<#
.SYNOPSIS
  CrashDoctor - зводить у один звіт усе, що Windows записала про падіння, BSOD,
  зависання відеодрайвера (TDR), апаратні помилки (WHEA) та збої дисків/програм.

.EXAMPLE
  .\CrashDoctor.ps1                # останні 14 днів, HTML-звіт відкриється у браузері
  .\CrashDoctor.ps1 -Days 60       # за 60 днів
  .\CrashDoctor.ps1 -NoOpen        # не відкривати звіт автоматично
#>
param(
    [int]$Days = 14,
    [string]$OutDir = (Join-Path $PSScriptRoot 'reports'),
    [switch]$NoOpen
)

$ErrorActionPreference = 'SilentlyContinue'
$since = (Get-Date).AddDays(-$Days)
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# --- Довідник кодів BSOD (найчастіші) -------------------------------------
$BugChecks = @{
    0x0A  = @('IRQL_NOT_LESS_OR_EQUAL', 'Драйвер звернувся до недопустимої пам''яті. Часто драйвери або RAM/розгін.')
    0x1A  = @('MEMORY_MANAGEMENT', 'Помилка керування пам''яттю. Перевірити RAM (MemTest86), вимкнути EXPO/XMP.')
    0x1E  = @('KMODE_EXCEPTION_NOT_HANDLED', 'Необроблений виняток у драйвері.')
    0x3B  = @('SYSTEM_SERVICE_EXCEPTION', 'Виняток у системному виклику, часто драйвер.')
    0x50  = @('PAGE_FAULT_IN_NONPAGED_AREA', 'Звернення до неіснуючої пам''яті: драйвер, RAM або диск.')
    0x7E  = @('SYSTEM_THREAD_EXCEPTION_NOT_HANDLED', 'Необроблений виняток у системному потоці (драйвер).')
    0x7F  = @('UNEXPECTED_KERNEL_MODE_TRAP', 'Апаратна проблема або розгін CPU/RAM.')
    0x9F  = @('DRIVER_POWER_STATE_FAILURE', 'Драйвер не впорався з переходом у сон/пробудження.')
    0xA0  = @('INTERNAL_POWER_ERROR', 'Помилка керування живленням.')
    0xD1  = @('DRIVER_IRQL_NOT_LESS_OR_EQUAL', 'Драйвер звернувся до пам''яті на високому IRQL.')
    0xEF  = @('CRITICAL_PROCESS_DIED', 'Критичний системний процес завершився (диск/система).')
    0x101 = @('CLOCK_WATCHDOG_TIMEOUT', 'Ядро CPU не відповідає: розгін/Curve Optimizer/нестабільний CPU.')
    0x116 = @('VIDEO_TDR_FAILURE', 'Відеодрайвер завис, і Windows не змогла його перезапустити. Драйвер GPU, розгін GPU, живлення відеокарти.')
    0x117 = @('VIDEO_TDR_TIMEOUT_DETECTED', 'Відеодрайвер перестав відповідати (відновлено).')
    0x119 = @('VIDEO_SCHEDULER_INTERNAL_ERROR', 'Помилка планувальника GPU (драйвер/GPU).')
    0x124 = @('WHEA_UNCORRECTABLE_ERROR', 'Некоректовна апаратна помилка (CPU/RAM/PCIe). Дивіться розділ WHEA.')
    0x133 = @('DPC_WATCHDOG_VIOLATION', 'Драйвер занадто довго тримав процесор (часто GPU/диск/мережа).')
    0x139 = @('KERNEL_SECURITY_CHECK_FAILURE', 'Пошкодження структур ядра: драйвер або RAM.')
    0x141 = @('VIDEO_ENGINE_TIMEOUT_DETECTED', 'GPU перестав відповідати, Windows перезапустила драйвер (без BSOD).')
    0x144 = @('BUGCODE_USB3_DRIVER', 'Помилка USB3-драйвера.')
    0x154 = @('UNEXPECTED_STORE_EXCEPTION', 'Проблема з диском або пам''яттю.')
    0x15F = @('CONNECTED_STANDBY_WATCHDOG_TIMEOUT_LIVEDUMP', 'Зависання під час сну.')
    0x1A8 = @('BUGCODE_NDIS_DRIVER_LIVE_DUMP', 'Мережевий драйвер.')
    0x1B8 = @('GPU_LIVE_DUMP', 'Живий дамп стану GPU, знятий разом із TDR.')
}
function Get-BugCheckInfo([string]$hex) {
    $code = [Convert]::ToInt64(($hex -replace '^0x', ''), 16)
    if ($BugChecks.ContainsKey([int]$code)) { return $BugChecks[[int]$code] }
    return @('UNKNOWN', ('Невідомий код — шукайте "bugcheck 0x{0:X}"' -f $code))
}
function Short([string]$s, [int]$n = 300) {
    $s = ($s -replace '\s+', ' ').Trim()
    if ($s.Length -gt $n) { $s.Substring(0, $n) + '…' } else { $s }
}
function Enc([string]$s) { [System.Net.WebUtility]::HtmlEncode($s) }
function Get-Ev($filter, [int]$max = 2000) {
    $filter.StartTime = $since
    @(Get-WinEvent -FilterHashtable $filter -MaxEvents $max -ErrorAction SilentlyContinue)
}

