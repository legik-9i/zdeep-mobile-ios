# План реализации инфраструктуры разработки ZDEEP iOS

> **Для агента-исполнителя:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Шаги отмечаются флажками `- [ ]`. Способ исполнения выбирает пользователь после проверки плана.

**Цель:** дать пользователю приложение с кнопками открытия и закрытия WebView и Debug-панелью, а агентам — проверенные команды тестирования и диагностики.

**Архитектура:** один координатор приложения управляет контуром и жизненным циклом WebView. Диагностический исполнитель используется напрямую тестами, панелью и проверенным каналом команд с Mac; бизнесовый объект `ZdeepNative` остаётся пустым. Набор интеграционных тестов параметризуется для локального и тестового веба и использует одну сборку.

**Стек:** существующие SwiftUI, WebKit, Swift Testing, XCTest/XCUIAutomation, Xcode CLI, Python 3 для команд Mac без дополнительных пакетов. Сохранить текущий минимальный iOS приложения 17.6 и bundle ID `ru.zdeep.mobile`; тестовые targets привести к совместимому минимуму. Не менять signing team пользователя.

**Спецификация:** `ZDEEP/docs/superpowers/specs/2026-10-02-development-infrastructure-design.md`.

**Порядок исполнения:** задачи 1–2 → минимальная реализация задачи 3 → эксперимент задачи 5 → завершение проверок задачи 3 и задача 4 → рабочий транспорт задачи 5 → задачи 6–7. Канал iPhone подтверждается до расширения диагностики и написания навыков; временный код эксперимента не считается завершённой реализацией.

## Общие ограничения

- Документация и проектные навыки — на русском; актуальную техническую документацию получать через MCP Context7.
- `local`: веб `http://localhost:4005`, API `http://localhost:4002`, готовность API `/health` → 200.
- `test`: веб `https://5e9afe68-2ddd-4e58-8e57-5942cfa16099.website.twcstorage.ru`, API `https://api.zdeep.ru/testing/`.
- `prod`: веб `https://webview2.zdeep.ru`, API `https://api.zdeep.ru`; хранить константы, не выполнять сетевые проверки или загрузку прода.
- Симулятор по умолчанию использует `local`, установка на iPhone — `test`. Все интеграционные этапы проверять на обоих разрешённых контурах; прод проверять только без сети.
- Приложение не загружает веб на старте или при смене контура: загрузка начинается по кнопке «Открыть WebView».
- Закрытие веба возвращает начальный экран; Debug доступен на обоих экранах.
- Бизнесовые API, сертификаты, JWT и методы моста не реализуются. `window.ZdeepNative` — пустой объект на старте основного документа.
- Существующие пользовательские изменения Xcode-проекта и начального экрана сохранять при адресных изменениях. Не сбрасывать рабочую копию.
- Сборки и результаты команд сохранять в игнорируемом `.artifacts/`, локальные настройки — в игнорируемом `.local/`.

## На что обратить внимание при проверке

1. Закрытие и повторное открытие веба: старые результаты JS не должны изменять новое состояние — задача 3.
2. Выбор `prod`: адреса видны, но сетевой запрос без нажатия кнопки не отправляется — задачи 2 и 4.
3. Тестовый префикс `/testing/`: построение API URL не должно его терять — задача 2.
4. Повтор теста после редактирования исходников: устаревшая сборка отклоняется, результаты не перезаписываются — задача 1.
5. Заблокированный/отключённый iPhone или недоступный веб: команда завершается понятной ошибкой и тайм-аутом — задачи 3 и 5.

## Структура файлов

- `scripts/zdeep.py`: CLI сборки, тестирования, диагностики и установки; делегирует отдельным модулям.
- `scripts/zdeep_tools/build.py`, `preflight.py`, `diagnostics.py`: сборка и идентичность артефактов; доступность сервисов; команды и ответы диагностики.
- `scripts/tests/`: проверки CLI на временных файлах и подставном исполнителе процессов без запуска продовых запросов.
- `ZDEEP/ZDEEP/Environment/AppEnvironment.swift`, `LaunchConfiguration.swift`: адреса и параметры запуска.
- `ZDEEP/ZDEEP/App/AppCoordinator.swift`: контур, открытие/закрытие и сброс.
- `ZDEEP/ZDEEP/Web/WebSession.swift`, `WebViewHost.swift`: WebKit, жизненный цикл, инжекция и отображение.
- `ZDEEP/ZDEEP/Debug/`: диагностические команды, события, транспорт, панель и плавающая кнопка.
- `ZDEEP/ZDEEPTests/`: обычные и hosted-интеграционные тесты настоящего `WKWebView`.
- `ZDEEP/ZDEEPUITests/`: кнопки, панель, переключение, повторное открытие; UI-тесты не подменяют интеграционные JS-проверки.
- `.codex/skills/ios-testing/`, `ios-debugging/`, `ios-stitch-implementation/`: проектные инструкции.

