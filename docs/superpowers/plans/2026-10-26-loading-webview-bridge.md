# План реализации загрузки и контракта WebView

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Цель:** показать загрузку с иллюстрациями, плавно раскрыть готовый WebView,
передать сведения о приложении в URL и обработать существующий веб вызов отвязки.

**Архитектура:** сохранить текущие AppCoordinator, проверку готовности документа
и предварительную загрузку. URL дополняется перед нативной загрузкой;
очисткой привязки владеет координатор. Отдельное SwiftUI представление содержит
иллюстрацию, локальное размытие и существующий лоадер.

**Стек:** SwiftUI, WebKit, Foundation URLComponents, Swift Testing, XCTest UI.
Новых зависимостей нет.

**Спецификация:** [согласованный дизайн](../specs/2026-10-26-loading-webview-bridge-design.md).

## Общие ограничения

- Менять только iOS-проект, не `/Users/oleg/projects/zdeep-webview2`.
- Домен и выбор окружения не менять; не открывать production при проверках.
- Использовать восемь исходников 841 × 1870, выбирать один на ожидание.
- Лоадер и «Загрузка» — в верхней трети, с локальным размытием; отвязки нет.
- Переход — растворение загрузки над неподвижным готовым вебом без возврата.
- Версия бриджа начинается с `0.0.1`; patch повышается один раз на коммит.
- Отвязка локальная, через существующую очистку; подтверждение уже есть в вебе.
- Не затрагивать пользовательские изменения `scripts/zdeep.py` и
  `scripts/zdeep_tools/build.py`; перед выполнением проверить актуальный status.
- Документация и новый AGENTS.md — на русском языке.

## Особое внимание при ревью

1. URL с уже существующими служебными параметрами, посторонним query и fragment:
   сохранить посторонние данные, заменить четыре служебных параметра без дублей.
2. Изменение темы до нового открытия: URL использует актуальную тему, а не
   сохранённую при старте; открытый сайт не перезагружается из-за темы.
3. Два вызова unlinkCar и старый документ: очистка запускается один раз,
   чужой/устаревший документ не может отвязать машину.
4. Закрытие WebView в процессе unlinkCar: очистка продолжается, публичный
   JS-метод возвращает undefined, отклонение транспорта обработано.
5. Быстрая готовность, фон, ошибка и recovery: не мелькают новый случайный
   фон и повторная анимация; ошибочный экран не растворяется как успешный.

### Task 1: Параметры URL и версия бриджа

**Файлы:** создать `ZDEEP/ZDEEP/Web/WebLaunchURL.swift`,
`ZDEEP/ZDEEP/Web/AGENTS.md`, `ZDEEP/ZDEEPTests/WebLaunchURLTests.swift`;
изменить `Web/NativeBridge.swift`, `Web/WebSession.swift`,
`App/AppCoordinator.swift`, `ContentView.swift`; проверить существующие
ожидания requestedURL в `ZDEEP/ZDEEPTests/WebSessionIntegrationTests*.swift`.

**Интерфейсы:** `NativeBridge.version: String`;
`WebLaunchURL.make(baseURL: URL, appVersion: String, bridgeVersion: String,
theme: String) -> URL`. URL helper чистый, темы только `light`/`dark`;
продуктовый источник темы — SwiftUI colorScheme, переданный координатору
до first-frame подготовки. Версия приложения берётся из Bundle.

- [ ] Добавить тесты `test_preserves_environment_path_query_and_fragment`,
  `test_replaces_duplicate_host_parameters`, `test_light_and_dark_theme`,
  `test_keeps_app_version_unchanged`: проверить четыре точных имени параметров,
  `platform=ios`, версии `1.0` и `0.0.1`, обе темы, сохранение path/fragment
  и постороннего query; покрыть local/test/prod URL без сетевого обращения.
- [ ] Запустить unit-набор и подтвердить, что новые тесты падают из-за
  отсутствующего URL helper, а не посторонней ошибки сборки.
- [ ] Реализовать helper через URLComponents. Передавать актуальную тему
  в координатор через ContentView; first-frame подготовка не должна опередить
  начальную передачу темы. Начальную загрузку и явные повторные открытия
  дополнять в общем пути WebSession.prepareAndLoad; origin доверия не менять.
  Не модифицировать произвольные пользовательские переходы внутри сайта.
  File URL интеграционных fixture не дополнять.
