# Task 11 — готовность WebSession, повторы и восстановление процесса

## Реализация

Добавлена координация ready-событий WebSession с проверкой scenario, container, attempt и document identity, актуальной привязки и JWT-сессии, foreground-состояния и допустимого экрана. Readiness принимает только валидный `reportReady`; mailbox и DOM-ready не открывают веб. Принятый ready отменяет таймер сразу, даже если показ WebView отложен до foreground.

60-секундный active budget использует тот же `SessionClock`, что AuthClient/SessionManager. Таймер приостанавливается в фоне, продолжает отсчёт с остатка, не сбрасывается при redirect/refresh и начинается заново для нового документа. Callback таймера захватывает scenario ID, поэтому старый timeout не меняет состояние нового restore.

Authorization Retry всегда выполняет token attempt, в том числе при холодном restore без WebSession; после успешной авторизации готовится новый документ. Web Retry с действующей сессией создаёт новый документ без HTTP. Полная навигация сохраняет рабочий режим SessionManager. Добавлено одноразовое восстановление завершившегося WebKit content process с новой попыткой после успешного восстановления.

## TDD и диагностика

- Первый focused RED был compile-time: отсутствовали `acceptWebReady(..., screen:)` и внедряемый `sessionClock`. Тестового bundle не ожидалось; точный лог: `/tmp/task11-red-compile.log`.
- Во время реализации устранены build/fixture проблемы: доступ к `isWebViewOpen` из extension, локальный URL для integration, соответствие старых CoordinatorTests новой сигнатуре и strict `documentPreparing` перед commit. Эти попытки не считались тестовыми результатами.
- Expanded readiness RED обнаружил утечку времени предыдущего документа: новый 60s budget терял 20s от старого. Исправлено порядком отмены старого timer до установки нового бюджета.
- RED `test_old_scenario_readiness_timeout_cannot_override_restore()` воспроизвёл старый timeout, переводящий новый restore в error. Таймер теперь захватывает UUID сценария, callback проверяет точное совпадение. GREEN focused bundle: `.artifacts/runs/20261005-104108-1791186068604908000/Tests.xcresult`.
- Во время full unit тест `test_cancel_cold_restore_token_attempt_before_and_after_retry()` выявил, что auth retry без WebSession не запускал token attempt и зависал. Убрано требование WebSession для auth retry; при её наличии создаётся новый документ. Тест прошёл в `.artifacts/runs/20261005-101136-1791184296286838000/Tests.xcresult`.
- Первая версия public reload integration пыталась вернуть из JS `undefined`, что WebKit не сериализует. Тест заменён на Promise, возвращающий serializable boolean, и проверяет новую document identity и доступность bridge после reload.
- Отдельные прежние incomplete/failed попытки не учитываются как PASS: unit hang до исправления auth retry (`.artifacts/runs/20261005-100305-1791183785219893000`, повтор `.artifacts/runs/20261005-100629-1791183989465717000`); первая full integration не прошла новый reload тест из-за JS результата; ранние сборочные ошибки зафиксированы в логах `/tmp/task11-focused-attempt2.log`, `/tmp/task11-focused-green1.log`, `/tmp/task11-focused-green2.log`. Полные свежие результаты ниже относятся к окончательному diff.

## Проверки

Все команды выполнялись на Simulator `0DDEE416-EECF-4BF3-8F15-BA93A980033A`, только `--environment local`.

- `python3 scripts/zdeep.py test --environment local --suite unit --simulator 0DDEE416-EECF-4BF3-8F15-BA93A980033A` — PASS, 185 tests / 21 suites; `.artifacts/runs/20261005-104342-1791186222174301000/Tests.xcresult`.
- `python3 scripts/zdeep.py test --environment local --suite integration --simulator 0DDEE416-EECF-4BF3-8F15-BA93A980033A` — PASS, 26/26; включает public WebKit reload/reinjection и локальную auth integration; `.artifacts/runs/20261005-104429-1791186269135735000/Tests.xcresult`.
- `python3 scripts/zdeep.py test --environment local --suite ui --simulator 0DDEE416-EECF-4BF3-8F15-BA93A980033A` — PASS, 22/22; `.artifacts/runs/20261005-104555-1791186355617168000/Tests.xcresult`.
- `git diff --check` — PASS.

Unit, integration и UI запущены отдельно после последнего production изменения. Test/prod окружения и физическое устройство не использовались. Токены и тела auth-запросов не выводились.

## Remediation после Sol review

### RED → GREEN

1. `test_readiness_budget_starts_when_jwt_is_published_before_first_frame` доказал RED: без первого кадра прошло 59 активных секунд после успешной публикации JWT; старый код стартовал полный бюджет только при `documentPreparing`, поэтому не переходил в timeout через ещё 1 секунду. RED: `.artifacts/runs/20261005-110227-1791187347933605000/Tests.xcresult`. Теперь момент публикации JWT начинает активный отсчёт; первая подготовка документа сохраняет уже израсходованную часть бюджета. GREEN: `.artifacts/runs/20261005-110829-1791187709584553000/Tests.xcresult`.
2. `test_web_retry_preserves_failed_full_navigation_url` доказал RED двумя assertions: ошибка навигации заменяла путь на `endpoints.web`, и Retry повторно загружал корень. RED: `.artifacts/runs/20261005-110335-1791187415783875000/Tests.xcresult`. Coordinator теперь сохраняет URL последней подготовки документа в web retry context; Retry получает этот URL. GREEN: `.artifacts/runs/20261005-110848-1791187728933090000/Tests.xcresult`.
3. `test_session_expired_preserves_visible_native_web_error_context` доказал RED: событие `.sessionExpired` заменяло видимую native web error на authorization error и теряло прежний web retry context. RED: `.artifacts/runs/20261005-110518-1791187518438559000/Tests.xcresult`. Passive expiry теперь сохраняет текущую native web error/context. GREEN: `.artifacts/runs/20261005-110907-1791187747530698000/Tests.xcresult`.

