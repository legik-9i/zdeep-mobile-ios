# ZDEEP iOS: план реализации регистрации и веб-сессии

> **Для исполнителей:** обязательный навык — `superpowers:subagent-driven-development` либо `superpowers:executing-plans`. Выполнять задачи последовательно; шаги отмечать чекбоксами. При выборе разработки субагентами код и исправления выполняет Luna, ревью — Sol, по правилам `AGENTS.md`.

**Цель:** реализовать привязку телефона через QR, сохранённый вход, обновление JWT и безопасный показ существующего веб-приложения.

**Архитектура:** шесть согласованных компонентов: BindingStore, AuthClient, SessionManager, существующий WebSession как контейнер, NativeBridge и существующий AppCoordinator. Изменяемое состояние приложения находится на MainActor; синхронный Security/CryptoKit работает на одной последовательной очереди хранилища. Эти компоненты составляют одну связанную функцию приложения, поэтому задачи объединены в один план с явными интерфейсами.

**Технологии:** Swift, SwiftUI, UIKit, CryptoKit, Security, Foundation/URLSession, WebKit, Swift Testing, XCTest UI. Существующие iOS deployment target 17.6 и Swift language version 5.0 сохраняются. Единственный новый пакет — CodeScanner 2.5.2, точная версия в SPM.

**Спецификации:**

- [Общая архитектура](../specs/2026-10-03-mobile-session-design.md).
- [BindingStore](../specs/2026-10-03-binding-store-design.md).
- [AuthClient](../specs/2026-10-03-auth-client-design.md).
- [SessionManager](../specs/2026-10-03-session-manager-design.md).
- [WebSession](../specs/2026-10-04-webview-container-design.md).
- [NativeBridge](../specs/2026-10-04-native-bridge-design.md).
- [AppCoordinator](../specs/2026-10-04-app-coordinator-design.md).
- [Контракт веба](../specs/2026-10-03-webview-bridge-prerequisites.md).

Статус: план подготовлен для проверки пользователем. Код и зависимости этим документом не изменены; выполнение начинается после принятия плана.

Ревью Sol от 2026-10-04: пять замечаний исправлены — local-only UI, своевременная адаптация старых тестов, пассивный hosted test root, сериализация shared WebKit storage и background execution для любой общей auth-операции. Повторное ревью подтвердило закрытие замечаний; новых противоречий в исправлениях не обнаружено. Физический iPhone исключён из обязательной приёмки по уточнению пользователя.

## Общие ограничения

- Все сетевые проверки — только `local`: web `http://localhost:4005`, API `http://localhost:4002`. Никаких прогонов в `test`/`prod`.
- Полное завершение задачи и приёмка не требуют физического iPhone. Все обязательные проверки выполняются на Simulator с `local`, включая реальный WKWebView и локальный backend; камера и события жизненного цикла проверяются заменяемыми адаптерами.
- Готовая конфигурация окружений используется как зависимость. API URL и web URL никогда не берутся из QR.
- Регистрация: одна попытка `pair`; завершение только после проверенного JWT и сохранения `registered`. Ошибка незавершённой регистрации требует очистки перед новым QR.
- Хранилище имеет состояния `pending`, `registered`, `resetting`; отсутствие записи отдельно. JWT, QR-токен и поправка часов только в памяти.
- Keychain: `AfterFirstUnlockThisDeviceOnly`, без iCloud sync и биометрического запроса; приватный ключ не покидает BindingStore.
- HTTP: 30 секунд с отправки до полного ответа, без redirects и скрытых повторов.
- Обновление после каждой новой публикации JWT: за 120 секунд; интервалы после неудачи в режиме работы 5, 10, 20, 30 секунд, далее 30; после истечения попытки продолжаются. В режиме входа ошибка требует явного действия.
- Native определяет срок по серверному времени и ContinuousClock; веб не сравнивает JWT с часами телефона. Одинаковая строка повторного JWT — `BAD_RESPONSE`, без публикации и продления дедлайна.
- Готовность веба: 60 секунд активного времени после появления JWT; принятие готовности останавливает таймер. Ротация JWT и redirects его не перезапускают.
- До первого показа нужны актуальный `reportReady`, действующая сессия и активное приложение. Живой показанный WebView при проблемах JWT остаётся видимым.
- «Отмена» регистрации/входа/подготовки веба выполняет локальный сброс. Логотип и очистка кнопки отмены не имеют. Перепривязка требует подтверждения.
- Обычный сброс заменяет экземпляр WKWebView и сохраняет persistent web cache. Полный debug-сброс удаляет все данные приложения, включая Keychain и маркер установки.
- Публичный bridge: четыре существующих метода, `zdeep:session-event` и `zdeep:host-event`; без protocolVersion и ревизии JWT.
- Существующий WelcomeView сохраняется. Временная загрузка — слово «Загрузка». Стартовый прозрачный логотип на `#F5F5F7`, как welcome.
- Пользовательские ошибки не содержат сырых HTTP-тел, ключей и токенов. Диагностика: `NT`, код до 15 символов, 8 hex-символов идентификатора, версия приложения отдельно.

## Фокус ревью

Эти риски проверяются дополнительно к обычным успешным сценариям:

1. Отмена между сохранением `registered` и публикацией JWT: поздний успех не возвращает авторизацию — задачи 3, 10.
2. Правильный ранний `getSession` до commit, за ним `getHostState`: второй метод не зависает за первым — задача 7.
3. Готовность принята в фоне, затем JWT истёк: нет второго таймаута; явный повтор входа загружает новый документ — задача 11.
4. Ошибка маркера установки и последующий сброс: welcome недоступен до успешного `reset → restore → none` — задачи 1, 10.
5. Веб-ошибка, затем пассивный отказ обновления: причина ошибки и контекст её повтора сохраняются — задачи 4, 11.

## Размещение файлов и границы

Все пути ниже относительно корня репозитория. В задачах короткие имена production-файлов раскрываются таблицей ниже внутри `ZDEEP/ZDEEP/`; короткие имена unit/integration-тестов — внутри `ZDEEP/ZDEEPTests/`. UI-тесты лежат только в `ZDEEP/ZDEEPUITests/`. Новые Swift-файлы в `ZDEEP/ZDEEP` и `ZDEEP/ZDEEPTests` подхватывает существующая структура проекта; ресурсы и пакет добавляются в Xcode явно, когда это необходимо.

| Область | Файлы | Ответственность |
| --- | --- | --- |
| Привязка | `Session/BindingModels.swift`, `BindingStore.swift`, `KeychainRecordStorage.swift`, `InstallMarkerStorage.swift` | Публичное описание, пять операций, Security, маркер установки |
| API | `Session/AuthModels.swift`, `SessionClock.swift`, `AuthClient.swift`, `AuthResponseValidator.swift`, `AuthHTTPTransport.swift` | Ошибки/сессия, время, подпись/один запрос, проверка ответа, URLSession |
| Сессия | `Session/SessionManager.swift`, `SessionRefreshPolicy.swift`, `BackgroundExecution.swift` | Общая операция, потребители/события, планы обновления, ограниченное завершение в фоне |
| Камера | `Camera/CarQRParser.swift`, `CameraPermission.swift`, `QRScannerView.swift` | Разбор QR, разрешение, адаптер CodeScanner |
| Веб | существующий `Web/WebSession.swift`; новые `WebDocumentContext.swift`, `WebNavigationPolicy.swift` | Контейнер, актуальность документа, решение о навигации |
| Bridge | `Web/NativeBridge.swift`, `BridgeModels.swift`, `BridgeBootstrap.js` | Reply-handler, JSON DTO, JS Promise/event adapter |
| Приложение | существующий `App/AppCoordinator.swift`; новые `AppState.swift`, `AppCoordinator+Authorization.swift`, `AppCoordinator+WebPreparation.swift`, `AppCoordinator+Reset.swift` | Состояние/сценарий, вход, готовность, очистка и окружение |
| Экраны | `Presentation/StartupLogoView.swift`, `NativeLoadingView.swift`, `NativeErrorView.swift`, `CameraPermissionView.swift`, `FirstFrameProbe.swift`, `NativeErrorStyle.swift` | Только представление состояния и действия |
| Полная очистка | `App/OwnedClientDataCleaner.swift` | Явный перечень данных приложения и возобновление незавершённой очистки |
| Тестовые зависимости | `ZDEEP/ZDEEPTests/Support/SessionTestDoubles.swift`, `LocalAuthFixture.swift` | Детерминированные часы, управляемые завершения, свежий local carToken |

