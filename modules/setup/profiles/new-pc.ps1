# Профіль - набір рецептів під задачу + кроки, які не автоматизуються.
@{
    Title       = (T 'Новий ПК: базове налаштування' 'New PC: basic setup')
    Description = (T 'Усе для свіжовстановленої Windows: стабільність, домашня мережа. Перевірка без змін — швидкий аудит ПК.' 'Everything for a fresh Windows install: stability and home network. Checking without applying is a quick PC audit.')
    Recipes     = @('pcie-aspm', 'disk-power', 'fast-startup', 'home-network')
    Steps       = @(
        @{ Text = (T 'Встановіть усі оновлення Windows, включно з необов''язковими оновленнями драйверів.' 'Install all Windows updates, including optional driver updates.'); Open = 'ms-settings:windowsupdate' }
        (T 'Встановіть драйвер чипсета і відеодрайвер із сайтів виробників.' 'Install the chipset and graphics drivers from the vendors'' sites.')
        @{ Text = (T 'Перевірте, що активна потрібна схема живлення: налаштування рецептів пишуться в поточну схему.' 'Check that the right power plan is active: recipe settings are written to the current plan.'); Open = 'powercfg.cpl' }
        (T 'Залиште DEADPIXEL в автозапуску (Налаштування → "Запускати разом із Windows"), щоб чорна скринька писалась із першого дня.' 'Keep DEADPIXEL in autostart (Settings → "Start with Windows") so the black box records from day one.')
    )
}
