# Хвости видалених програм. Більшість хвостів безпечні (кілобайти в реєстрі) - тут лише ті, що реально важать:
# небезпечні (посилання на файл, який може створити будь-яка програма), зламані (помилки, гальма) і великі (місце).
# Прибирання - лише через карантин модуля Setup (кнопка «Прибрати…»), з можливістю відновити.

# Драйвери з відомими вразливостями, якими користуються для атак на ядро (BYOVD); ім'я файлу без .sys
$script:VulnerableDrivers = @{
    'rtcore64' = 'MSI Afterburner (старі версії)'; 'rtcore32' = 'MSI Afterburner (старі версії)'
    'winring0x64' = 'WinRing0 (Open/LibreHardwareMonitor до 0.9.4, FanControl, утиліти розгону)'; 'winring0' = 'WinRing0'
    'gdrv' = 'Gigabyte App Center / утиліти Gigabyte'; 'asio' = 'ASUS AI Suite'; 'asio64' = 'ASUS AI Suite'; 'asio2' = 'ASUS'; 'asio3' = 'ASUS'
    'atillk64' = 'старі утиліти AMD/ATI'; 'dbutil_2_3' = 'Dell BIOS Utility'; 'iqvw64e' = 'Intel Network Adapter Diagnostic'
    'ene' = 'утиліти RGB-підсвітки (ENE)'; 'mhyprot2' = 'анти-чит Genshin Impact (стара версія)'; 'mhyprot3' = 'анти-чит miHoYo'
    'cpuz141_x64' = 'CPU-Z 1.41'; 'physmem' = 'утиліти доступу до пам''яті'; 'speedfan' = 'SpeedFan'; 'aswarpot' = 'Avast (стара версія)'
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
    $m10 = $n % 10; $m100 = $n % 100
    if ($m10 -eq 1 -and $m100 -ne 11) { 'правило' } elseif ($m10 -ge 2 -and $m10 -le 4 -and ($m100 -lt 10 -or $m100 -ge 20)) { 'правила' } else { 'правил' }
}

