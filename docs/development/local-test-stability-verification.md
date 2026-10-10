# Проверка стабильности local-тестов

Этот отчёт фиксирует приёмку контракта local-тестов для стабилизации CLI. Автоматические наборы запускаются только в `local`; тестовый контур остаётся для диагностики симулятора/iPhone согласно [verification.md](verification.md), без health-проверки testing API.

## Среда и исходное состояние

- Проверенный исходный commit ветки `fix/local-test-stability`: `e8d7e3f793131e2ef79525a258b0c284cd2e40e0`.
- Xcode 27.0, build 27A266a; Swift 6.4. Целевой симулятор: iPhone 18 Pro, iOS 27.0, UDID `0DDEE416-EECF-4BF3-8F15-BA93A980033A`.
- `python3 scripts/zdeep.py preflight --environment local --suite all` — успешно: настроенный API `/health` и настроенный Web вернули HTTP 200.
- Physical UDID `00008101-001A25963AC2001E` при перечислении устройств отображался как `available (paired)`. Однако обязательная read-only команда `logs --target device` не смогла установить CoreDevice-соединение: error 4000, `ControlChannelConnectionError`, `Connection reset by peer`. Debug-запуск и физический `1+1` поэтому не выполнялись; физическая проверка неподтверждена.

## Python runner

```sh
python3 -m unittest discover -s scripts/tests
```

Первый запуск завершился ошибкой sandbox на bind `127.0.0.1` в тесте перенаправления preflight. Та же команда с разрешённым loopback завершилась успешно: **54/54**, ошибок нет. Это ограничение среды выполнения; код не менялся.

## Полный local all

Первый запуск:

```sh
python3 scripts/zdeep.py test --environment local --suite all --simulator 0DDEE416-EECF-4BF3-8F15-BA93A980033A
```

- Exit code 0; `xcodebuild build-for-testing` собрал тестовые targets с `CODE_SIGNING_ALLOWED=YES` и `CODE_SIGN_IDENTITY=-`.
- Xcode result: `Passed`, **257/257**, failures 0, unexpected failures 0, skipped 0, runtime warnings 0.
- Состав по test tree: unit 205, hosted integration 30, UI 22. Наборы исполнялись в одном `all`; отдельного повторного запуска unit/integration/UI не было.
- Preflight прошёл; bundle: `.artifacts/runs/20261010-054215-1791600135635649000/Tests.xcresult`.

Единственный повтор на той же сборке:

```sh
python3 scripts/zdeep.py test --environment local --suite all --simulator 0DDEE416-EECF-4BF3-8F15-BA93A980033A --skip-build
```

- Exit code 0; CLI использовал `xcodebuild test-without-building` и существующий `.xctestrun`. `build-for-testing` в повторе не запускался.
- Result bundle новый. Результат и состав совпали с первым: `Passed`, 257/257 (unit 205, integration 30, UI 22), failures 0, skips 0, runtime warnings 0.
- Bundle: `.artifacts/runs/20261010-054815-1791600495080249000/Tests.xcresult`.

Оба result bundle оставлены для аудита. Этот единичный повтор подтверждает повторяемость на текущей сборке, но не гарантирует отсутствия будущих flakes. Автоматические retries и прогоны в `test` не использовались.

## Фокусная допроверка после финального ревью

После полного `all` и `--skip-build` на commit `e8d7e3f793131e2ef79525a258b0c284cd2e40e0` ревью обнаружило один пропуск в bridge smoke: `test_public_reload_reinjects_bridge_for_a_new_document()` загружал статический `AppEnvironment.local.endpoints.web`. Исправление использует общий `LaunchConfiguration` endpoint suite и проверяет `session.requestedURL == endpoints.web`.

Сначала запуск с shell-переменными не создал RED: CLI `test` берёт URL из `.local/development.json` и подменил shell env настройками по умолчанию. Этот запуск не считается доказательством. Затем использовался временный `.local/development.json` с Web `http://127.0.0.1:4005` и API `http://127.0.0.1:4002`; strict local preflight подтвердил HTTP 200 для API `/health` и Web. RED-команда:

```sh
python3 scripts/zdeep.py test --environment local --suite integration --only 'WebSessionIntegrationTests/test_public_reload_reinjects_bridge_for_a_new_document()' --simulator 0DDEE416-EECF-4BF3-8F15-BA93A980033A
```

Assertion упала: `session.requestedURL` было `http://localhost:4005`, ожидаемый настроенный URL — `http://127.0.0.1:4005`. Bundle: `.artifacts/runs/20261010-061131-1791601891279429000/Tests.xcresult`.

После исправления та же команда с теми же overrides завершилась успешно: 1/1 passed; preflight снова подтвердил HTTP 200. Bundle: `.artifacts/runs/20261010-061244-1791601964219274000/Tests.xcresult`. Временный `.local/development.json` удалён. На момент этой фокусной допроверки полный suite ещё не перезапускался; ниже зафиксированы последующие полные прогоны на финальном HEAD.

## Финальный повтор на проверенном HEAD

После уточнения требования о надёжности тестов полный набор повторно запущен на финальном commit `3ddaa9d` двумя последовательными прогонами. Первый собрал тестовые targets; второй использовал `--skip-build` и тот же `.xctestrun`.

- Первый: `Passed`, **257/257**, failures 0, skips 0, runtime warnings 0. Bundle: `.artifacts/runs/20261010-064812-1791604092916377000/Tests.xcresult`.
- Повтор `--skip-build`: `Passed`, **257/257**, failures 0, skips 0, runtime warnings 0. Bundle: `.artifacts/runs/20261010-065305-1791604385770534000/Tests.xcresult`.
- `xcresulttool` подтвердил одинаковые счётчики, iPhone 18 Pro Simulator / iOS 27.0 и пустые `testFailures` в обоих bundles. Локальные API `/health` и Web прошли строгий preflight с HTTP 200.

Таким образом, текущий проверенный HEAD прошёл полный набор два раза подряд на одной сборке без flake. Это даёт будущему агенту воспроизводимую базовую проверку; последующие изменения всё равно должны проходить тот же набор, чтобы сохранить результат.

## Строгий ответ preflight без redirect

По уточнённому контракту настроенный API `/health` и Web URL должны сами вернуть HTTP 200. Любой redirect считается отказом готовности; preflight не должен проверять конечный адрес. Ранее `urllib` следовал за same-origin redirect, поэтому `302` на локальный `/health`, завершившийся `200`, ошибочно считался готовностью и делал дополнительный запрос.

Теперь redirect отклоняется до запроса назначения. Регрессионный loopback-тест сначала падал на `/redirect-local` и подтверждал, что был запрошен `/health`; после исправления он проходит и проверяет, что ни локальное, ни внешнее назначение не было запрошено. `python3 -m unittest discover -s scripts/tests`: **54/54**, OK. Отдельный живой `preflight --environment local --suite integration` вернул HTTP 200 от API и Web.

Это исправление также убирает прежнее замечание о сравнении origin с портами по умолчанию: сравнение origin больше не выполняется, поскольку разрешённых redirect нет.

Перед слиянием полный local `all` запущен на commit `bff7add` после этого исправления: `Passed`, **257/257**, failures 0, skips 0, runtime warnings 0. Bundle: `.artifacts/runs/20261010-072644-1791606404095721000/Tests.xcresult` (iPhone 18 Pro Simulator, iOS 27.0).
