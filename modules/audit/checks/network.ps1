# Мережа: що на ПК приймає з'єднання ззовні, чи пропускає це брандмауер, ризиковані служби, Wi-Fi.

# Довідник: людський опис програм, що слухають мережу. Ключ - ім'я exe без розширення, у нижньому регістрі.
$script:KnownListeners = @{
    'steam' = (T 'Steam: Remote Play і завантаження ігор з інших ПК у локальній мережі' 'Steam: Remote Play and game downloads from other PCs on the local network')
    'syncthing' = (T 'Syncthing: синхронізація файлів між вашими пристроями' 'Syncthing: file sync between your devices')
    'qbittorrent' = (T 'qBittorrent: приймає з''єднання від інших учасників торента' 'qBittorrent: accepts connections from other torrent peers')
    'utorrent' = (T 'uTorrent: приймає з''єднання від інших учасників торента' 'uTorrent: accepts connections from other torrent peers')
    'postgres' = (T 'PostgreSQL: база даних' 'PostgreSQL: database')
    'mysqld' = (T 'MySQL: база даних' 'MySQL: database')
    'mongod' = (T 'MongoDB: база даних' 'MongoDB: database')
    'redis-server' = (T 'Redis: база даних у пам''яті' 'Redis: in-memory database')
    'sqlservr' = (T 'Microsoft SQL Server: база даних' 'Microsoft SQL Server: database')
    'node' = (T 'Node.js: сервер розробника' 'Node.js: developer server')
    'python' = (T 'Python: сервер або скрипт розробника' 'Python: developer server or script')
    'java' = (T 'Java: сервер або програма на Java (Minecraft-сервер, IDE)' 'Java: a Java server or program (Minecraft server, IDE)')
    'javaw' = (T 'Java: програма на Java' 'Java: a Java program')
    'nginx' = (T 'nginx: веб-сервер' 'nginx: web server')
    'httpd' = (T 'Apache: веб-сервер' 'Apache: web server')
    'com.docker.backend' = 'Docker Desktop'
    'spotify' = (T 'Spotify: керування відтворенням з інших пристроїв (Spotify Connect)' 'Spotify: playback control from other devices (Spotify Connect)')
    'teamviewer_service' = (T 'TeamViewer: віддалений доступ до ПК' 'TeamViewer: remote access to the PC')
    'anydesk' = (T 'AnyDesk: віддалений доступ до ПК' 'AnyDesk: remote access to the PC')
    'rustdesk' = (T 'RustDesk: віддалений доступ до ПК' 'RustDesk: remote access to the PC')
    'parsecd' = (T 'Parsec: віддалений доступ і стрімінг ігор' 'Parsec: remote access and game streaming')
    'sunshine' = (T 'Sunshine: стрімінг ігор на інші пристрої' 'Sunshine: game streaming to other devices')
    'nvcontainer' = (T 'NVIDIA: служби драйвера і GeForce Experience' 'NVIDIA: driver services and GeForce Experience')
    'msi.centralserver' = (T 'MSI Center: керування підсвіткою й налаштуваннями плати' 'MSI Center: lighting and board settings')
    'warp-svc' = 'Cloudflare WARP: VPN'
    'discord' = 'Discord'
    'jellyfin' = (T 'Jellyfin: медіасервер' 'Jellyfin: media server')
    'plex media server' = (T 'Plex: медіасервер' 'Plex: media server')
    'code' = (T 'Visual Studio Code: сервер розширень або налагодження' 'Visual Studio Code: extension or debug server')
}