- [ ] Добавить тест актуальности темы при новом открытии и отсутствия reload
  текущего документа только из-за смены темы. Обновить затронутые URL assertions,
  сохранив проверки реального origin и redirect chain.
- [ ] Добавить AGENTS.md с точным списком `NativeBridge.swift`,
  `BridgeModels.swift`, `BridgeBootstrap.js` и правилом patch относительно
  родительского коммита; первый коммит задаёт `0.0.1`. Без Git hook.
- [ ] Запустить unit-набор до PASS. Проверить diff и зафиксировать только
  файлы задачи, сообщение `feat: add native WebView launch parameters`.

### Task 2: Отвязка по существующему веб контракту

**Файлы:** изменить `Web/BridgeBootstrap.js`, `Web/BridgeModels.swift`,
`Web/NativeBridge.swift`, `App/AppCoordinator.swift`;
тесты `NativeBridgeTests.swift`, `CoordinatorTests.swift`,
`WebSessionIntegrationTests+Bridge.swift` и связанные fixture в этом файле.
Переиспользовать `App/AppCoordinator+Reset.swift` без дублирования очистки.

**Интерфейсы:** JS `window.ZdeepNative.unlinkCar(): void`;
NativeBridge получает callback `onUnlinkCar: () -> Void` отдельным параметром
перед существующим последним `onReady` (последнюю trailing closure сохранить).
В тестах допустим callback по умолчанию `{}`; продуктовый координатор всегда
подключает callback к своей очистке. Координатор запускает cleanup в своей
MainActor Task, не внутри задачи бриджа.

- [ ] Добавить тест `test_unlink_request_accepts_only_null_params`: null
  принимается, объект/строка/массив отвергаются. Расширить проверку bootstrap
  новым методом; запустить unit-набор, подтвердить ожидаемое падение.
- [ ] Добавить dispatch unlinkCar с существующей проверкой origin/main frame
  и document identity. На нативной стороне повторный unlink одного документа
  не вызывает callback дважды. JS-метод ничего не возвращает, обрабатывает
  rejection Promise send; исключения других методов не поглощать.
- [ ] Подключить callback координатора к resetBindingAndShowWelcome.
  Не ждать завершения cleanup перед техническим ответом бриджа и не связывать
  lifetime cleanup с bridge.close. Не добавлять второй alert и серверный API.
- [ ] Добавить coordinator тесты успешной очистки и ошибки хранилища,
  используя существующие resettable store/manager fake: закрытие WebView,
  stop сессии, reset ровно один раз, Welcome либо существующая cleanup error.
- [ ] Добавить WKWebView fixture тесты вызова без аргументов, результата
  `typeof ... === 'undefined'`, двух вызовов, запроса старого документа и
  непринятия запроса недоверенного/дочернего фрейма по существующим fixture
  паттернам. Отдельно подменить транспорт на rejected Promise в fixture,
  вызвать unlinkCar и через барьер JS event loop проверить ноль
  unhandledrejection; тест с настоящим закрытием проверяет завершение
  координаторской очистки после уничтожения bridge.
- [ ] Unit-набор до PASS; targeted integration только для проверки этой
  конкретной границы. В этом коммите повысить patch до `0.0.2` по AGENTS.md.
  Проверить diff и commit `feat: handle web car unlink in native bridge`.

### Task 3: Иллюстрации и раскрытие готового веба

**Файлы:** создать `Presentation/WebLoadingView.swift`,
восемь `Assets.xcassets/LoadingScene01.imageset` … `LoadingScene08.imageset`
с Contents.json и оптимизированными изображениями;
изменить `ContentView.swift`, `Presentation/NativeStatusViews.swift`,
`App/AppCoordinator.swift`, `App/AppCoordinator+Authorization.swift`,
`App/AppCoordinator+WebPreparation.swift`; при удалении устаревшего cancellation
API проверить все callers в `App/`. Тесты `CoordinatorTests.swift`,
`WebReadinessTests.swift`, `NativePresentationTests.swift`,
`ZDEEPUITests/AuthorizationUITests.swift`, `NativePresentationUITests.swift`.

