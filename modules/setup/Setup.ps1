<#
.SYNOPSIS
  DEADPIXEL Setup - групові налаштування Windows за рецептами: перевірити, застосувати, відкотити.
.DESCRIPTION
  Рецепт - файл recipes\<назва>.ps1, що повертає @{ Title; Description; Items }.
  Кожен пункт уміє лише прочитати поточне значення і записати нове; з цього випливає все інше:
  перевірка порівнює з Desired, застосування спершу зберігає старі значення в бекап,
  відкат повертає саме їх (а не "протилежне" значення).
.EXAMPLE
  .\Setup.ps1                                  # меню
  .\Setup.ps1 -List
  .\Setup.ps1 -Recipe disk-power               # перевірка (за замовчуванням); код виходу = кількість відхилень
  .\Setup.ps1 -Recipe disk-power -Apply
  .\Setup.ps1 -Recipe disk-power -Revert
  .\Setup.ps1 -Recipe *                        # аудит ПК за всіма рецептами
#>
param(
    [string]$Recipe,
    [switch]$List,
    [switch]$Apply,
    [switch]$Revert
)

$ErrorActionPreference = 'Stop'
$RecipeDir = Join-Path $PSScriptRoot 'recipes'
$Absent = '<absent>'   # значення реєстру, якого немає: відкат до нього = видалення

# Дані поруч із програмою (data\setup); якщо туди писати не можна - %LOCALAPPDATA%\DeadPixel\setup (як у трей-програми)
function Get-BackupDir {
    $dir = Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'data\setup'
    try {
        New-Item -ItemType Directory -Force $dir | Out-Null
        $probe = Join-Path $dir '.write-test'
        Set-Content $probe '' ; Remove-Item $probe
    } catch {
        $dir = Join-Path $env:LOCALAPPDATA 'DeadPixel\setup'
        New-Item -ItemType Directory -Force $dir | Out-Null
    }
    $dir
}

function Test-Admin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ---------------------------------------------------------------- рецепти

function Get-Recipes([string]$pattern) {
    if (-not $pattern) { $pattern = '*' }
    Get-ChildItem $RecipeDir -Filter '*.ps1' | Where-Object { $_.BaseName -like $pattern } | Sort-Object BaseName | ForEach-Object {
        $r = & $_.FullName
        $r.Name = $_.BaseName
        $r
    }
}

# ---------------------------------------------------------------- типи пунктів

# Power: Sub, Setting (аліас або GUID), Power = AC|DC. Значення - індекс/число.
# FirewallRule: Name (не DisplayName - той локалізований). Значення - 'True'/'False'.
# Registry: Path, Name, Type (DWord за замовчуванням). Значення - дані або '<absent>'.
# Custom: Get = { ... }, Set = { param($value) ... }.

function Get-Value($item) {
    switch ($item.Kind) {
        'Power' {
            $out = (powercfg /query SCHEME_CURRENT $item.Sub $item.Setting) -join "`n"
            # Поточні AC/DC - завжди два останні 0x-числа (перед ними можуть бути Min/Max/Increment).
            # Неіснуюче налаштування powercfg повертає з кодом 0 і без цих рядків.
            $hex = [regex]::Matches($out, '0x[0-9a-fA-F]{8}')
            if ($LASTEXITCODE -ne 0 -or $hex.Count -lt 2) { throw 'налаштування немає в цій системі' }
            $i = if ($item.Power -eq 'DC') { $hex.Count - 1 } else { $hex.Count - 2 }
            return [long][Convert]::ToUInt32($hex[$i].Value.Substring(2), 16)
        }
        'FirewallRule' {
            $r = Get-NetFirewallRule -Name $item.Name -ErrorAction SilentlyContinue
            if (-not $r) { throw "правила $($item.Name) немає" }
            return [string]$r.Enabled
        }
        'Registry' {
            $p = Get-ItemProperty -Path $item.Path -Name $item.Name -ErrorAction SilentlyContinue
            if ($null -eq $p) { return $Absent }
            return $p.($item.Name)
        }
        'Custom' { return & $item.Get }
        default { throw "невідомий тип пункту: $($item.Kind)" }
    }
}

