# Хвости видалених програм. Більшість хвостів безпечні (кілобайти в реєстрі) - тут лише ті, що реально важать:
# небезпечні (посилання на файл, який може створити будь-яка програма), зламані (помилки, гальма) і великі (місце).
# Прибирання - лише через карантин модуля Setup (кнопка «Прибрати…»), з можливістю відновити.

# Драйвери з відомими вразливостями, якими користуються для атак на ядро (BYOVD); ім'я файлу без .sys
$script:VulnerableDrivers = @{
    'rtcore64' = (T 'MSI Afterburner (старі версії)' 'MSI Afterburner (old versions)'); 'rtcore32' = (T 'MSI Afterburner (старі версії)' 'MSI Afterburner (old versions)')
    'winring0x64' = (T 'WinRing0 (Open/LibreHardwareMonitor до 0.9.4, FanControl, утиліти розгону)' 'WinRing0 (Open/LibreHardwareMonitor before 0.9.4, FanControl, overclocking tools)'); 'winring0' = 'WinRing0'
    'gdrv' = (T 'Gigabyte App Center / утиліти Gigabyte' 'Gigabyte App Center / Gigabyte utilities'); 'asio' = 'ASUS AI Suite'; 'asio64' = 'ASUS AI Suite'; 'asio2' = 'ASUS'; 'asio3' = 'ASUS'
    'atillk64' = (T 'старі утиліти AMD/ATI' 'old AMD/ATI utilities'); 'dbutil_2_3' = 'Dell BIOS Utility'; 'iqvw64e' = 'Intel Network Adapter Diagnostic'
    'ene' = (T 'утиліти RGB-підсвітки (ENE)' 'RGB lighting utilities (ENE)'); 'mhyprot2' = (T 'анти-чит Genshin Impact (стара версія)' 'Genshin Impact anti-cheat (old version)'); 'mhyprot3' = (T 'анти-чит miHoYo' 'miHoYo anti-cheat')
    'cpuz141_x64' = 'CPU-Z 1.41'; 'physmem' = (T 'утиліти доступу до пам''яті' 'memory access utilities'); 'speedfan' = 'SpeedFan'; 'aswarpot' = (T 'Avast (стара версія)' 'Avast (old version)')
    'kprocesshacker' = 'Process Hacker 2'; 'zamguard64' = 'Zemana AntiMalware'; 'amifldrv64' = 'AMI BIOS flash utility'
}

