# PCIe Link State Power Management. 0 = вимкнено, 1 = помірне, 2 = максимальне енергозбереження.
@{
    Title       = 'PCIe ASPM вимкнено (від мережі)'
    Description = 'Енергозбереження лінії PCIe у поточній схемі живлення. Вимкнення прибирає зависання GPU/NVMe на виході з low-power станів.'
    Items       = @(
        @{ Kind = 'Power'; Id = 'aspm-ac'; Title = 'PCIe ASPM (від мережі)'
           Sub = 'SUB_PCIEXPRESS'; Setting = 'ASPM'; Power = 'AC'; Desired = 0
           Labels = @{ 0 = 'вимкнено'; 1 = 'помірне'; 2 = 'максимальне' }
           Hint = 'Коли лінія PCIe "засинає", відеокарта або NVMe-диск інколи не прокидаються вчасно — Windows бачить це як зависання драйвера (TDR, подія 4101) або зникнення диска. Вимкнення ASPM коштує кілька ватів у простої і прибирає цей клас збоїв.' }
    )
    Steps       = @(
        'Якщо в BIOS/UEFI є "Native ASPM" або "PCIe ASPM Support" — вимкніть і там: коли BIOS не передав керування ASPM системі, налаштування Windows на нього не впливає.'
        'Після зміни поспостерігайте за подіями GPU у DEADPIXEL (вкладка "Події") кілька днів.'
    )

    Tabs        = @(
        @{ Id = 'bios'; Title = 'ASPM у BIOS'
           Description = 'Сценарій із перезавантаженням: вимкнути ASPM на рівні BIOS/UEFI. Прогрес зберігається — після перезавантаження вікно відкриється на потрібному кроці.'
           Steps = @(
               @{ Text = 'Дізнайтеся модель материнської плати і версію BIOS — за ними шукайте пункт меню в інструкції.'
                  Run = 'Get-CimInstance Win32_BaseBoard | Format-List Manufacturer, Product; Get-CimInstance Win32_BIOS | Format-List SMBIOSBIOSVersion, ReleaseDate' }
               @{ Text = 'Знайдіть в інструкції до плати, де налаштовується ASPM.'
                  Hint = 'Типові місця: Advanced → PCI Subsystem Settings / Onboard Devices → Native ASPM, PCIe ASPM Support, PEG ASPM, PCH ASPM. Назви відрізняються у виробників.' }
               @{ Text = 'Перезавантажте ПК одразу в BIOS/UEFI.'; Reboot = 'firmware'
                  Hint = 'Кнопка виконує shutdown /r /fw. Якщо плата не підтримує вхід у UEFI з Windows — перезавантажте звичайно і тисніть Del або F2 під час старту.' }
               'У BIOS вимкніть Native ASPM (або PEG / PCH ASPM = Disabled), збережіть і вийдіть (зазвичай F10).'
               @{ Text = 'Переконайтеся, що у Windows ASPM також вимкнено (від мережі).'
                  Hint = 'Перевірка лише читає налаштування. Змінити його — вкладка "Рекомендовані".'
                  Run = "`$h = [regex]::Matches((powercfg /query SCHEME_CURRENT SUB_PCIEXPRESS ASPM) -join ' ', '0x[0-9a-fA-F]{8}'); 'ASPM від мережі: ' + [Convert]::ToInt32(`$h[`$h.Count - 2].Value, 16)"
                  Expect = 'ASPM від мережі: 0\b' }
           ) }
    )
}
