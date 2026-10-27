# ПК видно в домашній мережі і він відповідає на ping.
# Правила файрвола - за Name, а не DisplayName: DisplayName локалізований і на неанглійській Windows не знайдеться.
@{
    Title       = (T 'Домашня мережа: приватний профіль і ping' 'Home network: private profile and ping')
    Description = (T 'Профіль активного підключення і правила "File and Printer Sharing (Echo Request)" у файрволі.' 'The active connection''s profile and the "File and Printer Sharing (Echo Request)" firewall rules.')
    Items       = @(
        @{ Kind = 'Custom'; Id = 'net-category'; Title = (T 'Профіль мережі з інтернетом' 'Profile of the internet connection'); Desired = 'Private'
           Hint = (T 'Public — для кафе й аеропортів: Windows ховає ПК від інших пристроїв мережі. Private — для дому: працюють виявлення мережі і спільний доступ. Змінюється лише підключення, через яке зараз є інтернет.' 'Public is for cafés and airports: Windows hides the PC from other devices. Private is for home: network discovery and sharing work. Only the connection that currently has internet is changed.')
           Get = {
               $p = Get-NetConnectionProfile | Where-Object { $_.IPv4Connectivity -eq 'Internet' } | Select-Object -First 1
               if (-not $p) { throw (T 'немає підключення з доступом до інтернету' 'no connection with internet access') }
               [string]$p.NetworkCategory
           }
           Set = {
               param($value)
               Get-NetConnectionProfile | Where-Object { $_.IPv4Connectivity -eq 'Internet' } | Select-Object -First 1 |
                   Set-NetConnectionProfile -NetworkCategory $value
           } }
        @{ Kind = 'FirewallRule'; Id = 'ping-v4'; Title = (T 'Відповідати на ping (ICMPv4)' 'Reply to ping (ICMPv4)'); Name = 'FPS-ICMP4-ERQ-In'; Desired = 'True'
           Hint = (T 'Вбудоване правило "File and Printer Sharing (Echo Request - ICMPv4-In)". Увага: воно діє одночасно для профілів Private і Public — у публічних мережах ПК теж відповідатиме на ping.' 'The built-in rule "File and Printer Sharing (Echo Request - ICMPv4-In)". Note: it applies to both Private and Public profiles — the PC will reply to ping on public networks too.') }
        @{ Kind = 'FirewallRule'; Id = 'ping-v6'; Title = (T 'Відповідати на ping (ICMPv6)' 'Reply to ping (ICMPv6)'); Name = 'FPS-ICMP6-ERQ-In'; Desired = 'True'
           Hint = (T 'Те саме для IPv6. Потрібне, якщо роутер роздає IPv6-адреси і ви пінгуєте за ними або за іменем ПК.' 'The same for IPv6. Needed if the router hands out IPv6 addresses and you ping them or the PC name.') }
    )
    Steps       = @(
        @{ Text = (T 'Увімкніть "Виявлення мережі" і "Спільний доступ до файлів і принтерів" для приватних мереж (додаткові параметри спільного доступу).' 'Turn on "Network discovery" and "File and printer sharing" for private networks (advanced sharing settings).'); Open = 'control.exe /name Microsoft.NetworkAndSharingCenter /page Advanced' }
        @{ Text = (T 'Перевірте з іншого пристрою: ping <IP цього ПК>. IP видно у властивостях підключення.' 'Check from another device: ping <this PC''s IP>. The IP is in the connection properties.'); Open = 'ms-settings:network-status' }
    )

    # Сценарії - покрокові інструкції у вкладках GUI
    Tabs        = @(
        @{ Id = 'ping-on'; Title = (T 'Увімкнути ping' 'Turn ping on')
           Description = (T 'Покроково: подивитися, що вже дозволено у файрволі, увімкнути відповідь на ping і перевірити з іншого пристрою.' 'Step by step: see what the firewall already allows, turn on ping replies and check from another device.')
           Steps = @(
               @{ Text = (T 'Подивіться, які правила "Спільний доступ до файлів і принтерів" уже ввімкнено.' 'See which "File and Printer Sharing" rules are already on.')
                  Hint = (T 'Група задана ідентифікатором @FirewallAPI.dll,-28502, а не назвою: назва групи перекладена, ідентифікатор — ні.' 'The group is given by the id @FirewallAPI.dll,-28502 rather than its name: the name is translated, the id is not.')
                  Run = "Get-NetFirewallRule -Group '@FirewallAPI.dll,-28502' | Where-Object Enabled -eq True | Format-Table DisplayName, Profile, Direction, Action -AutoSize" }
               @{ Text = (T 'Увімкніть правило відповіді на ping (ICMPv4).' 'Turn on the ping reply rule (ICMPv4).'); Admin = $true
                  Hint = (T 'Правило FPS-ICMP4-ERQ-In діє для профілів Private і Public. Щоб вимкнути — вкладка "Вимкнути ping".' 'The FPS-ICMP4-ERQ-In rule applies to Private and Public profiles. To turn it off — the "Turn ping off" tab.')
                  Run = "Enable-NetFirewallRule -Name 'FPS-ICMP4-ERQ-In'; Get-NetFirewallRule -Name 'FPS-ICMP4-ERQ-In' | Format-List DisplayName, Enabled, Profile"
                  Expect = 'Enabled\s*:\s*True' }
               @{ Text = (T 'Правила немає — знайдіть схожі (можливо, його перейменовано або видалено).' 'The rule is missing — find similar ones (it may have been renamed or deleted).'); If = 'fail'
                  Run = "Get-NetFirewallRule | Where-Object { `$_.Name -like '*ICMP4*' -or `$_.DisplayName -like '*Echo Request*' } | Format-Table Name, DisplayName, Enabled, Profile -AutoSize" }
               @{ Text = (T 'Дізнайтеся IP-адресу цього ПК.' 'Find out this PC''s IP address.')
                  Run = "Get-NetIPAddress -AddressFamily IPv4 | Where-Object { `$_.PrefixOrigin -ne 'WellKnown' } | Format-Table InterfaceAlias, IPAddress -AutoSize" }
               @{ Text = (T 'На іншому пристрої виконайте ping <IP цього ПК> — мають бути відповіді (Reply / Відповідь від…).' 'On another device run ping <this PC''s IP> — there should be replies (Reply from…).')
                  Hint = (T 'Якщо відповідей немає: перевірте, що обидва пристрої в одній мережі і що профіль мережі — Private (вкладка "Рекомендовані").' 'If there are no replies: check that both devices are on the same network and the network profile is Private (the "Recommended" tab).') }
           ) }
        @{ Id = 'ping-off'; Title = (T 'Вимкнути ping' 'Turn ping off')
           Description = (T 'Повернути як було за замовчуванням: ПК не відповідає на ping.' 'Back to the default: the PC does not reply to ping.')
           Steps = @(
               @{ Text = (T 'Вимкніть правила відповіді на ping (IPv4 і IPv6).' 'Turn off the ping reply rules (IPv4 and IPv6).'); Admin = $true
                  Run = "Disable-NetFirewallRule -Name 'FPS-ICMP4-ERQ-In', 'FPS-ICMP6-ERQ-In'; Get-NetFirewallRule -Name 'FPS-ICMP4-ERQ-In', 'FPS-ICMP6-ERQ-In' | Format-Table DisplayName, Enabled -AutoSize" }
           ) }
        @{ Id = 'check'; Title = (T 'Перевірити зв''язок' 'Check connectivity')
           Description = (T 'Перевірка зв''язку з іншим пристроєм у мережі: ping і доступ до спільних папок.' 'Check connectivity to another device on the network: ping and shared folder access.')
           Params = @(
               @{ Name = 'IP'; Title = (T 'IP або ім''я пристрою' 'Device IP or name'); Default = '192.168.1.1'; Pattern = '[\w.\-:]+'
                  Hint = (T 'Наприклад, роутер (192.168.1.1 / 192.168.0.1) або інший ПК.' 'For example, the router (192.168.1.1 / 192.168.0.1) or another PC.') }
           )
           Steps = @(
               @{ Text = (T 'Пропінгуйте {IP}.' 'Ping {IP}.'); Run = 'ping -n 4 {IP}'; Expect = 'TTL='
                  Hint = (T 'Успіх — якщо у виводі є TTL=: це означає, що прийшла відповідь. "Request timed out" — пристрій не відповідає (вимкнений або блокує ping файрвол).' 'Success if the output has TTL=: a reply arrived. "Request timed out" — the device does not respond (it is off or its firewall blocks ping).') }
               @{ Text = (T 'Перевірте доступ до спільних папок {IP} (SMB, порт 445).' 'Check access to shared folders on {IP} (SMB, port 445).'); If = 'ok'
                  Run = 'Test-NetConnection -ComputerName {IP} -Port 445 -WarningAction SilentlyContinue | Format-List ComputerName, RemoteAddress, TcpTestSucceeded'
                  Expect = 'TcpTestSucceeded\s*:\s*True' }
           ) }
    )
}
