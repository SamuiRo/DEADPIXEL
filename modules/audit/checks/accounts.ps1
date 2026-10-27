# Облікові записи: хто може увійти в ПК і з якими правами.

$script:LocalUsers = $null
function Get-Users {
    if ($null -eq $script:LocalUsers) { $script:LocalUsers = @(Get-LocalUser -ErrorAction Stop) }
    $script:LocalUsers
}

# Відносний ідентифікатор (останнє число SID): 500 - вбудований Administrator, 501 - Guest, 503/504 - службові
function Get-Rid($u) { [int]($u.SID.Value -split '-')[-1] }

@{
    Id = 'accounts'; Title = 'Облікові записи'; Order = 3
    Checks = @(
        @{
            Id = 'autologon-password'; Title = 'Пароль автовходу в реєстрі'
            Test = {
                $p = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
                $pwd = Get-RegValue $p 'DefaultPassword'
                $auto = (Get-RegValue $p 'AutoAdminLogon') -eq '1'
                # Сам пароль не показуємо і нікуди не пишемо - лише факт, що він там є
                if ($pwd) { return Issue critical 'пароль збережено відкрито' 'Пароль облікового запису лежить у реєстрі звичайним текстом - його може прочитати будь-яка програма.' @("Користувач: $(Get-RegValue $p 'DefaultUserName')") }
                if ($auto) { return Issue info 'автовхід увімкнено' 'ПК входить в обліковий запис без пароля при старті: будь-хто з фізичним доступом отримує ваш робочий стіл.' }
                Ok 'немає'
            }
            Explain = 'Для автоматичного входу деякі інструкції радять записати пароль у реєстр (DefaultPassword). Там він зберігається відкритим текстом і доступний кожній програмі на ПК.'
            Pros = @('Пароль не витече через будь-яку програму на ПК')
            Cons = @('Якщо автовхід потрібен - налаштуйте його через Sysinternals Autologon: він зберігає пароль зашифрованим')
            Fix = @{ Open = 'netplwiz.exe'; Steps = @(
                'Щоб вимкнути автовхід: у вікні netplwiz поставте галочку «Користувачі мають вводити ім''я та пароль».',
                'Щоб лишити автовхід без відкритого пароля: видаліть значення DefaultPassword з HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon і налаштуйте вхід через Sysinternals Autologon.'
            ) }
        }
        @{
            Id = 'guest'; Title = 'Обліковий запис «Гість»'
            Test = {
                $g = Get-Users | Where-Object { (Get-Rid $_) -eq 501 }
                if ($g -and $g.Enabled) { return Issue high 'увімкнено' 'Будь-хто може увійти в ПК без пароля, а по мережі - отримати доступ до спільних папок.' }
                Ok 'вимкнено'
            }
            Explain = 'Гостьовий обліковий запис не має пароля. Windows вимикає його за замовчуванням; увімкнений зазвичай лишається після «спрощення» доступу до спільних папок.'
            Pros = @('Ніхто не увійде без пароля')
            Cons = @('Спільні папки, відкриті «для всіх» через гостя, перестануть працювати - надайте доступ конкретним користувачам')
            Fix = @{ Open = 'lusrmgr.msc'; Steps = @('Вимкнути: у командному рядку від адміністратора - net user Guest /active:no (або «Гість» у локалізованій Windows).') }
        }
        @{
            Id = 'builtin-admin'; Title = 'Вбудований обліковий запис Administrator'
            Test = {
                $a = Get-Users | Where-Object { (Get-Rid $_) -eq 500 }
                if ($a -and $a.Enabled) { return Issue medium 'увімкнено' 'На цей запис не діє UAC: усе, що в ньому запущено, одразу має повні права. Його ім''я однакове на всіх ПК - це перша ціль підбору пароля.' @($a.Name) }
                Ok 'вимкнено'
            }
            Explain = 'Вбудований Administrator - службовий запис для відновлення системи. Windows вимикає його за замовчуванням; працювати в ньому щодня небезпечно.'
            Pros = @('Немає облікового запису з повними правами без UAC')
            Cons = @('Якщо ви входите саме під ним - спершу створіть звичайний обліковий запис адміністратора')
            Fix = @{ Open = 'lusrmgr.msc'; Steps = @('Вимкнути: у командному рядку від адміністратора - net user Administrator /active:no.') }
        }
        @{
            Id = 'password-not-required'; Title = 'Облікові записи, яким не потрібен пароль'
            Test = {
                $bad = @(Get-Users | Where-Object { $_.Enabled -and -not $_.PasswordRequired -and (Get-Rid $_) -notin 501, 503 } | ForEach-Object { $_.Name })
                if ($bad.Count) { return Issue medium "$($bad.Count) шт." 'Для цих записів Windows дозволяє порожній пароль - у них може увійти будь-хто, хто сидить за ПК.' $bad }
                Ok 'немає'
            }
            Explain = 'Прапорець «пароль не обов''язковий» дозволяє обліковому запису мати порожній пароль. Через мережу Windows блокує вхід без пароля, але локально - ні.'
            Pros = @('Ніхто не увійде у ваш обліковий запис без пароля')
            Cons = @()
            Fix = @{ Open = 'ms-settings:signinoptions'; Steps = @('Встановіть пароль або PIN; прапорець скидається командою net user <ім''я> /passwordreq:yes (від адміністратора).') }
        }
        @{
            Id = 'daily-admin'; Title = 'Щоденна робота з правами адміністратора'
            Test = {
                # Під UAC група Administrators у токені позначена "лише для заборони", і WindowsIdentity.Groups її не показує;
                # whoami /groups показує її в обох режимах (CSV-заголовки локалізовані, тож шукаємо сам SID)
                $isAdminGroup = [bool](whoami /groups /fo csv /nh | Where-Object { $_ -match '"S-1-5-32-544"' })
                $members = @()
                try { $members = @(Get-LocalGroupMember -SID 'S-1-5-32-544' -ErrorAction Stop | ForEach-Object { $_.Name }) } catch { }
                if ($isAdminGroup) { return Issue info 'так' 'Ваш обліковий запис - адміністратор. Це звично для домашнього ПК: UAC все одно питає підтвердження, тож головне - не вимикати UAC.' $members }
                Ok 'ні' 'Ви працюєте як звичайний користувач - найбезпечніший варіант.' $members
            }
            Explain = 'Під обліковим записом адміністратора шкідливій програмі достатньо одного вашого «Так» в UAC. Звичайний користувач для підвищення прав мусить ввести пароль адміністратора.'
            Pros = @('Окремий обліковий запис адміністратора для встановлення програм, а щодня - звичайний користувач: найнадійніший варіант')
            Cons = @('Незручно: для встановлення програм і налаштувань доведеться вводити пароль адміністратора')
            Fix = @{ Open = 'ms-settings:otherusers' }
        }
        @{
            Id = 'local-accounts'; Title = 'Увімкнені облікові записи'
            Test = {
                $on = @(Get-Users | Where-Object Enabled | ForEach-Object {
                    $last = if ($_.LastLogon) { 'вхід ' + $_.LastLogon.ToString('dd.MM.yyyy') } else { 'ще не входив' }
                    "$($_.Name) ($last)"
                })
                Issue info "$($on.Count) шт." 'Перевірте, що впізнаєте кожен обліковий запис. Незнайомий запис - ознака того, що хтось налаштував собі доступ (або його створила програма, як-от пісочниця розробника).' $on
            }
            Explain = 'Зайвий увімкнений обліковий запис - ще один вхід у ПК. Зловмисники часто створюють собі прихований обліковий запис, щоб повертатися.'
            Pros = @()
            Cons = @()
            Fix = @{ Open = 'lusrmgr.msc' }
        }
    )
}
