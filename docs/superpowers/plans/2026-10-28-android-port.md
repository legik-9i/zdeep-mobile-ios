# ZDEEP Android Port Implementation Plan

**Scope clarification (2026-11-02):** All native Android code, including Kotlin `app/src/main/java/ru/zdeep/mobile/web/**`, may be changed. The prohibition applies to the separate `/Users/oleg/projects/zdeep-webview2` repository. The earlier native-WebView prohibition was an agent interpretation error. Website Back/modal handling and Stackflow theme are a separate task and do not block completion of the native Android port.


> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver the complete user-facing iOS functionality in an installable testing Debug APK, with meaningful local tests and production configuration prepared for a later release.

**Architecture:** One Kotlin/Compose Activity hosts the existing web app in an Android WebView. Port the existing iOS authentication/session rules; use Android Keystore, AndroidX WebKit, CameraX and ML Kit for platform integration. Shared Stackflow Back/theme integration is deferred under the user constraint against modifying the common web repository.

**Tech Stack:** Kotlin, Compose Material 3, AndroidX Lifecycle/WebKit/CameraX, bundled ML Kit, OkHttp, kotlinx.serialization JSON, coroutines, JUnit4, MockWebServer, AndroidX Test, existing web Vitest/Playwright.

**Spec:** `/Users/oleg/projects/zdeep-mobile/ios/docs/superpowers/specs/2026-10-28-android-port-design.md` (read the entire document before Task 1, especially §§12–13).

