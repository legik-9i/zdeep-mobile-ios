---
name: ios-testing
description: Use when running, selecting, diagnosing, or verifying iOS unit, WebView integration, or UI tests in the ZDEEP repository.
---

# Тестирование ZDEEP iOS

Используй этот skill для тестов Swift Testing, настоящего `WKWebView`, UI-тестов, выбора отдельного теста, повторного запуска без сборки и проверки local/test. Команды запускай из корня репозитория.

## Контуры и ограничения

| Контур | Web | API | Проверка перед интеграционным запуском |
|---|---|---|---|
| `local` | `http://localhost:4005` | `http://localhost:4002` | `GET /health` обязан вернуть 200 |
| `test` | `https://5e9afe68-2ddd-4e58-8e57-5942cfa16099.website.twcstorage.ru` | `https://api.zdeep.ru/testing/` | HTTPS-сервис должен отвечать; 401/403/404 допустимы, 5xx — ошибка |
| `prod` | `https://webview2.zdeep.ru` | `https://api.zdeep.ru` | сетевые тесты запрещены |

CLI `test` принимает только `local` или `test`. Не передавай prod URL в override-конфигурацию и не открывай продовый WebView. Проверяй контуры отдельными запусками, чтобы по команде и отчёту было понятно, где исполнялись тесты.

## Подготовка

Нужны Python 3, Xcode Command Line Tools, доступный iOS Simulator UDID и работающие сервисы выбранного контура. Получи UDID командой:

```sh
xcrun simctl list devices available
```

Можно настроить симулятор в игнорируемом `.local/development.json`:

```json
{
  "simulator": "<SIMULATOR_UDID>"
}
```

Либо передавай `--simulator <UDID>` явно. Результаты сборок и запусков находятся в `.artifacts/`; новый прогон создаёт отдельный result bundle. Не удаляй bundle до чтения отчёта.

## Полный local/test прогон и повтор без сборки

`all` включает unit, hosted-интеграционные тесты настоящего WebKit и UI-тесты. Первый запуск собирает тестовые targets и запускает полный набор в local:

```sh
python3 scripts/zdeep.py test --environment local --suite all --simulator <SIMULATOR_UDID>
```

Проверь, что CLI вывел новый путь `Результаты: ...`. Затем используй ту же сборку для test:

```sh
python3 scripts/zdeep.py test --environment test --suite all --simulator <SIMULATOR_UDID> --skip-build
```

Сборка годится для `--skip-build`, пока fingerprint исходников, проекта, скриптов, Xcode toolchain и UDID симулятора не изменился. Если CLI сообщает, что актуальной сборки нет, повтори запуск без `--skip-build`. Не запускай `all` отдельно для каждого теста: фильтруй готовый набор по `nodeIdentifier`.

Обычный unit-тест можно повторить после сборки без повторной компиляции:

```sh
python3 scripts/zdeep.py test --environment local --suite unit --only 'EnvironmentTests/test_testing_api_path_is_preserved()' --simulator <SIMULATOR_UDID> --skip-build
```

Указывай точный `nodeIdentifier` из `xcresult`, обычно без имени test target, и соответствующий `--suite`. Не подставляй имя target к идентификатору вручную. CLI преобразует его в формат селектора Xcode и проверяет по bundle, что исполнен ровно один тест. Если fingerprint изменился, повтор без `--skip-build` сначала пересоберёт тесты. Для integration выбери `local` или `test` явно.

## Существенные примеры

Unit-проверка контракта URL удерживает важный `/testing/` префикс:

```swift
@Test func test_testing_api_path_is_preserved() {
    #expect(AppEnvironment.test.endpoints.backend.absoluteString == "https://api.zdeep.ru/testing/")
}
```

Интеграционная проверка ждёт готовности реального документа и исполняет JS в его `WKWebView`:

```swift
_ = try await session.waitForJavaScript(
    "document.readyState",
    equals: .string("complete"),
    timeout: .seconds(60)
)
let nativeType = try await session.executeJavaScript(
    "typeof window.ZdeepNative",
    timeout: .seconds(10)
)
#expect(nativeType == .string("object"))
```

Для Swift Testing используй `@Test`, `#expect` и async/await; не ставь фиксированный `sleep`, если можно ждать проверяемое условие. [Документация Apple по async Swift Testing](https://developer.apple.com/documentation/testing/testing-asynchronous-code).

## Preflight и разбор результата

Для отдельной проверки доступности запусти:

```sh
python3 scripts/zdeep.py preflight --environment local --suite integration
python3 scripts/zdeep.py preflight --environment test --suite integration
```

Local требует `/health` → 200. Test API проверяет доступность HTTPS, не готовность бизнесовых методов; 404 на базовом URL сам по себе не означает сбой. Unit-набор не требует сети. Интеграционные и UI тесты могут открыть выбранный сайт в настоящем WebView.

При падении:

1. Зафиксируй contour, команду и путь `.artifacts/runs/.../Tests.xcresult`.
2. Прочитай test report и точный `nodeIdentifier` из этого bundle.
3. Сначала проверь preflight и доступность симулятора.
4. Повтори только упавший тест через `--only ... --skip-build`, если исходники и конфигурация fingerprint не менялись; иначе пересобери.
5. Разделяй сбой preflight, падение теста и ошибку чтения `xcresult` в отчёте.

Полезные наборы: `unit` не открывает сайты; `integration` проверяет настоящий WebView; `ui` проверяет нативные действия; `all` выполняет все три. Текущие тесты и CLI лежат в `ZDEEP/ZDEEPTests/`, `ZDEEP/ZDEEPUITests/` и `scripts/zdeep.py`.
