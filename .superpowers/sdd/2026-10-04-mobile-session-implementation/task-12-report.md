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

## Remediation по review Sol

Исправлены три Important замечания:

1. Каждый `startNewRestoreScenario()` теперь ставит generation UUID до `restore()` и применяет результат или ошибку только пока этот UUID остаётся активным. Тест с приостановленным первым restore и вторым environment switch подтвердил, что stale binding больше не меняет scenario/screen и не запускает `updateSession`.
2. Пока full reset содержит оставшиеся категории, environment picker/switch заблокирован. Retry повторяет только эти категории; restore/auth продолжается только после успешного cleanup. Тест подтвердил, что same-scope переключение не снимает `.fullReset` и не начинает auth, затем явный retry очищает keychain и только после него допускает restore/auth.
3. При создании каждого WebSession mailbox opt-in повторно проверяется по целевой текущей environment и платформе. Fake local→prod switch с настоящей WebSession на loopback refused URL подтвердил, что prod WebSession не публикует USB mailbox handshake.

### RED/GREEN remediation

- RED stale restore: `.artifacts/runs/20261005-123514-1791192914079653000/Tests.xcresult`; GREEN: `.artifacts/runs/20261005-123936-1791193176628475000/Tests.xcresult`.
- RED pending cleanup bypass: `.artifacts/runs/20261005-123535-1791192935100052000/Tests.xcresult`; GREEN: `.artifacts/runs/20261005-123959-1791193199440651000/Tests.xcresult`.
- RED prod mailbox: `.artifacts/runs/20261005-123558-1791192958554846000/Tests.xcresult`; GREEN: `.artifacts/runs/20261005-124031-1791193231575885000/Tests.xcresult`.

### Финальная проверка remediation

| Проверка | Результат | xcresult |
|---|---:|---|
| Полный unit suite | PASS, 202 теста, 0 failures | `.artifacts/runs/20261005-124056-1791193256095494000/Tests.xcresult` |
| Полный WebKit integration suite | PASS, 26 тестов, 0 failures | `.artifacts/runs/20261005-124123-1791193283689169000/Tests.xcresult` |
| Полный UI suite | PASS, 22 теста, 0 failures | `.artifacts/runs/20261005-124227-1791193347872337000/Tests.xcresult` |
| Release Simulator build | PASS | `.artifacts/release-build-final-review/Build/Products/Release-iphonesimulator/ZDEEP.app` |

После dynamic eligibility изменения Release executable повторно проверен `nm -a` и binary marker scan: символы и маркеры `DiagnosticExecutor`, `DebugPanel`, `DiagnosticMailbox` отсутствуют. `git diff --check` прошёл.

## Проверка test fixture безопасности и финальная матрица

Review выявил, что предыдущий focused prod-mailbox тест возвращал настоящий `WebSession`. Хотя factory задавал ему trusted URL на loopback, coordinator отдельно передавал в `load(url:)` `endpoints.web` целевой environment; для `.prod` это могло обратиться к production URL. Предыдущий GREEN bundle `.artifacts/runs/20261005-124031-1791193231575885000/Tests.xcresult` поэтому не засчитывается как доказательство для этого контракта.

Fixture заменён на fake `WebSessionHandle`, у которого нет пути к `WebSession.load`. Проверка напрямую подтверждает opt-in для исходной local environment и запрет для целевой prod environment, а также отсутствие diagnostic handshake. Targeted test прошёл: `.artifacts/runs/20261005-125342-1791194022954943000/Tests.xcresult`. Ни один `.test`/`.prod` URL этим сценарием не загружается.

Дополнительный Sol Important предотвращает обход незавершённой environment cleanup другим same-scope switch. Его regression test и явный retry прошли: `.artifacts/runs/20261005-125323-1791194003224623000/Tests.xcresult`.

После замены fixture заново пройдена полная local матрица на Simulator `0DDEE416-EECF-4BF3-8F15-BA93A980033A`:

| Проверка | Результат | xcresult |
|---|---:|---|
| Полный unit suite | PASS, 203 теста, 0 failures | `.artifacts/runs/20261005-125411-1791194051854460000/Tests.xcresult` |
| Полный WebKit integration suite | PASS, 26 тестов, 0 failures | `.artifacts/runs/20261005-125441-1791194081853561000/Tests.xcresult` |
| Полный UI suite | PASS, 22 теста, 0 failures | `.artifacts/runs/20261005-125549-1791194149647043000/Tests.xcresult` |

Финальный UI suite собран и запущен после изменения fixture; оба `DiagnosticMailboxUITests` прошли. `git diff --check` прошёл.

После Sol guard change `canSwitchEnvironment` повторно выполнен Release Simulator build (build only) по пути `.artifacts/release-build-final-review/Build/Products/Release-iphonesimulator/ZDEEP.app`; `nm -a` и binary marker scan снова не нашли `DiagnosticExecutor`, `DebugPanel` или `DiagnosticMailbox`.

## Финальная проверка coordinator eligibility seam

Scoped review Sol отметил, что fake-session test завершался до создания настоящей WebSession, поэтому отсутствие handshake само по себе не проверяло coordinator decision. Добавлено внутреннее `AppCoordinator.isDiagnosticMailboxEligible`; `prepareWebSession` использует его в существующем `#if DEBUG` gate, а fake local→prod тест проверяет свойство после смены environment. Fake fixture не поддерживает `load`, так что ни один prod URL не запрашивается. Sol одобрил этот scoped production diff.

Повторная матрица после изменения:

| Проверка | Результат | xcresult |
|---|---:|---|
| Coordinator eligibility focused | PASS, 1 тест | `.artifacts/runs/20261005-130906-1791194946312717000/Tests.xcresult` |
| Полный unit suite | PASS, 203 теста, 0 failures | `.artifacts/runs/20261005-130929-1791194969491498000/Tests.xcresult` |
| Полный WebKit integration suite | PASS, 26 тестов, 0 failures | `.artifacts/runs/20261005-130950-1791194990011962000/Tests.xcresult` |
| Полный UI suite | PASS, 22 теста, 0 failures | `.artifacts/runs/20261005-131043-1791195043396082000/Tests.xcresult` |
| Release Simulator build | PASS, build only | `.artifacts/release-build-final-policy/Build/Products/Release-iphonesimulator/ZDEEP.app` |

Release executable повторно проверен `nm -a` и `strings`: совпадений `DiagnosticExecutor`, `DebugPanel` и `DiagnosticMailbox` нет. `git diff --check` выполнен после обновления отчёта.