Не добавлять общий event bus, библиотеку state machine, отдельные actor для каждого компонента или общий framework повторов. Coordinator extensions используют одни и те же поля AppCoordinator: они не создают независимые контроллеры.

## Контракты между задачами

Это имена и типы, которые задачи обязаны использовать. Невыбранные тела методов пишет исполнитель.

### BindingStore — задача 1

```swift
struct PendingBinding: Equatable, Sendable {
    let bindingId: UUID
    let publicCertificate: String
}
struct RegisteredBinding: Equatable, Sendable {
    let bindingId: UUID
    let publicCertificate: String
    let carId: String
}
protocol BindingStoring: Sendable {
    func restore() async throws -> RegisteredBinding?
    func beginRegistration() async throws -> PendingBinding
    func sign(bindingId: UUID, bytes: Data) async throws -> Data
    func completeRegistration(bindingId: UUID, carId: String) async throws -> RegisteredBinding
    func reset() async throws
}
```

`BindingStoreError`: `keychain(operation: String, status: OSStatus)`, `invalidRecord`, `cryptography`, `installMarker(operation: String)`, `staleBinding`, `registrationNotAllowed`. Строки operation — безопасные константы. Внутренний Codable `BindingRecord` не публичен и хранится одним Data.

### Время/API — задача 2

```swift
struct AuthSession: Equatable, Sendable {
    let accessToken: String
    let userId: String
    let carId: String
    let expiresAt: String // UTC ISO 8601, имя поля веб-контракта
    let deadline: Duration // монотонное время относительно общего origin
    let serverTimeMs: Double
    let attemptId: UUID
}
enum AuthStage: String, Sendable { case pair, token, storage, publication, web }
enum AuthErrorKind: String, Codable, Sendable {
    case network, timeout, server, local
    case invalidResponse = "invalid-response"
}
struct AuthFailure: Error, Equatable, Sendable {
    let kind: AuthErrorKind
    let stage: AuthStage
    let attemptId: UUID
    let message: String
    let httpStatus: Int?
    let serverCode: String?
    let diagnosticCode: String
}
@MainActor protocol CancellationHandle: AnyObject { func cancel() }
@MainActor protocol SessionClock: AnyObject {
    var now: Duration { get }
    var wallTimeMs: Double { get }
    func schedule(at deadline: Duration,
                  action: @escaping @MainActor () -> Void) -> any CancellationHandle
}
@MainActor protocol AuthClientProtocol: AnyObject {
    func pair(binding: PendingBinding, carToken: String) async throws -> AuthSession
    func token(binding: RegisteredBinding) async throws -> AuthSession
    func invalidateCurrentAttempt()
}
```

`ContinuousSessionClock`: один `ContinuousClock` и один origin на граф зависимостей; `now = origin.duration(to: clock.now)`. FakeClock меняет монотонное и wall-время независимо. Production schedule — отменяемая Task, sleep до заданного continuous deadline. Никаких ожиданий реальных минут в unit-тестах.

### SessionManager — задачи 3–4

```swift
enum SessionManagerEvent {
    case sessionChanged(AuthSession)
    case sessionExpired(AuthFailure?)
    case entryFailed(AuthFailure)
    case authorizationActivityChanged(Bool) // только native, не событие JS
}
struct RegistrationFailure: Error {
    let failure: AuthFailure
    let registeredBinding: RegisteredBinding? // сохранено до ошибки публикации
}
@MainActor protocol SessionManaging: AnyObject {
    var currentSession: AuthSession? { get } // только действующий JWT
    var lastError: AuthFailure? { get }
    var registeredBinding: RegisteredBinding? { get }
    var isAuthorizationInFlight: Bool { get }
    func register(binding: PendingBinding, carToken: String) async throws -> AuthSession
    func updateSession(binding: RegisteredBinding?) async throws -> AuthSession
    func subscribe(_ observer: @escaping @MainActor (SessionManagerEvent) -> Void)
        -> any CancellationHandle
    func webViewDidBecomeVisible()
    func setActive(_ active: Bool)
    func stop()
}
```

Первый вход вызывает `updateSession(binding: restored)`, остальные — `updateSession(binding: nil)`. Ошибка отмены — `CancellationError`; `RegistrationFailure` сообщает только неудачу регистрации/публикации и сохранённый публичный контекст. Список callback-подписчиков местный. isAuthorizationInFlight отражает общую manager-owned операцию; authorizationActivityChanged отправляется один раз при её начале/завершении/stop, независимо от инициатора и количества потребителей. NativeBridge не сериализует этот внутренний сигнал в JS. Перед callback повторно проверять актуальность публикации: подписчик может синхронно вызвать stop. Другой bindingId без stop отклоняется локальной ошибкой.

### WebSession/bridge — задачи 6–7

```swift
enum WebReadyScreen: String, Codable { case content, error }
enum WebPreparationReason { case initial, explicitRetry, fullNavigation, processRecovery }
struct WebDocumentIdentity: Equatable {
    let containerId: UUID
    let attemptId: UUID
    let documentId: UUID
}
enum WebSessionEvent {
    case documentPreparing(WebDocumentIdentity, URL, WebPreparationReason)
    case documentCommitted(WebDocumentIdentity)
    case documentFailed(WebDocumentIdentity, AuthFailure)
    case processTerminated
}
```

WebSession сохраняет текущие `id`, `webView`, `load(url:)`, `reload()`, `close()` и debug-методы. Добавить `currentDocument: WebDocumentIdentity?`, `onEvent: ((WebSessionEvent) -> Void)?`, `prepare(url:reason:)`, `attachBridge(_ bridge: any WebDocumentBridgeHandling)`. Context принадлежит только контейнеру; bridge читает его через weak WebSession. `load`/`reload` используют тот же prepare-path. Factory создаёт контейнер, но не начинает загрузку до команды координатора. В задаче 6 определить малый `@MainActor protocol WebDocumentBridgeHandling: AnyObject` в WebDocumentContext: `bootstrap(documentId: UUID) -> WKUserScript`, `documentDidCommit(_ identity: WebDocumentIdentity)`, `closeDocument(_ identity: WebDocumentIdentity)`, `close()`. Задача 6 тестирует его fake; NativeBridge в задаче 7 реализует этот протокол. Так контейнер собирается до появления конкретного bridge.

`NativeBridge.init(session: WebSession, manager: any SessionManaging, onReady: @escaping (WebDocumentIdentity, WebReadyScreen) throws -> Void)`, `setActive(_:)`, `closeDocument(_:)`, `close()`. Container вызывает `documentDidCommit(_:)` для запуска удержанных вызовов. Bridge DTO повторяют точные типы `src/shared/session/types.ts` и `src/shared/host/types.ts` соседнего web-repo; внутренние native UUID и deadline наружу не сериализуются.

### Coordinator — задачи 9–12

`AppScreen`: `startup`, `welcome`, `camera`, `cameraPermission`, `loading(canCancel: Bool)`, `error(NativeErrorPresentation)`, `web`. `AppScenario`: `restoring`, `waitingForUser`, `scanning`, `registering`, `signingIn`, `preparingWeb`, `working`, `resetting`; у сценария отдельный UUID, без публичной ревизии.

`RetryContext`: `restore`, `authorization(RegisteredBinding)`, `web(url: URL, bindingId: UUID, reason: WebPreparationReason)`, `cleanup(reason: LocalResetReason, next: CleanupNextStep)`, `environment(target: AppEnvironment, previous: AppEnvironment, stage: EnvironmentSwitchStage)`, `fullReset(OwnedCleanupProgress)`.

`CleanupNextStep`: `restoreThenWelcome`, `showRegistrationError(AuthFailure)`. `LocalResetReason`: `cancel`, `rebind`, `failedRegistration`, `storageReset`. `EnvironmentSwitchStage`: `cleanup`, `apply`. `OwnedCleanupProgress` хранит `remaining: Set<OwnedDataCategory>` и `failures: [OwnedDataCategory: AuthFailure]`; категории определяет enum `OwnedDataCategory: Hashable`: `keychain`, `files`, `preferences`, `webData`; remaining содержит только ещё не завершённые категории. `NativeErrorPresentation` содержит безопасную ошибку и RetryContext, либо первичную ошибку с единственным действием StartOver; никаких замыканий, JWT или QR.

