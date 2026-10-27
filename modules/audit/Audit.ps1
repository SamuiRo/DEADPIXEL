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
    [string]$Lang,       # uk | en; без нього - з data\settings.ini (як у трей-програми)
    [string]$OutFile   # машинний режим для GUI: результат як JSON у файл, без виводу в консоль
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# Мова текстів (перевірки формують пояснення нею): T 'українською' 'English'
. (Join-Path (Split-Path $PSScriptRoot) 'common\Lang.ps1')
$script:UiLang = Resolve-UiLang $Lang (Split-Path (Split-Path $PSScriptRoot))

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

# Що можна прибрати (через карантин модуля Setup): кожен пункт - Kind + поля цілі + Label для списку в GUI.
# Kind: Path (файл/папка) | RegistryKey | RegistryValue (Key, Name) | Service (Name) | Task (Key = TaskPath, Name) |
#       PathEntry (Scope = Machine|User, Target = запис як у реєстрі) | FirewallRule (Target = програма як у правилі)
# Default - чи позначати пункт у списку одразу (зламані записи - так; «можливо залишки» - ні)
function Add-Cleanup($r, $items) {
    $r.Cleanup = @($items | Where-Object { $_ })
    $r
}
function New-CleanupItem([string]$Kind, [string]$Label, [hashtable]$Fields, [bool]$Default = $true, [long]$Size = 0) {
    $o = [ordered]@{ Kind = $Kind; Label = $Label; Default = $Default; Size = $Size; Target = ''; Key = ''; Name = ''; Scope = '' }
    foreach ($k in $Fields.Keys) { $o[$k] = [string]$Fields[$k] }
    [pscustomobject]$o
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
        return @{ Points = 2; Why = (T 'запущено з тимчасової папки або «Завантажень»' 'started from a temporary folder or Downloads') }
    }
    if ($p -match '^[a-z]:\\programdata\\[^\\]+$') { return @{ Points = 2; Why = (T 'файл лежить просто в корені ProgramData' 'the file sits directly in the ProgramData root') } }
    if ($p -match '\\appdata\\') { return @{ Points = 1; Why = (T 'папка профілю користувача (AppData)' 'a user profile folder (AppData)') } }
    @{ Points = 0; Why = '' }
}

# Ознаки зловживання вбудованими інструментами Windows у командному рядку
function Get-CommandRisk([string]$Cmd) {
    $why = @(); $points = 0
    if (-not $Cmd) { return @{ Points = 0; Why = $why } }
    if ($Cmd -match '(?i)(powershell|pwsh)' -and $Cmd -match '(?i)(downloadstring|downloadfile|net\.webclient|invoke-webrequest|\biwr\b|start-bitstransfer).*(\biex\b|invoke-expression)|(\biex\b|invoke-expression).*(downloadstring|net\.webclient)') {
        $points += 4; $why += (T 'PowerShell завантажує і одразу виконує код з інтернету' 'PowerShell downloads and immediately runs code from the internet')
    } elseif ($Cmd -match '(?i)(powershell|pwsh).*\s-e(nc|ncodedcommand)?\s+[a-z0-9+/=]{20,}') {
        $points += 3; $why += (T 'PowerShell із закодованою командою (так ховають, що виконується; буває і в легітимних інструментів)' 'PowerShell with an encoded command (hides what runs; legitimate tools do it too)')
    }
    if ($Cmd -match '(?i)mshta(\.exe)?["\s]+(https?:|javascript:|vbscript:)') { $points += 4; $why += (T 'mshta виконує скрипт з інтернету' 'mshta runs a script from the internet') }
    if ($Cmd -match '(?i)rundll32(\.exe)?["\s].*javascript:') { $points += 4; $why += (T 'rundll32 виконує JavaScript' 'rundll32 runs JavaScript') }
    if ($Cmd -match '(?i)regsvr32(\.exe)?.*\/i:\s*https?:|scrobj\.dll') { $points += 4; $why += (T 'regsvr32 завантажує скрипт (техніка Squiblydoo)' 'regsvr32 loads a script (the Squiblydoo technique)') }
    if ($Cmd -match '(?i)certutil(\.exe)?.*(-urlcache|-decode)') { $points += 3; $why += (T 'certutil завантажує або розкодовує файл' 'certutil downloads or decodes a file') }
    if ($Cmd -match '(?i)(wscript|cscript)(\.exe)?.*\\(appdata|temp|downloads|users\\public)\\.*\.(js|jse|vbs|vbe|wsf)') { $points += 3; $why += (T 'скрипт Windows Script Host з папки користувача' 'a Windows Script Host script from a user folder') }
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
            $points += 5; $why += (T "ім'я системного процесу Windows, але файл не в папці Windows і не підписаний Microsoft" "a Windows system process name, but the file is outside the Windows folder and not signed by Microsoft")
        }
    } else {
        $typo = Get-Typosquat $base
        if ($typo) { $points += 4; $why += (T "ім'я майже як у системного «$typo» - типове маскування" "the name nearly matches the system '$typo' - typical disguise") }
    }
    # Підпис перевіряємо лише в підозрілих місцях: у Windows/Program Files він майже завжди є, а перевірка коштує часу
    if ($Path -and -not $sig -and ($loc.Points -gt 0 -or $points -gt 0)) { $sig = Get-FileSignature $Path }
    if ($sig -and $loc.Points -gt 0) {
        if ($sig.Status -eq 'NotSigned') { $points += $(if ($loc.Points -ge 2) { 2 } else { 1 }); $why += (T 'файл не має цифрового підпису' 'the file has no digital signature') }
        elseif ($sig.Status -notin 'Valid', 'NotSigned', 'UnknownError') { $points += 4; $why += (T "підпис недійсний ($($sig.Status)) - файл могли змінити" "invalid signature ($($sig.Status)) - the file may have been modified") }
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

# Встановлені програми з «Програм і компонентів» (усі три розділи реєстру) - потрібні кільком областям
$script:Installed = $null
function Get-InstalledApps {
    if ($null -eq $script:Installed) {
        $keys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
        $script:Installed = @(foreach ($k in $keys) { Get-ItemProperty $k -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName } })
    }
    $script:Installed
}