Write-Host "CrashDoctor: збираю дані за $Days днів..." -ForegroundColor Cyan
if (-not $isAdmin) { Write-Host "  (без прав адміністратора частина даних недоступна — запускайте через CrashDoctor.cmd)" -ForegroundColor Yellow }

# --- 1. Непередбачені перезавантаження ------------------------------------
$unexpected = Get-Ev @{LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Power'; Id = 41 }
$bsod       = Get-Ev @{LogName = 'System'; ProviderName = 'Microsoft-Windows-WER-SystemErrorReporting'; Id = 1001 }
$relDriver  = Get-Ev @{LogName = 'System'; ProviderName = 'Microsoft-Windows-WER-SystemErrorReporting'; Id = 1019 }

$crashRows = foreach ($e in $unexpected) {
    $bc = ($e.Properties[0].Value)
    # BSOD-подія записується через кілька секунд після Kernel-Power 41
    $match = $bsod | Where-Object { [math]::Abs(($_.TimeCreated - $e.TimeCreated).TotalMinutes) -lt 5 } | Select-Object -First 1
    $drv   = $relDriver | Where-Object { [math]::Abs(($_.TimeCreated - $e.TimeCreated).TotalMinutes) -lt 5 } | Select-Object -First 1
    $code = $null; $params = ''; $dump = ''
    if ($match -and [string]$match.Properties[0].Value -match '^(0x[0-9a-fA-F]+) \(([^)]*)\)') {
        $code = $Matches[1]; $params = $Matches[2]
        $dump = [string]$match.Properties[1].Value
    } elseif ($bc -and [int64]$bc -ne 0) {
        $code = '0x{0:X8}' -f [int64]$bc
    }
    $info = if ($code) { Get-BugCheckInfo $code } else { @('—', 'Без BSOD: раптова втрата живлення, зависання з ручним ресетом, або БЖ/перегрів.') }
    $driver = ''
    if ($drv) { $driver = [string]$drv.Properties[0].Value }
    [pscustomobject]@{
        Time = $e.TimeCreated; Code = $code; Name = $info[0]; Hint = $info[1]
        Params = $params; Driver = $driver; Dump = $dump
    }
}

# --- 2. Live Kernel Events / TDR (відновлені зависання GPU) ---------------
$werEvents = Get-Ev @{LogName = 'Application'; ProviderName = 'Windows Error Reporting'; Id = 1001 } 20000
# WER кожні кілька годин повторно надсилає ті самі звіти, тому рахуємо за унікальним файлом дампу,
# а реальний час події беремо з імені файлу (напр. WATCHDOG-20261001-0232.dmp)
$lke = foreach ($e in $werEvents) {
    # властивості події не залежать від мови Windows: [2] = назва події, [5] = P1, [15] = вкладені файли
    if ([string]$e.Properties[2].Value -eq 'LiveKernelEvent' -and [string]$e.Properties[5].Value -match '^([0-9a-fA-F]+)$') {
        $c = '0x' + $Matches[1]
        $file = if ([string]$e.Properties[15].Value -match '(\S*LiveKernelReports\S+?\.dmp)') { $Matches[1] -replace '^\\\\\?\\', '' } else { '' }
        $time = $e.TimeCreated
        if ($file -match '-(\d{8})-(\d{4})(-\d+)?\.dmp$') { $time = [datetime]::ParseExact("$($Matches[1])$($Matches[2])", 'yyyyMMddHHmm', $null) }
        [pscustomobject]@{ Time = $time; Code = $c; Name = (Get-BugCheckInfo $c)[0]; File = $file }
    }
}
$lke = $lke | Group-Object { if ($_.File) { $_.File } else { "$($_.Code)|$($_.Time)" } } |
    ForEach-Object { $_.Group[0] } | Where-Object Time -ge $since | Sort-Object Time -Descending
$lkrFiles = Get-ChildItem "$env:SystemRoot\LiveKernelReports" -Recurse -File -Filter *.dmp |
    Where-Object LastWriteTime -ge $since | Sort-Object LastWriteTime -Descending

$tdr = @()
$tdr += Get-Ev @{LogName = 'System'; ProviderName = 'nvlddmkm' }
$tdr += Get-Ev @{LogName = 'System'; ProviderName = 'amdkmdag' }
$tdr += Get-Ev @{LogName = 'System'; ProviderName = 'Display'; Id = 4101 }
$tdr = $tdr | Sort-Object TimeCreated -Descending

# --- 3. WHEA (апаратні помилки CPU/RAM/PCIe) ------------------------------
$whea = Get-Ev @{LogName = 'System'; ProviderName = 'Microsoft-Windows-WHEA-Logger' }

# --- 4. Диски --------------------------------------------------------------
$diskEv = @()
foreach ($p in 'disk', 'Ntfs', 'stornvme', 'storahci', 'volmgr') {
    $diskEv += Get-Ev @{LogName = 'System'; ProviderName = $p; Level = 1, 2, 3 } 5000
}
$diskEv = $diskEv | Where-Object { $_.Id -ne 162 }  # 162 = "дамп створено успішно"
$diskSummary = $diskEv | Group-Object ProviderName, Id | ForEach-Object {
    $last = $_.Group | Sort-Object TimeCreated -Descending | Select-Object -First 1
    $diskNum = if ($last.Message -match 'Disk (\d+)|Harddisk(\d+)') { ($Matches[1], $Matches[2] | Where-Object { $_ })[0] } else { '' }
    [pscustomobject]@{ Source = $_.Name; Count = $_.Count; Disk = $diskNum; Last = $last.TimeCreated; Example = Short $last.Message 220 }
} | Sort-Object Count -Descending

# --- 5. Збої програм -------------------------------------------------------
$appCrash = Get-Ev @{LogName = 'Application'; ProviderName = 'Application Error'; Id = 1000 }
$appHang  = Get-Ev @{LogName = 'Application'; ProviderName = 'Application Hang'; Id = 1002 }
$appSummary = @($appCrash + $appHang) | ForEach-Object {
    $exe = $_.Properties[0].Value
    $mod = if ($_.Id -eq 1000) { $_.Properties[3].Value } else { '(зависання)' }
    [pscustomobject]@{ Exe = $exe; Module = $mod; Time = $_.TimeCreated }
} | Group-Object Exe, Module | ForEach-Object {
    [pscustomobject]@{ App = $_.Group[0].Exe; Module = $_.Group[0].Module; Count = $_.Count; Last = ($_.Group.Time | Sort-Object -Descending)[0] }
} | Sort-Object Count -Descending | Select-Object -First 20

# --- 6. Штатні перезавантаження (для контексту) ---------------------------
$planned = Get-Ev @{LogName = 'System'; ProviderName = 'User32'; Id = 1074 } | ForEach-Object {
    [pscustomobject]@{ Time = $_.TimeCreated; Proc = (Split-Path $_.Properties[0].Value -Leaf); Reason = $_.Properties[2].Value; Type = $_.Properties[4].Value }
}

# --- 7. Система ------------------------------------------------------------
$os   = Get-CimInstance Win32_OperatingSystem
$cpu  = (Get-CimInstance Win32_Processor | Select-Object -First 1).Name
$mb   = Get-CimInstance Win32_BaseBoard
$bios = Get-CimInstance Win32_BIOS
$ram  = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
$gpus = Get-CimInstance Win32_VideoController | ForEach-Object {
    $ageDays = if ($_.DriverDate) { [int]((Get-Date) - $_.DriverDate).TotalDays } else { $null }
    [pscustomobject]@{ Name = $_.Name; Driver = $_.DriverVersion; Date = $_.DriverDate; AgeDays = $ageDays }
}
$disks = Get-PhysicalDisk | Select-Object DeviceId, FriendlyName, MediaType, BusType, HealthStatus
$minidumps = Get-ChildItem "$env:SystemRoot\Minidump" -File -Filter *.dmp | Sort-Object LastWriteTime -Descending | Select-Object -First 15
$uptime = (Get-Date) - $os.LastBootUpTime

# --- 8. Автоматичні висновки ----------------------------------------------
$findings = New-Object System.Collections.Generic.List[object]
function Add-Finding($level, $title, $text) { $findings.Add([pscustomobject]@{ Level = $level; Title = $title; Text = $text }) }

$gpuCrashes = @($crashRows | Where-Object { $_.Code -and ([Convert]::ToInt64(($_.Code -replace '^0x', ''), 16) -in 0x116, 0x117, 0x119) })
$gpuDrivers = @($crashRows | Where-Object { $_.Driver -match 'nvlddmkm|amdkmdag|atikmdag|igdkmd|dxgkrnl' })
if ($gpuCrashes.Count -or $gpuDrivers.Count -or @($lke | Where-Object { $_.Code -match '^0x(141|117)$' }).Count) {
    $nv = $gpus | Where-Object Name -match 'NVIDIA' | Select-Object -First 1
    $t = "BSOD через відеодрайвер: $($gpuCrashes.Count), відновлених зависань GPU (LiveKernelEvent 141/117): $(@($lke | Where-Object { $_.Code -match '^0x(141|117)$' }).Count)."
    if ($nv -and $nv.AgeDays -gt 90) { $t += " Драйвер $($nv.Name) $($nv.Driver) має вік $($nv.AgeDays) днів — оновіть (чиста інсталяція, або DDU)." }
    $t += ' Також перевірте: розгін/андервольт GPU (MSI Afterburner), окремі кабелі 12V-2x6/PCIe від БЖ і чи щільно вставлений роз''єм, вимкнути "Аппаратне прискорення планування GPU" для тесту.'
    Add-Finding 'crit' 'Проблема з відеокартою / драйвером GPU' $t
}
$dpc = @($crashRows | Where-Object { $_.Code -match '0x0*133$' })
if ($dpc.Count) { Add-Finding 'warn' "DPC_WATCHDOG_VIOLATION ×$($dpc.Count)" 'Драйвер занадто довго блокував CPU. Часто це той самий GPU-драйвер, рідше драйвер NVMe/мережі/USB.' }
$noBsod = @($crashRows | Where-Object { -not $_.Code })
if ($noBsod.Count) { Add-Finding 'warn' "Раптові вимкнення без BSOD ×$($noBsod.Count)" 'Втрата живлення, ручний ресет під час зависання, спрацювання захисту БЖ або перегрів.' }
$usb = @($lke | Where-Object { $_.Code -match '^0x144$' }).Count
if ($usb) { Add-Finding 'warn' "Збої USB3-контролера (0x144) ×$usb" 'Проблемний USB-пристрій (часто зовнішній диск/хаб) або драйвер USB. Спробуйте інший порт (ззаду на платі), без хабів, оновіть чипсет-драйвер AMD.' }
if ($whea.Count) { Add-Finding 'crit' "Апаратні помилки WHEA ×$($whea.Count)" 'CPU/RAM/PCIe повідомляють про помилки. Скиньте розгін (EXPO/PBO/Curve Optimizer), перевірте RAM.' }
$badDisk = $diskSummary | Where-Object { $_.Source -match '^disk, (7|51|153|154)$' }
if ($badDisk) {
    $known = @($disks.DeviceId)
    foreach ($d in $badDisk | Group-Object Disk) {
        $cnt = ($d.Group | Measure-Object Count -Sum).Sum
        $absent = $d.Name -and ($known -notcontains $d.Name)
        $txt = "Помилки введення-виведення: $cnt шт. (лічильник обмежено 5000 на тип)."
        if ($absent) { $txt += " Диска №$($d.Name) зараз немає в системі — ймовірно, це USB-флешка / зовнішній диск / кардрідер. Перевірте його окремо (chkdsk, CrystalDiskInfo) або не підключайте." }
        Add-Finding 'warn' "Помилки диска №$($d.Name)" $txt
    }
}
if (-not $findings.Count) { Add-Finding 'ok' 'Критичних проблем не знайдено' "За $Days днів немає аварійних перезавантажень." }

# --- 9. HTML-звіт ----------------------------------------------------------
function Table($rows, [string[]]$cols) {
    if (-not $rows) { return '<p class="muted">Немає записів.</p>' }
    $h = '<div class="tw"><table><tr>' + (($cols | ForEach-Object { "<th>$(Enc $_)</th>" }) -join '') + '</tr>'
    foreach ($r in $rows) {
        $h += '<tr>' + (($cols | ForEach-Object {
            $v = $r.$_
            if ($v -is [datetime]) { $v = $v.ToString('yyyy-MM-dd HH:mm:ss') }
            "<td>$(Enc ([string]$v))</td>"
        }) -join '') + '</tr>'
    }
    $h + '</table></div>'
}

$stamp = Get-Date -Format 'yyyy-MM-dd_HH-mm'
New-Item -ItemType Directory -Force $OutDir | Out-Null
$htmlPath = Join-Path $OutDir "CrashDoctor_$stamp.html"
$txtPath  = Join-Path $OutDir "CrashDoctor_$stamp.txt"

$findingsHtml = ($findings | ForEach-Object { "<div class='f $($_.Level)'><b>$(Enc $_.Title)</b><p>$(Enc $_.Text)</p></div>" }) -join "`n"
$tdrRows = $tdr | Select-Object -First 40 | ForEach-Object {
    $msg = if ($_.Message) { Short $_.Message 200 } else { Short (($_.Properties | ForEach-Object { $_.Value } | Where-Object { $_ -is [string] }) -join ' | ') 200 }
    [pscustomobject]@{ Time = $_.TimeCreated; Source = "$($_.ProviderName) $($_.Id)"; Message = $msg }
}
$wheaRows = $whea | Select-Object -First 40 | ForEach-Object { [pscustomobject]@{ Time = $_.TimeCreated; Id = $_.Id; Message = Short $_.Message 250 } }
$lkrRows = $lkrFiles | Select-Object -First 30 | ForEach-Object { [pscustomobject]@{ Time = $_.LastWriteTime; Type = $_.Directory.Name; File = $_.FullName; SizeMB = [math]::Round($_.Length / 1MB, 1) } }
$dumpRows = $minidumps | ForEach-Object { [pscustomobject]@{ Time = $_.LastWriteTime; File = $_.FullName; SizeMB = [math]::Round($_.Length / 1MB, 1) } }

$html = @"
<!doctype html><html lang="uk"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>CrashDoctor $stamp</title>
<style>
:root{--bg:#f6f7f9;--card:#fff;--fg:#1c1f24;--muted:#6b7280;--line:#e3e6ea;--crit:#c62828;--warn:#b26a00;--ok:#2e7d32}
@media (prefers-color-scheme:dark){:root{--bg:#15171b;--card:#1e2126;--fg:#e6e8eb;--muted:#9aa1ab;--line:#2c3037;--crit:#ef5350;--warn:#ffb74d;--ok:#66bb6a}}
body{background:var(--bg);color:var(--fg);font:14px/1.5 Segoe UI,system-ui,sans-serif;margin:0;padding:24px 16px}
main{max-width:1200px;margin:auto}h1{margin:0 0 4px}h2{margin:28px 0 8px;font-size:18px}
.muted{color:var(--muted)}.card{background:var(--card);border:1px solid var(--line);border-radius:8px;padding:12px 16px}
.f{background:var(--card);border:1px solid var(--line);border-left:4px solid var(--muted);border-radius:6px;padding:8px 14px;margin:8px 0}
.f p{margin:4px 0 0}.f.crit{border-left-color:var(--crit)}.f.warn{border-left-color:var(--warn)}.f.ok{border-left-color:var(--ok)}
.tw{overflow-x:auto}table{border-collapse:collapse;width:100%;background:var(--card);font-size:13px}
th,td{border-bottom:1px solid var(--line);padding:6px 8px;text-align:left;vertical-align:top}th{color:var(--muted);font-weight:600}
code{font-family:Consolas,monospace}
</style></head><body><main>
<h1>CrashDoctor</h1>
<div class="muted">$(Enc $env:COMPUTERNAME) · звіт від $(Get-Date -Format 'yyyy-MM-dd HH:mm') · період: $Days днів · адмін: $isAdmin</div>

<h2>Висновки</h2>
$findingsHtml

<h2>Аварійні перезавантаження ($(@($crashRows).Count))</h2>
$(Table ($crashRows | Sort-Object Time -Descending) @('Time','Code','Name','Driver','Hint','Params','Dump'))

<h2>Відновлені зависання ядра / GPU (LiveKernelEvent)</h2>
$(Table $lke @('Time','Code','Name','File'))
$(Table $lkrRows @('Time','Type','File','SizeMB'))

<h2>Події відеодрайвера (TDR)</h2>
$(Table $tdrRows @('Time','Source','Message'))

<h2>Апаратні помилки WHEA ($(@($whea).Count))</h2>
$(Table $wheaRows @('Time','Id','Message'))

<h2>Помилки дисків</h2>
$(Table $diskSummary @('Source','Count','Disk','Last','Example'))

<h2>Збої та зависання програм (топ-20)</h2>
$(Table $appSummary @('App','Module','Count','Last'))

<h2>Штатні перезавантаження / вимкнення</h2>
$(Table ($planned | Select-Object -First 20) @('Time','Proc','Reason','Type'))

<h2>Система</h2>
<div class="card">
<b>ОС:</b> $(Enc $os.Caption) $(Enc $os.Version) (build $(Enc $os.BuildNumber)) · аптайм $([int]$uptime.TotalHours) год<br>
<b>CPU:</b> $(Enc $cpu) · <b>RAM:</b> $ram GB<br>
<b>Плата:</b> $(Enc $mb.Manufacturer) $(Enc $mb.Product) · <b>BIOS:</b> $(Enc $bios.SMBIOSBIOSVersion) ($(if($bios.ReleaseDate){$bios.ReleaseDate.ToString('yyyy-MM-dd')}))
</div>
$(Table $gpus @('Name','Driver','Date','AgeDays'))
$(Table $disks @('DeviceId','FriendlyName','MediaType','BusType','HealthStatus'))

<h2>Файли дампів</h2>
$(Table $dumpRows @('Time','File','SizeMB'))
<p class="muted">Детальний аналіз дампу: встановіть WinDbg (<code>winget install Microsoft.WinDbg</code>), відкрийте .dmp і виконайте <code>!analyze -v</code>. Або BlueScreenView від NirSoft.</p>
</main></body></html>
"@
$html | Out-File -Encoding utf8 $htmlPath

# Текстова версія — зручно скопіювати в чат
$txt = @()
$txt += "CrashDoctor $stamp | $env:COMPUTERNAME | $Days днів"
$txt += "`n== ВИСНОВКИ =="
$txt += $findings | ForEach-Object { "[$($_.Level.ToUpper())] $($_.Title)`n    $($_.Text)" }
$txt += "`n== АВАРІЙНІ ПЕРЕЗАВАНТАЖЕННЯ =="
$txt += $crashRows | Sort-Object Time -Descending | ForEach-Object { "{0:yyyy-MM-dd HH:mm}  {1,-10} {2,-32} {3}" -f $_.Time, $_.Code, $_.Name, $_.Driver }
$txt += "`n== LiveKernelEvent =="
$txt += $lke | ForEach-Object { "{0:yyyy-MM-dd HH:mm}  {1,-6} {2,-32} {3}" -f $_.Time, $_.Code, $_.Name, $_.File }
$txt += "`n== GPU =="
$txt += $gpus | ForEach-Object { "{0}  driver {1}  ({2} днів)" -f $_.Name, $_.Driver, $_.AgeDays }
$txt += "`n== ДИСКИ (помилки) =="
$txt += $diskSummary | ForEach-Object { "{0,-14} x{1,-6} disk {2}  last {3:yyyy-MM-dd HH:mm}" -f $_.Source, $_.Count, $_.Disk, $_.Last }
$txt += "`n== WHEA: $(@($whea).Count) подій"
$txt -join "`n" | Out-File -Encoding utf8 $txtPath

Write-Host ''
$findings | ForEach-Object {
    $c = @{ crit = 'Red'; warn = 'Yellow'; ok = 'Green' }[$_.Level]
    Write-Host "[$($_.Level.ToUpper())] $($_.Title)" -ForegroundColor $c
    Write-Host "    $($_.Text)"
}
Write-Host "`nЗвіт: $htmlPath`nТекст: $txtPath" -ForegroundColor Cyan
if (-not $NoOpen) { Start-Process $htmlPath }
