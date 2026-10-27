# Захист LSA (RunAsPPL): у процес входу можуть заходити лише підписані Microsoft компоненти.
@{
    Title       = (T 'Захист LSA увімкнено' 'LSA protection on')
    Description = (T 'Процес входу в систему працює як захищений - паролі й токени не прочитати з його пам''яті.' 'The sign-in process runs protected — passwords and tokens cannot be read from its memory.')
    Reboot      = $true
    Items       = @(
        @{ Kind = 'Registry'; Id = 'runasppl'; Title = (T 'Захист LSA (RunAsPPL)' 'LSA protection (RunAsPPL)')
           Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa'; Name = 'RunAsPPL'; Desired = 2
           Labels = @{ 0 = (T 'вимкнено' 'off'); 1 = (T 'увімкнено з UEFI-блокуванням' 'on with UEFI lock'); 2 = (T 'увімкнено' 'on') }
           Hint = (T 'Значення 2 - увімкнено без блокування в UEFI, тож звичайний відкат його вимикає (1 - з блокуванням, вимкнення потребує окремої процедури, тому тут не використовується). Мінус: старі плагіни входу, смарт-карт або менеджерів паролів, що вбудовуються в LSA, перестануть завантажуватися.' 'Value 2 means on without a UEFI lock, so a normal revert turns it off (1 is with a lock, which needs a separate procedure to undo, so it is not used here). Con: old sign-in, smart card or password manager plug-ins that load into LSA stop loading.') }
    )
    Steps       = @((T 'Якщо після перезавантаження перестав працювати вхід через сторонню програму (смарт-карта, VPN, менеджер паролів) - натисніть «Відкотити».' 'If signing in through a third-party program (smart card, VPN, password manager) stops working after the restart, click "Revert".'))
}
