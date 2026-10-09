# PCIe Link State Power Management. 0 = вимкнено, 1 = помірне, 2 = максимальне енергозбереження.
# Агресивний ASPM - часта причина зависань GPU/NVMe (TDR, зникнення диска) після виходу зі сну.
@{
    Title       = 'PCIe ASPM: помірне енергозбереження (від мережі)'
    Description = 'powercfg SUB_PCIEXPRESS ASPM у поточній схемі живлення'
    Items       = @(
        @{ Kind = 'Power'; Id = 'aspm-ac'; Title = 'PCIe ASPM (від мережі)'
           Sub = 'SUB_PCIEXPRESS'; Setting = 'ASPM'; Power = 'AC'; Desired = 1
           Labels = @{ 0 = 'вимкнено'; 1 = 'помірне'; 2 = 'максимальне' } }
    )
}