**Интерфейсы:** `WebLoadingView(imageName: String)`; координатор хранит
выбранное имя и отличает ожидание авторизации/веба от технической `.loading`
при запросе камеры и cleanup. Нужна явная причина загрузки, а не вывод
из наличия binding: регистрация после QR идёт ещё без готовой привязки.
Существующий didRevealWebSession определяет первый показ. Новые представления
не управляют авторизацией, timeout или готовностью документа.

- [ ] Добавить coordinator тесты выбора допустимого asset один раз на
  ожидание: старт с привязкой, QR до завершения регистрации, retry,
  публикации состояния, фон/foreground. Проверить отсутствие иллюстрации
  при запросе камеры и cleanup. Не тестировать статистику случайности.
- [ ] Запустить unit-набор и подтвердить ожидаемое падение новых тестов.
- [ ] Подготовить ресурсы из восьми исходников, не менять originals;
  использовать локальное форматирование/конвертацию без генерации нового
  содержания, не увеличивать разрешение. Выбрать размер сжатия после сравнения
  качества, записать суммарный объём ресурсов. При необходимости обновить
  project.pbxproj, не добавлять AGENTS.md в ресурсы приложения.
- [ ] Реализовать выбор и сохранение asset на время ожидания, отдельное
  от простой `.loading`. Повторные изменения состояния и фон не выбирают
  картинку. Возврат к Welcome завершает ожидание.
- [ ] Реализовать полноэкранный aspect-fill фон с clipping. В верхней трети
  по центру — ThinkingOrb `.connecting`, `.px64`, `.light` и подпись «Загрузка».
  Под ними локальная размытая копия выровненного фона с мягкой маской:
  размытие захватывает тот же участок, не всю иллюстрацию. Декоративные
  картинки и blur скрыть от accessibility, подпись оставить доступной.
- [ ] Удалить кнопку отвязки и alert из NativeLoadingView. Удалить только
  ставшие неиспользуемыми cancellation flags/methods после поиска callers;
  сохранить ошибочные экраны и их подтверждение. Переписать UI тесты,
  которые нажимали кнопку на загрузке, на отсутствие кнопки; проверки
  reset/error перенести на существующую ошибку или bridge сценарий задачи 2.
- [ ] При accepted readiness сделать веб непрозрачным под уходящим overlay.
  Анимировать только удаление WebLoadingView при первом успешном reveal
  (предлагаемая реализационная длительность 0.25 s, без искусственного ожидания).
  Не анимировать весь switch screen; не оставлять прозрачный фон между слоями.
  При Reduce Motion убрать длительность. Вход/выход из фона и process recovery
  не повторяют первое раскрытие. Ошибки показывать существующим способом.
- [ ] Unit-тестами проверить первый reveal, отсутствие повторного reveal
  после foreground/recovery и сохранение readiness gate; визуально в симуляторе
  проверить обе точки входа, быстрый/медленный ready, маленький и большой iPhone,
  светлую/тёмную тему, Reduce Motion, каждый из восьми фонов.
- [ ] Unit-набор до PASS; проверить diff и commit
  `feat: show illustrated loading screen before WebView`.

## Команды проверки и завершение

Использовать `.codex/skills/ios-testing/SKILL.md`. Получить UDID через
`xcrun simctl list devices available`; ниже заменить `<UDID>` реальным.

Промежуточная проверка задач:
`python3 scripts/zdeep.py test --environment local --suite unit --simulator <UDID>`.
Ожидается PASS, CLI сообщает путь нового xcresult. Для точечного integration
использовать точный nodeIdentifier согласно skill, не угадывать селектор.

- [ ] Выполнить один полный финальный прогон:
  `python3 scripts/zdeep.py test --environment local --suite all --simulator <UDID>`.
  Ожидается PASS всех наборов; недоступность local API/веба обозначать как
  блокировку проверки, не как пройденный тест.
- [ ] Прочитать итоговый report, проверить git diff/status, отсутствие
  изменений во фронте и чужих скриптах. Провести финальное ревью изменений.
- [ ] Записать фактические результаты и ограничения; убрать только свои
  завершённые build/run артефакты по ios-testing skill после анализа отчётов.

## Самопроверка плана

Все разделы спецификации распределены по трём задачам. Пять рисков из раздела
ревью покрыты тестами задач 1–3; визуальная проверка нужна для обрезки,
размытия и плавности. Сценарий камеры не смешан с ожиданием сайта, контракт
void не заменён Promise API, текущая предзагрузка на Welcome не переделывается.
