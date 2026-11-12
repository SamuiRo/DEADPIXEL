# Паролі й секрети: що з цього ПК забере викрадач паролів (infostealer) за кілька секунд.
# Аудит читає лише назви сайтів, імена файлів і змінних - самі паролі, токени й ключі не читаються і в звіт не потрапляють.

# Сайти, пароль від яких відкриває гроші, пошту (а через неї - решту акаунтів), код чи документи
$script:ImportantSites = '(?i)(^|\.)(' + (@(
    'google\.com', 'gmail\.com', 'live\.com', 'microsoft\.com', 'microsoftonline\.com', 'outlook\.com', 'apple\.com', 'icloud\.com', 'proton\.me', 'protonmail\.com', 'ukr\.net', 'yahoo\.com', 'i\.ua', 'meta\.ua'
    'privatbank\.ua', 'privat24\.ua', 'monobank\.ua', 'oschadbank\.ua', 'pumb\.ua', 'raiffeisen\.ua', 'a-bank\.com\.ua', 'sense-bank\.ua', 'ukrsibbank\.com', 'paypal\.com', 'wise\.com', 'revolut\.com', 'payoneer\.com', 'stripe\.com'
    'binance\.com', 'coinbase\.com', 'kraken\.com', 'bybit\.com', 'okx\.com', 'whitebit\.com', 'kuna\.io', 'metamask\.io'
    'diia\.gov\.ua', 'gov\.ua', 'tax\.gov\.ua'
    'github\.com', 'gitlab\.com', 'bitbucket\.org', 'aws\.amazon\.com', 'amazon\.com', 'console\.cloud\.google\.com', 'azure\.com', 'digitalocean\.com', 'cloudflare\.com', 'npmjs\.com', 'docker\.com', 'hetzner\.com', 'namecheap\.com', 'godaddy\.com'
    'facebook\.com', 'instagram\.com', 'telegram\.org', 'discord\.com', 'steampowered\.com', 'steamcommunity\.com', 'twitter\.com', 'x\.com', 'linkedin\.com', 'epicgames\.com', 'battle\.net'
    'bitwarden\.com', '1password\.com', 'lastpass\.com', 'dropbox\.com', 'mega\.nz', 'anthropic\.com', 'claude\.ai', 'openai\.com'
) -join '|') + ')$'

function Get-HostName([string]$Url) {
    $u = $null
    if ([Uri]::TryCreate($Url, 'Absolute', [ref]$u) -and $u.Host) { return $u.Host.ToLowerInvariant() }
    $null
}

# Збережені паролі: @{ Label; Hosts = @(...) } на профіль
function Get-SavedLogins {
    foreach ($p in Get-ChromiumProfiles) {
        $rows = Invoke-Sqlite (Join-Path $p.Path 'Login Data') 'SELECT signon_realm FROM logins WHERE blacklisted_by_user = 0'
        if ($null -eq $rows) { continue }
        [pscustomobject]@{ Label = $p.Label; Hosts = @($rows | ForEach-Object { Get-HostName $_[0] } | Where-Object { $_ }) }
    }
    foreach ($p in Get-FirefoxProfiles) {
        $f = Join-Path $p.Path 'logins.json'
        if (-not (Test-Path -LiteralPath $f)) { continue }
        # Регулярний вираз, а не ConvertFrom-Json: у PowerShell 5.1 той не читає файли понад 2 МБ
        $text = Read-SharedText $f 50MB
        if ($null -eq $text) { continue }
        [pscustomobject]@{ Label = $p.Label; Hosts = @([regex]::Matches($text, '"hostname"\s*:\s*"([^"]+)"') | ForEach-Object { Get-HostName $_.Groups[1].Value } | Where-Object { $_ }) }
    }
}

