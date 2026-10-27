# Цілісність пам'яті (Memory Integrity, HVCI) - перемикач "Безпека Windows → Безпека пристрою → Ізоляція ядра".
@{
    Title       = (T 'Цілісність пам''яті (HVCI) увімкнено' 'Memory integrity (HVCI) on')
    Description = (T 'Захист ядра від шкідливих і вразливих драйверів. Перед увімкненням перевірте несумісні драйвери, після - перезавантаження.' 'Kernel protection against malicious and vulnerable drivers. Check for incompatible drivers before turning it on; restart afterwards.')
    Reboot      = $true
    Items       = @(
        @{ Kind = 'Registry'; Id = 'hvci'; Title = (T 'Цілісність пам''яті (HVCI)' 'Memory integrity (HVCI)')
           Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity'; Name = 'Enabled'; Desired = 1
           Labels = @{ 0 = (T 'вимкнено' 'off'); 1 = (T 'увімкнено' 'on') }
           Hint = (T 'Кожен драйвер перевіряється в ізольованому середовищі перед завантаженням, а код ядра не можна змінити під час роботи. Мінуси: у частині ігор −1…5% FPS; старі драйвери (розгін, RGB, деякі аудіо й VPN) можуть не завантажитися. Відкат повертає попереднє значення.' 'Every driver is checked in an isolated environment before loading, and kernel code cannot be modified at runtime. Cons: −1…5% FPS in some games; old drivers (overclocking, RGB, some audio and VPN) may fail to load. Revert restores the previous value.') }
    )
    Steps       = @(
        @{ Text = (T 'ДО застосування: відкрийте «Ізоляцію ядра» - якщо Windows показує «Несумісні драйвери», спершу оновіть або видаліть програми, яким вони належать.' 'BEFORE applying: open "Core isolation" — if Windows lists "Incompatible drivers", first update or remove the programs they belong to.')
           Open = 'windowsdefender://coreisolation'
           Hint = (T 'Якщо увімкнути HVCI з несумісним драйвером, Windows просто не завантажить цей драйвер: відповідний пристрій або програма перестане працювати.' 'If you turn on HVCI with an incompatible driver, Windows simply will not load that driver: the device or program stops working.') }
        (T 'Після перезавантаження перевірте в DEADPIXEL → «Аудит системи», що цілісність пам''яті працює.' 'After the restart, check in DEADPIXEL → "System audit" that memory integrity is running.')
    )
}
