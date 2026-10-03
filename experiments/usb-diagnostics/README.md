# USB-диагностика: результаты эксперимента

Дата: 2 октября 2026 года. Эксперимент проверял доступ к приложению и app-data container на iPhone, а также запуск JavaScript в test WebView через одноразовый Debug harness. Постоянный transport не добавлялся. Код harness удалён из `ContentView.swift`; коммит не создавался.

## Устройство и Debug-сборка

- Физическое устройство: iPhone 12 mini, UDID `00008101-001A25963AC2001E`, iOS 26.7.1.
- `devicectl device info details` показал pairing state `paired`, device state `connected`, Developer Mode включён. При этом CoreDevice сообщал `Transport Type: localNetwork`, хотя телефон был подключён по кабелю.
- `devicectl device info lockState` сообщил `unlockedSinceBoot: true`. Первый запуск был отклонён с `FBSOpenApplicationServiceErrorDomain`, `BSErrorCodeDescription = Locked`; screenshot показал домашний экран. Повторный запуск прошёл.
- Физическая Debug-сборка прошла с identity `Apple Development: legik-soft-stydio@yandex.ru` и provisioning profile `iOS Team Provisioning Profile: ru.zdeep.mobile`.

Команда сборки:

```sh
xcodebuild -project ZDEEP/ZDEEP.xcodeproj -scheme ZDEEP -configuration Debug \
  -destination 'id=00008101-001A25963AC2001E' \
  -derivedDataPath .artifacts/usb-device-derived build
```

Установка завершилась `App installed` для `ru.zdeep.mobile`. Обычный запуск в test:

```sh
xcrun devicectl device process launch \
  --device 00008101-001A25963AC2001E \
  --environment-variables '{"ZDEEP_ENVIRONMENT":"test"}' \
  --terminate-existing ru.zdeep.mobile
```

Команда вывела `Launched application with ru.zdeep.mobile bundle identifier`. Экран показал test URL `https://5e9afe68-2ddd-4e58-8e57-5942cfa16099.website.twcstorage.ru` и test API `https://api.zdeep.ru/testing/`. Ни приложение, ни тесты не открывали production.

## UI test на физическом iPhone

Попытка запуска `testTestEnvironmentWelcomeScreenDoesNotLoadWebUntilOpened` через Xcode не дошла до теста: сборка UI runner остановилась с ошибкой подписи:

```text
No profiles for 'ru.zdeep.ZDEEPUITests.xctrunner' were found:
Xcode couldn't find any iOS App Development provisioning profiles matching
'ru.zdeep.ZDEEPUITests.xctrunner'. Automatic signing is disabled and unable
to generate a profile. To enable automatic signing, pass -allowProvisioningUpdates.
```

Соответственно, физическое открытие WebView выполнялось отдельным временным DEBUG launch harness. Screenshot `.artifacts/usb-mailbox-webview.png` показывает, что test WebView открылся и загрузил тестовый сайт. Сайт отображал бизнесовое сообщение `Приложение недоступно / Не удалось получить доступ к данным автомобиля`; проверка авторизации не входила в эксперимент.

## App-data copy и mailbox

Проверен двусторонний `devicectl device copy` в `appDataContainer` приложения `ru.zdeep.mobile`. Тестовый файл вернулся без изменений:

```sh
xcrun devicectl device copy to --device 00008101-001A25963AC2001E \
  --source .artifacts/usb-mailbox-probe.json \
  --destination Library/Caches/ZdeepDiagnostics/inbox/probe-001.json \
  --domain-type appDataContainer --domain-identifier ru.zdeep.mobile

xcrun devicectl device copy from --device 00008101-001A25963AC2001E \
  --source Library/Caches/ZdeepDiagnostics/inbox/probe-001.json \
  --destination .artifacts/usb-mailbox-roundtrip.json \
  --domain-type appDataContainer --domain-identifier ru.zdeep.mobile
```

Обе команды завершились успешно; round-trip вернул `{"probe":"usb-copy","id":"probe-001"}`.

Временный reader работал только в Debug при `ZDEEP_USB_MAILBOX_EXPERIMENT=1` и `ZDEEP_ENVIRONMENT=test`. Он открывал test WebView, читал JSON-команду, вызывал существующий `WebSession.executeJavaScript`, а ответ записывал атомарно в app-data `outbox`. Чтобы избежать чтения незавершённой передачи, проверялась двухфазная публикация: сначала `<id>.uploading`, после успешного `copy to` — отдельный пустой `<id>.ready` marker.

Результаты команд:

- Первая команда `1 + 1` с прямой передачей `.json` была исполнена, ответ удалось получить, но сам `copy to` завершился `CoreDeviceError 7000: Failed to retrieve the file node`: reader успел удалить входной файл во время передачи. Это выявило гонку прямого чтения и копирования.
- Повтор `1 + 1` через `.uploading` и отдельный `.ready` прошёл: оба `copy to` завершились успешно, `copy from` завершился успешно и вернул `{"ok":true,"id":"00000000-0000-4000-8000-000000000004","result":2}`. Консоль приложения подтвердила `USB_MAILBOX_RESPONSE ...0004 ok`.
- JavaScript-команда с `throw new Error("usb mailbox deliberate error")` и её `.ready` marker были скопированы успешно. Ответа в `outbox` не появилось; попытка `copy from .../outbox/00000000-0000-4000-8000-000000000005.json` вернула `CoreDeviceError 7000: Failed to retrieve the file node`. `devicectl device info files` показал, что `.uploading` и `.ready` остались во `inbox`; stdout содержал только `USB_MAILBOX_READY` и успешный ответ для id 4. Причина, по которой reader не закончил эту команду, не установлена.
- Проверка JS DOM event (`CustomEvent`, listener и возврат `event.detail`) не запускалась после неудачи error-команды и ограничения числа попыток.

Следовательно, физически подтверждены app-data round-trip и выполнение/ответ для JavaScript `1 + 1`. Надёжность JS error path и получение DOM event на устройстве пока не подтверждены. Для продолжения нужен диагностируемый reader (логирование стадий read/evaluate/write и жизненного цикла задачи) с двухфазной публикацией; альтернативный путь — подготовить provisioning profile для `ru.zdeep.ZDEEPUITests.xctrunner` и выполнять проверки через UI/XCTest runner на устройстве.

## Симуляторные проверки

Симулятор iPhone 18 Pro: UDID `0DDEE416-EECF-4BF3-8F15-BA93A980033A`.

Local:

```sh
python3 scripts/zdeep.py test --environment local --suite all \
  --simulator 0DDEE416-EECF-4BF3-8F15-BA93A980033A
```

Результат: `TEST EXECUTE SUCCEEDED`, 32 теста (29 unit/integration и 3 UI), 0 failures. Local API preflight: `/health` HTTP 200. xcresult: `.artifacts/runs/20261002-181250-1790953970537005000/Tests.xcresult`.

Test:

```sh
python3 scripts/zdeep.py test --environment test --suite all \
  --simulator 0DDEE416-EECF-4BF3-8F15-BA93A980033A
```

Результат: `TEST EXECUTE SUCCEEDED`, 32 теста, 0 failures. Test API preflight ответил HTTP 404; preflight считает это доступным ответом, поскольку отклоняет только HTTP 5xx. xcresult: `.artifacts/runs/20261002-181435-1790954075954337000/Tests.xcresult`.

В обоих наборах прошёл существующий unit test `test_timeout_records_last_value()`. Отдельный тест с физически отключённым Wi-Fi не выполнялся; network-offline режим этим результатом не подтверждён.

## Очистка эксперимента

Временный `ContentView.swift` diff удалён и проверен как пустой; запущенных `xcodebuild`, `devicectl process launch` или `simctl diagnose` процессов после прерывания console-сеанса нет. Последний временный Debug build на устройстве был остановлен сигналом 2; его бинарник остался установленным, но harness требует явной пары launch-переменных выше. Код в исходниках восстановлен, коммитов по эксперименту нет. Рабочие изменения в `ZDEEP.xcodeproj/project.pbxproj`, design spec и plan не затрагивались.

## Task 5: постоянный mailbox (3 октября 2026 года)

Добавлен Debug-only polling reader в `ZDEEP/ZDEEP/Debug/DiagnosticMailbox.swift`. Reader подключается только после явного `ZDEEP_USB_DIAGNOSTICS=1`; для iPhone он разрешён только в `test`, для симулятора — в `local`/`test`. Его жизненный цикл совпадает с активной `WebSession`. Обычный старт приложения и `device-launch` оставляют WebView закрытой. Только явная команда `diagnose --target simulator` может добавить отдельный DEBUG/simulator-only аргумент `--usb-diagnostics-open-webview`, если нет свежей handshake-записи нужного окружения. Физический WebView остаётся user-opened. Команда публикуется в два этапа (`<uuid>.uploading`, затем `<uuid>.ready`), ответ атомарно появляется в `outbox`, а файлы удаляются после скопированного и опубликованного acknowledgement.

### Проверка на физическом iPhone

Устройство: iPhone 12 mini `00008101-001A25963AC2001E`; app `ru.zdeep.mobile`; только `test`. Сборка и установка текущего Debug приложения завершились успешно. Первый запуск после установки был отклонён SpringBoard с причиной `Locked`, хотя `device info lockState` показывал `unlockedSinceBoot: true`. После ручной разблокировки повторный запуск прошёл. Пользователь вручную открыл WebView; запуск приложения не открывает страницу автоматически.

Три последовательные операции прошли в одной сессии `c190f2d0-b70e-4b40-b545-e6851f2b3bb2`:

| JavaScript | Ответ |
| --- | --- |
| `1 + 1` | `ok: true`, `result: 2` |
| `throw new Error("usb mailbox deliberate error")` | `ok: false`, `JavaScriptError`, сообщение включает `usb mailbox deliberate error` |
| синхронный `CustomEvent` listener/dispatch | `ok: true`, `result: {"ok":true,"source":"usb-mailbox"}` |