Публичные действия AppCoordinator: `start()`, `scanRequested()`, `scannerCompleted(_ result: Result<String, Error>)`, `scannerClosed()`, `cancelLoading()`, `retry()`, `startOver()`, `requestRebind()`, `confirmRebind()`, `dismissRebindConfirmation()`, `openCameraSettings()`, `cameraPermissionBack()`, `setActive(_:)`, `nativeFrameDisplayed(scenarioId: UUID)`, `acceptWebReady(_ identity: WebDocumentIdentity, screen: WebReadyScreen) throws`. Существующие `switchEnvironment(to:)` и `resetClientData()` сохраняют имена. Начатое асинхронное действие владеет Task координатора; публичные UI-действия синхронно проверяют/блокируют повторные нажатия до создания Task.

## Проверки и рабочий цикл

Перед выполнением выбрать доступный Simulator UDID через `xcrun simctl list devices available`, далее использовать его как `<UDID>`. Команды ниже — будущие шаги, на этапе плана они не выполнялись.

```sh
python3 scripts/zdeep.py test --environment local --suite unit --simulator <UDID>
python3 scripts/zdeep.py test --environment local --suite integration --simulator <UDID>
python3 scripts/zdeep.py test --environment local --suite ui --simulator <UDID>
python3 scripts/zdeep.py test --environment local --suite all --simulator <UDID>
```

Сборка Swift входит в команды тестов; при изменениях исходников не использовать `--skip-build`. Для точечного повтора брать настоящий nodeIdentifier из завершённого `.xcresult`, а не угадывать его. Успех — exit 0 и читаемый новый result bundle с ненулевым количеством ожидаемых тестов.

CLI сейчас относит к integration только `WebSessionIntegrationTests`. Перед первым integration-прогоном задачи 2 пометить этот suite `@Suite(.serialized)`: все его extensions используют тот же последовательный suite и shared-default WebKit store. Unit-тесты cleaner используют fake WebKit adapter, не WKWebsiteDataStore.default. Новые реальные WebKit/API-проверки размещать как extensions **этого** suite в отдельных файлах; чистые unit не должны обращаться к сети. Не расширять классификатор CLI ради новых имён suite.

До исполнения использовать `using-git-worktrees` для изолированной ветки. Соседние backend/web/agent checkout остаются источниками референсов, изменения в них не входят в этот план.

До первого UI-прогона задачи 8 адаптировать `ZDEEP/ZDEEPUITests/ZDEEPUITests.swift::testTestEnvironmentWelcomeScreenDoesNotLoadWebUntilOpened`: заменить сетевой сценарий на local и убрать выбор `--environment test`. Проверки констант/сохранения shared scope test/prod остаются в EnvironmentTests с fake dependencies. Проверить все UI launchArguments/launchEnvironment: `--environment local` обязателен даже для performance launch; CLI environment не переопределяет аргумент приложения. Ни один UI-тест не открывает remote test/prod web.

До изменения автоматического старта в задаче 9 добавить пассивный hosted-test режим. CLI выставляет `ZDEEP_PASSIVE_TEST_HOST=1` только target `ZDEEPTests` в копии `.xctestrun` по имени TestBundlePath, не target `ZDEEPUITests`. В DEBUG + Simulator root приложения в этом режиме не создаёт production coordinator и не начинает restore/web/auth; tests явно создают свои компоненты. Режим не действует в обычном запуске/Release. Для `all` hosted suite пассивен, а UI launch композиция нормальная либо явно выбранная UI fixture. Не использовать один глобальный флаг для всех targets.

В каждой задаче: падающий тест → минимальная реализация → успешный соответствующий набор → ревью и исправления → коммит только файлов задачи. Если тест падает из-за окружения/preflight, он ещё не является красным тестом поведения. Общие test doubles растут только по фактической необходимости текущей задачи.

## Задачи

### Task 1: Сериализованное хранилище и восстановление установки

**Файлы:** создать четыре `Session/Binding*.swift`/адаптера из таблицы; `ZDEEP/ZDEEPTests/BindingStoreTests.swift`, `Support/SessionTestDoubles.swift`.

**Интерфейсы:** производит BindingStoring, PendingBinding, RegisteredBinding, BindingStoreError. Внутренние синхронные адаптеры: `KeychainRecordStorage.read() throws -> Data?`, `write(_ data: Data) throws`, `delete() throws`; `InstallMarkerStorage.exists() throws -> Bool`, `create() throws`, `remove() throws`. Подменяются в тестах.

- [ ] Написать `test_restore_missing_marker_removes_registered_before_creating_marker`, `test_marker_read_error_does_not_delete_keychain`, `test_pending_and_resetting_are_deleted_on_restore`: проверить точный порядок операций и отсутствие результата при ошибке очистки/сохранения маркера.
- [ ] Написать `test_begin_sign_complete_and_restore_registered`: `restore == nil`; begin сохраняет pending до возврата; DER-публичный ключ проверяет DER-подпись точных байтов; complete сохраняет carId; новое хранилище восстанавливает тот же bindingId. Добавить idempotent complete той же пары, отказ другой машины/id, некорректной записи и несоответствующего публичного ключа.
- [ ] Написать `test_reset_failure_never_reports_success`, `test_reset_invalid_record_uses_owned_keychain_query`, `test_queued_reset_follows_inflight_begin`, `test_begin_requires_successful_restore`: сбой пометки с успешным delete допустим; сбой обоих возвращает ошибку; resetting не подписывает; неактуальный bindingId отклоняется.
- [ ] Запустить unit, убедиться в падении новых проверок из-за отсутствующего поведения.
- [ ] Реализовать BindingStore: одна serial DispatchQueue; каждую из пяти операций целиком выполнять в одном queue.async без await внутри критической операции; возврат через checked continuation. BindingStore как единственный владелец queue-confined state может быть @unchecked Sendable; адаптеры не используются вне этой очереди. CryptoKit P256 rawRepresentation приватного ключа, derRepresentation публичного/подписи. Security generic-password service `Bundle.main.bundleIdentifier + ".auth"`, account `binding`, synchronize false. В тестах отдельный UUID-service с defer-delete и отдельный временный каталог маркера; реальные записи приложения не трогать.
- [ ] Реализовать маркер `Application Support/ZDEEP/install.marker`: атомарная запись, исключение из backup; отличать ENOENT от ошибки чтения. Начало регистрации разрешить только после успешного restore и подтверждённого отсутствия записи.

Контрольные assertions для описанных выше фикстур:

```swift
// test_begin_sign_complete_and_restore_registered
#expect(pending.bindingId == registered.bindingId)
#expect(restored == registered)
#expect(publicKey.isValidSignature(signature, for: bytes))
```

- [ ] Запустить unit, проверить PASS; коммит `feat: add durable binding store`.

### Task 2: Одна подписанная HTTP-попытка и проверка ответа

**Файлы:** создать пять Session-файлов времени/API из таблицы; изменить `ZDEEP/ZDEEPTests/WebSessionIntegrationTests.swift` для `@Suite(.serialized)`; `AuthClientTests.swift`, `AuthResponseValidatorTests.swift`, `Support/LocalAuthFixture.swift`, `WebSessionIntegrationTests+LocalAuth.swift` в `ZDEEP/ZDEEPTests`.

**Интерфейсы:** потребляет BindingStoring; производит AuthClientProtocol/AuthSession/AuthFailure/SessionClock. `AuthHTTPTransport.send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)`, `cancelCurrentRequest()`; состояние транспорта на MainActor, URLSession delegate запрещает redirects.

