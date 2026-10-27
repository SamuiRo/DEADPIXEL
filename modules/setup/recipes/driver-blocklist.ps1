# Блок-лист вразливих драйверів Microsoft (захист від атак "принеси свій вразливий драйвер").
@{
    Title       = (T 'Блок-лист вразливих драйверів увімкнено' 'Vulnerable driver blocklist on')
    Description = (T 'Windows не завантажуватиме драйвери з відомими вразливостями, якими атакують ядро.' 'Windows will not load drivers with known vulnerabilities that are used to attack the kernel.')
    Reboot      = $true
    Items       = @(
        @{ Kind = 'Registry'; Id = 'blocklist'; Title = (T 'Блок-лист вразливих драйверів' 'Vulnerable driver blocklist')
           Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Config'; Name = 'VulnerableDriverBlocklistEnable'; Desired = 1
           Labels = @{ 0 = (T 'вимкнено' 'off'); 1 = (T 'увімкнено' 'on') }
           Hint = (T 'Список веде Microsoft і оновлює разом із Windows. Зрідка блокує старий драйвер легітимної утиліти (розгін, моніторинг) - тоді оновіть утиліту.' 'Microsoft maintains the list and updates it with Windows. It occasionally blocks an old driver of a legitimate utility (overclocking, monitoring) — then update the utility.') }
    )
}
