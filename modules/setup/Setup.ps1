<#
.SYNOPSIS
  DEADPIXEL Setup - групові налаштування Windows за рецептами: перевірити, застосувати, відкотити.
.DESCRIPTION
  Рецепт - recipes\<назва>.ps1, що повертає @{ Title; Description; Items; Steps; Reboot }.
  Профіль - profiles\<назва>.ps1: @{ Title; Description; Recipes = @(...); Steps }.
  Кожен пункт уміє лише прочитати поточне значення і записати нове; з цього випливає все інше:
  перевірка порівнює з Desired, застосування спершу зберігає старі значення в бекап,
  відкат повертає саме їх (а не "протилежне" значення).
  Логіка повертає об'єкти-результати; консоль і GUI (SetupGui.exe, через -OutFile) лише показують їх.
.EXAMPLE
  .\Setup.ps1                                  # меню
  .\Setup.ps1 -List
  .\Setup.ps1 -Recipe disk-power               # перевірка (за замовчуванням); код виходу = кількість відхилень
  .\Setup.ps1 -Recipe disk-power -Apply
  .\Setup.ps1 -Recipe disk-power -Revert
  .\Setup.ps1 -ProfileName new-pc -Apply       # усі рецепти профілю
  .\Setup.ps1 -Recipe *                        # аудит ПК за всіма рецептами
#>
param(
    [string[]]$Recipe,
    [string]$ProfileName,
    [switch]$List,
    [switch]$Apply,
    [switch]$Revert,
    [string]$OutFile   # машинний режим для GUI: результат як JSON у файл, без виводу в консоль
)

$ErrorActionPreference = 'Stop'
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

function Find-Backup([string]$name) {
    Get-ChildItem (Get-BackupDir) -Filter "$name-*.json" -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -Last 1
}

function Test-Admin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ---------------------------------------------------------------- рецепти та профілі

function Read-Defs([string]$dir) {
    if (-not (Test-Path $dir)) { return }
    Get-ChildItem $dir -Filter '*.ps1' | Sort-Object BaseName | ForEach-Object {
        $d = & $_.FullName
        $d.Name = $_.BaseName
        $d
    }
}

$AllRecipes = @(Read-Defs (Join-Path $PSScriptRoot 'recipes'))
$AllProfiles = @(Read-Defs (Join-Path $PSScriptRoot 'profiles'))

# Крок - рядок (ручна дія) або хеш-таблиця:
#   Text     що зробити ({Param} підставляється);  Hint - пояснення "чому"
#   Run      команда PowerShell, яку GUI виконає кнопкою ▶ ({Param} підставляється як рядок у лапках)
#   Expect   regex: крок успішний, лише якщо вивід йому відповідає (інакше - лише код виходу)
#   If       'ok' | 'fail': крок діє, лише якщо попередня команда вдалася / не вдалася
#   Open     що відкрити (devmgmt.msc, ms-settings:..., control.exe /name ...)
#   Reboot   'restart' | 'firmware' (у BIOS/UEFI): прогрес зберігається, після перезавантаження GUI продовжить
#   Admin    $true - команді потрібні права адміністратора;  Confirm - текст підтвердження перед запуском
function ConvertTo-Step($s) {
    if ($s -is [string]) { $s = @{ Text = $s } }
    [pscustomobject]@{
        Text = $s.Text; Hint = $s.Hint; Run = $s.Run; Expect = $s.Expect; If = $s.If; Open = $s.Open
        Reboot = $(if ($s.Reboot -eq 'firmware') { 'firmware' } elseif ($s.Reboot) { 'restart' } else { $null })
        Admin = [bool]$s.Admin; Confirm = $s.Confirm
    }
}

function Get-Steps($def) {
    @($def.Steps | Where-Object { $_ } | ForEach-Object { ConvertTo-Step $_ })
}

