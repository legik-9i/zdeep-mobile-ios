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
