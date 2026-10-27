# Мережа: що на ПК приймає з'єднання ззовні, чи пропускає це брандмауер, ризиковані служби, Wi-Fi.

# Довідник: людський опис програм, що слухають мережу. Ключ - ім'я exe без розширення, у нижньому регістрі.
$script:KnownListeners = @{
    'steam' = 'Steam: Remote Play і завантаження ігор з інших ПК у локальній мережі'
    'syncthing' = 'Syncthing: синхронізація файлів між вашими пристроями'
    'qbittorrent' = 'qBittorrent: приймає з''єднання від інших учасників торента'
    'utorrent' = 'uTorrent: приймає з''єднання від інших учасників торента'
    'postgres' = 'PostgreSQL: база даних'
    'mysqld' = 'MySQL: база даних'
    'mongod' = 'MongoDB: база даних'
    'redis-server' = 'Redis: база даних у пам''яті'
    'sqlservr' = 'Microsoft SQL Server: база даних'
    'node' = 'Node.js: сервер розробника'
    'python' = 'Python: сервер або скрипт розробника'
    'java' = 'Java: сервер або програма на Java (Minecraft-сервер, IDE)'
    'javaw' = 'Java: програма на Java'
    'nginx' = 'nginx: веб-сервер'
    'httpd' = 'Apache: веб-сервер'
    'com.docker.backend' = 'Docker Desktop'
    'spotify' = 'Spotify: керування відтворенням з інших пристроїв (Spotify Connect)'
    'teamviewer_service' = 'TeamViewer: віддалений доступ до ПК'
    'anydesk' = 'AnyDesk: віддалений доступ до ПК'
    'rustdesk' = 'RustDesk: віддалений доступ до ПК'
    'parsecd' = 'Parsec: віддалений доступ і стрімінг ігор'
    'sunshine' = 'Sunshine: стрімінг ігор на інші пристрої'
    'nvcontainer' = 'NVIDIA: служби драйвера і GeForce Experience'
    'msi.centralserver' = 'MSI Center: керування підсвіткою й налаштуваннями плати'
    'warp-svc' = 'Cloudflare WARP: VPN'
    'discord' = 'Discord'
    'jellyfin' = 'Jellyfin: медіасервер'
    'plex media server' = 'Plex: медіасервер'
    'code' = 'Visual Studio Code: сервер розширень або налагодження'
}

# Порти, які небезпечно відкривати в мережу: [опис, рівень, якщо брандмауер їх пропускає]
$script:RiskyPorts = @{
    21 = @('FTP: пароль передається відкрито', 'medium'); 23 = @('Telnet: керування без шифрування', 'high')
    1433 = @('SQL Server', 'medium'); 2375 = @('Docker API без шифрування: повний контроль над ПК', 'high')
    3306 = @('MySQL', 'medium'); 3389 = @('Віддалений робочий стіл (RDP)', 'medium'); 5432 = @('PostgreSQL', 'medium'); 5433 = @('PostgreSQL', 'medium')
    5900 = @('VNC: віддалений доступ', 'high'); 6379 = @('Redis: часто без пароля', 'high'); 9200 = @('Elasticsearch', 'medium')
    11211 = @('Memcached', 'medium'); 27017 = @('MongoDB: часто без пароля', 'high')
}

# Системні процеси Windows, чиї порти (RPC, SMB, Delivery Optimization) показуємо одним рядком
$script:SystemListeners = @('system', 'svchost', 'lsass', 'wininit', 'services', 'spoolsv')

