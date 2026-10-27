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
    Id = 'windows'; Title = (T 'Захист Windows' 'Windows protection'); Order = 2
    Checks = @(
        @{
            Id = 'win-support'; Title = (T 'Підтримка версії Windows' 'Windows version support')
            Test = {
                $os = Get-OsInfo
                $ev = @("$($os.Name), " + (T 'збірка ' 'build ') + "$($os.Build).$($os.Ubr), " + (T 'редакція ' 'edition ') + $os.EditionID)
                if ($os.EditionID -match 'EnterpriseS|IoT') { return NotApplicable (T 'LTSC/IoT-версії мають власні, довші терміни підтримки.' 'LTSC/IoT editions have their own, longer support periods.') }
                $known = @($WinLifecycle.Keys | Sort-Object)
                if ($os.Build -gt $known[-1]) { return Ok (T 'новіша за відомі версії' 'newer than known versions') '' $ev }
                $row = $WinLifecycle[$os.Build]
                if (-not $row) { return Issue critical (T 'без підтримки' 'unsupported') (T 'Ця версія Windows давно не отримує оновлень безпеки.' 'This Windows version stopped getting security updates long ago.') $ev }
                $end = [datetime]$(if ($os.EditionID -match 'Enterprise|Education') { $row[2] } else { $row[1] })
                $days = [int]($end - (Get-Date)).TotalDays
                $endText = $end.ToString('dd.MM.yyyy')
                if ($days -lt 0) {
                    $esu = if ($os.Build -eq 19045) { T ' Якщо ПК записаний у програму розширених оновлень (ESU), вони тривали до 13.10.2026.' ' If the PC was enrolled in Extended Security Updates (ESU), they lasted until 13.10.2026.' } else { '' }
                    return Issue critical ((T 'підтримку завершено ' 'support ended ') + $endText) ((T 'Windows більше не отримує виправлень безпеки - нові вразливості лишаються відкритими.' 'Windows no longer receives security fixes - new vulnerabilities stay open.') + $esu) $ev
                }
                if ($days -lt 90) { return Issue medium ((T 'підтримка до ' 'supported until ') + $endText) (T "Залишилось $days дн. Заплануйте оновлення до новішої версії." "$days days left. Plan an upgrade to a newer version.") $ev }
                Ok ((T 'підтримка до ' 'supported until ') + $endText) '' $ev
            }
            Explain = (T 'Кожна версія Windows отримує оновлення безпеки обмежений час. Після цього нові вразливості не виправляють - це найпоширеніша причина зламу домашніх ПК.' 'Each Windows version receives security updates for a limited time. After that, new vulnerabilities are not fixed - the most common reason home PCs get hacked.')
            Pros = @((T 'Оновлення до новішої версії через Windows Update безкоштовне і зберігає програми та файли' 'Upgrading through Windows Update is free and keeps your programs and files'))
            Cons = @((T 'Велике оновлення займає 30-60 хвилин і кілька перезавантажень' 'A feature update takes 30-60 minutes and several restarts'), (T 'Зрідка старі драйвери або програми потребують оновлення після переходу' 'Occasionally old drivers or programs need updating afterwards'))
            Fix = @{ Open = 'ms-settings:windowsupdate'; Steps = @((T 'Відкрийте Windows Update і встановіть доступне функціональне оновлення (наприклад, «Windows 11, версія 25H2»).' 'Open Windows Update and install the available feature update (for example, "Windows 11, version 25H2").')) }
        }
        @{
            Id = 'antivirus'; Title = (T 'Антивірус' 'Antivirus')
            Test = {
                $other = Get-ThirdPartyAv
                if ($other) { return Ok $other.Name (T 'Microsoft Defender у пасивному режимі - захищає сторонній антивірус.' 'Microsoft Defender is in passive mode - a third-party antivirus provides protection.') }
                $mp = Get-Mp
                if (-not $mp.AntivirusEnabled) { return Issue critical (T 'вимкнено' 'off') (T 'Жоден антивірус не захищає ПК.' 'No antivirus protects the PC.') }
                if (-not $mp.RealTimeProtectionEnabled) { return Issue critical (T 'захист у реальному часі вимкнено' 'real-time protection off') (T 'Файли не перевіряються під час завантаження і запуску - шкідлива програма спрацює непомітно.' 'Files are not scanned when downloaded and run - malware will run unnoticed.') }
                Ok 'Microsoft Defender' (T 'Захист у реальному часі працює.' 'Real-time protection is on.')
            }
            Explain = (T 'Антивірус перевіряє файли під час завантаження й запуску. Вбудованого Microsoft Defender для домашнього ПК достатньо; другий антивірус поруч з ним не потрібен.' 'The antivirus scans files when downloaded and run. The built-in Microsoft Defender is enough for a home PC; a second antivirus alongside it is not needed.')
            Pros = @((T 'Блокує відомі шкідливі програми ще до запуску' 'Blocks known malware before it runs'))
            Cons = @((T 'Перевірка файлів трохи сповільнює компіляцію і розпакування великих архівів - для робочих папок можна додати винятки' 'Scanning slightly slows compiling and unpacking large archives - you can add exclusions for work folders'))
            Fix = @{ Open = 'windowsdefender://threat' }
        }
        @{
            Id = 'av-signatures'; Title = (T 'Бази антивіруса' 'Antivirus definitions')
            Test = {
                $other = Get-ThirdPartyAv
                if ($other) {
                    if ($other.UpToDate) { return Ok (T 'актуальні' 'up to date') } else { return Issue high (T 'застарілі' 'outdated') (T "$($other.Name) повідомляє, що бази застаріли." "$($other.Name) reports outdated definitions.") }
                }
                $age = (Get-Mp).AntivirusSignatureAge
                if ($age -gt 7) { return Issue high (T "оновлено $age дн. тому" "updated $age days ago") (T 'Антивірус не знає нових загроз останнього тижня.' 'The antivirus does not know this week''s new threats.') }
                if ($age -gt 3) { return Issue medium (T "оновлено $age дн. тому" "updated $age days ago") (T 'Бази зазвичай оновлюються кілька разів на день.' 'Definitions normally update several times a day.') }
                Ok $(if ($age -le 0) { T 'оновлено сьогодні' 'updated today' } else { T "оновлено $age дн. тому" "updated $age days ago" })
            }
            Explain = (T 'Бази (сигнатури) - опис відомих загроз. Щодня з''являються нові, тож застарілі бази пропускають свіжі віруси.' 'Definitions (signatures) describe known threats. New ones appear daily, so outdated definitions miss fresh malware.')
            Pros = @((T 'Захист від нових загроз' 'Protection from new threats'))
            Cons = @()
            Fix = @{ Open = 'windowsdefender://threat'; Steps = @((T 'У «Безпеці Windows» → «Захист від вірусів і загроз» натисніть «Оновлення захисту» → «Перевірити наявність оновлень».' 'In Windows Security → Virus & threat protection click "Protection updates" → "Check for updates".')) }
        }
        @{
            Id = 'tamper'; Title = (T 'Захист від підробки (Tamper Protection)' 'Tamper Protection')
            Test = {
                if (Get-ThirdPartyAv) { return NotApplicable (T 'Працює сторонній антивірус.' 'A third-party antivirus is active.') }
                if ((Get-Mp).IsTamperProtected) { Ok (T 'увімкнено' 'on') } else { Issue medium (T 'вимкнено' 'off') (T 'Шкідлива програма з правами адміністратора може тихо вимкнути Defender.' 'Malware with administrator rights can quietly turn Defender off.') }
            }
            Explain = (T 'Захист від підробки не дає програмам (навіть з правами адміністратора) вимикати Defender або змінювати його налаштування - це перше, що робить більшість шкідливих програм.' 'Tamper Protection stops programs (even with administrator rights) from disabling Defender or changing its settings - the first thing most malware tries.')
            Pros = @((T 'Шкідлива програма не зможе вимкнути антивірус' 'Malware cannot switch the antivirus off'))
            Cons = @((T 'Деякі «оптимізатори» і скрипти налаштування Defender перестануть працювати - змінюйте налаштування вручну в «Безпеці Windows»' 'Some "optimizers" and Defender tweak scripts stop working - change settings manually in Windows Security'))
            Fix = @{ Open = 'windowsdefender://threatsettings' }
        }
        @{
            Id = 'pua'; Title = (T 'Блокування небажаних програм (PUA)' 'Potentially unwanted app (PUA) blocking')
            Test = {
                if (Get-ThirdPartyAv) { return NotApplicable (T 'Працює сторонній антивірус.' 'A third-party antivirus is active.') }
                switch ((Get-MpPreference -ErrorAction Stop).PUAProtection) {
                    1 { Ok (T 'увімкнено' 'on') }
                    2 { Issue low (T 'лише аудит' 'audit only') (T 'Defender помічає небажані програми, але не блокує їх.' 'Defender notices unwanted apps but does not block them.') }
                    default { Issue low (T 'вимкнено' 'off') (T 'Рекламні модулі, «прискорювачі» і майнери з інсталяторів не блокуються.' 'Adware, "speed-up" tools and miners bundled with installers are not blocked.') }
                }
            }
            Explain = (T 'PUA - потенційно небажані програми: не віруси, але рекламні тулбари, «чистильники», приховані майнери, що їдуть разом із безкоштовними інсталяторами.' 'PUAs are potentially unwanted apps: not viruses, but ad toolbars, "cleaners" and hidden miners bundled with free installers.')
            Pros = @((T 'Блокує сміттєві програми з інсталяторів' 'Blocks junk bundled with installers'))
            Cons = @((T 'Зрідка блокує легітимні утиліти (генератори ключів, деякі завантажувачі торентів) - їх можна дозволити в журналі захисту' 'Occasionally blocks legitimate utilities (key generators, some torrent clients) - you can allow them in Protection history'))
            Fix = @{ Recipe = 'defender-pua'; Open = 'windowsdefender://appbrowser' }
        }
        @{
            Id = 'firewall'; Title = (T 'Брандмауер' 'Firewall')
            Test = {
                $off = @(Get-NetFirewallProfile -ErrorAction Stop | Where-Object { -not $_.Enabled } | ForEach-Object { $_.Name })
                if ($off.Count -eq 0) { return Ok (T 'увімкнено для всіх мереж' 'on for all networks') }
                $fw = @(Get-CimInstance -Namespace root\SecurityCenter2 -ClassName FirewallProduct -ErrorAction SilentlyContinue |
                        Where-Object { (($_.productState -shr 12) -band 0xF) -eq 1 })
                if ($fw) { return Ok $fw[0].displayName (T 'Брандмауер Windows вимкнено, але працює сторонній.' 'Windows Firewall is off, but a third-party firewall is active.') }
                $names = @{ Domain = (T 'доменна' 'domain'); Private = (T 'приватна' 'private'); Public = (T 'публічна' 'public') }
                $sev = if ($off -contains 'Public') { 'high' } else { 'medium' }
                Issue $sev ((T 'вимкнено: ' 'off: ') + (($off | ForEach-Object { $names[$_] }) -join ', ')) (T 'Вхідні з''єднання з мережі не фільтруються - відкриті служби ПК доступні всім у мережі (у кафе, готелі - стороннім людям).' 'Incoming network connections are not filtered - the PC''s open services are reachable by everyone on the network (strangers in a café or hotel).') $off
            }
            Explain = (T 'Брандмауер не пускає вхідні з''єднання з мережі до програм, яким ви цього не дозволяли. Особливо важливий у публічних Wi-Fi.' 'The firewall blocks incoming network connections to programs you have not allowed. Especially important on public Wi-Fi.')
            Pros = @((T 'Служби ПК (спільні папки, віддалений доступ) не видно стороннім у мережі' 'The PC''s services (shared folders, remote access) are hidden from strangers on the network'))
            Cons = @((T 'Програма, що приймає з''єднання (сервер гри, спільний доступ), при першому запуску попросить дозвіл' 'A program that accepts connections (a game server, sharing) asks for permission on first run'))
            Fix = @{ Open = 'windowsdefender://network' }
        }
        @{
            Id = 'uac'; Title = (T 'Контроль облікових записів (UAC)' 'User Account Control (UAC)')
            Test = {
                $p = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
                if ((Get-RegValue $p 'EnableLUA') -eq 0) { return Issue critical (T 'вимкнено' 'off') (T 'Кожна програма автоматично отримує повні права адміністратора.' 'Every program automatically gets full administrator rights.') }
                if ((Get-RegValue $p 'ConsentPromptBehaviorAdmin') -eq 0) { return Issue high (T 'без запитів' 'no prompts') (T 'Програми підвищують права без вашого підтвердження.' 'Programs elevate without your confirmation.') }
                if ((Get-RegValue $p 'PromptOnSecureDesktop') -eq 0) { return Issue low (T 'без захищеного робочого столу' 'no secure desktop') (T 'Запит UAC показується на звичайному робочому столі - шкідлива програма може «натиснути» його сама.' 'The UAC prompt appears on the normal desktop - malware can "click" it by itself.') }
                Ok (T 'типовий рівень' 'default level')
            }
            Explain = (T 'UAC питає підтвердження, коли програма хоче змінити систему. Навіть якщо ви адміністратор, програми працюють з обмеженими правами, доки ви не скажете «Так».' 'UAC asks for confirmation when a program wants to change the system. Even as an administrator, programs run with limited rights until you say "Yes".')
            Pros = @((T 'Шкідлива програма не отримає повних прав непомітно' 'Malware cannot silently get full rights'))
            Cons = @((T 'Частіше бачите запит «Дозволити цій програмі вносити зміни?»' 'You see "Do you want to allow this app to make changes?" more often'))
            Fix = @{ Recipe = 'uac-default' }
        }
        @{
            Id = 'smartscreen'; Title = (T 'SmartScreen для програм і файлів' 'SmartScreen for apps and files')
            Test = {
                $policy = Get-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'EnableSmartScreen'
                $explorer = Get-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer' 'SmartScreenEnabled'
                if ($policy -eq 0 -or $explorer -eq 'Off') { return Issue medium (T 'вимкнено' 'off') (T 'Windows не попереджає перед запуском маловідомих завантажених програм.' 'Windows does not warn before running little-known downloaded programs.') }
                Ok $(if ($null -eq $policy -and -not $explorer) { T 'увімкнено (типово)' 'on (default)' } else { T 'увімкнено' 'on' })
            }
            Explain = (T 'SmartScreen перевіряє репутацію завантажених програм і попереджає, якщо файл новий, рідкісний або відомий як шкідливий.' 'SmartScreen checks the reputation of downloaded programs and warns if a file is new, rare or known to be malicious.')
            Pros = @((T 'Попередження перед запуском підозрілих завантажень' 'A warning before running suspicious downloads'))
            Cons = @((T 'Показує попередження і для нових легітимних програм без підпису (як-от DEADPIXEL) - «Докладніше» → «Усе одно запустити»' 'It also warns about new legitimate unsigned programs (like DEADPIXEL) - "More info" → "Run anyway"'))
            Fix = @{ Open = 'windowsdefender://appbrowser' }
        }
        @{
            Id = 'updates'; Title = (T 'Оновлення Windows' 'Windows updates')
            Test = {
                $pause = Get-RegValue 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings' 'PauseUpdatesExpiryTime'
                $last = (New-Object -ComObject Microsoft.Update.AutoUpdate).Results.LastInstallationSuccessDate
                $ev = @()
                if ($last) { $ev += (T 'Останнє встановлення: ' 'Last installed: ') + ([datetime]$last).ToLocalTime().ToString('dd.MM.yyyy HH:mm') }
                if ($pause -and ([datetime]$pause) -gt (Get-Date)) {
                    $until = ([datetime]$pause).ToString('dd.MM.yyyy')
                    $ev += (T 'Призупинено до: ' 'Paused until: ') + $until
                    return Issue low ((T 'призупинено до ' 'paused until ') + $until) (T 'Поки оновлення призупинені, виправлення безпеки не встановлюються.' 'While updates are paused, security fixes are not installed.') $ev
                }
                if (-not $last) { return Unknown (T 'Windows Update не повідомив дату останнього встановлення.' 'Windows Update did not report the last install date.') }
                $days = [int]((Get-Date) - ([datetime]$last).ToLocalTime()).TotalDays
                if ($days -gt 60) { return Issue high (T "$days дн. без оновлень" "$days days without updates") (T 'Виправлення безпеки виходять щомісяця - ПК пропустив щонайменше два.' 'Security fixes ship monthly - the PC has missed at least two.') $ev }
                if ($days -gt 35) { return Issue medium (T "$days дн. без оновлень" "$days days without updates") (T 'Пропущено щомісячне оновлення безпеки.' 'A monthly security update was missed.') $ev }
                Ok $(if ($days -le 0) { T 'оновлено сьогодні' 'updated today' } else { T "оновлено $days дн. тому" "updated $days days ago" }) '' $ev
            }
            Explain = (T 'Щомісяця (другий вівторок) Microsoft випускає виправлення вразливостей. Чим довше ПК без оновлень, тим більше відомих способів його зламати.' 'Every month (Patch Tuesday) Microsoft ships vulnerability fixes. The longer a PC goes without updates, the more known ways there are to break in.')
            Pros = @((T 'Закриває вразливості, які вже використовують зловмисники' 'Closes vulnerabilities attackers already use'))
            Cons = @((T 'Потрібне перезавантаження; зрідка оновлення драйвера через Windows Update гірше за драйвер виробника (GPU-драйвер краще ставити з сайту NVIDIA/AMD)' 'A restart is needed; occasionally a driver from Windows Update is worse than the vendor''s (install GPU drivers from the NVIDIA/AMD site)'))
            Fix = @{ Open = 'ms-settings:windowsupdate' }
        }
        @{
            Id = 'pending-reboot'; Title = (T 'Очікує перезавантаження' 'Pending restart')
            Test = {
                $wu = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
                $cbs = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
                if ($wu -or $cbs) { return Issue low (T 'так' 'yes') (T 'Встановлені оновлення почнуть діяти лише після перезавантаження.' 'Installed updates take effect only after a restart.') }
                Ok (T 'ні' 'no')
            }
            Explain = (T 'Частина оновлень замінює системні файли, які зараз використовуються, - вони застосовуються під час перезавантаження. До того ПК лишається вразливим.' 'Some updates replace system files that are in use - they are applied during a restart. Until then the PC stays vulnerable.')
            Pros = @((T 'Оновлення безпеки починають діяти' 'Security updates take effect'))
            Cons = @((T 'Потрібно закрити програми' 'Programs have to be closed'))
            Fix = @{ Open = 'ms-settings:windowsupdate' }
        }
    )
}
