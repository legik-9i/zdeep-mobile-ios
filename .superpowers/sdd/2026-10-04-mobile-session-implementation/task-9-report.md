# Task 9 — staged startup и подготовка WebSession

Выполнено по принятому brief и плану. Изменён только компонент Task 9; Task 10 не начинал. `progress.md` и `task-7-report.md` принадлежат контроллеру и в commit не включать.

## Реализация

- Hosted passive-host флаг включается только для target `ZDEEPTests.xctest` в обоих форматах `.xctestrun`; существующие `EnvironmentVariables` сохраняются, UI target флаг не получает. Для `all` сохраняется этот же target scope.
- `ZDEEPApp` выбирает passive hosted-test root, DEBUG+Simulator UI fixture или production `AppRootView` до создания production coordinator. Пустая fixture использует debug-only empty binding store и не подменяет бизнесовую авторизацию.
- Координатор начинает с native logo, отображает результат restore, запускает auth независимо от первого кадра, а WKWebView создаёт только после frame callback для актуального scenario и active scene. Для restore error WebSession не создаётся.
- WebSession создаётся один раз; bridge и diagnostic mailbox подключаются до `load`. `acceptWebReady` требует active scene, текущий scenario, совпадающие текущий WebSession/document identity, зарегистрированную binding и действующую сессию. Reveal сохраняет тот же instance без reload.
- Пока нет accepted-ready, WebView остаётся скрытым, исключённым из взаимодействия и accessibility. Legacy diagnostic open flag подготавливает сессию, но не раскрывает бизнесовый WebView. В DebugPanel JavaScript выключен до reveal.
- Добавлены one-shot `FirstFrameProbe` и fakeable `BackgroundExecution`, включая общую активность scheduled refresh и bridge recovery, сбалансированные begin/end и запрет нового background task после expiration до foreground.
- UI, DebugPanel, DiagnosticMailbox, coordinator и WebSession reset tests переведены на staged startup и prepared-vs-visible состояние. JS, JS error/value, stale document, late reply и mailbox/bridge проверки остаются в serialized WebSession integration/Bridge suites с fixture documents; UI tests не создают фиктивную авторизацию.

## RED → GREEN

### Passive hosted-test flag

Добавлены Python-тесты обоих `.xctestrun` форматов, `all`, сохранения окружения и app-entry ветвления. До реализации `python3 -m unittest discover -s scripts/tests` показал ожидаемые 3 ошибки: UI target получал passive flag в двух форматах, app entry не выбирал passive branch до создания root. После реализации вся Python suite прошла.

### Coordinator и reveal

`test_restore_error_starts_no_webview` сначала падал на двух assertions после native frame: создавался WebSession и `isWebPrepared` становился true. Bundle RED неполный и не является test-run результатом: `.artifacts/runs/20261005-061402-1791170042294068000/Tests.xcresult`. После запрета подготовки для restore error focused GREEN: `.artifacts/runs/20261005-061802-1791170282307942000/Tests.xcresult`.

`test_web_reveal_keeps_the_prepared_session_instance` добавлен до production API; RED был compile-time: `webSessionDidEmit` недоступен тесту, не было `acceptWebReady` и идентификатора подготовленного instance. После минимального API и проверки ready focused GREEN: `CoordinatorTests/test_web_reveal_keeps_the_prepared_session_instance()` — 1/1, `.artifacts/runs/20261005-063451-1791171291389902000/Tests.xcresult`. Assertion подтверждает один вызов factory и прежний ID после reveal.

### Prepared WebView UI

Первый полный UI-прогон выявил, что legacy DebugPanel helper закрывал панель до чтения `webview-state`; также старые проверки предполагали debug reveal без accepted-ready. UI assertions обновлены так, чтобы читать state пока панель открыта, проверять существующий, но non-hittable WebView и сохранение welcome. JavaScript control теперь выключен до accepted-ready.

Перед production gating focused UI `test_preparedWebviewDisablesJavaScriptUntilReady` подтвердил RED: execute-кнопка оставалась включённой. В одном промежуточном focused bundle после исправления helper оставалась одна ошибка: кнопка запрашивалась до прокрутки; это был UI visibility assertion, не ошибка ready state. Bundle: `.artifacts/runs/20261005-064749-1791172069182897000/Tests.xcresult` (4/5; не считать итогом). После прокрутки focused DebugPanel class bundle: `.artifacts/runs/20261005-065131-1791172291377357000/Tests.xcresult`, 5/5 passed. Обёртка вернула код 1 только потому, что `--only 'DebugPanelUITests'` требует ровно один node ID; xcresult подтверждает все пять тестов passed.

Focused UI подтверждение welcome + hidden prepared WebView: `ZDEEPUITests/testLocalEnvironmentWelcomeRemainsVisibleWithPreparedHiddenWeb()` — 1/1, `.artifacts/runs/20261005-063523-1791171323602125000/Tests.xcresult`.

## Полные проверки

Все запуски были только на iPhone 18 Pro Simulator `0DDEE416-EECF-4BF3-8F15-BA93A980033A` и с `--environment local`. Test/prod и физические устройства не запускались.

| Команда | Результат | Bundle |
|---|---:|---|
| `python3 scripts/zdeep.py test --environment local --suite unit --simulator 0DDEE416-EECF-4BF3-8F15-BA93A980033A` | 144/144 | `.artifacts/runs/20261005-065932-1791172772687844000/Tests.xcresult` |
| `python3 scripts/zdeep.py test --environment local --suite ui --simulator 0DDEE416-EECF-4BF3-8F15-BA93A980033A` | 18/18 | `.artifacts/runs/20261005-065317-1791172397900087000/Tests.xcresult` |
| `python3 scripts/zdeep.py test --environment local --suite integration --simulator 0DDEE416-EECF-4BF3-8F15-BA93A980033A` | 25/25 | `.artifacts/runs/20261005-065758-1791172678230233000/Tests.xcresult` |
| `python3 scripts/zdeep.py test --environment local --suite all --simulator 0DDEE416-EECF-4BF3-8F15-BA93A980033A` | 187/187 | `.artifacts/runs/20261005-070022-1791172822853629000/Tests.xcresult` |
| `python3 -m unittest discover -s scripts/tests` | 34/34 | — |
| `git diff --check` | PASS | — |

`all` result summary подтверждён xcresulttool: `Passed`, 187 total, 187 passed, 0 failed, 0 skipped. Local preflight `/health` ответил HTTP 200.

## Неполные промежуточные bundle

Ниже не результаты прохождения. В каждом случае xcodebuild напечатал тестовый вывод, но завис на завершении до создания `Info.plist`; остановлен только соответствующий tool session ID через Ctrl-C согласно ios-testing.

- `.artifacts/runs/20261005-061024-1791169824042737000/Tests.xcresult` и `.artifacts/runs/20261005-061402-1791170042294068000/Tests.xcresult` — ранние interrupted coordinator runs; RED из второго описан выше.
- `.artifacts/runs/20261005-061925-1791170365101821000/Tests.xcresult` — ранний UI run до isolated empty-binding launch fixture.
- `.artifacts/runs/20261005-063635-1791171395981127000/Tests.xcresult` — диагностический полный UI run со старыми assertions; xcodebuild успел напечатать 18 тестов/13 failures, затем завис до bundle metadata. Не считать полным suite result.
- `.artifacts/runs/20261005-064543-1791171943540943000/Tests.xcresult` — focused UI RED до disabled gating; assertion ожидала неактивную кнопку, затем process завис на финализации. Не считать завершённым bundle.

Токены и тела auth-запросов в отчёт/исходники не включались. Fixture значения синтетические.
