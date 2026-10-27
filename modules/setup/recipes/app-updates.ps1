# Оновлення встановлених програм через winget (вбудований менеджер програм Windows).
@{
    Title       = (T 'Оновлення програм' 'App updates')
    Description = (T 'Оновити програми до актуальних версій однією командою: старі версії браузерів, месенджерів, архіваторів і рантаймів - найчастіша діра в домашньому ПК.' 'Update programs to current versions with one command: old browsers, messengers, archivers and runtimes are the most common hole in a home PC.')
    Tabs        = @(
        @{ Id = 'update'; Title = (T 'Оновити все' 'Update everything')
           Description = (T 'Спершу список того, що оновиться, потім саме оновлення. Закрийте програми, які оновлюються (браузер, месенджери), - інакше їхній інсталятор чекатиме.' 'First the list of what will update, then the update itself. Close the programs being updated (browser, messengers) — otherwise their installer will wait.')
           Steps = @(
               @{ Text = (T 'Подивитися, що буде оновлено.' 'See what will be updated.')
                  Run = '[Console]::OutputEncoding = [Text.Encoding]::UTF8; winget upgrade --include-unknown --accept-source-agreements --disable-interactivity'
                  Hint = (T 'Нічого не змінює - лише показує доступні оновлення. Програми з версією «Unknown» winget не може порівняти: їх він оновить, лише якщо ви вкажете окремо.' 'Changes nothing — only lists available updates. winget cannot compare programs with version "Unknown": it updates them only if you name them explicitly.') }
               (T 'Закрийте програми зі списку, якими зараз користуєтеся (браузери, месенджери, редактори).' 'Close the programs on the list that you are using (browsers, messengers, editors).')
               @{ Text = (T 'Оновити всі програми.' 'Update all programs.')
                  Run = '[Console]::OutputEncoding = [Text.Encoding]::UTF8; winget upgrade --all --silent --accept-package-agreements --accept-source-agreements --disable-interactivity'
                  Admin = $true
                  Confirm = (T 'Оновити всі програми зі списку? Це може тривати кілька хвилин; програми, що оновлюються, закриються.' 'Update all programs on the list? This can take a few minutes; programs being updated will close.')
                  Hint = (T 'Права адміністратора - щоб не підтверджувати UAC для кожного інсталятора окремо. Якщо якесь оновлення не вдасться, решта все одно встановиться; повторіть крок або оновіть ту програму вручну.' 'Administrator rights avoid a UAC prompt for every installer. If one update fails, the rest still install; repeat the step or update that program manually.') }
               (T 'Запустіть «Аудит системи» ще раз, щоб переконатися, що важливих оновлень не лишилося.' 'Run the "System audit" again to make sure no important updates are left.')
           ) }
    )
}