# Microsoft.PowerShell.Core\Registry::HKEY_LOCAL_MACHINE\... → HKLM:\... (так шлях зрозуміють і Setup, і людина)
function ConvertTo-RegDrivePath([string]$PSPath) {
    $p = $PSPath -replace '^Microsoft\.PowerShell\.Core\\Registry::', ''
    $p -replace '^HKEY_LOCAL_MACHINE\\', 'HKLM:\' -replace '^HKEY_CURRENT_USER\\', 'HKCU:\'
}

# Чи може звичайна програма створити цей шлях (його немає, але найближча наявна батьківська папка відкрита на запис).
# Саме так «хвости» стають дірою: служба/завдання/PATH посилаються на місце, куди можна підкласти свій файл
function Test-CreatableByUsers([string]$Path) {
    $p = Get-CleanPath $Path
    if (-not $p -or -not [IO.Path]::IsPathRooted($p)) { return $false }
    $dir = Split-Path $p
    while ($dir -and -not (Test-Path -LiteralPath $dir)) { $dir = Split-Path $dir }
    if (-not $dir) { return $false }
    Test-WritableByUsers $dir
}

# Розмір папки з обмеженням часу й кількості файлів: великі папки (кеші ігор) не повинні затримувати сканування
$script:DirSizeType = $null
function Get-DirSize([string]$Path, [int]$MaxFiles = 200000) {
    if (-not $script:DirSizeType) {
        Add-Type -TypeDefinition @'
using System; using System.Collections.Generic; using System.IO;
public static class DeadPixelDirSize {
    public static long Measure(string root, int maxFiles) {
        long total = 0; int files = 0;
        var stack = new Stack<string>(); stack.Push(root);
        while (stack.Count > 0 && files < maxFiles) {
            var dir = stack.Pop();
            try {
                foreach (var f in new DirectoryInfo(dir).EnumerateFileSystemInfos()) {
                    if ((f.Attributes & FileAttributes.ReparsePoint) != 0) continue;
                    if ((f.Attributes & FileAttributes.Directory) != 0) stack.Push(f.FullName);
                    else { total += ((FileInfo)f).Length; files++; }
                }
            } catch { }
        }
        return total;
    }
}
'@
        $script:DirSizeType = $true
    }
    if (Test-Path -LiteralPath $Path -PathType Leaf) { return (Get-Item -LiteralPath $Path -Force).Length }
    [DeadPixelDirSize]::Measure($Path, $MaxFiles)
}