# Файли в профілі користувача, де програми зберігають токени відкритим текстом: відносний шлях, ознака секрету, що це
$script:SecretFiles = @(
    @{ Path = '.aws\credentials'; Match = '(?im)^\s*aws_secret_access_key\s*='; What = (T 'ключі доступу AWS' 'AWS access keys') }
    @{ Path = '.git-credentials'; Match = '://[^/\s:]+:[^@\s]+@'; What = (T 'паролі/токени Git (credential.helper=store)' 'Git passwords/tokens (credential.helper=store)') }
    @{ Path = '.npmrc'; Match = '(?im)^\s*(//[^\s=]+:)?(_authToken|_auth|_password)\s*=\s*(?!\$\{)\S'; What = (T 'токен публікації npm' 'npm publish token') }
    @{ Path = '.yarnrc.yml'; Match = '(?im)^\s*npmAuthToken\s*:\s*["'']?(?!\$\{)\S'; What = (T 'токен npm (Yarn)' 'npm token (Yarn)') }
    @{ Path = '.pypirc'; Match = '(?im)^\s*password\s*[=:]\s*\S'; What = (T 'токен публікації PyPI' 'PyPI publish token') }
    @{ Path = '.netrc'; Match = '(?i)\bpassword\s+\S'; What = (T 'паролі до серверів (.netrc)' 'server passwords (.netrc)') }
    @{ Path = '_netrc'; Match = '(?i)\bpassword\s+\S'; What = (T 'паролі до серверів (_netrc)' 'server passwords (_netrc)') }
    @{ Path = '.docker\config.json'; Match = '"auth"\s*:\s*"[A-Za-z0-9+/=]{8,}"'; What = (T 'паролі до реєстрів Docker' 'Docker registry passwords') }
    @{ Path = '.kube\config'; Match = '(?im)^\s*(token|client-key-data|password)\s*:\s*\S'; What = (T 'доступ до кластерів Kubernetes' 'Kubernetes cluster access') }
    @{ Path = '.config\gh\hosts.yml'; Match = '(?im)^\s*oauth_token\s*:\s*\S'; What = (T 'токен GitHub CLI' 'GitHub CLI token') }
    @{ Path = '.cargo\credentials.toml'; Match = '(?im)^\s*token\s*=\s*\S'; What = (T 'токен crates.io' 'crates.io token') }
    @{ Path = '.cargo\credentials'; Match = '(?im)^\s*token\s*=\s*\S'; What = (T 'токен crates.io' 'crates.io token') }
    @{ Path = 'AppData\Roaming\terraform.d\credentials.tfrc.json'; Match = '"token"\s*:\s*"\S'; What = (T 'токен Terraform Cloud' 'Terraform Cloud token') }
    @{ Path = 'AppData\Roaming\gcloud\application_default_credentials.json'; Match = '"(refresh_token|private_key)"\s*:'; What = (T 'облікові дані Google Cloud' 'Google Cloud credentials') }
    @{ Path = 'AppData\Roaming\gcloud\legacy_credentials'; Match = $null; What = (T 'облікові дані Google Cloud' 'Google Cloud credentials') }
    @{ Path = '.azure\msal_token_cache.json'; Match = '"secret"\s*:'; What = (T 'токени Azure CLI без шифрування' 'unencrypted Azure CLI tokens') }
    @{ Path = 'AppData\Roaming\rclone\rclone.conf'; Match = '(?im)^\s*(token|pass|secret_access_key|key)\s*=\s*\S'; What = (T 'доступ до хмарних сховищ (rclone)' 'cloud storage access (rclone)') }
    @{ Path = 'AppData\Roaming\FileZilla\sitemanager.xml'; Match = '<Pass\b'; What = (T 'паролі FTP/SFTP (FileZilla)' 'FTP/SFTP passwords (FileZilla)') }
    @{ Path = 'AppData\Roaming\FileZilla\recentservers.xml'; Match = '<Pass\b'; What = (T 'паролі FTP/SFTP (FileZilla)' 'FTP/SFTP passwords (FileZilla)') }
    @{ Path = '.composer\auth.json'; Match = '"(password|token|oauth)"|"[a-z.]+"\s*:\s*"\S{16,}"'; What = (T 'токени Composer' 'Composer tokens') }
    @{ Path = '.m2\settings.xml'; Match = '<password>[^<{]'; What = (T 'паролі до сховищ Maven' 'Maven repository passwords') }
    @{ Path = '.gradle\gradle.properties'; Match = '(?im)^\s*\S*(password|token|secret)\S*\s*=\s*\S'; What = (T 'паролі в налаштуваннях Gradle' 'passwords in Gradle settings') }
)

