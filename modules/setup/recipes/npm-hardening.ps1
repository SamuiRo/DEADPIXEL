# npm: не виконувати скрипти встановлення пакетів і не брати щойно опубліковані версії.
# Обидва налаштування - рядки в ~/.npmrc користувача; інші рядки файлу (токени, реєстри) не чіпаються.

# Пункт рецепта для одного ключа ~/.npmrc. Значення '<absent>' - ключа немає (так його і повертає відкат)
function New-NpmrcItem([string]$Key, [string]$Desired, [string]$Title, [string]$Hint, [int]$MinNpmMajor = 0) {
    @{ Kind = 'Custom'; Id = $Key; Title = $Title; Desired = $Desired; Hint = $Hint
       Get = {
           if ($MinNpmMajor) {
               $cmd = Get-Command npm -ErrorAction SilentlyContinue | Select-Object -First 1
               $pkg = if ($cmd) { Join-Path (Split-Path $cmd.Source) 'node_modules\npm\package.json' }
               $major = if ($pkg -and (Test-Path -LiteralPath $pkg) -and ((Get-Content -LiteralPath $pkg -Raw) -match '"version"\s*:\s*"(\d+)\.')) { [int]$Matches[1] } else { 0 }
               if ($major -lt $MinNpmMajor) { throw "npm $MinNpmMajor+" }
           }
           $f = Join-Path $env:USERPROFILE '.npmrc'; $v = '<absent>'
           if (Test-Path -LiteralPath $f) { foreach ($l in Get-Content -LiteralPath $f) { if ($l -match "^\s*$([regex]::Escape($Key))\s*=\s*(.*?)\s*$") { $v = $Matches[1].Trim('"') } } }
           $v
       }.GetNewClosure()
       Set = {
           param($value)
           $f = Join-Path $env:USERPROFILE '.npmrc'
           $lines = @(if (Test-Path -LiteralPath $f) { Get-Content -LiteralPath $f | Where-Object { $_ -notmatch "^\s*$([regex]::Escape($Key))\s*=" } })
           if ("$value" -ne '<absent>') { $lines += "$Key=$value" }
           # Без BOM: npm читає .npmrc як ini і спіткнувся б об перший рядок
           [IO.File]::WriteAllLines($f, [string[]]$lines, (New-Object Text.UTF8Encoding $false))
       }.GetNewClosure() }
}

@{
    Title       = (T 'Захист npm від заражених пакетів' 'npm hardening against infected packages')
    Description = (T 'Пакети більше не виконують власні скрипти під час встановлення, а версії, молодші за тиждень, не встановлюються. Діє для всіх проєктів і для команд, які запускає ШІ-агент. Прав адміністратора не потребує.' 'Packages no longer run their own scripts during installation, and versions younger than a week are not installed. Applies to all projects and to commands run by an AI agent. Needs no administrator rights.')
    Items       = @(
        (New-NpmrcItem 'ignore-scripts' 'true' (T 'Не виконувати скрипти встановлення' 'Do not run install scripts') (T 'Пакети з нативними модулями (sharp, electron, puppeteer, sqlite3) після встановлення потребують npm rebuild <пакет>. Скрипти вашого власного package.json (npm run build) працюють як і раніше.' 'Packages with native modules (sharp, electron, puppeteer, sqlite3) need npm rebuild <package> after install. Scripts of your own package.json (npm run build) work as before.'))
        (New-NpmrcItem 'min-release-age' '7' (T 'Не встановлювати версії, молодші за 7 днів' 'Do not install versions younger than 7 days') (T 'Потрібен npm 11 або новіший. Термінове оновлення залежності встановлюйте, вказавши версію явно.' 'Needs npm 11 or newer. Install an urgent dependency update by naming the version explicitly.') 11)
    )
}
