# Захист Windows: антивірус, брандмауер, UAC, оновлення і термін підтримки версії.

# Кінець підтримки (Home/Pro; Enterprise/Education - другий рядок). Після цієї дати оновлень безпеки немає.
# Джерело: Microsoft Lifecycle. Нові версії Windows - дописати сюди.
$script:WinLifecycle = @{
    19045 = @('Windows 10 22H2', '2025-10-14', '2025-10-14')
    22000 = @('Windows 11 21H2', '2023-10-10', '2024-10-08')
    22621 = @('Windows 11 22H2', '2024-10-08', '2025-10-14')
    22631 = @('Windows 11 23H2', '2025-11-11', '2026-11-10')
    26100 = @('Windows 11 24H2', '2026-10-13', '2027-10-12')
    26200 = @('Windows 11 25H2', '2027-10-12', '2028-10-10')
}

# Антивіруси, які бачить Центр безпеки Windows: productState, біти 12-15 = 1 - увімкнено, біти 4-7 = 0 - бази актуальні
function Get-AvProducts {
    @(Get-CimInstance -Namespace root\SecurityCenter2 -ClassName AntiVirusProduct -ErrorAction SilentlyContinue | ForEach-Object {
        [pscustomobject]@{
            Name = $_.displayName; Enabled = (($_.productState -shr 12) -band 0xF) -eq 1
            UpToDate = (($_.productState -shr 4) -band 0xF) -eq 0
            IsDefender = $_.displayName -match 'Defender'
        }
    })
}

function Get-ThirdPartyAv { @(Get-AvProducts | Where-Object { $_.Enabled -and -not $_.IsDefender }) | Select-Object -First 1 }

$script:MpStatus = $null
function Get-Mp {
    if (-not $script:MpStatus) { $script:MpStatus = Get-MpComputerStatus -ErrorAction Stop }
    $script:MpStatus
}