# Приватний ключ SSH: 'encrypted' | 'plain' | $null (не ключ)
function Get-SshKeyState([string]$Path) {
    try {
        $fi = Get-Item -LiteralPath $Path -Force
        if ($fi.Length -gt 64KB -or $fi.Length -lt 100) { return $null }
        $text = [IO.File]::ReadAllText($Path)
    } catch { return $null }
    if ($text -match '^PuTTY-User-Key-File') { if ($text -match '(?m)^Encryption:\s*none') { return 'plain' } else { return 'encrypted' } }
    if ($text -notmatch '-----BEGIN ([A-Z ]*)PRIVATE KEY-----') { return $null }
    if ($Matches[1] -match 'ENCRYPTED' -or $text -match 'Proc-Type:\s*4,ENCRYPTED') { return 'encrypted' }
    if ($Matches[1] -match 'OPENSSH') {
        # Формат OpenSSH: "openssh-key-v1\0", далі довжина (4 байти) й назва шифру; "none" - ключ без пароля
        try {
            $b64 = ($text -replace '-----[^-]+-----', '' -replace '\s', '')
            $raw = [Convert]::FromBase64String($b64.Substring(0, [Math]::Min($b64.Length, 64)))
            $len = ($raw[15] -shl 24) -bor ($raw[16] -shl 16) -bor ($raw[17] -shl 8) -bor $raw[18]
            if ([Text.Encoding]::ASCII.GetString($raw, 19, [Math]::Min($len, $raw.Length - 19)) -eq 'none') { return 'plain' } else { return 'encrypted' }
        } catch { return 'plain' }
    }
    'plain'
}

# Назва розширення: у маніфесті часто стоїть __MSG_ключ__, а текст - у _locales
function Get-ExtensionName([string]$Dir, $Manifest) {
    $name = [string]$Manifest.name
    if ($name -notmatch '^__MSG_(.+)__$') { return $name }
    $key = $Matches[1]
    foreach ($loc in @([string]$Manifest.default_locale, 'en', 'en_US') | Where-Object { $_ }) {
        $f = Join-Path $Dir "_locales\$loc\messages.json"
        if (-not (Test-Path -LiteralPath $f)) { continue }
        try {
            $m = Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json
            $p = $m.PSObject.Properties | Where-Object { $_.Name -eq $key } | Select-Object -First 1   # ключі без урахування регістру
            if ($p -and $p.Value.message) { return [string]$p.Value.message }
        } catch { }
    }
    $name
}