Первая попытка focused RED #1 не дошла до сборки/теста: sandbox ограничил CoreSimulatorService и доступ SPM к CodeScanner, xcodebuild завершился кодом 74. По `ios-testing` ту же команду повторил с разрешённым Simulator/SPM доступом; bundle выше содержит поведенческий RED.

### Свежие полные проверки после remediation

Только local, Simulator `0DDEE416-EECF-4BF3-8F15-BA93A980033A`:

- `python3 scripts/zdeep.py test --environment local --suite unit --simulator 0DDEE416-EECF-4BF3-8F15-BA93A980033A` — PASS, 188 тестов / 21 suite; `.artifacts/runs/20261005-110943-1791187783204509000/Tests.xcresult`.
- `python3 scripts/zdeep.py test --environment local --suite integration --simulator 0DDEE416-EECF-4BF3-8F15-BA93A980033A` — PASS, 26/26; `/health` HTTP 200; `.artifacts/runs/20261005-111014-1791187814551617000/Tests.xcresult`.
- `python3 scripts/zdeep.py test --environment local --suite ui --simulator 0DDEE416-EECF-4BF3-8F15-BA93A980033A` — PASS, 22/22; `.artifacts/runs/20261005-111128-1791187888020074000/Tests.xcresult`.
- `git diff --check` — PASS.

Test/prod и физическое устройство не использовались. Токены и тела auth-запросов не выводились.

## Дополнительное исправление Sol по timeout без document и URL после token refresh

В shared worktree поступили три production/test files от Sol: `AppCoordinator.swift`, `AppCoordinator+WebPreparation.swift`, `WebReadinessTests.swift`. Я их не перезаписывал и после handoff production-код не редактировал.

- `test_readiness_timeout_without_document_after_jwt_publication` — PASS, 1/1; `.artifacts/runs/20261005-112441-1791188681012430000/Tests.xcresult`. Проверяет, что JWT запускает active timer без document и deadline переводит coordinator в web timeout error.
- `test_web_retry_preserves_failed_navigation_url_after_token_refresh` — PASS, 1/1; `.artifacts/runs/20261005-112504-1791188704267647000/Tests.xcresult`. Проверяет полный путь: неуспешная full navigation → отсутствующая сессия → token retry → повтор того же navigation URL.

### Повторная полная матрица на handoff diff

Все команды выполнялись на Simulator `0DDEE416-EECF-4BF3-8F15-BA93A980033A`, только local:

- `python3 scripts/zdeep.py test --environment local --suite unit --simulator 0DDEE416-EECF-4BF3-8F15-BA93A980033A` — PASS, 190 tests / 21 suites; `.artifacts/runs/20261005-112621-1791188781364914000/Tests.xcresult`.
- `python3 scripts/zdeep.py test --environment local --suite integration --simulator 0DDEE416-EECF-4BF3-8F15-BA93A980033A` — PASS, 26/26, `/health` HTTP 200; `.artifacts/runs/20261005-112702-1791188822799643000/Tests.xcresult`.
- `python3 scripts/zdeep.py test --environment local --suite ui --simulator 0DDEE416-EECF-4BF3-8F15-BA93A980033A` — PASS, 22/22; `.artifacts/runs/20261005-112827-1791188907077337000/Tests.xcresult`.
- `git diff --check` — PASS.

Для этих двух тестов текущая handoff проверка подтверждает GREEN; тесты/production patch в этом ходе Luna не меняла. Test/prod и физическое устройство не использовались.

### Stuck protocol по двум повторившимся замечаниям

В следующем Sol re-review после Luna remediation `1e4a1d9` повторились замечания о таймауте без документа и сохранении URL после full-navigation retry. Причина повторения: первый фикс записывал старт бюджета при публикации JWT, но ставил timeout callback только при `documentPreparing`; URL сохранялся лишь в ветви с действующим JWT, а auth fallback терял его. Третье замечание — сохранение нативной ошибки при passive expiry — было закрыто.

По правилу stuck protocol Sol узко исправил только эти две повторившиеся проблемы и добавил два fake-clock regression tests; проверки Sol не запускал. Luna получила handoff, не меняла production diff, запустила оба focused теста и полную матрицу. Исправление запускает terminal timeout после 60 active seconds от JWT даже без первого документа, а исходный URL проходит через token retry и загружается после успешной авторизации.

- `test_readiness_timeout_without_document_after_jwt_publication` — GREEN 1/1, `.artifacts/runs/20261005-112441-1791188681012430000/Tests.xcresult`.
- `test_web_retry_preserves_failed_navigation_url_after_token_refresh` — GREEN 1/1, `.artifacts/runs/20261005-112504-1791188704267647000/Tests.xcresult`.
- Итоговый Simulator `local`: unit 190/190 (`.artifacts/runs/20261005-112621-1791188781364914000/Tests.xcresult`), integration 26/26 (`.artifacts/runs/20261005-112702-1791188822799643000/Tests.xcresult`), UI 22/22 (`.artifacts/runs/20261005-112827-1791188907077337000/Tests.xcresult`), `git diff --check` PASS.
- Sol сделал stuck-protocol patch; Luna подтвердила результаты и закоммитила его вместе с тестами/отчётом как `8c47478590618b867aaaaa886771b59fddeaf038`. Test/prod и физическое устройство не использовались.
