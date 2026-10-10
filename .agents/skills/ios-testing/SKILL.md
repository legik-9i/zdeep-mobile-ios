---
name: ios-testing
description: Use when running, selecting, diagnosing, or verifying iOS unit, WebView integration, or UI tests in the ZDEEP repository.
---

# Тестирование ZDEEP iOS

Используй этот skill для тестов Swift Testing, настоящего `WKWebView`, UI-тестов, выбора отдельного теста и повторного запуска без сборки. Команды запускай из корня репозитория.

## Контуры и ограничения

| Действие | Разрешённый контур |
|---|---|
| Все автоматические наборы (`unit`, `integration`, `ui`, `all`) | `local` |
| Диагностика симулятора | `local` или `test` |
| Диагностика физического iPhone | `test` |

Автоматический `test`/`prod` запуск не поддерживается. Не передавай продовые адреса в override-конфигурацию и не открывай продовый WebView.

## Подготовка

Нужны Python 3, Xcode Command Line Tools и доступный iOS Simulator UDID. Получи UDID командой:

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

## Уборка артефактов

После проверки и записи нужных результатов освободи место на диске: удали созданные для своей задачи каталоги `.artifacts/runs/<запуск>` и `.artifacts/builds/<fingerprint>` (включая `DerivedData`). Если собирал напрямую через `xcodebuild -derivedDataPath` или создавал отдельный release-каталог, убери и этот каталог. Удаляй также артефакты неудачных и прерванных попыток после разбора ошибки. Оставь только файлы, которые ещё нужны для следующего `--skip-build`, незавершённого анализа или явно запрошены в отчёте; перечисли их пути и причину в передаче задачи. Перед удалением проверь точные пути и что их не использует параллельный агент или работающий `xcodebuild`. Не удаляй всю общую `.artifacts/` и каталоги соседних задач. Если сборка понадобится позднее, CLI создаст её заново.

Если работаешь в git worktree, сначала проверь корень checkout:

```sh
git rev-parse --show-toplevel
```

Запускай `scripts/zdeep.py` из этого корня. У worktree свои `.artifacts/` и fingerprint сборки, поэтому результат или сборка из основного checkout не подтверждают запуск в worktree. Передавай UDID явно через `--simulator`, особенно если одновременно открыто несколько checkout.

## Сборка и запуск

`all` включает unit, hosted-интеграционные тесты настоящего WebKit и UI-тесты. CLI создаёт подписанную тестовую сборку; `--skip-build` повторно использует её, пока fingerprint исходников, проекта, скриптов, Xcode toolchain и UDID симулятора не изменился. Unit-набор не обращается к живым API или Web; остальные наборы проходят строгий local preflight.

В ходе работы запускай относящиеся к изменению лёгкие проверки. Отдельный integration/UI набор запускай до финала только для воспроизведения конкретной проблемы или проверки её исправления. После успешного полного `all` не запускай наборы по отдельности. Выполни один полный local запуск в финале:

```sh
python3 scripts/zdeep.py test --environment local --suite all --simulator <SIMULATOR_UDID>
```

Проверь, что CLI вывел новый путь `Результаты: ...`. Для проверки повторного использования той же сборки запускай `all --skip-build` только когда это прямо требуется задачей:

```sh
python3 scripts/zdeep.py test --environment local --suite all --simulator <SIMULATOR_UDID> --skip-build
```

Не запускай повторный полный набор регулярно и не используй повторы, скрывающие первое падение.

Обычный unit-тест можно повторить после сборки без повторной компиляции:

```sh
python3 scripts/zdeep.py test --environment local --suite unit --only 'EnvironmentTests/test_testing_api_path_is_preserved()' --simulator <SIMULATOR_UDID> --skip-build
```

Указывай точный `nodeIdentifier` из `xcresult`, обычно без имени test target, и соответствующий `--suite`. Не подставляй имя target к идентификатору вручную. CLI преобразует его в формат селектора Xcode и проверяет по bundle, что исполнен ровно один тест. Integration запускается только в `local`.

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

