# Контроль облікових записів (UAC) на типовому рівні Windows.
@{
    Title       = (T 'UAC на типовому рівні' 'UAC at the default level')
    Description = (T 'Програми отримують права адміністратора лише після вашого підтвердження на захищеному робочому столі.' 'Programs get administrator rights only after you confirm on the secure desktop.')
    Reboot      = $true
    Items       = @(
        @{ Kind = 'Registry'; Id = 'lua'; Title = (T 'UAC увімкнено (EnableLUA)' 'UAC on (EnableLUA)')
           Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'; Name = 'EnableLUA'; Desired = 1
           Labels = @{ 0 = (T 'вимкнено' 'off'); 1 = (T 'увімкнено' 'on') }
           Hint = (T 'Вимкнений UAC дає кожній програмі повні права адміністратора. Зміна діє після перезавантаження.' 'With UAC off, every program gets full administrator rights. Takes effect after a restart.') }
        @{ Kind = 'Registry'; Id = 'consent-admin'; Title = (T 'Запит для адміністраторів' 'Prompt for administrators')
           Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'; Name = 'ConsentPromptBehaviorAdmin'; Desired = 5
           Labels = @{ 0 = (T 'без запиту' 'no prompt'); 1 = (T 'пароль на захищеному столі' 'password on secure desktop'); 2 = (T 'завжди питати' 'always prompt'); 5 = (T 'питати для програм (типово)' 'prompt for programs (default)') }
           Hint = (T 'Типовий рівень: питати, коли програма (а не ви в налаштуваннях Windows) хоче змінити систему.' 'The default level: prompt when a program (not you in Windows settings) wants to change the system.') }
        @{ Kind = 'Registry'; Id = 'secure-desktop'; Title = (T 'Захищений робочий стіл для запиту' 'Secure desktop for the prompt')
           Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'; Name = 'PromptOnSecureDesktop'; Desired = 1
           Labels = @{ 0 = (T 'ні' 'no'); 1 = (T 'так' 'yes') }
           Hint = (T 'Екран затемнюється, і інші програми не можуть «натиснути» кнопку запиту за вас.' 'The screen dims and other programs cannot "click" the prompt for you.') }
    )
}
