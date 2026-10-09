# Вимикає енергозбереження дисків і USB від мережі: диски не "засинають" і не ловлять зависання
# на виході з low-power станів (такі зависання ловить детектор на вкладці "Диски").
@{
    Title       = 'Диски без енергозбереження (від мережі)'
    Description = 'AHCI HIPM/DIPM, вимкнення дисків і USB selective suspend у поточній схемі живлення.'
    Items       = @(
        @{ Kind = 'Power'; Id = 'ahci-lpm-ac'; Title = 'AHCI Link Power Management'
           Sub = 'SUB_DISK'; Setting = '0b2d69d7-a2a1-449c-9680-f91c70521c60'; Power = 'AC'; Desired = 0
           Labels = @{ 0 = 'Active'; 1 = 'HIPM'; 2 = 'HIPM+DIPM'; 3 = 'DIPM'; 4 = 'Lowest' }
           Hint = 'Енергозбереження лінії SATA. У станах HIPM/DIPM диск відповідає з затримкою, а деякі SSD і контролери зависають на кілька секунд — у журналі це події disk 129/153. Active = лінія завжди активна.' }
        @{ Kind = 'Power'; Id = 'disk-idle-ac'; Title = 'Вимикати диск через, с (0 = ніколи)'
           Sub = 'SUB_DISK'; Setting = 'DISKIDLE'; Power = 'AC'; Desired = 0
           Hint = 'Через скільки секунд простою Windows зупиняє диск. HDD потім розкручується 5–10 с, і програми в цей час "висять". 0 = ніколи не зупиняти.' }
        @{ Kind = 'Power'; Id = 'usb-suspend-ac'; Title = 'USB selective suspend'
           Sub = '2a737441-1930-4402-8d77-b2bebba308a3'; Setting = '48e6b7a6-50f5-4782-a5d4-53bb8f07e226'; Power = 'AC'; Desired = 0
           Labels = @{ 0 = 'вимкнено'; 1 = 'увімкнено' }
           Hint = 'Windows присипляє USB-пристрої, які вважає неактивними. Зовнішні диски (UASP) і хаби від цього інколи відвалюються або зависають. Вимкнення — стандартний крок при "зникненні" USB-дисків.' }
    )
    Steps       = @(
        @{ Text = 'Диспетчер пристроїв → Контролери USB → кожен "USB Root Hub" / "Generic USB Hub" → Властивості → Керування живленням → зняти "Дозволити вимикати цей пристрій для економії енергії".'; Open = 'devmgmt.msc' }
        'Для NVMe: оновіть прошивку SSD утилітою виробника (Samsung Magician, WD Dashboard, Crucial Storage Executive тощо).'
    )
}
