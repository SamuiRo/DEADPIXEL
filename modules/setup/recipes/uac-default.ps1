# Контроль облікових записів (UAC) на типовому рівні Windows.
@{
    Title       = 'UAC на типовому рівні'
    Description = 'Програми отримують права адміністратора лише після вашого підтвердження на захищеному робочому столі.'
    Reboot      = $true
    Items       = @(
        @{ Kind = 'Registry'; Id = 'lua'; Title = 'UAC увімкнено (EnableLUA)'
           Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'; Name = 'EnableLUA'; Desired = 1
           Labels = @{ 0 = 'вимкнено'; 1 = 'увімкнено' }
           Hint = 'Вимкнений UAC дає кожній програмі повні права адміністратора. Зміна діє після перезавантаження.' }
        @{ Kind = 'Registry'; Id = 'consent-admin'; Title = 'Запит для адміністраторів'
           Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'; Name = 'ConsentPromptBehaviorAdmin'; Desired = 5
           Labels = @{ 0 = 'без запиту'; 1 = 'пароль на захищеному столі'; 2 = 'завжди питати'; 5 = 'питати для програм (типово)' }
           Hint = 'Типовий рівень: питати, коли програма (а не ви в налаштуваннях Windows) хоче змінити систему.' }
        @{ Kind = 'Registry'; Id = 'secure-desktop'; Title = 'Захищений робочий стіл для запиту'
           Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'; Name = 'PromptOnSecureDesktop'; Desired = 1
           Labels = @{ 0 = 'ні'; 1 = 'так' }
           Hint = 'Екран затемнюється, і інші програми не можуть «натиснути» кнопку запиту за вас.' }
    )
}
