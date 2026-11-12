# Програми й драйвери: застарілі версії, програми без підтримки, проблемні драйвери.

# winget перевіряє оновлення 10-20 с і ходить в інтернет (каталог Microsoft) - запускаємо його в Prepare,
# щоб він працював паралельно з рештою перевірок
$script:Winget = $null
function Start-Winget {
    $exe = (Get-Command winget.exe -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    if (-not $exe) { return }
    $psi = New-Object Diagnostics.ProcessStartInfo $exe, 'upgrade --include-unknown --accept-source-agreements --disable-interactivity'
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    $p = [Diagnostics.Process]::Start($psi)
    $script:Winget = @{ Process = $p; Out = $p.StandardOutput.ReadToEndAsync(); Err = $p.StandardError.ReadToEndAsync() }
}

# Таблиця winget: колонки визначаємо за позиціями слів у заголовку над рядком «-----»
# (назви колонок перекладені, а позиції - ні). Прогрес-індикатор переписує рядок через \r - беремо останню частину
function ConvertFrom-WingetTable([string]$text) {
    $lines = @($text -split "`n" | ForEach-Object { ($_.TrimEnd("`r") -split "`r")[-1] })
    $res = @()
    for ($i = 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -notmatch '^-{10,}') { continue }
        $starts = @([regex]::Matches($lines[$i - 1], '\S+') | ForEach-Object { $_.Index })
        if ($starts.Count -lt 4) { continue }
        for ($j = $i + 1; $j -lt $lines.Count; $j++) {
            $l = $lines[$j]
            if (-not $l.Trim() -or $l.Length -le $starts[3]) { break }
            $cells = for ($k = 0; $k -lt 4; $k++) {
                $to = if ($k + 1 -lt $starts.Count) { [Math]::Min($starts[$k + 1], $l.Length) } else { $l.Length }
                $l.Substring($starts[$k], $to - $starts[$k]).Trim()
            }
            $res += [pscustomobject]@{ Name = $cells[0]; Id = $cells[1]; Version = $cells[2]; Available = $cells[3] }
        }
    }
    $res
}

# Програми, де застаріла версія - пряма діра: браузери, архіватори, месенджери, засоби віддаленого доступу, рантайми
$script:SensitiveIds = '(?i)^(Google\.Chrome|Mozilla\.(Firefox|Thunderbird)|Microsoft\.Edge|Brave\.|Opera\.|Vivaldi|7zip|RARLab|Oracle\.|EclipseAdoptium|Amazon\.Corretto|Microsoft\.OpenJDK|Adobe\.Acrobat|VideoLAN\.VLC|Zoom\.|Notepad\+\+|PuTTY|WinSCP|OpenJS\.NodeJS|Python\.Python|Git\.Git|Telegram\.|OpenWhisperSystems\.Signal|Discord\.|TheDocumentFoundation|KeePass|DominikReichl|TeamViewer|AnyDesk|Mobatek|qBittorrent|PostgreSQL\.PostgreSQL|Microsoft\.DotNet\.|Session\.Session|Microsoft\.PowerShell|Microsoft\.OpenSSH|Valve\.Steam)'

