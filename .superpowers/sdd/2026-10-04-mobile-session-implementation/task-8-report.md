# Task 8 — native status screens and branding

## Реализация

- Добавлены `StartupLogoView`, `NativeLoadingView`, `NativeErrorView` и `CameraPermissionView`. Экраны принимают состояние и callbacks, не выполняют auth, reset или запрос разрешений.
- Экран ошибки выводит русское сообщение, ограниченный 15 символами диагностический код, первые 8 hex-символов ID попытки, HTTP status и версию приложения. Действия строятся из `NativeErrorPresentation`; reset/rebind запрашивают подтверждение с принятым текстом.
- UI-test fixture включается только для DEBUG Simulator сборки с явным `--ui-test-presentation` и показывает синтетические данные, не создавая `AppCoordinator` и не обращаясь к API/ключам.
- Добавлены прозрачный `StartupLogo` asset, светлый `NativeBackground`, статический `LaunchScreen.storyboard`, утверждённый непрозрачный AppIcon и официальные JetBrains Mono Regular/Medium с OFL. Info.plist регистрирует шрифты и launch storyboard.
- Welcome UI test переведён на `--environment local`, assertion главного welcome заголовка сохранён, WebView до явного открытия не запускается.
- Скриншот native error UI: `.artifacts/native-error-screen.png`. Визуально сверен с сохранённым `docs/design/assets/native-error/error-screen.html`: фон, вертикальная композиция, интервалы и типографика соответствуют принятым значениям.

## TDD и проверки

Ожидаемый RED до реализации: focused UI test для initial registration не находил `Ошибка подключения`, так как launch flag ещё не подключал fixture. Результат: `.artifacts/runs/20261005-045738-1791165458169533000/Tests.xcresult`.

Focused GREEN smoke:

```text
python3 scripts/zdeep.py test --environment local --suite ui --only 'NativePresentationUITests/test_initialRegistrationError_exposesOnlyStartOver()' --simulator 0DDEE416-EECF-4BF3-8F15-BA93A980033A
1 test, 0 failures
```

Все новые UI-сценарии:

```text
python3 scripts/zdeep.py test --environment local --suite ui --only NativePresentationUITests --simulator 0DDEE416-EECF-4BF3-8F15-BA93A980033A
NativePresentationUITests: 6 tests, 0 failures; xcodebuild TEST EXECUTE SUCCEEDED
```

Wrapper не распознал имя класса `NativePresentationUITests` как ровно один test selection и сообщил об ошибке разбора результата после успешного выполнения suite. Полный UI suite ниже выполнен без фильтра и завершился штатно.

Полный UI suite:

```text
python3 scripts/zdeep.py test --environment local --suite ui --simulator 0DDEE416-EECF-4BF3-8F15-BA93A980033A
17 tests, 0 failures; TEST EXECUTE SUCCEEDED
```

Полный unit suite:

```text
python3 scripts/zdeep.py test --environment local --suite unit --simulator 0DDEE416-EECF-4BF3-8F15-BA93A980033A
131 tests in 20 suites, 0 failures; TEST EXECUTE SUCCEEDED
```

Все UI команды использовали `--environment local`. Включая тест welcome, ни один тест/prod endpoint не запускался.

Проверка AppIcon подтвердила размер 1024×1024, RGB без alpha и пиксельное совпадение RGB с одобренным белым источником `ZDEEP_Mobile_1024_white.png`. Info.plist содержит `UILaunchStoryboardName = LaunchScreen` и JetBrains Mono Regular/Medium в `UIAppFonts`.

## Передача

Реализация готова к scoped Sol review. `progress.md` не изменялся. Commit будет сделан после одобрения ревью.

## Sol review round 1 — исправления

Обновление по замечаниям Sol:

1. Диагностическая строка теперь формируется как `Код: NT · <diagnosticCode, до 15 символов> · <первые 8 заглавных hex-символов attemptId>`. `serverCode` не подменяет `diagnosticCode`; HTTP status и app version выводятся отдельными переносимыми строками.
2. Экран использует `NativeErrorPresentation.userExplanation`, а не `AuthFailure.message`. Добавлена русская таблица для всех известных серверных кодов из принятой спецификации; полный `serverCode` добавляется без сокращения. Неизвестный код выводится рядом с общим русским объяснением. При отсутствующем серверном коде используется общее русское объяснение с HTTP status. Текст тела ответа не выводится.
3. Diagnostic line, status и version разнесены по вертикальным строкам с Dynamic Type. UI-тест при XXXL проверяет содержимое и hittable-состояние этих полей, а также доступность действий.
4. Действие reset переименовано в «Сбросить авторизацию».

RED round 1: focused registered error UI test ожидал русское сообщение для `CAR_ACCESS_DENIED`, но старая реализация отображала синтетический сырой текст. xcresult: `.artifacts/runs/20261005-052112-1791166872941477000/Tests.xcresult`.

Focused GREEN результаты:

- registered known code + diagnostic/status fields: 1/1, `.artifacts/runs/20261005-053040-1791167440262931000/Tests.xcresult`;
- Dynamic Type XXXL metadata/action reachability + reset confirmation: 1/1, `.artifacts/runs/20261005-053120-1791167480180828000/Tests.xcresult`;
- unknown code and missing JSON code unit mapping: 1/1, `.artifacts/runs/20261005-053520-1791167720986089000/Tests.xcresult`.

После исправлений полный Simulator прогон в `local`:

- unit: 134 теста в 20 suite, 0 failures, `.artifacts/runs/20261005-053543-1791167743310532000/Tests.xcresult`;
- UI: 18 тестов, 0 failures, `.artifacts/runs/20261005-053628-1791167788404462000/Tests.xcresult`.

`git diff --check` прошёл. `progress.md` и Task 7 исходники не менялись. Изменения ждут повторного scoped Sol review; commit после одобрения.