function Set-Value($item, $value) {
    switch ($item.Kind) {
        'Power' {
            $verb = if ($item.Power -eq 'DC') { '/setdcvalueindex' } else { '/setacvalueindex' }
            powercfg $verb SCHEME_CURRENT $item.Sub $item.Setting $value | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "powercfg $verb завершився з кодом $LASTEXITCODE" }
            powercfg /setactive SCHEME_CURRENT | Out-Null
        }
        'FirewallRule' { Set-NetFirewallRule -Name $item.Name -Enabled $value }
        'Registry' {
            if ($value -eq $Absent) { Remove-ItemProperty -Path $item.Path -Name $item.Name -ErrorAction SilentlyContinue; return }
            if (-not (Test-Path $item.Path)) { New-Item -Path $item.Path -Force | Out-Null }
            $type = if ($item.Type) { $item.Type } else { 'DWord' }
            New-ItemProperty -Path $item.Path -Name $item.Name -Value $value -PropertyType $type -Force | Out-Null
        }
        'Custom' { & $item.Set $value }
    }
}

function Format-Value($item, $value) {
    if ($null -eq $value) { return '—' }
    if ($item.Labels -and $item.Labels.ContainsKey([int]$value)) { return "$value ($($item.Labels[[int]$value]))" }
    "$value"
}

function Test-Same($a, $b) { "$a" -eq "$b" }

# ---------------------------------------------------------------- дії

function Write-Row([string]$tag, [ConsoleColor]$color, [string]$title, [string]$detail) {
    Write-Host ('  [{0,-4}] ' -f $tag) -ForegroundColor $color -NoNewline
    Write-Host $title -NoNewline
    if ($detail) { Write-Host "  $detail" -ForegroundColor DarkGray } else { Write-Host }
}

function Write-Header($r) {
    Write-Host
    Write-Host "$($r.Name) — $($r.Title)" -ForegroundColor Cyan
    if ($r.Description) { Write-Host "  $($r.Description)" -ForegroundColor DarkGray }
}

# Повертає кількість пунктів, що відрізняються від бажаного (недоступні не рахуються)
function Invoke-Check($r) {
    Write-Header $r
    $diff = 0
    foreach ($it in $r.Items) {
        try { $cur = Get-Value $it }
        catch { Write-Row 'N/A' DarkGray $it.Title $_.Exception.Message; continue }
        if (Test-Same $cur $it.Desired) { Write-Row 'OK' Green $it.Title (Format-Value $it $cur) }
        else {
            $diff++
            Write-Row 'DIFF' Yellow $it.Title ("зараз {0}, треба {1}" -f (Format-Value $it $cur), (Format-Value $it $it.Desired))
        }
    }
    $diff
}

function Invoke-Apply($r) {
    Write-Header $r
    # 1. Знімок: бекап пишемо ДО змін, щоб відкат був можливий навіть після збою посередині
    $todo = @()
    foreach ($it in $r.Items) {
        try { $cur = Get-Value $it }
        catch { Write-Row 'N/A' DarkGray $it.Title $_.Exception.Message; continue }
        if (Test-Same $cur $it.Desired) { Write-Row 'OK' Green $it.Title 'вже як треба' }
        else { $todo += [pscustomobject]@{ Item = $it; Old = $cur } }
    }
    if ($todo.Count -eq 0) { Write-Host '  Нічого змінювати.' -ForegroundColor DarkGray; return }
    $backup = Join-Path (Get-BackupDir) ('{0}-{1:yyyyMMdd-HHmmss}.json' -f $r.Name, (Get-Date))
    [pscustomobject]@{
        Recipe = $r.Name; Time = (Get-Date).ToString('s'); Computer = $env:COMPUTERNAME
        Items  = @($todo | ForEach-Object { [pscustomobject]@{ Id = $_.Item.Id; Value = $_.Old } })
    } | ConvertTo-Json -Depth 4 | Set-Content -Encoding UTF8 $backup

    # 2. Застосування з перевіркою результату
    foreach ($t in $todo) {
        $it = $t.Item
        try {
            Set-Value $it $it.Desired
            $now = Get-Value $it
            if (Test-Same $now $it.Desired) { Write-Row 'SET' Green $it.Title ("{0} → {1}" -f (Format-Value $it $t.Old), (Format-Value $it $now)) }
            else { Write-Row 'FAIL' Red $it.Title ("записано, але зараз {0}" -f (Format-Value $it $now)) }
        }
        catch { Write-Row 'FAIL' Red $it.Title $_.Exception.Message }
    }
    Write-Host "  Бекап для відкату: $backup" -ForegroundColor DarkGray
}

