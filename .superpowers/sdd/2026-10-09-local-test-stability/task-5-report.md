# Task 5 — навыки, документация и финальная приёмка

## Готово

- Обновлены `.agents/skills/ios-testing/SKILL.md`, `.agents/skills/ios-debugging/SKILL.md` и `docs/development/verification.md`: автоматические наборы только в `local`; диагностика симулятора — `local`/`test`, iPhone — `test`; local API `/health` и настроенный Web требуют HTTP 200; unit не зависит от сети.
- В instructions для тестирования оставлены один финальный `all`, выборочный `--only` для локальной диагностики падений и ограниченный `--skip-build` повтор только по требованию задачи. Уточнены правила единой подписанной сборки и отсутствие повторного запуска отдельных наборов после успешного `all`.
- Исторические local/test и 404 результаты в `verification.md` и отчёте Task 4 помечены как результаты прежнего контракта. Исторические результаты не переписывались.
- После получения доказательств создан долговременный отчёт [local-test-stability-verification.md](../../../docs/development/local-test-stability-verification.md).
- До Task 5 изменений ветка `fix/local-test-stability` находилась на commit `e8d7e3f793131e2ef79525a258b0c284cd2e40e0`; полный прогон и повтор выполнены на нём. Commit Task 5 содержит только документацию/отчёт.
- Commit Task 5: `4c166a1859ea398fa67e1689377c701d3415cea7` (`docs: align iOS testing and diagnostics guidance`).
- Последующее уточнение матрицы диагностики `test` на симуляторе и iPhone: `09a5acbc09d44083cffa80a74f66b304eaef1878` (`docs: clarify testing simulator diagnostics`).

## Проверки

- `python3 -m unittest discover -s scripts/tests` — **54/54 passed**. Первый вызов в sandbox не смог открыть loopback-сокет в тесте redirect-preflight; повтор той же команды с разрешённым loopback завершился успешно.
- `python3 scripts/zdeep.py preflight --environment local --suite all` — успешно, настроенные API `/health` и Web вернули HTTP 200.
- `python3 scripts/zdeep.py test --environment local --suite all --simulator 0DDEE416-EECF-4BF3-8F15-BA93A980033A` — успешно. Xcode 27.0, build 27A266a; iPhone 18 Pro Simulator, iOS 27.0. `Passed`, 257/257: unit 205, integration 30, UI 22; 0 failures, 0 unexpected failures, 0 skips, runtime warnings 0. Bundle: `.artifacts/runs/20261010-054215-1791600135635649000/Tests.xcresult`.
- `python3 scripts/zdeep.py test --environment local --suite all --simulator 0DDEE416-EECF-4BF3-8F15-BA93A980033A --skip-build` — успешно на той же сборке через `xcodebuild test-without-building`, без `build-for-testing`. Новый bundle, тот же состав и результат 257/257. Bundle: `.artifacts/runs/20261010-054815-1791600495080249000/Tests.xcresult`.
- CLI `test --help` и `preflight --help` показывают только `--environment {local}`. Тестовые сети в `test` не запускались.
- Прочитаны обе завершённые сводки `.xcresult` и test trees. Оба показали Passed, по 257 тестов, 0 failures, 0 skips; состав совпал.
- До любого действия на физическом телефоне выполнена только read-only команда `python3 scripts/zdeep.py logs --target device --device 00008101-001A25963AC2001E`. CoreDevice вернул error 4000 и `Connection reset by peer`; дальнейшие device-команды не запускались. Физический Debug запуск и mailbox `1+1` остаются неподтверждёнными.

## Самопроверка

- `git diff --check` прошёл.
- Поиск в актуальных instructions не выявляет рекомендаций автоматического `test`-прогона или принятия реального HTTP 404. Найденные старые `test`/404 команды находятся в сохранённых исторических блоках с явной пометкой о замене контракта. `device-launch --environment test` остаётся в диагностических инструкциях.
- Использован только короткий статический контрактный и search check, требуемый брифом для обновления project-local skills; новый skill, reusable harness или тестовый suite не добавлялись.
- После полного `all` и `--skip-build` правился только текст документов. Полные тесты после этих текстовых правок повторно не запускались.

## Ограничения

- Физический iPhone числился paired/available при перечислении устройств, но CoreDevice-соединение сбросилось до чтения журналов. Поэтому физическое приложение не запускалось, WebView вручную не открывалась, а `1+1` не выполнялся. Это ограничение устройства/транспорта, а не успешная физическая проверка.
- Оба финальных `.xcresult` сохранены. После report commit и проверки процессов удалён только принадлежащий этим прогонам build-каталог `.artifacts/builds/5c3f766237ac88304861f75a2dfa91e0345d828427a44e59f5c5061ce866fccf` (244 MB); в каталоги соседних задач и остальные bundles/builds изменений не вносилось.

## Фокусная допроверка после финального ревью

После полного `all` и `--skip-build` на commit `e8d7e3f793131e2ef79525a258b0c284cd2e40e0` ревью обнаружило один пропуск в bridge smoke: `test_public_reload_reinjects_bridge_for_a_new_document()` загружал статический `AppEnvironment.local.endpoints.web`. Исправление использует общий `LaunchConfiguration` endpoint suite и проверяет `session.requestedURL == endpoints.web`.

Сначала запуск с shell-переменными не создал RED: CLI `test` берёт URL из `.local/development.json` и подменил shell env настройками по умолчанию. Этот запуск не считается доказательством. Затем использовался временный `.local/development.json` с Web `http://127.0.0.1:4005` и API `http://127.0.0.1:4002`; strict local preflight подтвердил HTTP 200 для API `/health` и Web. RED-команда:

```sh
python3 scripts/zdeep.py test --environment local --suite integration --only 'WebSessionIntegrationTests/test_public_reload_reinjects_bridge_for_a_new_document()' --simulator 0DDEE416-EECF-4BF3-8F15-BA93A980033A
```

Assertion упала: `session.requestedURL` было `http://localhost:4005`, ожидаемый настроенный URL — `http://127.0.0.1:4005`. Bundle: `.artifacts/runs/20261010-061131-1791601891279429000/Tests.xcresult`.

После исправления та же команда с теми же overrides завершилась успешно: 1/1 passed; preflight снова подтвердил HTTP 200. Bundle: `.artifacts/runs/20261010-061244-1791601964219274000/Tests.xcresult`. Временный `.local/development.json` удалён. Полный suite не перезапускался: финальные полные bundles относятся к предыдущему test commit `e8d7e3f`; этот единственный изменённый callsite проверен целевым integration selector.

Финальный review также подтвердил отложенное не блокирующее замечание Minor P3 из Task 2: `scripts/zdeep_tools/preflight.py:17` сравнивает origin без нормализации явного default port (`http://host` и `http://host:80`). Его оставили вне этой узкой правки; reviewer отметил отсутствие внешнего запроса/влияния на безопасность.
