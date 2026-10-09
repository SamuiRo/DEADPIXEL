# ПК видно в домашній мережі і він відповідає на ping.
# Правила файрвола - за Name, а не DisplayName: DisplayName локалізований і на неанглійській Windows не знайдеться.
@{
    Title       = 'Домашня мережа: приватний профіль і ping'
    Description = 'Профіль активного підключення і правила "File and Printer Sharing (Echo Request)" у файрволі.'
    Items       = @(
        @{ Kind = 'Custom'; Id = 'net-category'; Title = 'Профіль мережі з інтернетом'; Desired = 'Private'
           Hint = 'Public — для кафе й аеропортів: Windows ховає ПК від інших пристроїв мережі. Private — для дому: працюють виявлення мережі і спільний доступ. Змінюється лише підключення, через яке зараз є інтернет.'
           Get = {
               $p = Get-NetConnectionProfile | Where-Object { $_.IPv4Connectivity -eq 'Internet' } | Select-Object -First 1
               if (-not $p) { throw 'немає підключення з доступом до інтернету' }
               [string]$p.NetworkCategory
           }
           Set = {
               param($value)
               Get-NetConnectionProfile | Where-Object { $_.IPv4Connectivity -eq 'Internet' } | Select-Object -First 1 |
                   Set-NetConnectionProfile -NetworkCategory $value
           } }
        @{ Kind = 'FirewallRule'; Id = 'ping-v4'; Title = 'Відповідати на ping (ICMPv4)'; Name = 'FPS-ICMP4-ERQ-In'; Desired = 'True'
           Hint = 'Вбудоване правило "File and Printer Sharing (Echo Request - ICMPv4-In)". Увага: воно діє одночасно для профілів Private і Public — у публічних мережах ПК теж відповідатиме на ping.' }
        @{ Kind = 'FirewallRule'; Id = 'ping-v6'; Title = 'Відповідати на ping (ICMPv6)'; Name = 'FPS-ICMP6-ERQ-In'; Desired = 'True'
           Hint = 'Те саме для IPv6. Потрібне, якщо роутер роздає IPv6-адреси і ви пінгуєте за ними або за іменем ПК.' }
    )
    Steps       = @(
        @{ Text = 'Увімкніть "Виявлення мережі" і "Спільний доступ до файлів і принтерів" для приватних мереж (додаткові параметри спільного доступу).'; Open = 'control.exe /name Microsoft.NetworkAndSharingCenter /page Advanced' }
        @{ Text = 'Перевірте з іншого пристрою: ping <IP цього ПК>. IP видно у властивостях підключення.'; Open = 'ms-settings:network-status' }
    )

    # Сценарії - покрокові інструкції у вкладках GUI
    Tabs        = @(
        @{ Id = 'ping-on'; Title = 'Увімкнути ping'
           Description = 'Покроково: подивитися, що вже дозволено у файрволі, увімкнути відповідь на ping і перевірити з іншого пристрою.'
           Steps = @(
               @{ Text = 'Подивіться, які правила "Спільний доступ до файлів і принтерів" уже ввімкнено.'
                  Hint = 'Група задана ідентифікатором @FirewallAPI.dll,-28502, а не назвою: назва групи перекладена, ідентифікатор — ні.'
                  Run = "Get-NetFirewallRule -Group '@FirewallAPI.dll,-28502' | Where-Object Enabled -eq True | Format-Table DisplayName, Profile, Direction, Action -AutoSize" }
               @{ Text = 'Увімкніть правило відповіді на ping (ICMPv4).'; Admin = $true
                  Hint = 'Правило FPS-ICMP4-ERQ-In діє для профілів Private і Public. Щоб вимкнути — вкладка "Вимкнути ping".'
                  Run = "Enable-NetFirewallRule -Name 'FPS-ICMP4-ERQ-In'; Get-NetFirewallRule -Name 'FPS-ICMP4-ERQ-In' | Format-List DisplayName, Enabled, Profile"
                  Expect = 'Enabled\s*:\s*True' }
               @{ Text = 'Правила немає — знайдіть схожі (можливо, його перейменовано або видалено).'; If = 'fail'
                  Run = "Get-NetFirewallRule | Where-Object { `$_.Name -like '*ICMP4*' -or `$_.DisplayName -like '*Echo Request*' } | Format-Table Name, DisplayName, Enabled, Profile -AutoSize" }
               @{ Text = 'Дізнайтеся IP-адресу цього ПК.'
                  Run = "Get-NetIPAddress -AddressFamily IPv4 | Where-Object { `$_.PrefixOrigin -ne 'WellKnown' } | Format-Table InterfaceAlias, IPAddress -AutoSize" }
               @{ Text = 'На іншому пристрої виконайте ping <IP цього ПК> — мають бути відповіді (Reply / Відповідь від…).'
                  Hint = 'Якщо відповідей немає: перевірте, що обидва пристрої в одній мережі і що профіль мережі — Private (вкладка "Рекомендовані").' }
           ) }
        @{ Id = 'ping-off'; Title = 'Вимкнути ping'
           Description = 'Повернути як було за замовчуванням: ПК не відповідає на ping.'
           Steps = @(
               @{ Text = 'Вимкніть правила відповіді на ping (IPv4 і IPv6).'; Admin = $true
                  Run = "Disable-NetFirewallRule -Name 'FPS-ICMP4-ERQ-In', 'FPS-ICMP6-ERQ-In'; Get-NetFirewallRule -Name 'FPS-ICMP4-ERQ-In', 'FPS-ICMP6-ERQ-In' | Format-Table DisplayName, Enabled -AutoSize" }
           ) }
        @{ Id = 'check'; Title = 'Перевірити зв''язок'
           Description = 'Перевірка зв''язку з іншим пристроєм у мережі: ping і доступ до спільних папок.'
           Params = @(
               @{ Name = 'IP'; Title = 'IP або ім''я пристрою'; Default = '192.168.1.1'; Pattern = '[\w.\-:]+'
                  Hint = 'Наприклад, роутер (192.168.1.1 / 192.168.0.1) або інший ПК.' }
           )
           Steps = @(
               @{ Text = 'Пропінгуйте {IP}.'; Run = 'ping -n 4 {IP}'; Expect = 'TTL='
                  Hint = 'Успіх — якщо у виводі є TTL=: це означає, що прийшла відповідь. "Request timed out" — пристрій не відповідає (вимкнений або блокує ping файрвол).' }
               @{ Text = 'Перевірте доступ до спільних папок {IP} (SMB, порт 445).'; If = 'ok'
                  Run = 'Test-NetConnection -ComputerName {IP} -Port 445 -WarningAction SilentlyContinue | Format-List ComputerName, RemoteAddress, TcpTestSucceeded'
                  Expect = 'TcpTestSucceeded\s*:\s*True' }
           ) }
    )
}
