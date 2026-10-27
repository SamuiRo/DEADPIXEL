# Блок-лист вразливих драйверів Microsoft (захист від атак "принеси свій вразливий драйвер").
@{
    Title       = 'Блок-лист вразливих драйверів увімкнено'
    Description = 'Windows не завантажуватиме драйвери з відомими вразливостями, якими атакують ядро.'
    Reboot      = $true
    Items       = @(
        @{ Kind = 'Registry'; Id = 'blocklist'; Title = 'Блок-лист вразливих драйверів'
           Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Config'; Name = 'VulnerableDriverBlocklistEnable'; Desired = 1
           Labels = @{ 0 = 'вимкнено'; 1 = 'увімкнено' }
           Hint = 'Список веде Microsoft і оновлює разом із Windows. Зрідка блокує старий драйвер легітимної утиліти (розгін, моніторинг) - тоді оновіть утиліту.' }
    )
}
