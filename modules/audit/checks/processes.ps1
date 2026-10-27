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
    $state = if ($disabled) { ' (вимкнено)' } else { '' }
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
        $m.Points += 5; $m.Why += "будь-яка програма може замінити цей файл, а запускається він від імені $who"
    } elseif (Test-WritableByUsers (Split-Path $exe)) {
        $m.Points += 3; $m.Why += "будь-яка програма може покласти файли в цю папку (наприклад, підмінну DLL), а запускається вона від імені $who"
    }
}

function Get-Worst($items) {
    $rank = @{ medium = 1; high = 2 }
    $w = $null
    foreach ($i in $items) { if ($i.Sev -and (-not $w -or $rank[$i.Sev] -gt $rank[$w])) { $w = $i.Sev } }
    $w
}

@{
    Id = 'processes'; Title = 'Процеси й автозапуск'; Order = 5
    Checks = @(
        @{
            Id = 'suspicious-processes'; Title = 'Підозрілі процеси'
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
                        $m.Points += 4; $m.Why += "запущено з $($parent.Name): документ запустив командний рядок (типовий шкідливий макрос)"
                    }
                    $sev = Get-RiskSeverity $m.Points
                    $path = Get-CleanPath $p.ExecutablePath
                    if ($sev) { $flagged += [pscustomobject]@{ Sev = $sev; Path = $path; Line = "$($p.Name) (PID $($p.ProcessId)) - $path  [$($m.Why -join '; ')]" } }
                }
                $note = if ($hidden -and -not (Test-Admin)) { "Перевірено процесів: $checked. Ще $hidden (системні й інших користувачів) видно лише з правами адміністратора." } else { "Перевірено процесів: $checked." }
                if (-not $flagged) { return Limited (Ok 'не знайдено' $note) }
                Limited (Issue (Get-Worst $flagged) "$($flagged.Count) шт." "Ознаки, типові для шкідливих програм. Це підозра, а не вирок: перевірте файл Defender'ом і згадайте, чи встановлювали цю програму. $note" @($flagged | ForEach-Object Line) @($flagged | ForEach-Object Path))
            }
            Explain = 'Аудит шукає ознаки, якими зазвичай виділяються шкідливі програми: запуск з тимчасових папок, відсутній або зламаний цифровий підпис, ім''я під системний процес (svchost.exe не з папки Windows, scvhost.exe), PowerShell, що завантажує й виконує код з інтернету, документ Word/Excel, що запустив командний рядок.'
            Pros = @('Ловить те, що антивірус ще не знає: поведінку, а не відомі сигнатури')
            Cons = @('Можливі хибні тривоги: маленькі утиліти без підпису, інсталятори з «Завантажень», інструменти розробника із закодованими командами')
            Fix = @{ Steps = @(
                '«Перевірити Defender''ом» - перевірка конкретного файлу (нічого не видаляє, лише повідомляє).',
                'Не впізнаєте програму - знайдіть її в «Програмах і компонентах» і видаліть, або завершіть процес і перевірте ПК повним скануванням Defender.'
            ); Open = 'windowsdefender://threat' }
        }
        @{
            Id = 'remote-access-tools'; Title = 'Програми віддаленого доступу'
            Test = {
                $found = [ordered]@{}
                foreach ($p in (Get-ProcessTable).Values) {
                    $b = Get-BaseName $p.Name
                    if ($RemoteTools.Contains($b)) { $found[$RemoteTools[$b]] = 'запущено' }
                }
                $service = $false
                foreach ($s in Get-CimInstance Win32_Service -ErrorAction SilentlyContinue) {
                    $b = Get-BaseName (Get-ExeFromCommand $s.PathName)
                    if ($RemoteTools.Contains($b) -or $RemoteTools.Contains($s.Name.ToLowerInvariant())) {
                        $t = if ($RemoteTools.Contains($b)) { $RemoteTools[$b] } else { $RemoteTools[$s.Name.ToLowerInvariant()] }
                        $found[$t] = "служба, запуск: $($s.StartMode), зараз: $($s.State)"
                        if ($s.StartMode -eq 'Auto') { $service = $true }
                    }
                }
                if ($found.Count -eq 0) { return Ok 'не знайдено' }
                $ev = @($found.Keys | ForEach-Object { "$_ - $($found[$_])" })
                if ($service) { return Issue low "$($found.Count) шт." 'Служба запускається разом із Windows: до ПК можна підключитися, навіть коли ви не за ним (якщо налаштовано постійний доступ). Переконайтеся, що встановлювали це самі і знаєте, хто має доступ.' $ev }
                Issue info "$($found.Count) шт." 'Переконайтеся, що встановлювали ці програми самі.' $ev
            }
            Explain = 'Програми віддаленого доступу дають повне керування ПК через інтернет. Ними користуються служби підтримки - і шахраї: «служба банку» просить встановити AnyDesk чи TeamViewer, а потім переказує гроші з вашого рахунку.'
            Pros = @('Знаєте, хто потенційно може керувати ПК')
            Cons = @('Видалення - не зможете отримати віддалену допомогу, поки не встановите знову')
            Fix = @{ Open = 'ms-settings:appsfeatures'; Steps = @('Непотрібну програму видаліть через «Програми». Потрібну - залиште, але вимкніть постійний (unattended) доступ і поставте складний пароль у її налаштуваннях.') }
        }
        @{
            Id = 'startup-entries'; Title = 'Автозавантаження'
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
                        $entries += [pscustomobject]@{ Label = "$($f.Name) (папка «Автозавантаження»)"; Path = $target; M = (Measure-Executable $target $cmd $null); Off = [bool]$folderOff[$f.Name] }
                    }
                }
                if (-not $entries) { return Ok 'порожньо' }
                $bad = @($entries | Where-Object { Get-RiskSeverity $_.M.Points })
                $ev = @($entries | Sort-Object { -$_.M.Points }, Label | ForEach-Object { Format-Entry $_.Label $_.Path $_.M $_.Off })
                $on = @($entries | Where-Object { -not $_.Off }).Count
                $value = "$($entries.Count) шт., увімкнено $on"
                if ($bad) {
                    $sev = Get-Worst @($bad | ForEach-Object { [pscustomobject]@{ Sev = Get-RiskSeverity $_.M.Points } })
                    return Issue $sev $value 'Серед програм автозапуску є підозрілі (позначені ⚠). Шкідливі програми майже завжди прописуються в автозапуск, щоб пережити перезавантаження.' $ev @($bad | ForEach-Object Path)
                }
                Issue info $value 'Усе, що стартує разом із Windows. Кожна зайва програма сповільнює запуск і тримає ресурси - вимкніть те, чим не користуєтеся щодня.' $ev
            }
            Explain = 'Автозавантаження - програми, що запускаються під час входу в Windows. Це найпростіший спосіб для шкідливої програми «прижитися», а для звичайних програм - причина повільного старту ПК.'
            Pros = @('Швидший запуск ПК і менше фонових процесів', 'Видно, якщо щось прописалося без вашого відома')
            Cons = @('Вимкнена програма не стартує сама (месенджер, хмара) - запускайте її вручну')
            Fix = @{ Open = 'ms-settings:startupapps' }
        }
        @{
            Id = 'scheduled-tasks'; Title = 'Сторонні завдання Планувальника'
            Test = {
                $items = @()
                foreach ($t in Get-ScheduledTask -ErrorAction Stop | Where-Object { $_.TaskPath -notlike '\Microsoft\*' }) {
                    $system = $t.Principal.UserId -in 'SYSTEM', 'S-1-5-18', 'LOCAL SERVICE', 'NETWORK SERVICE' -or $t.Principal.RunLevel -eq 'Highest'
                    foreach ($a in @($t.Actions | Where-Object { $_.Execute })) {
                        $exe = Get-ExeFromCommand $a.Execute
                        $m = Measure-Executable $exe "$($a.Execute) $($a.Arguments)" $null
                        if ($system) { Add-WritableRisk $m $exe 'адміністратора' }
                        $items += [pscustomobject]@{ Label = "$($t.TaskPath.TrimEnd('\'))\$($t.TaskName)" + $(if ($system) { ' [з правами]' } else { '' }); Path = $exe; M = $m; Off = $t.State -eq 'Disabled' }
                    }
                }
                if (-not $items) { return Ok 'немає' }
                $bad = @($items | Where-Object { Get-RiskSeverity $_.M.Points })
                $ev = @($items | Sort-Object { -$_.M.Points }, Label | ForEach-Object { Format-Entry $_.Label $_.Path $_.M $_.Off })
                if ($bad) {
                    $sev = Get-Worst @($bad | ForEach-Object { [pscustomobject]@{ Sev = Get-RiskSeverity $_.M.Points } })
                    return Issue $sev "$($items.Count) шт., підозрілих $($bad.Count)" 'Підозрілі завдання позначені ⚠.' $ev @($bad | ForEach-Object Path)
                }
                Issue info "$($items.Count) шт." 'Завдання, створені програмами (оновлення браузерів, драйверів, лаунчерів). Перевірте, що впізнаєте кожне.' $ev
            }
            Explain = 'Планувальник завдань запускає програми за розкладом або під час входу, часто з правами адміністратора. Шкідливі програми ховаються тут, бо в автозавантаженні їх легко помітити.'
            Pros = @('Видно приховані способи автозапуску')
            Cons = @('Вимкнене завдання оновлення - програма перестане сама оновлюватися')
            Fix = @{ Open = 'taskschd.msc' }
        }
        @{
            Id = 'services'; Title = 'Сторонні служби'
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
                            if (Test-WritableByUsers (Split-Path $candidate)) { $m.Points += 5; $m.Why += "шлях без лапок: файл $candidate запуститься замість служби"; break }
                        }
                    }
                    if (Get-RiskSeverity $m.Points) { $flagged += [pscustomobject]@{ Sev = Get-RiskSeverity $m.Points; Path = $exe; Line = "$($s.DisplayName) ($($s.Name)) - $exe  [$($m.Why -join '; ')]" } }
                }
                if (-not $flagged) { return Ok 'проблем не знайдено' "Перевірено сторонніх служб: $count." }
                Issue (Get-Worst $flagged) "$($flagged.Count) з $count" 'Служби працюють з найвищими правами. Якщо їх файл може змінити звичайна програма, будь-який вірус отримає права SYSTEM.' @($flagged | ForEach-Object Line) @($flagged | ForEach-Object Path)
            }
            Explain = 'Служби стартують разом із Windows і працюють від імені системи. Перевіряємо служби сторонніх програм: чи не лежить їхній файл у папці, куди може писати будь-яка програма, чи шлях узятий у лапки, чи файл підписаний.'
            Pros = @('Закриває типовий спосіб підвищити права до SYSTEM')
            Cons = @()
            Fix = @{ Open = 'services.msc'; Steps = @(
                'Найпростіше - переустановити програму в C:\Program Files: туди звичайні програми писати не можуть. Часто так буває з лаунчерами ігор, встановленими на інший диск (S:\Games…): там папки успадковують права «Змінювати» для всіх користувачів.',
                'Або забрати права запису з папки програми (командний рядок від адміністратора; ігри в бібліотеці лаунчера це не зачепить): icacls "<папка програми>" /inheritance:d, потім icacls "<папка програми>" /remove:g *S-1-5-11 /grant *S-1-5-11:(OI)(CI)RX',
                'Якщо програма не потрібна - видаліть її, служба зникне разом з нею.'
            ) }
        }
        @{
            Id = 'ifeo-debugger'; Title = 'Перехоплення запуску програм (IFEO)'
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
                if ($hits) { return Issue high "$($hits.Count) шт." 'Замість цих програм Windows запускає іншу. Так віруси не дають відкрити антивірус або Диспетчер завдань і «вбудовуються» в екран входу (sethc.exe, utilman.exe).' $hits }
                if ($known) { return Ok 'лише Process Explorer' 'Диспетчер завдань замінено на Process Explorer - це ваше налаштування.' $known }
                Ok 'немає'
            }
            Explain = 'Image File Execution Options - налаштування для розробників: «запускати програму X під налагоджувачем Y». Зловмисники використовують його, щоб підмінити запуск будь-якої програми своєю.'
            Pros = @('Ловить рідкісний, але небезпечний спосіб закріпитися в системі')
            Cons = @()
            Fix = @{ Steps = @('Видаліть значення Debugger у HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\<програма> (regedit від адміністратора), потім перевірте ПК повним скануванням Defender.') }
        }
        @{
            Id = 'wmi-persistence'; Title = 'Приховані підписки WMI'
            Admin = $true
            Test = {
                $c = @(Get-CimInstance -Namespace root\subscription -ClassName __EventConsumer -ErrorAction Stop |
                       Where-Object { $_.CimClass.CimClassName -in 'CommandLineEventConsumer', 'ActiveScriptEventConsumer' })
                if (-not $c) { return Ok 'немає' }
                Issue high "$($c.Count) шт." 'Підписка WMI запускає команду або скрипт за подією (старт системи, таймер). Звичайні програми так майже не роблять, а шкідливі - часто, бо це не видно в автозавантаженні.' @($c | ForEach-Object { "$($_.Name): $($_.CommandLineTemplate)$($_.ScriptText)" })
            }
            Explain = 'WMI-підписка - «безфайловий» автозапуск: команда зберігається в базі WMI і виконується за подією. Її не показують ні Диспетчер завдань, ні автозавантаження.'
            Pros = @('Знаходить один із найприхованіших способів закріплення')
            Cons = @()
            Fix = @{ Steps = @('Перевірте ПК повним і офлайн-скануванням Defender; видалити підписку можна через Sysinternals Autoruns (вкладка WMI).') }
        }
    )
}
