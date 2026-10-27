# Віддалений робочий стіл: вимагати перевірку пароля (NLA) ще до показу екрана входу.
@{
    Title       = (T 'Віддалений робочий стіл лише з NLA' 'Remote Desktop with NLA only')
    Description = (T 'Якщо RDP увімкнено, до екрана входу пускає лише після перевірки пароля - так не працюють атаки на сам екран входу (BlueKeep) і масовий підбір паролів.' 'If RDP is on, the sign-in screen appears only after the password is checked — this stops attacks on the sign-in screen itself (BlueKeep) and mass password guessing.')
    Items       = @(
        @{ Kind = 'Registry'; Id = 'nla'; Title = (T 'Перевірка на рівні мережі (NLA)' 'Network Level Authentication (NLA)')
           Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp'; Name = 'UserAuthentication'; Desired = 1
           Labels = @{ 0 = (T 'вимкнено' 'off'); 1 = (T 'увімкнено' 'on') }
           Hint = (T 'Мінус: не підключаться дуже старі клієнти RDP (Windows XP, старі тонкі клієнти). Сучасним клієнтам Windows, macOS, Android, iOS це не заважає.' 'Con: very old RDP clients (Windows XP, old thin clients) cannot connect. Modern Windows, macOS, Android and iOS clients are unaffected.') }
    )
    Steps       = @(
        @{ Text = (T 'Якщо ви не підключаєтеся до цього ПК віддалено - просто вимкніть «Віддалений робочий стіл».' 'If you do not connect to this PC remotely, simply turn off "Remote Desktop".'); Open = 'ms-settings:remotedesktop' }
        (T 'Ніколи не відкривайте порт RDP (3389) на роутері в інтернет: для доступу ззовні використовуйте VPN.' 'Never open the RDP port (3389) on the router to the internet: use a VPN for outside access.')
    )
}