@{
    Id = 'windows'; Title = 'Захист Windows'; Order = 2
    Checks = @(
        @{
            Id = 'win-support'; Title = 'Підтримка версії Windows'
            Test = {
                $os = Get-OsInfo
                $ev = @("$($os.Name), збірка $($os.Build).$($os.Ubr), редакція $($os.EditionID)")
                if ($os.EditionID -match 'EnterpriseS|IoT') { return NotApplicable 'LTSC/IoT-версії мають власні, довші терміни підтримки.' }
                $known = @($WinLifecycle.Keys | Sort-Object)
                if ($os.Build -gt $known[-1]) { return Ok 'новіша за відомі версії' '' $ev }
                $row = $WinLifecycle[$os.Build]
                if (-not $row) { return Issue critical 'без підтримки' 'Ця версія Windows давно не отримує оновлень безпеки.' $ev }
                $end = [datetime]$(if ($os.EditionID -match 'Enterprise|Education') { $row[2] } else { $row[1] })
                $days = [int]($end - (Get-Date)).TotalDays
                $endText = $end.ToString('dd.MM.yyyy')
                if ($days -lt 0) {
                    $esu = if ($os.Build -eq 19045) { ' Якщо ПК записаний у програму розширених оновлень (ESU), вони тривали до 13.10.2026.' } else { '' }
                    return Issue critical "підтримку завершено $endText" ("Windows більше не отримує виправлень безпеки - нові вразливості лишаються відкритими.$esu") $ev
                }
                if ($days -lt 90) { return Issue medium "підтримка до $endText" "Залишилось $days дн. Заплануйте оновлення до новішої версії." $ev }
                Ok "підтримка до $endText" '' $ev
            }
            Explain = 'Кожна версія Windows отримує оновлення безпеки обмежений час. Після цього нові вразливості не виправляють - це найпоширеніша причина зламу домашніх ПК.'
            Pros = @('Оновлення до новішої версії через Windows Update безкоштовне і зберігає програми та файли')
            Cons = @('Велике оновлення займає 30-60 хвилин і кілька перезавантажень', 'Зрідка старі драйвери або програми потребують оновлення після переходу')
            Fix = @{ Open = 'ms-settings:windowsupdate'; Steps = @('Відкрийте Windows Update і встановіть доступне функціональне оновлення (наприклад, «Windows 11, версія 25H2»).') }
        }
        @{
            Id = 'antivirus'; Title = 'Антивірус'
            Test = {
                $other = Get-ThirdPartyAv
                if ($other) { return Ok $other.Name 'Microsoft Defender у пасивному режимі - захищає сторонній антивірус.' }
                $mp = Get-Mp
                if (-not $mp.AntivirusEnabled) { return Issue critical 'вимкнено' 'Жоден антивірус не захищає ПК.' }
                if (-not $mp.RealTimeProtectionEnabled) { return Issue critical 'захист у реальному часі вимкнено' 'Файли не перевіряються під час завантаження і запуску - шкідлива програма спрацює непомітно.' }
                Ok 'Microsoft Defender' 'Захист у реальному часі працює.'
            }
            Explain = 'Антивірус перевіряє файли під час завантаження й запуску. Вбудованого Microsoft Defender для домашнього ПК достатньо; другий антивірус поруч з ним не потрібен.'
            Pros = @('Блокує відомі шкідливі програми ще до запуску')
            Cons = @('Перевірка файлів трохи сповільнює компіляцію і розпакування великих архівів - для робочих папок можна додати винятки')
            Fix = @{ Open = 'windowsdefender://threat' }
        }
        @{
            Id = 'av-signatures'; Title = 'Бази антивіруса'
            Test = {
                $other = Get-ThirdPartyAv
                if ($other) {
                    if ($other.UpToDate) { return Ok 'актуальні' } else { return Issue high 'застарілі' "$($other.Name) повідомляє, що бази застаріли." }
                }
                $age = (Get-Mp).AntivirusSignatureAge
                if ($age -gt 7) { return Issue high "оновлено $age дн. тому" 'Антивірус не знає нових загроз останнього тижня.' }
                if ($age -gt 3) { return Issue medium "оновлено $age дн. тому" 'Бази зазвичай оновлюються кілька разів на день.' }
                Ok $(if ($age -le 0) { 'оновлено сьогодні' } else { "оновлено $age дн. тому" })
            }
            Explain = 'Бази (сигнатури) - опис відомих загроз. Щодня з''являються нові, тож застарілі бази пропускають свіжі віруси.'
            Pros = @('Захист від нових загроз')
            Cons = @()
            Fix = @{ Open = 'windowsdefender://threat'; Steps = @('У «Безпеці Windows» → «Захист від вірусів і загроз» натисніть «Оновлення захисту» → «Перевірити наявність оновлень».') }
        }
        @{
            Id = 'tamper'; Title = 'Захист від підробки (Tamper Protection)'
            Test = {
                if (Get-ThirdPartyAv) { return NotApplicable 'Працює сторонній антивірус.' }
                if ((Get-Mp).IsTamperProtected) { Ok 'увімкнено' } else { Issue medium 'вимкнено' 'Шкідлива програма з правами адміністратора може тихо вимкнути Defender.' }
            }
            Explain = 'Захист від підробки не дає програмам (навіть з правами адміністратора) вимикати Defender або змінювати його налаштування - це перше, що робить більшість шкідливих програм.'
            Pros = @('Шкідлива програма не зможе вимкнути антивірус')
            Cons = @('Деякі «оптимізатори» і скрипти налаштування Defender перестануть працювати - змінюйте налаштування вручну в «Безпеці Windows»')
            Fix = @{ Open = 'windowsdefender://threatsettings' }
        }
        @{
            Id = 'pua'; Title = 'Блокування небажаних програм (PUA)'
            Test = {
                if (Get-ThirdPartyAv) { return NotApplicable 'Працює сторонній антивірус.' }
                switch ((Get-MpPreference -ErrorAction Stop).PUAProtection) {
                    1 { Ok 'увімкнено' }
                    2 { Issue low 'лише аудит' 'Defender помічає небажані програми, але не блокує їх.' }
                    default { Issue low 'вимкнено' 'Рекламні модулі, «прискорювачі» і майнери з інсталяторів не блокуються.' }
                }
            }
            Explain = 'PUA - потенційно небажані програми: не віруси, але рекламні тулбари, «чистильники», приховані майнери, що їдуть разом із безкоштовними інсталяторами.'
            Pros = @('Блокує сміттєві програми з інсталяторів')
            Cons = @('Зрідка блокує легітимні утиліти (генератори ключів, деякі завантажувачі торентів) - їх можна дозволити в журналі захисту')
            Fix = @{ Recipe = 'defender-pua'; Open = 'windowsdefender://appbrowser' }
        }
        @{
            Id = 'firewall'; Title = 'Брандмауер'
            Test = {
                $off = @(Get-NetFirewallProfile -ErrorAction Stop | Where-Object { -not $_.Enabled } | ForEach-Object { $_.Name })
                if ($off.Count -eq 0) { return Ok 'увімкнено для всіх мереж' }
                $fw = @(Get-CimInstance -Namespace root\SecurityCenter2 -ClassName FirewallProduct -ErrorAction SilentlyContinue |
                        Where-Object { (($_.productState -shr 12) -band 0xF) -eq 1 })
                if ($fw) { return Ok $fw[0].displayName 'Брандмауер Windows вимкнено, але працює сторонній.' }
                $names = @{ Domain = 'доменна'; Private = 'приватна'; Public = 'публічна' }
                $sev = if ($off -contains 'Public') { 'high' } else { 'medium' }
                Issue $sev ('вимкнено: ' + (($off | ForEach-Object { $names[$_] }) -join ', ')) 'Вхідні з''єднання з мережі не фільтруються - відкриті служби ПК доступні всім у мережі (у кафе, готелі - стороннім людям).' $off
            }
            Explain = 'Брандмауер не пускає вхідні з''єднання з мережі до програм, яким ви цього не дозволяли. Особливо важливий у публічних Wi-Fi.'
            Pros = @('Служби ПК (спільні папки, віддалений доступ) не видно стороннім у мережі')
            Cons = @('Програма, що приймає з''єднання (сервер гри, спільний доступ), при першому запуску попросить дозвіл')
            Fix = @{ Open = 'windowsdefender://network' }
        }
        @{
            Id = 'uac'; Title = 'Контроль облікових записів (UAC)'
            Test = {
                $p = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
                if ((Get-RegValue $p 'EnableLUA') -eq 0) { return Issue critical 'вимкнено' 'Кожна програма автоматично отримує повні права адміністратора.' }
                if ((Get-RegValue $p 'ConsentPromptBehaviorAdmin') -eq 0) { return Issue high 'без запитів' 'Програми підвищують права без вашого підтвердження.' }
                if ((Get-RegValue $p 'PromptOnSecureDesktop') -eq 0) { return Issue low 'без захищеного робочого столу' 'Запит UAC показується на звичайному робочому столі - шкідлива програма може «натиснути» його сама.' }
                Ok 'типовий рівень'
            }
            Explain = 'UAC питає підтвердження, коли програма хоче змінити систему. Навіть якщо ви адміністратор, програми працюють з обмеженими правами, доки ви не скажете «Так».'
            Pros = @('Шкідлива програма не отримає повних прав непомітно')
            Cons = @('Частіше бачите запит «Дозволити цій програмі вносити зміни?»')
            Fix = @{ Recipe = 'uac-default' }
        }
        @{
            Id = 'smartscreen'; Title = 'SmartScreen для програм і файлів'
            Test = {
                $policy = Get-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'EnableSmartScreen'
                $explorer = Get-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer' 'SmartScreenEnabled'
                if ($policy -eq 0 -or $explorer -eq 'Off') { return Issue medium 'вимкнено' 'Windows не попереджає перед запуском маловідомих завантажених програм.' }
                Ok $(if ($null -eq $policy -and -not $explorer) { 'увімкнено (типово)' } else { 'увімкнено' })
            }
            Explain = 'SmartScreen перевіряє репутацію завантажених програм і попереджає, якщо файл новий, рідкісний або відомий як шкідливий.'
            Pros = @('Попередження перед запуском підозрілих завантажень')
            Cons = @('Показує попередження і для нових легітимних програм без підпису (як-от DEADPIXEL) - «Докладніше» → «Усе одно запустити»')
            Fix = @{ Open = 'windowsdefender://appbrowser' }
        }
        @{
            Id = 'updates'; Title = 'Оновлення Windows'
            Test = {
                $pause = Get-RegValue 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings' 'PauseUpdatesExpiryTime'
                $last = (New-Object -ComObject Microsoft.Update.AutoUpdate).Results.LastInstallationSuccessDate
                $ev = @()
                if ($last) { $ev += 'Останнє встановлення: ' + ([datetime]$last).ToLocalTime().ToString('dd.MM.yyyy HH:mm') }
                if ($pause -and ([datetime]$pause) -gt (Get-Date)) {
                    $ev += 'Призупинено до: ' + ([datetime]$pause).ToString('dd.MM.yyyy')
                    return Issue low ('призупинено до ' + ([datetime]$pause).ToString('dd.MM.yyyy')) 'Поки оновлення призупинені, виправлення безпеки не встановлюються.' $ev
                }
                if (-not $last) { return Unknown 'Windows Update не повідомив дату останнього встановлення.' }
                $days = [int]((Get-Date) - ([datetime]$last).ToLocalTime()).TotalDays
                if ($days -gt 60) { return Issue high "$days дн. без оновлень" 'Виправлення безпеки виходять щомісяця - ПК пропустив щонайменше два.' $ev }
                if ($days -gt 35) { return Issue medium "$days дн. без оновлень" 'Пропущено щомісячне оновлення безпеки.' $ev }
                Ok $(if ($days -le 0) { 'оновлено сьогодні' } else { "оновлено $days дн. тому" }) '' $ev
            }
            Explain = 'Щомісяця (другий вівторок) Microsoft випускає виправлення вразливостей. Чим довше ПК без оновлень, тим більше відомих способів його зламати.'
            Pros = @('Закриває вразливості, які вже використовують зловмисники')
            Cons = @('Потрібне перезавантаження; зрідка оновлення драйвера через Windows Update гірше за драйвер виробника (GPU-драйвер краще ставити з сайту NVIDIA/AMD)')
            Fix = @{ Open = 'ms-settings:windowsupdate' }
        }
        @{
            Id = 'pending-reboot'; Title = 'Очікує перезавантаження'
            Test = {
                $wu = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
                $cbs = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
                if ($wu -or $cbs) { return Issue low 'так' 'Встановлені оновлення почнуть діяти лише після перезавантаження.' }
                Ok 'ні'
            }
            Explain = 'Частина оновлень замінює системні файли, які зараз використовуються, - вони застосовуються під час перезавантаження. До того ПК лишається вразливим.'
            Pros = @('Оновлення безпеки починають діяти')
            Cons = @('Потрібно закрити програми')
            Fix = @{ Open = 'ms-settings:windowsupdate' }
        }
    )
}