$script:FwView = $null
function Get-FirewallView {
    if ($script:FwView) { return $script:FwView }
    $pol = New-Object -ComObject HNetCfg.FwPolicy2
    $cur = [int]$pol.CurrentProfileTypes
    $on = $true
    foreach ($bit in 1, 2, 4) { if (($cur -band $bit) -and -not $pol.FirewallEnabled($bit)) { $on = $false } }
    # Лише дозвільні вхідні правила, увімкнені для поточного профілю мережі
    $rules = @(foreach ($r in $pol.Rules) {
        if ($r.Direction -eq 1 -and $r.Enabled -and $r.Action -eq 1 -and ($r.Profiles -band $cur)) {
            [pscustomobject]@{
                App = $(if ($r.ApplicationName) { [Environment]::ExpandEnvironmentVariables($r.ApplicationName).ToLowerInvariant() } else { '' })
                Ports = [string]$r.LocalPorts; Protocol = [int]$r.Protocol; Service = [string]$r.ServiceName; Name = [string]$r.Name
            }
        }
    })
    $name = if ($cur -band 4) { 'публічна' } elseif ($cur -band 2) { 'приватна' } else { 'доменна' }
    $script:FwView = [pscustomobject]@{ On = $on; Rules = $rules; ProfileName = $name }
    $script:FwView
}

function Test-PortInList([string]$list, [int]$port) {
    if (-not $list -or $list -eq '*') { return $true }
    foreach ($part in $list -split ',') {
        if ($part -match '^\s*(\d+)\s*-\s*(\d+)\s*$') { if ($port -ge [int]$Matches[1] -and $port -le [int]$Matches[2]) { return $true } }
        elseif ($part -match '^\s*(\d+)\s*$') { if ($port -eq [int]$Matches[1]) { return $true } }
    }
    $false
}

# Чи пропустить брандмауер вхідне з'єднання до програми на порт (наближено: блокувальні правила й обмеження адрес не враховуються)
function Test-FirewallAllows([string]$path, [int]$port, [int]$protocol) {
    $fw = Get-FirewallView
    if (-not $fw.On) { return $true }
    $p = if ($path) { $path.ToLowerInvariant() } else { '' }
    foreach ($r in $fw.Rules) {
        if ($r.Service) { continue }
        if ($r.Protocol -ne 256 -and $r.Protocol -ne $protocol) { continue }
        if ($r.App -and $r.App -ne $p) { continue }
        if (-not $r.App -and -not $r.Ports) { continue }   # правило «для всього» без програми і портів - зазвичай службове
        if (Test-PortInList $r.Ports $port) { return $true }
    }
    $false
}

