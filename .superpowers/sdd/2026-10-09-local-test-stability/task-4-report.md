# Task 4. Локальные integration-тесты и ожидания

## Изменения

- Integration suite использует `.local` явно.
- `makeLoadedSession()` загружает существующий `document-start.html`, ждёт `document.readyState == "complete"` с лимитом 5 секунд и закрывает WebSession при любой ошибке.
- Ожидание `documentFailed` после неподдерживаемой отправки формы заменено на polling события с дедлайном 5 секунд.
- В тесте закрытия WebSession старт долгого JS Promise теперь подтверждается сообщением от отдельного `WKScriptMessageHandler`. Опросить страницу через второй `waitForJavaScript` нельзя: `DiagnosticExecutor` удерживает command gate до окончания Promise. Обработчик удаляется до `close()` и не хранит ссылку на сессию.
- Реальные web и local-auth smoke-сценарии сохранены. Контрактные WebKit тесты используют существующий локальный HTML fixture. Производственный код, bridge, suite/test identifiers и локальные fixture contracts не менялись.

## Проверки

Task 2 ранее подтвердил HTTP 200 от local API `/health` и local Web; этот preflight повторно не запускался.

Предыдущая Luna сообщила, что прошли selectors; подтверждающие bundles:

- `test_js_value_and_error` — `.artifacts/runs/20261009-190647-1791562007183579000/Tests.xcresult`
- `test_timeout_records_last_value` — `.artifacts/runs/20261009-190702-1791562022152030000/Tests.xcresult`
- `test_reload_reinjects_object` — `.artifacts/runs/20261009-190714-1791562034706175000/Tests.xcresult`
- `test_unsupported_form_submission_fails_current_document` — `.artifacts/runs/20261009-190724-1791562044277768000/Tests.xcresult`
- `test_unsupported_user_link_preserves_current_document` — `.artifacts/runs/20261009-190738-1791562058939794000/Tests.xcresult`

Предыдущая Luna остановилась по usage limit, оставив незакоммиченные изменения Task4. В bundle `.artifacts/runs/20261009-190759-1791562079506783000/Tests.xcresult` тест `test_closed_session_cannot_apply_result()` завершился с `nonSerializableResult("JavaScript returned undefined")`: первое чтение маркера до его установки возвращало `undefined`. В моём воспроизведении `.artifacts/runs/20261010-045523-1791597323593434000/Tests.xcresult` условие `=== true` устранило ошибку типа, но ожидание завершилось `timedOut(lastValue: false)`. Причина: JS polling вставал за незавершённым JS Promise в том же command gate.

После замены ожидания на сигнал из script-message handler точный selector прошёл:

```sh
python3 scripts/zdeep.py test --environment local --suite integration --only 'WebSessionIntegrationTests/test_closed_session_cannot_apply_result()' --simulator 0DDEE416-EECF-4BF3-8F15-BA93A980033A
```

Результат: `TEST BUILD SUCCEEDED`, selector passed (1 test); bundle `.artifacts/runs/20261010-045758-1791597478181593000/Tests.xcresult`. При первой компиляции helper использовал устаревшее имя API `addScriptMessageHandler`; по диагностике SDK заменено на `add`, после чего сборка и selector прошли.

`test all`, integration suite целиком и уже прошедшие selectors повторно не запускались. Full `all` остаётся для Task5.

## Fixed-sleep inventory

- Redirect failure event: bounded condition loop, максимум 100 × 50 ms; сохранён.
- Unsupported user link: фиксированное наблюдение 250 ms после действия сохранено намеренно, потому что тест проверяет отсутствие события.
- Unsupported form: фиксированное ожидание 250 ms заменено polling `documentFailed` с дедлайном 5 секунд и шагом 25 ms.
- Освобождение WebView после `close()`: два bounded weak-reference цикла до 20 × 25 ms (redirect и close/history); это ожидание освобождения ресурса, сохранено.
- Закрытие во время pending JS: фиксированное ожидание 100 ms заменено сообщением от WebKit handler и ограниченным polling этого native-флага (дедлайн 5 секунд, шаг 25 ms). JavaScript `setTimeout(..., 1500)` оставлен как управляемая длительность pending Promise, не как ожидание теста.
- `test_timeout_records_last_value` по-прежнему задаёт 250 ms как проверяемый timeout, не как фиксированную паузу.

## Ограничения исходного прогона Task4