## Задача 1. Воспроизводимая сборка и повтор тестов

**Файлы:** создать `scripts/zdeep.py`, `scripts/zdeep_tools/build.py`, `scripts/zdeep_tools/preflight.py`, `scripts/tests/test_build.py`, `scripts/tests/test_preflight.py`; изменить `.gitignore`, shared scheme `ZDEEP/ZDEEP.xcodeproj/xcshareddata/xcschemes/ZDEEP.xcscheme` и настройки тестовых targets в `project.pbxproj`.

**Интерфейс CLI:** `python3 scripts/zdeep.py build-tests --simulator <UDID>`; `test --environment local|test --suite unit|integration|ui|all [--only <test-id>] [--skip-build]`; `preflight --environment local|test`. Конфигурация пользователя `.local/development.json` содержит UDID симулятора/устройства и необязательные адреса. Интеграционная команда не принимает `prod`.

- [ ] Написать `test_build_once_for_suite`, `test_skip_build_rejects_changed_sources`, `test_results_are_unique`, `test_local_health_requires_200`, `test_prod_integration_is_rejected_without_request`: утверждать количество вызовов build, отказ при изменении входов, уникальность каталога, статус `/health` и отсутствие HTTP-вызовов для prod.
- [ ] Запустить `python3 -m unittest discover -s scripts/tests`; подтвердить падение новых проверок до реализации.
- [ ] Реализовать CLI: `build-for-testing` → `test-without-building`; fingerprint включает содержимое исходников и ресурсов, конфигурацию проекта, параметры сборки и версию toolchain. Контур — параметр запуска, а не сборки: для local/test создавать отдельные копии `.xctestrun` с runtime-настройками, не менять исходный артефакт. Результаты каждого запуска находятся в уникальном каталоге `.artifacts/runs/`.
- [ ] Проверить найденный симулятор средствами Xcode; согласовать deployment target тестов с приложением без изменения его минимума и пользовательского signing. Создать воспроизводимую shared scheme.
- [ ] Выполнить обычные тесты и инфраструктурный smoke-прогон на `local` и `test`, сначала одной сборкой, затем `--skip-build --only ...`. Для test проверять HTTPS-доступность разрешённого базового API без предположения о наличии `/health`: статус 401/403/404 фиксируется как ответ доступного HTTP-сервиса, 5xx и транспортные ошибки — как ошибка подготовки. Это не проверка бизнесового API.
- [ ] Сохранить команды и результаты этапа; ревью и отдельный коммит только файлов задачи.

## Задача 2. Контуры и управление открытием

**Файлы:** создать `Environment/AppEnvironment.swift`, `Environment/LaunchConfiguration.swift`, `App/AppCoordinator.swift` и `ZDEEPTests/EnvironmentTests.swift`, `CoordinatorTests.swift`; изменить `ZDEEPApp.swift` и `ContentView.swift`.

**Интерфейсы:** `AppEnvironment: String { local, test, prod }`; `EnvironmentEndpoints { web: URL, backend: URL }`; `AppCoordinator.openWebView()`, `closeWebView()`, `switchEnvironment(to:) async`, `resetClientData() async`. `openWebView` создаёт сессию только по явному действию; сессия задачи 3 подключается через отдельный factory. До её появления проверяется координатор с подставным factory.

- [ ] Написать `test_exact_environment_urls`, `test_testing_api_path_is_preserved`, `test_select_prod_does_not_load_web`, `test_close_then_reopen_creates_new_session`, `test_cross_database_switch_requests_clear`, `test_test_prod_switch_preserves_store`: проверить точные адреса, ноль загрузок при выборе контура, разные идентификаторы сессий и решение об очистке.
- [ ] Запустить выбранные тесты; подтвердить исходное падение, затем реализовать интерфейсы и кнопки начального экрана. Accessibility IDs: `open-webview`, `close-webview`, `current-environment`.
- [ ] Смена контура возвращает начальный экран, отменяет текущую сессию. Полный сброс применяется только к существующим данным приложения; не создавать фиктивное хранилище сертификатов.
- [ ] Повторить обычные проверки и UI-smoke начального экрана с параметрами `local` и `test`. В prod проверять только константы и координатор с подставным загрузчиком.
- [ ] Ревью и коммит задачи.