# Порти, які небезпечно відкривати в мережу: [опис, рівень, якщо брандмауер їх пропускає]
$script:RiskyPorts = @{
    21 = @((T 'FTP: пароль передається відкрито' 'FTP: the password travels in plain text'), 'medium'); 23 = @((T 'Telnet: керування без шифрування' 'Telnet: unencrypted remote control'), 'high')
    1433 = @('SQL Server', 'medium'); 2375 = @((T 'Docker API без шифрування: повний контроль над ПК' 'Docker API without TLS: full control of the PC'), 'high')
    3306 = @('MySQL', 'medium'); 3389 = @((T 'Віддалений робочий стіл (RDP)' 'Remote Desktop (RDP)'), 'medium'); 5432 = @('PostgreSQL', 'medium'); 5433 = @('PostgreSQL', 'medium')
    5900 = @((T 'VNC: віддалений доступ' 'VNC: remote access'), 'high'); 6379 = @((T 'Redis: часто без пароля' 'Redis: often without a password'), 'high'); 9200 = @('Elasticsearch', 'medium')
    11211 = @('Memcached', 'medium'); 27017 = @((T 'MongoDB: часто без пароля' 'MongoDB: often without a password'), 'high')
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
    $name = if ($cur -band 4) { T 'публічна' 'public' } elseif ($cur -band 2) { T 'приватна' 'private' } else { T 'доменна' 'domain' }
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
    Id = 'network'; Title = (T 'Мережа' 'Network'); Order = 4
    Checks = @(
        @{
            Id = 'listening-ports'; Title = (T 'Програми, що приймають з''єднання з мережі' 'Programs accepting network connections')
            Test = {
                $procs = Get-ProcessTable
                $fw = Get-FirewallView
                $seen = @{}; $system = @{}; $rows = @(); $files = @(); $open = 0
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
                    if ($allowed) { $open++ }
                    $desc = $KnownListeners[$name.ToLowerInvariant()]
                    $risky = $RiskyPorts[$l.Port]
                    $flag = ''
                    $exe = Measure-Executable $path $(if ($p) { $p.CommandLine }) $name
                    if ($allowed -and $risky) { $s = $risky[1]; $flag = '⚠ ' + $risky[0] + (T ' відкрито в мережу' ' exposed to the network') }
                    elseif ($allowed -and (Get-RiskSeverity $exe.Points)) { $s = 'medium'; $flag = (T '⚠ підозріла програма приймає з''єднання: ' '⚠ a suspicious program accepts connections: ') + ($exe.Why -join '; '); $files += $path }
                    else { $s = $null }
                    if ($s -and $sevRank[$s] -gt $worst) { $worst = $sevRank[$s]; $sev = $s }
                    $state = if ($allowed) { T "брандмауер ПРОПУСКАЄ ($($fw.ProfileName) мережа)" "firewall ALLOWS ($($fw.ProfileName) network)" } else { T 'брандмауер блокує' 'firewall blocks' }
                    $rows += ('TCP {0} - {1}{2} - {3}' -f $l.Port, $name, $(if ($desc) { " ($desc)" } else { '' }), $state) + $(if ($flag) { "  $flag" } else { '' })
                }
                $udp = @(Get-NetUDPEndpoint -ErrorAction SilentlyContinue | Where-Object { $_.LocalAddress -notmatch '^(127\.|::1$)' } | ForEach-Object {
                    $p = $procs[[int]$_.OwningProcess]; if ($p) { [IO.Path]::GetFileNameWithoutExtension($p.Name) }
                } | Where-Object { $_ -and $SystemListeners -notcontains $_.ToLowerInvariant() } | Sort-Object -Unique)
                if ($udp.Count) { $rows += (T 'UDP (пошук пристроїв, ігри, торенти): ' 'UDP (device discovery, games, torrents): ') + ($udp -join ', ') }
                if ($system.Count) { $rows += (T 'Служби Windows: TCP ' 'Windows services: TCP ') + (($system.Keys | Sort-Object) -join ', ') + (T ' (спільні папки, RPC, Delivery Optimization)' ' (file sharing, RPC, Delivery Optimization)') }

                $apps = @($seen.Keys | ForEach-Object { ($_ -split '\|')[0] } | Sort-Object -Unique).Count
                $ports = $seen.Count
                $detail = if (-not $fw.On) { T 'Брандмауер вимкнено - усі ці програми доступні з мережі.' 'The firewall is off - all these programs are reachable from the network.' }
                          else { T "Брандмауер пропускає $open з $ports портів. Роутер зазвичай не пускає ці порти з інтернету, тож головний ризик - інші пристрої в тій самій мережі (публічний Wi-Fi, гуртожиток, офіс)." "The firewall allows $open of $ports ports. A router usually keeps these ports closed to the internet, so the main risk is other devices on the same network (public Wi-Fi, dorm, office)." }
                $value = T "$apps прогр., відкрито портів: $open" "$apps programs, open ports: $open"
                if ($sev) { return Limited (Issue $sev $value $detail $rows $files) }
                if ($apps -eq 0) { return Limited (Ok (T 'немає' 'none') (T 'Сторонні програми не приймають з''єднань з мережі.' 'No third-party program accepts network connections.') $rows) }
                Limited (Issue info $value $detail $rows)
            }
            Explain = (T 'Програма, що «слухає» порт, приймає з''єднання від інших пристроїв. Це нормально для ігор, синхронізації, торентів, але кожна така програма - двері в ПК: якщо в ній знайдуть вразливість, через неї зайдуть. Бази даних і сервери розробника краще прив''язувати лише до 127.0.0.1.' 'A program that "listens" on a port accepts connections from other devices. That is normal for games, sync and torrents, but each such program is a door into the PC: if a vulnerability is found in it, that is how attackers get in. Bind databases and developer servers to 127.0.0.1 only.')
            Pros = @((T 'Знаєте, які програми видно з мережі, і закриваєте зайві' 'You know which programs are visible from the network and close the unneeded ones'))
            Cons = @((T 'Якщо заблокувати програмі мережу, перестануть працювати її мережеві функції (спільна гра, синхронізація, роздача торента)' 'Blocking a program''s network access breaks its network features (multiplayer, sync, torrent seeding)'))
            Fix = @{ Open = 'windowsdefender://network'; Steps = @(
                (T 'Непотрібну програму закрийте або приберіть з автозапуску.' 'Close an unneeded program or remove it from startup.'),
                (T 'Для бази даних або сервера розробника в налаштуваннях вкажіть адресу 127.0.0.1 замість 0.0.0.0 (PostgreSQL: listen_addresses = ''localhost'').' 'For a database or developer server, set the address to 127.0.0.1 instead of 0.0.0.0 (PostgreSQL: listen_addresses = ''localhost'').'),
                (T 'Дозволи брандмауера: «Безпека Windows» → «Брандмауер і захист мережі» → «Дозволити роботу програми через брандмауер».' 'Firewall permissions: Windows Security → Firewall & network protection → "Allow an app through firewall".')
            ) }
        }
        @{
            Id = 'smb1'; Title = (T 'Застарілий протокол SMBv1' 'The obsolete SMBv1 protocol')
            Test = {
                $svc = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Services\mrxsmb10' 'Start'
                if ($null -eq $svc -or $svc -eq 4) { return Ok (T 'вимкнено' 'off') }
                Issue high (T 'увімкнено' 'on') (T 'SMBv1 не має сучасного захисту; через нього поширювалися WannaCry і NotPetya.' 'SMBv1 lacks modern protection; WannaCry and NotPetya spread through it.')
            }
            Explain = (T 'SMB - протокол спільних папок і принтерів Windows. Перша версія (SMBv1) застаріла 30 років тому і має критичні вразливості. Сучасна Windows її не встановлює; вона лишається після оновлень зі старих систем або для дуже старих NAS.' 'SMB is the Windows file and printer sharing protocol. Its first version (SMBv1) is 30 years old and has critical vulnerabilities. Modern Windows does not install it; it lingers after upgrades from old systems or for very old NAS devices.')
            Pros = @((T 'Закриває шлях, яким поширювалися найвідоміші мережеві віруси' 'Closes the path the most famous network worms used'))
            Cons = @((T 'Перестануть відкриватися спільні папки на дуже старих мережевих дисках (NAS) і Windows XP - оновіть їм прошивку або ввімкніть SMBv2' 'Shared folders on very old network drives (NAS) and Windows XP stop opening - update their firmware or enable SMBv2'))
            Fix = @{ Recipe = 'smb1-off' }
        }
        @{
            Id = 'rdp'; Title = (T 'Віддалений робочий стіл (RDP)' 'Remote Desktop (RDP)')
            Test = {
                if ((Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' 'fDenyTSConnections') -ne 0) { return Ok (T 'вимкнено' 'off') }
                $port = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' 'PortNumber'
                $nla = (Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' 'UserAuthentication') -eq 1
                $ev = @((T 'Порт: ' 'Port: ') + $port)
                if (-not $nla) { return Issue high (T 'увімкнено без NLA' 'on without NLA') (T 'Екран входу Windows доступний будь-кому в мережі ще до перевірки пароля - так атакують підбором і через вразливості RDP (BlueKeep).' 'The Windows sign-in screen is reachable by anyone on the network before any password check - used for brute force and RDP exploits (BlueKeep).') $ev }
                Issue low (T 'увімкнено (з NLA)' 'on (with NLA)') (T 'До ПК можна підключитися віддалено з паролем облікового запису. Якщо ви цим не користуєтеся - вимкніть.' 'The PC accepts remote connections with an account password. If you do not use this, turn it off.') $ev
            }
            Explain = (T 'RDP дозволяє керувати ПК з іншого комп''ютера. Відкритий в інтернет RDP - найпоширеніший спосіб, яким шифрувальники потрапляють у компанії. NLA вимагає пароль ще до показу екрана входу.' 'RDP lets another computer control the PC. RDP exposed to the internet is the most common way ransomware gets into companies. NLA requires the password before the sign-in screen appears.')
            Pros = @((T 'Вимкнений RDP або RDP з NLA закриває популярний вектор атак' 'RDP off, or RDP with NLA, closes a popular attack vector'))
            Cons = @((T 'Вимкнення: не зможете підключитися до цього ПК через «Підключення до віддаленого робочого стола»' 'Turning it off: you cannot connect to this PC with Remote Desktop Connection'))
            Fix = @{ Recipe = 'rdp-hardening'; Open = 'ms-settings:remotedesktop' }
        }
        @{
            Id = 'remote-registry'; Title = (T 'Служба «Віддалений реєстр»' 'The Remote Registry service')
            Test = {
                $s = Get-Service RemoteRegistry -ErrorAction SilentlyContinue
                if (-not $s) { return NotApplicable (T 'Служби немає в цій системі.' 'The service does not exist on this system.') }
                if ($s.Status -eq 'Running' -or $s.StartType -eq 'Automatic') { return Issue medium "$($s.Status), $($s.StartType)" (T 'З мережі можна читати і змінювати реєстр цього ПК (з паролем адміністратора).' 'The registry of this PC can be read and changed over the network (with an administrator password).') }
                Ok $(if ($s.StartType -eq 'Disabled') { T 'вимкнено' 'disabled' } else { T 'не запущено' 'not running' })
            }
            Explain = (T 'Віддалений реєстр дозволяє адміністраторам змінювати реєстр ПК по мережі. Вдома він не потрібен, а для зловмисника в мережі - зручний інструмент.' 'Remote Registry lets administrators change the PC''s registry over the network. Not needed at home, but handy for an attacker on the network.')
            Pros = @((T 'Ще одна мережева служба менше' 'One fewer network service'))
            Cons = @((T 'Деякі корпоративні інструменти адміністрування не зможуть керувати ПК' 'Some corporate management tools cannot manage the PC'))
            Fix = @{ Recipe = 'remote-registry-off' }
        }
        @{
            Id = 'network-profile'; Title = (T 'Профіль мережі' 'Network profile')
            Test = {
                $profiles = @(Get-NetConnectionProfile -ErrorAction Stop)
                $cat = @{ Public = (T 'публічна' 'public'); Private = (T 'приватна' 'private'); DomainAuthenticated = (T 'доменна' 'domain') }
                $ev = @($profiles | ForEach-Object { "$($_.Name) ($($_.InterfaceAlias)): $($cat[[string]$_.NetworkCategory])" })
                $wifiPrivate = @($profiles | Where-Object { $_.NetworkCategory -eq 'Private' -and $_.InterfaceAlias -match '(?i)wi-?fi|wlan|бездрот' })
                if ($wifiPrivate) { return Issue info (T 'Wi-Fi як приватна' 'Wi-Fi as private') (T "Мережа «$($wifiPrivate[0].Name)» позначена як приватна: ПК видно іншим пристроям у ній. Це нормально вдома, але не в кафе, готелі чи гуртожитку." "The network '$($wifiPrivate[0].Name)' is marked private: the PC is visible to other devices on it. Fine at home, but not in a café, hotel or dorm.") $ev }
                Ok $(if ($profiles | Where-Object NetworkCategory -eq 'Private') { T 'приватна' 'private' } else { T 'публічна' 'public' }) '' $ev
            }
            Explain = (T 'У «приватній» мережі Windows показує ПК іншим пристроям і дозволяє спільні папки та принтери. У «публічній» - ховає. Для чужих мереж завжди вибирайте «публічна».' 'On a "private" network Windows shows the PC to other devices and allows file and printer sharing. On a "public" one it hides it. Always choose "public" for networks you do not own.')
            Pros = @((T 'Публічний профіль у чужій мережі - ПК невидимий для інших' 'The public profile on someone else''s network keeps the PC invisible'))
            Cons = @((T 'У публічній мережі не працюють спільні папки і пошук пристроїв (Chromecast, принтери)' 'On a public network, file sharing and device discovery (Chromecast, printers) do not work'))
            Fix = @{ Open = 'ms-settings:network-status' }
        }
        @{
            Id = 'shares'; Title = (T 'Спільні папки' 'Shared folders')
            Test = {
                $shares = @(Get-CimInstance Win32_Share -ErrorAction Stop | Where-Object { $_.Type -eq 0 -and $_.Name -notmatch '\$$' })
                if (-not $shares) { return Ok (T 'немає' 'none') }
                Issue info (T "$($shares.Count) шт." "$($shares.Count)") (T 'Ці папки доступні по мережі. Переконайтеся, що серед них немає зайвих і що доступ мають лише потрібні люди.' 'These folders are available over the network. Make sure none are unneeded and only the right people have access.') @($shares | ForEach-Object { "$($_.Name) → $($_.Path)" })
            }
            Explain = (T 'Спільна папка відкриває файли іншим комп''ютерам мережі. Права доступу перевіряйте у властивостях папки → «Спільний доступ».' 'A shared folder opens files to other computers on the network. Check access rights in the folder properties → Sharing.')
            Pros = @()
            Cons = @()
            Fix = @{ Open = 'fsmgmt.msc' }
        }
        @{
            Id = 'wifi-open'; Title = (T 'Збережені відкриті Wi-Fi мережі' 'Saved open Wi-Fi networks')
            Test = {
                # Профілі експортуються без паролів (без key=clear) у тимчасову папку і одразу видаляються
                $dir = Join-Path $env:TEMP ('deadpixel-wlan-' + [guid]::NewGuid().ToString('N'))
                New-Item -ItemType Directory $dir | Out-Null
                try {
                    $null = netsh wlan export profile folder="$dir" 2>&1
                    $xml = @(Get-ChildItem $dir -Filter *.xml)
                    if ($xml.Count -eq 0) { return NotApplicable (T 'Немає Wi-Fi або збережених мереж.' 'No Wi-Fi or saved networks.') }
                    $open = @(foreach ($f in $xml) {
                        [xml]$x = Get-Content $f.FullName -Raw -Encoding UTF8
                        $auth = $x.WLANProfile.MSM.security.authEncryption.authentication
                        if ($auth -eq 'open') { [pscustomobject]@{ Name = $x.WLANProfile.name; Auto = $x.WLANProfile.connectionMode -eq 'auto' } }
                    })
                } finally { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
                if (-not $open) { return Ok (T 'немає' 'none') (T "Перевірено збережених мереж: $($xml.Count)." "Saved networks checked: $($xml.Count).") }
                $auto = @($open | Where-Object Auto)
                $ev = @($open | ForEach-Object { $_.Name + $(if ($_.Auto) { T ' (підключається автоматично)' ' (connects automatically)' } else { '' }) })
                if ($auto) { return Issue low (T "$($open.Count) шт., авто: $($auto.Count)" "$($open.Count), auto: $($auto.Count)") (T 'ПК сам підключиться до будь-якої відкритої мережі з такою назвою - зловмисник може створити точку доступу з тим самим ім''ям і бачити ваш трафік.' 'The PC will join any open network with that name by itself - an attacker can create an access point with the same name and see your traffic.') $ev }
                Issue info (T "$($open.Count) шт." "$($open.Count)") (T 'Збережені мережі без пароля. Автоматично ПК до них не підключається.' 'Saved networks without a password. The PC does not join them automatically.') $ev
            }
            Explain = (T 'Відкрита Wi-Fi мережа не шифрує трафік, а її назву легко підробити. Якщо ПК пам''ятає таку мережу з автопідключенням, він під''єднається до підробки сам.' 'An open Wi-Fi network does not encrypt traffic, and its name is easy to fake. If the PC remembers such a network with auto-connect, it will join a fake one by itself.')
            Pros = @((T 'ПК не під''єднається сам до підробленої точки доступу' 'The PC will not join a fake access point by itself'))
            Cons = @((T 'До цих мереж доведеться підключатися вручну' 'You have to join these networks manually'))
            Fix = @{ Open = 'ms-settings:network-wifisettings'; Steps = @((T '«Керування відомими мережами» → виберіть мережу → «Забути», або вимкніть «Підключатися автоматично».' '"Manage known networks" → pick the network → "Forget", or turn off "Connect automatically".')) }
        }
    )
}
