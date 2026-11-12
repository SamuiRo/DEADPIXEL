# Windows Script Host: вимкнути запуск .js/.vbs/.wsf - типових «документів» із шкідливих листів.
@{
    Title       = (T 'Вимкнути Windows Script Host' 'Turn off Windows Script Host')
    Description = (T 'Файли .js, .vbs, .wsf більше не запускаються подвійним клацанням як програми. PowerShell і .bat/.cmd це не зачіпає.' '.js, .vbs and .wsf files no longer run as programs on double-click. PowerShell and .bat/.cmd are not affected.')
    Items       = @(
        @{ Kind = 'Registry'; Id = 'wsh-enabled'; Title = (T 'Windows Script Host' 'Windows Script Host'); Desired = 0
           Path = 'HKLM:\SOFTWARE\Microsoft\Windows Script Host\Settings'; Name = 'Enabled'; Type = 'DWord'
           Labels = @{ 0 = (T 'вимкнено' 'off'); 1 = (T 'увімкнено' 'on') }
           Hint = (T 'Перестануть працювати скрипти .vbs/.js, зокрема slmgr.vbs (керування активацією Windows) і скрипти деяких старих інсталяторів. На час їх запуску відкотіть рецепт.' '.vbs/.js scripts stop working, including slmgr.vbs (Windows activation management) and scripts of some old installers. Revert the recipe while you run them.') }
    )
}
