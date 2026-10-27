# Профіль - набір рецептів під задачу + кроки, які не автоматизуються.
@{
    Title       = (T 'Діагностика крашів' 'Crash diagnostics')
    Description = (T 'Підготувати ПК до розслідування: більші журнали, дамп при BSOD, інструменти (WinDbg, LibreHardwareMonitor, CrystalDiskInfo).' 'Prepare the PC for an investigation: bigger logs, a dump on BSOD, tools (WinDbg, LibreHardwareMonitor, CrystalDiskInfo).')
    Recipes     = @('event-logs', 'diag-tools')
    Steps       = @(
        (T 'Увімкніть автозапуск DEADPIXEL (Налаштування → "Запускати разом із Windows"), щоб чорна скринька писала стан до кожного краша.' 'Turn on DEADPIXEL autostart (Settings → "Start with Windows") so the black box records the state before every crash.')
        (T 'Запустіть LibreHardwareMonitor від адміністратора і залиште в треї - DEADPIXEL почне показувати температуру CPU.' 'Run LibreHardwareMonitor as administrator and leave it in the tray — DEADPIXEL starts showing the CPU temperature.')
        (T 'Після наступного краша: DEADPIXEL → Краші → таймлайн і "Аналізувати дамп"; для звернення в сервіс - "Зібрати пакет для діагностики".' 'After the next crash: DEADPIXEL → Crashes → the timeline and "Analyze dump"; for a service request — "Build diagnostics package".')
    )
}