# Шлях драйвера з Win32_SystemDriver: \??\C:\..., \SystemRoot\..., System32\drivers\...
function Resolve-DriverPath([string]$p) {
    if (-not $p) { return $null }
    $p = $p.Trim().Trim('"')
    if ($p.StartsWith('\??\')) { $p = $p.Substring(4) }
    if ($p -match '^\\SystemRoot\\(.*)$') { $p = Join-Path $env:windir $Matches[1] }
    elseif ($p -match '^(system32|syswow64)\\') { $p = Join-Path $env:windir $p }
    $p
}

function Get-RulesWord([int]$n) {
    if ($UiLang -eq 'en') { if ($n -eq 1) { return 'rule' } else { return 'rules' } }
    $m10 = $n % 10; $m100 = $n % 100
    if ($m10 -eq 1 -and $m100 -ne 11) { 'правило' } elseif ($m10 -ge 2 -and $m10 -le 4 -and ($m100 -lt 10 -or $m100 -ge 20)) { 'правила' } else { 'правил' }
}

function Test-UnderWindows([string]$p) { $p -and $p.ToLowerInvariant().StartsWith($env:windir.ToLowerInvariant() + '\') }

# Для «залишків папок»: ключ імені без пробілів і розділових знаків
function Get-NameKey([string]$s) { if ($s) { ($s.ToLowerInvariant() -replace '[^\p{L}\p{Nd}]', '') } else { '' } }

$script:SkipFolders = '^(microsoft.*|windows.*|common files|internet explorer|modifiablewindowsapps|windowsapps|package cache|packages|temp|tmp|nvidia.*|amd|ati|intel|realtek|reference assemblies|msbuild|dotnet|powershell|windowspowershell|uninstall information|regid\..*|usoshared|usoprivate|softwaredistribution|comms|connecteddevicesplatform|crashdumps|crashreportclient|d3dscache|programs|peerdistrepub|desktop|ssh|application data|history|temporary internet files|deadpixel|claude.*|anthropic.*|cache|caches|fonts|virtualstore|publishers|identities|start menu|templates|\..*)$'

@{
    Id = 'leftovers'; Title = (T 'Хвости програм' 'Program leftovers'); Order = 8
    Checks = @(
        @{
            Id = 'orphan-services'; Title = (T 'Служби видалених програм' 'Services of removed programs')
            Test = {
                $ev = @(); $items = @(); $danger = $false
                foreach ($s in Get-CimInstance Win32_Service -ErrorAction Stop) {
                    $exe = Get-ExeFromCommand $s.PathName
                    if (-not $exe -or -not [IO.Path]::IsPathRooted($exe) -or (Test-UnderWindows $exe) -or (Test-Path -LiteralPath $exe)) { continue }
                    $create = Test-CreatableByUsers $exe
                    if ($create) { $danger = $true }
                    $ev += $(if ($create) { "⚠ $($s.DisplayName) ($($s.Name)) - $exe  [" + (T "файлу немає, а створити його може будь-яка програма: він запуститься від імені $($s.StartName)" "the file is missing and any program can create it: it would run as $($s.StartName)") + ']' } else { "$($s.DisplayName) ($($s.Name)) - $exe" })
                    $items += New-CleanupItem 'Service' (T "Служба «$($s.DisplayName)» ($($s.Name))" "Service '$($s.DisplayName)' ($($s.Name))") @{ Name = $s.Name }
                }
                foreach ($d in Get-CimInstance Win32_SystemDriver -ErrorAction SilentlyContinue) {
                    $sys = Resolve-DriverPath $d.PathName
                    if (-not $sys -or -not [IO.Path]::IsPathRooted($sys) -or (Test-UnderWindows $sys) -or (Test-Path -LiteralPath $sys)) { continue }
                    $ev += (T 'Драйвер ' 'Driver ') + "$($d.DisplayName) ($($d.Name)) - $sys"
                    $items += New-CleanupItem 'Service' (T "Драйвер «$($d.DisplayName)» ($($d.Name))" "Driver '$($d.DisplayName)' ($($d.Name))") @{ Name = $d.Name }
                }
                if (-not $items) { return Ok (T 'немає' 'none') }
                $r = if ($danger) { Issue high (T "$($items.Count) шт." "$($items.Count)") (T 'Службу видаленої програми Windows досі пробує запускати. Якщо її файлу немає, а папка відкрита на запис, будь-яка програма може покласти туди свій файл - і він запуститься з правами системи.' 'Windows still tries to start a service of a removed program. If its file is missing and the folder is writable, any program can put its own file there - and it will run with system rights.') $ev }
                     else { Issue low (T "$($items.Count) шт." "$($items.Count)") (T 'Windows під час старту пробує запустити службу, якої вже немає: зайвий запис у журналі помилок і секунда до завантаження.' 'At startup Windows tries to start a service that no longer exists: an extra error log entry and a second added to boot.') $ev }
                Add-Cleanup $r $items
            }
            Explain = (T 'Деінсталятори не завжди видаляють свої служби. Запис служби лишається і посилається на неіснуючий файл. Зазвичай це просто сміття, але якщо папку, де мав бути файл, може створити звичайна програма - це спосіб отримати права SYSTEM.' 'Uninstallers do not always remove their services. The service entry stays and points to a missing file. Usually it is just clutter, but if an ordinary program can create the folder where the file should be, it is a way to get SYSTEM rights.')
            Pros = @((T 'Закриває спосіб підвищити права через «порожню» службу' 'Closes a privilege escalation path through an "empty" service'), (T 'Менше помилок під час старту' 'Fewer errors at startup'))
            Cons = @((T 'Якщо програму ще будете перевстановлювати - вона створить службу знову, тож нічого не втратите' 'If you reinstall the program it creates the service again, so nothing is lost'))
            Fix = @{ Steps = @((T '«Прибрати…» перенесе записи служб у карантин (з резервною копією в .reg); відновити можна в «Карантин…». Видалення служби діє одразу, повернення - після перезавантаження.' '"Clean up…" moves the service entries to quarantine (with a .reg backup); restore them in "Quarantine…". Removal takes effect at once, restoring after a restart.')) }
        }
        @{
            Id = 'orphan-tasks'; Title = (T 'Завдання Планувальника на неіснуючі файли' 'Scheduled tasks pointing to missing files')
            Test = {
                $ev = @(); $items = @(); $worst = 'low'
                foreach ($t in Get-ScheduledTask -ErrorAction Stop | Where-Object { $_.TaskPath -notlike '\Microsoft\*' }) {
                    foreach ($a in @($t.Actions | Where-Object { $_.Execute })) {
                        $exe = Get-ExeFromCommand $a.Execute
                        if (-not $exe -or -not [IO.Path]::IsPathRooted($exe) -or (Test-Path -LiteralPath $exe)) { continue }
                        $priv = $t.Principal.UserId -in 'SYSTEM', 'S-1-5-18' -or $t.Principal.RunLevel -eq 'Highest'
                        $create = Test-CreatableByUsers $exe
                        if ($priv -and $create) { $worst = 'high' } elseif ($create -and $worst -eq 'low') { $worst = 'medium' }
                        $name = "$($t.TaskPath.TrimEnd('\'))\$($t.TaskName)"
                        $ev += $(if ($create) { "⚠ $name - $exe  [" + (T 'файл може створити будь-яка програма' 'any program can create the file') + $(if ($priv) { T '; завдання з правами адміністратора' '; the task runs elevated' }) + ']' } else { "$name - $exe" })
                        $items += New-CleanupItem 'Task' ((T 'Завдання ' 'Task ') + $name) @{ Key = $t.TaskPath; Name = $t.TaskName }
                        break
                    }
                }
                if (-not $items) { return Ok (T 'немає' 'none') }
                $detail = if ($worst -ne 'low') { T 'Завдання запускає файл, якого немає, з місця, куди може писати будь-яка програма: підклавши туди свій файл, вона запуститься за розкладом.' 'The task runs a missing file from a place any program can write to: a program that drops its own file there gets run on schedule.' } else { T 'Завдання від видалених програм: щоразу закінчуються помилкою.' 'Tasks of removed programs: they fail every time.' }
                Add-Cleanup (Issue $worst (T "$($items.Count) шт." "$($items.Count)") $detail $ev) $items
            }
            Explain = (T 'Програми створюють завдання Планувальника для оновлень і запуску, а деінсталятори часто їх забувають. Завдання на неіснуючий файл - сміття, а якщо папку можна створити - діра.' 'Programs create scheduled tasks for updates and launching, and uninstallers often forget them. A task pointing to a missing file is clutter, and if the folder can be created, a hole.')
            Pros = @((T 'Немає завдань, які можна «підхопити» підкладеним файлом' 'No tasks that can be hijacked with a planted file'))
            Cons = @()
            Fix = @{ Open = 'taskschd.msc'; Steps = @((T '«Прибрати…» збереже завдання в XML і видалить його; відновлюється з «Карантин…».' '"Clean up…" saves the task as XML and deletes it; restore it from "Quarantine…".')) }
        }
        @{
            Id = 'vulnerable-drivers'; Title = (T 'Відомі вразливі драйвери' 'Known vulnerable drivers')
            Test = {
                $ev = @(); $running = $false
                foreach ($d in Get-CimInstance Win32_SystemDriver -ErrorAction Stop) {
                    $sys = Resolve-DriverPath $d.PathName
                    $base = if ($sys) { [IO.Path]::GetFileNameWithoutExtension($sys).ToLowerInvariant() } else { '' }
                    if (-not $VulnerableDrivers.ContainsKey($base)) { continue }
                    $exists = $sys -and (Test-Path -LiteralPath $sys)
                    if ($d.State -eq 'Running') { $running = $true }
                    $ev += "⚠ $($d.Name) - $sys ($($VulnerableDrivers[$base])), " + (T "зараз: $($d.State), запуск: $($d.StartMode)" "now: $($d.State), start: $($d.StartMode)") + $(if (-not $exists) { T ', файлу вже немає' ', the file is gone' })
                }
                if (-not $ev) { return Ok (T 'не знайдено' 'none found') }
                Issue $(if ($running) { 'high' } else { 'medium' }) (T "$($ev.Count) шт." "$($ev.Count)") (T 'Ці драйвери легітимні, але мають відому вразливість: будь-яка програма з правами адміністратора отримує через них доступ до ядра (так вимикають антивіруси). Часто лишаються після утиліт розгону, моніторингу й RGB.' 'These drivers are legitimate but have a known vulnerability: any program with administrator rights gets kernel access through them (that is how antiviruses get disabled). They often remain after overclocking, monitoring and RGB utilities.') $ev
            }
            Explain = (T 'Атака «принеси свій вразливий драйвер» (BYOVD): зловмисник використовує старий підписаний драйвер з дірою, щоб виконати код у ядрі. Блок-лист Microsoft блокує частину з них, але не всі й не завжди.' 'A "bring your own vulnerable driver" (BYOVD) attack: the attacker uses an old signed driver with a hole to run code in the kernel. Microsoft''s blocklist stops some of them, but not all and not always.')
            Pros = @((T 'Закриває шлях у ядро в обхід антивіруса' 'Closes a path into the kernel that bypasses the antivirus'))
            Cons = @((T 'Програма, якій належить драйвер (утиліта моніторингу, підсвітки, розгону), перестане працювати - оновіть її: нові версії переходять на безпечні драйвери (LibreHardwareMonitor 0.9.4+ - на PawnIO)' 'The program that owns the driver (monitoring, lighting or overclocking utility) stops working - update it: new versions move to safe drivers (LibreHardwareMonitor 0.9.4+ uses PawnIO)'))
            Fix = @{ Open = 'ms-settings:appsfeatures'; Steps = @((T 'Оновіть або видаліть програму, якій належить драйвер (назва - у доказах).' 'Update or uninstall the program that owns the driver (its name is in the evidence).'), (T 'Якщо програми вже немає: sc.exe delete <ім''я драйвера> у командному рядку від адміністратора, потім перезавантаження.' 'If the program is already gone: sc.exe delete <driver name> in an administrator command prompt, then restart.')) }
        }
        @{
            Id = 'path-entries'; Title = (T 'Неіснуючі папки в PATH' 'Missing folders in PATH')
            Test = {
                $ev = @(); $items = @(); $worst = 'low'
                $sources = @(
                    @{ Scope = 'Machine'; Key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SYSTEM\CurrentControlSet\Control\Session Manager\Environment') }
                    @{ Scope = 'User'; Key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment') }
                )
                foreach ($s in $sources) {
                    if (-not $s.Key) { continue }
                    $raw = [string]$s.Key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                    $s.Key.Close()
                    foreach ($entry in $raw -split ';' | Where-Object { $_.Trim() }) {
                        $dir = [Environment]::ExpandEnvironmentVariables($entry.Trim().Trim('"'))
                        if (-not [IO.Path]::IsPathRooted($dir) -or (Test-Path -LiteralPath $dir)) { continue }
                        $create = Test-CreatableByUsers (Join-Path $dir 'x')
                        if ($s.Scope -eq 'Machine' -and $create) { $worst = 'high' }
                        $scope = if ($s.Scope -eq 'Machine') { T 'системний' 'system' } else { T 'користувача' 'user' }
                        $ev += $(if ($s.Scope -eq 'Machine' -and $create) { "⚠ $entry ($scope PATH)  [" + (T 'папку може створити будь-яка програма, а системні служби шукають у ній DLL і програми' 'any program can create the folder, and system services look for DLLs and programs in it') + ']' } else { "$entry ($scope PATH)" })
                        $items += New-CleanupItem 'PathEntry' "PATH ($scope): $entry" @{ Scope = $s.Scope; Target = $entry }
                    }
                }
                if (-not $items) { return Ok (T 'немає' 'none') }
                $detail = if ($worst -eq 'high') { T 'У системному PATH є папка, якої немає, але яку може створити будь-яка програма: поклавши туди DLL чи exe зі «знайомим» ім''ям, вона змусить системні процеси запустити свій код.' 'The system PATH contains a missing folder that any program can create: by dropping a DLL or exe with a "familiar" name there, it makes system processes run its code.' } else { T 'Записи від видалених програм: самі по собі не шкодять, лише сповільнюють пошук програм у командному рядку.' 'Entries of removed programs: harmless by themselves, they only slow down program lookup in the command line.' }
                Add-Cleanup (Issue $worst (T "$($items.Count) шт." "$($items.Count)") $detail $ev) $items
            }
            Explain = (T 'PATH - список папок, де Windows шукає програми й бібліотеки за коротким ім''ям. Інсталятори додають туди свої папки, а деінсталятори часто їх забувають.' 'PATH is the list of folders where Windows looks for programs and libraries by short name. Installers add their folders there, and uninstallers often forget them.')
            Pros = @((T 'Закриває підміну програм і DLL через «порожню» папку в PATH' 'Closes program and DLL hijacking through an "empty" PATH folder'))
            Cons = @((T 'Якщо програму перевстановите, вона сама додасть свою папку знову' 'If you reinstall the program, it adds its folder again by itself'))
            Fix = @{ Open = 'rundll32.exe sysdm.cpl,EditEnvironmentVariables' }
        }
        @{
            Id = 'firewall-orphans'; Title = (T 'Дозволи брандмауера для видалених програм' 'Firewall permissions for removed programs')
            Test = {
                $pol = New-Object -ComObject HNetCfg.FwPolicy2
                $apps = @{}
                foreach ($r in $pol.Rules) {
                    if (-not $r.ApplicationName -or $r.Action -ne 1) { continue }
                    if (-not $apps.ContainsKey($r.ApplicationName)) { $apps[$r.ApplicationName] = 0 }
                    $apps[$r.ApplicationName]++
                }
                $ev = @(); $items = @()
                foreach ($raw in $apps.Keys | Sort-Object) {
                    $path = [Environment]::ExpandEnvironmentVariables($raw)
                    if (-not [IO.Path]::IsPathRooted($path) -or (Test-UnderWindows $path) -or (Test-Path -LiteralPath $path)) { continue }
                    $n = $apps[$raw]
                    $ev += "$path - $n $(Get-RulesWord $n)"
                    $items += New-CleanupItem 'FirewallRule' ((T 'Брандмауер: ' 'Firewall: ') + "$path ($n $(Get-RulesWord $n))") @{ Target = $raw }
                }
                if (-not $items) { return Ok (T 'немає' 'none') }
                # Низький рівень: файл за цим шляхом отримав би лише дозвіл на вхідні з'єднання, а не права
                Add-Cleanup (Issue low (T "$($items.Count) прогр." "$($items.Count) programs") (T 'Брандмауер досі дозволяє з''єднання програмам, яких уже немає (часто - старим версіям програм, що оновлюються в нову папку). Файл, покладений за тим самим шляхом, отримав би цей дозвіл без запиту.' 'The firewall still allows connections for programs that no longer exist (often old versions of programs that update into a new folder). A file placed at the same path would get this permission without asking.') $ev) $items
            }
            Explain = (T 'Під час першого запуску мережевої програми Windows створює для неї дозвіл у брандмауері. Після видалення програми дозвіл лишається.' 'When a network program first runs, Windows creates a firewall permission for it. After the program is removed, the permission stays.')
            Pros = @((T 'Менше «відчинених дверей» у брандмауері' 'Fewer open doors in the firewall'))
            Cons = @((T 'Якщо програму встановите знову, Windows ще раз спитає дозвіл' 'If you install the program again, Windows asks for permission again'))
            Fix = @{ Open = 'wf.msc' }
        }
        @{
            Id = 'broken-autoruns'; Title = (T 'Автозапуск неіснуючих програм' 'Startup entries for missing programs')
            Test = {
                $ev = @(); $items = @()
                $hosts = '^(rundll32|cmd|powershell|pwsh|wscript|cscript|msiexec|explorer|conhost|mshta)$'
                foreach ($k in 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce',
                               'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run', 'HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce',
                               'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run') {
                    $p = Get-ItemProperty $k -ErrorAction SilentlyContinue
                    if (-not $p) { continue }
                    foreach ($x in $p.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' -and $_.Value -is [string] }) {
                        $exe = Get-ExeFromCommand $x.Value
                        if (-not $exe -or -not [IO.Path]::IsPathRooted($exe) -or [IO.Path]::GetFileNameWithoutExtension($exe) -match $hosts -or (Test-Path -LiteralPath $exe)) { continue }
                        $ev += "$($x.Name) - $exe"
                        $items += New-CleanupItem 'RegistryValue' (T "Автозапуск «$($x.Name)»" "Startup entry '$($x.Name)'") @{ Key = $k; Name = $x.Name }
                    }
                }
                $shell = New-Object -ComObject WScript.Shell
                foreach ($dir in [Environment]::GetFolderPath('Startup'), [Environment]::GetFolderPath('CommonStartup')) {
                    foreach ($f in Get-ChildItem $dir -Filter *.lnk -File -ErrorAction SilentlyContinue) {
                        $target = $shell.CreateShortcut($f.FullName).TargetPath
                        if (-not $target -or -not [IO.Path]::IsPathRooted($target) -or (Test-Path -LiteralPath $target)) { continue }
                        $ev += $f.Name + (T ' (папка «Автозавантаження») - ' ' (Startup folder) - ') + $target
                        $items += New-CleanupItem 'Path' (T "Ярлик автозавантаження «$($f.Name)»" "Startup shortcut '$($f.Name)'") @{ Target = $f.FullName }
                    }
                }
                if (-not $items) { return Ok (T 'немає' 'none') }
                Add-Cleanup (Issue low (T "$($items.Count) шт." "$($items.Count)") (T 'Під час входу Windows пробує запустити програми, яких уже немає.' 'At sign-in Windows tries to start programs that no longer exist.') $ev) $items
            }
            Explain = (T 'Записи автозапуску від видалених програм. Самі по собі не шкодять, але засмічують список автозавантаження й журнал помилок.' 'Startup entries of removed programs. Harmless by themselves, but they clutter the startup list and the error log.')
            Pros = @((T 'Чистий список автозавантаження' 'A clean startup list'))
            Cons = @()
            Fix = @{ Open = 'ms-settings:startupapps' }
        }
        @{
            Id = 'shell-extensions'; Title = (T 'Зламані пункти контекстного меню' 'Broken context menu entries')
            Test = {
                $ev = @(); $items = @()
                foreach ($b in '*', 'Directory', 'Directory\Background', 'Folder', 'Drive', 'AllFilesystemObjects') {
                    foreach ($h in Get-ChildItem -LiteralPath "Registry::HKEY_CLASSES_ROOT\$b\shellex\ContextMenuHandlers" -ErrorAction SilentlyContinue) {
                        $def = (Get-ItemProperty -LiteralPath $h.PSPath -ErrorAction SilentlyContinue).'(default)'
                        $clsid = if ($def -match '^\{[0-9a-fA-F-]{36}\}$') { $def } elseif ($h.PSChildName -match '^\{[0-9a-fA-F-]{36}\}$') { $h.PSChildName } else { $null }
                        if (-not $clsid) { continue }
                        $srv = (Get-ItemProperty -LiteralPath "Registry::HKEY_CLASSES_ROOT\CLSID\$clsid\InprocServer32" -ErrorAction SilentlyContinue).'(default)'
                        $why = $null
                        if (-not $srv) { $why = T 'компонент не зареєстрований' 'the component is not registered' }
                        else {
                            $dll = [Environment]::ExpandEnvironmentVariables($srv.Trim('"'))
                            if (-not [IO.Path]::IsPathRooted($dll)) { $dll = Join-Path "$env:windir\System32" $dll }
                            if (-not (Test-Path -LiteralPath $dll)) { $why = (T 'немає файлу ' 'missing file ') + $dll }
                        }
                        if (-not $why) { continue }
                        $rel = "SOFTWARE\Classes\$b\shellex\ContextMenuHandlers\$($h.PSChildName)"
                        $target = if (Test-Path -LiteralPath "HKLM:\$rel") { "HKLM:\$rel" } else { "HKCU:\$($rel -replace '^SOFTWARE', 'Software')" }
                        $ev += "$($h.PSChildName) ($b) - $why"
                        $items += New-CleanupItem 'RegistryKey' ((T 'Контекстне меню: ' 'Context menu: ') + "$($h.PSChildName) ($b)") @{ Target = $target }
                    }
                }
                if (-not $items) { return Ok (T 'немає' 'none') }
                Add-Cleanup (Issue low (T "$($items.Count) шт." "$($items.Count)") (T 'Провідник під час правого кліку пробує завантажити розширення, якого вже немає: меню відкривається повільніше, інколи Провідник зависає.' 'On right-click Explorer tries to load an extension that no longer exists: the menu opens slower, and Explorer sometimes hangs.') $ev) $items
            }
            Explain = (T 'Програми додають пункти в контекстне меню Провідника (архіватори, хмари, антивіруси). Після видалення програми запис може лишитися з посиланням на неіснуючу DLL.' 'Programs add entries to the Explorer context menu (archivers, cloud sync, antiviruses). After the program is removed, the entry may remain, pointing to a missing DLL.')
            Pros = @((T 'Швидше контекстне меню, менше зависань Провідника' 'A faster context menu and fewer Explorer hangs'))
            Cons = @()
            Fix = @{ Steps = @((T '«Прибрати…» експортує ключ у .reg і видалить його; відновлюється з «Карантин…».' '"Clean up…" exports the key to .reg and deletes it; restore it from "Quarantine…".')) }
        }
        @{
            Id = 'broken-uninstall'; Title = (T 'Записи «Програм», які не видаляються' 'Installed-program entries that cannot be uninstalled')
            Test = {
                $ev = @(); $items = @()
                foreach ($a in Get-InstalledApps) {
                    if (-not $a.UninstallString -or $a.UninstallString -match '(?i)msiexec') { continue }
                    $exe = Get-ExeFromCommand $a.UninstallString
                    if (-not $exe -or -not [IO.Path]::IsPathRooted($exe) -or (Test-Path -LiteralPath $exe)) { continue }
                    if ($a.InstallLocation -and (Test-Path -LiteralPath $a.InstallLocation.Trim('"'))) { continue }   # програма на місці - не чіпаємо
                    $ev += "$($a.DisplayName) - " + (T 'деінсталятора немає: ' 'uninstaller missing: ') + $exe
                    $items += New-CleanupItem 'RegistryKey' (T "Запис «$($a.DisplayName)»" "Entry '$($a.DisplayName)'") @{ Target = ConvertTo-RegDrivePath $a.PSPath }
                }
                if (-not $items) { return Ok (T 'немає' 'none') }
                Add-Cleanup (Issue low (T "$($items.Count) шт." "$($items.Count)") (T 'У «Програмах і компонентах» є програми, яких уже немає на диску: кнопка «Видалити» для них не працює.' 'Programs and Features lists programs that are no longer on disk: the Uninstall button does not work for them.') $ev) $items
            }
            Explain = (T 'Якщо папку програми видалили вручну, її запис у «Програмах і компонентах» лишається назавжди - деінсталятора, який би його прибрав, уже немає.' 'If a program folder was deleted by hand, its entry in Programs and Features stays forever - the uninstaller that would remove it is gone.')
            Pros = @((T 'Чистий список програм; оновлювачі не пропонують «оновити» те, чого немає' 'A clean program list; updaters stop offering to "update" what is not there'))
            Cons = @()
            Fix = @{ Open = 'ms-settings:appsfeatures' }
        }
        @{
            Id = 'leftover-folders'; Title = (T 'Папки, що не належать жодній програмі' 'Folders that belong to no program')
            Test = {
                $sw = [Diagnostics.Stopwatch]::StartNew()
                $apps = @(Get-InstalledApps | ForEach-Object {
                    [pscustomobject]@{
                        Keys = @((Get-NameKey $_.DisplayName), (Get-NameKey $_.Publisher), (Get-NameKey (($_.DisplayName -split '\s+')[0]))) | Where-Object { $_.Length -ge 4 }
                        Loc = $(if ($_.InstallLocation) { $_.InstallLocation.Trim('"').TrimEnd('\').ToLowerInvariant() })
                    }
                })
                $busy = @(@((Get-ProcessTable).Values | ForEach-Object { Get-CleanPath $_.ExecutablePath }) +
                          @(Get-CimInstance Win32_Service | ForEach-Object { Get-ExeFromCommand $_.PathName }) | Where-Object { $_ } | ForEach-Object { $_.ToLowerInvariant() })
                $roots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData, $env:LOCALAPPDATA, (Join-Path $env:LOCALAPPDATA 'Programs'), $env:APPDATA) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique
                $found = @(); $cutoff = (Get-Date).AddDays(-60)
                foreach ($root in $roots) {
                    foreach ($d in Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue) {
                        if ($d.Name -match $SkipFolders -or ($d.Attributes -band [IO.FileAttributes]::ReparsePoint)) { continue }
                        $key = Get-NameKey $d.Name
                        if ($key.Length -lt 3) { continue }
                        $path = $d.FullName.ToLowerInvariant()
                        $owned = $false
                        foreach ($a in $apps) {
                            if ($a.Loc -and ($a.Loc.StartsWith($path) -or $path.StartsWith($a.Loc))) { $owned = $true; break }
                            foreach ($k in $a.Keys) { if ($k.Contains($key) -or ($key.Length -ge 4 -and $key.Contains($k))) { $owned = $true; break } }
                            if ($owned) { break }
                        }
                        if ($owned) { continue }
                        if ($busy | Where-Object { $_.StartsWith($path + '\') }) { continue }   # з цієї папки щось працює
                        # Свіжі зміни - програма, найпевніше, живе (портативна або без запису в «Програмах»)
                        $last = $d.LastWriteTime
                        foreach ($c in Get-ChildItem -LiteralPath $d.FullName -Force -ErrorAction SilentlyContinue) { if ($c.LastWriteTime -gt $last) { $last = $c.LastWriteTime } }
                        if ($last -gt $cutoff) { continue }
                        $found += [pscustomobject]@{ Path = $d.FullName; Last = $last; Size = 0L }
                    }
                }
                # Розмір - найдовша частина: рахуємо, доки є час, від найстаріших (вони найімовірніше покинуті)
                foreach ($f in $found | Sort-Object Last) { if ($sw.Elapsed.TotalSeconds -gt 15) { break }; $f.Size = Get-DirSize $f.Path }
                $big = @($found | Where-Object { $_.Size -ge 10MB } | Sort-Object Size -Descending)
                if (-not $big) { return Ok (T 'не знайдено' 'none found') (T 'Перевірено папок програм; можливих залишків більше 10 МБ немає.' 'Program folders checked; no possible leftovers over 10 MB.') }
                $total = ($big | Measure-Object Size -Sum).Sum
                $ev = @($big | Select-Object -First 40 | ForEach-Object { "$(Format-Size $_.Size) - $($_.Path) (" + (T 'остання зміна ' 'last changed ') + "$($_.Last.ToString('MM.yyyy')))" })
                $items = @($big | Select-Object -First 40 | ForEach-Object { New-CleanupItem 'Path' "$(Format-Size $_.Size) - $($_.Path)" @{ Target = $_.Path } $false $_.Size })
                Add-Cleanup (Issue info (T "$($big.Count) шт., $(Format-Size $total)" "$($big.Count), $(Format-Size $total)") (T 'Папки, які не належать жодній встановленій програмі і давно не змінювалися: залишки видалених програм, кеші інструментів розробника (pip, npm), дані ігор. Це припущення - перевірте кожну, перш ніж прибирати.' 'Folders that belong to no installed program and have not changed for a long time: leftovers of removed programs, developer tool caches (pip, npm), game data. This is a guess - check each one before cleaning up.') $ev) $items
            }
            Explain = (T 'Деінсталятори часто лишають налаштування, кеші й журнали в Program Files, ProgramData і AppData. Аудит шукає папки, які не належать жодній встановленій програмі, ні один процес чи служба з них не працює і які не змінювалися щонайменше 2 місяці.' 'Uninstallers often leave settings, caches and logs in Program Files, ProgramData and AppData. The audit looks for folders that belong to no installed program, that no process or service runs from, and that have not changed for at least 2 months.')
            Pros = @((T 'Звільняє місце' 'Frees up space'))
            Cons = @(
                (T 'УВАГА: у AppData часто лежать ЗБЕРЕЖЕННЯ ІГОР (папки з назвою гри, як-от EldenRing) - їх не прибирайте, якщо плануєте грати' 'WARNING: AppData often holds GAME SAVES (folders named after the game, such as EldenRing) - do not clean them up if you plan to play'),
                (T 'Це лише припущення: папка може належати портативній програмі - тому в списку нічого не позначено заздалегідь' 'This is only a guess: a folder may belong to a portable program - that is why nothing in the list is pre-selected'),
                (T 'Карантин переносить папки в data\quarantine: місце звільниться лише після остаточного видалення через 30 днів' 'Quarantine moves folders to data\quarantine: the space is freed only after final deletion 30 days later')
            )
            Fix = @{ Steps = @(
                (T 'Позначте в «Прибрати…» лише ті папки, які точно впізнаєте як залишки.' 'In "Clean up…" select only the folders you clearly recognize as leftovers.'),
                (T 'Кеші інструментів краще чистити їхніми командами: pip cache purge, npm cache clean --force, pnpm store prune.' 'Tool caches are better cleaned with their own commands: pip cache purge, npm cache clean --force, pnpm store prune.')
            ) }
        }
        @{
            Id = 'old-driver-packages'; Title = (T 'Старі версії драйверів у сховищі' 'Old driver versions in the driver store')
            Test = {
                $repo = Join-Path $env:windir 'System32\DriverStore\FileRepository'
                $groups = Get-ChildItem -LiteralPath $repo -Directory -ErrorAction Stop | Group-Object { $_.Name -replace '_(amd64|x86|arm64|ia64)_[0-9a-f]+$', '' } | Where-Object Count -gt 1
                $sw = [Diagnostics.Stopwatch]::StartNew()
                $rows = @(); $extra = 0L
                foreach ($g in $groups) {
                    if ($sw.Elapsed.TotalSeconds -gt 10) { break }
                    $sizes = @($g.Group | Sort-Object LastWriteTime -Descending | ForEach-Object { Get-DirSize $_.FullName 20000 })
                    $old = ($sizes | Select-Object -Skip 1 | Measure-Object -Sum).Sum
                    if ($old -ge 100MB) { $rows += [pscustomobject]@{ Name = $g.Name; Count = $g.Count; Old = [long]$old }; $extra += $old }
                }
                if (-not $rows) { return Ok (T 'немає зайвих' 'nothing extra') }
                Issue info "~$(Format-Size $extra)" (T 'Windows зберігає попередні версії драйверів (щоб можна було відкотити). Найбільше місця займають старі драйвери відеокарти.' 'Windows keeps previous driver versions (so you can roll back). Old graphics drivers take the most space.') @($rows | Sort-Object Old -Descending | ForEach-Object { "$($_.Name) - " + (T "версій: $($_.Count), старі займають ~$(Format-Size $_.Old)" "versions: $($_.Count), old ones take ~$(Format-Size $_.Old)") })
            }
            Explain = (T 'Сховище драйверів (DriverStore) тримає кожну встановлену версію драйвера. Після кількох оновлень драйвера відеокарти це гігабайти.' 'The driver store (DriverStore) keeps every installed driver version. After a few graphics driver updates that is gigabytes.')
            Pros = @((T 'Звільняє місце на системному диску' 'Frees up space on the system drive'))
            Cons = @((T 'Після очищення не вийде відкотити драйвер до старішої версії кнопкою «Відкотити» в Диспетчері пристроїв' 'After cleanup you cannot roll a driver back to an older version with Roll Back Driver in Device Manager'))
            Fix = @{ Open = 'cleanmgr.exe'; Steps = @((T '«Очищення диска» → «Очистити системні файли» → позначте «Пакети драйверів пристроїв» (видаляє лише невикористовувані версії).' 'Disk Cleanup → Clean up system files → tick "Device driver packages" (removes only unused versions).')) }
        }
    )
}
