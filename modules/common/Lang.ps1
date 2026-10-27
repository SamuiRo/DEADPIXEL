# Мова інтерфейсу для PowerShell-частини DEADPIXEL: T 'українською' 'English'.
# Підключається через "." з Setup.ps1, Audit.ps1 і DeadPixel.ps1; правило вибору - як у src\L.cs.

# -Lang uk|en має перевагу; інакше Language= з data\settings.ini (system | uk | en). Файл налаштувань є, а рядка
# Language немає - це оновлення з версії, яка була лише українською: лишаємо українську
function Resolve-UiLang([string]$Requested, [string]$Root) {
    if ($Requested -in 'uk', 'en') { return $Requested }
    $mode = 'system'
    foreach ($ini in (Join-Path $Root 'data\settings.ini'), (Join-Path $env:LOCALAPPDATA 'DeadPixel\settings.ini')) {
        if (-not (Test-Path $ini)) { continue }
        $line = Get-Content $ini -ErrorAction SilentlyContinue | Where-Object { $_ -like 'Language=*' } | Select-Object -First 1
        $mode = if ($line) { $line.Substring(9).Trim() } else { 'uk' }
        break
    }
    if ($mode -in 'uk', 'en') { return $mode }
    if ((Get-UICulture).TwoLetterISOLanguageName -eq 'uk') { 'uk' } else { 'en' }
}

$script:UiLang = 'uk'
function T([string]$uk, [string]$en) { if ($script:UiLang -eq 'en') { $en } else { $uk } }