@{
    Id = 'secrets'; Title = (T 'Паролі й секрети' 'Passwords and secrets'); Order = 3.5
    Checks = @(
        @{
            Id = 'browser-passwords'; Title = (T 'Паролі, збережені в браузерах' 'Passwords saved in browsers')
            Test = {
                $profiles = @(Get-SavedLogins)
                if (-not $profiles) { return NotApplicable (T 'Браузерів зі сховищем паролів не знайдено.' 'No browsers with a password store found.') }
                $total = 0; $ev = @(); $important = @()
                foreach ($p in $profiles) {
                    if (-not $p.Hosts.Count) { continue }
                    $total += $p.Hosts.Count
                    $imp = @($p.Hosts | Where-Object { $_ -match $ImportantSites } | Sort-Object -Unique)
                    $important += $imp
                    $ev += "$($p.Label): " + (T "$($p.Hosts.Count) паролів" "$($p.Hosts.Count) passwords") + $(if ($imp) { (T ', серед них важливі: ' ', important among them: ') + (($imp | Select-Object -First 15) -join ', ') + $(if ($imp.Count -gt 15) { " … +$($imp.Count - 15)" }) })
                }
                if ($total -eq 0) { return Ok (T 'немає' 'none') (T 'У браузерах не збережено жодного пароля.' 'No passwords are saved in browsers.') }
                $important = @($important | Sort-Object -Unique)
                $why = T 'Браузер шифрує паролі ключем, який лежить у вашому ж профілі Windows. Будь-яка програма, запущена від вашого імені (зламаний лаунчер, «кряк», макрос), розшифровує всю базу за секунди й без жодного запиту - саме так працюють викрадачі паролів.' 'The browser encrypts passwords with a key stored in your own Windows profile. Any program running as you (a compromised launcher, a "crack", a macro) decrypts the whole store in seconds with no prompt - this is exactly how password stealers work.'
                if ($important) { return Issue medium (T "$total, важливих сайтів: $($important.Count)" "$total, important sites: $($important.Count)") $why $ev }
                Issue low (T "$total шт." "$total") $why $ev
            }
            Explain = (T 'Менеджер паролів браузера зручний, але не захищений від програм на цьому ж ПК: базі не потрібен головний пароль. Окремий менеджер (KeePassXC, Bitwarden, 1Password) шифрує базу головним паролем, якого на диску немає, і блокується, коли ви відходите. Аудит читає лише адреси сайтів; самі паролі не розшифровуються і нікуди не потрапляють.' 'The browser password manager is convenient but not protected from programs on the same PC: the store needs no master password. A dedicated manager (KeePassXC, Bitwarden, 1Password) encrypts its database with a master password that is not on disk and locks when you step away. The audit reads only site addresses; the passwords themselves are not decrypted and go nowhere.')
            Pros = @((T 'Викрадач паролів, що потрапив на ПК, не забере всі акаунти одразу' 'A password stealer that lands on the PC does not take every account at once'), (T 'Один менеджер для всіх браузерів і пристроїв' 'One manager for all browsers and devices'))
            Cons = @((T 'Автозаповнення працює через розширення менеджера - на крок довше' 'Autofill works through the manager''s extension - one step longer'), (T 'Забутий головний пароль не відновити: потрібна резервна копія бази' 'A forgotten master password cannot be recovered: keep a backup of the database'))
            Fix = @{ Steps = @(
                (T 'Експортуйте паролі з браузера (Налаштування → Паролі → Експорт) та імпортуйте в менеджер паролів. Файл експорту після імпорту видаліть - у ньому паролі відкритим текстом.' 'Export passwords from the browser (Settings → Passwords → Export) and import them into a password manager. Delete the export file after importing - it holds passwords in plain text.'),
                (T 'У браузері видаліть збережені паролі й вимкніть «Пропонувати зберігати паролі» та автовхід.' 'In the browser delete the saved passwords and turn off "Offer to save passwords" and auto sign-in.'),
                (T 'Для важливих акаунтів (пошта, банк, GitHub) увімкніть двофакторну автентифікацію: вкрадений пароль без другого фактора не спрацює.' 'For important accounts (mail, bank, GitHub) turn on two-factor authentication: a stolen password alone will not work.')
            ) }
        }
        @{
            Id = 'browser-cards'; Title = (T 'Платіжні картки, збережені в браузерах' 'Payment cards saved in browsers')
            Test = {
                $ev = @(); $total = 0; $seen = $false
                foreach ($p in Get-ChromiumProfiles) {
                    $rows = Invoke-Sqlite (Join-Path $p.Path 'Web Data') 'SELECT COUNT(*) FROM credit_cards'
                    if ($null -eq $rows) { continue }
                    $seen = $true
                    $n = [int]$rows[0][0]
                    if ($n) { $total += $n; $ev += "$($p.Label): $n" }
                }
                foreach ($p in Get-FirefoxProfiles) {
                    $text = Read-SharedText (Join-Path $p.Path 'autofill-profiles.json') 20MB
                    if ($null -eq $text) { continue }
                    $seen = $true
                    $n = [regex]::Matches($text, '"cc-number-encrypted"').Count
                    if ($n) { $total += $n; $ev += "$($p.Label): $n" }
                }
                if (-not $seen) { return NotApplicable (T 'Браузерів не знайдено.' 'No browsers found.') }
                if ($total -eq 0) { return Ok (T 'немає' 'none') }
                Issue medium (T "$total шт." "$total") (T 'Номер і термін дії картки лежать у профілі браузера і розшифровуються так само легко, як паролі. Код CVV браузер зазвичай не зберігає, але багато магазинів і підписок його не питають.' 'The card number and expiry date sit in the browser profile and decrypt as easily as passwords. The browser usually does not keep the CVV, but many shops and subscriptions do not ask for it.') $ev
            }
            Explain = (T 'Автозаповнення карток зберігає їх у тій самій базі, що й решту даних браузера. Викрадачі паролів забирають картки разом із паролями.' 'Card autofill keeps cards in the same store as the rest of the browser data. Password stealers take cards along with passwords.')
            Pros = @((T 'Викрадені дані браузера не містять вашої картки' 'Stolen browser data does not include your card'))
            Cons = @((T 'Номер картки доведеться вводити вручну або з менеджера паролів' 'You will type the card number manually or from a password manager'))
            Fix = @{ Steps = @((T 'Браузер → Налаштування → «Способи оплати»: видаліть картки й вимкніть «Зберігати та підставляти способи оплати». Для покупок в інтернеті зручніша віртуальна картка з лімітом.' 'Browser → Settings → Payment methods: delete the cards and turn off "Save and fill payment methods". For online shopping a virtual card with a limit is safer.')) }
        }
        @{
            Id = 'browser-extensions'; Title = (T 'Розширення браузерів' 'Browser extensions')
            Test = {
                $all = @(); $broad = 0
                foreach ($p in Get-ChromiumProfiles) {
                    foreach ($ext in Get-ChildItem -LiteralPath (Join-Path $p.Path 'Extensions') -Directory -ErrorAction SilentlyContinue) {
                        $ver = Get-ChildItem -LiteralPath $ext.FullName -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | Select-Object -Last 1
                        if (-not $ver) { continue }
                        try { $m = Get-Content -LiteralPath (Join-Path $ver.FullName 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
                        $perms = @($m.permissions) + @($m.host_permissions) + @($m.optional_host_permissions) + @($m.content_scripts | ForEach-Object { $_.matches })
                        $everywhere = [bool]($perms | Where-Object { $_ -is [string] -and $_ -match '^(<all_urls>|\*://\*/\*|https?://\*/\*)$' })
                        $risky = @($perms | Where-Object { $_ -is [string] -and $_ -in 'nativeMessaging', 'debugger', 'proxy', 'webRequestBlocking', 'cookies', 'clipboardRead', 'management' })
                        # Розширення з магазину мають адресу оновлення; без неї - встановлене в обхід магазину (його ніхто не перевіряв)
                        $sideloaded = -not $m.update_url
                        $flags = @()
                        if ($sideloaded) { $flags += (T 'не з магазину розширень' 'not from the extension store') }
                        if ($everywhere) { $flags += (T 'читає і змінює всі сайти' 'reads and changes all sites'); $broad++ }
                        if ($risky) { $flags += ($risky -join ', ') }
                        $name = Get-ExtensionName $ver.FullName $m
                        $all += [pscustomobject]@{ Bad = ($sideloaded -and ($everywhere -or $risky)); Line = "$($p.Label): $name $($m.version)" + $(if ($flags) { "  [$($flags -join '; ')]" }) + "  ($($ext.Name))" }
                    }
                }
                if (-not $all) { return Ok (T 'немає' 'none') }
                $bad = @($all | Where-Object Bad)
                $ev = @($bad | ForEach-Object { "⚠ $($_.Line)" }) + @($all | Where-Object { -not $_.Bad } | ForEach-Object Line | Sort-Object)
                $value = T "$($all.Count) шт., з доступом до всіх сайтів: $broad" "$($all.Count), with access to all sites: $broad"
                if ($bad) { return Issue medium $value (T 'Позначені ⚠ розширення встановлені не з магазину і мають широкі права: їх ніхто не перевіряв, а вони бачать усе, що ви робите в браузері. Якщо не ставили їх самі - видаліть.' 'Extensions marked ⚠ were installed outside the store and have broad rights: nobody reviewed them, yet they see everything you do in the browser. If you did not install them yourself, remove them.') $ev }
                Issue info $value (T 'Розширення з доступом до всіх сайтів бачить сторінки банку й пошти та може підміняти їх вміст. Розширення продають, а нові власники додають шкідливий код оновленням - лишайте тільки ті, якими користуєтеся.' 'An extension with access to all sites sees your bank and mail pages and can alter their content. Extensions get sold, and new owners add malicious code in an update - keep only the ones you use.') $ev
            }
            Explain = (T 'Розширення - це програма всередині браузера. З правом «читати й змінювати дані на всіх сайтах» воно бачить паролі, які ви вводите, вміст листів і може підмінити реквізити платежу. Антивірус розширення не перевіряє.' 'An extension is a program inside the browser. With the "read and change data on all sites" right it sees the passwords you type and the content of your mail, and can swap payment details. The antivirus does not check extensions.')
            Pros = @((T 'Менше коду, який бачить ваші сторінки' 'Less code that sees your pages'), (T 'Браузер працює швидше' 'The browser runs faster'))
            Cons = @((T 'Видалене розширення перестане працювати - блокувальник реклами й менеджер паролів варто лишити' 'A removed extension stops working - keep the ad blocker and the password manager'))
            Fix = @{ Steps = @((T 'Відкрийте в браузері сторінку розширень (edge://extensions, brave://extensions, opera://extensions) і видаліть зайві. Для потрібних обмежте доступ: «Доступ до сайтів» → «Після натискання» або «На певних сайтах».' 'Open the browser''s extensions page (edge://extensions, brave://extensions, opera://extensions) and remove the unneeded ones. For the ones you keep, restrict access: "Site access" → "On click" or "On specific sites".')) }
        }
        @{
            Id = 'plaintext-tokens'; Title = (T 'Токени й ключі у відкритих файлах' 'Tokens and keys in plain-text files')
            Test = {
                $found = @()
                foreach ($s in $SecretFiles) {
                    $f = Join-Path $env:USERPROFILE $s.Path
                    if (-not (Test-Path -LiteralPath $f)) { continue }
                    if ($s.Match) {
                        if (Test-Path -LiteralPath $f -PathType Container) { continue }
                        $text = Read-SharedText $f 5MB
                        if (-not $text -or $text -notmatch $s.Match) { continue }
                    }
                    $found += "$f - $($s.What)"
                }
                # git credential.helper=store зберігає паролі в .git-credentials відкритим текстом
                $gitconfig = Join-Path $env:USERPROFILE '.gitconfig'
                if ((Test-Path -LiteralPath $gitconfig) -and ((Read-SharedText $gitconfig 1MB) -match '(?im)^\s*helper\s*=\s*store\b')) {
                    $found += "$gitconfig - " + (T 'Git налаштовано зберігати паролі відкритим текстом (credential.helper = store)' 'Git is set to store passwords in plain text (credential.helper = store)')
                }
                if (-not $found) { return Ok (T 'не знайдено' 'none found') (T "Перевірено відомих місць: $($SecretFiles.Count)." "Known locations checked: $($SecretFiles.Count).") }
                Issue medium (T "$($found.Count) шт." "$($found.Count)") (T 'Ці файли містять робочі токени й ключі без шифрування. Викрадачі паролів мають готовий список таких шляхів і забирають їх першими: з токеном npm чи ключем AWS зловмисник діє від вашого імені без пароля і двофакторного коду.' 'These files hold working tokens and keys without encryption. Password stealers carry a ready list of such paths and grab them first: with an npm token or an AWS key the attacker acts as you, with no password or two-factor code.') $found
            }
            Explain = (T 'Інструменти розробника за замовчуванням часто кладуть токени у звичайний текстовий файл у профілі користувача. Прочитати його може будь-яка програма, запущена від вашого імені. Аудит перевіряє лише наявність секрету у відомих файлах; значення не читаються у звіт.' 'Developer tools often put tokens into an ordinary text file in the user profile by default. Any program running as you can read it. The audit only checks whether a secret is present in known files; the values are not copied into the report.')
            Pros = @((T 'Зламаний пакет або лаунчер не забере доступ до ваших репозиторіїв і хмар' 'A compromised package or launcher does not take access to your repositories and clouds'))
            Cons = @((T 'Після переходу на сховище облікових даних інструмент попросить увійти ще раз' 'After switching to a credential store the tool asks you to sign in again'), (T 'CI та скрипти, що читали файл напряму, доведеться переналаштувати' 'CI and scripts that read the file directly need reconfiguring'))
            Fix = @{ Steps = @(
                (T 'Git: git config --global credential.helper manager (паролі підуть у Диспетчер облікових даних Windows), потім видаліть .git-credentials.' 'Git: git config --global credential.helper manager (passwords go to Windows Credential Manager), then delete .git-credentials.'),
                (T 'AWS: aws configure sso замість постійних ключів; Docker: "credsStore": "wincred" у config.json; npm: токен з обмеженим строком і правами, краще через змінну середовища лише в CI.' 'AWS: aws configure sso instead of long-lived keys; Docker: "credsStore": "wincred" in config.json; npm: a token limited in time and scope, preferably via an environment variable in CI only.'),
                (T 'Токен, що лежав відкрито, після перенесення перевипустіть: старий міг уже потрапити в чужі руки.' 'Reissue a token that sat in the open after moving it: the old one may already be in the wrong hands.')
            ) }
        }
        @{
            Id = 'ssh-keys'; Title = (T 'Ключі SSH без пароля' 'SSH keys without a passphrase')
            Test = {
                $dir = Join-Path $env:USERPROFILE '.ssh'
                $files = @(Get-ChildItem -LiteralPath $dir -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Extension -notin '.pub', '.old', '.bak' -and $_.Name -notmatch '^(known_hosts|config|authorized_keys)' })
                $files += @(Get-ChildItem -LiteralPath $env:USERPROFILE, (Join-Path $env:USERPROFILE 'Documents') -File -Filter '*.ppk' -ErrorAction SilentlyContinue)
                $plain = @(); $enc = 0
                foreach ($f in $files) {
                    switch (Get-SshKeyState $f.FullName) { 'plain' { $plain += $f.FullName } 'encrypted' { $enc++ } }
                }
                if (-not $plain -and -not $enc) { return Ok (T 'ключів немає' 'no keys') }
                if (-not $plain) { return Ok (T "усі з паролем ($enc)" "all protected ($enc)") }
                Issue low (T "$($plain.Count) без пароля" "$($plain.Count) unprotected") (T 'Приватний ключ без пароля - це готовий доступ до серверів і репозиторіїв: достатньо скопіювати файл. З паролем украдений файл марний, а вводити пароль щоразу не треба - ключ тримає ssh-agent.' 'A private key without a passphrase is ready-made access to servers and repositories: copying the file is enough. With a passphrase the stolen file is useless, and you do not type it every time - ssh-agent holds the key.') $plain
            }
            Explain = (T 'Ключ SSH замінює пароль для входу на сервери й у GitHub/GitLab. Файл приватного ключа лежить у папці .ssh, і викрадачі паролів забирають її цілком.' 'An SSH key replaces the password for signing in to servers and GitHub/GitLab. The private key file sits in the .ssh folder, and password stealers take that folder whole.')
            Pros = @((T 'Вкрадений файл ключа марний без пароля' 'A stolen key file is useless without the passphrase'))
            Cons = @((T 'Пароль треба ввести раз після входу в Windows (далі його тримає ssh-agent)' 'You enter the passphrase once after signing in to Windows (ssh-agent keeps it afterwards)'), (T 'Скрипти, що використовують ключ без нагляду, потребують окремого ключа з обмеженими правами' 'Unattended scripts using the key need a separate key with limited rights'))
            Fix = @{ Steps = @(
                (T 'Додати пароль до наявного ключа: ssh-keygen -p -f <шлях до ключа>' 'Add a passphrase to an existing key: ssh-keygen -p -f <path to key>'),
                (T 'Щоб не вводити його щоразу: увімкніть службу «OpenSSH Authentication Agent» (services.msc → тип запуску «Автоматично») і виконайте ssh-add <шлях до ключа>.' 'To avoid typing it every time: enable the "OpenSSH Authentication Agent" service (services.msc → startup type Automatic) and run ssh-add <path to key>.')
            ) }
        }
        @{
            Id = 'env-secrets'; Title = (T 'Секрети у змінних середовища' 'Secrets in environment variables')
            Test = {
                $names = @()
                $rx = '(?i)(token|secret|api[_-]?key|apikey|passw(or)?d|passwd|_pwd$|private[_-]?key|access[_-]?key|auth[_-]?key|credential)'
                foreach ($src in @{ Key = 'HKCU:\Environment'; Scope = (T 'користувача' 'user') }, @{ Key = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment'; Scope = (T 'системи' 'system') }) {
                    $p = Get-ItemProperty $src.Key -ErrorAction SilentlyContinue
                    if (-not $p) { continue }
                    foreach ($x in $p.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' -and $_.Name -match $rx -and "$($_.Value)".Length -ge 8 }) {
                        # Шлях до файлу з ключем (GOOGLE_APPLICATION_CREDENTIALS=C:\...) - не сам секрет
                        if ("$($x.Value)" -match '^[a-zA-Z]:\\|^%') { continue }
                        $names += "$($x.Name) (" + (T "змінна $($src.Scope)" "$($src.Scope) variable") + ')'
                    }
                }
                if (-not $names) { return Ok (T 'не знайдено' 'none found') }
                Issue low (T "$($names.Count) шт." "$($names.Count)") (T 'Постійну змінну середовища бачить кожна програма, яку ви запускаєте, - включно з інсталяторами, іграми і скриптами встановлення пакетів (npm, pip). Значення не показано у звіті.' 'A persistent environment variable is visible to every program you launch - including installers, games and package install scripts (npm, pip). The values are not shown in the report.') $names
            }
            Explain = (T 'Зберігати ключ API у змінній середовища зручно, але постійна змінна - це секрет, розданий усім програмам одразу. Безпечніше передавати його лише тій програмі, якій він потрібен.' 'Keeping an API key in an environment variable is convenient, but a persistent variable is a secret handed to every program at once. It is safer to pass it only to the program that needs it.')
            Pros = @((T 'Сторонні програми і скрипти встановлення не бачать ваших ключів' 'Third-party programs and install scripts do not see your keys'))
            Cons = @((T 'Ключ доведеться задавати для конкретного проєкту або термінала' 'You will set the key per project or per terminal session'))
            Fix = @{ Open = 'rundll32.exe sysdm.cpl,EditEnvironmentVariables'; Steps = @((T 'Перенесіть ключ у файл .env проєкту (доданий у .gitignore) або в менеджер секретів, видаліть постійну змінну і перевипустіть ключ.' 'Move the key into the project''s .env file (listed in .gitignore) or a secrets manager, delete the persistent variable and reissue the key.')) }
        }
        @{
            Id = 'password-files'; Title = (T 'Файли з паролями на видноті' 'Password files in plain sight')
            Test = {
                $rx = '(?i)(passw|парол|логін[иі]|credentials|секрет|seed[ _-]?phrase|сід[ _-]?фраз|mnemonic|recovery[ _-]?(code|key|phrase)|backup[ _-]?codes?|резервн\S* код|2fa|wallet|гаманець|bitwarden_export|lastpass|1password|keepass.*\.(csv|xml|txt)$|private[ _-]?key)'
                $ext = '.txt', '.csv', '.doc', '.docx', '.xls', '.xlsx', '.rtf', '.md', '.json', '.xml', '.odt', '.ods', '.pdf', '.png', '.jpg', '.jpeg', '.html'
                $roots = @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('MyDocuments'), (Join-Path $env:USERPROFILE 'Downloads'), $env:OneDrive) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Sort-Object -Unique
                $hits = @()
                foreach ($r in $roots) {
                    # Два рівні вглиб: глибше - це вже проєкти й архіви, де назва нічого не означає
                    $level1 = @(Get-ChildItem -LiteralPath $r -Force -ErrorAction SilentlyContinue | Select-Object -First 3000)
                    $files = @($level1 | Where-Object { -not $_.PSIsContainer })
                    foreach ($d in $level1 | Where-Object { $_.PSIsContainer -and -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) } | Select-Object -First 200) {
                        $files += @(Get-ChildItem -LiteralPath $d.FullName -File -Force -ErrorAction SilentlyContinue | Select-Object -First 1000)
                    }
                    $hits += @($files | Where-Object { $_.Extension -in $ext -and $_.BaseName -match $rx -and $_.Length -gt 0 } | ForEach-Object FullName)
                }
                $hits = @($hits | Sort-Object -Unique)
                if (-not $hits) { return Ok (T 'не знайдено' 'none found') }
                Issue medium (T "$($hits.Count) шт." "$($hits.Count)") (T 'Назви цих файлів кажуть, що в них паролі, коди відновлення або експорт із менеджера паролів. Викрадачі шукають саме такі назви на Робочому столі, у Документах і Завантаженнях. Якщо папка синхронізується з хмарою - файл лежить і там.' 'These file names suggest passwords, recovery codes or a password manager export. Stealers search for exactly such names on the Desktop, in Documents and Downloads. If the folder syncs to the cloud, the file is there too.') ($hits | Select-Object -First 40)
            }
            Explain = (T 'Аудит дивиться лише на назви файлів на Робочому столі, у Документах, Завантаженнях і OneDrive (два рівні вглиб); вміст не відкривається. Типова знахідка - «паролі.txt» або експорт паролів браузера, який забули видалити після імпорту.' 'The audit looks only at file names on the Desktop, in Documents, Downloads and OneDrive (two levels deep); contents are not opened. A typical finding is "passwords.txt" or a browser password export left behind after an import.')
            Pros = @((T 'Паролі не лежать там, де їх шукають першими' 'Passwords do not sit where they are searched for first'))
            Cons = @((T 'Хибна тривога, якщо файл лише називається схоже (інструкція «Як змінити пароль»)' 'A false alarm if the file is merely named similarly (a "How to change a password" guide)'))
            Fix = @{ Steps = @((T 'Перенесіть вміст у менеджер паролів (коди відновлення - у нотатки запису), файл видаліть і очистіть Кошик. Якщо файл побував у хмарі - видаліть його і там, разом з історією версій.' 'Move the contents into a password manager (recovery codes go into the entry notes), delete the file and empty the Recycle Bin. If the file was in the cloud, delete it there too, including version history.')) }
        }
    )
}