- [ ] Написать `test_signs_exact_sent_body_and_sends_once`: перехватить Data JSON, проверить подпись `<X-Timestamp>|<body>` сохранённым публичным ключом; body содержит только согласованные поля; 401/429/503 и 307/308 не вызывают второго send.
- [ ] Написать `test_900_seconds_is_not_900_milliseconds`: при serverTimeMs=1000000, exp=1900, expiresIn=900, HTTP-duration=2000ms, now=2s получить deadline=900s и expiresAt от 1900000ms; wall-clock ± сутки не меняет дедлайн.
- [ ] Написать проверки пустого JWT, плохого Base64URL/JSON, отсутствующих/нечисловых/неконечных сроков, неправильных aud/context/carId/tokenType и уже исчерпанного срока. Должны вернуть invalid-response/BAD_RESPONSE, не ключи/сырое тело. 403 с неизвестным code сохраняет код и статус; не-JSON 503 сохраняет статус.
- [ ] Написать `test_timestamp_error_updates_next_attempt_only`, `test_invalidated_reply_cannot_update_offset`, `test_full_timeout_does_not_reset_on_chunks`: виртуальная доставка на 29s ещё допустима, на 30s — timeout; cancellation/late response имеют один итог. Поправку применять только после принятого успеха либо валидного TIMESTAMP_OUT_OF_RANGE.
- [ ] Запустить unit и подтвердить ожидаемые падения.
- [ ] Реализовать AuthClient/validator по формуле спецификации. JSONEncoder сериализует body один раз; decoder читает только нужный JWT payload и не проверяет HS256 секрет. URL base из готовых endpoints сохраняет префикс пути. Валидировать ответ в MainActor до применения offset; invalidate синхронно закрывает attempt и отменяет network/task.
- [ ] Реализовать total HTTP deadline через SessionClock и отмену URLSession task, плюс URLSession timeoutIntervalForResource=30; перед принятием полного ответа проверять монотонный предел повторно. CancellationError отличать от AuthFailure.
- [ ] Добавить local integration `test_local_pair_then_token_accepts_spki_and_der_signature`: получить свежий carToken методом из [тестовых данных](../../development/local-auth-test-data.md), создать временную привязку, выполнить pair и complete, затем token, проверить одну машину/пользователя и действующие сроки. Не требовать различия JWT двух близких вызовов клиента; эту политику тестирует менеджер. defer удаляет тестовый Keychain/маркер; серверные сертификаты не отзывать. Не печатать токены.

Контрольные assertions для описанных выше фикстур:

```swift
// test_900_seconds_is_not_900_milliseconds
#expect(session.deadline == .seconds(900))
#expect(requests.count == 1)
#expect(failure.diagnosticCode == "BAD_RESPONSE") // invalid-response fixture
```

- [ ] Запустить unit и integration на local; оба PASS; коммит `feat: add signed mobile auth client`.

### Task 3: Менеджер: публикация и одна общая операция

**Файлы:** создать `Session/SessionManager.swift`, `ZDEEP/ZDEEPTests/SessionManagerTests.swift`; дополнить test doubles управляемыми ответами/сохранением.

**Интерфейсы:** потребляет BindingStoring/AuthClientProtocol/SessionClock; производит SessionManaging. Таймерная политика реализуется в следующей задаче; интерфейс режима и активности уже есть.

- [ ] Написать `test_pair_publishes_only_after_registered_save`, `test_save_failure_has_no_published_jwt`, `test_expiry_during_save_preserves_registered_context`: управлять моментом завершения store; последний тест возвращает RegistrationFailure с RegisteredBinding и currentSession=nil.
- [ ] Написать `test_concurrent_consumers_share_one_attempt`, `test_update_joins_pair`, `test_cancelled_consumer_does_not_cancel_shared_auth`: два потребителя получают один результат, отменённый — CancellationError, общий клиент/счётчик вызывается один раз. Зарегистрированный контекст иной привязки отклоняется.
- [ ] Написать `test_auth_activity_covers_register_manual_scheduled_and_bridge_attempts`: isAuthorizationInFlight=true пока общая Task не закончена, один true/false event на операцию, join не создаёт событий, stop завершает состояние.
- [ ] Написать `test_stop_during_registered_save_prevents_late_publication`, `test_stop_invalidates_client_before_network_cancellation`, `test_reentrant_subscriber_stop_blocks_later_delivery`: событие старой операции не доставляется и не оживляет менеджер после stop.
- [ ] Написать `test_identical_jwt_keeps_original_deadline_and_reports_bad_response`: также сравнить с последним истёкшим JWT; нет sessionChanged/нового дедлайна. После stop первая публикация такой же строки допустима.
- [ ] Запустить unit, подтвердить падения; реализовать один MainActor manager-owned Task, UUID операции и словарь continuation потребителей. Перед добавлением waiter проверить Task cancellation, чтобы отмена до регистрации continuation не оставила вечное ожидание; добавить этот case в тест независимой отмены. Отмена потребителя удаляет только его continuation; общий Task отменяет только stop. Отмена из nonisolated cancellation handler передаёт удаление на MainActor; завершение каждого waiter защищено удалением из словаря.
- [ ] Реализовать register/update/currentSession/subscribe/stop и RegistrationFailure. До/после каждого await проверять operation identity; привязку complete сохраняет store. Подписчики — локальный словарь; cancel handle удаляет запись. currentSession проверяет дедлайн при каждом чтении и выдаёт истечение не более одного раза.

Контрольные assertions для описанных выше фикстур:

```swift
// test_stop_during_registered_save_prevents_late_publication
#expect(manager.currentSession == nil)
#expect(publishedSessions.isEmpty)
#expect(clientPairCalls == 1)
```

- [ ] Запустить unit, PASS; коммит `feat: coordinate shared authorization and publication`.

### Task 4: Обновление, повторы и активность приложения

**Файлы:** создать `Session/SessionRefreshPolicy.swift`, `SessionRefreshTests.swift`; изменить SessionManager.

**Интерфейсы:** потребляет SessionClock/SessionManaging задачи 3. `SessionRefreshPolicy.refreshDeadline(for: AuthSession) -> Duration`, `retryDelay(failureCount: Int) -> Duration`. BackgroundExecution подключает координатор в задаче 9; менеджер знает только active/inactive и сохраняет общую уже начатую операцию.

- [ ] Написать тесты планирования **любой** публикации: при TTL900 старт на 780s; TTL<=120 запускает следующий обмен после завершения текущего, без двух операций. Отказ входа отменяет авторефреш/повтор, сохраняет expiry; foreground не повторяет отказ входа.
- [ ] Написать `test_working_retry_delays_are_5_10_20_30_30`, `test_retry_continues_after_expiry`, `test_success_resets_retry_count`, `test_manual_update_joins_or_replaces_scheduled_retry`: задержка отсчитывается после завершения ошибки, один общий отказ увеличивает счётчик один раз.
- [ ] Написать `test_foreground_keeps_visible_working_mode_and_rechecks_deadline`, `test_background_starts_no_new_auth`: оставшийся срок >120 сохраняет план, <=120/истёкший запускает одну попытку при разрешённом режиме; in-flight допускает завершение в фоне. При foreground после пропущенного expiry currentSession=nil и одно sessionExpired.
- [ ] Написать тест включения рабочего режима после предшествующей ошибки обновления: назначается retry; полная навигация/процесс веба не сбрасывают этот режим. Ошибка native web не блокирует working refresh.
- [ ] Запустить unit, подтвердить падения; реализовать два отменяемых плана refresh/retry и expiry, идентичность callback, сохранять абсолютный следующий план при уходе в фон. При активном внешнем update отменить старый retry. Ошибка входа блокирует автостарт до пользовательского действия.
- [ ] Проверить, что уход в фон не отменяет сам по себе уже начатую общую операцию; её 30-секундный deadline по-прежнему определяет AuthClient. Новые попытки в фоне не создаются.

Контрольные assertions для описанных выше фикстур:

```swift
// test_working_retry_delays_are_5_10_20_30_30
#expect(delays == [5, 10, 20, 30, 30].map { Duration.seconds($0) })
#expect(expiredEvents.count == 1)
```

- [ ] Запустить unit, PASS; коммит `feat: schedule session refresh and recovery`.

### Task 5: Разбор QR и адаптер камеры

**Файлы:** создать три Camera-файла из таблицы, `CarQRParserTests.swift`, `CameraPermissionTests.swift`; изменить `ZDEEP/Info.plist`, `ZDEEP/ZDEEP.xcodeproj/project.pbxproj`, создать соответствующий `Package.resolved` проекта.

