# Облікові записи: хто може увійти в ПК і з якими правами.

$script:LocalUsers = $null
function Get-Users {
    if ($null -eq $script:LocalUsers) { $script:LocalUsers = @(Get-LocalUser -ErrorAction Stop) }
    $script:LocalUsers
}

# Відносний ідентифікатор (останнє число SID): 500 - вбудований Administrator, 501 - Guest, 503/504 - службові
function Get-Rid($u) { [int]($u.SID.Value -split '-')[-1] }

@{
    Id = 'accounts'; Title = (T 'Облікові записи' 'Accounts'); Order = 3
    Checks = @(
        @{
            Id = 'autologon-password'; Title = (T 'Пароль автовходу в реєстрі' 'Auto sign-in password in the registry')
            Test = {
                $p = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
                $pwd = Get-RegValue $p 'DefaultPassword'
                $auto = (Get-RegValue $p 'AutoAdminLogon') -eq '1'
                # Сам пароль не показуємо і нікуди не пишемо - лише факт, що він там є
                if ($pwd) { return Issue critical (T 'пароль збережено відкрито' 'password stored in plain text') (T 'Пароль облікового запису лежить у реєстрі звичайним текстом - його може прочитати будь-яка програма.' 'The account password sits in the registry as plain text - any program can read it.') @((T 'Користувач: ' 'User: ') + (Get-RegValue $p 'DefaultUserName')) }
                if ($auto) { return Issue info (T 'автовхід увімкнено' 'auto sign-in on') (T 'ПК входить в обліковий запис без пароля при старті: будь-хто з фізичним доступом отримує ваш робочий стіл.' 'The PC signs in without a password at startup: anyone with physical access gets your desktop.') }
                Ok (T 'немає' 'none')
            }
            Explain = (T 'Для автоматичного входу деякі інструкції радять записати пароль у реєстр (DefaultPassword). Там він зберігається відкритим текстом і доступний кожній програмі на ПК.' 'For automatic sign-in, some guides suggest writing the password to the registry (DefaultPassword). There it is stored in plain text and readable by every program on the PC.')
            Pros = @((T 'Пароль не витече через будь-яку програму на ПК' 'The password cannot leak through any program on the PC'))
            Cons = @((T 'Якщо автовхід потрібен - налаштуйте його через Sysinternals Autologon: він зберігає пароль зашифрованим' 'If you need auto sign-in, set it up with Sysinternals Autologon: it stores the password encrypted'))
            Fix = @{ Open = 'netplwiz.exe'; Steps = @(
                (T 'Щоб вимкнути автовхід: у вікні netplwiz поставте галочку «Користувачі мають вводити ім''я та пароль».' 'To turn off auto sign-in: in netplwiz tick "Users must enter a user name and password".'),
                (T 'Щоб лишити автовхід без відкритого пароля: видаліть значення DefaultPassword з HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon і налаштуйте вхід через Sysinternals Autologon.' 'To keep auto sign-in without a plain-text password: delete DefaultPassword from HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon and set up sign-in with Sysinternals Autologon.')
            ) }
        }
        @{
            Id = 'guest'; Title = (T 'Обліковий запис «Гість»' 'The Guest account')
            Test = {
                $g = Get-Users | Where-Object { (Get-Rid $_) -eq 501 }
                if ($g -and $g.Enabled) { return Issue high (T 'увімкнено' 'enabled') (T 'Будь-хто може увійти в ПК без пароля, а по мережі - отримати доступ до спільних папок.' 'Anyone can sign in to the PC without a password and, over the network, access shared folders.') }
                Ok (T 'вимкнено' 'disabled')
            }
            Explain = (T 'Гостьовий обліковий запис не має пароля. Windows вимикає його за замовчуванням; увімкнений зазвичай лишається після «спрощення» доступу до спільних папок.' 'The Guest account has no password. Windows disables it by default; it usually stays enabled after "simplifying" shared folder access.')
            Pros = @((T 'Ніхто не увійде без пароля' 'Nobody can sign in without a password'))
            Cons = @((T 'Спільні папки, відкриті «для всіх» через гостя, перестануть працювати - надайте доступ конкретним користувачам' 'Shared folders opened to "everyone" via Guest stop working - grant access to specific users'))
            Fix = @{ Open = 'lusrmgr.msc'; Steps = @((T 'Вимкнути: у командному рядку від адміністратора - net user Guest /active:no (або «Гість» у локалізованій Windows).' 'To disable: in an administrator command prompt run net user Guest /active:no (the account name may be localized).')) }
        }
        @{
            Id = 'builtin-admin'; Title = (T 'Вбудований обліковий запис Administrator' 'The built-in Administrator account')
            Test = {
                $a = Get-Users | Where-Object { (Get-Rid $_) -eq 500 }
                if ($a -and $a.Enabled) { return Issue medium (T 'увімкнено' 'enabled') (T 'На цей запис не діє UAC: усе, що в ньому запущено, одразу має повні права. Його ім''я однакове на всіх ПК - це перша ціль підбору пароля.' 'UAC does not apply to this account: everything run in it has full rights at once. Its name is the same on every PC - the first target of password guessing.') @($a.Name) }
                Ok (T 'вимкнено' 'disabled')
            }
            Explain = (T 'Вбудований Administrator - службовий запис для відновлення системи. Windows вимикає його за замовчуванням; працювати в ньому щодня небезпечно.' 'The built-in Administrator is a service account for system recovery. Windows disables it by default; using it daily is dangerous.')
            Pros = @((T 'Немає облікового запису з повними правами без UAC' 'No account with full rights that bypasses UAC'))
            Cons = @((T 'Якщо ви входите саме під ним - спершу створіть звичайний обліковий запис адміністратора' 'If you sign in with it, first create a regular administrator account'))
            Fix = @{ Open = 'lusrmgr.msc'; Steps = @((T 'Вимкнути: у командному рядку від адміністратора - net user Administrator /active:no.' 'To disable: in an administrator command prompt run net user Administrator /active:no.')) }
        }
        @{
            Id = 'password-not-required'; Title = (T 'Облікові записи, яким не потрібен пароль' 'Accounts that do not require a password')
            Test = {
                $bad = @(Get-Users | Where-Object { $_.Enabled -and -not $_.PasswordRequired -and (Get-Rid $_) -notin 501, 503 } | ForEach-Object { $_.Name })
                if ($bad.Count) { return Issue medium (T "$($bad.Count) шт." "$($bad.Count)") (T 'Для цих записів Windows дозволяє порожній пароль - у них може увійти будь-хто, хто сидить за ПК.' 'Windows allows an empty password for these accounts - anyone at the PC can sign in to them.') $bad }
                Ok (T 'немає' 'none')
            }
            Explain = (T 'Прапорець «пароль не обов''язковий» дозволяє обліковому запису мати порожній пароль. Через мережу Windows блокує вхід без пароля, але локально - ні.' 'The "password not required" flag lets an account have an empty password. Windows blocks passwordless sign-in over the network, but not locally.')
            Pros = @((T 'Ніхто не увійде у ваш обліковий запис без пароля' 'Nobody can sign in to your account without a password'))
            Cons = @()
            Fix = @{ Open = 'ms-settings:signinoptions'; Steps = @((T 'Встановіть пароль або PIN; прапорець скидається командою net user <ім''я> /passwordreq:yes (від адміністратора).' 'Set a password or PIN; clear the flag with net user <name> /passwordreq:yes (as administrator).')) }
        }
        @{
            Id = 'daily-admin'; Title = (T 'Щоденна робота з правами адміністратора' 'Daily use of an administrator account')
            Test = {
                # Під UAC група Administrators у токені позначена "лише для заборони", і WindowsIdentity.Groups її не показує;
                # whoami /groups показує її в обох режимах (CSV-заголовки локалізовані, тож шукаємо сам SID)
                $isAdminGroup = [bool](whoami /groups /fo csv /nh | Where-Object { $_ -match '"S-1-5-32-544"' })
                $members = @()
                try { $members = @(Get-LocalGroupMember -SID 'S-1-5-32-544' -ErrorAction Stop | ForEach-Object { $_.Name }) } catch { }
                if ($isAdminGroup) { return Issue info (T 'так' 'yes') (T 'Ваш обліковий запис - адміністратор. Це звично для домашнього ПК: UAC все одно питає підтвердження, тож головне - не вимикати UAC.' 'Your account is an administrator. That is normal for a home PC: UAC still asks for confirmation, so the key thing is to keep UAC on.') $members }
                Ok (T 'ні' 'no') (T 'Ви працюєте як звичайний користувач - найбезпечніший варіант.' 'You work as a standard user - the safest option.') $members
            }
            Explain = (T 'Під обліковим записом адміністратора шкідливій програмі достатньо одного вашого «Так» в UAC. Звичайний користувач для підвищення прав мусить ввести пароль адміністратора.' 'On an administrator account, malware needs just one "Yes" from you in UAC. A standard user must enter an administrator password to elevate.')
            Pros = @((T 'Окремий обліковий запис адміністратора для встановлення програм, а щодня - звичайний користувач: найнадійніший варіант' 'A separate administrator account for installing programs and a standard user for daily work is the most robust setup'))
            Cons = @((T 'Незручно: для встановлення програм і налаштувань доведеться вводити пароль адміністратора' 'Less convenient: installing programs and changing settings requires the administrator password'))
            Fix = @{ Open = 'ms-settings:otherusers' }
        }
        @{
            Id = 'local-accounts'; Title = (T 'Увімкнені облікові записи' 'Enabled accounts')
            Test = {
                $on = @(Get-Users | Where-Object Enabled | ForEach-Object {
                    $last = if ($_.LastLogon) { (T 'вхід ' 'last sign-in ') + $_.LastLogon.ToString('dd.MM.yyyy') } else { T 'ще не входив' 'never signed in' }
                    "$($_.Name) ($last)"
                })
                Issue info (T "$($on.Count) шт." "$($on.Count)") (T 'Перевірте, що впізнаєте кожен обліковий запис. Незнайомий запис - ознака того, що хтось налаштував собі доступ (або його створила програма, як-от пісочниця розробника).' 'Make sure you recognize every account. An unfamiliar one is a sign that someone set up access for themselves (or a program created it, such as a developer sandbox).') $on
            }
            Explain = (T 'Зайвий увімкнений обліковий запис - ще один вхід у ПК. Зловмисники часто створюють собі прихований обліковий запис, щоб повертатися.' 'An unneeded enabled account is one more way into the PC. Attackers often create a hidden account to come back.')
            Pros = @()
            Cons = @()
            Fix = @{ Open = 'lusrmgr.msc' }
        }
    )
}
