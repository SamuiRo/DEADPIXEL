# Посилений захист: те, що у Windows є, але вимкнено за замовчуванням, і те, що антивірус сам не закриває.

# Правила зменшення поверхні атаки (ASR) Microsoft Defender. Recommended - безпечні для домашнього ПК
# (їх вмикає рецепт asr-rules); решта часто заважає розробці та адмініструванню - лише показуємо.
# Джерело ідентифікаторів: Microsoft Learn, «Attack surface reduction rules reference».
$script:AsrRules = @(
    @{ Id = '56a863a9-875e-4185-98a7-b882c64b5ce5'; Recommended = $true; Title = (T 'Блокувати вразливі підписані драйвери' 'Block abuse of vulnerable signed drivers') }
    @{ Id = '9e6c4e1f-7d60-472f-ba1a-a39ef669e4b2'; Recommended = $true; Title = (T 'Блокувати крадіжку паролів із пам''яті Windows (LSASS)' 'Block credential stealing from Windows memory (LSASS)') }
    @{ Id = 'e6db77e5-3df2-4cf1-b95a-636979351e5b'; Recommended = $true; Title = (T 'Блокувати закріплення через підписки WMI' 'Block persistence through WMI subscriptions') }
    @{ Id = 'be9ba2d9-53ea-4cdc-84e5-9b1eeee46550'; Recommended = $true; Title = (T 'Блокувати програми з листів і вебпошти' 'Block executable content from email and webmail') }
    @{ Id = 'd3e037e1-3eb8-44c8-a917-57927947596d'; Recommended = $true; Title = (T 'Блокувати запуск завантажених програм зі скриптів JS/VBS' 'Block JS/VBS from launching downloaded executables') }
    @{ Id = 'd4f940ab-401b-4efc-aadc-ad5f3c50688a'; Recommended = $true; Title = (T 'Office: блокувати запуск інших програм' 'Office: block creating child processes') }
    @{ Id = '3b576869-a4ec-4529-8536-b80a7769e899'; Recommended = $true; Title = (T 'Office: блокувати створення програм' 'Office: block creating executable content') }
    @{ Id = '75668c1f-73b5-4cf0-bb93-3ecf5cb7cc84'; Recommended = $true; Title = (T 'Office: блокувати втручання в інші процеси' 'Office: block injecting code into other processes') }
    @{ Id = '92e97fa1-2edf-4476-bdd6-9dd0b4dddc7b'; Recommended = $true; Title = (T 'Office: блокувати виклики Win32 API з макросів' 'Office: block Win32 API calls from macros') }
    @{ Id = '26190899-1602-49e8-8b27-eb1d0a1ce869'; Recommended = $true; Title = (T 'Outlook: блокувати запуск інших програм' 'Outlook: block creating child processes') }
    @{ Id = '7674ba52-37eb-4a4f-a9a1-f0f9a1619a2c'; Recommended = $true; Title = (T 'Adobe Reader: блокувати запуск інших програм' 'Adobe Reader: block creating child processes') }
    @{ Id = 'b2b3f03d-6a65-4f7b-a9c7-1c7ef74a9ba4'; Recommended = $true; Title = (T 'Блокувати непідписані програми з USB-носіїв' 'Block untrusted and unsigned processes from USB') }
    @{ Id = 'c1db55ab-c21a-4637-bb3f-a12568109d35'; Recommended = $true; Title = (T 'Розширений захист від програм-вимагачів' 'Advanced protection against ransomware') }
    @{ Id = 'c0033c00-d16d-4114-a5a0-dc9b3a7d2ceb'; Recommended = $true; Title = (T 'Блокувати підроблені копії системних утиліт' 'Block copied or impersonated system tools') }
    @{ Id = '33ddedf1-c6e0-47cb-833e-de6133960387'; Recommended = $true; Title = (T 'Блокувати перезавантаження в безпечний режим' 'Block rebooting the machine in Safe Mode') }
    @{ Id = '5beb7efe-fd9a-4556-801d-275e5ffc04cc'; Recommended = $false; Title = (T 'Блокувати заплутані (обфусковані) скрипти' 'Block potentially obfuscated scripts') }
    @{ Id = '01443614-cd74-433a-b99e-2ecdc07bfc25'; Recommended = $false; Title = (T 'Блокувати маловідомі програми (за поширеністю й віком)' 'Block executables unless they meet prevalence or age criteria') }
    @{ Id = 'd1e49aac-8f56-4280-b9ba-993a6d77406c'; Recommended = $false; Title = (T 'Блокувати запуск процесів через PsExec і WMI' 'Block process creations from PsExec and WMI commands') }
)