### Какие тесты запускать

Для отдельной проверки local доступности запусти:

```sh
python3 scripts/zdeep.py preflight --environment local --suite integration
```

Для сетевых наборов local preflight требует прямой ответ HTTP 200 на `GET /health` API и `GET` настроенного Web URL. Любой redirect, другой статус, тайм-аут или транспортная ошибка блокирует запуск; redirect не выполняется. Для unit preflight не обращается к сети. Test/preflight в `test` не поддерживаются.

При падении:

1. Зафиксируй контур, команду и путь `.artifacts/runs/.../Tests.xcresult`.
2. Прочитай test report и точный `nodeIdentifier` из этого bundle.
3. Сначала проверь preflight и доступность симулятора.
4. Повтори только упавший тест через `--only ... --skip-build`, если исходники и конфигурация fingerprint не менялись; иначе пересобери.
5. Разделяй сбой preflight, падение теста и ошибку чтения `xcresult` в отчёте.

### Сбои запуска в worktree и симуляторе

| Симптом | Что делать |
|---|---|
| Команда упирается в ограничение sandbox: `Operation not permitted`, запрет доступа к `localhost`, CoreSimulator или его логам | Сразу повтори ту же необходимую команду с запросом разрешения на запуск вне sandbox (`require_escalated`) и кратко объясни, какой доступ нужен для теста. Не трать время на повторные запуски с теми же ограничениями и не меняй конфигурацию проекта ради обхода sandbox. Продолжай после разрешения; если запрос отклонён, сообщи точный блокирующий вывод. |
| Local preflight падает с `Operation not permitted` при запросе `http://localhost:4002/health` или API/Web на localhost | Это может быть ограничение среды запуска на локальную сеть, а не недоступность сервиса. Повтори ту же команду теста в разрешённом окружении с доступом к localhost. Не меняй URL контура и не подменяй local на test, чтобы обойти preflight. Если запрос разрешён, но сервис по-прежнему не отвечает или возвращает не 200, чини/поднимай сервис и только потом повторяй тест. |
| Тест-кейсы уже вывели результат, но `xcodebuild` завис после прогона, либо свежий `.xcresult` не содержит `Info.plist` и CLI не может прочитать отчёт | Считай такой bundle неполным: вывод тест-кейсов сам по себе не подтверждает успешный запуск. Останови только зависший процесс `xcodebuild`, который относится к этому запуску, сохрани его лог и повтори затронутый тест через `--only`. Добавь `--skip-build`, только если fingerprint для этого checkout не менялся; иначе запускай без него. Успех подтверждай по завершившейся команде и читаемому отчёту из нового `.xcresult`. |
| `simctl list devices available` или тест сообщает `CoreSimulatorService connection became invalid`, `Connection refused`, либо что задание `simdiskimaged` не зарегистрировано/выгружено | Это сбой доступности CoreSimulator, а не результат теста. Не перезапускай системные launchd-сервисы и не убивай процессы CoreSimulator. Повтори проверку списка устройств позже; когда симулятор снова доступен, запусти тест свежей командой с явным `--simulator <UDID>`. Если ошибка сохраняется, остановись и приложи точный вывод `simctl`/`xcodebuild` как блокер окружения. |

Не используй `.xcresult` зависшего или оборванного процесса как основание для pass/fail. Сохраняй каждый повтор в новом каталоге `.artifacts/runs/...`, чтобы отчёты запусков не смешивались.

Полезные наборы: `unit` не открывает сайты; `integration` проверяет настоящий WebView; `ui` проверяет нативные действия; `all` выполняет все три. Текущие тесты и CLI лежат в `ZDEEP/ZDEEPTests/`, `ZDEEP/ZDEEPUITests/` и `scripts/zdeep.py`.