**Интерфейсы:** `CarQRParser.parse(_ value: String) throws -> CarQR`, где `CarQR: Equatable, Sendable` содержит только `carToken: String` и извлечённый `carId: String`; `CarQRParserError: Error` имеет один case `unsupported`; `CameraPermission.status() -> AVAuthorizationStatus`, `requestAccess() async -> Bool`. `QRScannerView(onResult:onCancel:)` возвращает Result<String, Error>, не HTTP/BindingStore.

- [ ] Написать тесты URL агента `/auth/get-otp?token=...`: ровно один непустой token, читаемый JWT payload carId; мусор/дубли/отсутствие carId отклоняются. URL не используется для API или открытия страницы, QR JWT не проверяется по часам телефона. Поддерживаемый URL разбирать через URLComponents, путь может иметь префикс BASE_URL агента; проверять окончание пути `/auth/get-otp`.
- [ ] Написать permission-тесты notDetermined/authorized/denied/restricted, без реального системного prompt. Scanner выдаёт первый результат один раз, завершение/закрытие после закрытия игнорируется.
- [ ] Запустить unit, подтвердить падения; добавить точную SPM dependency CodeScanner 2.5.2 из `https://github.com/twostraws/CodeScanner`, закрепить resolved revision. Применить `.qr`, `.once`, без gallery/manual/photo output; разрешения остаются за координатором. Добавить `NSCameraUsageDescription`: «Камера нужна, чтобы отсканировать QR-код машины».
- [ ] Реализовать parser/permission/scanner. Simulator UI получает результат через debug test fixture задачи 10, Release не принимает QR из launch arguments. Никаких настоящих токенов в Package/исходниках.

Контрольные assertions для описанных выше фикстур:

```swift
// test_duplicate_token_query_is_rejected
#expect(throws: CarQRParserError.self) { try CarQRParser.parse(duplicateTokenURL) }
#expect(scannerResults.count == 1) // repeated scanner completion fixture
```

- [ ] Запустить unit и сборку через test-команду, PASS; коммит `feat: add QR scanner and camera permission adapter`.

### Task 6: Контейнер: документ и политика навигации

**Файлы:** изменить `Web/WebSession.swift`, `Web/WebViewHost.swift`, фабрику в `App/AppCoordinator.swift`; создать WebDocumentContext/WebNavigationPolicy, `WebNavigationPolicyTests.swift`, `WebDocumentContextTests.swift`; расширить `WebSessionIntegrationTests.swift`.

**Интерфейсы:** производит контракты WebSession из раздела выше. Bridge transport пока подключается заменяемым callback для проверки контекста; настоящая инжекция — следующая задача.

- [ ] Написать unit для exact origin: scheme/host/effective port; разрешён same-origin, запрещены back/forward полного документа/автоматический чужой redirect, внешний пользовательский HTTP(S) link открывает system browser, чужой window.open без user gesture блокируется. SPA fragment/history changes не меняют документ.
- [ ] Написать `test_own_load_policy_reuses_prepared_context`, `test_redirect_keeps_document_identity`, `test_late_navigation_callback_cannot_revive_closed_document`: перед load/allow-full-navigation создаётся один preparing context, didStart связывает WKNavigation, didCommit grants; superseded callbacks отсечены NavigationCallbackGate.
- [ ] Запустить unit, подтвердить падения; расширить существующий контейнер. Указать WKWebsiteDataStore.default; отключить allowsBackForwardNavigationGestures, не вводить controls истории. Preserve инфраструктурные scripts при замене bootstrap. Main-frame HTTP4xx/5xx и foreign redirects немедленно дают documentFailed; CDN subresources не запрещать.
- [ ] Добавить WKUIDelegate для targetFrame=nil и системного браузера с инжектируемым openURL. Все разрешения решения navigation policy завершаются один раз. `close` отписывает delegates/bridge/diagnostics, stopLoading и делает текущий context closed.
- [ ] Добавить integration `test_prepare_commit_and_reload_have_distinct_documents`, `test_file_fixture_has_no_real_session`, `test_close_releases_old_webview_and_history`: для файла не давать реальные токены/ключи; weak reference старого WebView после освобождения становится nil. Существующие reinjection/late diagnostics тесты продолжают работать.

Контрольные assertions для описанных выше фикстур:

```swift
// test_redirect_keeps_document_identity
#expect(afterRedirect == beforeRedirect)
#expect(afterReload != beforeRedirect) // separate reload fixture
```

- [ ] Запустить unit и integration local, PASS; коммит `feat: constrain WebView navigation and document lifetime`.

### Task 7: Полный JS bridge и события

**Файлы:** создать NativeBridge/BridgeModels/BridgeBootstrap.js, `NativeBridgeTests.swift`, `WebSessionIntegrationTests+Bridge.swift`, `Fixtures/bridge-contract.html`; изменить WebSession и включение JS/fixture в resources.

**Интерфейсы:** потребляет SessionManaging, WebSession.currentDocument, onReady coordinator callback; производит четыре JS метода и события существующего web-контракта.

- [ ] Написать `test_precommit_calls_start_in_order_but_finish_independently`: queued getSession ждёт JWT, getHostState после commit немедленно завершается; вызовы до commit не выполняют business effects. Late commit после fail/close не запускает очередь.
- [ ] Написать source-validation тесты wrong documentId/iframe/foreign origin/old container, malformed method/params; ни один не получает JWT. Повторный ответ исключён; замена документа отменяет только его waiters, общий auth остаётся.
- [ ] Написать `test_get_session_returns_valid_cache_during_failed_refresh`, `test_recover_requires_actual_new_attempt`, `test_report_ready_rejects_invalid_state`: recover до первой сессии — unavailable/temporary, повреждённый или запрещённо сменённый контекст — terminal; отказ update без действующего JWT — expired, с действующим — temporary. Существующие поля AuthError и recovery соблюдать точно.
- [ ] Написать event-тесты sessionChanged/sessionExpired/lifecycle/refresh, включая уже поставленное в JS очередь событие старого документа: receiver проверяет captured documentId. Повторный reportReady принятого актуального документа idempotent, без нового перехода/таймера; оба screen допустимы.
- [ ] Запустить unit, подтвердить падения; реализовать WKScriptMessageHandlerWithReply в `.page`, mainframe-only bootstrap atDocumentStart. Сообщения и три reply-envelope из native-bridge §§2.1–2.2. Удержанные вызовы после commit **запускать** по порядку, не await-ить весь первый перед вторым. getSession до первой публикации подписывается на manager events; это ожидание не инициирует pair/token. Если ошибка первоначального входа уже произошла до вызова, сразу вернуть manager.lastError, а не ждать пропущенного entryFailed; проверить отдельным тестом.
- [ ] Реализовать четыре Promise wrappers, AbortError и CustomEvent adapters в JS. Native `callAsyncJavaScript` передаёт payload через arguments; JWT не интерполируется в source. JS-обёртка захватывает documentId, наружу его не экспортирует; протокольной версии нет. JSON DTO WebviewSession не включает userId/deadline/attemptId; другие DTO сохраняют точный соответствующий web-контракт.
- [ ] Подписки на manager закрывать вместе с bridge; bootstrap присутствует в Release, диагностические API — только DEBUG. Пока нет потребителя события, получить актуальную сессию можно через getSession; для первых commit доставлять только действующий текущий snapshot, без replay старых токенов.
- [ ] Добавить реальные WebKit integration всех четырёх методов, структурированных reject/AbortError и document-start вызова; local HTML fixture без настоящего JWT проверяет только транспорт. Настоящий JWT допускается только configured local origin.

Контрольные assertions для описанных выше фикстур:

```swift
// test_precommit_calls_start_in_order_but_finish_independently
#expect(getSessionReply == nil)
#expect(getHostStateReply != nil)
#expect(authCalls == 1)
```

- [ ] Запустить unit и integration local, PASS; коммит `feat: implement native session bridge`.

### Task 8: Логотип, загрузка и экран ошибки

**Файлы:** изменить `ZDEEP/ZDEEP/ZDEEPApp.swift` и `ZDEEP/ZDEEPUITests/ZDEEPUITests.swift` для local-only launch; создать Presentation-файлы кроме FirstFrameProbe и debug-only `Debug/SessionUITestFixture.swift`; assets `StartupLogo.imageset`, `NativeBackground.colorset`, `LaunchScreen.storyboard`; заполнить AppIcon.appiconset; изменить Info.plist/проект; `NativePresentationTests.swift`, `ZDEEPUITests/NativePresentationUITests.swift`; сохранить источник error HTML в `docs/design/assets/native-error/`.