function Test-UnderWindows([string]$p) { $p -and $p.ToLowerInvariant().StartsWith($env:windir.ToLowerInvariant() + '\') }

# Для «залишків папок»: ключ імені без пробілів і розділових знаків
function Get-NameKey([string]$s) { if ($s) { ($s.ToLowerInvariant() -replace '[^\p{L}\p{Nd}]', '') } else { '' } }

$script:SkipFolders = '^(microsoft.*|windows.*|common files|internet explorer|modifiablewindowsapps|windowsapps|package cache|packages|temp|tmp|nvidia.*|amd|ati|intel|realtek|reference assemblies|msbuild|dotnet|powershell|windowspowershell|uninstall information|regid\..*|usoshared|usoprivate|softwaredistribution|comms|connecteddevicesplatform|crashdumps|crashreportclient|d3dscache|programs|peerdistrepub|desktop|ssh|application data|history|temporary internet files|deadpixel|claude.*|anthropic.*|cache|caches|fonts|virtualstore|publishers|identities|start menu|templates|\..*)$'

@{
    Id = 'leftovers'; Title = 'Хвости програм'; Order = 8
    Checks = @(
        @{
            Id = 'orphan-services'; Title = 'Служби видалених програм'
            Test = {
                $ev = @(); $items = @(); $danger = $false
                foreach ($s in Get-CimInstance Win32_Service -ErrorAction Stop) {
                    $exe = Get-ExeFromCommand $s.PathName
                    if (-not $exe -or -not [IO.Path]::IsPathRooted($exe) -or (Test-UnderWindows $exe) -or (Test-Path -LiteralPath $exe)) { continue }
                    $create = Test-CreatableByUsers $exe
                    if ($create) { $danger = $true }
                    $ev += $(if ($create) { "⚠ $($s.DisplayName) ($($s.Name)) - $exe  [файлу немає, а створити його може будь-яка програма: він запуститься від імені $($s.StartName)]" } else { "$($s.DisplayName) ($($s.Name)) - $exe" })
                    $items += New-CleanupItem 'Service' "Служба «$($s.DisplayName)» ($($s.Name))" @{ Name = $s.Name }
                }
                foreach ($d in Get-CimInstance Win32_SystemDriver -ErrorAction SilentlyContinue) {
                    $sys = Resolve-DriverPath $d.PathName
                    if (-not $sys -or -not [IO.Path]::IsPathRooted($sys) -or (Test-UnderWindows $sys) -or (Test-Path -LiteralPath $sys)) { continue }
                    $ev += "Драйвер $($d.DisplayName) ($($d.Name)) - $sys"
                    $items += New-CleanupItem 'Service' "Драйвер «$($d.DisplayName)» ($($d.Name))" @{ Name = $d.Name }
                }
                if (-not $items) { return Ok 'немає' }
                $r = if ($danger) { Issue high "$($items.Count) шт." 'Службу видаленої програми Windows досі пробує запускати. Якщо її файлу немає, а папка відкрита на запис, будь-яка програма може покласти туди свій файл - і він запуститься з правами системи.' $ev }
                     else { Issue low "$($items.Count) шт." 'Windows під час старту пробує запустити службу, якої вже немає: зайвий запис у журналі помилок і секунда до завантаження.' $ev }
                Add-Cleanup $r $items
            }
            Explain = 'Деінсталятори не завжди видаляють свої служби. Запис служби лишається і посилається на неіснуючий файл. Зазвичай це просто сміття, але якщо папку, де мав бути файл, може створити звичайна програма - це спосіб отримати права SYSTEM.'
            Pros = @('Закриває спосіб підвищити права через «порожню» службу', 'Менше помилок під час старту')
            Cons = @('Якщо програму ще будете перевстановлювати - вона створить службу знову, тож нічого не втратите')
            Fix = @{ Steps = @('«Прибрати…» перенесе записи служб у карантин (з резервною копією в .reg); відновити можна в «Карантин…». Видалення служби діє одразу, повернення - після перезавантаження.') }
        }
        @{
            Id = 'orphan-tasks'; Title = 'Завдання Планувальника на неіснуючі файли'
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
                        $ev += $(if ($create) { "⚠ $name - $exe  [файл може створити будь-яка програма$(if ($priv) { '; завдання з правами адміністратора' })]" } else { "$name - $exe" })
                        $items += New-CleanupItem 'Task' "Завдання $name" @{ Key = $t.TaskPath; Name = $t.TaskName }
                        break
                    }
                }
                if (-not $items) { return Ok 'немає' }
                $detail = if ($worst -ne 'low') { 'Завдання запускає файл, якого немає, з місця, куди може писати будь-яка програма: підклавши туди свій файл, вона запуститься за розкладом.' } else { 'Завдання від видалених програм: щоразу закінчуються помилкою.' }
                Add-Cleanup (Issue $worst "$($items.Count) шт." $detail $ev) $items
            }
            Explain = 'Програми створюють завдання Планувальника для оновлень і запуску, а деінсталятори часто їх забувають. Завдання на неіснуючий файл - сміття, а якщо папку можна створити - діра.'
            Pros = @('Немає завдань, які можна «підхопити» підкладеним файлом')
            Cons = @()
            Fix = @{ Open = 'taskschd.msc'; Steps = @('«Прибрати…» збереже завдання в XML і видалить його; відновлюється з «Карантин…».') }
        }
        @{
            Id = 'vulnerable-drivers'; Title = 'Відомі вразливі драйвери'
            Test = {
                $ev = @(); $running = $false
                foreach ($d in Get-CimInstance Win32_SystemDriver -ErrorAction Stop) {
                    $sys = Resolve-DriverPath $d.PathName
                    $base = if ($sys) { [IO.Path]::GetFileNameWithoutExtension($sys).ToLowerInvariant() } else { '' }
                    if (-not $VulnerableDrivers.ContainsKey($base)) { continue }
                    $exists = $sys -and (Test-Path -LiteralPath $sys)
                    if ($d.State -eq 'Running') { $running = $true }
                    $ev += "⚠ $($d.Name) - $sys ($($VulnerableDrivers[$base])), зараз: $($d.State), запуск: $($d.StartMode)$(if (-not $exists) { ', файлу вже немає' })"
                }
                if (-not $ev) { return Ok 'не знайдено' }
                Issue $(if ($running) { 'high' } else { 'medium' }) "$($ev.Count) шт." 'Ці драйвери легітимні, але мають відому вразливість: будь-яка програма з правами адміністратора отримує через них доступ до ядра (так вимикають антивіруси). Часто лишаються після утиліт розгону, моніторингу й RGB.' $ev
            }
            Explain = 'Атака «принеси свій вразливий драйвер» (BYOVD): зловмисник використовує старий підписаний драйвер з дірою, щоб виконати код у ядрі. Блок-лист Microsoft блокує частину з них, але не всі й не завжди.'
            Pros = @('Закриває шлях у ядро в обхід антивіруса')
            Cons = @('Програма, якій належить драйвер (утиліта моніторингу, підсвітки, розгону), перестане працювати - оновіть її: нові версії переходять на безпечні драйвери (LibreHardwareMonitor 0.9.4+ - на PawnIO)')
            Fix = @{ Open = 'ms-settings:appsfeatures'; Steps = @('Оновіть або видаліть програму, якій належить драйвер (назва - у доказах).', 'Якщо програми вже немає: sc.exe delete <ім''я драйвера> у командному рядку від адміністратора, потім перезавантаження.') }
        }
        @{
            Id = 'path-entries'; Title = 'Неіснуючі папки в PATH'
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
                        $scope = if ($s.Scope -eq 'Machine') { 'системний' } else { 'користувача' }
                        $ev += $(if ($s.Scope -eq 'Machine' -and $create) { "⚠ $entry ($scope PATH)  [папку може створити будь-яка програма, а системні служби шукають у ній DLL і програми]" } else { "$entry ($scope PATH)" })
                        $items += New-CleanupItem 'PathEntry' "PATH ($scope): $entry" @{ Scope = $s.Scope; Target = $entry }
                    }
                }
                if (-not $items) { return Ok 'немає' }
                $detail = if ($worst -eq 'high') { 'У системному PATH є папка, якої немає, але яку може створити будь-яка програма: поклавши туди DLL чи exe зі «знайомим» ім''ям, вона змусить системні процеси запустити свій код.' } else { 'Записи від видалених програм: самі по собі не шкодять, лише сповільнюють пошук програм у командному рядку.' }
                Add-Cleanup (Issue $worst "$($items.Count) шт." $detail $ev) $items
            }
            Explain = 'PATH - список папок, де Windows шукає програми й бібліотеки за коротким ім''ям. Інсталятори додають туди свої папки, а деінсталятори часто їх забувають.'
            Pros = @('Закриває підміну програм і DLL через «порожню» папку в PATH')
            Cons = @('Якщо програму перевстановите, вона сама додасть свою папку знову')
            Fix = @{ Open = 'rundll32.exe sysdm.cpl,EditEnvironmentVariables' }
        }
        @{
            Id = 'firewall-orphans'; Title = 'Дозволи брандмауера для видалених програм'
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
                    $items += New-CleanupItem 'FirewallRule' "Брандмауер: $path ($n $(Get-RulesWord $n))" @{ Target = $raw }
                }
                if (-not $items) { return Ok 'немає' }
                # Низький рівень: файл за цим шляхом отримав би лише дозвіл на вхідні з'єднання, а не права
                Add-Cleanup (Issue low "$($items.Count) прогр." 'Брандмауер досі дозволяє з''єднання програмам, яких уже немає (часто - старим версіям програм, що оновлюються в нову папку). Файл, покладений за тим самим шляхом, отримав би цей дозвіл без запиту.' $ev) $items
            }
            Explain = 'Під час першого запуску мережевої програми Windows створює для неї дозвіл у брандмауері. Після видалення програми дозвіл лишається.'
            Pros = @('Менше «відчинених дверей» у брандмауері')
            Cons = @('Якщо програму встановите знову, Windows ще раз спитає дозвіл')
            Fix = @{ Open = 'wf.msc' }
        }
        @{
            Id = 'broken-autoruns'; Title = 'Автозапуск неіснуючих програм'
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
                        $items += New-CleanupItem 'RegistryValue' "Автозапуск «$($x.Name)»" @{ Key = $k; Name = $x.Name }
                    }
                }
                $shell = New-Object -ComObject WScript.Shell
                foreach ($dir in [Environment]::GetFolderPath('Startup'), [Environment]::GetFolderPath('CommonStartup')) {
                    foreach ($f in Get-ChildItem $dir -Filter *.lnk -File -ErrorAction SilentlyContinue) {
                        $target = $shell.CreateShortcut($f.FullName).TargetPath
                        if (-not $target -or -not [IO.Path]::IsPathRooted($target) -or (Test-Path -LiteralPath $target)) { continue }
                        $ev += "$($f.Name) (папка «Автозавантаження») - $target"
                        $items += New-CleanupItem 'Path' "Ярлик автозавантаження «$($f.Name)»" @{ Target = $f.FullName }
                    }
                }
                if (-not $items) { return Ok 'немає' }
                Add-Cleanup (Issue low "$($items.Count) шт." 'Під час входу Windows пробує запустити програми, яких уже немає.' $ev) $items
            }
            Explain = 'Записи автозапуску від видалених програм. Самі по собі не шкодять, але засмічують список автозавантаження й журнал помилок.'
            Pros = @('Чистий список автозавантаження')
            Cons = @()
            Fix = @{ Open = 'ms-settings:startupapps' }
        }
        @{
            Id = 'shell-extensions'; Title = 'Зламані пункти контекстного меню'
            Test = {
                $ev = @(); $items = @()
                foreach ($b in '*', 'Directory', 'Directory\Background', 'Folder', 'Drive', 'AllFilesystemObjects') {
                    foreach ($h in Get-ChildItem -LiteralPath "Registry::HKEY_CLASSES_ROOT\$b\shellex\ContextMenuHandlers" -ErrorAction SilentlyContinue) {
                        $def = (Get-ItemProperty -LiteralPath $h.PSPath -ErrorAction SilentlyContinue).'(default)'
                        $clsid = if ($def -match '^\{[0-9a-fA-F-]{36}\}$') { $def } elseif ($h.PSChildName -match '^\{[0-9a-fA-F-]{36}\}$') { $h.PSChildName } else { $null }
                        if (-not $clsid) { continue }
                        $srv = (Get-ItemProperty -LiteralPath "Registry::HKEY_CLASSES_ROOT\CLSID\$clsid\InprocServer32" -ErrorAction SilentlyContinue).'(default)'
                        $why = $null
                        if (-not $srv) { $why = 'компонент не зареєстрований' }
                        else {
                            $dll = [Environment]::ExpandEnvironmentVariables($srv.Trim('"'))
                            if (-not [IO.Path]::IsPathRooted($dll)) { $dll = Join-Path "$env:windir\System32" $dll }
                            if (-not (Test-Path -LiteralPath $dll)) { $why = "немає файлу $dll" }
                        }
                        if (-not $why) { continue }
                        $rel = "SOFTWARE\Classes\$b\shellex\ContextMenuHandlers\$($h.PSChildName)"
                        $target = if (Test-Path -LiteralPath "HKLM:\$rel") { "HKLM:\$rel" } else { "HKCU:\$($rel -replace '^SOFTWARE', 'Software')" }
                        $ev += "$($h.PSChildName) ($b) - $why"
                        $items += New-CleanupItem 'RegistryKey' "Контекстне меню: $($h.PSChildName) ($b)" @{ Target = $target }
                    }
                }
                if (-not $items) { return Ok 'немає' }
                Add-Cleanup (Issue low "$($items.Count) шт." 'Провідник під час правого кліку пробує завантажити розширення, якого вже немає: меню відкривається повільніше, інколи Провідник зависає.' $ev) $items
            }
            Explain = 'Програми додають пункти в контекстне меню Провідника (архіватори, хмари, антивіруси). Після видалення програми запис може лишитися з посиланням на неіснуючу DLL.'
            Pros = @('Швидше контекстне меню, менше зависань Провідника')
            Cons = @()
            Fix = @{ Steps = @('«Прибрати…» експортує ключ у .reg і видалить його; відновлюється з «Карантин…».') }
        }
        @{
            Id = 'broken-uninstall'; Title = 'Записи «Програм», які не видаляються'
            Test = {
                $ev = @(); $items = @()
                foreach ($a in Get-InstalledApps) {
                    if (-not $a.UninstallString -or $a.UninstallString -match '(?i)msiexec') { continue }
                    $exe = Get-ExeFromCommand $a.UninstallString
                    if (-not $exe -or -not [IO.Path]::IsPathRooted($exe) -or (Test-Path -LiteralPath $exe)) { continue }
                    if ($a.InstallLocation -and (Test-Path -LiteralPath $a.InstallLocation.Trim('"'))) { continue }   # програма на місці - не чіпаємо
                    $ev += "$($a.DisplayName) - деінсталятора немає: $exe"
                    $items += New-CleanupItem 'RegistryKey' "Запис «$($a.DisplayName)»" @{ Target = ConvertTo-RegDrivePath $a.PSPath }
                }
                if (-not $items) { return Ok 'немає' }
                Add-Cleanup (Issue low "$($items.Count) шт." 'У «Програмах і компонентах» є програми, яких уже немає на диску: кнопка «Видалити» для них не працює.' $ev) $items
            }
            Explain = 'Якщо папку програми видалили вручну, її запис у «Програмах і компонентах» лишається назавжди - деінсталятора, який би його прибрав, уже немає.'
            Pros = @('Чистий список програм; оновлювачі не пропонують «оновити» те, чого немає')
            Cons = @()
            Fix = @{ Open = 'ms-settings:appsfeatures' }
        }
        @{
            Id = 'leftover-folders'; Title = 'Папки, що не належать жодній програмі'
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
                if (-not $big) { return Ok 'не знайдено' "Перевірено папок програм; можливих залишків більше 10 МБ немає." }
                $total = ($big | Measure-Object Size -Sum).Sum
                $ev = @($big | Select-Object -First 40 | ForEach-Object { "$(Format-Size $_.Size) - $($_.Path) (остання зміна $($_.Last.ToString('MM.yyyy')))" })
                $items = @($big | Select-Object -First 40 | ForEach-Object { New-CleanupItem 'Path' "$(Format-Size $_.Size) - $($_.Path)" @{ Target = $_.Path } $false $_.Size })
                Add-Cleanup (Issue info "$($big.Count) шт., $(Format-Size $total)" 'Папки, які не належать жодній встановленій програмі і давно не змінювалися: залишки видалених програм, кеші інструментів розробника (pip, npm), дані ігор. Це припущення - перевірте кожну, перш ніж прибирати.' $ev) $items
            }
            Explain = 'Деінсталятори часто лишають налаштування, кеші й журнали в Program Files, ProgramData і AppData. Аудит шукає папки, які не належать жодній встановленій програмі, ні один процес чи служба з них не працює і які не змінювалися щонайменше 2 місяці.'
            Pros = @('Звільняє місце')
            Cons = @(
                'УВАГА: у AppData часто лежать ЗБЕРЕЖЕННЯ ІГОР (папки з назвою гри, як-от EldenRing) - їх не прибирайте, якщо плануєте грати',
                'Це лише припущення: папка може належати портативній програмі - тому в списку нічого не позначено заздалегідь',
                'Карантин переносить папки в data\quarantine: місце звільниться лише після остаточного видалення через 30 днів'
            )
            Fix = @{ Steps = @(
                'Позначте в «Прибрати…» лише ті папки, які точно впізнаєте як залишки.',
                'Кеші інструментів краще чистити їхніми командами: pip cache purge, npm cache clean --force, pnpm store prune.'
            ) }
        }
        @{
            Id = 'old-driver-packages'; Title = 'Старі версії драйверів у сховищі'
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
                if (-not $rows) { return Ok 'немає зайвих' }
                Issue info "~$(Format-Size $extra)" 'Windows зберігає попередні версії драйверів (щоб можна було відкотити). Найбільше місця займають старі драйвери відеокарти.' @($rows | Sort-Object Old -Descending | ForEach-Object { "$($_.Name) - версій: $($_.Count), старі займають ~$(Format-Size $_.Old)" })
            }
            Explain = 'Сховище драйверів (DriverStore) тримає кожну встановлену версію драйвера. Після кількох оновлень драйвера відеокарти це гігабайти.'
            Pros = @('Звільняє місце на системному диску')
            Cons = @('Після очищення не вийде відкотити драйвер до старішої версії кнопкою «Відкотити» в Диспетчері пристроїв')
            Fix = @{ Open = 'cleanmgr.exe'; Steps = @('«Очищення диска» → «Очистити системні файли» → позначте «Пакети драйверів пристроїв» (видаляє лише невикористовувані версії).') }
        }
    )
}
