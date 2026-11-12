# Розробка й ШІ-агенти: ланцюг постачання пакетів і налаштування агентів, які самі запускають команди.
# Заражений пакет приходить через легітимний менеджер пакетів, а встановлює його часто ШІ-агент без участі людини -
# антивірус тут нічого не бачить. Перевірки читають лише файли налаштувань; жодна програма не запускається.

# Версія менеджера пакетів без його запуску: package.json поруч із виконуваним файлом (npm, pnpm, yarn ставляться як пакети)
function Get-NodeToolVersion([string]$Name) {
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $cmd) { return $null }
    foreach ($p in (Join-Path (Split-Path $cmd.Source) "node_modules\$Name\package.json"), (Join-Path (Split-Path (Split-Path $cmd.Source)) "$Name\package.json")) {
        if (-not (Test-Path -LiteralPath $p)) { continue }
        $m = [regex]::Match((Read-SharedText $p 2MB), '"version"\s*:\s*"(\d+)\.(\d+)\.(\d+)')
        if ($m.Success) { return [version]"$($m.Groups[1].Value).$($m.Groups[2].Value).$($m.Groups[3].Value)" }
    }
    [version]'0.0.0'   # є, але версію не визначити
}

# Значення ключа з ~/.npmrc (останнє входження); $null - не задано
function Get-NpmrcValue([string]$Key) {
    $f = Join-Path $env:USERPROFILE '.npmrc'
    if (-not (Test-Path -LiteralPath $f)) { return $null }
    $v = $null
    foreach ($l in Get-Content -LiteralPath $f -ErrorAction SilentlyContinue) { if ($l -match "^\s*$([regex]::Escape($Key))\s*=\s*(.*?)\s*$") { $v = $Matches[1].Trim('"') } }
    $v
}

# Файли налаштувань редакторів родини VS Code (JSON з коментарями - читаємо регулярними виразами)
function Get-EditorSettings {
    foreach ($e in @{ Name = 'VS Code'; Dir = 'Code' }, @{ Name = 'VS Code Insiders'; Dir = 'Code - Insiders' }, @{ Name = 'Cursor'; Dir = 'Cursor' },
                   @{ Name = 'Windsurf'; Dir = 'Windsurf' }, @{ Name = 'Antigravity'; Dir = 'Antigravity' }, @{ Name = 'VSCodium'; Dir = 'VSCodium' }) {
        $f = Join-Path $env:APPDATA "$($e.Dir)\User\settings.json"
        if (Test-Path -LiteralPath $f) { [pscustomobject]@{ Name = $e.Name; Path = $f; Text = [string](Read-SharedText $f 5MB) } }
    }
}

