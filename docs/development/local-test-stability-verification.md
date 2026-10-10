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