**Интерфейсы:** `StartupLogoView()`, `NativeLoadingView(canCancel:onCancel:)`, `NativeErrorView(presentation:onRetry:onStartOver:onRebind:)`, `CameraPermissionView(status:onSettings:onBack:)`; представления не выполняют auth/reset. Создать NativeErrorPresentation/RetryContext в AppState.swift по контракту координатора; вычисление действий зависит от enum.

- [ ] До любого UI-прогона выполнить local-only адаптацию существующего test-environment UI-сценария из раздела проверок. Сохранить проверку welcome, но не открывать внешний контур; константы test/prod проверять только unit.
- [ ] Получить актуальный Stitch error screen `projects/1417382377358815087/screens/411b28d9024448b7a36d813cbf00b56c`, сохранить HTML и метаданные источника. Следовать ios-stitch-implementation; если текущая тема конфликтует с согласованным фоном приложения — уточнить конкретные значения перед переносом. Кнопки использовать из существующего WelcomeStyle, не придумывать новую тему. Временная загрузка — только «Загрузка» и разрешённая отмена.
- [ ] Написать table-тесты действий: первичная ошибка → StartOver; storage restore → Retry/Reset; registered auth/web → Retry/Rebind; cleanup → Retry. Коды NETWORK/TIMEOUT/HTTP_403/BAD_RESPONSE/KEYCHAIN/SIGNATURE помещаются в 15 символов; attempt UUID отображается первыми 8 hex-символами без дефисов. Версия из CFBundleShortVersionString/CFBundleVersion.
- [ ] Написать UI-тесты видимости/доступности кнопок, длинного неизвестного serverCode/русского текста, Dynamic Type и подтверждения с текстом «Привязка на этом телефоне будет удалена. Для входа потребуется снова отсканировать QR-код машины». Denied → Settings/Back, restricted → объяснение/Back; notDetermined сначала системный prompt задачи 10.
- [ ] Для UI-тестов этой задачи добавить изолированный presentation-host в SessionUITestFixture, включаемый только DEBUG + Simulator + явный UI-test launch flag; подключить его в ZDEEPApp. Он показывает выбранный экран с безопасными фикстурами без API/ключей и не меняет обычный старт приложения. Запустить unit/ui, подтвердить падения; реализовать экраны с общим фоном #F5F5F7. Transparent PNG из [брендинга](../../design/assets/branding/README.md) копировать в StartupLogo без перекраски; логотип квадратный aspect-fit, центр корневого экрана, ширина доступной области минус два существующих `WelcomeStyle.pageHorizontalInset` (сейчас 16pt), без нового визуального токена. LaunchScreen повторяет эти constraints; фон заполняет экран включая safe areas. LaunchScreen storyboard использует тот же ресурс/background и статические constraints; никакой сети/кода.
- [ ] Белый PNG — источник AppIcon. Перед asset catalog проверить непрозрачность; если в исходнике alpha, сделать непрозрачную копию на белом с сохранением исходника, через imagegen согласно правилам работы с изображениями. Проверить итог 1024×1024 и отсутствие alpha. Не использовать прозрачный логотип как AppIcon.

Контрольные assertions для описанных выше фикстур:

```swift
// test_primary_registration_error_has_only_start_over
#expect(visibleButtonTitles == ["Начать сначала"])
#expect(diagnosticCode.count <= 15)
#expect(displayAttemptId.count == 8)
```

- [ ] Запустить unit/ui local и сравнить screenshot ошибки с HTML при сопоставимом viewport; коммит `feat: add native session status screens and branding`.

### Task 9: Старт координатора и отложенная подготовка веба

**Файлы:** изменить AppCoordinator, ContentView, ZDEEPApp, WelcomeView; создать App/AppRootView.swift, Presentation/FirstFrameProbe.swift и Session/BackgroundExecution.swift; изменить `scripts/zdeep_tools/build.py`, `scripts/tests/test_build.py`; расширить AppState; расширить CoordinatorTests, `ZDEEP/ZDEEPUITests/ZDEEPUITests.swift`, `DebugPanelUITests.swift`, `DiagnosticMailboxUITests.swift`, `DiagnosticMailboxLaunchTests.swift` и `ZDEEP/ZDEEPTests/WebSessionIntegrationTests.swift` по зависимостям старого открытия.

**Интерфейсы:** потребляет BindingStoring/SessionManaging/фабрику WebSession/экраны. `AppCoordinator.init` получает эти зависимости с production defaults; `start()` вызывается один раз из app lifecycle. WelcomeView принимает `onScan: () -> Void`, его вёрстка сохраняется.

- [ ] Перед wiring start написать Python-тесты `test_passive_host_flag_is_scoped_to_hosted_target` для обоих xctestrun layouts и `all`: ZDEEPTests получает флаг, ZDEEPUITests нет, существующие EnvironmentVariables сохраняются. Добавить app-entry тест отсутствия production factory/marker/HTTP при passive flag. Убедиться в ожидаемых падениях, реализовать flag в `_configure_xctestrun` по TestBundlePath ending `/ZDEEPTests.xctest` (также basename без slash). В ZDEEPApp выбрать passive/UI fixture/production branch **до создания** AppCoordinator; AppRootView владеет StateObject только в production branch. Пустая root test-host view не вызывает ContentView.start/first-frame. Запустить Python suite.
- [ ] Написать `test_none_restores_to_welcome`, `test_registered_starts_one_token_without_welcome_flash`, `test_restore_error_starts_no_webview`, `test_web_factory_waits_for_native_frame`: startup logo → результат restore; factory не вызывается до уведомления UI; JWT attempt стартует независимо.
- [ ] Написать `test_stale_frame_callback_does_not_create_container`, `test_background_defers_web_creation`: уведомление связано с UUID сценария, подготовка ровно один раз после активности/актуального frame.

Контрольные assertions для описанных выше фикстур:

```swift
// test_web_factory_waits_for_native_frame
#expect(factoryMakeCountBeforeFrame == 0)
#expect(factoryMakeCountAfterFrame == 1)
```

- [ ] Запустить unit, подтвердить падения; реализовать start/restore и state. Создавать контейнер на актуальное уведомление, подключать bridge и diagnostics перед load. В этой задаче подключить onReady к acceptWebReady и реализовать базовую проверку актуального документа/registered context/действующего JWT, сохранение принятой готовности и reveal только при active. Рабочий режим включается только после фактического показа; таймер и расширенные сценарии добавляет задача 11. Отдельный подготовленный WebView находится под непрозрачным native view в одном ZStack, disabled/hitTesting false и accessibilityHidden до показа. Reveal использует тот же instance без reload.
- [ ] Реализовать FirstFrameProbe как малый UIViewRepresentable: после didMoveToWindow запустить одноразовый CADisplayLink, уведомить на втором tick (между ними прошёл rendering cycle первого кадра), invalidate при detach/смене scenarioId. Не использовать onAppear как доказательство отображения, DispatchQueue delay или фиксированные миллисекунды. Координатор дополнительно проверяет active/scenario; probe не создаёт WKWebView.
- [ ] Подключить BackgroundExecution к координатору по manager.isAuthorizationInFlight и authorizationActivityChanged: beginBackgroundTask при уходе в фон с **любой** уже начатой общей auth-операцией (register, scheduled/manual refresh, bridge recover); наличие Task координатора не требуется. end ровно один раз при завершении общей операции/stop/foreground/expiration. После expiration повторно entitlement для той же непрерывной background-фазы не запрашивать; сбросить этот запрет при foreground. Expiration завершает право на background execution, не запускает retry и не обещает работу при suspension; проверка HTTP deadline при возобновлении остаётся у клиента. Добавить fake-adapter тесты balanced begin/end для scheduled refresh и recover без Task координатора, expiration и отсутствия background-series, без BGTaskScheduler.
- [ ] Удалить техническую URL/navigation-error строку из обычного ContentView; debug сведения остаются в панели. ScenePhase передаёт setActive менеджеру/bridge/coordinator. Legacy openWebView перестаёт обходить auth, диагностический флаг не раскрывает бизнесовый веб.
- [ ] В этой же задаче адаптировать прежние open/close/lazy WebView ожидания, а не откладывать до12: CoordinatorTests используют fake manager/store и prepared-vs-visible состояние; ZDEEPUITests/DebugPanelUITests/DiagnosticMailboxUITests работают с hidden prepared local WebView, диагностические open flags не раскрывают его. DebugPanelTestActions ожидает подготовленный контейнер вместо auth bypass. Сохранить тесты JS/late replies/mailbox, сменив только способ получения доступного документа. `WebSessionIntegrationTests.test_full_reset_clears_web_cookie_and_local_storage` создаёт WebSession напрямую для записи cookie/storage, закрывает его до reset и создаёт новый напрямую для чтения; не использует coordinator.openWebView. Полный набор после9 не содержит ожиданий прежнего bypass.
- [ ] Добавить UI startup/welcome/loading тесты; проверить first reveal с тем же id контейнера через unit. Запустить unit/integration/ui local и `python3 -m unittest discover -s scripts/tests`, PASS; коммит `feat: connect staged startup and web preparation`.

