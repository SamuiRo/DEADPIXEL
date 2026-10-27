# Карантин для прибирання хвостів програм (Аудит → «Прибрати…»). Підключається з Setup.ps1.
# Нічого не видаляється одразу: файли й папки переносяться в data\quarantine\<сесія>, розділи реєстру й служби
# експортуються в .reg, завдання - в XML, правила брандмауера - з усіма параметрами. Остаточно - лише через 30 днів.
# Перед кожною дією ціль перевіряється ще раз: вона досі «хвіст» і лежить у дозволеному місці.

$QuarantineDays = 30

function Get-QuarantineRoot {
    $d = Join-Path (Split-Path (Get-BackupDir)) 'quarantine'
    New-Item -ItemType Directory -Force $d | Out-Null
    $d
}

# Дозволені розділи реєстру: записи «Програм» і обробники контекстного меню. Решту реєстру карантин не чіпає
$RegAllowed = @(
    '^HK(LM|CU):\\SOFTWARE\\(WOW6432Node\\)?Microsoft\\Windows\\CurrentVersion\\Uninstall\\[^\\]+$'
    '^HK(LM|CU):\\SOFTWARE\\Classes\\(\*|Directory|Directory\\Background|Folder|Drive|AllFilesystemObjects)\\shellex\\ContextMenuHandlers\\[^\\]+$'
)
$RunKeys = '^HK(LM|CU):\\Software\\(WOW6432Node\\)?Microsoft\\Windows\\CurrentVersion\\Run(Once)?$'