## Задача 3. Настоящий WebView и исполнитель JS

**Файлы:** создать `Web/WebSession.swift`, `Web/WebViewHost.swift`, `Debug/DiagnosticCommand.swift`, `Debug/DiagnosticExecutor.swift`, `ZDEEPTests/WebSessionIntegrationTests.swift`, `ZDEEPTests/DiagnosticExecutorTests.swift` и `ZDEEPTests/Fixtures/document-start.html`.

**Интерфейсы:** `@MainActor WebSession.load(url:)`, `close()`, `reload()`; `executeJavaScript(_ source: String, timeout: Duration) async throws -> JSONValue`; `waitForJavaScript(_ source: String, equals expected: JSONValue, timeout: Duration) async throws -> JSONValue`. `JSONValue` — Codable-представление null/bool/number/string/array/object. Ошибки: нет сессии, JS, несериализуемый результат, timeout, закрытая или заменённая сессия.

- [ ] Написать интеграционные тесты `test_real_web_url_and_native_object`, `test_js_value_and_error`, `test_timeout_records_last_value`, `test_reload_reinjects_object`, `test_closed_session_cannot_apply_result`; для fixture добавить `test_document_script_sees_native_object`.
- [ ] Подтвердить падение; реализовать `WKUserScript` на `.atDocumentStart` в page content world только основного frame. Не добавлять методов в `ZdeepNative`.
- [ ] Реализовать управление временем, отменой и идентификатором сессии; изменение состояния только на MainActor. Подключить WebView к координатору и показать загрузку, URL/ошибку и кнопку закрытия.
- [ ] Запустить один и тот же hosted-интеграционный набор на `local` и `test`. Проверить `location` после навигации, `typeof window.ZdeepNative === 'object'`, JSON-значение и JS-ошибку. При редиректе сохранять цепочку и конечный URL, не считать произвольный error page успешной интеграцией.
- [ ] Проверить закрытие/повторное открытие UI-тестом на обоих контурах; сохранить диагностику и коммит после ревью.

## Задача 4. Панель и сохраняемая диагностика

**Файлы:** создать `Debug/DiagnosticEventStore.swift`, `Debug/DebugPanel.swift`, `Debug/DebugOverlay.swift`, `ZDEEPTests/DiagnosticEventStoreTests.swift`, `ZDEEPUITests/DebugPanelUITests.swift`; изменить координатор и корневое отображение.

**Интерфейсы:** `DiagnosticEventStore.record(category:operationID:fields:)`, `snapshot()`, `export(to:)`; ограниченный по размеру журнал JSONL. DebugOverlay имеет accessibility ID `debug-button`; панель содержит `environment-picker`, `reload-webview`, `reset-client-data`, `js-input`, `execute-js`, `js-result`.

- [ ] Написать проверки удаления секретов из полей и URL, ограничения журнала и UI-проверки доступности панели на начальном экране, при загрузке/ошибке веба и после закрытия.
- [ ] Реализовать перемещаемую кнопку «Debug» и нативный sheet. Системные SwiftUI-компоненты; не придумывать брендовые токены. JS исполняется через интерфейс задачи 3.
- [ ] Реализовать очистку `WKWebsiteDataStore`, настроек и текущей сессии при полном сбросе/переходе между базами. Проверить cookie/localStorage до и после очистки на разрешённых контурах. Не изменять серверные данные.
- [ ] При падении сохранять фильтрованные события и данные проверки; скриншоты остаются локальными, секретные результаты не записываются автоматически. Добавить явную политику сохранения произвольных JS-результатов.
- [ ] Выполнить UI и интеграционные проверки на `local` и `test`; выбирать prod только на начальном экране без открытия веба. Собрать Release и проверить исключение DebugOverlay/DiagnosticExecutor из рабочего интерфейса без запуска продовых запросов.
- [ ] Ревью и коммит этапа.

## Задача 5. Подтверждение и реализация диагностики по кабелю

**Файлы:** эксперимент `experiments/usb-diagnostics/README.md`; после подтверждения — `Debug/DiagnosticMailbox.swift`, `scripts/zdeep_tools/diagnostics.py`, `scripts/tests/test_diagnostics.py`, `docs/development/iphone-diagnostics.md`.

**Первый кандидат транспорта:** файлы команд/ответов в app data container. Локальная справка подтверждает наличие `devicectl device copy to/from --domain-type appDataContainer --domain-identifier ru.zdeep.mobile`. Возможность обмена файлами с работающим приложением ещё нужно подтвердить. Не считать эту гипотезу выбранным транспортом до эксперимента.