function Format-Size([long]$b) {
    if ($b -ge 1GB) { (T '{0:N1} ГБ' '{0:N1} GB') -f ($b / 1GB) } elseif ($b -ge 1MB) { (T '{0:N0} МБ' '{0:N0} MB') -f ($b / 1MB) } else { (T '{0:N0} КБ' '{0:N0} KB') -f ($b / 1KB) }
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
    if ($c.Admin -and -not $admin) { $r = Unknown (T 'Для цієї перевірки потрібні права адміністратора.' 'This check needs administrator rights.') -Admin }
    else {
        try { $r = & $c.Test } catch { $r = Unknown ((T 'Не вдалося перевірити: ' 'Could not check: ') + $_.Exception.Message) }
        if ($r -is [array]) { $r = $r[-1] }   # випадковий вивід із Test не повинен зламати результат
        if (-not $r) { $r = Ok }
    }
    $fix = $c.Fix
    [pscustomobject]@{
        Id = $c.Id; Area = $area.Id; Title = $c.Title
        Status = $r.Status; Severity = [string]$r.Severity; Value = [string]$r.Value; Detail = [string]$r.Detail
        Evidence = @($r.Evidence | Where-Object { $_ }); Files = @($r.Files | Where-Object { $_ } | Select-Object -Unique)
        Cleanup = @($r.Cleanup | Where-Object { $_ })
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
    if ($score -ge 85) { T 'Добре' 'Good' } elseif ($score -ge 70) { T 'Є що покращити' 'Room to improve' } elseif ($score -ge 40) { T 'Ризиковано' 'Risky' } else { T 'Небезпечно' 'Dangerous' }
}

function Read-IgnoreList {
    $f = Join-Path (Get-DataDir) 'ignore.json'
    if (-not (Test-Path $f)) { return @() }
    # ConvertFrom-Json у PowerShell 5.1 віддає JSON-масив одним об'єктом - розгортаємо
    try { @((Get-Content $f -Raw -Encoding UTF8 | ConvertFrom-Json) | ForEach-Object { $_ }) } catch { @() }
}

function Write-IgnoreList([string[]]$ids) {
    ConvertTo-Json -InputObject @($ids | Sort-Object -Unique) | Set-Content -Encoding UTF8 (Join-Path (Get-DataDir) 'ignore.json')
}

# ---------------------------------------------------------------- розклад (Планувальник завдань)

$TaskPath = '\DEADPIXEL\'
$TaskName = 'DEADPIXEL Audit'

function Get-ScheduleTask {
    Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction SilentlyContinue
}

function Get-ScheduleDays {
    try {
        $t = Get-ScheduleTask
        if (-not $t -or $t.State -eq 'Disabled') { return 0 }
        [int](@($t.Triggers)[0].DaysInterval)
    } catch { 0 }
}

# Завдання запускає AuditGui.exe --background: це winexe, тож жодне вікно консолі не блимає.
# Свідомо БЕЗ прав адміністратора: AuditGui.exe лежить у папці, куди може писати будь-яка програма користувача
# (встановлення в %LOCALAPPDATA%\Programs), і завдання з найвищими правами стало б тією самою дірою, яку шукає аудит:
# підмінив exe - отримав права адміністратора. Повну перевірку дає «Сканувати з правами» вручну.
function Set-Schedule([int]$days) {
    # Командлети ScheduledTasks (CDXML-модуль) не бачать $ErrorActionPreference скрипта - тому -ErrorAction Stop явно.
    # Завдання, створене колись із правами адміністратора, звичайний користувач змінити не може: NEEDS_ADMIN для GUI
    try { Set-ScheduleCore $days }
    catch {
        if (-not (Test-Admin) -and ($_.Exception.Message -match 'denied|0x80070005|заборон' -or $_.CategoryInfo.Category -eq 'PermissionDenied')) {
            throw ('NEEDS_ADMIN: ' + (T 'розклад створено з правами адміністратора - змінити його можна лише з ними.' 'the schedule was created with administrator rights - it can only be changed with them.'))
        }
        throw
    }
}

function Set-ScheduleCore([int]$days) {
    if (Get-ScheduleTask) { Unregister-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -Confirm:$false -ErrorAction Stop }
    if ($days -le 0) { return }
    $gui = Join-Path $PSScriptRoot 'AuditGui.exe'
    if (-not (Test-Path $gui)) { throw ((T 'Не знайдено ' 'Not found: ') + $gui) }
    $action = New-ScheduledTaskAction -Execute $gui -Argument '--background'
    $trigger = New-ScheduledTaskTrigger -Daily -DaysInterval $days -At '12:00'
    # Пропущений запуск (ПК був вимкнений) - одразу, щойно ПК увімкнуть; низький пріоритет; не довше 15 хв
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 15) -Priority 7 -MultipleInstances IgnoreNew
    $principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal `
        -Description (T 'DEADPIXEL: перевірка безпеки і стану системи. Лише читає систему; результат - у треї і вікні «Аудит системи».' 'DEADPIXEL: security and system health check. Read-only; results appear in the tray and the "System audit" window.') -ErrorAction Stop | Out-Null
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
        Error = $null; Time = $time; IsAdmin = $admin; Score = $score; Grade = Get-Grade $score; Lang = $UiLang
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
    if (-not (Test-Path $latest)) { throw (T 'Ще немає звіту - спершу запустіть сканування.' 'There is no report yet - run a scan first.') }
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
    $sev = @{ critical = (T 'Критично' 'Critical'); high = (T 'Високий' 'High'); medium = (T 'Середній' 'Medium'); low = (T 'Низький' 'Low') }
    $sb = New-Object Text.StringBuilder
    $t = [datetime]$report.Time
    $null = $sb.Append(@"
<!doctype html><html lang="$UiLang"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>$(T 'Аудит системи DEADPIXEL' 'DEADPIXEL system audit')</title><style>
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
<h1>$(T 'Аудит системи' 'System audit')</h1>
<div class="muted">$(ConvertTo-HtmlText ("$($os.Name), " + (T 'збірка ' 'build ') + "$($os.Build).$($os.Ubr) · " + (T 'сканування ' 'scanned ') + $t.ToString('dd.MM.yyyy HH:mm') + $(if ($report.IsAdmin) { T ' · з правами адміністратора' ' · as administrator' })))</div>
<div class="head" style="margin-top:14px"><span class="score">$($report.Score)</span><span><b>$(ConvertTo-HtmlText $report.Grade)</b><br><span class="muted">$(T 'загальна оцінка з 100' 'overall score out of 100')</span></span></div>
"@)
    foreach ($a in $report.Areas) {
        $null = $sb.Append("<h2>$(ConvertTo-HtmlText $a.Title) <span class=`"muted`">· $($a.Score)</span></h2>`n")
        $rank = @{ critical = 0; high = 1; medium = 2; low = 3 }
        $mine = @($report.Results | Where-Object { $_.Area -eq $a.Id } | Sort-Object { if ($_.Ignored) { 9 } elseif ($_.Status -eq 'issue') { $rank[$_.Severity] } elseif ($_.Status -eq 'unknown') { 4 } elseif ($_.Status -eq 'info') { 5 } elseif ($_.Status -eq 'ok') { 6 } else { 7 } })
        foreach ($r in $mine) {
            $cls = if ($r.Ignored) { 'ign' } elseif ($r.Status -eq 'issue') { $r.Severity } else { $r.Status }
            $chip = if ($r.Ignored) { T 'Ігнорується' 'Ignored' } elseif ($r.Status -eq 'issue') { $sev[$r.Severity] } else { @{ ok = (T 'Гаразд' 'OK'); info = (T 'Інфо' 'Info'); unknown = (T 'Невідомо' 'Unknown'); na = (T 'Н/д' 'N/A') }[$r.Status] }
            $null = $sb.Append("<div class=`"item $cls`"><div class=`"row`"><span class=`"chip`">$chip</span><span class=`"title`">$(ConvertTo-HtmlText $r.Title)</span><span class=`"value`">$(ConvertTo-HtmlText $r.Value)</span></div>")
            if ($r.Status -in 'issue', 'info', 'unknown' -and -not $r.Ignored) {
                if ($r.Detail) { $null = $sb.Append("<div>$(ConvertTo-HtmlText $r.Detail)</div>") }
                if ($r.Status -eq 'issue') {
                    if ($r.Explain) { $null = $sb.Append("<h3>$(T 'Що це' 'What it is')</h3><div>$(ConvertTo-HtmlText $r.Explain)</div>") }
                    if ($r.Cons) { $null = $sb.Append(('<h3>' + (T 'Мінуси і на що зважити' 'Cons and things to consider') + '</h3><ul>') + (($r.Cons | ForEach-Object { "<li>$(ConvertTo-HtmlText $_)</li>" }) -join '') + '</ul>') }
                }
                if ($r.Evidence) { $null = $sb.Append(('<h3>' + (T 'Докази' 'Evidence') + '</h3><ul>') + (($r.Evidence | ForEach-Object { "<li>$(ConvertTo-HtmlText $_)</li>" }) -join '') + '</ul>') }
                if ($r.Status -eq 'issue' -and $r.Fix.Steps) { $null = $sb.Append(('<h3>' + (T 'Як виправити' 'How to fix') + '</h3><ul>') + (($r.Fix.Steps | ForEach-Object { "<li>$(ConvertTo-HtmlText $_)</li>" }) -join '') + '</ul>') }
            }
            $null = $sb.Append("</div>`n")
        }
    }
    $null = $sb.Append('<footer class="muted">' + (T 'Створено DEADPIXEL. Звіт містить відомості про цей ПК (програми, шляхи, мережі) - показуйте його лише тим, кому довіряєте.' 'Created by DEADPIXEL. The report contains information about this PC (programs, paths, networks) - share it only with people you trust.') + '</footer></main></body></html>')
    New-Item -ItemType Directory -Force (Split-Path $path) | Out-Null
    [IO.File]::WriteAllText($path, $sb.ToString(), (New-Object Text.UTF8Encoding $false))
}

