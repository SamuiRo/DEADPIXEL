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