### Task 10: Камера, регистрация, отмена и перепривязка

**Файлы:** создать AppCoordinator+Authorization.swift и AppCoordinator+Reset.swift; изменить AppCoordinator/ContentView; расширить CoordinatorTests и `ZDEEPUITests/AuthorizationUITests.swift`; расширить debug-only `Debug/SessionUITestFixture.swift` задачи 8.

**Интерфейсы:** потребляет parser/permission/store/manager; производит UI-действия scan/result/close/cancel/rebind/retry/startOver. Сценарий invalidated синхронно до async cleanup.

- [ ] Написать `test_camera_permission_is_requested_before_scanner`, denied/restricted/Settings-return тесты: открыть камеру только при разрешении и актуальном scan intent; Back/новый сценарий исключает поздний callback. Закрытие камеры → welcome без ключей.
- [ ] Написать `test_one_qr_starts_one_pair`, `test_invalid_qr_returns_start_over_error`, `test_pair_failure_cleans_before_start_over`: после первого распознавания камера закрыта; begin/pair один раз; failed pair/complete → reset → restore none → первичная ошибка. Cleanup failure блокирует QR и даёт только Retry cleanup.
- [ ] Написать `test_registered_save_then_expired_jwt_uses_token_retry`: RegistrationFailure.registeredBinding переводит в registered auth-error без автоматического удаления ключа.
- [ ] Написать `test_cancel_during_save_cleans_late_registered_result`, `test_cancel_after_jwt_before_reveal_resets_binding`, `test_marker_failure_after_reset_blocks_welcome`: порядок stop manager → close bridge/container → reset store → restore none → welcome; loading без кнопок на очистке; ошибку маркера повторять restore.
- [ ] Написать confirm/decline и двойное нажатие: decline ничего не удаляет; confirm тот же reset-path, камера автоматически не открывается. StartOver первичной ошибки не повторяет старый QR и не хранит его в RetryContext.
- [ ] Запустить unit, подтвердить падения; реализовать переходы по спецификации coordinator §§5,7–9. QR держать только в Task первичной регистрации и освобождать после её завершения/отмены. Не записывать его в состояние экрана или журнал. Ошибки переводить в безопасный NativeErrorPresentation.
- [ ] Добавить debug-only тестовую композицию с fake store/auth/permission и подачей распознанной строки на Simulator. Разрешить её только DEBUG + Simulator + явный UI-test launch flag; удалить возможность в Release. Фикстуры без реальных JWT/приватных ключей на диске; real local token получать в integration helper, не через токен в argv.

Контрольные assertions для описанных выше фикстур:

```swift
// test_cancel_after_jwt_before_reveal_resets_binding
#expect(manager.currentSession == nil)
#expect(restoredAfterCleanup == nil)
guard case .welcome = coordinator.screen else {
    Issue.record("Expected welcome after completed cleanup")
    return
}
```

- [ ] Запустить unit/ui local, PASS; коммит `feat: implement QR binding and cancellable local reset`.

### Task 11: Готовность, повторы веба и восстановление процесса

**Файлы:** создать AppCoordinator+WebPreparation.swift; расширить AppCoordinator/AppState/CoordinatorTests; создать `WebReadinessTests.swift`, дополнить WebKit integration.

**Интерфейсы:** потребляет onReady bridge, WebSessionEvent, SessionClock, currentSession/events; производит reveal, 60-second active budget, explicit retry и one-shot process recovery.

- [ ] Написать `test_reveal_requires_ready_valid_session_and_foreground`: DOM-ready/mailbox-ready не подходят; content/error screen допустимы; stale identity и ранний ready без требуемой сессии отклоняются, JS может повторить.
- [ ] Написать `test_readiness_budget_counts_60_active_seconds`, `test_refresh_and_redirect_do_not_restart_budget`, `test_accepted_ready_cancels_budget_even_when_hidden`: 59s ещё loading, 60s error; background не расходует остаток; после accepted-ready ожидание foreground/JWT не вызывает таймаут.
- [ ] Написать `test_auth_retry_after_background_ready_replaces_document`, `test_web_retry_uses_valid_jwt_without_http`, `test_native_error_survives_passive_auth_failure_and_success`: auth Retry всегда реальная token attempt, успех → новый document/ready; web Retry с validJWT → только новый document. Ошибка веба не заменяется entryFailed/working-error.
- [ ] Написать `test_full_navigation_preserves_working_mode_and_shows_cancel`, `test_process_death_gets_one_recovery_then_error`: до первого показа process death → native error; после показа одна auto-reload, сбой/timeout → Retry/Rebind; успешно восстановившийся документ допускает одну попытку при новом независимом death.
- [ ] Запустить unit, подтвердить падения; реализовать readiness state в координаторе с identity, accepted screen и remaining Duration. Бюджет стартует после JWT, pause/resume считает active time тем же clock; ready отменяет timer. Не запускать новый таймер после принятия. Во всех callback проверять scenario/container/attempt/document.
- [ ] Реализовать explicit auth/web Retry по ограниченным контекстам; старые bridge waiter/ready отзывать сразу. Сохранить правило задачи 9: после actual reveal единственный вызов manager.webViewDidBecomeVisible; проблемы JWT в рабочем документе только события bridge, без скрытия/reload. Full nav создаёт новую подготовку с cancel, режим manager остаётся working.
- [ ] Подключить webViewWebContentProcessDidTerminate. Реальное завершение WK-процесса не вызывать закрытым/private API: unit управляет callback, integration проверяет публичный reload/reinjection и обновление documentId.

Контрольные assertions для описанных выше фикстур:

```swift
// test_accepted_ready_cancels_budget_even_when_hidden
#expect(readinessTimeoutCount == 0)
#expect(revealedDocumentId == acceptedDocumentId) // foreground + valid JWT fixture
```

- [ ] Запустить unit/integration/ui local, PASS; коммит `feat: coordinate WebView readiness and recovery`.

### Task 12: Полный debug-сброс, смена окружения и диагностика

**Файлы:** создать App/OwnedClientDataCleaner.swift, `OwnedClientDataCleanerTests.swift`; расширить AppCoordinator+Reset, DebugPanel, DiagnosticMailbox/LaunchConfiguration при необходимости wiring, существующие CoordinatorTests/DebugPanelUITests/DiagnosticMailboxUITests; дополнить WebKit reset integration.

**Интерфейсы:** `OwnedClientDataCleaner.clean(remaining: Set<OwnedDataCategory>) async -> OwnedCleanupProgress` возвращает незавершённые категории и безопасные ошибки, успех только при пустом remaining. Существующие switchEnvironment/resetClientData теперь используют stop/close и этот путь; обычный local reset всё ещё BindingStore.reset.

