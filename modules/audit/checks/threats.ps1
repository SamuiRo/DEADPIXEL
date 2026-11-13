# Сліди зламу: індикатори відомих інцидентів і способи закріплення, яких не видно в автозавантаженні.
# Евристики - це підозри з доказами, а не вирок.

# ---------------------------------------------------------------- відомі інциденти

# Кожен інцидент: Id, Name, Date, Url (офіційне джерело індикаторів), Find = { ... } → $null (ПК не стосується) або
#   @{ Indicators = @(рядки доказів зараження); Exposure = @(рядки «був контакт, зараження не видно»); Cleanup = @(пункти); Files = @(шляхи) }
# Новий інцидент - новий блок у цьому списку; індикатори беремо лише з офіційних повідомлень виробника.

# Папки лаунчера NIKKE: з «Програм і компонентів» і типових місць у корені дисків
function Get-NikkeLauncherDirs {
    $dirs = @()
    foreach ($a in Get-InstalledApps | Where-Object { $_.DisplayName -match '^NIKKE' -or $_.Publisher -match 'Level Infinite' }) {
        $exe = Get-ExeFromCommand $a.UninstallString
        if ($exe) { $dirs += Split-Path $exe }
    }
    foreach ($d in [IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'Fixed' -and $_.IsReady }) {
        foreach ($n in Get-ChildItem -LiteralPath $d.RootDirectory.FullName -Directory -Filter 'NIKKE*' -ErrorAction SilentlyContinue) { $dirs += Join-Path $n.FullName 'Launcher' }
    }
    @($dirs | Where-Object { $_ -and (Test-Path -LiteralPath (Join-Path $_ 'intl_service')) } | ForEach-Object { (Get-Item -LiteralPath $_).FullName.TrimEnd('\') } | Sort-Object -Unique)
}

$script:Incidents = @(
    @{
        Id = 'nikke-launcher-2026'; Name = (T 'Злам лаунчера NIKKE для ПК' 'NIKKE PC launcher compromise'); Date = '2026-11-05'
        Url = 'https://nikke-en.com/newsdetail.html?content_id=ecdccd40a55a5a46aaa9abda64d436082db7'
        Find = {
            $launchers = @(Get-NikkeLauncherDirs)
            $cache = Join-Path $env:APPDATA 'nikke_launcher\tbs_cache'
            $clsid = 'HKCU:\Software\Classes\CLSID\{E77CC89B-7401-4C04-8CED-149DB35ADD04}'
            $ind = @(); $exp = @(); $clean = @(); $files = @()

            # 1. COM-запис, яким шкідлива DLL підвантажується в браузер
            if (Test-Path -LiteralPath $clsid) {
                $ind += (T 'Запис реєстру шкідливої програми: ' 'Malware registry entry: ') + 'HKCU\Software\Classes\CLSID\{E77CC89B-7401-4C04-8CED-149DB35ADD04}'
                $clean += New-CleanupItem 'RegistryKey' (T 'Запис реєстру шкідливої програми' 'Malware registry entry') @{ Target = $clsid }
            }
            # 2. DLL у профілі браузера: PlatformExperienceHelper\<64 hex>\platform_experience_helper.dll
            foreach ($r in Get-ChromiumRoots) {
                foreach ($d in Get-ChildItem -LiteralPath (Join-Path $r.Path 'PlatformExperienceHelper') -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^[0-9a-f]{64}$' }) {
                    $dll = Join-Path $d.FullName 'platform_experience_helper.dll'
                    if (-not (Test-Path -LiteralPath $dll)) { continue }
                    $ind += (T 'Шкідлива DLL у профілі браузера: ' 'Malicious DLL in the browser profile: ') + $dll
                    $clean += New-CleanupItem 'ThreatPath' ((T 'Папка зі шкідливою DLL: ' 'Folder with the malicious DLL: ') + $d.FullName) @{ Target = $d.FullName }
                    $files += $dll
                }
            }
            foreach ($l in $launchers) {
                # 3. Рядок у журналі лаунчера, який лишає шкідливий скрипт
                $log = Join-Path $l 'intl_service\debug.log'
                if (Test-Path -LiteralPath $log) {
                    $text = Read-SharedText $log
                    if ($null -eq $text) { $exp += (T 'Не вдалося прочитати журнал (завеликий або недоступний): ' 'Could not read the log (too large or unavailable): ') + $log }
                    elseif ($text.IndexOf('k2f_chan registered', [StringComparison]::Ordinal) -ge 0) { $ind += (T 'У журналі лаунчера є рядок «k2f_chan registered»: ' 'The launcher log contains "k2f_chan registered": ') + $log }
                    $text = $null
                }
                # 4. Завантажений шкідливий файл під виглядом журналу: рівно 205 135 байт
                foreach ($f in Get-ChildItem -LiteralPath (Join-Path $l 'log\tinyget') -File -Filter 'tinyget.*.log' -ErrorAction SilentlyContinue | Where-Object { $_.Length -eq 205135 }) {
                    $ind += (T 'Завантажений шкідливий файл: ' 'Downloaded malicious file: ') + $f.FullName
                    $clean += New-CleanupItem 'ThreatPath' ((T 'Шкідливий файл: ' 'Malicious file: ') + $f.FullName) @{ Target = $f.FullName }
                    $files += $f.FullName
                }
            }
            # Контакт: вбудований браузер лаунчера звертався до захопленого домену
            $state = Join-Path $cache 'Network Persistent State'
            if (Test-Path -LiteralPath $state) {
                $text = Read-SharedText $state 20MB
                if ($text -and $text.IndexOf('insightjs.com', [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                    $exp += (T 'Лаунчер звертався до захопленого домену insightjs.com (запис у його кеші).' 'The launcher contacted the hijacked domain insightjs.com (recorded in its cache).')
                    $clean += New-CleanupItem 'ThreatPath' ((T 'Кеш вбудованого браузера лаунчера: ' 'The launcher''s embedded browser cache: ') + $cache) @{ Target = $cache }
                }
            }
            if (-not $launchers -and -not $ind -and -not $exp) { return $null }
            @{ Indicators = $ind; Exposure = $exp; Cleanup = $clean; Files = $files }
        }
    }
    @{
        # Хробак у пакетах npm: preinstall запускає setup_bun.js, той - великий заплутаний bun_environment.js,
        # який краде токени GitHub/npm і ключі хмар та публікує заражені версії пакетів жертви
        Id = 'shai-hulud-2025'; Name = (T 'Хробак Shai-Hulud у пакетах npm' 'Shai-Hulud worm in npm packages'); Date = '2025-11-24'
        Url = 'https://www.stepsecurity.io/blog/sha1-hulud-the-second-coming-zapier-ens-domains-and-other-prominent-npm-packages-compromised'
        Find = {
            # Лише глобально встановлені пакети: проєкти на дисках аудит не обходить (це години на великих дисках)
            $roots = @()
            $npm = Get-Command npm -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($npm) { $roots += Join-Path (Split-Path $npm.Source) 'node_modules' }
            $roots += (Join-Path $env:APPDATA 'npm\node_modules'), (Join-Path $env:LOCALAPPDATA 'pnpm\global')
            if ($env:NVM_HOME) { $roots += @(Get-ChildItem -LiteralPath $env:NVM_HOME -Directory -Filter 'v*' -ErrorAction SilentlyContinue | ForEach-Object { Join-Path $_.FullName 'node_modules' }) }
            $roots = @($roots | Where-Object { Test-Path -LiteralPath $_ } | ForEach-Object { (Get-Item -LiteralPath $_).FullName } | Sort-Object -Unique)
            if (-not $roots) { return $null }
            $ind = @(); $files = @()
            foreach ($r in $roots) {
                foreach ($f in Find-FilesByExtension $r '.js' 600000) {
                    $name = [IO.Path]::GetFileName($f)
                    if ($name -eq 'bun_environment.js') {
                        # Справжній файл хробака - кілька мегабайт заплутаного коду; дрібний однойменний файл індикатором не вважаємо
                        if ((Get-Item -LiteralPath $f -Force).Length -lt 1MB) { continue }
                    } elseif ($name -eq 'setup_bun.js') {
                        $pkg = Read-SharedText (Join-Path (Split-Path $f) 'package.json') 2MB
                        if (-not $pkg -or $pkg -notmatch '"(pre|post)?install"\s*:\s*"[^"]*setup_bun') { continue }
                    } else { continue }
                    $ind += (T 'Файл хробака в глобально встановленому пакеті: ' 'Worm file in a globally installed package: ') + $f
                    $files += $f
                }
            }
            @{ Indicators = $ind; Exposure = @(); Cleanup = @(); Files = $files }
        }
    }
)

# ---------------------------------------------------------------- проксі

# Програми й SDK, що здають ПК в оренду як проксі-вузол: шаблон (ім'я процесу, служби, програми, автозапуску) → назва.
# Botnet - програми ботнету 911 S5 з попередження ФБР (травень 2024)
$script:Proxyware = @(
    @{ Match = '(?i)\b(MaskVPN|DewVPN|PaladinVPN|ProxyGate|ShieldVPN|ShineVPN)\b'; Name = '911 S5'; What = (T 'ботнет під виглядом безкоштовного VPN' 'a botnet posing as a free VPN'); Botnet = $true }
    @{ Match = '(?i)honeygain'; Name = 'Honeygain'; What = (T 'продаж вашого каналу' 'sells your bandwidth') }
    @{ Match = '(?i)packetstream'; Name = 'PacketStream'; What = (T 'продаж вашого каналу' 'sells your bandwidth') }
    @{ Match = '(?i)\bpawns(\.app)?\b|iproyal'; Name = 'Pawns.app (IPRoyal)'; What = (T 'продаж вашого каналу' 'sells your bandwidth') }
    @{ Match = '(?i)earnapp'; Name = 'EarnApp (Bright Data)'; What = (T 'продаж вашого каналу' 'sells your bandwidth') }
    @{ Match = '(?i)peer2profit'; Name = 'Peer2Profit'; What = (T 'продаж вашого каналу' 'sells your bandwidth') }
    @{ Match = '(?i)repocket'; Name = 'Repocket'; What = (T 'продаж вашого каналу' 'sells your bandwidth') }
    @{ Match = '(?i)traffmonetizer'; Name = 'Traffmonetizer'; What = (T 'продаж вашого каналу' 'sells your bandwidth') }
    @{ Match = '(?i)proxyrack|peerproxy'; Name = 'ProxyRack'; What = (T 'продаж вашого каналу' 'sells your bandwidth') }
    @{ Match = '(?i)bytelixir'; Name = 'ByteLixir'; What = (T 'продаж вашого каналу' 'sells your bandwidth') }
    @{ Match = '(?i)speedshare'; Name = 'SpeedShare'; What = (T 'продаж вашого каналу' 'sells your bandwidth') }
    @{ Match = '(?i)nodepay'; Name = 'Nodepay'; What = (T 'продаж вашого каналу' 'sells your bandwidth') }
    @{ Match = '(?i)getgrass|wynd ?labs|\bgrass(\.exe| desktop| node)'; Name = 'Grass'; What = (T 'продаж вашого каналу' 'sells your bandwidth') }
    @{ Match = '(?i)mysterium|\bmyst(-launcher|\.exe)'; Name = 'Mysterium Node'; What = (T 'вузол виходу чужого трафіку' 'an exit node for other people''s traffic') }
    @{ Match = '(?i)brd_sdk|brightdata|bright ?sdk|luminati|net_updater(32|64)?\.exe|lum_sdk'; Name = 'Bright Data SDK'; What = (T 'SDK проксі-мережі всередині безкоштовної програми' 'a proxy network SDK inside a free app') }
    @{ Match = '(?i)hola_svc|hola_cr|hola vpn|hola\.exe'; Name = 'Hola VPN'; What = (T 'безкоштовна версія пропускає чужий трафік (мережа Bright Data)' 'the free tier relays other people''s traffic (the Bright Data network)') }
    @{ Match = '(?i)infatica'; Name = 'Infatica SDK'; What = (T 'SDK проксі-мережі всередині безкоштовної програми' 'a proxy network SDK inside a free app') }
    @{ Match = '(?i)globalhop'; Name = 'Globalhop SDK'; What = (T 'SDK проксі-мережі всередині безкоштовної програми' 'a proxy network SDK inside a free app') }
    @{ Match = '(?i)digital ?pulse|proxynation'; Name = 'Digital Pulse'; What = (T 'проксі-вузол, що ставиться без згоди' 'a proxy node installed without consent') }
)

# ---------------------------------------------------------------- COM

# Шлях до файлу із запису InprocServer32 / LocalServer32; $null - це не шлях (наприклад, ідентифікатор програми з Магазину)
function Get-ComServerPath([string]$Value) {
    if (-not $Value) { return $null }
    $v = [Environment]::ExpandEnvironmentVariables($Value.Trim())
    if ($v.StartsWith('"')) { $end = $v.IndexOf('"', 1); if ($end -gt 1) { $v = $v.Substring(1, $end - 1) } }
    else { $m = [regex]::Match($v, '(?i)^.+?\.(dll|exe|ocx|cpl|ax)(?=\s|,|$)'); if ($m.Success) { $v = $m.Value } }
    if ($v -match '!') { return $null }
    if (-not [IO.Path]::IsPathRooted($v)) {
        # Ім'я без шляху (mscoree.dll) Windows шукає в System32
        $sys = Join-Path $env:windir "System32\$v"
        if ($v -notmatch '[\\/]' -and (Test-Path -LiteralPath $sys)) { return $sys }
        return $null
    }
    $v
}

# Довірені корені, встановлені лише для цього користувача (поза системним сховищем)
function Get-UserRootCerts {
    foreach ($k in Get-ChildItem 'HKCU:\Software\Microsoft\SystemCertificates\Root\Certificates' -ErrorAction SilentlyContinue) {
        $c = Get-Item -LiteralPath "Cert:\CurrentUser\Root\$($k.PSChildName)" -ErrorAction SilentlyContinue
        if ($c) { $c }
    }
}

@{
    Id = 'threats'; Title = (T 'Сліди зламу' 'Signs of compromise'); Order = 5.5
    Checks = @(
        @{
            Id = 'known-incidents'; Title = (T 'Відомі інциденти' 'Known incidents')
            Test = {
                $ind = @(); $exp = @(); $clean = @(); $files = @(); $names = @(); $applies = 0
                foreach ($i in $Incidents) {
                    $r = try { & $i.Find } catch { $null }
                    if (-not $r) { continue }
                    $applies++
                    $tag = "$($i.Name) ($($i.Date))"
                    if ($r.Indicators) { $ind += @($r.Indicators | ForEach-Object { "⚠ $tag - $_" }); $names += $i.Name }
                    if ($r.Exposure) { $exp += @($r.Exposure | ForEach-Object { "$tag - $_" }) }
                    if ($r.Indicators -or $r.Exposure) { $exp += (T 'Офіційні інструкції: ' 'Official instructions: ') + $i.Url }
                    $clean += @($r.Cleanup); $files += @($r.Files)
                }
                $checked = T "Перевірено інцидентів: $($Incidents.Count), стосуються цього ПК: $applies." "Incidents checked: $($Incidents.Count), relevant to this PC: $applies."
                if ($ind) {
                    return Add-Cleanup (Issue critical ($names | Select-Object -Unique | Select-Object -First 1) (T 'Знайдено сліди шкідливої програми з відомого інциденту. Вважайте паролі, сесії браузерів і ключі API з цього ПК викраденими: спершу приберіть знайдене і зробіть офлайн-сканування Defender, потім змініть паролі з іншого пристрою.' 'Traces of malware from a known incident were found. Treat passwords, browser sessions and API keys on this PC as stolen: first remove the findings and run a Defender offline scan, then change passwords from another device.') ($ind + $exp) $files) $clean
                }
                if ($exp) {
                    return Add-Cleanup (Issue low (T 'був контакт, зараження не видно' 'exposed, no infection found') ((T 'Програма з цього ПК потрапила під відомий інцидент, але жодного індикатора зараження немає. Приберіть залишки кешу; паролі важливих акаунтів, збережені в браузерах, варто змінити для певності. ' 'A program on this PC was affected by a known incident, but no infection indicator is present. Remove the cache leftovers; for certainty, change browser-saved passwords of important accounts. ') + $checked) $exp) $clean
                }
                Ok (T 'слідів немає' 'no traces') $checked
            }
            Explain = (T 'Коли зламують виробника програми (лаунчер гри, оновлювач, бібліотеку), шкідливий код приходить через легітимну, підписану програму - антивірус може мовчати тижнями. Виробник згодом публікує точні сліди (файли, записи реєстру, рядки в журналах). Аудит шукає саме їх. Список інцидентів оновлюється разом із DEADPIXEL.' 'When a software vendor is breached (a game launcher, an updater, a library), malicious code arrives through a legitimate, signed program - the antivirus may stay silent for weeks. The vendor later publishes exact traces (files, registry entries, log lines). The audit looks for exactly those. The incident list is updated with DEADPIXEL.')
            Pros = @((T 'Точні індикатори від виробника - майже без хибних тривог' 'Exact vendor indicators - almost no false alarms'), (T 'Знаходить те, що антивірус пропустив' 'Finds what the antivirus missed'))
            Cons = @((T 'Чистий результат не гарантує, що зараження не було: шкідлива програма могла прибрати сліди' 'A clean result does not guarantee there was no infection: malware may have removed its traces'), (T 'Покриває лише інциденти зі списку' 'Covers only the incidents on the list'))
            Fix = @{ Open = 'windowsdefender://threat'; Steps = @(
                (T 'Закрийте заражену програму і всі браузери, потім приберіть знайдене кнопкою «Прибрати» (через карантин - можна відновити).' 'Close the affected program and all browsers, then remove the findings with "Clean up" (through quarantine - restorable).'),
                (T 'Запустіть повне сканування і «Автономну перевірку Microsoft Defender» (Безпека Windows → Захист від вірусів і загроз → Параметри сканування).' 'Run a full scan and a "Microsoft Defender Offline scan" (Windows Security → Virus & threat protection → Scan options).'),
                (T 'Якщо знайдено індикатори зараження: з іншого пристрою змініть паролі, завершіть усі сесії («вийти на всіх пристроях») і перевипустіть ключі API та токени.' 'If infection indicators were found: from another device change passwords, end all sessions ("sign out everywhere") and reissue API keys and tokens.')
            ) }
        }
        @{
            Id = 'com-hijack'; Title = (T 'Перехоплення COM-компонентів' 'COM component hijacking')
            Test = {
                $flagged = @(); $shadow = @(); $count = 0; $clean = @()
                foreach ($root in 'HKCU:\Software\Classes\CLSID', 'HKCU:\Software\Classes\WOW6432Node\CLSID') {
                    $base = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($root.Substring(6))
                    if (-not $base) { continue }
                    foreach ($id in $base.GetSubKeyNames()) {
                        $k = $base.OpenSubKey($id)
                        if (-not $k) { continue }
                        $why = @(); $points = 0; $path = $null; $inproc = $false
                        # Напряму через .NET: Get-ItemProperty на сотнях ключів без потрібного підрозділу - це секунди на винятках
                        $subs = $k.GetSubKeyNames()
                        $scriptlet = $null
                        foreach ($sub in 'InprocServer32', 'LocalServer32', 'ScriptletURL') {
                            if ($subs -notcontains $sub) { continue }
                            $sk = $k.OpenSubKey($sub)
                            if (-not $sk) { continue }
                            $v = [string]$sk.GetValue('')
                            $sk.Close()
                            if (-not $v) { continue }
                            # Компонент-скрипт з інтернету - у звичайних програм не трапляється
                            if ($sub -eq 'ScriptletURL') { $scriptlet = $v; continue }
                            if (-not $path) { $path = Get-ComServerPath $v; if ($path) { $inproc = $sub -eq 'InprocServer32' } }
                        }
                        $k.Close()
                        if ($scriptlet) { $points += 5; $why += (T "виконує скрипт: $scriptlet" "runs a script: $scriptlet") }
                        if (-not $path -and -not $points) { continue }
                        $count++
                        # Той самий CLSID є в системному реєстрі: запис користувача має перевагу - це і є перехоплення
                        $machine = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Classes\$(if ($root -match 'WOW6432') { 'WOW6432Node\' })CLSID\$id"
                        $isShadow = Test-Path -LiteralPath $machine
                        if ($path) {
                            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { if (-not $isShadow -and -not $points) { continue } ; $why += (T 'файлу немає' 'the file is missing') }
                            else {
                                $sig = Get-FileSignature $path
                                $inWindows = $path.ToLowerInvariant().StartsWith($env:windir.ToLowerInvariant() + '\')
                                $trusted = $sig -and $sig.Status -eq 'Valid'
                                # Небезпечний лише файл там, куди може писати звичайна програма: у Program Files і WindowsApps
                                # (програми з Магазину підписані каталогом, а не кожен файл) без прав адміністратора нічого не підкласти.
                                # DLL (InprocServer32) завантажується в чужі процеси; exe (LocalServer32) - окрема програма, ризик нижчий
                                if (-not $trusted -and -not $inWindows -and (Test-WritableByUsers (Split-Path $path))) {
                                    $points += $(if ($isShadow) { 5 } elseif ($inproc) { 3 } else { 1 })
                                    $why += $(if ($sig -and $sig.Status -ne 'NotSigned') { T "підпис недійсний ($($sig.Status))" "invalid signature ($($sig.Status))" } else { T 'файл без цифрового підпису' 'the file has no digital signature' })
                                    $loc = Get-PathRisk $path
                                    if ($loc.Points) { $points += 1; $why += $loc.Why }
                                }
                                if ($isShadow -and $trusted) { $shadow += "$id → $path ($($sig.Signer))" }
                            }
                        }
                        if ($isShadow -and $points) { $why += (T 'підміняє системний компонент із таким самим ідентифікатором' 'overrides a system component with the same identifier') }
                        $sev = Get-RiskSeverity $points
                        if ($sev) {
                            $flagged += [pscustomobject]@{ Sev = $sev; Path = $path; Line = "⚠ $id → $(if ($path) { $path } else { '?' })  [$($why -join '; ')]" }
                            $clean += New-CleanupItem 'RegistryKey' "COM $id → $path" @{ Target = "$root\$id" } $false
                        }
                    }
                }
                $note = T "Перевірено записів користувача: $count." "Per-user entries checked: $count."
                if ($flagged) {
                    $rank = @{ medium = 1; high = 2 }
                    $sev = ($flagged | Sort-Object { -$rank[$_.Sev] } | Select-Object -First 1).Sev
                    return Add-Cleanup (Issue $sev (T "$($flagged.Count) шт." "$($flagged.Count)") ((T 'Компоненти, зареєстровані лише для вашого користувача, які вказують на непідписані файли. Windows і браузери завантажують такі DLL у свої процеси автоматично - це улюблений спосіб закріплення викрадачів паролів. Це підозра: перевірте файл Defender''ом і згадайте, чи встановлювали програму, якій він належить. ' 'Components registered only for your user that point to unsigned files. Windows and browsers load such DLLs into their processes automatically - a favorite persistence method of password stealers. This is a suspicion: scan the file with Defender and recall whether you installed the program it belongs to. ') + $note) (@($flagged | ForEach-Object Line) + $shadow) @($flagged | ForEach-Object Path)) $clean
                }
                Ok (T 'не знайдено' 'none found') $note $shadow
            }
            Explain = (T 'COM - механізм, яким програми Windows підключають компоненти одна одної за ідентифікатором (CLSID). Запис у розділі користувача (HKCU) має перевагу над системним і не потребує прав адміністратора: шкідлива програма реєструє свою DLL, і її сам завантажує Провідник, браузер чи планувальник. В автозавантаженні цього не видно. Саме так закріплювалася шкідлива програма з лаунчера NIKKE (2026).' 'COM is how Windows programs load each other''s components by identifier (CLSID). An entry in the user hive (HKCU) takes priority over the system one and needs no administrator rights: malware registers its DLL, and Explorer, a browser or the scheduler loads it by itself. Startup lists do not show it. This is how the NIKKE launcher malware (2026) persisted.')
            Pros = @((T 'Ловить закріплення, якого не показують ні Диспетчер завдань, ні автозавантаження' 'Catches persistence that neither Task Manager nor Startup shows'))
            Cons = @((T 'Можливі хибні тривоги: маленькі утиліти з непідписаними розширеннями Провідника' 'False alarms are possible: small utilities with unsigned Explorer extensions'))
            Fix = @{ Open = 'windowsdefender://threat'; Steps = @(
                (T '«Перевірити Defender''ом» файл зі списку. Якщо це програма, яку ви встановлювали, - додайте знахідку в «Ігнорувати».' '"Scan with Defender" the listed file. If it belongs to a program you installed, add the finding to "Ignore".'),
                (T 'Не впізнаєте - приберіть запис кнопкою «Прибрати» (карантин, можна відновити), перезавантажте ПК і зробіть повне сканування.' 'If you do not recognize it, remove the entry with "Clean up" (quarantine, restorable), restart the PC and run a full scan.')
            ) }
        }
        @{
            Id = 'browser-planted-files'; Title = (T 'Сторонні програми в профілях браузерів' 'Foreign executables in browser profiles')
            Test = {
                $roots = @(Get-ChromiumRoots)
                if (-not $roots) { return NotApplicable (T 'Браузерів на Chromium не знайдено.' 'No Chromium-based browsers found.') }
                $bad = @(); $total = 0
                foreach ($r in $roots) {
                    foreach ($f in Find-FilesByExtension $r.Path '.dll;.exe;.scr;.cpl') {
                        $total++
                        $sig = Get-FileSignature $f
                        if ($sig -and $sig.Status -eq 'Valid') { continue }
                        $hex = (Split-Path (Split-Path $f) -Leaf) -match '^[0-9a-f]{64}$'
                        $status = if ($sig -and $sig.Status -ne 'NotSigned') { T "підпис недійсний ($($sig.Status))" "invalid signature ($($sig.Status))" } else { T 'без підпису' 'unsigned' }
                        $bad += [pscustomobject]@{ Sev = $(if ($hex) { 'high' } else { 'medium' }); Path = $f; Line = "⚠ $($r.Name): $f  [$status]" }
                    }
                }
                $note = T "Перевірено виконуваних файлів у профілях: $total." "Executable files checked in profiles: $total."
                if (-not $bad) { return Ok (T 'не знайдено' 'none found') $note }
                $sev = if ($bad | Where-Object Sev -eq 'high') { 'high' } else { 'medium' }
                $clean = @($bad | ForEach-Object { New-CleanupItem 'ThreatPath' $_.Path @{ Target = $_.Path } $false })
                Add-Cleanup (Issue $sev (T "$($bad.Count) шт." "$($bad.Count)") ((T 'У папці даних браузера лежать програми без дійсного підпису. Справжні компоненти браузера (Widevine, оновлення) завжди підписані виробником; непідписана DLL тут - типова схованка викрадачів паролів і сесій. ' 'The browser data folder holds programs without a valid signature. Genuine browser components (Widevine, updates) are always vendor-signed; an unsigned DLL here is a typical hiding place of password and session stealers. ') + $note) @($bad | ForEach-Object Line) @($bad | ForEach-Object Path)) $clean
            }
            Explain = (T 'Папка профілю браузера - це дані: закладки, історія, кеш. Програм там майже не буває, а ті, що є, підписані Google, Microsoft чи іншим виробником браузера. Шкідливі програми кладуть туди DLL, бо антивірусні винятки й звичка «це ж папка браузера» грають на їхню користь.' 'A browser profile folder is data: bookmarks, history, cache. It rarely contains programs, and those it does are signed by Google, Microsoft or another browser vendor. Malware drops DLLs there because antivirus exclusions and the "it is just the browser folder" habit work in its favor.')
            Pros = @((T 'Знаходить викрадачів паролів, що маскуються під компонент браузера' 'Finds password stealers disguised as a browser component'))
            Cons = @((T 'Рідкісні розширення з власними непідписаними модулями дадуть хибну тривогу' 'Rare extensions with their own unsigned modules cause a false alarm'))
            Fix = @{ Open = 'windowsdefender://threat'; Steps = @(
                (T '«Перевірити Defender''ом» кожен файл зі списку.' '"Scan with Defender" each listed file.'),
                (T 'Закрийте браузер, приберіть файл кнопкою «Прибрати» (карантин), зробіть повне сканування і змініть паролі, збережені в цьому браузері.' 'Close the browser, remove the file with "Clean up" (quarantine), run a full scan and change the passwords saved in this browser.')
            ) }
        }
        @{
            Id = 'hosts-file'; Title = (T 'Файл hosts' 'The hosts file')
            Test = {
                $file = Join-Path $env:windir 'System32\drivers\etc\hosts'
                if (-not (Test-Path -LiteralPath $file)) { return Ok (T 'немає' 'absent') }
                $redirect = @(); $security = @(); $blocks = 0
                $protected = '(?i)(microsoft\.com|windowsupdate|windows\.com|live\.com|defender|virustotal|kaspersky|eset\.|avast|avg\.com|malwarebytes|bitdefender|drweb|norton|mcafee|sophos|google\.com|googleapis|apple\.com|github\.com|paypal|privatbank|privat24|monobank|binance|\.gov(\.|$)|diia)'
                foreach ($line in Get-Content -LiteralPath $file -ErrorAction Stop) {
                    $l = ($line -replace '#.*$', '').Trim()
                    if (-not $l) { continue }
                    $parts = $l -split '\s+'
                    if ($parts.Count -lt 2) { continue }
                    $ip = $parts[0]
                    $local = $ip -match '^(127\.|0\.0\.0\.0$|::1$|::$)'
                    foreach ($h in $parts[1..($parts.Count - 1)]) {
                        if ($h -match '^(localhost|.*\.localhost|.*\.local|.*\.test|.*\.internal|host\.docker\.internal|gateway\.docker\.internal|kubernetes\.docker\.internal)$') { continue }
                        if (-not $local) { $redirect += "⚠ $h → $ip" }
                        elseif ($h -match $protected -and $h -notmatch '(?i)telemetry|vortex|watson|ads?\.|adservice|doubleclick|analytics|activity|settings-win|data\.microsoft') { $security += "⚠ $h → $ip" + (T ' (заблоковано)' ' (blocked)') }
                        else { $blocks++ }
                    }
                }
                $note = if ($blocks) { T "Ще $blocks записів просто блокують сайти (реклама, телеметрія, активація програм)." "Another $blocks entries merely block sites (ads, telemetry, software activation)." } else { '' }
                if ($security) { return Issue high (T "заблоковано важливих: $($security.Count)" "important blocked: $($security.Count)") ((T 'hosts блокує сайти оновлень, антивірусів або акаунтів. Так шкідливі програми не дають оновити захист; так само роблять «активатори». ' 'hosts blocks update, antivirus or account sites. Malware does this to stop protection updates; so do "activators". ') + $note) ($security + $redirect) }
                if ($redirect) { return Issue medium (T "перенаправлень: $($redirect.Count)" "redirects: $($redirect.Count)") ((T 'Ці адреси сайтів ведуть на вказані IP замість справжніх. Нормально для власних серверів розробника і домашньої мережі; небезпечно, якщо ви цього не налаштовували - так підміняють сайти банків. ' 'These site names lead to the listed IPs instead of the real ones. Normal for a developer''s own servers and a home network; dangerous if you did not set it up - this is how bank sites get spoofed. ') + $note) $redirect }
                Ok $(if ($blocks) { T "лише блокування ($blocks)" "blocks only ($blocks)" } else { T 'чистий' 'clean' }) $note
            }
            Explain = (T 'Файл hosts має перевагу над DNS: рядок у ньому може перенаправити будь-який сайт на іншу адресу або заблокувати його. Для зміни потрібні права адміністратора, тож запис, якого ви не робили, - слід програми з такими правами.' 'The hosts file takes priority over DNS: a line in it can redirect any site to another address or block it. Changing it needs administrator rights, so an entry you did not make is a trace of a program that had them.')
            Pros = @((T 'Видно підміну сайтів і блокування оновлень захисту' 'Reveals site spoofing and blocked protection updates'))
            Cons = @((T 'Видалення блокувань від «активаторів» може зняти неліцензійну активацію програм' 'Removing "activator" blocks may undo unlicensed software activation'))
            Fix = @{ Steps = @((T 'Відкрийте Блокнот від імені адміністратора → Файл → Відкрити → C:\Windows\System32\drivers\etc\hosts (тип «Усі файли») і видаліть рядки, яких не додавали.' 'Open Notepad as administrator → File → Open → C:\Windows\System32\drivers\etc\hosts (type "All files") and delete lines you did not add.')) }
        }
        @{
            Id = 'proxy'; Title = (T 'Проксі-сервер системи' 'System proxy')
            Test = {
                $k = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
                $pac = Get-RegValue $k 'AutoConfigURL'
                $server = if ([int](Get-RegValue $k 'ProxyEnable') -eq 1) { [string](Get-RegValue $k 'ProxyServer') } else { '' }
                $ev = @()
                if ($pac) { $ev += (T 'Скрипт автоналаштування: ' 'Auto-config script: ') + $pac }
                if ($server) { $ev += (T 'Проксі: ' 'Proxy: ') + $server }
                if (-not $ev) { return Ok (T 'не використовується' 'not used') }
                $remote = ($pac -and $pac -notmatch '(?i)^(file:|https?://(127\.|localhost|\[::1\]))') -or ($server -and ($server -split ';' | Where-Object { $_ -and ($_ -replace '^[a-z]+=', '') -notmatch '^(127\.|localhost|\[::1\])' }))
                if ($remote) { return Issue medium (T 'зовнішній проксі' 'external proxy') (T 'Весь трафік браузерів і програм іде через чужий сервер: його власник бачить, які сайти ви відкриваєте, а разом зі стороннім кореневим сертифікатом - і вміст. Нормально, якщо це робочий або ваш VPN/проксі.' 'All browser and program traffic goes through someone else''s server: its owner sees which sites you open and, together with a foreign root certificate, the content too. Normal if it is your work or your own VPN/proxy.') $ev }
                Issue info (T 'локальний проксі' 'local proxy') (T 'Трафік проходить через програму на цьому ПК (VPN-клієнт, блокувальник реклами, засіб налагодження). Переконайтеся, що знаєте, яка це програма.' 'Traffic passes through a program on this PC (a VPN client, ad blocker, debugging tool). Make sure you know which program it is.') $ev
            }
            Explain = (T 'Системний проксі - посередник між вашими програмами та інтернетом. Шкідливі програми вмикають його, щоб читати й підміняти сторінки (наприклад, реквізити платежу).' 'A system proxy is an intermediary between your programs and the internet. Malware turns one on to read and alter pages (for example, payment details).')
            Pros = @((T 'Видно, якщо трафік тихо завернули через чужий сервер' 'Reveals traffic silently routed through a foreign server'))
            Cons = @((T 'Вимкнення проксі зламає VPN або робочий доступ, які його використовують' 'Turning the proxy off breaks a VPN or work access that relies on it'))
            Fix = @{ Open = 'ms-settings:network-proxy' }
        }
        @{
            Id = 'proxyware'; Title = (T 'ПК як чужий проксі-сервер' 'The PC as someone else''s proxy')
            Test = {
                $hits = @{}; $botnet = $false
                $add = {
                    param([string]$text, [string]$where)
                    foreach ($p in $Proxyware) {
                        if ($text -notmatch $p.Match) { continue }
                        if ($p.Botnet) { Set-Variable botnet $true -Scope 1 }
                        $key = "$($p.Name) - $($p.What)"
                        if (-not $hits.ContainsKey($key)) { $hits[$key] = @() }
                        $hits[$key] += $where
                        break
                    }
                }
                foreach ($p in (Get-ProcessTable).Values) { if ($p.Name) { & $add "$($p.Name) $($p.ExecutablePath)" ((T 'процес ' 'process ') + "$($p.Name) (PID $($p.ProcessId))") } }
                foreach ($s in Get-CimInstance Win32_Service -ErrorAction SilentlyContinue) { & $add "$($s.Name) $($s.DisplayName) $($s.PathName)" ((T 'служба ' 'service ') + "$($s.Name), $($s.State)") }
                foreach ($a in Get-InstalledApps) { & $add "$($a.DisplayName)" ((T 'встановлено: ' 'installed: ') + $a.DisplayName) }
                foreach ($k in 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run', 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run', 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run') {
                    $pr = Get-ItemProperty $k -ErrorAction SilentlyContinue
                    if ($pr) { foreach ($x in $pr.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' }) { & $add "$($x.Name) $($x.Value)" ((T 'автозапуск ' 'startup ') + $x.Name) } }
                }
                foreach ($t in Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskPath -notlike '\Microsoft\*' }) { & $add "$($t.TaskName) $(@($t.Actions | ForEach-Object { $_.Execute }) -join ' ')" ((T 'завдання ' 'task ') + $t.TaskName) }
                if ($hits.Count -eq 0) { return Limited (Ok (T 'не знайдено' 'none found') (T "Перевірено за списком із $($Proxyware.Count) відомих програм і SDK." "Checked against a list of $($Proxyware.Count) known programs and SDKs.")) }
                $ev = foreach ($k in $hits.Keys | Sort-Object) { "⚠ $k"; $hits[$k] | Sort-Object -Unique | Select-Object -First 6 | ForEach-Object { "     $_" } }
                if ($botnet) { return Issue high (T "$($hits.Count) шт." "$($hits.Count)") (T 'Знайдено програму з ботнету 911 S5: «безкоштовний VPN», який продавав доступ до ПК користувачів як проксі для шахрайства (ліквідований ФБР у 2024). Видаліть її, зробіть повне сканування і перевірте, чи ваша IP-адреса не потрапила в чорні списки.' 'A program from the 911 S5 botnet was found: a "free VPN" that sold access to users'' PCs as proxies for fraud (taken down by the FBI in 2024). Remove it, run a full scan and check whether your IP address was blacklisted.') $ev }
                Issue medium (T "$($hits.Count) шт." "$($hits.Count)") (T 'Ці програми пропускають через ваш ПК і вашу IP-адресу чужий інтернет-трафік: за гроші («заробіток на інтернеті») або непомітно, як плата за «безкоштовний» VPN чи програму. Що саме йде через вашу адресу, ви не контролюєте - шахрайство, обхід блокувань, атаки на сайти записуються на вас. Якщо ставили свідомо - додайте в «Ігнорувати».' 'These programs route other people''s internet traffic through your PC and your IP address: for money ("earn from your internet") or quietly, as the price of a "free" VPN or app. You do not control what goes through your address - fraud, block evasion, attacks on sites are attributed to you. If you installed it knowingly, add it to "Ignore".') $ev
            }
            Explain = (T '«Резидентні проксі» - це мережі з домашніх ПК, через які клієнти сервісу виходять в інтернет з чужої адреси. ПК потрапляє туди трьома шляхами: програма «пасивного заробітку» (Honeygain, Pawns, EarnApp), SDK у безкоштовній програмі чи VPN (Bright Data, Infatica - згода захована в ліцензії) або шкідлива програма. Перевірка разова й порівнює процеси, служби, програми й автозапуск зі списком - ПК вона не навантажує.' '"Residential proxies" are networks of home PCs through which a service''s customers reach the internet from someone else''s address. A PC ends up there in three ways: a "passive income" app (Honeygain, Pawns, EarnApp), an SDK inside a free app or VPN (Bright Data, Infatica - consent buried in the license) or malware. The check is one-off and compares processes, services, programs and startup entries against a list - it puts no load on the PC.')
            Pros = @((T 'Ваша IP-адреса не відповідає за чужі дії' 'Your IP address does not answer for other people''s actions'), (T 'Канал і трафік лишаються вашими' 'Your bandwidth and traffic stay yours'))
            Cons = @((T 'Список неповний: нову або перейменовану програму він не впізнає - тому поруч є перевірка «Пересилання трафіку»' 'The list is incomplete: it will not recognize a new or renamed program - hence the "Traffic forwarding" check next to it'), (T '«Безкоштовна» програма без свого SDK може попросити оплату або перестати працювати' 'A "free" app without its SDK may ask for payment or stop working'))
            Fix = @{ Open = 'ms-settings:appsfeatures'; Steps = @((T 'Видаліть програму через «Програми». Якщо це SDK усередині іншої програми (Bright Data в безкоштовних VPN і програвачах) - вимкніть «ділитися ресурсами» в її налаштуваннях або видаліть і її.' 'Uninstall the program through Apps. If it is an SDK inside another program (Bright Data in free VPNs and players), turn off "share resources" in its settings or remove that program too.')) }
        }
        @{
            Id = 'traffic-forwarding'; Title = (T 'Пересилання трафіку через ПК' 'Traffic forwarding through the PC')
            Test = {
                $ev = @(); $sev = $null
                # Правила netsh portproxy: вхідні з'єднання на порт ПК пересилаються на іншу адресу
                foreach ($k in Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services\PortProxy' -Recurse -ErrorAction SilentlyContinue) {
                    foreach ($n in $k.GetValueNames()) {
                        $to = [string]$k.GetValue($n)
                        $local = $n -match '^(127\.|localhost|::1)' -or $to -match '^(127\.|localhost|::1|172\.(1[6-9]|2\d|3[01])\.|192\.168\.|10\.)'
                        $ev += $(if ($local) { '' } else { '⚠ ' }) + (T 'Правило пересилання: ' 'Forwarding rule: ') + "$n → $to"
                        if (-not $local) { $sev = 'medium' } elseif (-not $sev) { $sev = 'info' }
                    }
                }
                if ([int](Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters' 'IPEnableRouter') -eq 1) {
                    $ev += (T 'Маршрутизацію IP увімкнено: ПК пересилає пакети між мережами (потрібно для спільного доступу, Hyper-V, деяких VPN).' 'IP routing is on: the PC forwards packets between networks (needed for connection sharing, Hyper-V, some VPNs).')
                    if (-not $sev) { $sev = 'info' }
                }
                $ics = Get-Service SharedAccess -ErrorAction SilentlyContinue
                if ($ics -and $ics.Status -eq 'Running') { $ev += (T 'Спільний доступ до інтернету (ICS) працює: інші пристрої виходять в інтернет через цей ПК (мобільний хот-спот).' 'Internet Connection Sharing (ICS) is running: other devices reach the internet through this PC (mobile hotspot).'); if (-not $sev) { $sev = 'info' } }
                # Типові порти проксі-серверів, відкриті для всієї мережі
                $ports = @{ 1080 = 'SOCKS'; 1081 = 'SOCKS'; 3128 = 'HTTP proxy'; 8118 = 'Privoxy'; 8888 = 'HTTP proxy'; 9050 = 'Tor SOCKS'; 9150 = 'Tor SOCKS'; 10808 = 'SOCKS (v2ray)'; 10809 = 'HTTP (v2ray)'; 7890 = 'Clash'; 3389 = $null }
                $procs = Get-ProcessTable
                foreach ($c in Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object { $ports[[int]$_.LocalPort] -and $_.LocalAddress -in '0.0.0.0', '::' } | Sort-Object LocalPort -Unique) {
                    $p = $procs[[int]$c.OwningProcess]
                    $ev += '⚠ ' + (T "Порт $($c.LocalPort) ($($ports[[int]$c.LocalPort])) відкритий для всієї мережі - " "Port $($c.LocalPort) ($($ports[[int]$c.LocalPort])) is open to the whole network - ") + $(if ($p) { "$($p.Name) (PID $($c.OwningProcess))" } else { "PID $($c.OwningProcess)" })
                    if ($sev -ne 'medium') { $sev = 'low' }
                }
                if (-not $ev) { return Ok (T 'не знайдено' 'none found') }
                if ($sev -eq 'info') { return Issue info (T "$($ev.Count) шт." "$($ev.Count)") (T 'ПК налаштований пересилати трафік, але лише всередині себе або домашньої мережі. Нормально для WSL, Docker, Hyper-V і хот-спота - якщо ви ними користуєтеся.' 'The PC is set to forward traffic, but only within itself or the home network. Normal for WSL, Docker, Hyper-V and a hotspot - if you use them.') $ev }
                Issue $sev (T "$($ev.Count) шт." "$($ev.Count)") (T 'Позначене ⚠ дозволяє іншим пристроям виходити в інтернет або в мережу через цей ПК. Так працюють і власні VPN/проксі для інших ваших пристроїв, і шкідливі програми, що перетворюють ПК на проксі-вузол. Переконайтеся, що налаштовували це самі; чи пропускає порт брандмауер, показує перевірка «Програми, що приймають з''єднання».' 'What is marked ⚠ lets other devices reach the internet or the network through this PC. That is how your own VPN/proxy for your other devices works - and how malware turns a PC into a proxy node. Make sure you set it up yourself; whether the firewall lets the port through is shown by the "Programs accepting network connections" check.') $ev
            }
            Explain = (T 'Щоб ПК став проксі, не потрібна окрема програма зі списку: досить правила пересилання портів у Windows (netsh portproxy), увімкненої маршрутизації або процесу, що слухає типовий порт проксі (SOCKS 1080, HTTP 3128, Tor 9050) для всієї мережі. Ця перевірка шукає саме механізм, а не назву.' 'For a PC to become a proxy no listed program is needed: a Windows port forwarding rule (netsh portproxy), IP routing turned on, or a process listening on a typical proxy port (SOCKS 1080, HTTP 3128, Tor 9050) for the whole network is enough. This check looks for the mechanism, not the name.')
            Pros = @((T 'Ловить і невідомі програми - за тим, як вони працюють' 'Catches unknown programs too - by how they work'))
            Cons = @((T 'Правила пересилання часто створюють WSL і засоби розробки - тоді це не загроза' 'Forwarding rules are often created by WSL and development tools - then it is not a threat'))
            Fix = @{ Steps = @(
                (T 'Правила пересилання: netsh interface portproxy show all; видалити все зайве: netsh interface portproxy reset (командний рядок від адміністратора).' 'Forwarding rules: netsh interface portproxy show all; remove everything unneeded: netsh interface portproxy reset (administrator command prompt).'),
                (T 'Для відкритого порту проксі: у налаштуваннях програми вимкніть «Дозволити підключення з локальної мережі» (Allow LAN) або прив''яжіть її до 127.0.0.1.' 'For an open proxy port: in the program''s settings turn off "Allow connections from LAN" or bind it to 127.0.0.1.')
            ) }
        }
        @{
            Id = 'user-root-certs'; Title = (T 'Сторонні кореневі сертифікати' 'Foreign root certificates')
            Test = {
                $certs = @(Get-UserRootCerts)
                if (-not $certs) { return Ok (T 'немає' 'none') }
                $dev = '(?i)localhost|mkcert|ASP\.NET|IIS Express|Development'
                $ev = @($certs | ForEach-Object { $(if ($_.Subject -match $dev) { '' } else { '⚠ ' }) + "$($_.GetNameInfo('SimpleName', $false)) - " + (T 'до ' 'until ') + $_.NotAfter.ToString('dd.MM.yyyy') + ", $($_.Thumbprint.Substring(0, 12))…" })
                $foreign = @($certs | Where-Object { $_.Subject -notmatch $dev })
                if ($foreign) { return Issue low (T "$($certs.Count) шт." "$($certs.Count)") (T 'Власник такого сертифіката може видати себе за будь-який сайт (банк, пошту) і читати зашифрований трафік цього користувача. Їх ставлять антивіруси, засоби налагодження (Fiddler, Charles), корпоративні проксі - і шкідливі програми. Впізнайте кожен.' 'The owner of such a certificate can impersonate any site (bank, mail) and read this user''s encrypted traffic. They are installed by antivirus products, debugging tools (Fiddler, Charles), corporate proxies - and malware. Make sure you recognize each one.') $ev }
                Issue info (T "лише для розробки: $($certs.Count)" "development only: $($certs.Count)") (T 'Сертифікати для локальної розробки (localhost). Їх приватний ключ лежить на цьому ПК - не діліться ним.' 'Local development (localhost) certificates. Their private key is on this PC - do not share it.') $ev
            }
            Explain = (T 'Кореневий сертифікат - це «я довіряю всьому, що підписав цей видавець». Системні корені керує Microsoft; корінь, доданий лише для вашого користувача, встановила якась програма без прав адміністратора.' 'A root certificate means "I trust everything this issuer signs". System roots are managed by Microsoft; a root added only for your user was installed by some program without administrator rights.')
            Pros = @((T 'Видно, хто може розшифровувати ваш HTTPS-трафік' 'Shows who can decrypt your HTTPS traffic'))
            Cons = @((T 'Видалення сертифіката зламає програму, яка його встановила (налагоджувач, локальний сервер розробки)' 'Removing a certificate breaks the program that installed it (a debugger, a local development server)'))
            Fix = @{ Open = 'certmgr.msc'; Steps = @((T 'certmgr.msc → «Довірені кореневі центри сертифікації» → «Сертифікати»: видаліть ті, які не впізнаєте (звіряйте за відбитком зі списку доказів).' 'certmgr.msc → Trusted Root Certification Authorities → Certificates: delete the ones you do not recognize (match the thumbprint from the evidence list).')) }
        }
    )
}
