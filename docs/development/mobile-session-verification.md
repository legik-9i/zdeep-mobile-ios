# Приёмка mobile session на Simulator

Дата: 2026-10-05. Базовый commit перед Task13: `b602b5f`.

## Локальная среда и безопасность

- Environment: `local`.
- Backend: `http://localhost:4002`; использованы `/health`, `/get-tmp-test-car-token`, `/auth/mobile/pair` и `/auth/mobile/token`.
- WebView: `http://localhost:4005`.
- Simulator: iPhone 18 Pro, iOS Simulator 27.0, UDID `0DDEE416-EECF-4BF3-8F15-BA93A980033A`.
- Реальная регистрация получала свежий временный `carToken` перед каждым из двух независимых pair запросов. Значение оставалось в памяти; token, QR URL, тело запроса и access token в исходники, журналы, скриншоты и этот отчёт не попали.
- Тестовые HTTP-ответы обслуживал отдельный ephemeral loopback `NWListener`. Запросы в test/prod окружения и физический iPhone не использовались.
- Временный Keychain service, binding key и install-marker файлы теста удаляются через `defer`. Backend может сохранить созданные локальные регистрации согласно процедуре `local-auth-test-data.md`; приложение не хранит их ключи после завершения теста.

## Полный запуск

Команда:

```sh
python3 scripts/zdeep.py test --environment local --suite all --simulator 0DDEE416-EECF-4BF3-8F15-BA93A980033A
```

Завершённый результат на финальном исходнике: `.artifacts/runs/20261005-175918-1791212358542160000/Tests.xcresult`.

`xcresulttool get test-results summary` подтвердил `Passed`, 254 теста, 0 failures, 0 skipped. Состав: unit — 203, integration — 29, UI — 22. Прогон завершился успешно примерно за 290 секунд. В нём присутствует финальная offline-проверка loopback HTTP test.

## Добавленные и переиспользованные сценарии

- `test_local_binding_to_real_web_ready`: настоящий `BindingStore`, `AuthClient`, `SessionManager`, `AppCoordinator`, QR parser, bridge и WebView обращаются только к local backend/web. Проверяются `carId`, успешный `getSession` bridge reply, commit/reveal одного `WKWebView` и отсутствие Welcome при восстановлении `RegisteredBinding`.
- В том же сквозном сценарии выполнен local rebind со вторым свежим временным токеном. Новые `bindingId`, P-256 certificate и WebView container отличаются от первой привязки.
- `test_local_ordinary_binding_reset_preserves_observed_web_data` записывает уникальные cookie и `localStorage` значения, выполняет обычный binding reset и подтверждает сохранение именно этих значений; test fixture удаляет только собственные ключ и cookie.
- `test_local_http_auth_failure_retry_and_invalid_response` использует реальный `URLSessionAuthHTTPTransport` против loopback fixture: HTTP 403 с неизвестным кодом, явный повтор с HTTP 200, malformed HTTP 200 и отключение fixture для offline ошибки. Счётчик принятых запросов проверяет отсутствие автоматического повтора.
- Persistent website data при полном reset проверяет существующий Task12 integration test `test_full_reset_clears_web_cookie_and_local_storage`; отдельная копия fixture не добавлялась.
- Остальные failure/recovery условия закрыты уже существующими FakeClock/fake dependency проверками: HTTP 401/403, malformed responses, virtual 30-second timeout и redirect — `AuthClientTests`; cancel на save и до reveal — `CoordinatorTests`; session expiry, 401 recovery и retry scheduling — `SessionRefreshTests` и `WebSessionIntegrationTests+Bridge`. Реальное ожидание истечения 15 минут не использовалось.

Focused результаты:

| Проверка | Результат | xcresult |
| --- | ---: | --- |
| Реальный pair → bridge → local web → rebind | 1/1 PASS | `.artifacts/runs/20261005-133256-1791196376108142000/Tests.xcresult` |
| Сохранение наблюдаемых cookie/localStorage при обычном reset | 1/1 PASS | `.artifacts/runs/20261005-132900-1791196140675503000/Tests.xcresult` |
| Loopback HTTP 403 → retry → malformed response | 1/1 PASS | `.artifacts/runs/20261005-133227-1791196347418679000/Tests.xcresult` |
| Тот же HTTP test с offline assertion | 1/1 PASS | `.artifacts/runs/20261005-172447-1791210287926317000/Tests.xcresult` |
| Authorization UI и error screenshot | 1/1 PASS | `.artifacts/runs/20261005-133337-1791196417340963000/Tests.xcresult` |

Более ранний повтор `--suite all` после временного добавления Welcome screenshot attachment вызвал аномалию XCTest: UI `waitForExistence` шаги показывали около 900 секунд каждый. Дополнительный screenshot вызов был удалён из тестового исходника. Повторный полный suite на финальном исходнике завершился штатно и подтвердил все 254 теста.

## Скриншоты

Снимки экспортированы из успешного focused UI xcresult и визуально проверены. Welcome screenshot получен из UI test fixture; camera error — нативный экран запрета камеры. В Welcome кадре виден debug UI test счётчик.

![Welcome и брендовый экран](../../.artifacts/verification-screenshots/C15F5F0B-8CF6-4AEA-B796-C232274AECAE.png)

![Нативная ошибка разрешения камеры](../../.artifacts/verification-screenshots/E9E376B7-BA7F-48D8-91E6-5305B2D53802.png)

Файлы также сохранены в `.artifacts/verification-screenshots/`; исходный attachment bundle: `.artifacts/runs/20261005-134521-1791197121886629000/Tests.xcresult`.

## Release Simulator build

```sh
xcodebuild -project ZDEEP/ZDEEP.xcodeproj -scheme ZDEEP -configuration Release -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath .artifacts/release-check CODE_SIGNING_ALLOWED=NO build
```

Сборка завершилась `BUILD SUCCEEDED` в `.artifacts/release-check/Build/Products/Release-iphonesimulator/ZDEEP.app`. Приложение не запускалось. В binary присутствуют маркеры business bridge (`window.ZdeepNative`, `recoverUnauthorized`); `nm` и `strings` не нашли `DiagnosticExecutor`, `DebugPanel` или `DiagnosticMailbox`.

`python3 -m unittest discover -s scripts/tests` не запускался: скрипты не менялись. Камера проверялась через Simulator fixtures; реальная камера и поведение настоящего фонового режима этим прогоном не подтверждаются.
