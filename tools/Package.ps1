<#
.SYNOPSIS
  Збирає реліз DEADPIXEL у dist\: portable .zip, інсталятор (якщо є Inno Setup), SHA256SUMS.txt, release-notes.md.
.DESCRIPTION
  Те саме локально і на GitHub Actions. Версія — з файлу VERSION. Інсталятор збирається, лише якщо знайдено
  ISCC.exe (Inno Setup 6); без нього — лише zip (параметр -RequireInstaller робить це помилкою, для CI).
.EXAMPLE
  powershell -NoProfile -File tools\Package.ps1
#>
param(
    [switch]$SkipBuild,
    [switch]$RequireInstaller
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$version = (Get-Content (Join-Path $root 'VERSION') -TotalCount 1).Trim()
if ($version -notmatch '^\d+\.\d+\.\d+$') { throw "VERSION має бути у форматі X.Y.Z, а не '$version'" }
$dist = Join-Path $root 'dist'
$stage = Join-Path $dist 'DEADPIXEL'

if (-not $SkipBuild) {
    & cmd.exe /c "`"$root\build.cmd`""
    if ($LASTEXITCODE -ne 0) { throw "build.cmd завершився з кодом $LASTEXITCODE" }
}

# ---------------------------------------------------------------- що потрапляє в реліз
# Лише те, що потрібно для роботи: без вихідного коду, assets і, головне, без data\ і reports\ (особисті дані)
if (Test-Path $dist) { Remove-Item $dist -Recurse -Force }
New-Item -ItemType Directory $stage | Out-Null
foreach ($f in 'DeadPixel.exe', 'DeadPixel.ps1', 'DeadPixel.cmd', 'README.md', 'CHANGELOG.md', 'LICENSE', 'VERSION') {
    Copy-Item (Join-Path $root $f) $stage
}
Get-ChildItem (Join-Path $root 'modules') -Recurse -File | Where-Object {
    $rel = $_.FullName.Substring($root.Length + 1)
    # вихідний код GUI вже в exe; із common потрібен лише Lang.ps1 (його підключають скрипти)
    $rel -notmatch '\\gui\\' -and $rel -notmatch '\.cs$' -and $rel -notmatch '\\data\\'
} | ForEach-Object {
    $dest = Join-Path $stage $_.FullName.Substring($root.Length + 1)
    New-Item -ItemType Directory -Force (Split-Path $dest) | Out-Null
    Copy-Item $_.FullName $dest
}
foreach ($exe in 'DeadPixel.exe', 'modules\setup\SetupGui.exe', 'modules\audit\AuditGui.exe') {
    if (-not (Test-Path (Join-Path $stage $exe))) { throw "Немає $exe — збірка не вдалася?" }
}

# ---------------------------------------------------------------- portable zip
$zip = Join-Path $dist "DEADPIXEL-$version-portable.zip"
Compress-Archive -Path $stage -DestinationPath $zip
Write-Host "portable:  $zip"

# ---------------------------------------------------------------- інсталятор
$iscc = @(
    (Get-Command ISCC.exe -ErrorAction SilentlyContinue | ForEach-Object Source),
    "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
    "$env:ProgramFiles\Inno Setup 6\ISCC.exe",
    "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe"
) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
if ($iscc) {
    & $iscc /Q "/DAppVersion=$version" "/DStageDir=$stage" "/O$dist" (Join-Path $root 'installer\DeadPixel.iss')
    if ($LASTEXITCODE -ne 0) { throw "Inno Setup завершився з кодом $LASTEXITCODE" }
    Write-Host "installer: $(Join-Path $dist "DEADPIXEL-$version-setup.exe")"
} elseif ($RequireInstaller) {
    throw 'Не знайдено Inno Setup 6 (ISCC.exe)'
} else {
    Write-Warning 'Inno Setup 6 не знайдено — інсталятор пропущено (zip зібрано).'
}

# ---------------------------------------------------------------- контрольні суми та нотатки релізу
$sums = Get-ChildItem $dist -File -Include '*.zip', '*.exe' -Recurse | Where-Object { $_.DirectoryName -eq $dist } | ForEach-Object {
    '{0}  {1}' -f (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant(), $_.Name
}
# LF, а не CRLF: інакше стандартний `sha256sum -c` (Linux, Git Bash) не знаходить файли
[IO.File]::WriteAllText((Join-Path $dist 'SHA256SUMS.txt'), (($sums -join "`n") + "`n"))

# Розділ "## [X.Y.Z]" з CHANGELOG.md — текст сторінки релізу на GitHub
$changelog = Get-Content (Join-Path $root 'CHANGELOG.md') -Encoding UTF8
$start = ($changelog | Select-String -Pattern "^## \[$([regex]::Escape($version))\]" | Select-Object -First 1).LineNumber
if (-not $start) { throw "У CHANGELOG.md немає розділу ## [$version]" }
$notes = $changelog[$start..($changelog.Count - 1)] | ForEach-Object -Begin { $stop = $false } -Process {
    if ($_ -match '^## ' -or $_ -match '^\[.+\]: ') { $stop = $true }
    if (-not $stop) { $_ }
}
$notes += '', '---', 'Перевірка файлів: `SHA256SUMS.txt`. Програма поки без цифрового підпису — Windows SmartScreen при першому запуску покаже попередження («Докладніше» → «Усе одно запустити»).'
[IO.File]::WriteAllLines((Join-Path $dist 'release-notes.md'), [string[]]$notes, (New-Object Text.UTF8Encoding $false))
Write-Host "Готово: DEADPIXEL $version → $dist"