# Вкладки-сценарії рецепта: @{ Id; Title; Description; Params = @(@{ Name; Title; Default; Pattern; Hint }); Steps }
function Get-Tabs($r) {
    @($r.Tabs | Where-Object { $_ } | ForEach-Object {
        $t = $_
        [pscustomobject]@{
            Id = $(if ($t.Id) { $t.Id } else { $t.Title }); Title = $t.Title; Description = $t.Description
            Params = @($t.Params | Where-Object { $_ } | ForEach-Object {
                [pscustomobject]@{ Name = $_.Name; Title = $_.Title; Default = [string]$_.Default; Pattern = $_.Pattern; Hint = $_.Hint }
            })
            Steps = @(Get-Steps $t)
        }
    })
}

# Рецепти для -Recipe (шаблони) або -ProfileName, у порядку, як їх перелічено
function Resolve-Recipes {
    if ($ProfileName) {
        $p = $AllProfiles | Where-Object { $_.Name -eq $ProfileName } | Select-Object -First 1
        if (-not $p) { throw "Профіль '$ProfileName' не знайдено. Список: Setup.ps1 -List" }
        $patterns = @($p.Recipes)
    } else { $patterns = @($Recipe) }
    $seen = @{}
    $res = @()
    foreach ($pat in $patterns) {
        $found = @($AllRecipes | Where-Object { $_.Name -like $pat })
        if ($found.Count -eq 0) { throw "Рецепт '$pat' не знайдено. Список: Setup.ps1 -List" }
        foreach ($r in $found) { if (-not $seen[$r.Name]) { $seen[$r.Name] = $true; $res += $r } }
    }
    $res
}

# ---------------------------------------------------------------- типи пунктів

# Power: Sub, Setting (аліас або GUID), Power = AC|DC. Значення - індекс/число.
# FirewallRule: Name (не DisplayName - той локалізований). Значення - 'True'/'False'.
# Registry: Path, Name, Type (DWord за замовчуванням). Значення - дані або '<absent>'.
# Custom: Get = { ... }, Set = { param($value) ... }.
# Спільні поля: Id (за ним зіставляється бекап), Title, Desired, Hint, Labels = @{ 0 = '...' }.