**Status (2026-11-01):** Android implementation for the agreed native scope is in place; remaining scope limits are Task 8 Stackflow integration (deferred by the user's no-web-edit instruction), the known Task 6 same-URL TLS selector, and unbuilt production Release/R8/signature. Android 16/API 36 is the development and emulator-test target (`minSdk=30`). Current-source JVM suites pass 99/99 each, Debug lint and Local/Testing Debug plus androidTest assemblies pass; the platform suite remains 37 passed / 1 known TLS skip. Task 7 now routes bridge unlink and native RESET/REBIND through one UI-owned close-then-cleanup callback; `AppLocalFlowTest` passed 1/1. Full ordered Task 10 driver `run-20261101T172612Z-9698` passed process/restore, install-over, offline scope cleanup, renderer recovery, uninstall/reinstall, fresh Virtual Scene QR decode and camera pairing through business content. The dedicated AVD config has `hw.gpu.enabled=no`; with runtime-only `-gpu host -memory 6144`, focused prepare/restore passed (1/1 each) and the full driver passed. The AVD config itself was not changed. Testing Debug was restored and verified: version 0.1.0, minSdk 30, targetSdk 36, installed SHA-256 `8deec23d7b703b0a3a7bdc12a37c0a8a5ed014a22f8dc0b0db4713d0fe790abb`. Final Sol High source/evidence audit after this driver: 12 PASS / 3 PARTIAL / 0 FAIL (NAV-01, BACK-01, ENV-01). No Android WebView product or shared-web sources were edited.

The Android checkout currently has no `.git` directory, so the per-task local commit steps were not possible there. No production APK or bundle has been built, as required. The shared web repository has not been edited or tested.

## Global Constraints

- Android 11+ (`minSdk=30`); ordinary phones, portrait. One application ID: `ru.zdeep.mobile`, with no flavor suffix.
- Variants: `localDebug`, `testingDebug`, `productionRelease`. Build/deliver Debug only. **Do not assemble/bundle productionRelease, even unsigned.** No production signing key is needed for this task.
- Local API/web already exist: host ports 4002/4005; emulator uses `10.0.2.2`. All automated backend traffic is local. User performs testing acceptance later; do not request their QR image.
- Native behavior follows current iOS code/tests. No debug panel, JS mailbox, Firebase, native Sentry, new product features, server revocation, multi-car selection, or new backend service.
- Existing web Sentry remains. Never log real JWT, QR payloads, signatures or private keys.
- Preserve public bridge methods and DTOs. Do not claim Android system Back reaches Stackflow while the common web host adapter is deferred. No predictive-progress integration, history or DOM workaround.
- Use existing illustrations/text/fonts; replace ThinkingOrb with the stock Android spinner. Respect font scaling, TalkBack and reduced motion.
- Russian specification/README/product copy; English implementation plan. Local Git only: no GitHub API/CLI, fetch, pull, push, clone or PR.
- Native implementation/fixes: Luna High; routine review: Terra medium. If the same review finding survives Luna's fix, Sol investigates and applies the narrow fix, then Luna tests it. Whole-change final review: Sol High. No Astra.
- User scope update (2026-10-29): do not edit `/Users/oleg/projects/zdeep-webview2` or any shared web repository. Task 8 is deferred; Android host Back cannot drive Stackflow modals/navigation without the web host adapter. Continue Android-only tasks and report this parity gap; do not claim complete parity until separately authorized.

## Current execution status (2026-11-01)

| Task | Status | Evidence / open condition |
|---|---|---|
| 1–5 | Implemented; scoped checks recorded | See verification ledger. API 36 is the development and test target; `minSdk=30`. |
| 6 | Implemented; one edge deferred | Same-URL recoverable TLS subresource during PREPARING remains ambiguous and its regression case is skipped pending behavior choice. |
| 7 | Implemented; lifecycle checks passed | `InFlightActivityRecreationTest` proves suspended pair/save survives real Activity recreation with one pair/save operation; `ReadyActivityRecreationTest` proves a fresh WebView/request epoch and ready document after recreation. JVM regressions cover stale callbacks and readiness deadlines. |
| 8 | Deferred by user scope | Requires shared web host/theme changes. Do not edit or test the shared web repository. |
| 9 | Implemented; emulator checks recorded | Native screens, camera QR scan and About flow are covered; see ledger. |
| 10 | Ordered local acceptance passed on current source | Historical localbackend package: 15 passed, 6 expected host-driver skips, 0 failures. Current full ordered driver `run-20261101T172612Z-9698` passed on API 36 with runtime-only `-gpu host -memory 6144`: network probe (3/3), fresh pair/business content, process restore after force-stop, same-scope install-over, offline local→Testing scope cleanup, pre-reveal and repeated renderer loss/recovery, uninstall/reinstall Welcome, fresh Virtual Scene QR hash decode, and camera pair through business content. Earlier JS callback timeouts occurred with the dedicated AVD's `hw.gpu.enabled=no` configuration and severe UI jank; host GPU correlated with the focused and full passes, but does not prove the cause of every prior timeout. Testing Debug was manually restored and its installed SHA-256 verified against the rebuilt artifact. Full run evidence is in the verification ledger. |
| 11 | Debug delivery ready; final audit refreshed | Current-source local/QA JVM suites pass 99/99 each; Local/Testing Debug lint and app/androidTest assemblies pass. API 36 platform suite remains 37 passed, 1 known TLS ignore. Current Task 10 full ordered driver `run-20261101T172612Z-9698` passes all phases. `AppLocalFlowTest` passed 1/1 after the shared unlink callback change. Final Sol High source/evidence audit: 12 PASS / 3 PARTIAL / 0 FAIL (NAV-01, BACK-01, ENV-01). No production Release build or physical-device run. Current Testing APK SHA-256: `8deec23d7b703b0a3a7bdc12a37c0a8a5ed014a22f8dc0b0db4713d0fe790abb`. |

## Review Focus

1. Switching local↔shared database scope by installing an APK over the existing one must clear binding before authentication; testing↔production stays in the shared scope (Tasks 3, 10).
2. Recomposition, Activity recreation, or backgrounding during pair/storage must not create a second pair or apply an old result after unlink (Tasks 5, 7, 10).
3. An inline script in a redirect/reloaded page can call the bridge before normal page-finished callbacks; old document authority must already be revoked (Task 6, mandatory early gate).
4. Two Back commands during a sheet exit, or Back during destructive submission, must not reach the page underneath (Tasks 8, 10).
5. Persistent malformed metadata or a missing Keystore key must produce a recoverable native error, not silently delete evidence and show welcome (Tasks 3, 7).

## Sources, repositories and boundaries

- iOS root (`I`): `/Users/oleg/projects/zdeep-mobile/ios`; inspected commit `72e4a3a74b1ae97870d3a60aff87a963308e6048`.
- Web root (`W`): `/Users/oleg/projects/zdeep-webview2`; inspected commit `9892541edeba2f87a72e3ae9d3bbf9a11c230623`.
- Android root (`A`): `/Users/oleg/projects/zdeep-mobile/android`; created by the user and confirmed present, currently empty. All Android paths below are relative to `A`.
- Source prefixes: `IS=I/ZDEEP/ZDEEP`, `IT=I/ZDEEP/ZDEEPTests`. These are path abbreviations for reading, not required shell environment variables.
- At execution start record actual revisions and working changes. If sources changed, review the relevant diff against these references; never reset unrelated work. Copy the approved specification and this plan into Android `docs/superpowers/{specs,plans}/` for a standalone handoff, recording their source revision/date; maintain the Android copies as authoritative once implementation starts.
- For web tooling, read `W/AGENTS.md` and applicable nested instructions. Existing web dependencies primarily live in Docker's volume; do not install Linux dependencies into a macOS checkout or copy a stale worktree cache. Use the documented container context if host dependencies are absent.

## Fixed baseline and commands

Choose these versions in `gradle/libs.versions.toml`; do not replace them with latest while fixing an unrelated failure:

| Item | Pin / setting |
| --- | --- |
| Gradle runtime | Installed Android Studio JBR 21.0.8; Java/Kotlin bytecode target 17 |
| Gradle Wrapper / AGP | 8.13 / 8.11.1 (documented compatible pair, max compile API 36) |
| Kotlin / Compose compiler plugin | 2.2.21 / 2.2.21 (AGP 8.11.1 is inside Kotlin's documented supported range) |
| SDK | min 30, compile 36, target 36; installed build-tools 35.0.0 |
| Compose BOM | 2025.10.01, shared by implementation and androidTest |
| Core / Activity / Lifecycle | core-ktx 1.17.0 / activity-compose 1.11.0 / lifecycle-runtime-ktx, runtime-compose, viewmodel-compose 2.9.4 |
| WebKit | 1.15.0; use stable `addWebMessageListener` / `addDocumentStartJavaScript`, not experimental navigation APIs |
| CameraX | camera-camera2, camera-lifecycle, camera-view, camera-mlkit-vision 1.5.3; includes the Android 17 dynamic-range crash fix missing in 1.5.1 |
| ML Kit | `com.google.mlkit:barcode-scanning:17.3.0` (bundled) |
| Coroutines / JSON | kotlinx-coroutines-android/test 1.10.2; kotlinx-serialization-json 1.9.0; use JsonElement/JsonObject, no compiler serialization plugin needed |
| HTTP / fixture HTTP | OkHttp / MockWebServer 4.12.0 (same line; MockWebServer test dependencies only) |
| Tests | JUnit 4.13.2; AndroidX test runner/core/rules 1.7.0; ext:junit 1.3.0; UI Automator 2.3.0; Compose ui-test-junit4 from BOM |

Do not add Retrofit, Hilt/Koin, Room, Robolectric, JUnit5, Firebase or logging interceptors. Dependencies go only in the source set that needs them. Use Google Maven/Maven Central; no JitPack. Resolve metadata and run `checkDebugAarMetadata` through the Debug build in Task 1. If the baseline fails, record the exact compatibility error and fix the narrow mismatch using official docs; update this table/spec handoff before continuing, rather than enabling suppressions or random upgrades.

`targetSdk=36` is an implementation choice, not an asserted RuStore publication deadline. The reviewed RuStore guide reads the minimum version from the manifest; publication is deferred, so recheck publication requirements at release time rather than importing Google Play policy.

Shell setup for the current Mac (README must explain how another developer supplies their paths):

```sh
export JAVA_HOME='/Applications/Android Studio.app/Contents/jbr/Contents/Home'
export ANDROID_SDK_ROOT='/Users/oleg/Library/Android/sdk'
export ANDROID_SERIAL='<selected-running-emulator-serial>'
```

Use `ANDROID_SERIAL` to select exactly one running emulator; report its actual API/ABI/WebView provider. Keep machine paths out of committed Gradle properties. Bootstrap the wrapper from an existing cached Gradle 8.13 executable or official Gradle distribution, and obtain `distributionSha256Sum` from the official checksum; never download/copy a wrapper from GitHub. Use the Wrapper thereafter.

Standard commands, run in `A` after Task 1 creates the project:

```sh
./gradlew :app:testLocalDebugUnitTest --tests 'ru.zdeep.mobile.tests.unit.*'
./gradlew :app:testLocalDebugUnitTest --tests 'ru.zdeep.mobile.tests.component.*'
./gradlew :app:connectedLocalDebugAndroidTest -Pandroid.testInstrumentationRunnerArguments.package=ru.zdeep.mobile.tests.platform
./gradlew :app:connectedLocalDebugAndroidTest -Pandroid.testInstrumentationRunnerArguments.package=ru.zdeep.mobile.tests.localbackend
```

Set `android.testInstrumentationRunnerArguments.class=<FQCN>#<method>` for a single Android test. JVM `--tests '<FQCN>.<method>'` selects one test. No selector means the instrumentation run includes localbackend; never call it platform-only. Use JUnit4 names/packages exactly as below. Integration fixture `support` packages contain no runnable tests. Test reports must include nonzero executed tests and no ignored mandatory cases.

## File structure and interfaces

One app module; package root `ru.zdeep.mobile`. Main code under `app/src/main/java/ru/zdeep/mobile/`:

| Files | Responsibility |
| --- | --- |
| `MainActivity.kt`, `app/AppRoot.kt`, `app/AppViewModel.kt`, `app/AppState.kt`, `app/NativeErrorPresentation.kt` | UI ownership, lifecycle, user flow and readiness; no parallel native web-navigation stack |
| `environment/AppEnvironment.kt`, `session/SessionClock.kt` | Build endpoints/data scope; monotonic and wall clocks |
| `session/AuthModels.kt`, `AuthResponseValidator.kt`, `BindingStore.kt`, `AndroidBindingStore.kt`, `AuthClient.kt`, `OkHttpAuthTransport.kt`, `SessionManager.kt`, `SessionRefreshPolicy.kt` | Existing authentication rules and the few boundaries required by tests |
| `web/WebLaunchUrl.kt`, `WebNavigationPolicy.kt`, `WebDocumentContext.kt`, `WebSession.kt`, `NativeBridge.kt`, `BridgeModels.kt` | Launch URL, navigation, document lifetime and Android transport |
| `camera/CarQrParser.kt`, `camera/QrScanner.kt`, `ui/WelcomeScreen.kt`, `ui/LoadingScreen.kt`, `ui/NativeErrorScreen.kt`, `ui/AboutSheet.kt`, `ui/ZdeepTheme.kt` | Native screens, resources, official scanner integration |
| `app/src/main/assets/bridge-bootstrap.js` | Existing JS API with Android request/reply transport |
| `app/src/main/res/`, `app/src/local/res/xml/network_security_config.xml` | Images/fonts/icons/copy, common deny-cleartext config, local-only HTTP override |
| `app/src/test/java/ru/zdeep/mobile/tests/{unit,component,support}/` | JVM unit/component tests and deterministic fakes |
| `app/src/androidTest/java/ru/zdeep/mobile/tests/{platform,localbackend,support}/` | Real Android boundaries and local backend tests |
| `app/src/androidTest/{assets,AndroidManifest.xml}` | Fixture HTML, isolated test host Activity; not in product APK |
| `scripts/local-preflight.py`, `scripts/check-process-restart.sh`, `README.md` | Small preflight and multi-process acceptance driver; Gradle remains the test/build runner |

Create only the files belonging to the current task; do not scaffold empty layers. Main/test constructors accept only dependencies the tests actually replace.

## Task 1: Reproducible project, variants and test runners

**Requirements:** ENV-01; infrastructure gate (§12.2).

**Files:** Create root `settings.gradle.kts`, `build.gradle.kts`, `gradle.properties`, `gradle/libs.versions.toml`, wrapper files, `.gitignore`, `AGENTS.md`; `app/build.gradle.kts`, `app/proguard-rules.pro`, main manifest, deny-cleartext and local network XML, `MainActivity.kt`, `res/values/{strings,themes}.xml`; tests `unit/BuildContractTest.kt`, `platform/{ActivityLaunchTest,WebViewCapabilityTest}.kt`, `localbackend/LocalNetworkProbeTest.kt`; Russian README setup section.

**Interfaces:** Produces BuildConfig `ENVIRONMENT`, `WEB_BASE_URL`, `API_BASE_URL`, `DATA_SCOPE`, `BRIDGE_VERSION="0.0.2"`; MainActivity initially displays accessible `ZDEEP`. Namespace/applicationId `ru.zdeep.mobile`. Variant endpoint values are exact spec §9 values, including the iOS testing storage URL and `/testing/` API prefix.

- [ ] Write `BuildContractTest.localHasApprovedIdentity`: assert local BuildConfig environment/scope, exact two emulator URLs and `DEBUG=true`. Write `ActivityLaunchTest.opensActivity`: launch MainActivity and assert a displayed ZDEEP root and package manager min/target SDK 30/36 (Android 16/API 36 target). These tests prove runner wiring/compiled configuration; do not count them as product acceptance.

```kotlin
assertEquals("local", BuildConfig.ENVIRONMENT)
assertEquals("http://10.0.2.2:4002", BuildConfig.API_BASE_URL)
assertEquals("http://10.0.2.2:4005", BuildConfig.WEB_BASE_URL)
assertTrue(BuildConfig.DEBUG)
```
- [ ] Create the minimal Gradle project using the fixed baseline, explicit Java/Kotlin target 17 and AndroidJUnitRunner. Flavor dimension `environment` with local/testing/production. Disable unintended combinations with Android Components variant selection: retain only localDebug, testingDebug, productionRelease. Release signing configuration must be optional at configuration time, absent key must not break Debug tasks, and no debug signing fallback is allowed.
- [ ] Wire INTERNET/CAMERA, launcher export, ordinary-phone portrait, backup disabled with cloud/device-transfer exclusion rules; keep non-exported test hosts out of main manifest. local-only cleartext config permits the development HTTP origins, testing/production deny cleartext. Set WebView debugging based on Debug, never from a JavaScript parameter.
- [ ] Run `./gradlew --version`, then `./gradlew :app:assembleLocalDebug :app:assembleTestingDebug :app:testLocalDebugUnitTest`. Expected: JBR 21, resolved pinned dependencies, two Debug APKs, the nonzero JVM test result. No release assembly task.
- [ ] Provision/use one dedicated phone AVD `Zdeep_API36` (`system-images;android-36;google_apis;arm64-v8a`) for all development and Android test suites. First confirm the exact stable package/device profile with `sdkmanager --list` and `avdmanager list device`; do not use a preview image. Configure rear camera Virtual Scene; cold boot/wait for actual boot completion, not a fixed sleep. Do not wipe or change unrelated AVDs. `minSdk=30` remains the install floor; API 30 is not a required test target.
- [ ] Select one stable phone with `ANDROID_SERIAL`, install local Debug and run the platform package command. Expected: ActivityLaunchTest and WebViewCapabilityTest actually execute; the latter constructs a real WebView and verifies both required feature flags/provider without backend. Separately run localbackend.LocalNetworkProbeTest with the Android class selector to verify direct 200 responses at local API `/health` and web root from the emulator (reuse in Task 4). This network probe must never be inside the platform package. Stop here on build, package, test discovery, provider or connectivity failure.
- [ ] Record SDK/JDK/AVD/provider details and actual output/report locations in README. Add project AGENTS: inherit local-only/no-GitHub/model routing, approved spec, exact test commands. Local commit scoped files: `chore: bootstrap Android variants and tests`.

## Task 2: Pure authentication types, clocks, validation and QR rules

**Requirements:** AUTH-03, SESSION-03 (policy), QR-01 (parser), ENV-01.

**Files:** Create `environment/AppEnvironment.kt`, `session/{AuthModels,AuthResponseValidator,SessionClock,SessionRefreshPolicy}.kt`, `camera/CarQrParser.kt`, `web/WebLaunchUrl.kt`; `unit/{AuthResponseValidatorTest,CarQrParserTest,SessionRefreshPolicyTest,WebLaunchUrlTest}.kt`; `support/{TestSessionClock,AuthFixtures}.kt`.

**Read:** IS `Session/{AuthModels,AuthResponseValidator,SessionClock,SessionRefreshPolicy}.swift`, `Camera/CarQRParser.swift`, `Web/WebLaunchURL.swift`; corresponding IT tests. Read numeric/Base64 rules, not just happy-path assertions.

**Interfaces:**
- `data class AuthSession(accessToken:String, userId:String, carId:String, expiresAt:String, deadlineMs:Long, serverTimeMs:Double, attemptId:UUID)`.
- `AuthFailure : Exception` carries kind (`network|timeout|server|local|invalid-response`), stage, attemptId, message, httpStatus?, serverCode?, diagnosticCode. Do not expose Throwable's raw message as product copy.
- `AuthResponseValidator.validate(body:ByteArray, stage:AuthStage, attemptId:UUID, expectedCarId:String?, expectedPairCarId:String?, sentAtMs:Long, receivedAtMs:Long):AuthSession`; `timestampFailure(body):TimestampFailure?`, `carIdFromJwt(token):String?`.
- `interface SessionClock { val nowMs:Long; val wallTimeMs:Double; fun schedule(deadlineMs:Long, action:()->Unit):CancellationHandle }`; `CancellationHandle.cancel()`. Production now uses elapsed realtime; tests tie now/scheduling to one TestCoroutineScheduler, with independently adjustable wall time.
- `CarQrParser.parse(value:String):CarQr` with `CarQr(carToken:String,carId:String)`. `WebLaunchUrl.make(baseUrl:String,appVersion:String,bridgeVersion:String,theme:String):String`. `SessionRefreshPolicy.refreshDeadlineMs(session:AuthSession):Long` and `retryDelayMs(failureCount:Int):Long`.

- [ ] Write failing tests: boolean/nonfinite/overflow numeric claims rejected; exact audience string/array rules; mismatched car/user rejected; `expiresIn=900` means seconds. Example fixture (`serverTime=1_000_000`, `exp=1_900`, sent=0, received=250) must produce `deadlineMs=900_000`, preserving the iOS deduction for delivery time. QR duplicate token/malformed payload fails. URL uses `/index.html`, platform android, nativeAppVersion/bridgeVersion/theme once, retaining unrelated query.
- [ ] Run the exact four unit classes with JVM `--tests` selectors; expected failures name missing implementation or assertions, not unavailable Android APIs.
- [ ] Implement using JDK URI/Base64 and kotlinx JSON; reject Boolean where a numeric claim is required; port iOS bounds and ISO formatting. Do not verify QR JWT with a fabricated client secret. Introduce no Android URI/org.json dependency in this pure logic.
- [ ] Add policy assertions: refresh deadline `deadlineMs-120_000`; backoff `5_000,10_000,20_000,30_000,30_000`; wall-time jump leaves monotonic expiry unchanged. `make(...theme)` only accepts light/dark; Stackflow android/cupertino is separate.

```kotlin
assertEquals(listOf(5_000L, 10_000L, 20_000L, 30_000L, 30_000L),
    (1..5).map(SessionRefreshPolicy::retryDelayMs))
assertEquals(30_000L, SessionRefreshPolicy.retryDelayMs(100))
```
- [ ] Run those unit classes; expected all cases pass with virtual time. Commit: `feat: port Android auth validation and QR contracts`.

## Task 3: Real Keystore and durable binding lifecycle

**Requirements:** STORE-01, ENV-01; Review Focus 1/5.

**Files:** Create `session/{BindingStore,AndroidBindingStore}.kt`; `unit/BindingLifecycleTest.kt`, `platform/BindingStoreTest.kt`, `support/{FakeBindingStore,FailingBindingMetadata}.kt`.

**Read:** IS `Session/BindingStore.swift`, `BindingModels.swift`, `BindingRecordStorage.swift`, `BindingInstallMarkerStorage.swift`; IT BindingStoreTests; IS `Environment/AppEnvironment.swift` and AppCoordinator scope-switch cleanup.

**Interfaces:** `PendingBinding(bindingId:UUID,publicCertificate:String)`, `RegisteredBinding(bindingId:UUID,publicCertificate:String,carId:String)`; `BindingStore` has suspend `restore():RegisteredBinding?`, `beginRegistration():PendingBinding`, `sign(bindingId:UUID,bytes:ByteArray):ByteArray`, `completeRegistration(bindingId:UUID,carId:String):RegisteredBinding`, `reset():Unit`. Android implementation accepts application context, data scope and scoped metadata/key dependencies only where needed for failure tests.

- [ ] Write lifecycle tests for pending/resetting cleanup, malformed metadata error, public-key mismatch, registered missing alias error, reset write/delete failures, and serialized begin/sign/reset. Unit fakes exercise policy/failure positions; platform tests exercise actual storage.
- [ ] Run `BindingLifecycleTest` (JVM) and `BindingStoreTest` (Android class selector); expected red. No real backend needed.
- [ ] Implement EC `secp256r1`, SHA256withECDSA, no biometric gate; export public `.encoded` SPKI, not the Keystore certificate. Persist metadata with AtomicFile in noBackupFilesDir under a serialized access path, running crypto/disk work off main. Keep iOS pending/registered/resetting rules and validate alias/public key consistency.
- [ ] Own aliases have a fixed app prefix and binding UUID; test instances add isolated prefixes. Crash after key generation/before metadata write leaves an app-owned orphan to clean safely on restore. Do not delete arbitrary Keystore entries or treat a read failure as a clean install. Account for key+file not being a single transaction.
- [ ] Persist last database scope outside backup: local→shared/shared→local must finish cleanup before restore. Testing/prod share scope. Ordinary same-scope update keeps binding. Confirm deletion before welcome/new pair; if deletion fails, retain retryable cleanup state.
- [ ] Run platform round-trip: create/sign, verify with JCA public key, construct new store and restore binding, reset and confirm missing metadata/alias. Run JVM failure cases. Commit: `feat: persist Android binding in Keystore`.

## Task 4: Exact-byte HTTP transport and early real backend compatibility

**Requirements:** AUTH-01/02/03; early Keystore/backend gate.

**Files:** Create `session/{AuthClient,OkHttpAuthTransport}.kt`, `component/AuthClientTest.kt`, `localbackend/AuthWireTest.kt`, `androidTest/.../support/LocalAuthFixture.kt`, `scripts/local-preflight.py`; reuse/extend Task 1 `localbackend/LocalNetworkProbeTest.kt`; add JVM and Android MockWebServer test dependencies as needed.

**Read:** IS `Session/{AuthClient,AuthHTTPTransport}.swift`; IT AuthClientTests, Support/LocalAuthFixture.swift; existing I `scripts/zdeep_tools/preflight.py`. Do not copy zdeep-agent's signing interceptor (different payload and unsafe unsigned-on-error fallback).

**Interfaces:** `AuthClientPort` exposes suspend `pair(binding:PendingBinding,carToken:String):AuthSession`, `token(binding:RegisteredBinding):AuthSession`, plus `invalidateCurrentAttempt():Unit`. `AuthClient(bindingStore:BindingStore, transport:AuthHttpTransport, clock:SessionClock, apiBaseUrl:String)` implements it. `AuthHttpTransport.send(request:AuthHttpRequest):AuthHttpResponse` is suspend and cancellation-aware; request fields are `url:String`, `headers:Map<String,String>`, `body:ByteArray`; response fields are `status:Int`, `body:ByteArray`, with no reserialization. Define these boundary types in AuthModels.kt, and the small transport interface in OkHttpAuthTransport.kt. `LocalAuthFixture.fetchFreshCarToken(apiBaseUrl:String):String` exists only in androidTest.

- [ ] Write MockWebServer cases: verify DER signature over captured `X-Timestamp + "|" + request.body`, exactly one POST; no follow-up request on 307/308; 401/403/429/503 not internally retried; non-JSON error retains HTTP status; chunks do not reset total 30-second deadline; cancellation cancels Call; signing failure sends zero requests. Offset correction only affects the next explicit attempt, never causes a hidden retry.
- [ ] Run component test class; expected red. Use JCA P-256 in the JVM signing fixture; leave real Keystore proof to AuthWireTest.
- [ ] Implement one OkHttpClient with total `callTimeout(30s)`, `followRedirects(false)`, `followSslRedirects(false)`, `retryOnConnectionFailure(false)`. Build body bytes once, sign once, send exactly those bytes. Close responses; cancellation must cancel the corresponding call even if registered just after cancellation. Keep real I/O deadline and deterministic policy clocks separate.
- [ ] Implement preflight as a small standard-library script: only local URLs, GET API `/health` and web root, direct 200, no redirect, finite timeout and nonzero failure. Write `scripts/tests/test_local_preflight.py` for 200/redirect/unreachable and run `python3 -m unittest discover -s scripts/tests`; no custom test orchestration framework. Android LocalNetworkProbeTest uses emulator endpoints and asserts actual status; provider feature assertions stay in backend-independent platform.WebViewCapabilityTest.
- [ ] Implement fresh token POST `/get-tmp-test-car-token` with fixture carId `e0f1c2b3-ce9d-4e0a-95e3-fe4bf1f519f6`, matching IT fixture. Validate echoed carId/expiresIn=600/nonempty carToken, never print payload. AuthWireTest uses actual AndroidBindingStore + AuthClient: restore→begin→pair→complete→token; assert car/user identity and nonexpired session; clean only its local client binding. No user account deletion.
- [ ] Run `python3 scripts/local-preflight.py` (defaults: host API http://127.0.0.1:4002, web http://127.0.0.1:4005), component tests, localbackend.LocalNetworkProbeTest and localbackend.AuthWireTest on stable AVD. Expected: real pair/token accepts Android SPKI/DER, not just mocked HTTP. **Do not continue if incompatible.** Commit: `feat: sign Android mobile auth requests`.

## Task 5: Single-flight session manager and deterministic race tests

**Requirements:** SESSION-01/02/03; Review Focus 2.

**Files:** Create `session/SessionManager.kt`; `unit/{SessionConcurrencyTest,SessionRefreshTest}.kt`; `component/SessionPublicationTest.kt`; `support/ControlledAuthClient.kt`.

**Read:** IS SessionManager.swift and SessionRefreshPolicy.swift; IT SessionManagerTests.swift, SessionRefreshTests.swift. Cover publication/cancellation sequences, not only matching final state.

**Interfaces:** `SessionManager(bindingStore:BindingStore,auth:AuthClientPort,clock:SessionClock,scope:CoroutineScope)` exposes `val state:StateFlow<SessionState>` (`session:AuthSession?`, `registeredBinding:RegisteredBinding?`, `inFlight:Boolean`, `lastFailure:AuthFailure?`) and `val events:SharedFlow<SessionEvent>` with `Changed(session:AuthSession)` / `Expired(failure:AuthFailure?)`; suspend `register(binding:PendingBinding,carToken:String):AuthSession`, `updateSession(binding:RegisteredBinding?):AuthSession`, `stopAndWait():Unit`; `setActive(active:Boolean):Unit`, `webViewDidBecomeVisible():Unit`. SessionState/event definitions belong in AuthModels.kt. Bridge conversion produces the existing JS sessionChanged/sessionExpired wire events, not the Kotlin names. Use caller-independent shared operation ownership in the provided long-lived scope; no GlobalScope.

- [ ] Write the exact SESSION-01 sequence with controlled deferred completion: launch two callers, cancel first, complete one network response; assert first cancelled, second gets session, requestCount=1 and shared cancelCount=0.
- [ ] Write SESSION-02 sequence tests: storage paused means no published JWT; save failure means no JWT; expiry during successful save retains registered binding but no expired JWT; stop/unlink during save or pending reply suppresses publication/events. A changed binding cannot join an old operation. Include subscriber-triggered stop and repeated identical JWT deadline behavior from IT.
- [ ] Run those test classes, expected red. Implement minimal serialized manager ownership and generation checks using coroutines, reusing policies from Task 2. Do not cancel the shared operation when one waiting caller is cancelled; do cancel/join it on stop.
- [ ] Add virtual-time assertions for exact 120-second lead/backoff, expiry during inactive period, future deadline preservation, no new background requests, allowed completion of in-flight work, foreground catch-up, entry failure needing user retry, visible working mode continuing retry. Avoid advanceUntilIdle on recurring schedules.
- [ ] Run Unit+Component manager classes; no backend/AVD, no wall-clock sleeps. Commit: `feat: port session concurrency and refresh policy`.

## Task 6: Real WebView transport, document lifetime and navigation gate

**Requirements:** BRIDGE-01, NAV-01, WEB-02; Review Focus 3.

**Files:** Create web `{BridgeModels,WebDocumentContext,WebNavigationPolicy,NativeBridge,WebSession}.kt`, assets/bridge-bootstrap.js; unit `{BridgeContractTest,WebNavigationPolicyTest,WebDocumentContextTest}.kt`; platform `{BridgeDocumentStartTest,WebNavigationTest,RendererRecoveryTest}.kt`; androidTest fixture Activity/HTML and support `WebViewFixture.kt`.

**Read:** IS Web/*, including nested AGENTS for contract version policy; IT NativeBridgeTests, WebDocumentContextTests, WebSessionIntegrationTests(+Bridge), Fixtures/{document-start,bridge-contract}.html. Do not modify the iOS contract files merely to port their transport.

**Interfaces:**
- `DocumentIdentity(containerId:UUID,attemptId:UUID,documentId:UUID)` and typed `WebEvent` (preparing/committed/failed/processTerminated/closed) mirror existing provenance.
- `WebLoadRequest(id:UUID,url:String,reason:WebPreparationReason)`. UI-owned `WebSession(manager:SessionManager,clock:SessionClock,trustedOrigin:String,appVersion:String,bridgeVersion:String,launchTheme:String,callbacks:BridgeCallbacks)` exposes `createView(context:Context):WebView`, `applyLoad(request:WebLoadRequest):Unit`, `setActive(active:Boolean):Unit`, `dispatchBack():Unit`, `close():Unit`; it never lives in AppViewModel.
- `BridgeCallbacks` is a small callback holder: `reportReady:(DocumentIdentity,WebReadyScreen)->Unit` (may reject), `onUnlinkCar:()->Unit`, `onWebEvent:(WebEvent)->Unit`. WebReadyScreen is content/error; exact wire DTOs follow IS BridgeModels.swift and W src/shared/session/types.ts.
- Android private envelope adds `requestId` to existing `documentId/method/params`; reply echoes requestId and existing `ok/value/error/cancelled` shape. JS maintains only a per-document pending Promise map. Public five methods and `__zdeepReceiveNativeEvent(capturedDocumentId,name,detail)` stay unchanged; unlinkCar returns void and catches transport rejection.

- [ ] Write unit contract/navigation tests, then real fixture tests whose first inline script calls getHostState/getSession and awaits a correctly shaped Promise. Add `iframeCannotGetSession`, `foreignOriginCannotCallBridge`, `reloadRevokesOldReply`, `replacementRevokesBeforeInlineRequest`, `malformedParamsRejected`. Run to see red.
- [ ] Implement scoped addWebMessageListener and document-start script only after both feature checks pass. Verify actual sourceOrigin/isMainFrame/current container+document; deny wildcard origins. Prepare/revoke native document authority before each app-initiated load; connect navigation callbacks to prepared identity rather than trusting a JS-supplied document ID. Keep redirect identity stable as in iOS; new full load/reload gets a new identity. Close old pending requests with cancellation and prevent late results from entering a replacement document.
- [ ] **Mandatory early spike inside this task:** exercise native load, same-origin redirect, reload, window.location navigation and fast inline request in actual WebView; record the order of bootstrap/messages/onPageStarted/onPageCommitVisible. Confirm the identity rules against real callbacks before wiring UI. If Android ordering invalidates them, stop this task and get a narrow transport design review; do not fix with onPageFinished, delayed injection, wildcard origin or token-in-query. The spike does not authorize a different public contract.
- [ ] Implement navigation policy: trusted main origin only, explicit external HTTP(S) user link→browser, automatic foreign navigation blocked; main-frame errors affect presentation, subresource errors do not. TLS always cancelled. Never grant session to an iframe or file/data fixture origin. New windows follow current iOS policy. About WebView remains separate in Task 9.
- [ ] Trigger actual renderer termination, wait for callback, close/destroy old WebView and revoke bridge. Return processTerminated event; policy decision is Task 7. Check old instance is not reused and renderer exits during setup produce native failure. Keep the test bounded; missing renderer handle is a failed prerequisite, not a skip.
- [ ] Run the three unit classes and three platform classes. Expected: early bridge, redirects/reload/stale replies, policy, real renderer destruction all pass without backend. Commit: `feat: bridge Android WebView with document isolation`.

## Task 7: App state, readiness and lifecycle without retaining UI

**Requirements:** WEB-01/02, LIFE-01, STORE-01; Review Focus 2/5.

**Files:** Create app `{AppState,AppViewModel,NativeErrorPresentation,AppRoot}.kt`; modify MainActivity; unit `{ReadinessTest,AppFlowTest,NativeErrorPresentationTest}.kt`; component `CleanupRaceTest.kt`; platform `ActivityRecreationTest.kt`.

**Read:** IS App/{AppCoordinator.swift,AppCoordinator+Authorization.swift,AppCoordinator+WebPreparation.swift,AppState.swift}, Presentation/FirstFrameProbe.swift; IT CoordinatorTests, WebReadinessTests, NativePresentationTests. Exclude obsolete debug/environment-panel states, preserve relevant failure actions.

**Interfaces:** `AppViewModel(store:BindingStore,manager:SessionManager,clock:SessionClock)` owns `val state:StateFlow<AppState>` and exposes the same `manager` as internal read-only `sessions:SessionManager` for UI-owned WebSession construction. Methods: `start():Unit`, `onFirstFrame():Unit`, `onForeground(active:Boolean):Unit`, `acceptQr(raw:String):Unit`, `onScannerClosed():Unit`, `onWebEvent(event:WebEvent):Unit`, `reportReady(identity:DocumentIdentity,screen:WebReadyScreen):Unit`, `retry():Unit`, `unlinkCar():Unit`. AppState contains current native screen, immutable WebLoadRequest?, loading illustration ID and contextual error; no WebView/Context/Activity and no persisted JWT.

- [ ] Write readiness tests: no reveal before committed current document+valid JWT+reportReady+foreground; 60_000 active milliseconds after JWT availability; pause/resume in background; redirect/refresh do not reset budget; late callbacks after failure do not revive. Test native first-frame gate before initial WebView creation. Run tests red.
- [ ] Write cleanup/flow tests: cold restore has no welcome flash; read errors show retry/reset, failed pair cleans pending before start-over, save failure no entry; error remains contextual despite passive refresh; unlink confirmed by web is not confirmed again. A previous binding's late reply cannot change welcome/error. Run red.
- [ ] Implement ViewModel and context-specific error presentation by porting current iOS behavior. One manager in ViewModel lifetime, real resources created in AppRoot/AndroidView.factory, applyLoad deduplicates request ID in update, onRelease closes. Foreground starts manager catch-up; background stops new schedules without requiring a persistent service.
- [x] Route native reset/unlink and bridge unlink through one UI-owned action that synchronously closes and clears the current WebSession before calling ViewModel.unlinkCar. `AppRoot` now passes the same remembered callback to `BridgeCallbacks.onUnlinkCar` and native RESET/REBIND. Cleanup remains in the ViewModel: wait for manager stop, reset and confirm empty storage, then show Welcome. `:app:compileLocalDebugKotlin` passed; no WebView product source changed.
- [ ] Implement renderer recovery exactly: error before first reveal; after reveal one auto attempt; second death before successful reportReady→error; successful process recovery resets eligibility. Keep manager/key/static web data. On retry do not silently create a new binding.
- [ ] Run unit/component classes. Run ActivityRecreationTest during paused auth and after ready; assert one pair, retained business operation and safe new-document readiness, not preservation of old DOM. Commit: `feat: coordinate Android readiness and recovery`.

## Task 8: DEFERRED — shared web Android theme and minimal Back adapter

**User constraint (2026-10-29):** Do not modify the shared web repository. The planned Stackflow Android theme and host Back event require changes there, so this task is deferred. Do not substitute WebView history, synthetic DOM input, or JS injection. Tasks 9–11 may continue; final delivery must state that Android host Back parity is incomplete until this task is authorized and implemented.

**Requirements:** BACK-01; Review Focus 4. Can be developed after Task 1; complete before full UI/end-to-end acceptance.

**Files (W):** Modify `src/shared/host/{types.ts,types.test.ts}`, `src/app/host/{HostLifecycleProvider.tsx,HostLifecycleProvider.test.tsx}`, `src/app/navigation/{createNavigation.tsx,createNavigation.test.tsx,NavigationRoot.tsx}`, existing modal components/tests. Create `src/app/navigation/{navigationTheme.ts,navigationTheme.test.ts,BackNavigationProvider.tsx,BackNavigationProvider.test.tsx,AndroidHostBack.integration.spec.ts}`. No package additions or lockfile changes expected.

**Interfaces:** `resolveNavigationTheme(search:string):'android'|'cupertino'` selects android only for one valid platform=android query; iOS/absent/invalid→existing cupertino fallback. `createNavigation(renderers,theme='cupertino')` passes the option to existing basicUIPlugin. Add `onBack?:()=>void` to existing HostLifecycleHandlers and explicit host-event back branch. `useBackLayer(handler:()=>void,present:boolean):void` registers just the current callback/order; `BackNavigationProvider` dispatches top layer, otherwise the existing NavigationRoot navigation.back wrapper (retaining Sentry diagnostics).

- [ ] Write host tests: valid/invalid back shape, duplicate/old sequence ignored, new back invokes onBack once and never onRefresh; current lifecycle/refresh/getHostState behavior unchanged. Write theme default/ios/android/duplicate tests. Run existing `npm run test:unit -- <changed test paths> --passWithNoTests=false` in the repo's configured tooling context; expect new cases red.
- [ ] Implement tiny layer registration tied to actual presence, cleanup on unmount, latest callback ref; no IDs/priorities/modal framework. UnlinkCarDialog consumes Back while submitting, otherwise invokes existing guarded cancellation. SentryHelpSheet uses requestClose and stays registered while present during exit animation; Back must not fall through even if closeRequested is already true. If no layer, invoke current navigation.back guard.
- [ ] Wire one root onBack subscription, not one per mounted Stackflow page; existing pages remain mounted. iOS emits no new event and keeps existing swipe. Do not synthesize keyboard Escape or introduce history-sync.
- [ ] Add Playwright tests using the existing `pages/home/test/integrationTest`/GraphQL fixtures: one event closes one modal; repeated Back during 200ms sheet exit leaves page; submitting modal blocks pop; root no-op; a settled back returns to previous activity; iOS theme/navigation unchanged. Disable reduced motion only in the test explicitly exercising exit timing; wait for state, no arbitrary sleep.
- [ ] Run typecheck, changed unit tests with nonzero results, changed Playwright integration test. Final full relevant web regression is Task 11; do not run production deploy commands. Commit: `feat: support Android host back and Stackflow theme`.

## Task 9: Native screens, official camera and about sheet

**Requirements:** QR-01, user UI parity, BACK-01 keyboard/native surfaces.

**Files:** Create camera/QrScanner.kt, ui/{WelcomeScreen,LoadingScreen,NativeErrorScreen,AboutSheet,ZdeepTheme}.kt; modify AppRoot/MainActivity; copy resources/fonts/licenses; platform `{NativeScreensTest,CameraPermissionTest,QrScannerTest,AboutSheetTest}.kt`, unit `ScannerResultGateTest.kt`.

**Read:** IS Welcome/*, Camera/{CameraPermission,QRScannerView}.swift, Presentation/{WebLoadingView,NativeStatusViews}.swift; IT CarQRParserTests/CameraPermissionTests/WelcomeResourceTests/WelcomeFontTests/NativePresentationTests; iOS UI tests as scenario references, not a debug-panel implementation dependency.

**Interfaces:** `QrScanner(onResult:(String)->Unit,onClose:()->Unit)` delivers one accepted raw string. `AboutSheet(url:String,onClose:()->Unit)` has a separate WebView with no business bridge. `AppRoot(viewModel:AppViewModel)` owns native UI/WebSession, wires one Compose BackHandler and lifecycle forwarding.

- [ ] Write UI tests for welcome actions/text, permission denied/settings return, loading illustration stability, error actions/confirmation, About error/close, large font content access. Write scanner gate test for result→late result, close→late result; no pair after cancel. Run relevant classes red.
- [ ] Copy WelcomeHero (use highest useful source resolution), StartupLogo and all LoadingScene01…08 JPGs into Android resources with valid lowercase names. Copy Inter weights and JetBrains Mono with existing licenses; convert the three simple Welcome SVG icons to VectorDrawable without redrawing. Reuse AppIcon source for Android launcher/adaptive icon assets. Russian strings follow source verbatim where product behavior is unchanged.
- [ ] Implement native screens using Material components, stock progress indicator, scrollable large-font layouts and accessible labels. Illustrated loader has no visible extra loading caption; ordinary loader retains its text. Reveal web by fading upper layer after readiness, respecting animator/reduced-motion setting. No unlink or cancel action on loading.
- [ ] Implement camera with LifecycleCameraController, PreviewView, MlKitAnalyzer and bundled BarcodeScanner configured QR-only. Bind/unbind lifecycle and close scanner; preserve the existing frame guidance and close action. Permission uses RequestPermission and current lifecycle checks, not a copied iOS permission enum. No gallery-import product feature or Play Services model download.
- [ ] Implement separate about sheet for `/about.html` of environment: ordinary links remain inside, new windows→browser, existing Russian error text. No native auth bridge injected there. Native Back dismisses scanner/about; with keyboard open it dismisses keyboard before web Back; loading/cleanup Back does not cancel or unlink.
- [ ] Run platform classes; verify a real local QR image via Virtual Scene camera. Use emulator Extended Controls to set image if supported automation is unavailable; record exact AVD and test outcome. Generate local QR in a temporary file (use installed QR tooling; if none, test-only ZXing core 3.5.3 encoder suffices), remove it afterward. Do not make image generation a runtime dependency. Commit: `feat: complete Android native flow and scanner`.

## Task 10: End-to-end local acceptance and real process restart

**Requirements:** LIFE-01, ENV-01, AUTH-01, BRIDGE-01, BACK-01, QR-01; Review Focus 1/2/4.

**Files:** Create localbackend `{AppLocalFlowTest,ProcessRestartTest,CameraLocalFlowTest}.kt`, platform `SystemBackTest.kt`, support fixtures, `scripts/check-process-restart.sh`; update preflight/README. Keep test-only host Activity/fixtures in androidTest; no product auth-bypass extras or mailbox.

**Interfaces:** `ProcessRestartTest.prepareBinding` and `ProcessRestartTest.restoreBinding` are separately selectable JUnit4 methods, separated by host adb force-stop/relaunch. Driver consumes explicit serial and built Debug/test APK paths, leaves app data intact between phases and checks instrumentation summaries. Record safe carId/expected binding identity only, never JWT. Initial test setup may use production methods with a real fresh local token; full camera path is separate.

- [ ] Write local flow assertions: fresh pair→durable binding→actual web reportReady→authenticated business content; cold start→token without QR; web unlink→native cleanup→welcome. Read existing web page semantic roles/GraphQL fixture IDs to choose a stable business-content assertion, not just an HTML title. Tests use real native bridge/auth, not devBridge or mocked JWT.
- [ ] Implement strict preflight in host and emulator. Missing backend, wrong origin, redirect or no business data fails visibly; no Assume/Ignore/test-server substitution. AuthWireTest remains a separate wire proof so UI failure can be distinguished from signature incompatibility.
- [ ] Implement phase driver with `set -eu`, adb argument arrays/quoting and finite waits. Finish prepare instrumentation, save its nonsecret assertions, then `adb -s "$ANDROID_SERIAL" shell am force-stop ru.zdeep.mobile`, relaunch launcher Activity, and invoke restore method in a new instrumentation session. Assert binding identity still matches and token obtains a valid session. Do not kill the test runner mid-test and use its partial XML as success. Add same-scope `adb install -r` retention and explicit uninstall→fresh QR checks on dedicated AVD; never uninstall the user's unrelated install.
- [ ] Test scope install-over change using local/testing builds only with network disabled for the testing phase: inspect clean-state behavior before any remote request. Do not send automated testing traffic. Resume local and create a fresh local binding. Verify both build URLs and `/testing/` through BuildConfig/package checks.
- [ ] Implement Android-owned `SystemBackTest` only for keyboard dismissal, scanner/About dismissal, Home/return lifecycle and delivery of any already-supported host callbacks. Shared Stackflow back/theme behavior is deferred by the user constraint; do not invent WebView-history, DOM, or JS-injection substitutes. The common-web modal/submitting/closing-sheet guards, settled stack pop and root no-op cannot be verified until Task 8 is separately authorized. Use UI Automator/system back and record a separate edge-gesture run only if supported by the existing native/WebView contract.
- [ ] Run localbackend package, separate process driver and SystemBackTest on Android 16 / API 36; run platform package and camera check on the same AVD. Actual camera QR run must be recorded separately if manual Virtual Scene setup was necessary. Commit: `test: verify Android local lifecycle and web integration`.

## Task 11: Complete acceptance, Debug delivery and deferred release configuration

**Requirements:** all 15 requirement IDs; spec §11/§13.6.

**Files:** Finish README; Android `docs/verification/2026-10-28-android-port.md` (actual date if later); final Gradle/manifest/config fixes only as required. No production artifact or signing key.

**Interfaces:** Deliver `app/build/outputs/apk/testing/debug/app-testing-debug.apk` (optionally copy to a clearly versioned delivery filename), source and exact rebuild/install instructions. Verification ledger maps every requirement ID to actual test selectors/results and remaining limitations.

- [ ] Review each source boundary against the original source revisions and any subsequent relevant changes. Ensure all acceptance cards have real tests/results; do not fill missing coverage with an assertion on a fake. Check Russian copy/fonts/resources, backup exclusions, key cleanup, release debug-off defaults, no debug mailbox/panel and no private material in tracked files.
- [ ] Run once after fixes: JVM Unit+Component with `./gradlew :app:testLocalDebugUnitTest --rerun-tasks`, full platform and localbackend runs on Android 16 / API 36, process driver and camera check. Run Debug lint (`:app:lintLocalDebug :app:lintTestingDebug`) and assemble both Debug variants. Select Android suites explicitly and keep separate reports or copy them before later connected runs overwrite the default destination. Record first failures and new confirming results; avoid repeated all-suite runs after green without new changes.
- [ ] Do not edit or test the sibling web repository under the current user constraint. Record Task 8 and common-web Back integration as deferred; do not claim Stackflow Android theme, modal Back, stack pop, or root no-op parity.
- [ ] Install actual testingDebug APK and confirm native launch/environment configuration without automated testing-backend requests; user will do actual testing login later. Compute SHA-256 and record versionName/versionCode, applicationId and artifact path. Debug→Release later may require uninstall/new QR because signing keys differ.
- [ ] Review production configuration source only: correct URLs, release non-debuggable/WebView debugging off, no fixture host/test dependencies, intended shrinking rules and optional external signing inputs. Debug tasks must configure without release credentials. Document unverified release assembly/shrinking/artifact/signature. **No assembleProductionRelease, bundleProductionRelease or unsigned release build.**
- [ ] Obtain final Sol High review across Android code (required by AGENTS for >3-task plans); no web repository changes are in scope. Implement genuine fixes with the specified routing; run only affected checks plus a new complete pass if behavior changed materially. Check iOS branch of common web contracts/theme with existing tests; do not claim a fresh iOS native test run unless one was actually run.
- [ ] Write concise Russian README and final evidence ledger: environment/toolchain, exact commands/selected serials, requirement→test mapping, report paths, Debug APK hash, user testing steps, future release/signing steps and emulator-only limits. Remove only temporary QR files and task-owned bulky build intermediates no longer needed; preserve delivery APK and necessary reports. Commit local reviewed changes; no remote integration.

## Coverage and self-review checklist

| Requirement | Owning tasks |
| --- | --- |
| AUTH-01 | 3, 4, 10 |
| AUTH-02 | 4 |
| AUTH-03 | 2, 4 |
| SESSION-01 | 5 |
| SESSION-02 | 5, 7 |
| SESSION-03 | 2, 5, 7 |
| STORE-01 | 3, 7 |
| BRIDGE-01 | 6, 10 |
| WEB-01 | 7, 10 |
| WEB-02 | 6, 7 |
| NAV-01 | 6 |
| LIFE-01 | 5, 7, 10 |
| BACK-01 | 8, 9, 10 |
| QR-01 | 2, 9, 10 |
| ENV-01 | 1, 2, 3, 10, 11 |

- [ ] Infrastructure gate produces actual Debug APK/unit/instrumented results before feature tasks.
- [ ] All tasks have explicit input/output interfaces, red→green checks and local commit boundaries.
- [ ] Task 6 callback-order spike proves early bridge behavior; never count callback assumptions as a verified Android feature.
- [ ] Shared coroutine operation ownership, deadline units, UUID identity and bridge DTOs stay consistent between tasks.
- [ ] Spec §§4–9 UI/auth/bridge/build details all have owning tasks; spec §§12–13 handoff/testing requirements appear in Tasks 1, 4, 10, 11.
- [ ] Review Focus has an owning regression test for each of five failure classes.
- [ ] No user QR/key required; no production build or automated testing/production traffic added.

## Documentation used for the baseline

Context7 was consulted first; official references were used to resolve incomplete output. These establish documented compatibility, not a successful local build:

- [AGP 8.11 compatibility and 8.11.1](https://developer.android.com/build/releases/agp-8-11-0-release-notes), [Kotlin Gradle/AGP compatibility](https://kotlinlang.org/docs/gradle-configure-project.html), [Gradle Java compatibility](https://docs.gradle.org/current/userguide/compatibility.html).
- [Compose BOM mapping](https://developer.android.com/develop/ui/compose/bom/bom-mapping), [Activity releases](https://developer.android.com/jetpack/androidx/releases/activity), [Lifecycle releases](https://developer.android.com/jetpack/androidx/releases/lifecycle), [WebKit releases](https://developer.android.com/jetpack/androidx/releases/webkit).
- [CameraX releases and Android 17 fix](https://developer.android.com/jetpack/androidx/releases/camera), [ML Kit bundled barcode scanner](https://developers.google.com/ml-kit/vision/barcode-scanning/android), [CameraX ML Kit Analyzer](https://developer.android.com/media/camera/camerax/mlkitanalyzer).
- [AndroidX Test releases](https://developer.android.com/jetpack/androidx/releases/test), [coroutine test scheduling](https://developer.android.com/kotlin/coroutines/test), [instrumented tests](https://developer.android.com/training/testing/instrumented-tests).
- [RuStore publication fields](https://www.rustore.ru/help/developers/publishing-and-verifying-apps/app-publication). Publication is not part of this task.

## Execution handoff

The project rules already specify delegated native implementation (Luna High), Terra medium review and Sol High whole-change review; preserve that method rather than asking the user to choose it again. Read this plan and the approved spec together, review before implementation, then use subagent-driven-development. The user receives one completed app delivery; task boundaries are internal implementation/review gates.

**Latest post-fix ordered-driver retry (2026-11-01):** A third full `scripts/check-process-restart.sh` attempt used the dedicated API 36 AVD with a runtime-only `-memory 6144` override (`run-20261101T164913Z-4447`). Local API preflight and all three `LocalNetworkProbeTest` cases passed. `ProcessRestartTest#prepareBinding` again failed at initial business-page readiness: WebView progress reached 100 and the UI heartbeat responded, but `evaluateJavascript` returned without its callback before the 35-second observation deadline (`state=LOADING`, `view-post-not-run-by-deadline`). No ANR or renderer crash was recorded in this run. The runtime RAM override did not resolve the symptom; no product cause is established. The ordered run stopped before later process/install/camera phases. Testing Debug was restored and hash-verified; cold launch took about 63 seconds, then accessibility confirmed Welcome and both actions. WebView product sources and the shared web repository remain untouched.


**Fourth post-host-fix Task 10 driver (2026-11-01):** `run-20261101T170458Z-81832` on the dedicated Android 16/API 36 emulator passed the local endpoint preflight, `LocalNetworkProbeTest` 3/3, `prepareBinding` 1/1, and `sameScopeInstallOverRetainsBinding` 1/1. After host force-stop/cold relaunch, `restoreBinding` ran 149.918 seconds and failed waiting for `reportReady(content)`: native state stayed `LOADING`; WebView progress was 100 and the main-thread heartbeat responded, while the `evaluateJavascript` DOM-observation callback was not received. The driver stopped before scope-change, renderer, reinstall and camera phases. No product root cause is established. The wrapper completed cleanup; readback confirmed Testing Debug version 0.1.0, minSdk 30, targetSdk 36, MainActivity foreground with the Welcome QR action visible, and installed APK SHA-256 matching the artifact (`0d9cc787fc32fac2626044474023f94d0f577e5c599defccb3456bd6769eab62`). No Android WebView product or shared-web source was edited.


**Task 10 full ordered acceptance with host GPU (2026-11-01):** `run-20261101T172612Z-9698` passed on `Zdeep_API36` / API 36 / arm64-v8a using runtime-only `-gpu host -memory 6144` (AVD config was left unchanged). Passed local endpoint/network probe (3/3), `prepareBinding`, same-scope install-over, process restore after force-stop, scope-change preparation, pre-reveal/repeated renderer failures and recovery, offline local→Testing cleanup, uninstall/reinstall Welcome, fresh Virtual Scene QR hash decode, and camera pairing through authenticated business content. The driver exited 0; temporary QR/marker/network/pose state was cleaned. Testing Debug was manually reinstalled after camera flow and launched: installed SHA-256 `8deec23d7b703b0a3a7bdc12a37c0a8a5ed014a22f8dc0b0db4713d0fe790abb` matches artifact; version 0.1.0, minSdk 30, targetSdk 36, Welcome QR action visible. Reports: `app/build/task10-reports/process-restart/run-20261101T172612Z-9698/` and `/private/tmp/android-task10-final-20261101/`. No Android WebView product or shared-web source was edited.
