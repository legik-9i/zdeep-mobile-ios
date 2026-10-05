# Task 12: полный debug-сброс, смена окружения и диагностика

## Объём

Реализовать очистку только принадлежащих приложению Keychain-записей, файлов в sandbox, UserDefaults domain и persistent WKWebsiteDataStore. Повтор очистки должен принимать только категории, которые ещё не очищены; пока есть остатки, reset/switch не завершается и новая авторизация не начинается. Перед файловой очисткой остановить mailbox и связанные задачи, закрыть WebSession, затем удалить и проверить WebKit-записи. Смена окружения применяется только после нужной успешной очистки; при одинаковом `databaseScope` всё равно сбросить memory JWT и старый document. Restore предшествует auth, а ответы старой async операции игнорируются.

Диагностика должна работать с подготовленным скрытым WebView, не раскрывая его. Полный reset закрывает mailbox до очистки debug-файлов. `sessionStateRevision` остаётся диагностическим счётчиком; Release не экспортирует debug executor.

## RED-последовательность

1. Unit: очистка всех app-owned категорий, сохранность посторонних записей, ошибка одной категории и повтор только оставшихся категорий.
2. Coordinator: cleanup failure сохраняет активные environment/target; same-scope switch сбрасывает JWT и document; restore идёт раньше auth, старый async ответ не меняет новый сценарий.
3. Диагностика и UI: hidden prepared WebView доступен mailbox без reveal; mailbox закрыт до удаления файлов; reset можно повторить; Release не экспортирует executor.
4. WebKit integration: persistent data fixture удалён через последовательный reset и отсутствие записей подтверждено после completion.

Все switching test/prod сценарии используют fake dependencies. Запуски тестов — только `--environment local` и Simulator `0DDEE416-EECF-4BF3-8F15-BA93A980033A`; без физического устройства и сетевых запросов в test/prod.

## Файлы

- Создать `ZDEEP/ZDEEP/App/OwnedClientDataCleaner.swift`, `ZDEEP/ZDEEPTests/OwnedClientDataCleanerTests.swift`.
- При необходимости расширить `ZDEEP/ZDEEP/App/AppCoordinator+Reset.swift`, `AppCoordinator.swift`, `Debug/DebugPanel.swift`, `Debug/DiagnosticMailbox.swift`, `Environment/LaunchConfiguration.swift`.
- Обновить `ZDEEP/ZDEEPTests/CoordinatorTests.swift`, `DiagnosticMailboxTests.swift`, `DiagnosticMailboxLaunchTests.swift`, `ZDEEP/ZDEEPUITests/DebugPanelUITests.swift`, `DiagnosticMailboxUITests.swift` и WebKit reset integration tests.

## Исходные материалы

План Task 12 и `ios/AGENTS.md` прочитаны. Сверены briefs/reports Tasks 1, 8, 9, 10 и 11 из `.superpowers/sdd/2026-10-04-mobile-session-implementation/`. Техническое поведение `WKWebsiteDataStore` проверено по актуальной документации через Context7.

В checkout присутствуют root-owned изменения `progress.md` и `task-7-report.md`; они не включаются в Task 12 commit.