# ---------------------------------------------------------------- консоль

$Tags = @{
    critical = @((T 'КРИТ' 'CRIT'), 'Red'); high = @((T 'ВИС ' 'HIGH'), 'Red'); medium = @((T 'СЕР ' 'MED '), 'Yellow'); low = @((T 'НИЗ ' 'LOW '), 'DarkYellow')
    ok = @(' OK ', 'Green'); info = @((T 'ІНФО' 'INFO'), 'Cyan'); unknown = @(' ?  ', 'DarkGray'); na = @(' —  ', 'DarkGray')
}

function Write-Report($report) {
    foreach ($a in $report.Areas) {
        Write-Host
        Write-Host ('{0}  {1}/100 ({2})' -f $a.Title, $a.Score, $a.Grade) -ForegroundColor Cyan
        foreach ($r in $report.Results | Where-Object { $_.Area -eq $a.Id }) {
            $t = if ($r.Status -eq 'issue') { $Tags[$r.Severity] } else { $Tags[$r.Status] }
            Write-Host ('  [{0}] ' -f $t[0]) -ForegroundColor $t[1] -NoNewline
            Write-Host $r.Title -NoNewline
            Write-Host ("  $($r.Value)" + $(if ($r.Ignored) { T '  (ігнорується)' '  (ignored)' } else { '' })) -ForegroundColor DarkGray
            if ($r.Status -in 'issue', 'unknown' -and $r.Detail -and -not $r.Ignored) { Write-Host "         $($r.Detail)" -ForegroundColor DarkGray }
        }
    }
    Write-Host
    $color = if ($report.Score -ge 85) { 'Green' } elseif ($report.Score -ge 40) { 'Yellow' } else { 'Red' }
    Write-Host ((T 'Загальна оцінка: {0}/100 - {1}' 'Overall score: {0}/100 - {1}') -f $report.Score, $report.Grade) -ForegroundColor $color
    if (-not $report.IsAdmin -and ($report.Results | Where-Object { $_.NeedsAdmin })) {
        Write-Host (T 'Частину перевірок пропущено: запустіть з правами адміністратора (Audit.cmd).' 'Some checks were skipped: run as administrator (Audit.cmd).') -ForegroundColor DarkGray
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
if ($Schedule -ge 0) { Write-Host $(if ($Schedule -gt 0) { T "Аудит запускатиметься автоматично раз на $Schedule дн." "The audit will run automatically every $Schedule days." } else { T 'Автоматичний аудит вимкнено.' 'Automatic audit is off.' }); exit 0 }
if ($Html) { Write-Host ((T 'Звіт: ' 'Report: ') + $Html); exit 0 }
Write-Report $report
# Код виходу = кількість активних критичних і високих знахідок (0 - немає), 255 - помилка запуску
exit [Math]::Min(254, @($report.Results | Where-Object { $_.Status -eq 'issue' -and -not $_.Ignored -and $_.Severity -in 'critical', 'high' }).Count)
