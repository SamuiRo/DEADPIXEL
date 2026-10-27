<#
.SYNOPSIS
  DEADPIXEL Audit - перевірка безпеки і стану Windows: що не так, наскільки небезпечно, плюси/мінуси, як виправити.
.DESCRIPTION
  Аудит лише ЧИТАЄ систему. Усі зміни робить модуль Setup (рецепти з бекапом і відкатом) - перевірка лише
  посилається на рецепт через Fix.Recipe.

  Перевірки - checks\<область>.ps1, кожен файл повертає:
    @{ Id; Title; Order; Checks = @( @{ Id; Title; Admin; Test = { ... }; Explain; Pros; Cons; Fix }, ... ) }
  Test повертає результат через Ok / Issue / Unknown / NotApplicable (нічого = Ok).
  Fix = @{ Recipe = 'назва рецепта Setup'; Open = 'ms-settings:...'; Steps = @('що зробити вручну') }.

  Логіка повертає об'єкти; консоль і GUI (AuditGui.exe, через -OutFile) лише показують їх.
.EXAMPLE
  .\Audit.ps1                         # усі перевірки, результат у консоль; код виходу = кількість критичних і високих
  .\Audit.ps1 -Area platform          # лише одна область
  .\Audit.ps1 -Check hvci,secure-boot # лише вибрані перевірки
  .\Audit.ps1 -Save                   # зберегти як останній звіт (data\audit\latest.json) + в історію
  .\Audit.ps1 -Ignore guest           # більше не рахувати знахідку (свідомий вибір); -Unignore повертає
  .\Audit.ps1 -List
#>
param(
    [string[]]$Area,
    [string[]]$Check,
    [switch]$List,
    [switch]$Save,
    [string]$Ignore,
    [string]$Unignore,
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

function Test-Admin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ---------------------------------------------------------------- для перевірок (checks\*.ps1)

# Status: ok | issue | info | unknown | na.  Severity (для issue): critical | high | medium | low
function Ok([string]$Value, [string]$Detail, [string[]]$Evidence) {
    @{ Status = 'ok'; Value = $Value; Detail = $Detail; Evidence = $Evidence }
}
function Issue([ValidateSet('critical', 'high', 'medium', 'low', 'info')][string]$Severity, [string]$Value, [string]$Detail, [string[]]$Evidence) {
    @{ Status = $(if ($Severity -eq 'info') { 'info' } else { 'issue' }); Severity = $Severity; Value = $Value; Detail = $Detail; Evidence = $Evidence }
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
        Evidence = @($r.Evidence | Where-Object { $_ })
        NeedsAdmin = [bool]$r.NeedsAdmin; Ignored = $false
        Explain = [string]$c.Explain; Pros = @($c.Pros | Where-Object { $_ }); Cons = @($c.Cons | Where-Object { $_ })
        Fix = [pscustomobject]@{
            Recipe = [string]$fix.Recipe; Open = [string]$fix.Open; Steps = @($fix.Steps | Where-Object { $_ })
        }
        Ms = [int]$sw.ElapsedMilliseconds
    }
}

# ---------------------------------------------------------------- оцінка

# Одна критична діра важить більше, ніж десяток дрібниць: вона обмежує оцінку зверху
$Weights = @{ critical = 40; high = 15; medium = 6; low = 2 }

function Get-Score($results) {
    $active = @($results | Where-Object { $_.Status -eq 'issue' -and -not $_.Ignored })
    $sum = 0; foreach ($r in $active) { $sum += $Weights[$r.Severity] }
    $score = [Math]::Max(0, 100 - $sum)
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

# Звіт: оцінка загалом і по областях; ігноровані знахідки видно, але вони не рахуються
function New-Report($areas, $results, [bool]$admin, [string]$time) {
    $ignored = Read-IgnoreList
    foreach ($r in $results) { $r.Ignored = $ignored -contains $r.Id }
    $score = Get-Score $results
    [pscustomobject]@{
        Error = $null; Time = $time; IsAdmin = $admin; Score = $score; Grade = Get-Grade $score
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
    $results = foreach ($a in $areas) {
        foreach ($c in $a.Checks) { if (Test-Match $c.Id $Check) { Invoke-Check $a $c $admin } }
    }
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
}

# -Ignore / -Unignore: оновити список і перерахувати останній звіт без нового сканування
function Update-Ignore {
    $ids = @(Read-IgnoreList)
    if ($Ignore) { $ids += $Ignore }
    if ($Unignore) { $ids = @($ids | Where-Object { $_ -ne $Unignore }) }
    Write-IgnoreList $ids
    $latest = Join-Path (Get-DataDir) 'latest.json'
    if (-not (Test-Path $latest)) { throw 'Ще немає звіту - спершу запустіть сканування.' }
    $old = Get-Content $latest -Raw -Encoding UTF8 | ConvertFrom-Json
    $areas = @($old.Areas | ForEach-Object { [pscustomobject]@{ Id = $_.Id; Title = $_.Title } })
    $report = New-Report $areas @($old.Results) ([bool]$old.IsAdmin) $old.Time
    ConvertTo-Json -InputObject $report -Depth 6 | Set-Content -Encoding UTF8 $latest
    $report
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
    $report = if ($Ignore -or $Unignore) { Update-Ignore } else { Invoke-Audit }
    # Частковий звіт (-Area/-Check) не замінює повний: інакше GUI і порівняння з минулим скануванням бачили б лише його
    if ($Save -and -not ($Ignore -or $Unignore -or $Area -or $Check)) { Save-Report $report }
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
Write-Report $report
# Код виходу = кількість активних критичних і високих знахідок (0 - немає), 255 - помилка запуску
exit [Math]::Min(254, @($report.Results | Where-Object { $_.Status -eq 'issue' -and -not $_.Ignored -and $_.Severity -in 'critical', 'high' }).Count)
