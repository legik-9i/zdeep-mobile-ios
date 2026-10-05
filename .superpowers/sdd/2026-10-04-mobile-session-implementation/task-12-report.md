# Task 12 — полный debug-сброс, смена окружения и диагностика

## Реализация

Добавлен `OwnedClientDataCleaner` с проверяемыми адаптерами для ограниченных app-owned ресурсов: explicit generic-password Keychain services/accounts, `Application Support/ZDEEP`, app Caches/Documents/tmp files, bundle UserDefaults domain и persistent `WKWebsiteDataStore` data types. После каждой очистки адаптер повторно проверяет отсутствие записей. Результат считается успешным только при пустом `remaining`; retry получает только предыдущие остатки.

Reset и смена environment теперь останавливают сценарий и SessionManager; до persistent WebKit deletion закрывают WebSession, останавливают mailbox и ждут завершения его задач. Full reset приостанавливает диагностическую запись, чтобы файлы журнала не появились снова между очисткой и retry. Переключение на другую `databaseScope` меняет текущую конфигурацию только после успешного удаления; сбой оставляет старую environment и отдаёт retry context с target/progress. Одинаковый scope не удаляет данные, но всё равно закрывает прежний документ и инвалидирует старую memory session. Новый сценарий запускает restore до auth; ответы остановленной операции не применяются.

Диагностика сохраняет подготовленный WebView скрытым; reset закрывает mailbox до удаления его файлов. `sessionStateRevision` не переопределялся и остаётся диагностическим счётчиком. Debug executor, mailbox и panel защищены существующим `#if DEBUG`; дополнительный production test hook не добавлялся.

## RED/GREEN и изменения тестов

- Cleaner unit tests покрывают partial failure/retry только оставшихся категорий, проверку emptiness до success, изолированный UUID Keychain service с сохранением чужого service, а также injected app-owned files/defaults roots.
- Coordinator regressions проверяют cleanup failure без преждевременной смены environment/target/JWT, очистку memory JWT/document на same-scope switch, reset partial retry без старта auth и clean-first порядок смены с восстановлением.
- Event store test проверяет, что запись приостановлена на reset и продолжается после resume.
- Diagnostic launch test использует настоящий скрытый WKWebView и локальный loopback refused endpoint: mailbox готов до reveal, затем reset закрывает его и проверяет отсутствие handshake-файла до вызова cleaner.
- Существующий integration test запускает persistent local WebKit fixture, закрывает начальный `WebSession`, выполняет reset, затем проверяет отсутствие cookie и localStorage из новой WebView.
- В первом полном unit run единственная ошибка оказалась устаревшим assertion в `test_select_prod_does_not_load_web`: оно ожидало `.local`, хотя clean-first switch теперь применяет `.prod`; assertion исправлен, focused тест прошёл, после чего весь unit run стал зелёным.

## Проверки

Все suite запускались с `--environment local` на Simulator `0DDEE416-EECF-4BF3-8F15-BA93A980033A` (iPhone 18 Pro, iOS Simulator 27.0). Тестовые environment switch сценарии используют fake dependencies; test/prod сетевые endpoints не запускались.

| Проверка | Результат | xcresult |
|---|---:|---|
| Полный unit suite | PASS, 199 тестов, 0 failures | `.artifacts/runs/20261005-121707-1791191827331069000/Tests.xcresult` |
| Полный WebKit integration suite | PASS, 26 тестов, 0 failures | `.artifacts/runs/20261005-121731-1791191851978792000/Tests.xcresult` |
| Полный UI suite | PASS, 22 теста, 0 failures | `.artifacts/runs/20261005-121904-1791191944034460000/Tests.xcresult` |
| Cleaner verification postcondition | PASS | `.artifacts/runs/20261005-120940-1791191380168655000/Tests.xcresult` |
| Files/defaults ownership | PASS | `.artifacts/runs/20261005-121250-1791191570992338000/Tests.xcresult` |
| Event store suspension | PASS | `.artifacts/runs/20261005-121309-1791191589652680000/Tests.xcresult` |
| Prepared hidden WebView/mailbox close order | PASS | `.artifacts/runs/20261005-120847-1791191327513123000/Tests.xcresult` |
| Release Simulator build | PASS | `xcodebuild -configuration Release ... build` |

Release executable проверен `nm -a` и binary marker scan: symbols/strings `DiagnosticExecutor`, `DebugPanel`, `DiagnosticMailbox` отсутствуют. Полный unit suite сделал один initial failed run из-за test assertion выше; исправление подтверждено focused run `.artifacts/runs/20261005-121636-1791191796465150000`, итоговый полный suite прошёл.

Integration reset оставил в Simulator log невлияющие предупреждения SQLite `vnode unlinked while in use` для `Library/Caches/ru.zdeep.mobile/Cache.db*`: WebSession закрыта перед cleaner, persistent website data очищены и проверены пустыми до file deletion; повторно созданная WebView подтвердила отсутствие seeded cookie/localStorage. Integration assertions прошли.

`git diff --check` прошёл. Python suite не запускался: scripts не менялись. Root-owned `progress.md` и `task-7-report.md` в commit не включены.
