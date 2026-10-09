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
        @{ Text = 'Увімкніть "Виявлення мережі" і "Спільний доступ до файлів і принтерів" для приватних мереж (додаткові параметри спільного доступу).'; Run = 'control.exe /name Microsoft.NetworkAndSharingCenter /page Advanced' }
        @{ Text = 'Перевірте з іншого пристрою: ping <IP цього ПК>. IP видно у властивостях підключення.'; Run = 'ms-settings:network-status' }
    )
}