@{
    Id = 'network'; Title = 'Мережа'; Order = 4
    Checks = @(
        @{
            Id = 'listening-ports'; Title = 'Програми, що приймають з''єднання з мережі'
            Test = {
                $procs = Get-ProcessTable
                $fw = Get-FirewallView
                $seen = @{}; $system = @{}; $rows = @(); $files = @()
                $worst = 0; $sevRank = @{ low = 1; medium = 2; high = 3 }; $sev = $null
                $listen = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | ForEach-Object { [pscustomobject]@{ Proto = 'TCP'; Num = 6; Port = [int]$_.LocalPort; Addr = $_.LocalAddress; Pid = [int]$_.OwningProcess } })
                foreach ($l in $listen | Sort-Object Port) {
                    if ($l.Addr -match '^(127\.|::1$)') { continue }   # лише для цього ПК - ззовні недоступно
                    $p = $procs[$l.Pid]
                    $name = if ($p) { [IO.Path]::GetFileNameWithoutExtension($p.Name) } else { "PID $($l.Pid)" }
                    if ($SystemListeners -contains $name.ToLowerInvariant()) { $system[$l.Port] = $true; continue }
                    $key = "$name|$($l.Port)"
                    if ($seen[$key]) { continue }
                    $seen[$key] = $true
                    $path = if ($p) { $p.ExecutablePath } else { $null }
                    $allowed = Test-FirewallAllows $path $l.Port $l.Num
                    $desc = $KnownListeners[$name.ToLowerInvariant()]
                    $risky = $RiskyPorts[$l.Port]
                    $flag = ''
                    $exe = Measure-Executable $path $(if ($p) { $p.CommandLine }) $name
                    if ($allowed -and $risky) { $s = $risky[1]; $flag = "⚠ $($risky[0]) відкрито в мережу" }
                    elseif ($allowed -and (Get-RiskSeverity $exe.Points)) { $s = 'medium'; $flag = '⚠ підозріла програма приймає з''єднання: ' + ($exe.Why -join '; '); $files += $path }
                    else { $s = $null }
                    if ($s -and $sevRank[$s] -gt $worst) { $worst = $sevRank[$s]; $sev = $s }
                    $state = if ($allowed) { "брандмауер ПРОПУСКАЄ ($($fw.ProfileName) мережа)" } else { 'брандмауер блокує' }
                    $rows += ('TCP {0} - {1}{2} - {3}' -f $l.Port, $name, $(if ($desc) { " ($desc)" } else { '' }), $state) + $(if ($flag) { "  $flag" } else { '' })
                }
                $udp = @(Get-NetUDPEndpoint -ErrorAction SilentlyContinue | Where-Object { $_.LocalAddress -notmatch '^(127\.|::1$)' } | ForEach-Object {
                    $p = $procs[[int]$_.OwningProcess]; if ($p) { [IO.Path]::GetFileNameWithoutExtension($p.Name) }
                } | Where-Object { $_ -and $SystemListeners -notcontains $_.ToLowerInvariant() } | Sort-Object -Unique)
                if ($udp.Count) { $rows += 'UDP (пошук пристроїв, ігри, торенти): ' + ($udp -join ', ') }
                if ($system.Count) { $rows += 'Служби Windows: TCP ' + (($system.Keys | Sort-Object) -join ', ') + ' (спільні папки, RPC, Delivery Optimization)' }

                $apps = @($seen.Keys | ForEach-Object { ($_ -split '\|')[0] } | Sort-Object -Unique).Count
                $ports = $seen.Count
                $open = @($rows | Where-Object { $_ -match 'ПРОПУСКАЄ' }).Count
                $detail = if (-not $fw.On) { 'Брандмауер вимкнено - усі ці програми доступні з мережі.' }
                          else { "Брандмауер пропускає $open з $ports портів. Роутер зазвичай не пускає ці порти з інтернету, тож головний ризик - інші пристрої в тій самій мережі (публічний Wi-Fi, гуртожиток, офіс)." }
                $value = "$apps прогр., відкрито портів: $open"
                if ($sev) { return Limited (Issue $sev $value $detail $rows $files) }
                if ($apps -eq 0) { return Limited (Ok 'немає' 'Сторонні програми не приймають з''єднань з мережі.' $rows) }
                Limited (Issue info $value $detail $rows)
            }
            Explain = 'Програма, що «слухає» порт, приймає з''єднання від інших пристроїв. Це нормально для ігор, синхронізації, торентів, але кожна така програма - двері в ПК: якщо в ній знайдуть вразливість, через неї зайдуть. Бази даних і сервери розробника краще прив''язувати лише до 127.0.0.1.'
            Pros = @('Знаєте, які програми видно з мережі, і закриваєте зайві')
            Cons = @('Якщо заблокувати програмі мережу, перестануть працювати її мережеві функції (спільна гра, синхронізація, роздача торента)')
            Fix = @{ Open = 'windowsdefender://network'; Steps = @(
                'Непотрібну програму закрийте або приберіть з автозапуску.',
                'Для бази даних або сервера розробника в налаштуваннях вкажіть адресу 127.0.0.1 замість 0.0.0.0 (PostgreSQL: listen_addresses = ''localhost'').',
                'Дозволи брандмауера: «Безпека Windows» → «Брандмауер і захист мережі» → «Дозволити роботу програми через брандмауер».'
            ) }
        }
        @{
            Id = 'smb1'; Title = 'Застарілий протокол SMBv1'
            Test = {
                $svc = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Services\mrxsmb10' 'Start'
                if ($null -eq $svc -or $svc -eq 4) { return Ok 'вимкнено' }
                Issue high 'увімкнено' 'SMBv1 не має сучасного захисту; через нього поширювалися WannaCry і NotPetya.'
            }
            Explain = 'SMB - протокол спільних папок і принтерів Windows. Перша версія (SMBv1) застаріла 30 років тому і має критичні вразливості. Сучасна Windows її не встановлює; вона лишається після оновлень зі старих систем або для дуже старих NAS.'
            Pros = @('Закриває шлях, яким поширювалися найвідоміші мережеві віруси')
            Cons = @('Перестануть відкриватися спільні папки на дуже старих мережевих дисках (NAS) і Windows XP - оновіть їм прошивку або ввімкніть SMBv2')
            Fix = @{ Recipe = 'smb1-off' }
        }
        @{
            Id = 'rdp'; Title = 'Віддалений робочий стіл (RDP)'
            Test = {
                if ((Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' 'fDenyTSConnections') -ne 0) { return Ok 'вимкнено' }
                $port = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' 'PortNumber'
                $nla = (Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' 'UserAuthentication') -eq 1
                $ev = @("Порт: $port")
                if (-not $nla) { return Issue high 'увімкнено без NLA' 'Екран входу Windows доступний будь-кому в мережі ще до перевірки пароля - так атакують підбором і через вразливості RDP (BlueKeep).' $ev }
                Issue low 'увімкнено (з NLA)' 'До ПК можна підключитися віддалено з паролем облікового запису. Якщо ви цим не користуєтеся - вимкніть.' $ev
            }
            Explain = 'RDP дозволяє керувати ПК з іншого комп''ютера. Відкритий в інтернет RDP - найпоширеніший спосіб, яким шифрувальники потрапляють у компанії. NLA вимагає пароль ще до показу екрана входу.'
            Pros = @('Вимкнений RDP або RDP з NLA закриває популярний вектор атак')
            Cons = @('Вимкнення: не зможете підключитися до цього ПК через «Підключення до віддаленого робочого стола»')
            Fix = @{ Recipe = 'rdp-hardening'; Open = 'ms-settings:remotedesktop' }
        }
        @{
            Id = 'remote-registry'; Title = 'Служба «Віддалений реєстр»'
            Test = {
                $s = Get-Service RemoteRegistry -ErrorAction SilentlyContinue
                if (-not $s) { return NotApplicable 'Служби немає в цій системі.' }
                if ($s.Status -eq 'Running' -or $s.StartType -eq 'Automatic') { return Issue medium "$($s.Status), запуск: $($s.StartType)" 'З мережі можна читати і змінювати реєстр цього ПК (з паролем адміністратора).' }
                Ok $(if ($s.StartType -eq 'Disabled') { 'вимкнено' } else { 'не запущено' })
            }
            Explain = 'Віддалений реєстр дозволяє адміністраторам змінювати реєстр ПК по мережі. Вдома він не потрібен, а для зловмисника в мережі - зручний інструмент.'
            Pros = @('Ще одна мережева служба менше')
            Cons = @('Деякі корпоративні інструменти адміністрування не зможуть керувати ПК')
            Fix = @{ Recipe = 'remote-registry-off' }
        }
        @{
            Id = 'network-profile'; Title = 'Профіль мережі'
            Test = {
                $profiles = @(Get-NetConnectionProfile -ErrorAction Stop)
                $ev = @($profiles | ForEach-Object { "$($_.Name) ($($_.InterfaceAlias)): $(@{ Public = 'публічна'; Private = 'приватна'; DomainAuthenticated = 'доменна' }[[string]$_.NetworkCategory])" })
                $wifiPrivate = @($profiles | Where-Object { $_.NetworkCategory -eq 'Private' -and $_.InterfaceAlias -match '(?i)wi-?fi|wlan|бездрот' })
                if ($wifiPrivate) { return Issue info 'Wi-Fi як приватна' "Мережа «$($wifiPrivate[0].Name)» позначена як приватна: ПК видно іншим пристроям у ній. Це нормально вдома, але не в кафе, готелі чи гуртожитку." $ev }
                Ok $(if ($profiles | Where-Object NetworkCategory -eq 'Private') { 'приватна' } else { 'публічна' }) '' $ev
            }
            Explain = 'У «приватній» мережі Windows показує ПК іншим пристроям і дозволяє спільні папки та принтери. У «публічній» - ховає. Для чужих мереж завжди вибирайте «публічна».'
            Pros = @('Публічний профіль у чужій мережі - ПК невидимий для інших')
            Cons = @('У публічній мережі не працюють спільні папки і пошук пристроїв (Chromecast, принтери)')
            Fix = @{ Open = 'ms-settings:network-status' }
        }
        @{
            Id = 'shares'; Title = 'Спільні папки'
            Test = {
                $shares = @(Get-CimInstance Win32_Share -ErrorAction Stop | Where-Object { $_.Type -eq 0 -and $_.Name -notmatch '\$$' })
                if (-not $shares) { return Ok 'немає' }
                Issue info "$($shares.Count) шт." 'Ці папки доступні по мережі. Переконайтеся, що серед них немає зайвих і що доступ мають лише потрібні люди.' @($shares | ForEach-Object { "$($_.Name) → $($_.Path)" })
            }
            Explain = 'Спільна папка відкриває файли іншим комп''ютерам мережі. Права доступу перевіряйте у властивостях папки → «Спільний доступ».'
            Pros = @()
            Cons = @()
            Fix = @{ Open = 'fsmgmt.msc' }
        }
        @{
            Id = 'wifi-open'; Title = 'Збережені відкриті Wi-Fi мережі'
            Test = {
                # Профілі експортуються без паролів (без key=clear) у тимчасову папку і одразу видаляються
                $dir = Join-Path $env:TEMP ('deadpixel-wlan-' + [guid]::NewGuid().ToString('N'))
                New-Item -ItemType Directory $dir | Out-Null
                try {
                    $null = netsh wlan export profile folder="$dir" 2>&1
                    $xml = @(Get-ChildItem $dir -Filter *.xml)
                    if ($xml.Count -eq 0) { return NotApplicable 'Немає Wi-Fi або збережених мереж.' }
                    $open = @(foreach ($f in $xml) {
                        [xml]$x = Get-Content $f.FullName -Raw -Encoding UTF8
                        $auth = $x.WLANProfile.MSM.security.authEncryption.authentication
                        if ($auth -eq 'open') { [pscustomobject]@{ Name = $x.WLANProfile.name; Auto = $x.WLANProfile.connectionMode -eq 'auto' } }
                    })
                } finally { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
                if (-not $open) { return Ok 'немає' "Перевірено збережених мереж: $($xml.Count)." }
                $auto = @($open | Where-Object Auto)
                $ev = @($open | ForEach-Object { $_.Name + $(if ($_.Auto) { ' (підключається автоматично)' } else { '' }) })
                if ($auto) { return Issue low "$($open.Count) шт., авто: $($auto.Count)" 'ПК сам підключиться до будь-якої відкритої мережі з такою назвою - зловмисник може створити точку доступу з тим самим ім''ям і бачити ваш трафік.' $ev }
                Issue info "$($open.Count) шт." 'Збережені мережі без пароля. Автоматично ПК до них не підключається.' $ev
            }
            Explain = 'Відкрита Wi-Fi мережа не шифрує трафік, а її назву легко підробити. Якщо ПК пам''ятає таку мережу з автопідключенням, він під''єднається до підробки сам.'
            Pros = @('ПК не під''єднається сам до підробленої точки доступу')
            Cons = @('До цих мереж доведеться підключатися вручну')
            Fix = @{ Open = 'ms-settings:network-wifisettings'; Steps = @('«Керування відомими мережами» → виберіть мережу → «Забути», або вимкніть «Підключатися автоматично».') }
        }
    )
}
