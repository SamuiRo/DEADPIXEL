# Microsoft Defender: блокування потенційно небажаних програм (PUA).
@{
    Title       = (T 'Defender блокує небажані програми (PUA)' 'Defender blocks unwanted apps (PUA)')
    Description = (T 'Рекламні модулі, «прискорювачі» і приховані майнери з безкоштовних інсталяторів блокуються, а не лише записуються в журнал.' 'Adware, "speed-up" tools and hidden miners from free installers are blocked, not just logged.')
    Items       = @(
        @{ Kind = 'Custom'; Id = 'pua'; Title = (T 'Захист від PUA' 'PUA protection'); Desired = 1
           Get = { [int](Get-MpPreference).PUAProtection }
           Set = { param($value) Set-MpPreference -PUAProtection $value }
           Labels = @{ 0 = (T 'вимкнено' 'off'); 1 = (T 'блокувати' 'block'); 2 = (T 'лише аудит' 'audit only') }
           Hint = (T 'Зрідка блокує легітимну утиліту (генератор ключів, завантажувач торентів) - її можна дозволити в «Безпека Windows» → «Журнал захисту».' 'It occasionally blocks a legitimate utility (key generator, torrent client) — you can allow it in Windows Security → Protection history.') }
    )
}
