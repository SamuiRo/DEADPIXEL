# Профіль - набір рецептів під задачу + кроки, які не автоматизуються.
@{
    Title       = (T 'Стабільність: зависання GPU і дисків' 'Stability: GPU and disk hangs')
    Description = (T 'Прибирає енергозбереження, яке найчастіше дає TDR, зависання дисків і відвалювання USB, і вмикає збереження доказів для аналізу крашів.' 'Removes the power saving that most often causes TDRs, disk hangs and USB drop-outs, and turns on evidence collection for crash analysis.')
    Recipes     = @('pcie-aspm', 'disk-power', 'fast-startup', 'event-logs', 'gpu-stability')
    Steps       = @(
        (T 'Міняйте по одному кроку і спостерігайте щонайменше тиждень: рідкісні краші за 2–3 дні можуть просто не встигнути статися.' 'Change one thing at a time and watch for at least a week: rare crashes may simply not happen within 2–3 days.')
        (T 'Оновіть BIOS/UEFI і драйвер чипсета з сайту виробника материнської плати (не через Windows Update).' 'Update the BIOS/UEFI and chipset driver from the motherboard vendor site (not via Windows Update).')
        (T 'Відеодрайвер - чиста установка (рецепт "Відеокарта", вкладка "Чиста установка драйвера").' 'Graphics driver — a clean install (the "Graphics card" recipe, the "Clean driver install" tab).')
        (T 'Живлення відеокарти: кожен вхід перехідника - окремим кабелем від БЖ, по можливості без "косичок" (daisy-chain).' 'Graphics card power: each adapter input on its own PSU cable, avoiding daisy-chains where possible.')
    )
}
