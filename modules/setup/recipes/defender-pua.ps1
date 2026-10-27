# Microsoft Defender: блокування потенційно небажаних програм (PUA).
@{
    Title       = 'Defender блокує небажані програми (PUA)'
    Description = 'Рекламні модулі, «прискорювачі» і приховані майнери з безкоштовних інсталяторів блокуються, а не лише записуються в журнал.'
    Items       = @(
        @{ Kind = 'Custom'; Id = 'pua'; Title = 'Захист від PUA'; Desired = 1
           Get = { [int](Get-MpPreference).PUAProtection }
           Set = { param($value) Set-MpPreference -PUAProtection $value }
           Labels = @{ 0 = 'вимкнено'; 1 = 'блокувати'; 2 = 'лише аудит' }
           Hint = 'Зрідка блокує легітимну утиліту (генератор ключів, завантажувач торентів) - її можна дозволити в «Безпека Windows» → «Журнал захисту».' }
    )
}