# Сервери MCP з усіх відомих місць: @{ Source; Name; Command; Args; Url }
function Get-McpServers {
    $u = $env:USERPROFILE; $a = $env:APPDATA
    $json = @(
        @{ Source = 'Claude Code'; Path = "$u\.claude.json" }, @{ Source = 'Claude Desktop'; Path = "$a\Claude\claude_desktop_config.json" }
        @{ Source = 'Cursor'; Path = "$u\.cursor\mcp.json" }, @{ Source = 'LM Studio'; Path = "$u\.lmstudio\mcp.json" }
        @{ Source = 'Gemini CLI'; Path = "$u\.gemini\settings.json" }, @{ Source = 'Antigravity'; Path = "$u\.gemini\antigravity\mcp_config.json" }
        @{ Source = 'Windsurf'; Path = "$u\.codeium\windsurf\mcp_config.json" }, @{ Source = 'VS Code'; Path = "$a\Code\User\mcp.json" }
        @{ Source = 'VS Code Insiders'; Path = "$a\Code - Insiders\User\mcp.json" }
    )
    foreach ($j in $json) {
        if (-not (Test-Path -LiteralPath $j.Path) -or (Get-Item -LiteralPath $j.Path).Length -gt 1.9MB) { continue }
        try { $d = Get-Content -LiteralPath $j.Path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
        $sets = @($d.mcpServers, $d.servers)
        # Claude Code зберігає сервери ще й окремо для кожного проєкту
        if ($d.projects) { foreach ($p in $d.projects.PSObject.Properties) { $sets += $p.Value.mcpServers } }
        foreach ($set in $sets | Where-Object { $_ }) {
            foreach ($s in $set.PSObject.Properties) {
                [pscustomobject]@{ Source = $j.Source; Name = $s.Name; Command = [string]$s.Value.command; Args = @($s.Value.args | ForEach-Object { [string]$_ }); Url = [string]$s.Value.url }
            }
        }
    }
    # Codex: TOML, секції [mcp_servers.<назва>]
    $codex = Read-SharedText "$u\.codex\config.toml" 2MB
    if ($codex) {
        # Назва без крапок: [mcp_servers.x.env] - це підтаблиця сервера x, а не окремий сервер. Рядки TOML - у "..." або '...'
        foreach ($m in [regex]::Matches($codex, '(?ms)^\[mcp_servers\.("[^"\r\n]+"|[^\].\r\n]+)\]\s*(.*?)(?=^\[|\z)')) {
            $body = $m.Groups[2].Value
            $q = '(?:"([^"]*)"|''([^'']*)'')'
            $c = [regex]::Match($body, "(?m)^\s*command\s*=\s*$q")
            $argv = @([regex]::Matches([regex]::Match($body, '(?ms)^\s*args\s*=\s*\[(.*?)\]').Groups[1].Value, $q) | ForEach-Object { $_.Groups[1].Value + $_.Groups[2].Value })
            $url = [regex]::Match($body, "(?m)^\s*url\s*=\s*$q")
            [pscustomobject]@{ Source = 'Codex'; Name = $m.Groups[1].Value.Trim('"'); Command = $c.Groups[1].Value + $c.Groups[2].Value; Args = $argv; Url = $url.Groups[1].Value + $url.Groups[2].Value }
        }
    }
}

# Файли, які агент читає як власні інструкції в кожній сесії: правила, команди, навички
function Get-AgentInstructionFiles {
    $u = $env:USERPROFILE
    $files = @("$u\.claude\CLAUDE.md", "$u\.codex\AGENTS.md", "$u\.gemini\GEMINI.md", "$u\.cursorrules", "$u\AGENTS.md", "$u\CLAUDE.md") | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }
    foreach ($d in "$u\.claude\commands", "$u\.claude\agents", "$u\.claude\skills", "$u\.claude\rules", "$u\.claude\output-styles", "$u\.codex\prompts", "$u\.cursor\rules", "$u\.gemini\commands") {
        $files += @(Get-ChildItem -LiteralPath $d -Recurse -File -Include '*.md', '*.mdc', '*.txt', '*.toml' -ErrorAction SilentlyContinue | Select-Object -First 2000 | ForEach-Object FullName)
    }
    @($files | Sort-Object -Unique)
}