# Кінець підтримки за назвою встановленої програми → @{ Label; End; Sev } або $null. Джерело - сторінки Lifecycle виробників.
function Get-EolInfo([string]$name) {
    if ($name -match '^Python (\d+)\.(\d+)\.\d+') {
        $v = "$($Matches[1]).$($Matches[2])"
        $end = @{ '3.7' = '2023-06-27'; '3.8' = '2024-10-07'; '3.9' = '2025-10-31'; '3.10' = '2026-10-31'; '3.11' = '2027-10-31'; '3.12' = '2028-10-31'; '3.13' = '2029-10-31' }[$v]
        if ([int]$Matches[1] -eq 2) { $end = '2020-01-01' } elseif (-not $end -and [int]$Matches[2] -le 6) { $end = '2021-12-23' }
        if ($end) { return @{ Label = "Python $v"; End = $end; Sev = 'low' } }
    }
    if ($name -match '^Microsoft (\.NET|ASP\.NET|Windows Desktop)( Core)? ?(Runtime|Shared Framework)?.*? - (\d+)\.\d+') {
        $major = [int]$Matches[4]
        $end = if ($major -le 3) { '2022-12-13' } else { @{ 5 = '2022-05-10'; 6 = '2024-11-12'; 7 = '2024-05-14'; 8 = '2026-11-10'; 9 = '2026-11-10'; 10 = '2028-11-14' }[$major] }
        if ($end -and $name -match 'Runtime') { return @{ Label = $(if ($major -le 3) { ".NET Core $major" } else { ".NET $major" }); End = $end; Sev = 'low' } }
    }
    if ($name -match '^Adobe Flash Player') { return @{ Label = 'Adobe Flash Player'; End = '2020-12-31'; Sev = 'high' } }
    if ($name -match '^Microsoft Silverlight') { return @{ Label = 'Microsoft Silverlight'; End = '2021-10-12'; Sev = 'medium' } }
    if ($name -match '^QuickTime') { return @{ Label = (T 'QuickTime для Windows' 'QuickTime for Windows'); End = '2016-01-01'; Sev = 'medium' } }
    if ($name -match '^Java( \(TM\))? (6|7)( |\(| Update)') { return @{ Label = "Java $($Matches[2])"; End = '2015-04-30'; Sev = 'medium' } }
    if ($name -match '^Microsoft Visual C\+\+ (2005|2008|2010) ') {
        return @{ Label = "Visual C++ $($Matches[1]) Redistributable"; End = @{ '2005' = '2016-04-12'; '2008' = '2018-04-10'; '2010' = '2020-07-14' }[$Matches[1]]; Sev = 'low' }
    }
    $null
}

# Версії з вразливостями, якими вже користуються зловмисники: назва в «Програмах і компонентах» → мінімальна безпечна версія.
# Сюди потрапляє лише перевірене за бюлетенем виробника; загальну «є новіша версія» показує outdated-software.
$script:KnownVulnerable = @(
    @{ Match = '^WinRAR '; Name = 'WinRAR'; Min = '7.13'; Sev = 'high'; Cve = 'CVE-2025-8088'
       Why = (T 'спеціально зроблений архів під час розпакування кладе програму в автозавантаження; вразливість використовували в реальних атаках' 'a crafted archive drops a program into Startup when extracted; exploited in real attacks') }
    @{ Match = '^7-Zip '; Name = '7-Zip'; Min = '25.00'; Sev = 'high'; Cve = 'CVE-2025-0411, CVE-2025-11001'
       Why = (T 'файли з архіву втрачають позначку «з інтернету» (SmartScreen мовчить), а архів із символьними посиланнями записує файли поза папкою розпакування' 'files from an archive lose the "from the internet" mark (SmartScreen stays silent), and an archive with symlinks writes files outside the extraction folder') }
    @{ Match = '^PuTTY release '; Name = 'PuTTY'; Min = '0.81'; Sev = 'medium'; Cve = 'CVE-2024-31497'
       Why = (T 'приватний ключ ECDSA P-521 можна відновити за підписами; такі ключі треба замінити' 'an ECDSA P-521 private key can be recovered from signatures; such keys must be replaced') }
    @{ Match = '^Git$|^Git version '; Name = 'Git for Windows'; Min = '2.50.1'; Sev = 'medium'; Cve = 'CVE-2025-48384'
       Why = (T 'клонування шкідливого репозиторію з підмодулями виконує чужий код' 'cloning a malicious repository with submodules runs foreign code') }
    @{ Match = '^KeePass Password Safe 2'; Name = 'KeePass 2'; Min = '2.54'; Sev = 'medium'; Cve = 'CVE-2023-32784'
       Why = (T 'головний пароль можна відновити з пам''яті процесу або файлу підкачки' 'the master password can be recovered from process memory or the page file') }
    @{ Match = '^AnyDesk'; Name = 'AnyDesk'; Min = '8.0.8'; Sev = 'medium'; Cve = (T 'злам AnyDesk, лютий 2024' 'AnyDesk breach, February 2024')
       Why = (T 'старіші версії підписані сертифікатом, викраденим під час зламу виробника' 'older versions are signed with a certificate stolen in the vendor breach') }
    @{ Match = '^Notepad\+\+ '; Name = 'Notepad++'; Min = '8.8.9'; Sev = 'medium'; Cve = 'CVE-2025-15556'
       Why = (T 'вбудований оновлювач не перевіряв завантажений файл: оновлення можна було підмінити шкідливим' 'the built-in updater did not verify the downloaded file: an update could be swapped for a malicious one') }
)

