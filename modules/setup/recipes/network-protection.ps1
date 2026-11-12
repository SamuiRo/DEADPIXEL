# Microsoft Defender: мережевий захист - блокування шкідливих і фішингових адрес для всіх програм, а не лише Edge.
@{
    Title       = (T 'Defender: мережевий захист' 'Defender: network protection')
    Description = (T 'З''єднання будь-якої програми (браузера, лаунчера, скрипта) з адресами, які Microsoft знає як шкідливі, блокуються.' 'Connections from any program (a browser, launcher or script) to addresses Microsoft knows to be malicious are blocked.')
    Items       = @(
        @{ Kind = 'Custom'; Id = 'network-protection'; Title = (T 'Мережевий захист' 'Network protection'); Desired = 1
           Get = { [int](Get-MpPreference).EnableNetworkProtection }
           Set = { param($value) Set-MpPreference -EnableNetworkProtection ([int]$value) }
           Labels = @{ 0 = (T 'вимкнено' 'off'); 1 = (T 'блокувати' 'block'); 2 = (T 'лише аудит' 'audit only') }
           Hint = (T 'Працює лише з Microsoft Defender. Якщо легітимний сайт перестав відкриватися - причину видно в «Безпека Windows» → «Журнал захисту».' 'Works only with Microsoft Defender. If a legitimate site stops opening, the reason shows in Windows Security → Protection history.') }
    )
}