На момент исходного commit Task4 был проверен только selector закрытия сессии; полный suite и UI тесты не запускались. Реальный local API/Web ранее проверен в Task2. Физический iPhone smoke этим отчётом не заявляется.

## Fix round 1 по замечанию ревью

### Пропущенное требование

Ревьюер обнаружил, что runner уже передаёт `ZDEEP_WEB_URL` и `ZDEEP_API_URL`, но реальные web/auth smoke-тесты создавали `LaunchConfiguration` с `variables: [:]` либо напрямую читали `AppEnvironment.local.endpoints`. Fresh-token fixture также жёстко обращался к `localhost:4002`, поэтому backend override не применялся. Это замечание исправлено в тестовых callers; production-код и suite identifier не менялись.

- Integration suite по-прежнему явно выбирает `.local`, а endpoint URLs берёт через `LaunchConfiguration` с `ProcessInfo.processInfo.environment`.
- Те же runtime variables теперь используются в full-reset и реальных local-auth сценариях: binding-to-web, сохранение web data и pair/token.
- `fetchFreshCarToken` получает настроенный backend и добавляет к нему прежний относительный маршрут `get-tmp-test-car-token`.
- Loopback auth контракт с собственным HTTP fixture и URL `http://localhost/auth/get-otp` оставлен без изменений.

### RED / GREEN

RED получен на точном selector `test_local_endpoints_follow_runner_overrides()` при временно восстановленном статическом `AppEnvironment.local.endpoints` и synthetic runtime variables `http://127.0.0.1:19005` / `http://127.0.0.1:19002`. Обе проверки endpoint URLs упали; тест не делал сетевых запросов. Bundle: `.artifacts/runs/20261010-050502-1791597902637160000/Tests.xcresult`.

GREEN: тот же selector и synthetic variables с `LaunchConfiguration` прошли. Bundle `.artifacts/runs/20261010-050544-1791597944442313000/Tests.xcresult` подтверждает `Passed`. Обёртка, захватывавшая stdout в `/private/tmp`, после успешного `xcodebuild test-without-building` завершилась `TypeError` на постпроверке из-за отсутствующего `capture_output` в её сигнатуре; сам test execution завершился успешно, результат проверен непосредственно через `xcresulttool`.

### Локальные smoke selectors

Все пять команд завершились успешно; каждый запуск исполнил 1 тест. Перед каждым запуском runner подтвердил local API `/health` и Web с HTTP 200. Итоговые assertions и bundles:

| Команда (`--only`) | Tests | Assertions | Bundle |
|---|---:|---|---|
| `python3 scripts/zdeep.py test --environment local --suite integration --only 'WebSessionIntegrationTests/test_real_web_url_and_native_object()' --simulator 0DDEE416-EECF-4BF3-8F15-BA93A980033A` | 1 | PASS | `.artifacts/runs/20261010-050654-1791598014291833000/Tests.xcresult` |
| `python3 scripts/zdeep.py test --environment local --suite integration --only 'WebSessionIntegrationTests/test_full_reset_clears_web_cookie_and_local_storage()' --simulator 0DDEE416-EECF-4BF3-8F15-BA93A980033A` | 1 | PASS | `.artifacts/runs/20261010-050708-1791598028017266000/Tests.xcresult` |
| `python3 scripts/zdeep.py test --environment local --suite integration --only 'WebSessionIntegrationTests/test_local_binding_to_real_web_ready()' --simulator 0DDEE416-EECF-4BF3-8F15-BA93A980033A` | 1 | PASS | `.artifacts/runs/20261010-050722-1791598042226942000/Tests.xcresult` |
| `python3 scripts/zdeep.py test --environment local --suite integration --only 'WebSessionIntegrationTests/test_local_ordinary_binding_reset_preserves_observed_web_data()' --simulator 0DDEE416-EECF-4BF3-8F15-BA93A980033A` | 1 | PASS | `.artifacts/runs/20261010-050737-1791598057091128000/Tests.xcresult` |
| `python3 scripts/zdeep.py test --environment local --suite integration --only 'WebSessionIntegrationTests/test_local_pair_then_token_accepts_spki_and_der_signature()' --simulator 0DDEE416-EECF-4BF3-8F15-BA93A980033A` | 1 | PASS | `.artifacts/runs/20261010-050750-1791598070208558000/Tests.xcresult` |

В первой синтетической попытке сборка выявила duplicate/missing локальные объявления `configuration`; они исправлены до RED/GREEN прогонов. Полный `all` и другие selectors не запускались.
