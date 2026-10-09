# ПК видно в домашній мережі і він відповідає на ping.
# Правила файрвола - за Name, а не DisplayName: DisplayName локалізований і на неанглійській Windows не знайдеться.
# Увага: FPS-ICMP*-ERQ-In діють для профілів Private і Public одночасно.
@{
    Title       = 'Домашня мережа: приватний профіль, відповідь на ping'
    Description = 'Профіль активного підключення + правила "File and Printer Sharing (Echo Request)"'
    Items       = @(
        @{ Kind = 'Custom'; Id = 'net-category'; Title = 'Профіль мережі з інтернетом'; Desired = 'Private'
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
        @{ Kind = 'FirewallRule'; Id = 'ping-v4'; Title = 'Відповідати на ping (ICMPv4)'; Name = 'FPS-ICMP4-ERQ-In'; Desired = 'True' }
        @{ Kind = 'FirewallRule'; Id = 'ping-v6'; Title = 'Відповідати на ping (ICMPv6)'; Name = 'FPS-ICMP6-ERQ-In'; Desired = 'True' }
    )
}
