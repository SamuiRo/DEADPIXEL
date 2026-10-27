# Процеси й автозапуск: що зараз працює і що стартує саме. Евристики - це підозри з доказами, а не вирок.

# Програми віддаленого доступу: ім'я процесу/служби (нижній регістр, без .exe) → назва
$script:RemoteTools = [ordered]@{
    'teamviewer' = 'TeamViewer'; 'teamviewer_service' = 'TeamViewer'; 'anydesk' = 'AnyDesk'; 'rustdesk' = 'RustDesk'
    'screenconnect.clientservice' = 'ScreenConnect'; 'screenconnect.windowsclient' = 'ScreenConnect'; 'remoting_host' = 'Chrome Remote Desktop'
    'winvnc' = 'VNC'; 'tvnserver' = 'TightVNC'; 'vncserver' = 'RealVNC'; 'uvnc_service' = 'UltraVNC'; 'parsecd' = 'Parsec'
    'aa_v3' = 'Ammyy Admin'; 'ammyy_admin' = 'Ammyy Admin'; 'rserver3' = 'Radmin'; 'logmein' = 'LogMeIn'; 'lmiguardiansvc' = 'LogMeIn'
    'supremo' = 'Supremo'; 'supremoservice' = 'Supremo'; 'client32' = 'NetSupport'; 'srservice' = 'Splashtop'; 'ultraviewer_service' = 'UltraViewer'
    'ateraagent' = 'Atera'; 'getscreen' = 'GetScreen'; 'meshagent' = 'MeshCentral'
}

# Офісні програми: якщо вони запускають командний рядок - класичний шкідливий макрос
$script:OfficeApps = @('winword', 'excel', 'powerpnt', 'outlook', 'onenote', 'msaccess', 'mspub', 'visio')
$script:ShellApps = @('powershell', 'pwsh', 'cmd', 'wscript', 'cscript', 'mshta', 'rundll32', 'regsvr32', 'certutil', 'bitsadmin')

function Get-BaseName([string]$n) { if ($n) { [IO.Path]::GetFileNameWithoutExtension($n).ToLowerInvariant() } else { '' } }

# Запис автозапуску → рядок доказів; позначка ⚠ і причини, якщо підозрілий
function Format-Entry([string]$label, [string]$path, $m, [bool]$disabled) {
    $state = if ($disabled) { T ' (вимкнено)' ' (disabled)' } else { '' }
    $line = "$label$state - $(if ($path) { $path } else { '?' })"
    if (Get-RiskSeverity $m.Points) { "⚠ $line  [$($m.Why -join '; ')]" } else { $line }
}

# Записи, які вимкнули в Диспетчері завдань → «Автозавантаження»: перший байт 03 - вимкнено
function Get-DisabledStartup([string]$key) {
    $res = @{}
    $p = Get-ItemProperty $key -ErrorAction SilentlyContinue
    if ($p) { foreach ($x in $p.PSObject.Properties) { if ($x.Value -is [byte[]] -and $x.Value.Length -gt 0 -and $x.Value[0] -eq 3) { $res[$x.Name] = $true } } }
    $res
}

# Файл, що запускається з правами SYSTEM/адміністратора: чи може його змінити (або підкласти DLL поруч) звичайна програма
function Add-WritableRisk($m, [string]$exe, [string]$who) {
    if (-not $exe) { return }
    if (Test-WritableByUsers $exe) {
        $m.Points += 5; $m.Why += (T "будь-яка програма може замінити цей файл, а запускається він від імені $who" "any program can replace this file, and it runs as $who")
    } elseif (Test-WritableByUsers (Split-Path $exe)) {
        $m.Points += 3; $m.Why += (T "будь-яка програма може покласти файли в цю папку (наприклад, підмінну DLL), а запускається вона від імені $who" "any program can drop files into this folder (for example a hijacking DLL), and it runs as $who")
    }
}

function Get-Worst($items) {
    $rank = @{ medium = 1; high = 2 }
    $w = $null
    foreach ($i in $items) { if ($i.Sev -and (-not $w -or $rank[$i.Sev] -gt $rank[$w])) { $w = $i.Sev } }
    $w
}