function Get-Value($item) {
    switch ($item.Kind) {
        'Power' {
            # /qh показує й приховані налаштування (напр. AHCI Link Power Management на свіжій Windows); /query їх не бачить
            $out = (powercfg /qh SCHEME_CURRENT $item.Sub $item.Setting) -join "`n"
            if ($LASTEXITCODE -ne 0) { $out = (powercfg /query SCHEME_CURRENT $item.Sub $item.Setting) -join "`n" }
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
    $n = $value -as [int]
    if ($item.Labels -and $null -ne $n -and $item.Labels.ContainsKey($n)) { return "$value ($($item.Labels[$n]))" }
    "$value"
}

function Test-Same($a, $b) { "$a" -eq "$b" }

# ---------------------------------------------------------------- дії (повертають результати, нічого не друкують)

# Status: OK | DIFF | NA (недоступно) | SET (застосовано) | BACK (відкочено) | FAIL | SKIP
function New-Result($r, $it, [string]$status, $cur, [string]$msg) {
    [pscustomobject]@{
        Recipe = $r.Name; Id = $it.Id; Title = $it.Title; Status = $status
        CurrentText = $(if ($status -eq 'NA') { '' } else { Format-Value $it $cur })
        DesiredText = Format-Value $it $it.Desired
        Message = $msg
    }
}

function New-Outcome($r, $results, [string]$backup, [string]$msg) {
    [pscustomobject]@{
        # @($null) - це масив з одним $null; рецепт без пунктів (лише сценарії) дає саме його
        Recipe = $r.Name; Title = $r.Title; Results = @($results | Where-Object { $_ }); Backup = $backup; Message = $msg
        HasBackup = [bool](Find-Backup $r.Name)
    }
}

function Test-Recipe($r) {
    $results = foreach ($it in $r.Items) {
        try { $cur = Get-Value $it }
        catch { New-Result $r $it 'NA' $null $_.Exception.Message; continue }
        New-Result $r $it $(if (Test-Same $cur $it.Desired) { 'OK' } else { 'DIFF' }) $cur ''
    }
    New-Outcome $r $results '' ''
}

function Invoke-ApplyRecipe($r) {
    # 1. Знімок: бекап пишемо ДО змін, щоб відкат був можливий навіть після збою посередині
    $results = @(); $todo = @()
    foreach ($it in $r.Items) {
        try { $cur = Get-Value $it }
        catch { $results += New-Result $r $it 'NA' $null $_.Exception.Message; continue }
        if (Test-Same $cur $it.Desired) { $results += New-Result $r $it 'OK' $cur 'вже як треба' }
        else { $todo += [pscustomobject]@{ Item = $it; Old = $cur } }
    }
    if ($todo.Count -eq 0) { return New-Outcome $r $results '' 'Нічого змінювати.' }
    $backup = Join-Path (Get-BackupDir) ('{0}-{1:yyyyMMdd-HHmmss}.json' -f $r.Name, (Get-Date))
    [pscustomobject]@{
        Recipe = $r.Name; Time = (Get-Date).ToString('s'); Computer = $env:COMPUTERNAME
        Items  = @($todo | ForEach-Object { [pscustomobject]@{ Id = $_.Item.Id; Value = $_.Old } })
    } | ConvertTo-Json -Depth 4 | Set-Content -Encoding UTF8 $backup

    # 2. Застосування з перевіркою результату
    foreach ($t in $todo) {
        $it = $t.Item
        try {
            $null = Set-Value $it $it.Desired
            $now = Get-Value $it
            if (Test-Same $now $it.Desired) { $results += New-Result $r $it 'SET' $now ('було ' + (Format-Value $it $t.Old)) }
            else { $results += New-Result $r $it 'FAIL' $now 'записано, але значення не змінилося' }
        }
        catch { $results += New-Result $r $it 'FAIL' $t.Old $_.Exception.Message }
    }
    New-Outcome $r $results $backup ''
}

function Invoke-RevertRecipe($r) {
    $file = Find-Backup $r.Name
    if (-not $file) { return New-Outcome $r @() '' 'Немає бекапу — рецепт не застосовувався або вже відкочено.' }
    $data = Get-Content $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    $results = @(); $ok = $true
    foreach ($b in @($data.Items)) {
        $it = $r.Items | Where-Object { $_.Id -eq $b.Id } | Select-Object -First 1
        if (-not $it) {
            $results += [pscustomobject]@{ Recipe = $r.Name; Id = $b.Id; Title = $b.Id; Status = 'SKIP'; CurrentText = ''; DesiredText = ''; Message = 'пункту вже немає в рецепті' }
            continue
        }
        try {
            $null = Set-Value $it $b.Value
            $results += New-Result $r $it 'BACK' (Get-Value $it) ''
        }
        catch { $ok = $false; $results += New-Result $r $it 'FAIL' $null $_.Exception.Message }
    }
    # Використаний бекап позначаємо, щоб наступний відкат узяв попередній, а не цей самий
    if ($ok) { Rename-Item $file.FullName ($file.Name + '.reverted') }
    New-Outcome $r $results '' "Повернуто значення з бекапу від $($data.Time)"
}

function Get-Catalog {
    [pscustomobject]@{
        Error    = $null
        Recipes  = @($AllRecipes | ForEach-Object {
            $r = $_
            [pscustomobject]@{
                Name = $r.Name; Title = $r.Title; Description = $r.Description; Reboot = [bool]$r.Reboot
                HasBackup = [bool](Find-Backup $r.Name); Steps = @(Get-Steps $r); Tabs = @(Get-Tabs $r)
                Items = @($r.Items | ForEach-Object { [pscustomobject]@{ Id = $_.Id; Title = $_.Title; Hint = $_.Hint; DesiredText = (Format-Value $_ $_.Desired) } })
            }
        })
        Profiles = @($AllProfiles | ForEach-Object {
            [pscustomobject]@{ Name = $_.Name; Title = $_.Title; Description = $_.Description; Recipes = @($_.Recipes); Steps = @(Get-Steps $_) }
        })
    }
}

# ---------------------------------------------------------------- консоль

$Colors = @{ OK = 'Green'; DIFF = 'Yellow'; NA = 'DarkGray'; SET = 'Green'; BACK = 'Cyan'; FAIL = 'Red'; SKIP = 'Yellow' }

function Write-Row([string]$tag, [string]$color, [string]$title, [string]$detail) {
    Write-Host ('  [{0,-4}] ' -f $tag) -ForegroundColor $color -NoNewline
    Write-Host $title -NoNewline
    if ($detail) { Write-Host "  $detail" -ForegroundColor DarkGray } else { Write-Host }
}

function Write-Steps($def) {
    $steps = @(Get-Steps $def)
    if ($def.Reboot) { $steps += ConvertTo-Step 'Перезавантажте ПК, щоб зміни набули чинності.' }
    if ($steps.Count -eq 0) { return }
    Write-Host '  Що зробити вручну:' -ForegroundColor Cyan
    foreach ($s in $steps) {
        Write-Host "   - $($s.Text)" -NoNewline
        $extra = if ($s.Run) { $s.Run } else { $s.Open }
        if ($extra) { Write-Host "  [$extra]" -ForegroundColor DarkGray } else { Write-Host }
    }
}

function Write-Outcome($r, $o, [bool]$withSteps) {
    Write-Host
    Write-Host "$($r.Name) — $($r.Title)" -ForegroundColor Cyan
    if ($r.Description) { Write-Host "  $($r.Description)" -ForegroundColor DarkGray }
    foreach ($x in $o.Results) {
        $detail = switch ($x.Status) {
            'DIFF' { "зараз $($x.CurrentText), треба $($x.DesiredText)" }
            'SET'  { "$($x.Message) → $($x.CurrentText)" }
            'NA'   { $x.Message }
            'FAIL' { $x.Message }
            'SKIP' { $x.Message }
            default { $x.CurrentText }
        }
        Write-Row $x.Status $Colors[$x.Status] $x.Title $detail
    }
    if ($o.Message) { Write-Host "  $($o.Message)" -ForegroundColor DarkGray }
    if ($o.Backup) { Write-Host "  Бекап для відкату: $($o.Backup)" -ForegroundColor DarkGray }
    if ($withSteps) { Write-Steps $r }
}

function Show-List {
    Write-Host 'Профілі:' -ForegroundColor Cyan
    foreach ($p in $AllProfiles) { Write-Host ('  {0,-16} {1}  [{2}]' -f $p.Name, $p.Title, (@($p.Recipes) -join ', ')) }
    Write-Host 'Рецепти:' -ForegroundColor Cyan
    foreach ($r in $AllRecipes) {
        Write-Host ('  {0,-16} {1}' -f $r.Name, $r.Title) -NoNewline
        $tabs = @(Get-Tabs $r)
        if ($tabs.Count) { Write-Host ("  [сценарії в GUI: {0}]" -f (($tabs | ForEach-Object { $_.Title }) -join ', ')) -ForegroundColor DarkGray } else { Write-Host }
    }
}

# ---------------------------------------------------------------- запуск

function Invoke-Action([string]$action) {
    if ($action -ne 'Check' -and -not (Test-Admin)) { throw 'Для змін потрібні права адміністратора — запустіть через Setup.cmd або SetupGui.exe.' }
    foreach ($r in Resolve-Recipes) {
        switch ($action) {
            'Check'  { Test-Recipe $r }
            'Apply'  { Invoke-ApplyRecipe $r }
            'Revert' { Invoke-RevertRecipe $r }
        }
    }
}

function Invoke-Console([string]$action) {
    $outcomes = @(Invoke-Action $action)
    foreach ($o in $outcomes) {
        $r = $AllRecipes | Where-Object { $_.Name -eq $o.Recipe }
        Write-Outcome $r $o ($action -eq 'Apply')
    }
    if ($action -eq 'Apply' -and $ProfileName) {
        $p = $AllProfiles | Where-Object { $_.Name -eq $ProfileName }
        Write-Host; Write-Host "Профіль: $($p.Title)" -ForegroundColor Cyan
        Write-Steps $p
    }
    $diff = @($outcomes | ForEach-Object { $_.Results } | Where-Object { $_.Status -eq 'DIFF' }).Count
    if ($action -eq 'Check') {
        Write-Host
        if ($diff -eq 0) { Write-Host 'Усе налаштовано як треба.' -ForegroundColor Green }
        else { Write-Host "Відхилень: $diff" -ForegroundColor Yellow }
    }
    $diff
}

function Show-Menu {
    while ($true) {
        $entries = @($AllProfiles | ForEach-Object { @{ Kind = 'profile'; Name = $_.Name; Title = "[профіль] $($_.Title)" } }) +
                   @($AllRecipes | ForEach-Object { @{ Kind = 'recipe'; Name = $_.Name; Title = $_.Title } })
        Write-Host
        Write-Host 'DEADPIXEL Setup' -ForegroundColor Cyan
        for ($i = 0; $i -lt $entries.Count; $i++) { Write-Host ('  {0,2}. {1,-16} {2}' -f ($i + 1), $entries[$i].Name, $entries[$i].Title) }
        Write-Host '   *. перевірити все'
        $sel = Read-Host 'Вибір (Enter — вихід)'
        if (-not $sel) { return }
        try {
            if ($sel -eq '*') { $script:Recipe = '*'; $script:ProfileName = $null; $null = Invoke-Console 'Check'; continue }
            $n = 0
            if (-not [int]::TryParse($sel, [ref]$n) -or $n -lt 1 -or $n -gt $entries.Count) { continue }
            $e = $entries[$n - 1]
            if ($e.Kind -eq 'profile') { $script:ProfileName = $e.Name; $script:Recipe = $null }
            else { $script:Recipe = $e.Name; $script:ProfileName = $null }
            $null = Invoke-Console 'Check'
            switch ((Read-Host '[A] застосувати, [R] відкотити, Enter — назад').ToUpper()) {
                'A' { $null = Invoke-Console 'Apply' }
                'R' { $null = Invoke-Console 'Revert' }
            }
        }
        catch { Write-Host $_.Exception.Message -ForegroundColor Red }
    }
}

if (@($Apply, $Revert, $List | Where-Object { $_ }).Count -gt 1) { throw 'Вкажіть лише одне з -List, -Apply, -Revert' }
$action = if ($Apply) { 'Apply' } elseif ($Revert) { 'Revert' } else { 'Check' }

if ($OutFile) {
    try {
        $out = if ($List) { Get-Catalog } else { [pscustomobject]@{ Error = $null; Recipes = @(Invoke-Action $action) } }
    }
    catch { $out = [pscustomobject]@{ Error = $_.Exception.Message; Recipes = @() } }
    ConvertTo-Json -InputObject $out -Depth 6 | Set-Content -Encoding UTF8 $OutFile
    exit 0
}

if ($List) { Show-List; exit 0 }
if (-not $Recipe -and -not $ProfileName) { Show-Menu; exit 0 }
try { $diff = Invoke-Console $action }
catch { Write-Host $_.Exception.Message -ForegroundColor Red; exit 255 }
# Перевірка: код = кількість відхилень (0 - усе гаразд); 255 - помилка запуску
exit $(if ($action -eq 'Check') { [Math]::Min([int]$diff, 254) } else { 0 })