# Шлях файлу служби / драйвера з ImagePath
function Resolve-ImagePath([string]$p) {
    if (-not $p) { return $null }
    $p = [Environment]::ExpandEnvironmentVariables($p.Trim())
    if ($p.StartsWith('"')) { $e = $p.IndexOf('"', 1); if ($e -gt 1) { $p = $p.Substring(1, $e - 1) } }
    else { $m = [regex]::Match($p, '(?i)^.+?\.(exe|sys|dll)(?=\s|$)'); if ($m.Success) { $p = $m.Value } }
    if ($p.StartsWith('\??\')) { $p = $p.Substring(4) }
    if ($p -match '^\\SystemRoot\\(.*)$') { $p = Join-Path $env:windir $Matches[1] }
    elseif ($p -match '^(system32|syswow64)\\') { $p = Join-Path $env:windir $p }
    $p
}

function Test-InWindows([string]$p) { $p -and $p.ToLowerInvariant().StartsWith($env:windir.ToLowerInvariant() + '\') }

function Get-AllowedParents {
    @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData, $env:LOCALAPPDATA, (Join-Path $env:LOCALAPPDATA 'Programs'), $env:APPDATA,
      [Environment]::GetFolderPath('Startup'), [Environment]::GetFolderPath('CommonStartup')) |
        Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\').ToLowerInvariant() }
}

# Кидає виняток з поясненням, якщо ціль не можна прибирати
function Assert-CleanupTarget($it) {
    switch ($it.Kind) {
        'Path' {
            $p = [IO.Path]::GetFullPath($it.Target).TrimEnd('\'); $l = $p.ToLowerInvariant()
            if (-not (Test-Path -LiteralPath $p)) { throw 'вже немає' }
            if (Test-InWindows $p) { throw 'це папка Windows' }
            if ((Get-AllowedParents) -notcontains (Split-Path $p).ToLowerInvariant()) { throw 'дозволено лише папки верхнього рівня в Program Files, ProgramData, AppData і ярлики автозавантаження' }
            if ((Split-Path $p -Leaf) -match '^(microsoft|windows|packages|programs|temp)') { throw 'службова папка' }
            $self = (Split-Path (Split-Path $PSScriptRoot)).ToLowerInvariant()
            if ($self -eq $l -or $self.StartsWith($l + '\')) { throw 'тут встановлено DEADPIXEL' }
            $run = @(Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -and $_.ExecutablePath.ToLowerInvariant().StartsWith($l + '\') })
            if ($run) { throw "з цієї папки зараз працює $($run[0].Name)" }
        }
        'RegistryKey' {
            if (-not ($RegAllowed | Where-Object { $it.Target -match $_ })) { throw 'цей розділ реєстру карантин не чіпає' }
            if (-not (Test-Path -LiteralPath $it.Target)) { throw 'вже немає' }
        }
        'RegistryValue' {
            if ($it.Key -notmatch $RunKeys) { throw 'це не запис автозапуску' }
            if ($null -eq (Get-ItemProperty -LiteralPath $it.Key -Name $it.Name -ErrorAction SilentlyContinue)) { throw 'вже немає' }
        }
        'Service' {
            $k = "HKLM:\SYSTEM\CurrentControlSet\Services\$($it.Name)"
            if ($it.Name -notmatch '^[\w.\- ]+$' -or -not (Test-Path -LiteralPath $k)) { throw 'служби вже немає' }
            $img = Resolve-ImagePath (Get-ItemProperty -LiteralPath $k).ImagePath
            if (-not $img -or (Test-InWindows $img)) { throw 'служба Windows' }
            if (Test-Path -LiteralPath $img) { throw 'файл служби існує - це не хвіст' }
        }
        'Task' {
            if ($it.Key -like '\Microsoft\*') { throw 'завдання Windows' }
            $t = Get-ScheduledTask -TaskPath $it.Key -TaskName $it.Name -ErrorAction Stop
            foreach ($a in @($t.Actions | Where-Object { $_.Execute })) {
                if (Test-Path -LiteralPath (Resolve-ImagePath $a.Execute)) { throw 'файл завдання існує - це не хвіст' }
            }
        }
        'PathEntry' {
            if ($it.Scope -notin 'Machine', 'User') { throw 'невідомий PATH' }
            if (Test-Path -LiteralPath ([Environment]::ExpandEnvironmentVariables($it.Target))) { throw 'папка існує' }
        }
        'FirewallRule' {
            $p = [Environment]::ExpandEnvironmentVariables($it.Target)
            if (Test-InWindows $p) { throw 'правило компонента Windows' }
            if (Test-Path -LiteralPath $p) { throw 'програма існує - це не хвіст' }
        }
        default { throw "невідомий тип: $($it.Kind)" }
    }
}

# Нативні утиліти (reg, sc, robocopy) пишуть навіть «успішно» у stderr, а PowerShell 5.1 з ErrorActionPreference=Stop
# вважає це помилкою. Успіх визначаємо лише за кодом виходу
function Invoke-Native([string]$exe, [string[]]$arguments) {
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $null = & $exe @arguments 2>&1 } finally { $ErrorActionPreference = $old }
    $LASTEXITCODE
}

function Export-RegKey([string]$psPath, [string]$file) {
    $regPath = $psPath -replace '^HKLM:\\', 'HKLM\' -replace '^HKCU:\\', 'HKCU\'
    $code = Invoke-Native reg.exe @('export', $regPath, $file, '/y')
    if ($code -ne 0) { throw "не вдалося зберегти розділ реєстру (reg export: $code)" }
}

function Send-EnvironmentChange {
    if (-not ('DeadPixelEnv.Native' -as [type])) {
        Add-Type -Namespace DeadPixelEnv -Name Native -MemberDefinition '[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr SendMessageTimeout(IntPtr h, uint msg, UIntPtr w, string l, uint flags, uint timeout, out UIntPtr result);'
    }
    $r = [UIntPtr]::Zero
    $null = [DeadPixelEnv.Native]::SendMessageTimeout([IntPtr]0xffff, 0x1A, [UIntPtr]::Zero, 'Environment', 2, 3000, [ref]$r)
}

# PATH змінюємо як рядок реєстру (без розгортання %змінних% і зі збереженням типу значення)
function Update-PathValue([string]$scope, [scriptblock]$change) {
    $root = if ($scope -eq 'Machine') { [Microsoft.Win32.Registry]::LocalMachine } else { [Microsoft.Win32.Registry]::CurrentUser }
    $sub = if ($scope -eq 'Machine') { 'SYSTEM\CurrentControlSet\Control\Session Manager\Environment' } else { 'Environment' }
    $k = $root.OpenSubKey($sub, $true)
    try {
        $kind = $k.GetValueKind('Path')
        $parts = @(([string]$k.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)) -split ';' | Where-Object { $_ -ne '' })
        $k.SetValue('Path', ((& $change $parts) -join ';'), $kind)
    } finally { $k.Close() }
    Send-EnvironmentChange
}

# Правила брандмауера: індекс за унікальним ID (імена правил повторюються - напр. у кожної версії Postman правило «Postman»)
$script:FwIndex = $null
function Get-FirewallIndex {
    if (-not $script:FwIndex) {
        $apps = @{}; foreach ($f in Get-NetFirewallApplicationFilter -All) { $apps[$f.InstanceID] = $f.Program }
        $ports = @{}; foreach ($f in Get-NetFirewallPortFilter -All) { $ports[$f.InstanceID] = $f }
        $addrs = @{}; foreach ($f in Get-NetFirewallAddressFilter -All) { $addrs[$f.InstanceID] = $f }
        $script:FwIndex = @{ Rules = @(Get-NetFirewallRule -All); Apps = $apps; Ports = $ports; Addrs = $addrs }
    }
    $script:FwIndex
}

# Переносить одну ціль у карантин; повертає, що збережено для відновлення
function Move-ToQuarantine($it, [string]$dir, [int]$n) {
    switch ($it.Kind) {
        'Path' {
            $src = [IO.Path]::GetFullPath($it.Target).TrimEnd('\')
            $dst = Join-Path $dir "files\$n"
            New-Item -ItemType Directory -Force (Split-Path $dst) | Out-Null
            if (Test-Path -LiteralPath $src -PathType Leaf) { Move-Item -LiteralPath $src -Destination $dst }
            else {
                # robocopy переносить і між дисками (Move-Item для папок - ні); /XJ - не йти за посиланнями-переходами
                $code = Invoke-Native robocopy.exe @($src, $dst, '/E', '/MOVE', '/COPY:DAT', '/DCOPY:T', '/R:1', '/W:1', '/XJ', '/NFL', '/NDL', '/NJH', '/NJS', '/NP')
                if ($code -ge 8) { throw "не вдалося перенести (robocopy: $code)" }
                # Частину файлів (зайнятих) не перенесено: запис лишається відновлюваним, відновлення злиє файли назад
                if (Test-Path -LiteralPath $src) { return @{ Stored = "files\$n"; Original = $src; Partial = $true } }
            }
            return @{ Stored = "files\$n"; Original = $src }
        }
        'RegistryKey' {
            $f = "reg-$n.reg"
            Export-RegKey $it.Target (Join-Path $dir $f)
            Remove-Item -LiteralPath $it.Target -Recurse -Force
            return @{ RegFile = $f }
        }
        'Service' {
            $f = "reg-$n.reg"
            Export-RegKey "HKLM:\SYSTEM\CurrentControlSet\Services\$($it.Name)" (Join-Path $dir $f)
            $code = Invoke-Native sc.exe @('delete', $it.Name)
            if ($code -notin 0, 1072) { throw "sc delete: код $code" }   # 1072 - уже позначена до видалення
            return @{ RegFile = $f }
        }
        'RegistryValue' {
            $k = Get-Item -LiteralPath $it.Key
            $saved = @{ ValueKind = [string]$k.GetValueKind($it.Name); Value = [string]$k.GetValue($it.Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) }
            Remove-ItemProperty -LiteralPath $it.Key -Name $it.Name
            return $saved
        }
        'Task' {
            $f = "task-$n.xml"
            Export-ScheduledTask -TaskPath $it.Key -TaskName $it.Name | Set-Content -Encoding Unicode (Join-Path $dir $f)
            Unregister-ScheduledTask -TaskPath $it.Key -TaskName $it.Name -Confirm:$false
            return @{ XmlFile = $f }
        }
        'PathEntry' {
            # Запам'ятовуємо позицію: порядок у PATH визначає, яка з однойменних програм запуститься
            $entry = $it.Target
            $script:PathIndex = -1
            Update-PathValue $it.Scope {
                param($parts)
                for ($i = 0; $i -lt $parts.Count; $i++) { if ($parts[$i].TrimEnd('\') -eq $entry.TrimEnd('\')) { $script:PathIndex = $i; break } }
                @($parts | Where-Object { $_.TrimEnd('\') -ne $entry.TrimEnd('\') })
            }
            return @{ Index = $script:PathIndex }
        }
        'FirewallRule' {
            $idx = Get-FirewallIndex
            $mine = @($idx.Rules | Where-Object { $idx.Apps[$_.Name] -and $idx.Apps[$_.Name] -eq $it.Target })
            if (-not $mine) { throw 'правил для цієї програми не знайдено' }
            $saved = @(foreach ($r in $mine) {
                $pf = $idx.Ports[$r.Name]; $af = $idx.Addrs[$r.Name]
                [ordered]@{
                    DisplayName = $r.DisplayName; Description = $r.Description; Direction = [string]$r.Direction; Action = [string]$r.Action
                    Enabled = [string]$r.Enabled; Profile = [string]$r.Profile; Protocol = [string]$pf.Protocol
                    LocalPort = @($pf.LocalPort); RemotePort = @($pf.RemotePort); RemoteAddress = @($af.RemoteAddress)
                }
            })
            Remove-NetFirewallRule -Name @($mine | ForEach-Object { $_.Name })
            return @{ Rules = $saved }
        }
    }
}

function Invoke-Cleanup([string]$file) {
    if (-not (Test-Admin)) { throw 'Для прибирання потрібні права адміністратора.' }
    # ConvertFrom-Json у PowerShell 5.1 віддає JSON-масив одним об'єктом - розгортаємо його в окремі пункти
    $items = @((Get-Content $file -Raw -Encoding UTF8 | ConvertFrom-Json) | ForEach-Object { $_ })
    $id = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $dir = Join-Path (Get-QuarantineRoot) $id
    New-Item -ItemType Directory -Force $dir | Out-Null
    $n = 0
    $done = foreach ($it in $items) {
        $n++
        $rec = [ordered]@{ Kind = $it.Kind; Label = $it.Label; Item = $it; Saved = $null; Status = 'MOVED'; Message = ''; Size = [long]$it.Size }
        try {
            Assert-CleanupTarget $it
            $rec.Saved = Move-ToQuarantine $it $dir $n
            if ($rec.Saved.Partial) { $rec.Message = 'частину файлів не перенесено (зайняті іншою програмою)' }
        } catch { $rec.Status = 'SKIP'; $rec.Message = $_.Exception.Message }
        [pscustomobject]$rec
    }
    $session = [pscustomobject]@{ Id = $id; Time = (Get-Date).ToString('s'); Restored = $false; Items = @($done) }
    ConvertTo-Json -InputObject $session -Depth 8 | Set-Content -Encoding UTF8 (Join-Path $dir 'manifest.json')
    if (-not ($done | Where-Object Status -eq 'MOVED')) { Remove-Item -LiteralPath $dir -Recurse -Force }
    [pscustomobject]@{ Error = $null; Session = $id; Items = @($done | ForEach-Object { [pscustomobject]@{ Label = $_.Label; Status = $_.Status; Message = $_.Message } }) }
}

function Get-Session([string]$id) {
    if ($id -notmatch '^\d{8}-\d{6}$') { throw 'неправильний ідентифікатор сесії' }
    $dir = Join-Path (Get-QuarantineRoot) $id
    $m = Join-Path $dir 'manifest.json'
    if (-not (Test-Path $m)) { throw 'сесії карантину не знайдено' }
    @{ Dir = $dir; Manifest = $m; Data = (Get-Content $m -Raw -Encoding UTF8 | ConvertFrom-Json) }
}

function Restore-Quarantine([string]$id) {
    if (-not (Test-Admin)) { throw 'Для відновлення потрібні права адміністратора.' }
    $s = Get-Session $id
    $res = @()
    $todo = @($s.Data.Items | Where-Object Status -eq 'MOVED')
    [array]::Reverse($todo)   # у зворотному порядку - як відкат транзакції
    foreach ($rec in $todo) {
        $it = $rec.Item; $sv = $rec.Saved
        try {
            switch ($rec.Kind) {
                'Path' {
                    if ((Test-Path -LiteralPath $sv.Original) -and -not $sv.Partial) { throw "на місці вже є $($sv.Original)" }
                    $from = Join-Path $s.Dir $sv.Stored
                    if (Test-Path -LiteralPath $from -PathType Leaf) { Move-Item -LiteralPath $from -Destination $sv.Original }
                    else {
                        $code = Invoke-Native robocopy.exe @($from, $sv.Original, '/E', '/MOVE', '/COPY:DAT', '/DCOPY:T', '/R:1', '/W:1', '/XJ', '/NFL', '/NDL', '/NJH', '/NJS', '/NP')
                        if ($code -ge 8) { throw "robocopy: $code" }
                    }
                }
                { $_ -in 'RegistryKey', 'Service' } {
                    $code = Invoke-Native reg.exe @('import', (Join-Path $s.Dir $sv.RegFile))
                    if ($code -ne 0) { throw "reg import: $code" }
                }
                'RegistryValue' { New-ItemProperty -LiteralPath $it.Key -Name $it.Name -Value $sv.Value -PropertyType $sv.ValueKind -Force | Out-Null }
                'Task' { Register-ScheduledTask -Xml (Get-Content (Join-Path $s.Dir $sv.XmlFile) -Raw -Encoding Unicode) -TaskPath $it.Key -TaskName $it.Name | Out-Null }
                'PathEntry' {
                    $entry = $it.Target; $at = if ($null -ne $sv.Index) { [int]$sv.Index } else { -1 }
                    Update-PathValue $it.Scope {
                        param($parts)
                        if ($parts | Where-Object { $_.TrimEnd('\') -eq $entry.TrimEnd('\') }) { return $parts }
                        $list = New-Object Collections.Generic.List[string]
                        foreach ($p in $parts) { $list.Add($p) }
                        if ($at -ge 0 -and $at -le $list.Count) { $list.Insert($at, $entry) } else { $list.Add($entry) }
                        $list.ToArray()
                    }
                }
                'FirewallRule' {
                    foreach ($r in @($sv.Rules)) {
                        $p = @{ DisplayName = $r.DisplayName; Direction = $r.Direction; Action = $r.Action; Enabled = $r.Enabled; Profile = $r.Profile; Program = $it.Target }
                        if ($r.Description) { $p.Description = $r.Description }
                        if ($r.Protocol -and $r.Protocol -ne 'Any') { $p.Protocol = $r.Protocol }
                        if ($r.Protocol -in 'TCP', 'UDP') {
                            if (@($r.LocalPort) -notcontains 'Any') { $p.LocalPort = @($r.LocalPort) }
                            if (@($r.RemotePort) -notcontains 'Any') { $p.RemotePort = @($r.RemotePort) }
                        }
                        if (@($r.RemoteAddress) -notcontains 'Any') { $p.RemoteAddress = @($r.RemoteAddress) }
                        New-NetFirewallRule @p | Out-Null
                    }
                }
            }
            $rec.Status = 'RESTORED'; $msg = if ($rec.Kind -eq 'Service') { 'діє після перезавантаження' } else { '' }
            $res += [pscustomobject]@{ Label = $rec.Label; Status = 'RESTORED'; Message = $msg }
        } catch {
            $res += [pscustomobject]@{ Label = $rec.Label; Status = 'FAIL'; Message = $_.Exception.Message }
        }
    }
    $s.Data.Restored = -not ($s.Data.Items | Where-Object Status -eq 'MOVED')
    ConvertTo-Json -InputObject $s.Data -Depth 8 | Set-Content -Encoding UTF8 $s.Manifest
    [pscustomobject]@{ Error = $null; Session = $id; Items = $res }
}

function Get-QuarantineList {
    $root = Get-QuarantineRoot
    $sessions = foreach ($d in Get-ChildItem $root -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending) {
        $m = Join-Path $d.FullName 'manifest.json'
        if (-not (Test-Path $m)) { continue }
        $data = Get-Content $m -Raw -Encoding UTF8 | ConvertFrom-Json
        $moved = @($data.Items | Where-Object Status -eq 'MOVED')
        $files = Join-Path $d.FullName 'files'
        $size = if (Test-Path $files) { [long](Get-ChildItem $files -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum } else { 0L }
        $age = [int]((Get-Date) - [datetime]$data.Time).TotalDays
        [pscustomobject]@{
            Id = $data.Id; Time = $data.Time; AgeDays = $age; Count = $moved.Count; Size = $size; Restored = [bool]$data.Restored
            CanPurge = [bool]$data.Restored -or $age -ge $QuarantineDays; Labels = @($moved | ForEach-Object Label)
        }
    }
    [pscustomobject]@{ Error = $null; Root = $root; Days = $QuarantineDays; Sessions = @($sessions) }
}

# Остаточне видалення: лише через 30 днів (або якщо все вже відновлено) - час помітити, що щось зламалося
function Remove-QuarantineSession([string]$id) {
    if (-not (Test-Admin)) { throw 'Для остаточного видалення потрібні права адміністратора.' }
    $s = Get-Session $id
    $age = ((Get-Date) - [datetime]$s.Data.Time).TotalDays
    if (-not $s.Data.Restored -and $age -lt $QuarantineDays) { throw "Остаточно видалити можна через $QuarantineDays днів після перенесення (лишилось $([int][Math]::Ceiling($QuarantineDays - $age)) дн.)." }
    Remove-Item -LiteralPath $s.Dir -Recurse -Force
    [pscustomobject]@{ Error = $null; Session = $id; Items = @() }
}