@{
    Id = 'processes'; Title = (T 'Процеси й автозапуск' 'Processes and startup'); Order = 5
    Checks = @(
        @{
            Id = 'suspicious-processes'; Title = (T 'Підозрілі процеси' 'Suspicious processes')
            Test = {
                $procs = Get-ProcessTable
                $flagged = @(); $hidden = 0; $checked = 0
                foreach ($p in $procs.Values) {
                    if ($p.ProcessId -le 4) { continue }
                    if (-not $p.ExecutablePath) { $hidden++; continue }   # без прав видно лише власні процеси
                    $checked++
                    $m = Measure-Executable $p.ExecutablePath $p.CommandLine $p.Name
                    $parent = $procs[[int]$p.ParentProcessId]
                    if ($parent -and $ShellApps -contains (Get-BaseName $p.Name) -and $OfficeApps -contains (Get-BaseName $parent.Name)) {
                        $m.Points += 4; $m.Why += (T "запущено з $($parent.Name): документ запустив командний рядок (типовий шкідливий макрос)" "started by $($parent.Name): a document launched a command shell (typical malicious macro)")
                    }
                    $sev = Get-RiskSeverity $m.Points
                    $path = Get-CleanPath $p.ExecutablePath
                    if ($sev) { $flagged += [pscustomobject]@{ Sev = $sev; Path = $path; Line = "$($p.Name) (PID $($p.ProcessId)) - $path  [$($m.Why -join '; ')]" } }
                }
                $note = if ($hidden -and -not (Test-Admin)) { T "Перевірено процесів: $checked. Ще $hidden (системні й інших користувачів) видно лише з правами адміністратора." "Processes checked: $checked. Another $hidden (system and other users') are visible only with administrator rights." } else { T "Перевірено процесів: $checked." "Processes checked: $checked." }
                if (-not $flagged) { return Limited (Ok (T 'не знайдено' 'none found') $note) }
                Limited (Issue (Get-Worst $flagged) (T "$($flagged.Count) шт." "$($flagged.Count)") ((T 'Ознаки, типові для шкідливих програм. Це підозра, а не вирок: перевірте файл Defender''ом і згадайте, чи встановлювали цю програму. ' 'Signs typical of malware. This is a suspicion, not a verdict: scan the file with Defender and recall whether you installed this program. ') + $note) @($flagged | ForEach-Object Line) @($flagged | ForEach-Object Path))
            }
            Explain = (T 'Аудит шукає ознаки, якими зазвичай виділяються шкідливі програми: запуск з тимчасових папок, відсутній або зламаний цифровий підпис, ім''я під системний процес (svchost.exe не з папки Windows, scvhost.exe), PowerShell, що завантажує й виконує код з інтернету, документ Word/Excel, що запустив командний рядок.' 'The audit looks for signs that usually set malware apart: running from temporary folders, a missing or broken digital signature, a name mimicking a system process (svchost.exe outside the Windows folder, scvhost.exe), PowerShell downloading and running code from the internet, a Word/Excel document that launched a command shell.')
            Pros = @((T 'Ловить те, що антивірус ще не знає: поведінку, а не відомі сигнатури' 'Catches what the antivirus does not know yet: behavior rather than known signatures'))
            Cons = @((T 'Можливі хибні тривоги: маленькі утиліти без підпису, інсталятори з «Завантажень», інструменти розробника із закодованими командами' 'False alarms are possible: small unsigned utilities, installers in Downloads, developer tools with encoded commands'))
            Fix = @{ Steps = @(
                (T '«Перевірити Defender''ом» - перевірка конкретного файлу (нічого не видаляє, лише повідомляє).' '"Scan with Defender" checks the specific file (it deletes nothing, it only reports).'),
                (T 'Не впізнаєте програму - знайдіть її в «Програмах і компонентах» і видаліть, або завершіть процес і перевірте ПК повним скануванням Defender.' 'If you do not recognize the program, find it in Programs and Features and uninstall it, or end the process and run a full Defender scan.')
            ); Open = 'windowsdefender://threat' }
        }
        @{
            Id = 'remote-access-tools'; Title = (T 'Програми віддаленого доступу' 'Remote access programs')
            Test = {
                $found = [ordered]@{}
                foreach ($p in (Get-ProcessTable).Values) {
                    $b = Get-BaseName $p.Name
                    if ($RemoteTools.Contains($b)) { $found[$RemoteTools[$b]] = (T 'запущено' 'running') }
                }
                $service = $false
                foreach ($s in Get-CimInstance Win32_Service -ErrorAction SilentlyContinue) {
                    $b = Get-BaseName (Get-ExeFromCommand $s.PathName)
                    if ($RemoteTools.Contains($b) -or $RemoteTools.Contains($s.Name.ToLowerInvariant())) {
                        $t = if ($RemoteTools.Contains($b)) { $RemoteTools[$b] } else { $RemoteTools[$s.Name.ToLowerInvariant()] }
                        $found[$t] = (T "служба, запуск: $($s.StartMode), зараз: $($s.State)" "service, start: $($s.StartMode), now: $($s.State)")
                        if ($s.StartMode -eq 'Auto') { $service = $true }
                    }
                }
                if ($found.Count -eq 0) { return Ok (T 'не знайдено' 'none found') }
                $ev = @($found.Keys | ForEach-Object { "$_ - $($found[$_])" })
                if ($service) { return Issue low (T "$($found.Count) шт." "$($found.Count)") (T 'Служба запускається разом із Windows: до ПК можна підключитися, навіть коли ви не за ним (якщо налаштовано постійний доступ). Переконайтеся, що встановлювали це самі і знаєте, хто має доступ.' 'The service starts with Windows: the PC can be reached even when you are away from it (if unattended access is set up). Make sure you installed it yourself and know who has access.') $ev }
                Issue info (T "$($found.Count) шт." "$($found.Count)") (T 'Переконайтеся, що встановлювали ці програми самі.' 'Make sure you installed these programs yourself.') $ev
            }
            Explain = (T 'Програми віддаленого доступу дають повне керування ПК через інтернет. Ними користуються служби підтримки - і шахраї: «служба банку» просить встановити AnyDesk чи TeamViewer, а потім переказує гроші з вашого рахунку.' 'Remote access programs give full control of the PC over the internet. Support teams use them - and so do scammers: a "bank support" caller asks you to install AnyDesk or TeamViewer and then moves money out of your account.')
            Pros = @((T 'Знаєте, хто потенційно може керувати ПК' 'You know who could potentially control the PC'))
            Cons = @((T 'Видалення - не зможете отримати віддалену допомогу, поки не встановите знову' 'Uninstalling: you cannot get remote help until you install it again'))
            Fix = @{ Open = 'ms-settings:appsfeatures'; Steps = @((T 'Непотрібну програму видаліть через «Програми». Потрібну - залиште, але вимкніть постійний (unattended) доступ і поставте складний пароль у її налаштуваннях.' 'Uninstall an unneeded program in Apps. Keep a needed one, but turn off unattended access and set a strong password in its settings.')) }
        }
        @{
            Id = 'startup-entries'; Title = (T 'Автозавантаження' 'Startup')
            Test = {
                $entries = @()
                $sources = @(
                    @{ Key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'; Approved = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run' }
                    @{ Key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'; Approved = $null }
                    @{ Key = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run'; Approved = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run' }
                    @{ Key = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce'; Approved = $null }
                    @{ Key = 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; Approved = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32' }
                )
                foreach ($s in $sources) {
                    $off = if ($s.Approved) { Get-DisabledStartup $s.Approved } else { @{} }
                    $p = Get-ItemProperty $s.Key -ErrorAction SilentlyContinue
                    if (-not $p) { continue }
                    foreach ($x in $p.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' -and $_.Value -is [string] }) {
                        $exe = Get-ExeFromCommand $x.Value
                        $entries += [pscustomobject]@{ Label = $x.Name; Path = $exe; M = (Measure-Executable $exe $x.Value $null); Off = [bool]$off[$x.Name] }
                    }
                }
                $shell = New-Object -ComObject WScript.Shell
                $folderOff = Get-DisabledStartup 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder'
                foreach ($dir in [Environment]::GetFolderPath('Startup'), [Environment]::GetFolderPath('CommonStartup')) {
                    foreach ($f in Get-ChildItem $dir -File -ErrorAction SilentlyContinue | Where-Object Name -ne 'desktop.ini') {
                        $target = $f.FullName; $cmd = $f.FullName
                        if ($f.Extension -eq '.lnk') { $sc = $shell.CreateShortcut($f.FullName); $target = $sc.TargetPath; $cmd = "`"$($sc.TargetPath)`" $($sc.Arguments)" }
                        $entries += [pscustomobject]@{ Label = $f.Name + (T ' (папка «Автозавантаження»)' ' (Startup folder)'); Path = $target; M = (Measure-Executable $target $cmd $null); Off = [bool]$folderOff[$f.Name] }
                    }
                }
                if (-not $entries) { return Ok (T 'порожньо' 'empty') }
                $bad = @($entries | Where-Object { Get-RiskSeverity $_.M.Points })
                $ev = @($entries | Sort-Object { -$_.M.Points }, Label | ForEach-Object { Format-Entry $_.Label $_.Path $_.M $_.Off })
                $on = @($entries | Where-Object { -not $_.Off }).Count
                $value = T "$($entries.Count) шт., увімкнено $on" "$($entries.Count), enabled $on"
                if ($bad) {
                    $sev = Get-Worst @($bad | ForEach-Object { [pscustomobject]@{ Sev = Get-RiskSeverity $_.M.Points } })
                    return Issue $sev $value (T 'Серед програм автозапуску є підозрілі (позначені ⚠). Шкідливі програми майже завжди прописуються в автозапуск, щоб пережити перезавантаження.' 'Some startup programs look suspicious (marked ⚠). Malware almost always adds itself to startup to survive a reboot.') $ev @($bad | ForEach-Object Path)
                }
                Issue info $value (T 'Усе, що стартує разом із Windows. Кожна зайва програма сповільнює запуск і тримає ресурси - вимкніть те, чим не користуєтеся щодня.' 'Everything that starts with Windows. Each unneeded program slows startup and holds resources - disable what you do not use daily.') $ev
            }
            Explain = (T 'Автозавантаження - програми, що запускаються під час входу в Windows. Це найпростіший спосіб для шкідливої програми «прижитися», а для звичайних програм - причина повільного старту ПК.' 'Startup is the set of programs launched when you sign in to Windows. It is the easiest way for malware to persist, and for ordinary programs a cause of slow PC startup.')
            Pros = @((T 'Швидший запуск ПК і менше фонових процесів' 'Faster PC startup and fewer background processes'), (T 'Видно, якщо щось прописалося без вашого відома' 'You see if something added itself without your knowledge'))
            Cons = @((T 'Вимкнена програма не стартує сама (месенджер, хмара) - запускайте її вручну' 'A disabled program will not start by itself (messenger, cloud sync) - launch it manually'))
            Fix = @{ Open = 'ms-settings:startupapps' }
        }
        @{
            Id = 'scheduled-tasks'; Title = (T 'Сторонні завдання Планувальника' 'Third-party scheduled tasks')
            Test = {
                $items = @()
                foreach ($t in Get-ScheduledTask -ErrorAction Stop | Where-Object { $_.TaskPath -notlike '\Microsoft\*' }) {
                    $system = $t.Principal.UserId -in 'SYSTEM', 'S-1-5-18', 'LOCAL SERVICE', 'NETWORK SERVICE' -or $t.Principal.RunLevel -eq 'Highest'
                    foreach ($a in @($t.Actions | Where-Object { $_.Execute })) {
                        $exe = Get-ExeFromCommand $a.Execute
                        $m = Measure-Executable $exe "$($a.Execute) $($a.Arguments)" $null
                        if ($system) { Add-WritableRisk $m $exe (T 'адміністратора' 'administrator') }
                        $items += [pscustomobject]@{ Label = "$($t.TaskPath.TrimEnd('\'))\$($t.TaskName)" + $(if ($system) { T ' [з правами]' ' [elevated]' } else { '' }); Path = $exe; M = $m; Off = $t.State -eq 'Disabled' }
                    }
                }
                if (-not $items) { return Ok (T 'немає' 'none') }
                $bad = @($items | Where-Object { Get-RiskSeverity $_.M.Points })
                $ev = @($items | Sort-Object { -$_.M.Points }, Label | ForEach-Object { Format-Entry $_.Label $_.Path $_.M $_.Off })
                if ($bad) {
                    $sev = Get-Worst @($bad | ForEach-Object { [pscustomobject]@{ Sev = Get-RiskSeverity $_.M.Points } })
                    return Issue $sev (T "$($items.Count) шт., підозрілих $($bad.Count)" "$($items.Count), suspicious $($bad.Count)") (T 'Підозрілі завдання позначені ⚠.' 'Suspicious tasks are marked ⚠.') $ev @($bad | ForEach-Object Path)
                }
                Issue info (T "$($items.Count) шт." "$($items.Count)") (T 'Завдання, створені програмами (оновлення браузерів, драйверів, лаунчерів). Перевірте, що впізнаєте кожне.' 'Tasks created by programs (browser, driver and launcher updaters). Make sure you recognize each one.') $ev
            }
            Explain = (T 'Планувальник завдань запускає програми за розкладом або під час входу, часто з правами адміністратора. Шкідливі програми ховаються тут, бо в автозавантаженні їх легко помітити.' 'Task Scheduler runs programs on a schedule or at sign-in, often with administrator rights. Malware hides here because it is easy to spot in Startup.')
            Pros = @((T 'Видно приховані способи автозапуску' 'Hidden ways of autostart become visible'))
            Cons = @((T 'Вимкнене завдання оновлення - програма перестане сама оновлюватися' 'Disabling an update task stops the program from updating itself'))
            Fix = @{ Open = 'taskschd.msc' }
        }
        @{
            Id = 'services'; Title = (T 'Сторонні служби' 'Third-party services')
            Test = {
                $flagged = @(); $count = 0
                foreach ($s in Get-CimInstance Win32_Service -ErrorAction Stop) {
                    $exe = Get-ExeFromCommand $s.PathName
                    if (-not $exe -or $exe.ToLowerInvariant().StartsWith($env:windir.ToLowerInvariant() + '\')) { continue }
                    $count++
                    $m = Measure-Executable $exe $s.PathName $null
                    Add-WritableRisk $m $exe $s.StartName
                    # Шлях без лапок із пробілами: Windows по черзі пробує "C:\Program.exe", "C:\Program Files\Some.exe"...
                    $raw = $s.PathName.Trim()
                    if (-not $raw.StartsWith('"') -and $exe -match ' ') {
                        $parts = $exe -split ' '
                        for ($k = 1; $k -lt $parts.Count; $k++) {
                            $candidate = ($parts[0..($k - 1)] -join ' ') + '.exe'
                            if (Test-WritableByUsers (Split-Path $candidate)) { $m.Points += 5; $m.Why += (T "шлях без лапок: файл $candidate запуститься замість служби" "unquoted path: the file $candidate would run instead of the service"); break }
                        }
                    }
                    if (Get-RiskSeverity $m.Points) { $flagged += [pscustomobject]@{ Sev = Get-RiskSeverity $m.Points; Path = $exe; Line = "$($s.DisplayName) ($($s.Name)) - $exe  [$($m.Why -join '; ')]" } }
                }
                if (-not $flagged) { return Ok (T 'проблем не знайдено' 'no problems found') (T "Перевірено сторонніх служб: $count." "Third-party services checked: $count.") }
                Issue (Get-Worst $flagged) (T "$($flagged.Count) з $count" "$($flagged.Count) of $count") (T 'Служби працюють з найвищими правами. Якщо їх файл може змінити звичайна програма, будь-який вірус отримає права SYSTEM.' 'Services run with the highest rights. If an ordinary program can change their file, any malware gets SYSTEM rights.') @($flagged | ForEach-Object Line) @($flagged | ForEach-Object Path)
            }
            Explain = (T 'Служби стартують разом із Windows і працюють від імені системи. Перевіряємо служби сторонніх програм: чи не лежить їхній файл у папці, куди може писати будь-яка програма, чи шлях узятий у лапки, чи файл підписаний.' 'Services start with Windows and run as the system. We check third-party services: whether their file sits in a folder any program can write to, whether the path is quoted, and whether the file is signed.')
            Pros = @((T 'Закриває типовий спосіб підвищити права до SYSTEM' 'Closes a typical way to escalate to SYSTEM'))
            Cons = @()
            Fix = @{ Open = 'services.msc'; Steps = @(
                (T 'Найпростіше - переустановити програму в C:\Program Files: туди звичайні програми писати не можуть. Часто так буває з лаунчерами ігор, встановленими на інший диск (S:\Games…): там папки успадковують права «Змінювати» для всіх користувачів.' 'The simplest fix is to reinstall the program into C:\Program Files: ordinary programs cannot write there. This often happens with game launchers installed on another drive (S:\Games…), where folders inherit "Modify" rights for all users.'),
                (T 'Або забрати права запису з папки програми (командний рядок від адміністратора; ігри в бібліотеці лаунчера це не зачепить): icacls "<папка програми>" /inheritance:d, потім icacls "<папка програми>" /remove:g *S-1-5-11 /grant *S-1-5-11:(OI)(CI)RX' 'Or remove write rights from the program folder (administrator command prompt; games in the launcher library are not affected): icacls "<program folder>" /inheritance:d, then icacls "<program folder>" /remove:g *S-1-5-11 /grant *S-1-5-11:(OI)(CI)RX'),
                (T 'Якщо програма не потрібна - видаліть її, служба зникне разом з нею.' 'If you do not need the program, uninstall it and the service goes with it.')
            ) }
        }
        @{
            Id = 'ifeo-debugger'; Title = (T 'Перехоплення запуску програм (IFEO)' 'Program launch hijacking (IFEO)')
            Test = {
                $root = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options'
                $hits = @(); $known = @()
                foreach ($k in Get-ChildItem $root -ErrorAction SilentlyContinue) {
                    $d = Get-RegValue $k.PSPath 'Debugger'
                    if (-not $d) { continue }
                    # Process Explorer / System Informer замість Диспетчера завдань - легітимне налаштування
                    if ($k.PSChildName -eq 'taskmgr.exe' -and $d -match '(?i)procexp|systeminformer|processhacker') { $known += "$($k.PSChildName) → $d"; continue }
                    $hits += "$($k.PSChildName) → $d"
                }
                if ($hits) { return Issue high (T "$($hits.Count) шт." "$($hits.Count)") (T 'Замість цих програм Windows запускає іншу. Так віруси не дають відкрити антивірус або Диспетчер завдань і «вбудовуються» в екран входу (sethc.exe, utilman.exe).' 'Windows launches another program instead of these. Malware uses this to block the antivirus or Task Manager and to plant itself on the sign-in screen (sethc.exe, utilman.exe).') $hits }
                if ($known) { return Ok (T 'лише Process Explorer' 'Process Explorer only') (T 'Диспетчер завдань замінено на Process Explorer - це ваше налаштування.' 'Task Manager is replaced with Process Explorer - that is your own setting.') $known }
                Ok (T 'немає' 'none')
            }
            Explain = (T 'Image File Execution Options - налаштування для розробників: «запускати програму X під налагоджувачем Y». Зловмисники використовують його, щоб підмінити запуск будь-якої програми своєю.' 'Image File Execution Options is a developer setting: "run program X under debugger Y". Attackers use it to replace the launch of any program with their own.')
            Pros = @((T 'Ловить рідкісний, але небезпечний спосіб закріпитися в системі' 'Catches a rare but dangerous persistence technique'))
            Cons = @()
            Fix = @{ Steps = @((T 'Видаліть значення Debugger у HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\<програма> (regedit від адміністратора), потім перевірте ПК повним скануванням Defender.' 'Delete the Debugger value in HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\<program> (regedit as administrator), then run a full Defender scan.')) }
        }
        @{
            Id = 'wmi-persistence'; Title = (T 'Приховані підписки WMI' 'Hidden WMI subscriptions')
            Admin = $true
            Test = {
                $c = @(Get-CimInstance -Namespace root\subscription -ClassName __EventConsumer -ErrorAction Stop |
                       Where-Object { $_.CimClass.CimClassName -in 'CommandLineEventConsumer', 'ActiveScriptEventConsumer' })
                if (-not $c) { return Ok (T 'немає' 'none') }
                Issue high (T "$($c.Count) шт." "$($c.Count)") (T 'Підписка WMI запускає команду або скрипт за подією (старт системи, таймер). Звичайні програми так майже не роблять, а шкідливі - часто, бо це не видно в автозавантаженні.' 'A WMI subscription runs a command or script on an event (system start, timer). Ordinary programs rarely do this, malware often does, because it does not show up in Startup.') @($c | ForEach-Object { "$($_.Name): $($_.CommandLineTemplate)$($_.ScriptText)" })
            }
            Explain = (T 'WMI-підписка - «безфайловий» автозапуск: команда зберігається в базі WMI і виконується за подією. Її не показують ні Диспетчер завдань, ні автозавантаження.' 'A WMI subscription is "fileless" autostart: the command is stored in the WMI database and runs on an event. Neither Task Manager nor Startup shows it.')
            Pros = @((T 'Знаходить один із найприхованіших способів закріплення' 'Finds one of the stealthiest persistence techniques'))
            Cons = @()
            Fix = @{ Steps = @((T 'Перевірте ПК повним і офлайн-скануванням Defender; видалити підписку можна через Sysinternals Autoruns (вкладка WMI).' 'Run a full and an offline Defender scan; the subscription can be removed with Sysinternals Autoruns (WMI tab).')) }
        }
    )
}