# Стан правил: ідентифікатор (нижній регістр) → дія (0 вимкнено, 1 блокувати, 2 аудит, 6 попереджати)
function Get-AsrState {
    $p = Get-MpPreference -ErrorAction Stop
    $state = @{}
    $ids = @($p.AttackSurfaceReductionRules_Ids); $actions = @($p.AttackSurfaceReductionRules_Actions)
    for ($i = 0; $i -lt $ids.Count; $i++) { if ($ids[$i]) { $state[([string]$ids[$i]).ToLowerInvariant()] = [int]$actions[$i] } }
    $state
}

@{
    Id = 'hardening'; Title = (T 'Посилений захист' 'Hardening'); Order = 2.5
    Checks = @(
        @{
            Id = 'asr-rules'; Title = (T 'Правила зменшення поверхні атаки (ASR)' 'Attack surface reduction (ASR) rules')
            Test = {
                if (Get-ThirdPartyAv) { return NotApplicable (T 'Працює сторонній антивірус - правила ASR Defender неактивні.' 'A third-party antivirus is active - Defender ASR rules do not apply.') }
                $state = Get-AsrState
                $names = @{ 0 = (T 'вимкнено' 'off'); 1 = (T 'блокує' 'blocks'); 2 = (T 'лише аудит' 'audit only'); 6 = (T 'попереджає' 'warns') }
                $on = 0; $rec = @($AsrRules | Where-Object Recommended)
                $ev = foreach ($r in $AsrRules) {
                    $a = [int]$state[$r.Id]
                    if ($r.Recommended -and $a -in 1, 6) { $on++ }
                    $mark = if ($a -in 1, 6) { '✓' } elseif ($r.Recommended) { '⚠' } else { '·' }
                    "$mark $($r.Title) - $($names[$a])" + $(if (-not $r.Recommended) { T ' (необов''язкове: заважає розробці)' ' (optional: gets in the way of development)' })
                }
                $value = T "$on з $($rec.Count)" "$on of $($rec.Count)"
                if ($on -eq $rec.Count) { return Ok $value '' $ev }
                $detail = T 'Ці правила блокують не конкретні віруси, а самі прийоми атак: документ, що запускає PowerShell; скрипт із листа, що завантажує програму; читання паролів із пам''яті Windows. Вони спрацьовують, навіть коли шкідлива програма нова і в базах її ще немає. У Windows Home і Pro вони є, але вимкнені.' 'These rules block not specific malware but the attack techniques themselves: a document launching PowerShell; an emailed script downloading a program; reading passwords from Windows memory. They work even when the malware is new and not yet in the definitions. Windows Home and Pro ship them, but turned off.'
                Issue $(if ($on -eq 0) { 'medium' } else { 'low' }) $value $detail $ev
            }
            Explain = (T 'Антивірус упізнає відомі шкідливі файли. Правила ASR закривають те, чого він не бачить: зловживання легітимними програмами (Word, Outlook, скрипти Windows, драйвери). Саме цей шар зупиняє більшість атак через документи й листи.' 'The antivirus recognizes known malicious files. ASR rules close what it cannot see: abuse of legitimate programs (Word, Outlook, Windows scripts, drivers). This layer stops most document- and email-borne attacks.')
            Pros = @((T 'Зупиняє нові загрози за поведінкою, а не за сигнатурою' 'Stops new threats by behavior, not by signature'), (T 'Безкоштовно і вже вбудовано у Windows' 'Free and already built into Windows'), (T 'Заблоковане видно в журналі захисту, правило можна вимкнути окремо' 'Blocked actions show in Protection history; each rule can be turned off separately'))
            Cons = @((T 'Зрідка блокує легітимне: макроси Office, що запускають зовнішні програми, утиліти з флешки без підпису' 'Occasionally blocks legitimate things: Office macros launching external programs, unsigned tools on a USB stick'), (T 'Потрібен Microsoft Defender із хмарним захистом; зі стороннім антивірусом правила не працюють' 'Requires Microsoft Defender with cloud protection; the rules do not work with a third-party antivirus'))
            Fix = @{ Recipe = 'asr-rules'; Steps = @((T 'Рецепт «Правила ASR» у Сетапі вмикає рекомендований набір і вміє відкотити кожне правило. Якщо щось потрібне заблоковано - «Безпека Windows» → «Журнал захисту» покаже, яке саме правило спрацювало.' 'The "ASR rules" recipe in Setup turns on the recommended set and can revert each rule. If something you need gets blocked, Windows Security → Protection history shows which rule fired.')) }
        }
        @{
            Id = 'network-protection'; Title = (T 'Мережевий захист Defender' 'Defender network protection')
            Test = {
                if (Get-ThirdPartyAv) { return NotApplicable (T 'Працює сторонній антивірус.' 'A third-party antivirus is active.') }
                switch ([int](Get-MpPreference -ErrorAction Stop).EnableNetworkProtection) {
                    1 { Ok (T 'увімкнено' 'on') }
                    2 { Issue low (T 'лише аудит' 'audit only') (T 'Defender записує звернення до шкідливих адрес, але не блокує їх.' 'Defender logs connections to malicious addresses but does not block them.') }
                    default { Issue low (T 'вимкнено' 'off') (T 'SmartScreen захищає лише Edge. Мережевий захист поширює ту саму базу шкідливих і фішингових адрес на всі програми: інші браузери, лаунчери, скрипти, вбудовані вебв''ю.' 'SmartScreen protects only Edge. Network protection extends the same database of malicious and phishing addresses to every program: other browsers, launchers, scripts, embedded web views.') }
                }
            }
            Explain = (T 'Мережевий захист блокує з''єднання будь-якої програми з адресами, які Microsoft знає як шкідливі: сервери керування вірусами, фішингові сайти, домени для завантаження шкідливих файлів.' 'Network protection blocks any program''s connections to addresses Microsoft knows to be malicious: malware command servers, phishing sites, malware download domains.')
            Pros = @((T 'Шкідлива програма не зв''яжеться зі своїм сервером, навіть якщо вже запустилася' 'Malware cannot reach its server even if it is already running'), (T 'Захист від фішингу в усіх браузерах, а не лише в Edge' 'Phishing protection in every browser, not just Edge'))
            Cons = @((T 'Зрідка блокує легітимний сайт - тоді з''єднання просто не встановлюється, причину видно в журналі захисту' 'Occasionally blocks a legitimate site - the connection simply fails; the reason shows in Protection history'))
            Fix = @{ Recipe = 'network-protection' }
        }
        @{
            Id = 'controlled-folders'; Title = (T 'Захист папок від програм-вимагачів' 'Ransomware protection for folders')
            Test = {
                if (Get-ThirdPartyAv) { return NotApplicable (T 'Працює сторонній антивірус.' 'A third-party antivirus is active.') }
                switch ([int](Get-MpPreference -ErrorAction Stop).EnableControlledFolderAccess) {
                    1 { Ok (T 'увімкнено' 'on') }
                    2 { Ok (T 'режим аудиту' 'audit mode') (T 'Спроби змінити захищені папки записуються, але не блокуються.' 'Attempts to change protected folders are logged but not blocked.') }
                    default { Issue info (T 'вимкнено' 'off') (T 'Будь-яка програма може зашифрувати або стерти Документи, Зображення й Робочий стіл. З увімкненим захистом це можуть робити лише довірені програми.' 'Any program can encrypt or wipe Documents, Pictures and the Desktop. With protection on, only trusted programs can.') }
                }
            }
            Explain = (T '«Контрольований доступ до папок» дозволяє змінювати файли в Документах, Зображеннях, на Робочому столі лише програмам, яким Microsoft довіряє. Програма-вимагач не зможе їх зашифрувати.' '"Controlled folder access" lets only programs Microsoft trusts change files in Documents, Pictures and on the Desktop. Ransomware cannot encrypt them.')
            Pros = @((T 'Найнадійніший вбудований захист особистих файлів від шифрувальників' 'The most reliable built-in protection of personal files from ransomware'))
            Cons = @((T 'Ігри й маловідомі програми не зможуть зберігати файли в Документи, поки ви не дозволите кожну вручну - тому це лише рекомендація, без кнопки «Виправити»' 'Games and lesser-known programs cannot save into Documents until you allow each one by hand - hence this is only a recommendation, with no "Fix" button'), (T 'Резервна копія на окремому диску або в хмарі з історією версій захищає краще' 'A backup on a separate disk or in a cloud with version history protects better'))
            Fix = @{ Open = 'windowsdefender://ransomwareprotection'; Steps = @((T '«Безпека Windows» → «Захист від вірусів і загроз» → «Керування захистом від програм-шантажистів». Після ввімкнення дозволяйте заблоковані програми в «Дозволити програмі доступ через контрольований доступ до папок».' 'Windows Security → Virus & threat protection → Manage ransomware protection. After turning it on, allow blocked programs under "Allow an app through Controlled folder access".')) }
        }
        @{
            Id = 'defender-exclusions'; Title = (T 'Винятки антивіруса' 'Antivirus exclusions')
            Admin = $true
            Test = {
                if (Get-ThirdPartyAv) { return NotApplicable (T 'Працює сторонній антивірус.' 'A third-party antivirus is active.') }
                $p = Get-MpPreference -ErrorAction Stop
                $paths = @($p.ExclusionPath | Where-Object { $_ }); $procs = @($p.ExclusionProcess | Where-Object { $_ }); $exts = @($p.ExclusionExtension | Where-Object { $_ })
                if (-not ($paths + $procs + $exts)) { return Ok (T 'немає' 'none') }
                $bad = @(); $ev = @()
                $userDir = $env:USERPROFILE.ToLowerInvariant()
                foreach ($x in $paths) {
                    $l = [Environment]::ExpandEnvironmentVariables($x).TrimEnd('\').ToLowerInvariant()
                    $why = if ($l -match '^[a-z]:$') { T 'цілий диск' 'a whole drive' }
                           elseif ($l -in $userDir, (Split-Path $userDir), "$userDir\appdata", "$userDir\appdata\local", "$userDir\appdata\roaming", $env:ProgramData.ToLowerInvariant(), $env:windir.ToLowerInvariant()) { T 'надто широка папка' 'a far too broad folder' }
                           elseif ($l -match '\\(temp|tmp|downloads)$' -or $l -eq [IO.Path]::GetTempPath().TrimEnd('\').ToLowerInvariant()) { T 'сюди потрапляють файли з інтернету' 'files from the internet land here' }
                           else { $null }
                    if ($why) { $bad += $x; $ev += "⚠ " + (T 'Папка: ' 'Folder: ') + "$x  [$why]" } else { $ev += (T 'Папка: ' 'Folder: ') + $x }
                }
                foreach ($x in $exts) {
                    if ($x.TrimStart('.') -match '(?i)^(exe|dll|ps1|bat|cmd|js|vbs|scr|msi|com|hta|lnk|jar)$') { $bad += $x; $ev += "⚠ " + (T 'Розширення: ' 'Extension: ') + "$x  [" + (T 'виконувані файли не перевіряються взагалі' 'executable files are not scanned at all') + ']' }
                    else { $ev += (T 'Розширення: ' 'Extension: ') + $x }
                }
                foreach ($x in $procs) {
                    if ((Split-Path $x -Leaf) -match '(?i)^(powershell|pwsh|cmd|wscript|cscript|mshta|rundll32|regsvr32|python|node|java)(\.exe)?$') { $bad += $x; $ev += "⚠ " + (T 'Процес: ' 'Process: ') + "$x  [" + (T 'усе, що відкриває цей інтерпретатор, не перевіряється' 'everything this interpreter opens goes unscanned') + ']' }
                    else { $ev += (T 'Процес: ' 'Process: ') + $x }
                }
                $count = ($paths + $procs + $exts).Count
                if ($bad) { return Issue high (T "$count, небезпечних: $($bad.Count)" "$count, dangerous: $($bad.Count)") (T 'Позначені ⚠ винятки фактично вимикають антивірус там, де він найпотрібніший. Шкідливі програми з правами адміністратора додають себе у винятки першим ділом; «кряки» просять зробити це вручну.' 'Exclusions marked ⚠ effectively switch the antivirus off where it matters most. Malware with administrator rights adds itself to exclusions first thing; "cracks" ask you to do it by hand.') $ev }
                Issue info (T "$count шт." "$count") (T 'У цих місцях антивірус нічого не перевіряє. Переконайтеся, що кожен виняток додали ви самі й він досі потрібен.' 'The antivirus scans nothing in these places. Make sure you added each exclusion yourself and still need it.') $ev
            }
            Explain = (T 'Виняток - це місце, файл або процес, які Defender не перевіряє. Їх додають для швидкості (папки збірки, ігри) - і зловмисники, щоб сховати свої файли. Список видно лише з правами адміністратора.' 'An exclusion is a place, file or process Defender does not scan. People add them for speed (build folders, games) - and attackers add them to hide their files. The list is visible only with administrator rights.')
            Pros = @((T 'Немає сліпих зон, про які ви не знаєте' 'No blind spots you are unaware of'))
            Cons = @((T 'Без винятку для папки збірки компіляція великих проєктів трохи повільніша' 'Without an exclusion for the build folder, compiling large projects is slightly slower'))
            Fix = @{ Open = 'windowsdefender://exclusions'; Steps = @((T 'Видаліть винятки, яких не додавали, і надто широкі (цілий диск, Завантаження, Temp). Потім зробіть повне сканування: воно вперше перевірить ці місця.' 'Remove exclusions you did not add and overly broad ones (a whole drive, Downloads, Temp). Then run a full scan: it will check those places for the first time.')) }
        }
        @{
            Id = 'full-scan'; Title = (T 'Повне сканування антивірусом' 'Full antivirus scan')
            Test = {
                if (Get-ThirdPartyAv) { return NotApplicable (T 'Працює сторонній антивірус.' 'A third-party antivirus is active.') }
                $mp = Get-Mp
                $age = [long]$mp.FullScanAge
                if (-not $mp.FullScanEndTime -or $age -gt 100000) { return Issue low (T 'ніколи' 'never') (T 'Швидке сканування й захист у реальному часі перевіряють лише те, що запускається, і типові місця. Файли, які потрапили на диск, поки бази ще не знали загрозу, і лежать без руху, знайде тільки повне сканування.' 'Quick scans and real-time protection check only what runs and the usual places. Files that landed on disk before the definitions knew the threat, and have sat idle since, are found only by a full scan.') }
                if ($age -gt 90) { return Issue info (T "$age дн. тому" "$age days ago") (T 'Після підозрілого випадку (зламаний лаунчер, дивна поведінка ПК) запустіть повне сканування ще раз.' 'After a suspicious event (a compromised launcher, odd PC behavior) run a full scan again.') }
                Ok $(if ($age -le 0) { T 'сьогодні' 'today' } else { T "$age дн. тому" "$age days ago" })
            }
            Explain = (T 'Повне сканування перевіряє кожен файл на всіх дисках актуальними базами. Триває від години до кількох, ПК при цьому можна користуватися.' 'A full scan checks every file on all disks with current definitions. It takes one to several hours; the PC remains usable meanwhile.')
            Pros = @((T 'Знаходить «сплячі» шкідливі файли, які ще не запускалися' 'Finds dormant malicious files that have not run yet'))
            Cons = @((T 'Навантажує диск і процесор на годину або довше' 'Loads the disk and CPU for an hour or more'))
            Fix = @{ Open = 'windowsdefender://threat'; Steps = @((T '«Безпека Windows» → «Захист від вірусів і загроз» → «Параметри сканування» → «Повне сканування». Після підтвердженого зараження додайте «Автономну перевірку Microsoft Defender» - вона працює до завантаження Windows.' 'Windows Security → Virus & threat protection → Scan options → Full scan. After a confirmed infection add the "Microsoft Defender Offline scan" - it runs before Windows starts.')) }
        }
        @{
            Id = 'script-host'; Title = (T 'Запуск скриптів подвійним клацанням (Windows Script Host)' 'Running scripts by double-click (Windows Script Host)')
            Test = {
                foreach ($k in 'HKLM:\SOFTWARE\Microsoft\Windows Script Host\Settings', 'HKCU:\SOFTWARE\Microsoft\Windows Script Host\Settings') {
                    $v = Get-RegValue $k 'Enabled'
                    if ($null -ne $v -and "$v" -eq '0') { return Ok (T 'вимкнено' 'off') }
                }
                Issue low (T 'увімкнено' 'on') (T 'Файл .js, .vbs чи .wsf із листа або архіву запускається подвійним клацанням як програма - і виглядає при цьому як документ. Це один із найчастіших способів зараження через пошту й месенджери.' 'A .js, .vbs or .wsf file from an email or archive runs as a program on double-click - while looking like a document. This is one of the most common infection routes through mail and messengers.')
            }
            Explain = (T 'Windows Script Host - стара вбудована система, що виконує скрипти JScript і VBScript. Звичайному користувачеві вона майже не потрібна, а зловмисники надсилають «рахунок.js» чи «фото.vbs», що завантажує шкідливу програму.' 'Windows Script Host is an old built-in system that runs JScript and VBScript files. An ordinary user hardly ever needs it, while attackers send an "invoice.js" or "photo.vbs" that downloads malware.')
            Pros = @((T 'Скрипт із листа чи архіву просто не запуститься' 'A script from an email or archive simply will not run'))
            Cons = @((T 'Перестануть працювати .vbs/.js скрипти, зокрема вбудований slmgr.vbs (керування активацією Windows) і скрипти деяких старих інсталяторів - на час їх запуску рецепт можна відкотити' '.vbs/.js scripts stop working, including the built-in slmgr.vbs (Windows activation management) and scripts of some old installers - revert the recipe while you run them'))
            Fix = @{ Recipe = 'script-host-off' }
        }
    )
}