@{
    Id = 'devtools'; Title = (T 'Розробка й ШІ-агенти' 'Development and AI agents'); Order = 3.7
    Checks = @(
        @{
            Id = 'install-scripts'; Title = (T 'Скрипти встановлення пакетів (npm)' 'Package install scripts (npm)')
            Test = {
                $npm = Get-NodeToolVersion 'npm'; $pnpm = Get-NodeToolVersion 'pnpm'
                if (-not $npm -and -not $pnpm) { return NotApplicable (T 'npm і pnpm не знайдено.' 'npm and pnpm not found.') }
                $ev = @(); $bad = $false
                if ($npm) {
                    if ((Get-NpmrcValue 'ignore-scripts') -eq 'true') { $ev += "✓ npm $npm - " + (T 'скрипти встановлення вимкнено (ignore-scripts=true)' 'install scripts are off (ignore-scripts=true)') }
                    else { $bad = $true; $ev += "⚠ npm $npm - " + (T 'кожен пакет і всі його залежності можуть виконати довільну програму під час npm install' 'every package and all of its dependencies may run an arbitrary program during npm install') }
                }
                if ($pnpm) {
                    if ($pnpm.Major -ge 10) { $ev += "✓ pnpm $pnpm - " + (T 'скрипти залежностей заблоковано за замовчуванням (дозволяються поіменно)' 'dependency scripts are blocked by default (allowed by name)') }
                    elseif ($pnpm.Major -gt 0) { $bad = $true; $ev += "⚠ pnpm $pnpm - " + (T 'скрипти залежностей виконуються; з версії 10 вони заблоковані за замовчуванням' 'dependency scripts run; from version 10 they are blocked by default') }
                }
                if (-not $bad) { return Ok (T 'вимкнено' 'off') '' $ev }
                Issue medium (T 'виконуються автоматично' 'run automatically') (T 'Скрипт preinstall/postinstall - головний спосіб зараження через пакети: хробак Shai-Hulud (2025) і більшість підроблених Web3-бібліотек крадуть токени, ключі SSH і гаманці саме під час встановлення, ще до того, як код пакета хтось викличе. ШІ-агент, який сам додає залежність, запускає це без вашої участі.' 'A preinstall/postinstall script is the main way packages infect machines: the Shai-Hulud worm (2025) and most fake Web3 libraries steal tokens, SSH keys and wallets during installation itself, before anyone calls the package code. An AI agent adding a dependency on its own triggers this without you.') $ev
            }
            Explain = (T 'Пакет npm може оголосити скрипт, який менеджер пакетів виконає одразу після завантаження - з вашими правами й доступом до всього профілю. Легітимним пакетам це потрібно рідко (збирання нативних модулів). З вимкненими скриптами заражений пакет лежить на диску, але не запускається, поки його код не викличуть.' 'An npm package can declare a script the package manager runs right after download - with your rights and access to your whole profile. Legitimate packages rarely need it (building native modules). With scripts off, an infected package sits on disk but does not run until its code is called.')
            Pros = @((T 'Закриває найпоширеніший шлях зараження через залежності' 'Closes the most common infection route through dependencies'), (T 'Діє і для команд, які запускає ШІ-агент' 'Applies to commands run by an AI agent too'))
            Cons = @((T 'Пакети з нативними модулями (sharp, electron, puppeteer, sqlite3, node-gyp) після встановлення потребують npm rebuild <пакет> - свідомо, для перевіреного пакета' 'Packages with native modules (sharp, electron, puppeteer, sqlite3, node-gyp) need npm rebuild <package> after install - deliberately, for a reviewed package'), (T 'Не захищає від шкідливого коду, який спрацьовує під час імпорту чи запуску пакета' 'Does not protect against malicious code that fires when the package is imported or run'))
            Fix = @{ Recipe = 'npm-hardening'; Steps = @((T 'Рецепт «Захист npm» додає ignore-scripts=true у ~/.npmrc. Вручну: npm config set ignore-scripts true. pnpm оновіть до версії 10+: corepack use pnpm@latest або npm i -g pnpm.' 'The "npm hardening" recipe adds ignore-scripts=true to ~/.npmrc. Manually: npm config set ignore-scripts true. Update pnpm to version 10+: corepack use pnpm@latest or npm i -g pnpm.')) }
        }
        @{
            Id = 'package-cooldown'; Title = (T 'Затримка для свіжих версій пакетів' 'Cooldown for freshly published packages')
            Test = {
                $npm = Get-NodeToolVersion 'npm'; $pnpm = Get-NodeToolVersion 'pnpm'
                if (-not $npm -and -not $pnpm) { return NotApplicable (T 'npm і pnpm не знайдено.' 'npm and pnpm not found.') }
                $ev = @(); $bad = $false
                if ($npm) {
                    $age = Get-NpmrcValue 'min-release-age'
                    if ($age -and [int]$age -gt 0) { $ev += "✓ npm $npm - min-release-age=$age " + (T 'дн.' 'days') }
                    elseif ($npm.Major -gt 0 -and $npm.Major -lt 11) { $bad = $true; $ev += "⚠ npm $npm - " + (T 'затримка (min-release-age) з''явилась у npm 11: оновіть npm (npm i -g npm@latest)' 'the cooldown (min-release-age) arrived in npm 11: update npm (npm i -g npm@latest)') }
                    else { $bad = $true; $ev += "⚠ npm $npm - " + (T 'min-release-age не задано: встановлюється версія, опублікована хоч хвилину тому' 'min-release-age is not set: a version published a minute ago gets installed') }
                }
                if ($pnpm) {
                    $set = $false
                    foreach ($f in (Join-Path $env:LOCALAPPDATA 'pnpm\config\rc'), (Join-Path $env:LOCALAPPDATA 'pnpm\config\config.yaml'), (Join-Path $env:USERPROFILE '.config\pnpm\config.yaml')) {
                        if ((Read-SharedText $f 1MB) -match '(?im)^\s*(minimumReleaseAge|minimum-release-age)\s*[:=]\s*[1-9]') { $set = $true }
                    }
                    if ($set) { $ev += "✓ pnpm $pnpm - " + (T 'minimumReleaseAge задано глобально' 'minimumReleaseAge is set globally') }
                    else { $ev += "· pnpm $pnpm - " + (T 'глобально не задано; у проєктах додайте minimumReleaseAge: 10080 (хвилини = 7 днів) у pnpm-workspace.yaml' 'not set globally; in projects add minimumReleaseAge: 10080 (minutes = 7 days) to pnpm-workspace.yaml') }
                }
                if (-not $bad) { return Ok (T 'налаштовано' 'configured') '' $ev }
                Issue low (T 'немає' 'none') (T 'Заражену версію пакета зазвичай знаходять і видаляють з реєстру за кілька годин або днів. Якщо менеджер пакетів не бере версії, молодші за тиждень, більшість таких атак вас просто не зачепить - без жодної перевірки коду.' 'An infected package version is usually found and pulled from the registry within hours or days. If the package manager refuses versions younger than a week, most such attacks simply pass you by - with no code review at all.') $ev
            }
            Explain = (T 'Зловмисник, який украв обліковий запис автора, публікує нову «версію» популярного пакета. Найбільше жертв - у перші години, поки спільнота не помітила. Затримка (cooldown) - це правило «не встановлювати версії, яким менше N днів».' 'An attacker who stole a maintainer account publishes a new "version" of a popular package. Most victims fall in the first hours, before the community notices. A cooldown is the rule "do not install versions younger than N days".')
            Pros = @((T 'Найдешевший захист від зламаних оновлень популярних пакетів' 'The cheapest protection from compromised updates of popular packages'))
            Cons = @((T 'Термінове виправлення безпеки у залежності прийде із затримкою - тоді версію вказують явно' 'An urgent security fix in a dependency arrives late - pin that version explicitly then'), (T 'Не допомагає проти пакета, який був шкідливим від початку і пролежав довше за затримку' 'Does not help against a package that was malicious from the start and sat longer than the cooldown'))
            Fix = @{ Recipe = 'npm-hardening'; Steps = @((T 'npm 11+: npm config set min-release-age 7. pnpm 10.16+: minimumReleaseAge: 10080 у pnpm-workspace.yaml. Bun: minimumReleaseAge у bunfig.toml. Yarn 4.10+: npmMinimalAgeGate у .yarnrc.yml. Python (uv): exclude-newer.' 'npm 11+: npm config set min-release-age 7. pnpm 10.16+: minimumReleaseAge: 10080 in pnpm-workspace.yaml. Bun: minimumReleaseAge in bunfig.toml. Yarn 4.10+: npmMinimalAgeGate in .yarnrc.yml. Python (uv): exclude-newer.')) }
        }
        @{
            Id = 'agent-permissions'; Title = (T 'Права ШІ-агентів і автозапуск у редакторах' 'AI agent permissions and editor auto-run')
            Test = {
                $bad = @(); $seen = @()
                $u = $env:USERPROFILE
                # Claude Code
                foreach ($f in "$u\.claude\settings.json", "$u\.claude\settings.local.json") {
                    if (-not (Test-Path -LiteralPath $f)) { continue }
                    $seen += 'Claude Code'
                    try { $s = Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
                    if ($s.permissions.defaultMode -eq 'bypassPermissions') { $bad += "⚠ Claude Code: " + (T 'режим bypassPermissions - агент виконує будь-які команди без запиту' 'bypassPermissions mode - the agent runs any command without asking') + " ($f)" }
                    $wide = @($s.permissions.allow | Where-Object { $_ -match '^Bash(\(\s*(\*|:\*)?\s*\))?$' })
                    if ($wide) { $bad += "⚠ Claude Code: " + (T 'дозволено всі команди оболонки' 'all shell commands are allowed') + " ($($wide -join ', '))" }
                    if ($s.skipDangerousModePermissionPrompt) { $bad += "⚠ Claude Code: " + (T 'вимкнено попередження про небезпечний режим' 'the dangerous-mode warning is turned off') }
                }
                # Codex
                $codex = Read-SharedText "$u\.codex\config.toml" 2MB
                if ($codex) {
                    $seen += 'Codex'
                    if ($codex -match '(?m)^\s*sandbox_mode\s*=\s*"danger-full-access"') { $bad += "⚠ Codex: sandbox_mode = danger-full-access - " + (T 'агент працює без пісочниці' 'the agent runs without a sandbox') }
                    if ($codex -match '(?m)^\s*approval_policy\s*=\s*"never"') { $bad += "⚠ Codex: approval_policy = never - " + (T 'команди виконуються без підтвердження' 'commands run without approval') }
                }
                # Редактори
                foreach ($e in Get-EditorSettings) {
                    $seen += $e.Name
                    if ($e.Text -match '"chat\.tools(\.global)?\.autoApprove"\s*:\s*true') { $bad += "⚠ $($e.Name): chat.tools.autoApprove - " + (T 'агент запускає інструменти й команди без запиту' 'the agent runs tools and commands without asking') }
                    if ($e.Text -match '"security\.workspace\.trust\.enabled"\s*:\s*false') { $bad += "⚠ $($e.Name): " + (T 'довіру до робочих папок вимкнено - будь-яка відкрита папка може запускати завдання й розширення' 'Workspace Trust is off - any opened folder can run tasks and extensions') }
                    if ($e.Text -match '"task\.allowAutomaticTasks"\s*:\s*"on"') { $bad += "⚠ $($e.Name): task.allowAutomaticTasks = on - " + (T 'завдання з .vscode/tasks.json запускаються, щойно папку відкрито' 'tasks from .vscode/tasks.json run as soon as a folder is opened') }
                    if ($e.Text -match '"terminal\.integrated\.(enableAutoRun|autoApprove)"|"cursor\.[a-zA-Z.]*(yolo|autoRun)[a-zA-Z.]*"\s*:\s*true') { $bad += "⚠ $($e.Name): " + (T 'увімкнено автоматичне виконання команд агентом' 'automatic command execution by the agent is on') }
                }
                $seen = @($seen | Sort-Object -Unique)
                if (-not $seen) { return NotApplicable (T 'ШІ-агентів і редакторів із налаштуваннями не знайдено.' 'No AI agents or editors with settings found.') }
                $note = (T 'Перевірено: ' 'Checked: ') + ($seen -join ', ') + '.'
                if (-not $bad) { return Ok (T 'запит перед виконанням' 'asks before running') $note }
                Issue high (T "$($bad.Count) шт." "$($bad.Count)") ((T 'Агент читає README, коментарі в коді, вебсторінки й відповіді інструментів - і в будь-якому з них може бути прихована інструкція («встанови цей пакет», «виконай цю команду»). Запит на підтвердження - єдине, що стоїть між такою інструкцією і вашим ПК. ' 'The agent reads READMEs, code comments, web pages and tool output - and any of them may hide an instruction ("install this package", "run this command"). The approval prompt is the only thing between such an instruction and your PC. ') + $note) $bad
            }
            Explain = (T 'ШІ-агент - це програма з вашими правами, якою керує текст. Атака «prompt injection» підсовує йому чужий текст як завдання. У режимах без підтвердження (YOLO, bypass, auto-approve) така інструкція виконується одразу. Те саме стосується автозапуску завдань у редакторі: відкрив чужий репозиторій - команда вже виконалась.' 'An AI agent is a program with your rights that is steered by text. A prompt injection attack feeds it someone else''s text as a task. In no-approval modes (YOLO, bypass, auto-approve) such an instruction runs at once. The same goes for editor auto-run tasks: open someone''s repository and the command has already run.')
            Pros = @((T 'Прихована інструкція в чужому коді не виконається без вашого «так»' 'A hidden instruction in foreign code does not run without your "yes"'))
            Cons = @((T 'Більше запитів під час роботи - їх зменшують точкові дозволи на безпечні команди, а не загальний «дозволити все»' 'More prompts while working - reduce them with narrow allow rules for safe commands, not a blanket "allow all"'), (T 'Режим без підтверджень лишається доречним в одноразовій віртуальній машині або контейнері без ваших ключів' 'No-approval mode remains fine inside a disposable VM or container that holds none of your keys'))
            Fix = @{ Steps = @(
                (T 'Claude Code: приберіть "defaultMode": "bypassPermissions" і загальний дозвіл Bash із ~/.claude/settings.json; дозволяйте конкретні команди (Bash(git status:*)).' 'Claude Code: remove "defaultMode": "bypassPermissions" and the blanket Bash allow from ~/.claude/settings.json; allow specific commands (Bash(git status:*)).'),
                (T 'Codex: sandbox_mode = "workspace-write", approval_policy = "on-request" у ~/.codex/config.toml.' 'Codex: sandbox_mode = "workspace-write", approval_policy = "on-request" in ~/.codex/config.toml.'),
                (T 'VS Code / Cursor: "task.allowAutomaticTasks": "off", довіру до робочих папок увімкнено, автосхвалення інструментів вимкнено. Чужі репозиторії відкривайте в режимі обмеженої довіри.' 'VS Code / Cursor: "task.allowAutomaticTasks": "off", Workspace Trust on, tool auto-approval off. Open foreign repositories in Restricted Mode.')
            ) }
        }
        @{
            Id = 'mcp-servers'; Title = (T 'Сервери MCP для ШІ-агентів' 'MCP servers for AI agents')
            Test = {
                $servers = @(Get-McpServers)
                if (-not $servers) { return Ok (T 'немає' 'none') (T 'Жодного сервера MCP у налаштуваннях агентів не знайдено.' 'No MCP servers found in agent settings.') }
                $bad = 0
                $ev = foreach ($s in $servers | Sort-Object Source, Name -Unique) {
                    $flags = @()
                    $runner = [IO.Path]::GetFileNameWithoutExtension($s.Command).ToLowerInvariant()
                    $line = "$($s.Command) $($s.Args -join ' ')".Trim()
                    if ($runner -in 'npx', 'bunx', 'pnpx', 'uvx', 'pipx' -or $line -match '(?i)\b(pnpm|yarn)\s+dlx\b|\bnpm\s+exec\b|\buv\s+tool\s+run\b') {
                        # Перший аргумент, що не є прапорцем, - назва пакета; без точної версії щоразу береться найновіша
                        $pkg = $s.Args | Where-Object { $_ -notmatch '^-' -and $_ -notin 'dlx', 'exec', 'tool', 'run', 'cmd', '/c' } | Select-Object -First 1
                        if ($pkg -and $pkg -notmatch '(?<=.)@\d+\.\d+|==\d' ) { $flags += (T 'без зафіксованої версії: під час кожного запуску завантажується й виконується найновіша версія пакета' 'no pinned version: each start downloads and runs the newest version of the package') }
                    }
                    if ($s.Url -match '^http://(?!127\.|localhost|\[::1\])') { $flags += (T 'з''єднання без шифрування' 'unencrypted connection') }
                    if ($flags) { $bad++ }
                    $(if ($flags) { '⚠ ' } else { '' }) + "$($s.Source): $($s.Name) - " + $(if ($s.Url) { $s.Url } else { ($line -replace '(?i)((key|token|secret|password)\S*[= ])\S+', '$1***') }) + $(if ($flags) { "  [$($flags -join '; ')]" })
                }
                $value = T "$(@($ev).Count) шт." "$(@($ev).Count)"
                if ($bad) { return Issue medium (T "$(@($ev).Count) шт., ризикованих $bad" "$(@($ev).Count), risky $bad") (T 'Сервер MCP - це програма, яку агент запускає сам і якій довіряє. Якщо він стартує через npx/uvx без точної версії, зламане оновлення пакета виконається на вашому ПК під час наступного запуску агента - без жодної вашої дії.' 'An MCP server is a program the agent starts by itself and trusts. If it launches through npx/uvx without an exact version, a compromised package update runs on your PC the next time the agent starts - with no action from you.') $ev }
                Issue info $value (T 'Кожен сервер MCP працює з вашими правами, а описи його інструментів потрапляють агентові як інструкції. Лишайте тільки ті, якими користуєтеся й авторам яких довіряєте.' 'Each MCP server runs with your rights, and its tool descriptions reach the agent as instructions. Keep only the ones you use and whose authors you trust.') $ev
            }
            Explain = (T 'MCP-сервери дають агентові інструменти: доступ до файлів, браузера, баз даних. Ризики два: сам сервер - це код із пакета (ланцюг постачання), а описи його інструментів агент сприймає як довірений текст (так звані «отруєні» інструменти можуть наказати агентові надіслати ваші файли).' 'MCP servers give the agent tools: access to files, a browser, databases. There are two risks: the server itself is code from a package (supply chain), and the agent takes its tool descriptions as trusted text (so-called "poisoned" tools can tell the agent to send your files away).')
            Pros = @((T 'Зламане оновлення MCP-сервера не потрапить на ПК саме' 'A compromised MCP server update does not land on the PC by itself'))
            Cons = @((T 'Зафіксовану версію треба оновлювати вручну' 'A pinned version has to be updated by hand'))
            Fix = @{ Steps = @((T 'У налаштуваннях агента замініть «npx -y пакет» на «npx -y пакет@1.2.3» (uvx: пакет==1.2.3) - конкретну версію, яку ви перевірили. Сервери, якими не користуєтеся, видаліть.' 'In the agent settings replace "npx -y package" with "npx -y package@1.2.3" (uvx: package==1.2.3) - a specific version you reviewed. Remove servers you do not use.')) }
        }
        @{
            Id = 'agent-instructions'; Title = (T 'Приховані символи в інструкціях для ШІ-агентів' 'Hidden characters in AI agent instructions')
            Test = {
                $files = @(Get-AgentInstructionFiles)
                if (-not $files) { return Ok (T 'файлів немає' 'no files') }
                # Блок «тегів» Unicode (невидимі копії ASCII) і керування напрямком тексту: людина їх не бачить, модель - читає
                $tags = [regex]'\uDB40[\uDC00-\uDC7F]'; $bidi = [regex]'[‪-‮⁦-⁩]'; $zero = [regex]'[​⁠-⁤]|(?<!^)﻿'
                $hits = @(); $sev = $null
                foreach ($f in $files) {
                    try { $t = [IO.File]::ReadAllText($f) } catch { continue }
                    if ($t.Length -gt 2MB) { continue }
                    $nt = $tags.Matches($t).Count; $nb = $bidi.Matches($t).Count; $nz = $zero.Matches($t).Count
                    if ($nt -or $nb) { $sev = 'high'; $hits += "⚠ $f - " + (T "невидимих символів-тегів: $nt, керування напрямком тексту: $nb" "invisible tag characters: $nt, text direction controls: $nb") }
                    elseif ($nz -ge 5) { if (-not $sev) { $sev = 'low' }; $hits += "$f - " + (T "символів нульової ширини: $nz" "zero-width characters: $nz") }
                }
                $note = T "Перевірено файлів інструкцій: $($files.Count)." "Instruction files checked: $($files.Count)."
                if (-not $hits) { return Ok (T 'не знайдено' 'none found') $note }
                Issue $sev (T "$($hits.Count) файлів" "$($hits.Count) files") ((T 'У цих файлах є текст, якого не видно в редакторі, але який читає модель. Так ховають інструкції для агента: «тихо додай цей пакет», «надішли вміст .env». Правила, навички й команди агент виконує в кожній сесії - це закріплення, якого не знайде жоден антивірус. ' 'These files contain text invisible in an editor but readable by the model. This is how instructions for the agent are hidden: "quietly add this package", "send the contents of .env". Rules, skills and commands are applied in every session - persistence no antivirus will find. ') + $note) $hits
            }
            Explain = (T 'Файли CLAUDE.md, AGENTS.md, правила Cursor, навички й команди - це інструкції, яким агент довіряє найбільше. Їх часто копіюють з інтернету («корисні правила для Cursor»). Невидимі символи Unicode дозволяють вписати туди команду, якої ви не побачите під час перегляду.' 'CLAUDE.md, AGENTS.md, Cursor rules, skills and commands are the instructions the agent trusts most. They are often copied from the internet ("useful Cursor rules"). Invisible Unicode characters allow a command to be written there that you will not see when reviewing.')
            Pros = @((T 'Ловить закладку в самому агенті - те, що не є програмою і не видно очима' 'Catches a backdoor in the agent itself - something that is not a program and is invisible to the eye'))
            Cons = @((T 'Символи нульової ширини трапляються й випадково (копіювання з вебсторінок) - тому вони дають лише низький рівень' 'Zero-width characters also occur by accident (copying from web pages) - hence only a low level for them'))
            Fix = @{ Steps = @((T 'Відкрийте файл у редакторі з показом невидимих символів (VS Code: «Render Control Characters», підсвічування Unicode) або видаліть і створіть заново з джерела, якому довіряєте. Перевірте також правила в самих репозиторіях (.cursor/rules, CLAUDE.md, AGENTS.md).' 'Open the file in an editor that shows invisible characters (VS Code: "Render Control Characters", Unicode highlighting) or delete it and recreate it from a source you trust. Also check the rules inside repositories themselves (.cursor/rules, CLAUDE.md, AGENTS.md).')) }
        }
        @{
            Id = 'git-exec-config'; Title = (T 'Команди в глобальних налаштуваннях Git' 'Commands in the global Git configuration')
            Test = {
                $f = Join-Path $env:USERPROFILE '.gitconfig'
                $text = Read-SharedText $f 2MB
                if (-not $text) { return Ok (T 'немає' 'none') }
                $ev = @(); $bad = $false
                foreach ($m in [regex]::Matches($text, '(?im)^\s*(hooksPath|fsmonitor|sshCommand|gitProxy|askPass|pager|editor|externalDiff|textconv|clean|smudge|process)\s*=\s*(.+?)\s*$')) {
                    $k = $m.Groups[1].Value; $v = $m.Groups[2].Value
                    if ($k -in 'fsmonitor' -and $v -match '^(true|false)$') { continue }
                    if ($k -in 'pager', 'editor' -and $v -notmatch '(?i)curl|wget|powershell|pwsh|cmd(\.exe)? /c|iex|base64|\\temp\\|\\appdata\\local\\temp') { continue }
                    if ($k -in 'clean', 'smudge', 'process' -and $v -match '^git-lfs ') { continue }
                    $risk = (Get-PathRisk (Get-ExeFromCommand $v)).Points -ge 2 -or $v -match '(?i)curl|wget|powershell|pwsh|iex|base64|mshta'
                    if ($risk) { $bad = $true }
                    $ev += $(if ($risk) { '⚠ ' } else { '' }) + "$k = $v"
                }
                foreach ($m in [regex]::Matches($text, '(?im)^\s*([\w-]+)\s*=\s*!(.+?)\s*$')) {
                    if ($m.Groups[2].Value -match '(?i)curl|wget|powershell|pwsh|iex|base64|mshta') { $bad = $true; $ev += "⚠ alias $($m.Groups[1].Value) = !$($m.Groups[2].Value)" }
                }
                if (-not $ev) { return Ok (T 'не знайдено' 'none found') }
                if ($bad) { return Issue high (T "$($ev.Count) шт." "$($ev.Count)") (T 'Git виконує ці програми сам під час звичайних команд (status, commit, fetch) у кожному репозиторії. Позначені ⚠ завантажують щось із мережі або лежать у тимчасовій папці - так закріплюються шкідливі пакети.' 'Git runs these programs by itself during ordinary commands (status, commit, fetch) in every repository. Those marked ⚠ download something or sit in a temporary folder - this is how malicious packages persist.') $ev }
                Issue info (T "$($ev.Count) шт." "$($ev.Count)") (T 'Git запускає ці програми під час звичайних команд у кожному репозиторії. Переконайтеся, що налаштували їх самі.' 'Git runs these programs during ordinary commands in every repository. Make sure you configured them yourself.') $ev
            }
            Explain = (T 'У ~/.gitconfig можна прописати програму, яку Git викликатиме сам: спільна папка хуків (core.hooksPath), монітор файлів, команда SSH, фільтри. Шкідливий скрипт встановлення пакета може додати туди рядок - і отримати запуск під час кожного вашого git commit.' 'In ~/.gitconfig one can register a program Git will call by itself: a shared hooks folder (core.hooksPath), a file monitor, an SSH command, filters. A malicious package install script can add a line there - and get executed on your every git commit.')
            Pros = @((T 'Видно закріплення, що спрацьовує через Git' 'Reveals persistence that fires through Git'))
            Cons = @()
            Fix = @{ Steps = @((T 'Перегляньте джерела налаштувань: git config --global --list --show-origin. Зайве видаліть: git config --global --unset <ключ>.' 'Review where settings come from: git config --global --list --show-origin. Remove what you did not add: git config --global --unset <key>.')) }
        }
    )
}
