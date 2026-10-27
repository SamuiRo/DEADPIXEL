<#
.SYNOPSIS
  DEADPIXEL - зводить у один звіт усе, що Windows записала про падіння, BSOD,
  зависання відеодрайвера (TDR), апаратні помилки (WHEA) та збої дисків/програм.

.EXAMPLE
  .\DeadPixel.ps1                # останні 14 днів, HTML-звіт відкриється у браузері
  .\DeadPixel.ps1 -Days 60       # за 60 днів
  .\DeadPixel.ps1 -NoOpen        # не відкривати звіт автоматично
  .\DeadPixel.ps1 -Lang en       # мова звіту (system / uk / en; за замовчуванням - з налаштувань)
#>
param(
    [int]$Days = 14,
    [string]$OutDir = (Join-Path $PSScriptRoot 'reports'),
    [switch]$NoOpen,
    [string]$Lang
)

$ErrorActionPreference = 'SilentlyContinue'
. (Join-Path $PSScriptRoot 'modules\common\Lang.ps1')
$script:UiLang = Resolve-UiLang $Lang $PSScriptRoot
$since = (Get-Date).AddDays(-$Days)
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# --- Довідник кодів BSOD (найчастіші) -------------------------------------
$BugChecks = @{
    0x0A  = @('IRQL_NOT_LESS_OR_EQUAL', (T 'Драйвер звернувся до недопустимої пам''яті. Часто драйвери або RAM/розгін.' 'A driver accessed invalid memory. Often drivers or RAM/overclocking.'))
    0x1A  = @('MEMORY_MANAGEMENT', (T 'Помилка керування пам''яттю. Перевірити RAM (MemTest86), вимкнути EXPO/XMP.' 'Memory management error. Test RAM (MemTest86), disable EXPO/XMP.'))
    0x1E  = @('KMODE_EXCEPTION_NOT_HANDLED', (T 'Необроблений виняток у драйвері.' 'Unhandled exception in a driver.'))
    0x3B  = @('SYSTEM_SERVICE_EXCEPTION', (T 'Виняток у системному виклику, часто драйвер.' 'Exception in a system call, often a driver.'))
    0x50  = @('PAGE_FAULT_IN_NONPAGED_AREA', (T 'Звернення до неіснуючої пам''яті: драйвер, RAM або диск.' 'Access to non-existent memory: driver, RAM or disk.'))
    0x7E  = @('SYSTEM_THREAD_EXCEPTION_NOT_HANDLED', (T 'Необроблений виняток у системному потоці (драйвер).' 'Unhandled exception in a system thread (driver).'))
    0x7F  = @('UNEXPECTED_KERNEL_MODE_TRAP', (T 'Апаратна проблема або розгін CPU/RAM.' 'Hardware problem or CPU/RAM overclocking.'))
    0x9F  = @('DRIVER_POWER_STATE_FAILURE', (T 'Драйвер не впорався з переходом у сон/пробудження.' 'A driver failed a sleep/wake transition.'))
    0xA0  = @('INTERNAL_POWER_ERROR', (T 'Помилка керування живленням.' 'Power management error.'))
    0xD1  = @('DRIVER_IRQL_NOT_LESS_OR_EQUAL', (T 'Драйвер звернувся до пам''яті на високому IRQL.' 'A driver accessed memory at a high IRQL.'))
    0xEF  = @('CRITICAL_PROCESS_DIED', (T 'Критичний системний процес завершився (диск/система).' 'A critical system process died (disk/system).'))
    0x101 = @('CLOCK_WATCHDOG_TIMEOUT', (T 'Ядро CPU не відповідає: розгін/Curve Optimizer/нестабільний CPU.' 'A CPU core stopped responding: overclocking/Curve Optimizer/unstable CPU.'))
    0x116 = @('VIDEO_TDR_FAILURE', (T 'Відеодрайвер завис, і Windows не змогла його перезапустити. Драйвер GPU, розгін GPU, живлення відеокарти.' 'The graphics driver hung and Windows could not restart it. GPU driver, GPU overclock, graphics card power.'))
    0x117 = @('VIDEO_TDR_TIMEOUT_DETECTED', (T 'Відеодрайвер перестав відповідати (відновлено).' 'The graphics driver stopped responding (recovered).'))
    0x119 = @('VIDEO_SCHEDULER_INTERNAL_ERROR', (T 'Помилка планувальника GPU (драйвер/GPU).' 'GPU scheduler error (driver/GPU).'))
    0x124 = @('WHEA_UNCORRECTABLE_ERROR', (T 'Некоректовна апаратна помилка (CPU/RAM/PCIe). Дивіться розділ WHEA.' 'Uncorrectable hardware error (CPU/RAM/PCIe). See the WHEA section.'))
    0x133 = @('DPC_WATCHDOG_VIOLATION', (T 'Драйвер занадто довго тримав процесор (часто GPU/диск/мережа).' 'A driver held the CPU too long (often GPU/disk/network).'))
    0x139 = @('KERNEL_SECURITY_CHECK_FAILURE', (T 'Пошкодження структур ядра: драйвер або RAM.' 'Kernel structure corruption: driver or RAM.'))
    0x141 = @('VIDEO_ENGINE_TIMEOUT_DETECTED', (T 'GPU перестав відповідати, Windows перезапустила драйвер (без BSOD).' 'The GPU stopped responding and Windows restarted the driver (no BSOD).'))
    0x144 = @('BUGCODE_USB3_DRIVER', (T 'Помилка USB3-драйвера.' 'USB3 driver error.'))
    0x154 = @('UNEXPECTED_STORE_EXCEPTION', (T 'Проблема з диском або пам''яттю.' 'Disk or memory problem.'))
    0x15F = @('CONNECTED_STANDBY_WATCHDOG_TIMEOUT_LIVEDUMP', (T 'Зависання під час сну.' 'Hang during sleep.'))
    0x1A8 = @('BUGCODE_NDIS_DRIVER_LIVE_DUMP', (T 'Мережевий драйвер.' 'Network driver.'))
    0x1B8 = @('GPU_LIVE_DUMP', (T 'Живий дамп стану GPU, знятий разом із TDR.' 'Live GPU state dump taken together with a TDR.'))
}
function Get-BugCheckInfo([string]$hex) {
    $code = [Convert]::ToInt64(($hex -replace '^0x', ''), 16)
    if ($BugChecks.ContainsKey([int]$code)) { return $BugChecks[[int]$code] }
    return @('UNKNOWN', ((T 'Невідомий код — шукайте "bugcheck 0x{0:X}"' 'Unknown code — search for "bugcheck 0x{0:X}"') -f $code))
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

Write-Host (T "DEADPIXEL: збираю дані за $Days днів..." "DEADPIXEL: collecting data for $Days days...") -ForegroundColor Cyan
if (-not $isAdmin) { Write-Host (T '  (без прав адміністратора частина даних недоступна — запускайте через DeadPixel.cmd)' '  (some data is unavailable without administrator rights — run via DeadPixel.cmd)') -ForegroundColor Yellow }

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
    $info = if ($code) { Get-BugCheckInfo $code } else { @('—', (T 'Без BSOD: раптова втрата живлення, зависання з ручним ресетом, або БЖ/перегрів.' 'No BSOD: sudden power loss, a hang with a manual reset, or PSU/overheating.')) }
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
$hangLabel = T '(зависання)' '(hang)'
$appSummary = @($appCrash + $appHang) | ForEach-Object {
    $exe = $_.Properties[0].Value
    $mod = if ($_.Id -eq 1000) { $_.Properties[3].Value } else { $hangLabel }
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
$gpuHangs = @($lke | Where-Object { $_.Code -match '^0x(141|117)$' }).Count
if ($gpuCrashes.Count -or $gpuDrivers.Count -or $gpuHangs) {
    $nv = $gpus | Where-Object Name -match 'NVIDIA' | Select-Object -First 1
    $t = T "BSOD через відеодрайвер: $($gpuCrashes.Count), відновлених зависань GPU (LiveKernelEvent 141/117): $gpuHangs." "BSODs caused by the graphics driver: $($gpuCrashes.Count), recovered GPU hangs (LiveKernelEvent 141/117): $gpuHangs."
    if ($nv -and $nv.AgeDays -gt 90) { $t += T " Драйвер $($nv.Name) $($nv.Driver) має вік $($nv.AgeDays) днів — оновіть (чиста інсталяція, або DDU)." " Driver $($nv.Name) $($nv.Driver) is $($nv.AgeDays) days old — update it (clean install, or DDU)." }
    $t += T ' Також перевірте: розгін/андервольт GPU (MSI Afterburner), окремі кабелі 12V-2x6/PCIe від БЖ і чи щільно вставлений роз''єм, вимкнути "Аппаратне прискорення планування GPU" для тесту.' ' Also check: GPU overclock/undervolt (MSI Afterburner), separate 12V-2x6/PCIe cables from the PSU and that the connector is fully seated; turn off "Hardware-accelerated GPU scheduling" as a test.'
    Add-Finding 'crit' (T 'Проблема з відеокартою / драйвером GPU' 'Graphics card / GPU driver problem') $t
}
$dpc = @($crashRows | Where-Object { $_.Code -match '0x0*133$' })
if ($dpc.Count) { Add-Finding 'warn' "DPC_WATCHDOG_VIOLATION ×$($dpc.Count)" (T 'Драйвер занадто довго блокував CPU. Часто це той самий GPU-драйвер, рідше драйвер NVMe/мережі/USB.' 'A driver blocked the CPU too long. Often the same GPU driver, less often an NVMe/network/USB driver.') }
$noBsod = @($crashRows | Where-Object { -not $_.Code })
if ($noBsod.Count) { Add-Finding 'warn' ((T 'Раптові вимкнення без BSOD ×' 'Sudden shutdowns without BSOD ×') + $noBsod.Count) (T 'Втрата живлення, ручний ресет під час зависання, спрацювання захисту БЖ або перегрів.' 'Power loss, a manual reset during a hang, PSU protection tripping, or overheating.') }
$usb = @($lke | Where-Object { $_.Code -match '^0x144$' }).Count
if ($usb) { Add-Finding 'warn' ((T 'Збої USB3-контролера (0x144) ×' 'USB3 controller failures (0x144) ×') + $usb) (T 'Проблемний USB-пристрій (часто зовнішній диск/хаб) або драйвер USB. Спробуйте інший порт (ззаду на платі), без хабів, оновіть чипсет-драйвер AMD.' 'A faulty USB device (often an external disk/hub) or USB driver. Try another port (on the back of the board), without hubs, and update the chipset driver.') }
if ($whea.Count) { Add-Finding 'crit' ((T 'Апаратні помилки WHEA ×' 'WHEA hardware errors ×') + $whea.Count) (T 'CPU/RAM/PCIe повідомляють про помилки. Скиньте розгін (EXPO/PBO/Curve Optimizer), перевірте RAM.' 'CPU/RAM/PCIe report errors. Reset overclocking (EXPO/PBO/Curve Optimizer) and test RAM.') }
$badDisk = $diskSummary | Where-Object { $_.Source -match '^disk, (7|51|153|154)$' }
if ($badDisk) {
    $known = @($disks.DeviceId)
    foreach ($d in $badDisk | Group-Object Disk) {
        $cnt = ($d.Group | Measure-Object Count -Sum).Sum
        $absent = $d.Name -and ($known -notcontains $d.Name)
        $txt = T "Помилки введення-виведення: $cnt шт. (лічильник обмежено 5000 на тип)." "I/O errors: $cnt (counter capped at 5000 per type)."
        if ($absent) { $txt += T " Диска №$($d.Name) зараз немає в системі — ймовірно, це USB-флешка / зовнішній диск / кардрідер. Перевірте його окремо (chkdsk, CrystalDiskInfo) або не підключайте." " Disk #$($d.Name) is not in the system now — probably a USB stick / external disk / card reader. Check it separately (chkdsk, CrystalDiskInfo) or stop connecting it." }
        Add-Finding 'warn' ((T 'Помилки диска №' 'Errors on disk #') + $d.Name) $txt
    }
}
if (-not $findings.Count) { Add-Finding 'ok' (T 'Критичних проблем не знайдено' 'No critical problems found') (T "За $Days днів немає аварійних перезавантажень." "No crash restarts in $Days days.") }

# --- 9. HTML-звіт ----------------------------------------------------------
function Table($rows, [string[]]$cols) {
    if (-not $rows) { return '<p class="muted">' + (T 'Немає записів.' 'No records.') + '</p>' }
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
$htmlPath = Join-Path $OutDir "DeadPixel_$stamp.html"
$txtPath  = Join-Path $OutDir "DeadPixel_$stamp.txt"

$findingsHtml = ($findings | ForEach-Object { "<div class='f $($_.Level)'><b>$(Enc $_.Title)</b><p>$(Enc $_.Text)</p></div>" }) -join "`n"
$tdrRows = $tdr | Select-Object -First 40 | ForEach-Object {
    $msg = if ($_.Message) { Short $_.Message 200 } else { Short (($_.Properties | ForEach-Object { $_.Value } | Where-Object { $_ -is [string] }) -join ' | ') 200 }
    [pscustomobject]@{ Time = $_.TimeCreated; Source = "$($_.ProviderName) $($_.Id)"; Message = $msg }
}
$wheaRows = $whea | Select-Object -First 40 | ForEach-Object { [pscustomobject]@{ Time = $_.TimeCreated; Id = $_.Id; Message = Short $_.Message 250 } }
$lkrRows = $lkrFiles | Select-Object -First 30 | ForEach-Object { [pscustomobject]@{ Time = $_.LastWriteTime; Type = $_.Directory.Name; File = $_.FullName; SizeMB = [math]::Round($_.Length / 1MB, 1) } }
$dumpRows = $minidumps | ForEach-Object { [pscustomobject]@{ Time = $_.LastWriteTime; File = $_.FullName; SizeMB = [math]::Round($_.Length / 1MB, 1) } }

$html = @"
<!doctype html><html lang="$UiLang"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>DEADPIXEL $stamp</title>
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
<h1>DEADPIXEL</h1>
<div class="muted">$(Enc $env:COMPUTERNAME) · $(T 'звіт від' 'report of') $(Get-Date -Format 'yyyy-MM-dd HH:mm') · $(T 'період' 'period'): $Days $(T 'днів' 'days') · $(T 'адмін' 'admin'): $isAdmin</div>

<h2>$(T 'Висновки' 'Findings')</h2>
$findingsHtml

<h2>$(T 'Аварійні перезавантаження' 'Crash restarts') ($(@($crashRows).Count))</h2>
$(Table ($crashRows | Sort-Object Time -Descending) @('Time','Code','Name','Driver','Hint','Params','Dump'))

<h2>$(T 'Відновлені зависання ядра / GPU (LiveKernelEvent)' 'Recovered kernel / GPU hangs (LiveKernelEvent)')</h2>
$(Table $lke @('Time','Code','Name','File'))
$(Table $lkrRows @('Time','Type','File','SizeMB'))

<h2>$(T 'Події відеодрайвера (TDR)' 'Graphics driver events (TDR)')</h2>
$(Table $tdrRows @('Time','Source','Message'))

<h2>$(T 'Апаратні помилки WHEA' 'WHEA hardware errors') ($(@($whea).Count))</h2>
$(Table $wheaRows @('Time','Id','Message'))

<h2>$(T 'Помилки дисків' 'Disk errors')</h2>
$(Table $diskSummary @('Source','Count','Disk','Last','Example'))

<h2>$(T 'Збої та зависання програм (топ-20)' 'Application crashes and hangs (top 20)')</h2>
$(Table $appSummary @('App','Module','Count','Last'))

<h2>$(T 'Штатні перезавантаження / вимкнення' 'Planned restarts / shutdowns')</h2>
$(Table ($planned | Select-Object -First 20) @('Time','Proc','Reason','Type'))

<h2>$(T 'Система' 'System')</h2>
<div class="card">
<b>$(T 'ОС' 'OS'):</b> $(Enc $os.Caption) $(Enc $os.Version) (build $(Enc $os.BuildNumber)) · $(T 'аптайм' 'uptime') $([int]$uptime.TotalHours) $(T 'год' 'h')<br>
<b>CPU:</b> $(Enc $cpu) · <b>RAM:</b> $ram GB<br>
<b>$(T 'Плата' 'Board'):</b> $(Enc $mb.Manufacturer) $(Enc $mb.Product) · <b>BIOS:</b> $(Enc $bios.SMBIOSBIOSVersion) ($(if($bios.ReleaseDate){$bios.ReleaseDate.ToString('yyyy-MM-dd')}))
</div>
$(Table $gpus @('Name','Driver','Date','AgeDays'))
$(Table $disks @('DeviceId','FriendlyName','MediaType','BusType','HealthStatus'))

<h2>$(T 'Файли дампів' 'Dump files')</h2>
$(Table $dumpRows @('Time','File','SizeMB'))
<p class="muted">$(T 'Детальний аналіз дампу: встановіть WinDbg (<code>winget install Microsoft.WinDbg</code>), відкрийте .dmp і виконайте <code>!analyze -v</code>. Або BlueScreenView від NirSoft.' 'Detailed dump analysis: install WinDbg (<code>winget install Microsoft.WinDbg</code>), open the .dmp and run <code>!analyze -v</code>. Or BlueScreenView by NirSoft.')</p>
</main></body></html>
"@
$html | Out-File -Encoding utf8 $htmlPath

# Текстова версія — зручно скопіювати в чат
$txt = @()
$txt += "DEADPIXEL $stamp | $env:COMPUTERNAME | $Days " + (T 'днів' 'days')
$txt += "`n== " + (T 'ВИСНОВКИ' 'FINDINGS') + " =="
$txt += $findings | ForEach-Object { "[$($_.Level.ToUpper())] $($_.Title)`n    $($_.Text)" }
$txt += "`n== " + (T 'АВАРІЙНІ ПЕРЕЗАВАНТАЖЕННЯ' 'CRASH RESTARTS') + " =="
$txt += $crashRows | Sort-Object Time -Descending | ForEach-Object { "{0:yyyy-MM-dd HH:mm}  {1,-10} {2,-32} {3}" -f $_.Time, $_.Code, $_.Name, $_.Driver }
$txt += "`n== LiveKernelEvent =="
$txt += $lke | ForEach-Object { "{0:yyyy-MM-dd HH:mm}  {1,-6} {2,-32} {3}" -f $_.Time, $_.Code, $_.Name, $_.File }
$txt += "`n== GPU =="
$txt += $gpus | ForEach-Object { "{0}  driver {1}  ({2} {3})" -f $_.Name, $_.Driver, $_.AgeDays, (T 'днів' 'days') }
$txt += "`n== " + (T 'ДИСКИ (помилки)' 'DISKS (errors)') + " =="
$txt += $diskSummary | ForEach-Object { "{0,-14} x{1,-6} disk {2}  last {3:yyyy-MM-dd HH:mm}" -f $_.Source, $_.Count, $_.Disk, $_.Last }
$txt += "`n== WHEA: $(@($whea).Count) " + (T 'подій' 'events')
$txt -join "`n" | Out-File -Encoding utf8 $txtPath

Write-Host ''
$findings | ForEach-Object {
    $c = @{ crit = 'Red'; warn = 'Yellow'; ok = 'Green' }[$_.Level]
    Write-Host "[$($_.Level.ToUpper())] $($_.Title)" -ForegroundColor $c
    Write-Host "    $($_.Text)"
}
Write-Host ((T "`nЗвіт: " "`nReport: ") + $htmlPath + (T "`nТекст: " "`nText: ") + $txtPath) -ForegroundColor Cyan
if (-not $NoOpen) { Start-Process $htmlPath }