- [ ] Подключить и разблокировать iPhone; перечислить устройства. Запустить минимальную Debug-сборку на test, получить событие запуска через `devicectl --console`.
- [ ] Временно проверить JSON-command mailbox в `Library/Caches/ZdeepDiagnostics/`: команды имеют UUID, ограничение времени и идентификатор сессии; ответы записываются атомарно. Симулятор доступен через его app container, iPhone — через copy to/from. Проверить JS `1 + 1`, JS-ошибку и получение события с реального WKWebView на test, затем на симуляторе local/test.
- [ ] Проверить отключение устройства и тайм-аут. Убедиться, что механизм не требует связи Mac и iPhone через Wi-Fi. Если кандидат не работает, зафиксировать точную ошибку и предложить подтверждаемую альтернативу до реализации остального транспорта.
- [ ] После подтверждения вынести транспорт в Debug-only файлы и добавить команды `device-install --device <ID>`, `device-launch --environment test`, `diagnose --target simulator|device --js <source> --timeout <seconds>`, `logs --target simulator|device`. Не помещать JS или ответы в постоянный shell history самим скриптом.
- [ ] Добавить и прогнать проверки CLI на неполный JSON, повтор UUID, устаревшую сессию, недоступное устройство и отсутствие ответа; затем реальный smoke на симуляторе обоих контуров и iPhone test.
- [ ] Подтвердить исключение транспорта из Release сборкой и проверкой конфигурации, без запуска продового веба. Описать фактические ограничения фонового режима и доступности файлов. Ревью и коммит.

Этап проверки транспорта выполняется до расширения его реализации и документации. Для него нужны только минимальный WebView и JS-исполнитель, созданные в задаче 3. При невозможности подтвердить обязательное требование зависимые этапы не объявляются завершёнными.

## Задача 6. Проектные навыки с практической проверкой

**Файлы:** `.codex/skills/ios-testing/SKILL.md`, `.codex/skills/ios-debugging/SKILL.md`, `.codex/skills/ios-stitch-implementation/SKILL.md`, корневой `AGENTS.md`, `docs/development/verification.md`.

- [ ] Применить навыки создания/редактирования навыков; описать назначение, условия применения, предусловия и реальные команды задач 1–5. Не определять повторно процесс Superpowers.
- [ ] В ios-testing включить один пример meaningful Swift Testing-проверки и один пример JS-интеграционного ожидания; команды local/test, выбор одного теста, build-once/reuse и разбор ошибок. В ios-debugging — проверенные команды iPhone и ограничения.
- [ ] В ios-stitch-implementation сослаться на существующий `stitch-design-pipeline`, проект `1417382377358815087`; описать HTML/тему/скриншот → фактические значения → SwiftUI → общие стили → визуальное сравнение. Не создавать нативные продуктовые экраны.
- [ ] Проверить навыки как инструкции: агент находит нужный навык по типичной задаче, выполняет полный local/test прогон и повтор отдельного теста; получает iPhone test логи/JS; получает из Stitch существующий экран и обосновывает одно соответствие стиля. Полный перенос нового экрана не заявлять проверенным.
- [ ] При исполнении через субагентов поручить отдельному агенту проверку обнаружения/применения навыков; при исполнении в одном агенте зафиксировать ограничение проверки свежим контекстом и не утверждать, что она выполнена. Учесть выбранные пользователем правила моделей.
- [ ] Сохранить в verification.md команды, результаты и ограничения. Исправить инструкции при любом расхождении; ревью и коммит.

## Задача 7. Итоговая проверка и приложение на iPhone

- [ ] Запустить Python-проверки CLI и полный Xcode-набор local, затем test на той же сборке, если inputs совместимы. Не обращаться к prod.
- [ ] Выполнить Release build без запуска приложения; проверить отсутствие debug-панели/канала в конфигурации и коде Release.
- [ ] Установить Debug-сборку на iPhone с test. Проверить запуск → «Открыть WebView» → тестовый веб → Debug → закрыть панель → «Закрыть WebView» → открыть снова.
- [ ] Проверить выбор контуров без автоматической загрузки: prod допускается выбрать для просмотра констант, затем вернуть test до открытия WebView. Local на iPhone не загружать.
- [ ] Получить с Mac событие и JS-результат с телефона; подготовить короткую инструкцию для ручной приёмки пользователя и расположение результатов всех этапов.
- [ ] Итоговое ревью, необходимые исправления и повтор только затронутых проверок. Отчёт различает реальные интеграционные проверки local/test, offline-проверки prod и непроверенные ограничения.
