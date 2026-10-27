<#
.SYNOPSIS
  DEADPIXEL Audit - перевірка безпеки і стану Windows: що не так, наскільки небезпечно, плюси/мінуси, як виправити.
.DESCRIPTION
  Аудит лише ЧИТАЄ систему. Усі зміни робить модуль Setup (рецепти з бекапом і відкатом) - перевірка лише
  посилається на рецепт через Fix.Recipe.

  Перевірки - checks\<область>.ps1, кожен файл повертає:
    @{ Id; Title; Order; Checks = @( @{ Id; Title; Admin; Prepare = { ... }; Test = { ... }; Explain; Pros; Cons; Fix }, ... ) }
  Test повертає результат через Ok / Issue / Unknown / NotApplicable (нічого = Ok).
  Prepare (необов'язково) запускається до всіх Test - щоб почати довгу роботу (winget) паралельно з рештою перевірок.
  Fix = @{ Recipe = 'назва рецепта Setup'; Open = 'ms-settings:...'; Steps = @('що зробити вручну') }.

  Логіка повертає об'єкти; консоль і GUI (AuditGui.exe, через -OutFile) лише показують їх.
.EXAMPLE
  .\Audit.ps1                         # усі перевірки, результат у консоль; код виходу = кількість критичних і високих
  .\Audit.ps1 -Area platform          # лише одна область
  .\Audit.ps1 -Check hvci,secure-boot # лише вибрані перевірки
  .\Audit.ps1 -Save                   # зберегти як останній звіт (data\audit\latest.json) + в історію
  .\Audit.ps1 -Ignore guest           # більше не рахувати знахідку (свідомий вибір); -Unignore повертає
  .\Audit.ps1 -Html report.html       # останній звіт як HTML-сторінка
  .\Audit.ps1 -Schedule 3             # сканувати автоматично раз на 3 дні (потрібні права адміністратора); 0 - вимкнути
  .\Audit.ps1 -List
#>
param(
    [string[]]$Area,
    [string[]]$Check,
    [switch]$List,
    [switch]$Save,
    [string]$Ignore,
    [string]$Unignore,
    [string]$Html,
    [int]$Schedule = -1,
    [string]$OutFile   # машинний режим для GUI: результат як JSON у файл, без виводу в консоль
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# Дані поруч із програмою (data\audit); якщо туди писати не можна - %LOCALAPPDATA%\DeadPixel\audit (як у трей-програми)
function Get-DataDir {
    $dir = Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'data\audit'
    try {
        New-Item -ItemType Directory -Force $dir | Out-Null
        $probe = Join-Path $dir '.write-test'
        Set-Content $probe '' ; Remove-Item $probe
    } catch {
        $dir = Join-Path $env:LOCALAPPDATA 'DeadPixel\audit'
        New-Item -ItemType Directory -Force $dir | Out-Null
    }
    $dir
}

$script:IsAdmin = $null
function Test-Admin {
    if ($null -eq $script:IsAdmin) {
        $script:IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    $script:IsAdmin
}

# ---------------------------------------------------------------- для перевірок (checks\*.ps1)

# Status: ok | issue | info | unknown | na.  Severity (для issue): critical | high | medium | low
# Files - шляхи до файлів, які GUI може перевірити Defender'ом
function Ok([string]$Value, [string]$Detail, [string[]]$Evidence) {
    @{ Status = 'ok'; Value = $Value; Detail = $Detail; Evidence = $Evidence }
}
function Issue([ValidateSet('critical', 'high', 'medium', 'low', 'info')][string]$Severity, [string]$Value, [string]$Detail, [string[]]$Evidence, [string[]]$Files) {
    @{ Status = $(if ($Severity -eq 'info') { 'info' } else { 'issue' }); Severity = $Severity; Value = $Value; Detail = $Detail; Evidence = $Evidence; Files = $Files }
}
# Результат неповний без прав адміністратора (не видно чужих процесів, служб тощо) - GUI запропонує сканування з правами
function Limited($r) {
    if (-not (Test-Admin)) { $r.NeedsAdmin = $true }
    $r
}
function Unknown([string]$Detail, [switch]$Admin) {
    @{ Status = 'unknown'; Value = '?'; Detail = $Detail; NeedsAdmin = [bool]$Admin }
}
function NotApplicable([string]$Detail) {
    @{ Status = 'na'; Value = '—'; Detail = $Detail }
}

function Get-RegValue([string]$Path, [string]$Name) {
    try { (Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop).$Name } catch { $null }
}

# Відомості про Windows - один раз на сканування
$script:OsInfo = $null
function Get-OsInfo {
    if ($script:OsInfo) { return $script:OsInfo }
    $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $build = [int]$cv.CurrentBuild
    # ProductName на Windows 11 досі "Windows 10 ..." - версію визначаємо за збіркою
    $name = if ($build -ge 22000) { $cv.ProductName -replace 'Windows 10', 'Windows 11' } else { $cv.ProductName }
    $script:OsInfo = [pscustomobject]@{
        Build = $build; Ubr = [int]$cv.UBR; DisplayVersion = $cv.DisplayVersion; EditionID = $cv.EditionID
        Name = "$name $($cv.DisplayVersion)"; IsWin11 = $build -ge 22000
        IsHome = $cv.EditionID -match '^Core'
    }
    $script:OsInfo
}

# ---------------------------------------------------------------- процеси, файли, підписи (спільне для кількох областей)

# PID → Win32_Process (Name, ExecutablePath, CommandLine, ParentProcessId). Без прав адміністратора
# шлях і командний рядок видно лише для власних процесів
$script:Procs = $null
function Get-ProcessTable {
    if (-not $script:Procs) {
        $script:Procs = @{}
        foreach ($p in Get-CimInstance Win32_Process) { $script:Procs[[int]$p.ProcessId] = $p }
    }
    $script:Procs
}

# Підписи кешуються між скануваннями (шлях + розмір + час зміни): Get-AuthenticodeSignature - найдовша операція аудиту
$script:SigCache = $null
$script:SigDirty = $false
function Get-SigCachePath { Join-Path (Get-DataDir) 'sigcache.json' }
function Get-FileSignature([string]$Path) {
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    if ($null -eq $script:SigCache) {
        $script:SigCache = @{}
        try {
            $old = Get-Content (Get-SigCachePath) -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($p in $old.PSObject.Properties) { $script:SigCache[$p.Name] = $p.Value }
        } catch { }
    }
    $fi = Get-Item -LiteralPath $Path -Force
    $key = '{0}|{1}|{2}' -f $Path.ToLowerInvariant(), $fi.Length, $fi.LastWriteTimeUtc.Ticks
    if ($script:SigCache.ContainsKey($key)) { return $script:SigCache[$key] }
    $s = Get-AuthenticodeSignature -LiteralPath $Path
    $r = [pscustomobject]@{
        Status = [string]$s.Status
        Signer = $(if ($s.SignerCertificate) { $s.SignerCertificate.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false) } else { '' })
    }
    $script:SigCache[$key] = $r
    $script:SigDirty = $true
    $r
}
function Save-SigCache {
    if (-not $script:SigDirty) { return }
    # 3000 записів - з великим запасом на всі exe, що бувають у процесах і автозапуску
    $keep = [ordered]@{}
    foreach ($k in @($script:SigCache.Keys | Select-Object -Last 3000)) { $keep[$k] = $script:SigCache[$k] }
    try { ConvertTo-Json -InputObject ([pscustomobject]$keep) -Depth 3 -Compress | Set-Content -Encoding UTF8 (Get-SigCachePath) } catch { }
}

# Наскільки підозріле місце, звідки запущено файл: туди може писати будь-яка програма користувача
function Get-PathRisk([string]$Path) {
    if (-not $Path) { return @{ Points = 0; Why = '' } }
    $p = $Path.ToLowerInvariant()
    $temp = [IO.Path]::GetTempPath().ToLowerInvariant()
    if ($p.StartsWith($temp) -or $p -match '\\appdata\\local\\temp\\|\\downloads\\|\\\$recycle\.bin\\' -or ($env:PUBLIC -and $p.StartsWith($env:PUBLIC.ToLowerInvariant() + '\'))) {
        return @{ Points = 2; Why = 'запущено з тимчасової папки або «Завантажень»' }
    }
    if ($p -match '^[a-z]:\\programdata\\[^\\]+$') { return @{ Points = 2; Why = 'файл лежить просто в корені ProgramData' } }
    if ($p -match '\\appdata\\') { return @{ Points = 1; Why = 'папка профілю користувача (AppData)' } }
    @{ Points = 0; Why = '' }
}

# Ознаки зловживання вбудованими інструментами Windows у командному рядку
function Get-CommandRisk([string]$Cmd) {
    $why = @(); $points = 0
    if (-not $Cmd) { return @{ Points = 0; Why = $why } }
    if ($Cmd -match '(?i)(powershell|pwsh)' -and $Cmd -match '(?i)(downloadstring|downloadfile|net\.webclient|invoke-webrequest|\biwr\b|start-bitstransfer).*(\biex\b|invoke-expression)|(\biex\b|invoke-expression).*(downloadstring|net\.webclient)') {
        $points += 4; $why += 'PowerShell завантажує і одразу виконує код з інтернету'
    } elseif ($Cmd -match '(?i)(powershell|pwsh).*\s-e(nc|ncodedcommand)?\s+[a-z0-9+/=]{20,}') {
        $points += 3; $why += 'PowerShell із закодованою командою (так ховають, що виконується; буває і в легітимних інструментів)'
    }
    if ($Cmd -match '(?i)mshta(\.exe)?["\s]+(https?:|javascript:|vbscript:)') { $points += 4; $why += 'mshta виконує скрипт з інтернету' }
    if ($Cmd -match '(?i)rundll32(\.exe)?["\s].*javascript:') { $points += 4; $why += 'rundll32 виконує JavaScript' }
    if ($Cmd -match '(?i)regsvr32(\.exe)?.*\/i:\s*https?:|scrobj\.dll') { $points += 4; $why += 'regsvr32 завантажує скрипт (техніка Squiblydoo)' }
    if ($Cmd -match '(?i)certutil(\.exe)?.*(-urlcache|-decode)') { $points += 3; $why += 'certutil завантажує або розкодовує файл' }
    if ($Cmd -match '(?i)(wscript|cscript)(\.exe)?.*\\(appdata|temp|downloads|users\\public)\\.*\.(js|jse|vbs|vbe|wsf)') { $points += 3; $why += 'скрипт Windows Script Host з папки користувача' }
    @{ Points = $points; Why = $why }
}

# Імена системних процесів, під які маскуються шкідливі програми
$SystemNames = @('svchost', 'lsass', 'csrss', 'winlogon', 'services', 'smss', 'explorer', 'dllhost', 'rundll32', 'conhost',
                 'taskhostw', 'spoolsv', 'wininit', 'dwm', 'sihost', 'ctfmon', 'runtimebroker', 'searchhost', 'taskmgr', 'msmpeng')

# Відстань Левенштейна двома рядками таблиці (PowerShell 5.1 не розбирає вирази в індексах двовимірних масивів)
function Get-EditDistance([string]$a, [string]$b) {
    $prev = [int[]](0..$b.Length)
    for ($i = 1; $i -le $a.Length; $i++) {
        $cur = New-Object int[] ($b.Length + 1)
        $cur[0] = $i
        for ($j = 1; $j -le $b.Length; $j++) {
            $cost = [int]($a[$i - 1] -ne $b[$j - 1])
            $cur[$j] = [Math]::Min([Math]::Min($prev[$j] + 1, $cur[$j - 1] + 1), $prev[$j - 1] + $cost)
        }
        $prev = $cur
    }
    $prev[$b.Length]
}

# Шлях з процесу/служби/реєстру → звичайний: без \\?\ і лапок, зі змінними середовища
function Get-CleanPath([string]$Path) {
    if (-not $Path) { return $null }
    $p = [Environment]::ExpandEnvironmentVariables($Path.Trim().Trim('"'))
    if ($p.StartsWith('\\?\') -or $p.StartsWith('\??\')) { $p = $p.Substring(4) }
    $p
}

$script:TypoCache = @{}
function Get-Typosquat([string]$base) {
    if (-not $script:TypoCache.ContainsKey($base)) {
        $hit = $null
        if ($base.Length -ge 6 -and $SystemNames -notcontains $base) {
            foreach ($s in $SystemNames) {
                if ($s.Length -ge 6 -and [Math]::Abs($s.Length - $base.Length) -le 1 -and (Get-EditDistance $base $s) -eq 1) { $hit = $s; break }
            }
        }
        $script:TypoCache[$base] = $hit
    }
    $script:TypoCache[$base]
}

# Оцінка самого файлу (місце, маскування, підпис) - одна на шлях: у системі десятки однакових процесів
$script:FileRisk = @{}
function Measure-File([string]$Path, [string]$base) {
    $points = 0; $why = @()
    $loc = Get-PathRisk $Path
    if ($loc.Points) { $points += $loc.Points; $why += $loc.Why }
    $inWindows = $Path -and $Path.ToLowerInvariant().StartsWith($env:windir.ToLowerInvariant() + '\')
    $sig = $null
    if ($base -and $Path -and -not $inWindows -and $SystemNames -contains $base) {
        # Справжні компоненти Windows бувають і поза папкою Windows (Defender - у ProgramData): вирішує підпис Microsoft
        $sig = Get-FileSignature $Path
        if (-not ($sig -and $sig.Status -eq 'Valid' -and $sig.Signer -match 'Microsoft')) {
            $points += 5; $why += "ім'я системного процесу Windows, але файл не в папці Windows і не підписаний Microsoft"
        }
    } else {
        $typo = Get-Typosquat $base
        if ($typo) { $points += 4; $why += "ім'я майже як у системного «$typo» - типове маскування" }
    }
    # Підпис перевіряємо лише в підозрілих місцях: у Windows/Program Files він майже завжди є, а перевірка коштує часу
    if ($Path -and -not $sig -and ($loc.Points -gt 0 -or $points -gt 0)) { $sig = Get-FileSignature $Path }
    if ($sig -and $loc.Points -gt 0) {
        if ($sig.Status -eq 'NotSigned') { $points += $(if ($loc.Points -ge 2) { 2 } else { 1 }); $why += 'файл не має цифрового підпису' }
        elseif ($sig.Status -notin 'Valid', 'NotSigned', 'UnknownError') { $points += 4; $why += "підпис недійсний ($($sig.Status)) - файл могли змінити" }
    }
    @{ Points = $points; Why = $why; Signature = $sig }
}

# Загальна оцінка виконуваного файлу: місце + підпис + маскування під системний + командний рядок
function Measure-Executable([string]$Path, [string]$Cmd, [string]$Name) {
    $Path = Get-CleanPath $Path
    $base = if ($Name) { [IO.Path]::GetFileNameWithoutExtension($Name).ToLowerInvariant() } elseif ($Path) { [IO.Path]::GetFileNameWithoutExtension($Path).ToLowerInvariant() } else { '' }
    $key = "$Path|$base"
    if (-not $script:FileRisk.ContainsKey($key)) { $script:FileRisk[$key] = Measure-File $Path $base }
    $f = $script:FileRisk[$key]
    $c = Get-CommandRisk $Cmd
    # Новий об'єкт: перевірки додають до нього власні причини
    @{ Points = $f.Points + $c.Points; Why = @($f.Why) + @($c.Why); Signature = $f.Signature }
}

function Get-RiskSeverity([int]$Points) { if ($Points -ge 5) { 'high' } elseif ($Points -ge 3) { 'medium' } else { $null } }

# Шлях до exe з командного рядка автозапуску / служби / завдання
function Get-ExeFromCommand([string]$Cmd) {
    if (-not $Cmd) { return $null }
    $c = [Environment]::ExpandEnvironmentVariables($Cmd.Trim())
    if ($c.StartsWith('"')) { $end = $c.IndexOf('"', 1); if ($end -gt 1) { return Get-CleanPath $c.Substring(1, $end - 1) } }
    $m = [regex]::Match($c, '(?i)^.+?\.(exe|com|bat|cmd|scr|pif)(?=\s|$)')
    if ($m.Success) { return Get-CleanPath $m.Value }
    Get-CleanPath ($c -split '\s+')[0]
}

# Чи може звичайна програма користувача змінити файл / створити файл у папці. Для файлу, що запускається
# з правами SYSTEM, це шлях до підвищення прав: підмінити сам exe або підкласти DLL поруч
$script:WritableCache = @{}
function Test-WritableByUsers([string]$Dir) {
    if (-not $Dir -or -not (Test-Path -LiteralPath $Dir)) { return $false }
    $k = $Dir.ToLowerInvariant()
    if ($script:WritableCache.ContainsKey($k)) { return $script:WritableCache[$k] }
    $sids = @('S-1-1-0', 'S-1-5-11', 'S-1-5-32-545', 'S-1-5-4', [Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
    # Для папки WriteData = «створювати файли»; AppendData = лише «створювати підпапки» (так у Users на C:\) - файл ним не підкласти
    $write = [Security.AccessControl.FileSystemRights]'WriteData, ChangePermissions, TakeOwnership'
    $res = $false
    try {
        foreach ($rule in (Get-Acl -LiteralPath $Dir).GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
            if ($rule.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly) { continue }   # стосується лише вкладених
            if ($rule.AccessControlType -eq 'Allow' -and $sids -contains $rule.IdentityReference.Value -and ($rule.FileSystemRights -band $write)) { $res = $true; break }
        }
    } catch { }
    $script:WritableCache[$k] = $res
    $res
}

# Ноутбук/планшет: від цього залежить, наскільки важливе шифрування диска
function Test-Portable {
    try { [bool](@((Get-CimInstance Win32_SystemEnclosure).ChassisTypes) | Where-Object { $_ -in 8, 9, 10, 11, 12, 14, 18, 21, 30, 31, 32 }) } catch { $false }
}

# ---------------------------------------------------------------- перевірки

# Файли перевірок підключаються через "." на рівні скрипта: допоміжні функції з них (Get-FirmwareType тощо)
# мають лишитися видимими, коли Test викликається пізніше
$AllAreas = @(foreach ($f in Get-ChildItem (Join-Path $PSScriptRoot 'checks') -Filter '*.ps1') { . $f.FullName }) | Sort-Object { $_.Order }
function Read-Areas { $AllAreas }

function Test-Match([string]$value, [string[]]$patterns) {
    if (-not $patterns) { return $true }
    foreach ($p in $patterns) { if ($value -like $p) { return $true } }
    $false
}

function Invoke-Check($area, $c, [bool]$admin) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    if ($c.Admin -and -not $admin) { $r = Unknown 'Для цієї перевірки потрібні права адміністратора.' -Admin }
    else {
        try { $r = & $c.Test } catch { $r = Unknown ('Не вдалося перевірити: ' + $_.Exception.Message) }
        if ($r -is [array]) { $r = $r[-1] }   # випадковий вивід із Test не повинен зламати результат
        if (-not $r) { $r = Ok }
    }
    $fix = $c.Fix
    [pscustomobject]@{
        Id = $c.Id; Area = $area.Id; Title = $c.Title
        Status = $r.Status; Severity = [string]$r.Severity; Value = [string]$r.Value; Detail = [string]$r.Detail
        Evidence = @($r.Evidence | Where-Object { $_ }); Files = @($r.Files | Where-Object { $_ } | Select-Object -Unique)
        NeedsAdmin = [bool]$r.NeedsAdmin; Ignored = $false; New = $false
        Explain = [string]$c.Explain; Pros = @($c.Pros | Where-Object { $_ }); Cons = @($c.Cons | Where-Object { $_ })
        Fix = [pscustomobject]@{
            Recipe = [string]$fix.Recipe; Open = [string]$fix.Open; Steps = @($fix.Steps | Where-Object { $_ })
        }
        Ms = [int]$sw.ElapsedMilliseconds
    }
}

# ---------------------------------------------------------------- оцінка

# Кожна знахідка забирає відсоток від того, що лишилося (а не фіксовані бали): інакше що більше перевірок,
# то гірше виглядав би будь-який ПК. Одна критична діра важить більше, ніж десяток дрібниць: вона обмежує оцінку зверху
$Weights = @{ critical = 40; high = 15; medium = 6; low = 2 }

function Get-Score($results) {
    $active = @($results | Where-Object { $_.Status -eq 'issue' -and -not $_.Ignored })
    $left = 1.0; foreach ($r in $active) { $left *= 1 - $Weights[$r.Severity] / 100 }
    $score = [int][Math]::Round(100 * $left)
    if ($active | Where-Object { $_.Severity -eq 'critical' }) { $score = [Math]::Min($score, 39) }
    elseif ($active | Where-Object { $_.Severity -eq 'high' }) { $score = [Math]::Min($score, 79) }
    $score
}

function Get-Grade([int]$score) {
    if ($score -ge 85) { 'Добре' } elseif ($score -ge 70) { 'Є що покращити' } elseif ($score -ge 40) { 'Ризиковано' } else { 'Небезпечно' }
}

function Read-IgnoreList {
    $f = Join-Path (Get-DataDir) 'ignore.json'
    if (-not (Test-Path $f)) { return @() }
    try { @(Get-Content $f -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { @() }
}

function Write-IgnoreList([string[]]$ids) {
    ConvertTo-Json -InputObject @($ids | Sort-Object -Unique) | Set-Content -Encoding UTF8 (Join-Path (Get-DataDir) 'ignore.json')
}

# ---------------------------------------------------------------- розклад (Планувальник завдань)

$TaskPath = '\DEADPIXEL\'
$TaskName = 'DEADPIXEL Audit'

function Get-ScheduleDays {
    try {
        $t = Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction Stop
        if ($t.State -eq 'Disabled') { return 0 }
        [int](@($t.Triggers)[0].DaysInterval)
    } catch { 0 }
}

# Завдання запускає AuditGui.exe --background: це winexe, тож жодне вікно консолі не блимає.
# Найвищі права - щоб бачити системні процеси й підписки WMI; тому й створення розкладу потребує UAC
function Set-Schedule([int]$days) {
    if (-not (Test-Admin)) { throw 'Щоб налаштувати розклад, потрібні права адміністратора.' }
    Unregister-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    if ($days -le 0) { return }
    $gui = Join-Path $PSScriptRoot 'AuditGui.exe'
    if (-not (Test-Path $gui)) { throw "Не знайдено $gui" }
    $action = New-ScheduledTaskAction -Execute $gui -Argument '--background'
    $trigger = New-ScheduledTaskTrigger -Daily -DaysInterval $days -At '12:00'
    # Пропущений запуск (ПК був вимкнений) - одразу, щойно ПК увімкнуть; низький пріоритет; не довше 15 хв
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 15) -Priority 7 -MultipleInstances IgnoreNew
    $principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Highest
    Register-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal `
        -Description 'DEADPIXEL: перевірка безпеки і стану системи. Лише читає систему; результат - у треї і вікні «Аудит системи».' | Out-Null
}

# ---------------------------------------------------------------- звіт

# «Нове» - проблема, якої не було в попередньому повному звіті (або яка стала серйознішою).
# Перше сканування нічого не позначає новим, щоб не засипати сповіщеннями
function Set-NewFlags($results) {
    $f = Join-Path (Get-DataDir) 'latest.json'
    if (-not (Test-Path $f)) { return }
    $prev = @{}
    try { foreach ($r in (Get-Content $f -Raw -Encoding UTF8 | ConvertFrom-Json).Results) { if ($r.Status -eq 'issue') { $prev[$r.Id] = $Weights[$r.Severity] } } } catch { return }
    foreach ($r in $results) {
        $r.New = $r.Status -eq 'issue' -and (-not $prev.ContainsKey($r.Id) -or $Weights[$r.Severity] -gt $prev[$r.Id])
    }
}

# Звіт: оцінка загалом і по областях; ігноровані знахідки видно, але вони не рахуються
function New-Report($areas, $results, [bool]$admin, [string]$time) {
    $ignored = Read-IgnoreList
    foreach ($r in $results) { $r.Ignored = $ignored -contains $r.Id }
    $score = Get-Score $results
    [pscustomobject]@{
        Error = $null; Time = $time; IsAdmin = $admin; Score = $score; Grade = Get-Grade $score
        ScheduleDays = Get-ScheduleDays; NewCount = @($results | Where-Object { $_.New -and -not $_.Ignored }).Count
        Areas = @($areas | ForEach-Object {
            $id = $_.Id
            $mine = @($results | Where-Object { $_.Area -eq $id })
            if ($mine.Count -eq 0) { return }
            $s = Get-Score $mine
            [pscustomobject]@{
                Id = $id; Title = $_.Title; Score = $s; Grade = Get-Grade $s
                Issues = @($mine | Where-Object { $_.Status -eq 'issue' -and -not $_.Ignored }).Count
            }
        })
        Results = @($results)
    }
}

function Invoke-Audit {
    $admin = Test-Admin
    $areas = @(Read-Areas | Where-Object { Test-Match $_.Id $Area })
    $selected = @(foreach ($a in $areas) { foreach ($c in $a.Checks) { if (Test-Match $c.Id $Check) { @{ Area = $a; Check = $c } } } })
    foreach ($s in $selected) { if ($s.Check.Prepare -and -not ($s.Check.Admin -and -not $admin)) { try { & $s.Check.Prepare } catch { } } }
    $results = foreach ($s in $selected) { Invoke-Check $s.Area $s.Check $admin }
    Save-SigCache
    Set-NewFlags @($results)
    New-Report $areas @($results) $admin (Get-Date).ToString('s')
}

function Save-Report($report) {
    $dir = Get-DataDir
    $json = ConvertTo-Json -InputObject $report -Depth 6
    $json | Set-Content -Encoding UTF8 (Join-Path $dir 'latest.json')
    $hist = Join-Path $dir 'history'
    New-Item -ItemType Directory -Force $hist | Out-Null
    $json | Set-Content -Encoding UTF8 (Join-Path $hist ('report-{0:yyyyMMdd-HHmmss}.json' -f (Get-Date)))
    # історія потрібна для "що нового з минулого разу" - 30 звітів більш ніж достатньо
    Get-ChildItem $hist -Filter 'report-*.json' | Sort-Object Name -Descending | Select-Object -Skip 30 | Remove-Item -Force
    Write-Summary $report
}

# Короткий підсумок для трея (ключ=значення): трей лише читає цей файл раз на хвилину і не розбирає JSON
function Write-Summary($report) {
    $alerts = @($report.Results | Where-Object { $_.New -and -not $_.Ignored -and $_.Severity -in 'critical', 'high' })
    $first = if ($alerts) { $alerts[0] } else { $null }
    @(
        "Time=$($report.Time)", "Score=$($report.Score)", "Grade=$($report.Grade)", "Alerts=$($alerts.Count)",
        "AlertId=$(if ($first) { $first.Id })", "AlertTitle=$(if ($first) { $first.Title })", "AlertValue=$(if ($first) { $first.Value })"
    ) | Set-Content -Encoding UTF8 (Join-Path (Get-DataDir) 'summary.ini')
}

# Останній збережений звіт з актуальними списком ігнорованого і розкладом - без нового сканування
function Read-Latest {
    $latest = Join-Path (Get-DataDir) 'latest.json'
    if (-not (Test-Path $latest)) { throw 'Ще немає звіту - спершу запустіть сканування.' }
    $old = Get-Content $latest -Raw -Encoding UTF8 | ConvertFrom-Json
    $areas = @($old.Areas | ForEach-Object { [pscustomobject]@{ Id = $_.Id; Title = $_.Title } })
    foreach ($r in $old.Results) { if ($null -eq $r.PSObject.Properties['New']) { $r | Add-Member New $false } }
    New-Report $areas @($old.Results) ([bool]$old.IsAdmin) $old.Time
}

# -Ignore / -Unignore: оновити список і перерахувати останній звіт без нового сканування
function Update-Ignore {
    $ids = @(Read-IgnoreList)
    if ($Ignore) { $ids += $Ignore }
    if ($Unignore) { $ids = @($ids | Where-Object { $_ -ne $Unignore }) }
    Write-IgnoreList $ids
    $report = Read-Latest
    ConvertTo-Json -InputObject $report -Depth 6 | Set-Content -Encoding UTF8 (Join-Path (Get-DataDir) 'latest.json')
    Write-Summary $report
    $report
}

# ---------------------------------------------------------------- HTML-звіт (щоб показати комусь, хто розбирається)

function ConvertTo-HtmlText([string]$s) { [Net.WebUtility]::HtmlEncode($s) }

function Export-Html($report, [string]$path) {
    $os = Get-OsInfo
    $sev = @{ critical = 'Критично'; high = 'Високий'; medium = 'Середній'; low = 'Низький' }
    $sb = New-Object Text.StringBuilder
    $t = [datetime]$report.Time
    $null = $sb.Append(@"
<!doctype html><html lang="uk"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Аудит системи DEADPIXEL</title><style>
:root{--bg:#f3f4f6;--card:#fff;--fg:#1c1f24;--muted:#6b7280;--line:#dadee4;--ok:#16873c;--warn:#b46400;--bad:#c62828;--info:#2563eb}
@media (prefers-color-scheme:dark){:root{--bg:#16181c;--card:#202329;--fg:#e5e7eb;--muted:#969eaa;--line:#343942;--ok:#4ade80;--warn:#fbbf24;--bad:#f87171;--info:#60a5fa}}
body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.5 "Segoe UI",system-ui,sans-serif}
main{max-width:980px;margin:0 auto;padding:24px 16px 48px}h1{margin:0 0 4px;font-size:26px}h2{margin:32px 0 10px;font-size:19px}
.muted{color:var(--muted)}.score{font-size:44px;font-weight:600;margin-right:12px}.head{display:flex;align-items:center;flex-wrap:wrap;gap:4px}
.item{background:var(--card);border:1px solid var(--line);border-radius:8px;padding:12px 14px;margin:8px 0}
.item.ok,.item.na,.item.ign{padding:6px 14px}.row{display:flex;gap:10px;flex-wrap:wrap;align-items:baseline}
.chip{font-weight:600;min-width:92px}.title{font-weight:600;flex:1}.value{color:var(--muted)}
.critical .chip,.high .chip{color:var(--bad)}.medium .chip,.low .chip{color:var(--warn)}.ok .chip{color:var(--ok)}.info .chip{color:var(--info)}.na .chip,.unknown .chip,.ign .chip{color:var(--muted)}
ul{margin:6px 0 0;padding-left:20px}li{margin:3px 0;overflow-wrap:anywhere}h3{font-size:13px;margin:10px 0 0;color:var(--info);text-transform:uppercase;letter-spacing:.04em}
footer{margin-top:32px;font-size:13px}
</style></head><body><main>
<h1>Аудит системи</h1>
<div class="muted">$(ConvertTo-HtmlText "$($os.Name), збірка $($os.Build).$($os.Ubr) · сканування $($t.ToString('dd.MM.yyyy HH:mm'))$(if ($report.IsAdmin) { ' · з правами адміністратора' })")</div>
<div class="head" style="margin-top:14px"><span class="score">$($report.Score)</span><span><b>$(ConvertTo-HtmlText $report.Grade)</b><br><span class="muted">загальна оцінка з 100</span></span></div>
"@)
    foreach ($a in $report.Areas) {
        $null = $sb.Append("<h2>$(ConvertTo-HtmlText $a.Title) <span class=`"muted`">· $($a.Score)</span></h2>`n")
        $rank = @{ critical = 0; high = 1; medium = 2; low = 3 }
        $mine = @($report.Results | Where-Object { $_.Area -eq $a.Id } | Sort-Object { if ($_.Ignored) { 9 } elseif ($_.Status -eq 'issue') { $rank[$_.Severity] } elseif ($_.Status -eq 'unknown') { 4 } elseif ($_.Status -eq 'info') { 5 } elseif ($_.Status -eq 'ok') { 6 } else { 7 } })
        foreach ($r in $mine) {
            $cls = if ($r.Ignored) { 'ign' } elseif ($r.Status -eq 'issue') { $r.Severity } else { $r.Status }
            $chip = if ($r.Ignored) { 'Ігнорується' } elseif ($r.Status -eq 'issue') { $sev[$r.Severity] } else { @{ ok = 'Гаразд'; info = 'Інфо'; unknown = 'Невідомо'; na = 'Н/д' }[$r.Status] }
            $null = $sb.Append("<div class=`"item $cls`"><div class=`"row`"><span class=`"chip`">$chip</span><span class=`"title`">$(ConvertTo-HtmlText $r.Title)</span><span class=`"value`">$(ConvertTo-HtmlText $r.Value)</span></div>")
            if ($r.Status -in 'issue', 'info', 'unknown' -and -not $r.Ignored) {
                if ($r.Detail) { $null = $sb.Append("<div>$(ConvertTo-HtmlText $r.Detail)</div>") }
                if ($r.Status -eq 'issue') {
                    if ($r.Explain) { $null = $sb.Append("<h3>Що це</h3><div>$(ConvertTo-HtmlText $r.Explain)</div>") }
                    if ($r.Cons) { $null = $sb.Append('<h3>Мінуси і на що зважити</h3><ul>' + (($r.Cons | ForEach-Object { "<li>$(ConvertTo-HtmlText $_)</li>" }) -join '') + '</ul>') }
                }
                if ($r.Evidence) { $null = $sb.Append('<h3>Докази</h3><ul>' + (($r.Evidence | ForEach-Object { "<li>$(ConvertTo-HtmlText $_)</li>" }) -join '') + '</ul>') }
                if ($r.Status -eq 'issue' -and $r.Fix.Steps) { $null = $sb.Append('<h3>Як виправити</h3><ul>' + (($r.Fix.Steps | ForEach-Object { "<li>$(ConvertTo-HtmlText $_)</li>" }) -join '') + '</ul>') }
            }
            $null = $sb.Append("</div>`n")
        }
    }
    $null = $sb.Append('<footer class="muted">Створено DEADPIXEL. Звіт містить відомості про цей ПК (програми, шляхи, мережі) - показуйте його лише тим, кому довіряєте.</footer></main></body></html>')
    New-Item -ItemType Directory -Force (Split-Path $path) | Out-Null
    [IO.File]::WriteAllText($path, $sb.ToString(), (New-Object Text.UTF8Encoding $false))
}

# ---------------------------------------------------------------- консоль

$Tags = @{
    critical = @('КРИТ', 'Red'); high = @('ВИС ', 'Red'); medium = @('СЕР ', 'Yellow'); low = @('НИЗ ', 'DarkYellow')
    ok = @(' OK ', 'Green'); info = @('ІНФО', 'Cyan'); unknown = @(' ?  ', 'DarkGray'); na = @(' —  ', 'DarkGray')
}

function Write-Report($report) {
    foreach ($a in $report.Areas) {
        Write-Host
        Write-Host ('{0}  {1}/100 ({2})' -f $a.Title, $a.Score, $a.Grade) -ForegroundColor Cyan
        foreach ($r in $report.Results | Where-Object { $_.Area -eq $a.Id }) {
            $t = if ($r.Status -eq 'issue') { $Tags[$r.Severity] } else { $Tags[$r.Status] }
            Write-Host ('  [{0}] ' -f $t[0]) -ForegroundColor $t[1] -NoNewline
            Write-Host $r.Title -NoNewline
            Write-Host ("  $($r.Value)" + $(if ($r.Ignored) { '  (ігнорується)' } else { '' })) -ForegroundColor DarkGray
            if ($r.Status -in 'issue', 'unknown' -and $r.Detail -and -not $r.Ignored) { Write-Host "         $($r.Detail)" -ForegroundColor DarkGray }
        }
    }
    Write-Host
    $color = if ($report.Score -ge 85) { 'Green' } elseif ($report.Score -ge 40) { 'Yellow' } else { 'Red' }
    Write-Host ('Загальна оцінка: {0}/100 - {1}' -f $report.Score, $report.Grade) -ForegroundColor $color
    if (-not $report.IsAdmin -and ($report.Results | Where-Object { $_.NeedsAdmin })) {
        Write-Host 'Частину перевірок пропущено: запустіть з правами адміністратора (Audit.cmd).' -ForegroundColor DarkGray
    }
}

if ($List) {
    foreach ($a in Read-Areas) {
        Write-Host "$($a.Id) - $($a.Title)" -ForegroundColor Cyan
        foreach ($c in $a.Checks) { Write-Host ('  {0,-22} {1}' -f $c.Id, $c.Title) }
    }
    exit 0
}

try {
    if ($Schedule -ge 0) {
        Set-Schedule $Schedule
        $report = try { Read-Latest } catch { [pscustomobject]@{ Error = $null; Results = @(); Areas = @(); ScheduleDays = Get-ScheduleDays } }
    }
    elseif ($Html) { $report = Read-Latest; Export-Html $report $Html }
    elseif ($Ignore -or $Unignore) { $report = Update-Ignore }
    else {
        $report = Invoke-Audit
        # Частковий звіт (-Area/-Check) не замінює повний: інакше GUI і порівняння з минулим скануванням бачили б лише його
        if ($Save -and -not ($Area -or $Check)) { Save-Report $report }
    }
} catch {
    if ($OutFile) {
        ConvertTo-Json -InputObject ([pscustomobject]@{ Error = $_.Exception.Message; Results = @() }) | Set-Content -Encoding UTF8 $OutFile
        exit 0
    }
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 255
}

if ($OutFile) {
    ConvertTo-Json -InputObject $report -Depth 6 | Set-Content -Encoding UTF8 $OutFile
    exit 0
}
if ($Schedule -ge 0) { Write-Host $(if ($Schedule -gt 0) { "Аудит запускатиметься автоматично раз на $Schedule дн." } else { 'Автоматичний аудит вимкнено.' }); exit 0 }
if ($Html) { Write-Host "Звіт: $Html"; exit 0 }
Write-Report $report
# Код виходу = кількість активних критичних і високих знахідок (0 - немає), 255 - помилка запуску
exit [Math]::Min(254, @($report.Results | Where-Object { $_.Status -eq 'issue' -and -not $_.Ignored -and $_.Severity -in 'critical', 'high' }).Count)