`python3 scripts/zdeep.py logs --target device --device 00008101-001A25963AC2001E` показал пары `usb.command.completed`/`usb.command.acknowledged` для UUID `3ebc2ac3-ad46-4f6e-8de2-0b5946858adc`, `b52c98af-6b19-475f-921f-a936b150c45d`, `0220234b-4a94-473f-bf9e-e949c37bfc34`. Для второго запроса журнал показал `usb.command.failed`, затем acknowledgement. Журнал содержит только категории и UUID, без исходного JS или результата. Запись acknowledgement следует после удаления mailbox файлов.

Команда с несуществующим ID `unavailable-device` завершилась немедленной ошибкой `CoreDeviceError 1000: The specified device was not found`; физический телефон при этом не отключался.

После подтверждения пользователя, что Wi-Fi выключен и USB-кабель подключён, `devicectl list devices` показал iPhone как `connected`, а `device info details` — `Transport Type: wired` и TCP tunnel. Первая CLI попытка успешно скопировала `inbox/a0b99a30-018c-495e-b0af-4724d81f4407.uploading` и отдельный `.ready`. Тело содержало корректный UUID, ожидаемый session ID `c190f2d0-b70e-4b40-b545-e6851f2b3bb2`, неистёкший deadline и JS `1+1`. Ответа в outbox и события UUID в журнале не было; `device info processes` не обнаружил `ru.zdeep.mobile`.

После того как пользователь оставил приложение на переднем плане, CoreDevice снова работал по `wired`, процесс приложения появился, а read-only screenshot подтвердил открытый test WebView с сообщением о недоступности интернета. Одна разрешённая повторная команда скопировала request `4ca14711-bd1d-4cdc-813d-5e2a4f117e5e` и `.ready`, но ответа и acknowledgement не появилось. Проверка handshake и журнала установила причину: видимый app process был запущен без `ZDEEP_USB_DIAGNOSTICS=1`; его свежая WebSession имела ID `A216487C-50FC-4D09-A174-5A60E9A77CE9`, а handshake всё ещё ссылался на прежнюю сессию `c190f2d0-b70e-4b40-b545-e6851f2b3bb2`. В журнале для обоих wired request UUID нет событий `usb.command.*`. Поэтому подтверждены wired CoreDevice file copy и открытый offline test WebView, но не выполнение JS без Wi-Fi: reader не был включён в текущем процессе. Других запусков и команд после единственного повтора не делали.

### Симулятор, проверки и ограничения

- `diagnose --target simulator --environment local --js-file .artifacts/task5-diagnostic-smoke.js` опубликовал WebView через явную diagnostic-only launch опцию, дождался mailbox-ответа `result: 2` (request `cb68140e-eff2-484c-832e-0264abee7e00`, session `857235be-06c3-43bb-9ac8-d76cd4aa3568`). Preflight API `/health` вернул HTTP 200.
- Аналогичная команда для `test` вернула `result: 2` (request `479a8d55-ad98-438e-9c1e-bfc018f5259e`, session `bfd5c2f8-cd8b-431b-9ab2-a6fd71812689`). Это подтверждает полный симуляторный copy-in/out mailbox path для обоих разрешённых окружений с file input, не передающим исходный JS в argv. Открытие страницы было явным действием CLI; обычный пользовательский welcome flow остался ленивым.
- Финальный Xcode `suite all` после исправлений review прошёл для local и test на симуляторе `0DDEE416-EECF-4BF3-8F15-BA93A980033A`: по 53 теста, 0 failures. Local xcresult `.artifacts/runs/20261003-095215-1791010335476952000/Tests.xcresult`; test xcresult `.artifacts/runs/20261003-095500-1791010500982585000/Tests.xcresult`.
- Python suite после исправлений review прошёл 28/28; `python3 -m compileall -q scripts/zdeep.py scripts/zdeep_tools scripts/tests` завершился без ошибок. Local API `/health` вернул HTTP 200; test API ответил HTTP 404 и считается доступным сервисом.
- Перед отправкой команды CLI теперь требует свежий handshake с UUID сессии, выбранным окружением и актуальным `updatedAt`; это отсекает оставшиеся файлы закрытой или запущенной без opt-in сессии.
- UUID обработанных команд хранятся до завершения WebSession, а устройство удаляет mailbox файлы только при наличии response JSON и совпадающего acknowledgement payload.
- CLI поддерживает `--js-file` и `--js-stdin`, чтобы исходный код не передавался в argv и shell history. `--js` оставлен для коротких несекретных выражений и может попасть в shell history/process listing.
- XCTest runner для физического iPhone по-прежнему не подписывается: отсутствует provisioning profile `ru.zdeep.ZDEEPUITests.xctrunner`. Signing team/profile не менялись.
- Предыдущий одноразовый harness не объяснил потерю error-команды. Постоянный reader прошёл отдельные физические проверки JS success, exception и DOM event; прежняя ошибка не воспроизвелась.
- После финальных mailbox исправлений повторно собран Release для iOS Simulator без запуска приложения. `nm -a` не нашёл символы `DiagnosticMailbox`, `USB_DIAGNOSTICS` или `usb.command`; `strings` не нашёл mailbox/launch-flag строки.