- [ ] Написать `test_full_reset_removes_all_owned_data_including_keychain_marker`, `test_partial_failure_retries_only_remaining_categories`: тестовый app-owned service/файлы/UserDefaults/web cache очищаются; ошибки не объявляют успех, новая авторизация заблокирована. Данные других приложений/чужие keychain services не трогать.
- [ ] Написать `test_environment_cleanup_failure_keeps_old_configuration_and_target`, `test_same_scope_switch_still_discards_memory_jwt`, `test_switch_restarts_restore_before_auth`: разные databaseScope → согласованная очистка; одна область → привязка может остаться, JWT и старый doc всегда удалены. Отложенный ответ старого API не применяется. Проверки смены test/prod — только с fake dependencies, без запросов к ним.
- [ ] Написать diagnostics-тесты: подготовленный hidden WebView доступен mailbox, diagnostics-ready не раскрывает веб, reset закрывает mailbox до удалений; Release не экспортирует debug executor. sessionStateRevision остаётся диагностическим счётчиком, не JWT/protocol version.
- [ ] Запустить unit/ui, подтвердить падения; перечислить app-owned Keychain services/accounts явно, удалить все принадлежащие приложению записи (не только декодируемый binding), app-owned Application Support/Caches/Documents файлы, defaults domain, WKWebsiteDataStore.allWebsiteDataTypes. Для WebKit после completion проверить оставшиеся records; сохранять ошибки других категорий. Удаление файлов выполнять после остановки mailbox/tasks, включая diagnostic-events.jsonl, handshake/mailbox файлы и app-owned временные файлы. До успеха удаления не записывать новые диагностические файлы в очищаемые каталоги; после завершения можно начать новый журнал. Не удалять bundle или sandbox чужих приложений.
- [ ] Подключить повтор полного reset и environment-switch с контекстом этапа; target применяется только после успешной необходимой очистки. После успеха start-path logo/restore/first-frame. Обычный cancel/rebind сохраняет install marker и web cache.
- [ ] Дополнить уже адаптированные в9 UI/integration-тесты полным очистителем; не возвращать debug auth bypass. Сохранить существующие EnvironmentTests/DiagnosticExecutorTests. Unit cleaner получает fake adapter, реальный persistent WebKit reset проверяется только сериализованным integration suite.

Контрольные assertions для описанных выше фикстур:

```swift
// test_partial_failure_retries_only_remaining_categories
#expect(progress.remaining == [.keychain])
#expect(appliedEnvironment == previousEnvironment) // failed switch fixture
```

- [ ] Запустить unit/integration/ui local; при изменении CLI дополнительно `python3 -m unittest discover -s scripts/tests`. PASS; коммит `feat: integrate complete reset and session diagnostics`.

### Task 13: Сквозная приёмка на Simulator и отчёт

**Файлы:** расширить `WebSessionIntegrationTests+LocalAuth.swift`, `WebSessionIntegrationTests+Bridge.swift`, AuthorizationUITests; создать `docs/development/mobile-session-verification.md`.

**Интерфейсы:** готовая production composition, configured local backend/web, свежий временный carToken. Никаких новых business API ради тестов.

- [ ] Добавить `test_local_binding_to_real_web_ready`: свежий tmp token → QR агента → actual store/client/manager/bridge → готовность real local web → reveal той же WKWebView. Проверить carId, ответ bridge, отсутствие welcome flash при последующем startup с RegisteredBinding. Секреты не логировать; временное app-owned storage после теста удалить.
- [ ] Добавить `test_local_rebind_uses_new_key_and_new_webview`, `test_local_cached_assets_survive_ordinary_reset`, `test_full_debug_reset_removes_persistent_web_data`: кеш проверять наблюдаемыми website data/cache fixtures, а не обещанием offline-запуска любого веба. В качестве условий использовать существующий local стенд либо изолированный localhost test HTTP fixture; другие сетевые адреса запрещены.
- [ ] Сквозные failure-paths с управляемым local HTTP fixture: offline/30s timeout/403 unknown code/неправильный ответ, retry, cancel на границе save/ready, 401 recovery, token expiration и восстановление. Свежий токен получать перед каждой реальной регистрацией; не ждать 15 минут — scheduling и expiry доказываются FakeClock unit/integration composition.

Контрольные assertions для описанных выше фикстур:

```swift
// test_local_binding_to_real_web_ready
#expect(session.carId == "e0f1c2b3-ce9d-4e0a-95e3-fe4bf1f519f6")
#expect(revealedContainerId == preparedContainerId)
```

- [ ] Запустить preflight local, полный `--suite all` на Simulator, Python suite при изменённых скриптах; проверить завершённый `.xcresult`, ненулевые unit/integration/ui количества и отсутствие новых failures. Отдельно собрать Release для Simulator без запуска сети и проверить наличие business bridge/отсутствие debug hooks: `xcodebuild -project ZDEEP/ZDEEP.xcodeproj -scheme ZDEEP -configuration Release -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath .artifacts/release-check CODE_SIGNING_ALLOWED=NO build`.
- [ ] Сохранить отчёт: команды, commit, local endpoints, Simulator UDID/runtime, paths к результатам, новые сценарии, итоговые количества, ограничения. Не писать «камера/реальный фон проверены» по результатам симуляции; приложить screenshot нативной ошибки/логотипа и зафиксировать замечания визуальной приёмки.
- [ ] Выполнить итоговое ревью всей ветки по восьми спецификациям и этому плану; исправления повторно проверять затронутым набором, затем all перед передачей. Коммит `test: verify mobile session on local simulator`.

## Завершение без физического устройства

Задача полностью завершена после реализации, исправления результатов итогового ревью и успешных обязательных проверок задачи 13 на Simulator с `local`. Доступ к iPhone пользователя, настройка local-сети для телефона и доработка device-команд не входят в этот план и не являются условиями завершения.

На Simulator камера подменяется результатом сканирования; permission, Settings-return, foreground/background, истечение background entitlement и приостановка моделируются управляемыми адаптерами. Настоящие URLSession, Security/CryptoKit и WKWebView проверяются на Simulator, подпись и привязка — на реальном local backend.

Отчёт честно отделяет эти проверки от проверки оптики камеры, hardware-specific WebKit поведения и фактического решения iOS о времени работы в фоне на физическом устройстве. Эти ограничения не блокируют завершение. Дополнительная проверка на устройстве возможна только как отдельная будущая задача по желанию пользователя.

## Самопроверка плана

| Требования спецификаций | Задачи |
| --- | --- |
| Durable registered, reinstall, pending/resetting, ошибки Keychain | 1, 3, 10, 12 |
| SPKI/DER proof, exact body, JSON/JWT validation, clock offset, timeout, redirects | 2 |
| Общая auth-operation, независимая отмена, reentrancy, duplicate JWT | 3, 7 |
| Every-token scheduling, entry/working, retry после expiry, foreground/background | 4, 11 |
| Camera permission, QR, StartOver, confirmation, no new QR during cleanup | 5, 8, 10 |
| Exact origin, document grant/commit, history, cache, освобождение WebView | 6, 7, 12, 13 |
| Four methods, events, no local web clock, structured reply, Release | 7, 13 |
| Logo, first actual native frame, early hidden preload, existing welcome | 8, 9 |
| 60 active seconds, accepted-ready stops budget, retry contexts, process death | 11 |
| Reset всех app-owned данных, environment switch, existing diagnostics | 12 |
| Только local, Simulator first, реальные временные токены, итоговая приёмка | 2, 13 |

Проверены согласованность имён межзадачных интерфейсов и наличие тестов для пяти рисков ревью. План задаёт контракт, конкретные файлы и ожидаемые результаты; детали Swift concurrency compatibility проверяются сборкой текущего toolchain без повышения deployment/language version.

## Источники технических решений

- Через Context7: `/swiftlang/swift` — ContinuousClock/Task cancellation; `/twostraws/codescanner` — `.once`, `.qr`, адаптер SwiftUI; `/websites/developer_apple_uikit` — display-link синхронизация. FirstFrameProbe использует доступный на iOS 17.6 CADisplayLink(target:selector:), не новый UIWindowScene.displayLink API.
- [CodeScanner 2.5.2](https://github.com/twostraws/CodeScanner/releases/tag/2.5.2): фиксируем опубликованный релиз, без автоматического повышения версии.
- WebKit/Keychain/URLSession источники и ограничения приведены в спецификациях компонентов; повторные проектные решения не вводятся.
- [Готовые команды проверки](../../development/verification.md) и [.agents/skills/ios-testing/SKILL.md](../../../.agents/skills/ios-testing/SKILL.md): для этой функции правило пользователя «только local» имеет приоритет над примерами запуска test.