function Invoke-Revert($r) {
    Write-Header $r
    $file = Get-ChildItem (Get-BackupDir) -Filter "$($r.Name)-*.json" -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -Last 1
    if (-not $file) { Write-Host '  Немає бекапу — рецепт не застосовувався (або вже відкочено).' -ForegroundColor Yellow; return }
    $data = Get-Content $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    Write-Host "  Бекап від $($data.Time)" -ForegroundColor DarkGray
    $ok = $true
    foreach ($b in $data.Items) {
        $it = $r.Items | Where-Object { $_.Id -eq $b.Id } | Select-Object -First 1
        if (-not $it) { Write-Row 'SKIP' Yellow $b.Id 'пункту вже немає в рецепті'; continue }
        try {
            Set-Value $it $b.Value
            Write-Row 'BACK' Green $it.Title (Format-Value $it (Get-Value $it))
        }
        catch { $ok = $false; Write-Row 'FAIL' Red $it.Title $_.Exception.Message }
    }
    # Використаний бекап позначаємо, щоб наступний відкат узяв попередній, а не цей самий
    if ($ok) { Rename-Item $file.FullName ($file.Name + '.reverted') }
}

function Invoke-Recipes([string]$pattern, [string]$action) {
    $recipes = @(Get-Recipes $pattern)
    if ($recipes.Count -eq 0) { Write-Host "Рецепт '$pattern' не знайдено. Список: Setup.ps1 -List" -ForegroundColor Red; return -1 }
    if ($action -ne 'Check' -and -not (Test-Admin)) {
        Write-Host 'Для змін потрібні права адміністратора — запустіть через Setup.cmd.' -ForegroundColor Red; return -1
    }
    $diff = 0
    foreach ($r in $recipes) {
        switch ($action) {
            'Check'  { $diff += Invoke-Check $r }
            'Apply'  { $null = Invoke-Apply $r }
            'Revert' { $null = Invoke-Revert $r }
        }
    }
    if ($action -eq 'Check') {
        Write-Host
        if ($diff -eq 0) { Write-Host 'Усе налаштовано як треба.' -ForegroundColor Green }
        else { Write-Host "Відхилень: $diff" -ForegroundColor Yellow }
    }
    $diff
}

function Show-List {
    foreach ($r in Get-Recipes) {
        Write-Host ('  {0,-16}' -f $r.Name) -ForegroundColor Cyan -NoNewline
        Write-Host " $($r.Title)"
    }
}

function Show-Menu {
    $recipes = @(Get-Recipes)
    while ($true) {
        Write-Host
        Write-Host 'DEADPIXEL Setup' -ForegroundColor Cyan
        for ($i = 0; $i -lt $recipes.Count; $i++) { Write-Host ('  {0,2}. {1,-16} {2}' -f ($i + 1), $recipes[$i].Name, $recipes[$i].Title) }
        Write-Host '   *. перевірити все'
        $sel = Read-Host 'Рецепт (Enter — вихід)'
        if (-not $sel) { return }
        if ($sel -eq '*') { $null = Invoke-Recipes '*' 'Check'; continue }
        $n = 0
        if (-not [int]::TryParse($sel, [ref]$n) -or $n -lt 1 -or $n -gt $recipes.Count) { continue }
        $name = $recipes[$n - 1].Name
        $null = Invoke-Recipes $name 'Check'
        $act = Read-Host '[A] застосувати, [R] відкотити, Enter — назад'
        switch ($act.ToUpper()) {
            'A' { $null = Invoke-Recipes $name 'Apply' }
            'R' { $null = Invoke-Recipes $name 'Revert' }
        }
    }
}

# ---------------------------------------------------------------- точка входу

if (@($Apply, $Revert, $List | Where-Object { $_ }).Count -gt 1) { throw 'Вкажіть лише одне з -List, -Apply, -Revert' }
if ($List) { Show-List; exit 0 }
if (-not $Recipe) { Show-Menu; exit 0 }
$action = if ($Apply) { 'Apply' } elseif ($Revert) { 'Revert' } else { 'Check' }
$result = Invoke-Recipes $Recipe $action
# Перевірка: код = кількість відхилень (0 - усе гаразд); 255 - помилка запуску
if ($result -lt 0) { exit 255 }
exit $(if ($action -eq 'Check') { [Math]::Min([int]$result, 254) } else { 0 })
