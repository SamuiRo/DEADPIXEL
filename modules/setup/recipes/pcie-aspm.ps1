# PCIe Link State Power Management. 0 = вимкнено, 1 = помірне, 2 = максимальне енергозбереження.
@{
    Title       = (T 'PCIe ASPM вимкнено (від мережі)' 'PCIe ASPM off (on AC)')
    Description = (T 'Енергозбереження лінії PCIe у поточній схемі живлення. Вимкнення прибирає зависання GPU/NVMe на виході з low-power станів.' 'PCIe link power saving in the current power plan. Turning it off removes GPU/NVMe hangs when leaving low-power states.')
    Items       = @(
        @{ Kind = 'Power'; Id = 'aspm-ac'; Title = (T 'PCIe ASPM (від мережі)' 'PCIe ASPM (on AC)')
           Sub = 'SUB_PCIEXPRESS'; Setting = 'ASPM'; Power = 'AC'; Desired = 0
           Labels = @{ 0 = (T 'вимкнено' 'off'); 1 = (T 'помірне' 'moderate'); 2 = (T 'максимальне' 'maximum') }
           Hint = (T 'Коли лінія PCIe "засинає", відеокарта або NVMe-диск інколи не прокидаються вчасно — Windows бачить це як зависання драйвера (TDR, подія 4101) або зникнення диска. Вимкнення ASPM коштує кілька ватів у простої і прибирає цей клас збоїв.' 'When the PCIe link "sleeps", the graphics card or an NVMe disk sometimes does not wake in time — Windows sees it as a driver hang (TDR, event 4101) or a vanished disk. Turning ASPM off costs a few watts at idle and removes this class of failures.') }
    )
    Steps       = @(
        (T 'Якщо в BIOS/UEFI є "Native ASPM" або "PCIe ASPM Support" — вимкніть і там: коли BIOS не передав керування ASPM системі, налаштування Windows на нього не впливає.' 'If the BIOS/UEFI has "Native ASPM" or "PCIe ASPM Support", turn it off there too: when the BIOS does not hand ASPM to the OS, the Windows setting has no effect.')
        (T 'Після зміни поспостерігайте за подіями GPU у DEADPIXEL (вкладка "Події") кілька днів.' 'After the change, watch GPU events in DEADPIXEL (the "Events" tab) for a few days.')
    )

    Tabs        = @(
        @{ Id = 'bios'; Title = (T 'ASPM у BIOS' 'ASPM in BIOS')
           Description = (T 'Сценарій із перезавантаженням: вимкнути ASPM на рівні BIOS/UEFI. Прогрес зберігається — після перезавантаження вікно відкриється на потрібному кроці.' 'A scenario with a restart: turn ASPM off at the BIOS/UEFI level. Progress is saved — after the restart the window opens at the right step.')
           Steps = @(
               @{ Text = (T 'Дізнайтеся модель материнської плати і версію BIOS — за ними шукайте пункт меню в інструкції.' 'Find the motherboard model and BIOS version — use them to find the menu item in the manual.')
                  Run = 'Get-CimInstance Win32_BaseBoard | Format-List Manufacturer, Product; Get-CimInstance Win32_BIOS | Format-List SMBIOSBIOSVersion, ReleaseDate' }
               @{ Text = (T 'Знайдіть в інструкції до плати, де налаштовується ASPM.' 'Find where ASPM is configured in the board manual.')
                  Hint = (T 'Типові місця: Advanced → PCI Subsystem Settings / Onboard Devices → Native ASPM, PCIe ASPM Support, PEG ASPM, PCH ASPM. Назви відрізняються у виробників.' 'Typical places: Advanced → PCI Subsystem Settings / Onboard Devices → Native ASPM, PCIe ASPM Support, PEG ASPM, PCH ASPM. Names differ between vendors.') }
               @{ Text = (T 'Перезавантажте ПК одразу в BIOS/UEFI.' 'Restart the PC straight into BIOS/UEFI.'); Reboot = 'firmware'
                  Hint = (T 'Кнопка виконує shutdown /r /fw. Якщо плата не підтримує вхід у UEFI з Windows — перезавантажте звичайно і тисніть Del або F2 під час старту.' 'The button runs shutdown /r /fw. If the board cannot enter UEFI from Windows, restart normally and press Del or F2 during boot.') }
               (T 'У BIOS вимкніть Native ASPM (або PEG / PCH ASPM = Disabled), збережіть і вийдіть (зазвичай F10).' 'In BIOS turn off Native ASPM (or PEG / PCH ASPM = Disabled), save and exit (usually F10).')
               @{ Text = (T 'Переконайтеся, що у Windows ASPM також вимкнено (від мережі).' 'Make sure ASPM is also off in Windows (on AC).')
                  Hint = (T 'Перевірка лише читає налаштування. Змінити його — вкладка "Рекомендовані".' 'The check only reads the setting. To change it — the "Recommended" tab.')
                  Run = "`$h = [regex]::Matches((powercfg /query SCHEME_CURRENT SUB_PCIEXPRESS ASPM) -join ' ', '0x[0-9a-fA-F]{8}'); 'ASPM AC: ' + [Convert]::ToInt32(`$h[`$h.Count - 2].Value, 16)"
                  Expect = 'ASPM AC: 0\b' }
           ) }
    )
}