# '7.13.0', 'ad 8.0.8', '24.09 (x64)' → [version]; $null - не розібрати
function ConvertTo-AppVersion([string]$s) {
    $m = [regex]::Match("$s", '\d+(\.\d+){1,3}')
    if (-not $m.Success) { return $null }
    try { [version]$m.Value } catch { $null }
}

@{
    Id = 'software'; Title = (T 'Програми й драйвери' 'Programs and drivers'); Order = 6
    Checks = @(
        @{
            Id = 'known-vulnerable'; Title = (T 'Програми з відомими вразливостями' 'Programs with known vulnerabilities')
            Test = {
                $hits = @(); $seen = @{}; $matched = 0
                foreach ($a in Get-InstalledApps) {
                    foreach ($k in $KnownVulnerable) {
                        if ($a.DisplayName -notmatch $k.Match -or $seen[$k.Name]) { continue }
                        # У назві версія точніша, ніж у DisplayVersion (PuTTY release 0.80, 7-Zip 24.09 (x64))
                        $v = ConvertTo-AppVersion $a.DisplayVersion
                        if (-not $v) { $v = ConvertTo-AppVersion ($a.DisplayName -replace $k.Match, '') }
                        if (-not $v) { continue }
                        $seen[$k.Name] = $true; $matched++
                        if ($v -lt [version]$k.Min) { $hits += [pscustomobject]@{ Sev = $k.Sev; Line = "⚠ $($k.Name) $v → " + (T "потрібна $($k.Min) або новіша" "needs $($k.Min) or newer") + " ($($k.Cve)): $($k.Why)" } }
                    }
                }
                $note = T "У списку програм: $($KnownVulnerable.Count), встановлено з них: $matched. Портативні копії (розпаковані без встановлення) не видно." "Programs on the list: $($KnownVulnerable.Count), installed: $matched. Portable copies (unpacked without installing) are not visible."
                if (-not $hits) { return Ok (T 'не знайдено' 'none found') $note }
                $sev = if ($hits | Where-Object Sev -eq 'high') { 'high' } else { 'medium' }
                Issue $sev (T "$($hits.Count) шт." "$($hits.Count)") ((T 'Для цих версій є готові способи атаки. Оновіть їх у першу чергу, не чекаючи загального оновлення. ' 'Ready-made attacks exist for these versions. Update them first, without waiting for a general update. ') + $note) @($hits | ForEach-Object Line)
            }
            Explain = (T 'Більшість застарілих програм - це просто «є новіша версія». Але для деяких версій відома конкретна вразливість, яку вже використовують: достатньо відкрити надісланий архів або клонувати репозиторій. Архіватори (WinRAR, 7-Zip) самі не оновлюються - їх найчастіше й забувають.' 'Most outdated programs are merely "a newer version exists". But for some versions a specific vulnerability is known and already exploited: opening a received archive or cloning a repository is enough. Archivers (WinRAR, 7-Zip) do not update themselves - they are the most often forgotten.')
            Pros = @((T 'Закриває діри, якими користуються просто зараз' 'Closes holes that are being exploited right now'))
            Cons = @((T 'Список короткий і ведеться вручну - він доповнює, а не замінює перевірку оновлень' 'The list is short and maintained by hand - it complements the update check, not replaces it'))
            Fix = @{ Recipe = 'app-updates'; Steps = @((T 'Оновіть програму з офіційного сайту або через winget upgrade <назва>. Портативні копії оновіть окремо - замініть папку новою версією.' 'Update the program from its official site or with winget upgrade <name>. Update portable copies separately - replace the folder with the new version.')) }
        }
        @{
            Id = 'outdated-software'; Title = (T 'Застарілі версії програм' 'Outdated program versions')
            Prepare = { Start-Winget }
            Test = {
                if (-not $script:Winget) { return Unknown (T 'winget не знайдено: встановіть «Інсталятор програм» (App Installer) з Microsoft Store.' 'winget not found: install App Installer from the Microsoft Store.') }
                $p = $script:Winget.Process
                if (-not $p.WaitForExit(120000)) { try { $p.Kill() } catch { }; return Unknown (T 'winget не відповів за 2 хвилини (немає інтернету?).' 'winget did not respond within 2 minutes (no internet?).') }
                $rows = @(ConvertFrom-WingetTable $script:Winget.Out.Result | Where-Object { $_.Id -and $_.Available })
                if (-not $rows) {
                    if ($p.ExitCode -ne 0) { return Unknown (T "winget завершився з кодом $($p.ExitCode) (немає інтернету?)." "winget exited with code $($p.ExitCode) (no internet?).") }
                    return Ok (T 'усе оновлено' 'all up to date')
                }
                $important = @($rows | Where-Object { $_.Id -match $SensitiveIds })
                $other = @($rows | Where-Object { $_.Id -notmatch $SensitiveIds })
                $ev = @($important | ForEach-Object { "⚠ $($_.Name): $($_.Version) → $($_.Available)" }) + @($other | ForEach-Object { "$($_.Name): $($_.Version) → $($_.Available)" })
                $value = T "$($rows.Count) оновлень, важливих $($important.Count)" "$($rows.Count) updates, important $($important.Count)"
                if ($important) { return Issue medium $value (T 'Позначені ⚠ - програми, які працюють з інтернетом, файлами чи паролями (браузери, месенджери, архіватори, рантайми): у старих версіях часто є відомі вразливості.' 'Marked ⚠ are programs that handle the internet, files or passwords (browsers, messengers, archivers, runtimes): old versions often have known vulnerabilities.') $ev }
                Issue low $value (T 'Для програм є новіші версії.' 'Newer versions of programs are available.') $ev
            }
            Explain = (T 'Оновлення програм закривають знайдені вразливості. Найважливіше оновлювати те, що відкриває файли й посилання з інтернету: браузери, месенджери, архіватори, PDF-переглядачі, програвачі, засоби віддаленого доступу. Перевірка - через winget (вбудований менеджер програм Windows); вона звертається до каталогу Microsoft в інтернеті.' 'Program updates close discovered vulnerabilities. Most important is updating what opens files and links from the internet: browsers, messengers, archivers, PDF viewers, media players, remote access tools. The check uses winget (the built-in Windows package manager); it queries the Microsoft catalog online.')
            Pros = @((T 'Закриває відомі вразливості, якими користуються віруси' 'Closes known vulnerabilities that malware exploits'), (T 'Одна команда оновлює майже все' 'One command updates almost everything'))
            Cons = @((T 'Оновлення може змінити інтерфейс або прибрати функцію' 'An update may change the interface or remove a feature'), (T 'Під час оновлення програму треба закрити; для частини потрібен UAC' 'The program must be closed while updating; some need UAC'))
            Fix = @{ Recipe = 'app-updates'; Steps = @((T 'Оновити все одразу: у терміналі виконайте winget upgrade --all (або через рецепт «Оновлення програм» у Сетапі).' 'Update everything at once: run winget upgrade --all in a terminal (or use the "App updates" recipe in Setup).')) }
        }
        @{
            Id = 'eol-software'; Title = (T 'Програми без підтримки' 'Unsupported programs')
            Test = {
                $now = Get-Date
                $seen = @{}; $past = @(); $soon = @()
                foreach ($a in Get-InstalledApps) {
                    $e = Get-EolInfo $a.DisplayName
                    if (-not $e -or $seen[$e.Label]) { continue }
                    $seen[$e.Label] = $true
                    $end = [datetime]$e.End
                    if ($end -lt $now) { $past += [pscustomobject]@{ Sev = $e.Sev; Line = "$($e.Label) - " + (T 'підтримку завершено ' 'support ended ') + $end.ToString('dd.MM.yyyy') } }
                    elseif ($end -lt $now.AddDays(60)) { $soon += "$($e.Label) - " + (T "підтримка до $($end.ToString('dd.MM.yyyy')) (через $([int]($end - $now).TotalDays) дн.)" "supported until $($end.ToString('dd.MM.yyyy')) (in $([int]($end - $now).TotalDays) days)") }
                }
                if ($past) {
                    $rank = @{ low = 1; medium = 2; high = 3 }
                    $sev = ($past | Sort-Object { -$rank[$_.Sev] } | Select-Object -First 1).Sev
                    return Issue $sev (T "$($past.Count) шт." "$($past.Count)") (T 'Ці програми або рантайми більше не отримують виправлень безпеки. Ризик є, поки ними користується якась програма.' 'These programs or runtimes no longer get security fixes. The risk remains while some program uses them.') (@($past | ForEach-Object Line) + $soon)
                }
                if ($soon) { return Issue info (T "скоро: $($soon.Count)" "soon: $($soon.Count)") (T 'Підтримка закінчується найближчим часом.' 'Support ends soon.') $soon }
                Ok (T 'не знайдено' 'none found')
            }
            Explain = (T 'Рантайми (.NET, Python, Visual C++) і плагіни часто лишаються після програм, яким вони були потрібні. Після кінця підтримки виробник не виправляє в них вразливостей.' 'Runtimes (.NET, Python, Visual C++) and plugins often remain after the programs that needed them. After end of support, the vendor no longer fixes their vulnerabilities.')
            Pros = @((T 'Менше старого коду, через який можна атакувати ПК' 'Less old code that can be used to attack the PC'), (T 'Звільняє місце' 'Frees up space'))
            Cons = @((T 'Програма, якій потрібен цей рантайм, перестане запускатися - вона скаже, що встановити (зазвичай новішу версію)' 'A program that needs this runtime stops launching - it will say what to install (usually a newer version)'), (T 'Старі ігри часто потребують Visual C++ 2005-2010: їх краще лишити' 'Old games often need Visual C++ 2005-2010: better keep those'))
            Fix = @{ Open = 'ms-settings:appsfeatures'; Steps = @(
                (T 'Видаліть у «Програмах» те, чим не користуєтеся (шукайте за назвою зі списку доказів).' 'Uninstall in Apps what you do not use (search by the name in the evidence list).'),
                (T 'Для .NET і Python встановіть актуальну версію: програми, що вимагають конкретну стару, підкажуть це при запуску.' 'For .NET and Python install the current version: programs that require a specific old one will say so when launched.')
            ) }
        }
        @{
            Id = 'drivers'; Title = (T 'Драйвери' 'Drivers')
            Test = {
                $drv = @(Get-CimInstance Win32_PnPSignedDriver -ErrorAction Stop | Where-Object DeviceName)
                $unsigned = @($drv | Where-Object { $_.IsSigned -eq $false } | ForEach-Object { "⚠ $($_.DeviceName) - $($_.DriverProviderName) $($_.DriverVersion)" + (T ' (без підпису)' ' (unsigned)') })
                $old = @($drv | Where-Object { $_.DriverDate -and $_.DriverDate -lt (Get-Date).AddYears(-6) -and $_.DriverProviderName -notmatch 'Microsoft' } |
                         ForEach-Object { "$($_.DeviceName) - $($_.DriverProviderName) $($_.DriverVersion), $($_.DriverDate.ToString('yyyy'))" } | Sort-Object -Unique)
                if ($unsigned) { return Issue high (T "без підпису: $($unsigned.Count)" "unsigned: $($unsigned.Count)") (T 'Драйвер без цифрового підпису працює в ядрі Windows і міг бути змінений; нормальна Windows такі не завантажує без вимкнення перевірки підписів.' 'A driver without a digital signature runs in the Windows kernel and may have been tampered with; normal Windows does not load such drivers unless signature checks are disabled.') ($unsigned + $old) }
                if ($old) { return Issue info (T "старих: $($old.Count)" "old: $($old.Count)") (T 'Драйвери сторонніх виробників, старші за 6 років. Часто це залишки давно не потрібних пристроїв або програм; старі драйвери - типова причина BSOD.' 'Third-party drivers older than 6 years. Often leftovers of long-unneeded devices or programs; old drivers are a typical cause of BSODs.') $old }
                Ok (T "підписані ($($drv.Count))" "signed ($($drv.Count))")
            }
            Explain = (T 'Драйвери працюють у ядрі Windows з повними правами: помилка в драйвері - синій екран, вразливість - повний доступ до системи. Тому вони мають бути підписані й не надто старі.' 'Drivers run in the Windows kernel with full rights: a driver bug means a blue screen, a vulnerability means full system access. So they should be signed and not too old.')
            Pros = @((T 'Менше синіх екранів і вразливостей у ядрі' 'Fewer blue screens and kernel vulnerabilities'))
            Cons = @((T 'Видалення драйвера - відповідний пристрій або віртуальний пристрій програми перестане працювати' 'Removing a driver stops the matching device or a program''s virtual device from working'))
            Fix = @{ Open = 'devmgmt.msc'; Steps = @((T 'Непотрібний пристрій видаліть у Диспетчері пристроїв разом з драйвером; потрібному - встановіть новіший драйвер із сайту виробника.' 'Remove an unneeded device together with its driver in Device Manager; for a needed one, install a newer driver from the vendor''s site.')) }
        }
    )
}
