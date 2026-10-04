# SDD ledger — plan: docs/superpowers/plans/2026-10-04-mobile-session-implementation.md

## Setup

- Worktree: `/private/tmp/zdeep-ios-mobile-session`, branch `codex/mobile-session-implementation`.
- Starting commit: `9efec72` (after Sol reviewed/fixed plan; main untouched).
- iOS target: Simulator UDID `0DDEE416-EECF-4BF3-8F15-BA93A980033A` (iPhone 18 Pro, iOS 27.0).
- User acceptance: all tests on Simulator against `local`; no physical iPhone; no network test/prod.
- Local preflight: `/health` returned HTTP 200 after retrying sandbox block with permission.
- Baseline unit: 39 Swift Testing checks across 9 suites passed. Result bundle `/private/tmp/zdeep-ios-mobile-session/.artifacts/runs/20261004-122841-1791106121749892000/Tests.xcresult`.
- Baseline UI: do not run full suite because existing `testTestEnvironmentWelcomeScreenDoesNotLoadWebUntilOpened` explicitly selects remote `test`. Run local-only UI methods after filtering; Task 8 fixes the offending test before its first UI run.

## Preflight scan — task pair interfaces and shared surfaces

| Tasks | Shared file/interface | Finding / ruling |
|---|---|---|
| 1→2 | BindingStore signing; AuthClient calls store | Task 2 consumes `sign(bindingId:bytes:)`; keep private key inside store. No conflict. |
| 1→3 | BindingStore protocols/models | Task 3 consumes restore/begin/complete/reset and public descriptions. No conflict. |
| 1→10 | Store reset and registration | Task 10 sequences store operations; cancellation invalidates manager before reset. No conflict. |
| 1→12 | Keychain and install marker | Full cleaner owns all app services; ordinary store reset preserves installation marker. Keep ownership boundary. |
| 1→13 | Real local auth fixture | Integration creates temporary binding and cleans app-owned test record; it must not mutate user's default Keychain service. |
| 2→3 | AuthClientProtocol/AuthSession/AuthFailure | Exact public contracts in plan. No conflict. |
| 2→4 | SessionClock / timeout | Same monotonic origin; manager scheduling shares AuthClient clock. No conflict. |
| 2→13 | AuthClient local pairing | Integration uses freshly fetched tmp car token, local endpoints only. No hard-coded JWT. |
| 3→4 | SessionManager state/tasks | Task 4 adds schedules against Task 3 manager; no parallel manager owner. |
| 3→7 | Manager + NativeBridge | Bridge consumes session/update/subscribe without starting pair. No conflicting ownership. |
| 3→9 | Manager + coordinator callbacks | Coordinator owns UI; manager owns one auth Task. Coordinator stops manager only for session reset/config transition. |
| 3→10 | Manager registration/reset | Late registration after cancel is cleaned before welcome. No conflict. |
| 3→11 | Manager current session/readiness | Coordinator calls shared update; bridge and coordinator join one manager task. No duplicate requests. |
| 3→12 | Manager stop/full reset | Stop/invalidate before deleting owned data. No conflict. |
| 4→9 | Scene activity | Coordinator forwards activity to manager; inactive manager starts no new auth. |
| 4→11 | Refresh and WebView error | Native error does not stop working mode or retry series. No conflict. |
| 5→10 | Parser/scanner | Scanner emits one string; parser extracts token; manager starts one pair. No conflict. |
| 6→7 | WebSession document context / bridge seam | Task 6 defines WebDocumentBridgeHandling fakeable seam; Task 7 implements it. No compile-order gap. |
| 6→9 | Factory/WebSession | Container can be created hidden before auth and loaded after first native frame. No conflict. |
| 6→11 | Navigation/readiness | One document identity per allowed full navigation; readiness keyed to it. |
| 6→12 | Default WKWebsiteDataStore | Cleaner closes/releases WebSession before removing persistent website data. |
| 6→13 | Real WebKit container | Integration uses configured local URL and verifies actual bridge/reveal. |
| 7→9 | Bridge callback + coordinator | Callback delegates reportReady to coordinator; public bridge surface stays exact. |
| 7→11 | Ready/event semantics | Task 11 enforces coordinator acceptance/deadline; bridge only transports exact DTOs/events. |
| 7→13 | Real web contract | Tests run against local web in real WKWebView; no test/prod URL. |
| 8→9 | Native screens/fixture/App root | Presentation test host uses safe fixtures; production coordinator only after explicit production branch. |
| 8→10 | Error/loading + camera UI | Coordinator supplies actions; view does not own auth or reset. |
| 8→11 | Native loading/reveal | Existing view stays opaque until coordinator accepts current ready + session + active state. |
| 9→10 | AppCoordinator shared state/actions | Keep a single scenario ID/state owner across extensions. |
| 9→11 | Web-preparation/readiness | Task 9 wires basic actual ready acceptance; Task 11 owns active budget/retry/process-recovery detail. |
| 9→12 | Environment/reset APIs and diagnostics | Task 9 removes debug auth bypass; tests are adapted in Task 9 before affected suites run. |
| 9→13 | Full startup composition | Local app startup only; first native frame before WebView construction. |
| 10→11 | Cancel/retry + document identity | Cancel invalidates both UI scenario and bridge/document before asynchronous cleanup. |
| 10→12 | Reset progression | Ordinary reset preserves cache/marker; full reset owns all app layers. |
| 10→13 | Camera/auth test fixture | Simulator injects scan result, local endpoint supplies fresh signed car token. |
| 11→12 | Native errors/session stops | Passive auth failure cannot overwrite a native web error; full reset stops manager first. |
| 11→13 | Readiness integration | Unit uses fake clock; real WebKit integration only waits for observable local readiness. |
| 12→13 | Cleaner/persistent store | Cleaner fake in unit; real shared WebKit-store verification serialized in WebSessionIntegrationTests. |
| 2,6,7,9,11,12→suite | `WebSessionIntegrationTests`, persistent default store | `@Suite(.serialized)` before first real integration run; UI runs only local. No concurrent reset/cache race. |
| 5,8,9,10→all UI | `ZDEEPUITests` and package/build files | Replace remote test UI flow by Task 8; passive host CLI flag targets only hosted `ZDEEPTests`; old bypass tests adapted in Task 9. |

## Per-task self consistency scan

| Task | Test/code/file consistency |
|---|---|
| 1 | Fake Keychain/marker adapters cover all five store operations; P-256 signature tested against public DER; no HTTP. |
| 2 | Fake clock/transport tests own request/timeout/parser logic; one real local pair/token test validates protocol; secrets omitted. |
| 3 | Manager operation/publishing tests use store/client fakes and cover late save/cancel/reentrancy; matches one MainActor owner. |
| 4 | Virtual clock makes retry/expiry checks deterministic; coordinator forwards activation; no background task scheduler. |
| 5 | Parser and permission are pure/injected; package scanner has one `.qr` completion; simulator injects fixture. |
| 6 | Container policy is unit tested independently; real WebKit identity/release checks are integration-only. |
| 7 | Bridge DTO/identity/replies are unit tested; document-start/WK reply are exercised in local WebKit suite. |
| 8 | Stitch source precedes SwiftUI transfer; presentation fixture supplies display states; camera/product flow belongs to Task 10. |
| 9 | Passive hosted app prevents real startup in unit/integration; UI launch test is local-only; web bypass dependents adapted before suite pass. |
| 10 | Cancel and error cleanup order tested with controlled continuations; UI fixture injects result but not production secrets. |
| 11 | Readiness/retry tested with fake clock and identities; process reload has one attempt; local WebKit verifies public APIs only. |
| 12 | Fake cleaner test covers partial failures; default WebKit storage touched only in serialized integration suite; switch side effects are faked. |
| 13 | Full E2E uses fresh local token, live local API/web, Simulator, then checks release build without network. |

## Plan defects discovered before Task 1

- The `task-brief` helper searches literal headings `Task N`; the accepted plan used Russian heading `Задача N`. Ruling: retain Russian body text and switch only task heading prefix to `Task N:` so the documented SDD extraction/report workflow works. This changes organization, not requirements.
- Baseline UI suite must be filtered until Task 8 replaces explicit `--environment test`; no remote test/prod is allowed.
- Initial baseline compile/tests run, continuing local integration baseline before Task 1.

## Task status

- Task 1 implementation: `792d286 feat: add durable binding store`; Luna review-fix commits `5bfb2bc` and `53bf961` (base `9df6c6a`). Initial Sol findings and second scoped runner findings are fixed; both re-reviews approved.
- Task 1 verification: official local Simulator unit suite 54/54, including real Security API read/write/update/durable restore/delete with unique UUID service and defer cleanup; Python build runner tests 17/17; `git diff --check` clean. Ad-hoc target earlier was 59/59 = 49 unit + 10 local WebSession integration; not reported as unit-only. Runner signing is limited to `unit/local` and `all/local` Simulator build-for-testing; `test` and regular builds remain unsigned; project signing settings are unchanged.
- Task 2 is active with Luna. Brief generated; base commit `53bf961`. Scope is AuthClient/validator/clock, local pair+token integration and serialized WebSession integration test suite. No test/prod endpoints or token logging.
- Task 2 implementation committed as `2bb7bca`; Sol found two P1 issues (numeric conversion traps; canceled queued request could still send). Luna fixed in `3ec0244`; Sol then found a nondeterministic test ordering, fixed with timer cleanup in `b2224f1`. Both re-reviews approved. Final verification: unit 66/66, integration/local 7/7, Python runner 17/17, diff check clean. Runner signing covers `unit/integration/all` only for local Simulator test builds; other environments and regular builds stay unsigned.
- Task 3 is active with Luna. Brief generated; base commit `b2224f1`; scope: shared SessionManager operation, waiters, publishing and stop; unit only.
- Task 3 implementation committed as `91198eb`; Sol found 5 completion/context issues plus missing plan checks, fixed in `bdce3be`. Scoped Sol re-review found 2 event reentrancy issues, fixed in `25b42cb`; both fixes re-reviewed APPROVED. Final unit/local 86/86 (13 suites), focused cancellation/reentrancy tests pass. Integration is not in scope.
- Task 4 implementation committed as `93f80f4`; unit/local 100/100 in 14 suites; RED confirmed missing policy; no integration required.
- Task 4 Sol findings fixed by Luna in `d9f13f3 fix: preserve session retry scheduling`: cancellation is checked before scheduling side effects; foreground starts one immediate refresh at ≤120s remaining or after expiry, while preserving the scheduled retry when >120s remains. Four fake-clock regression tests showed expected RED then GREEN; full local Simulator unit 104/104 in 14 suites; `git diff --check` clean. Sol re-review approved with no findings. Initial default-sandbox Simulator discovery failed because CoreSimulatorService paths were inaccessible; elevated read-only `simctl list devices available` confirmed the specified booted iPhone 18 Pro. No product change was made in response to this infrastructure issue.
- Task 4: complete (commits `93f80f4..d9f13f3`, review clean).
- Task 5 started with Luna. Brief: `.superpowers/sdd/2026-10-04-mobile-session-implementation/task-5-brief.md`; base commit `d9f13f3`; scope: QR parser, camera permission, and scanner adapter.
- Task 5 committed as `2041c05 feat: add QR scanner and camera permission adapter`; RED compilation failure and focused GREEN checks recorded; full local Simulator unit 110/110, plist/project metadata checks and diff check passed. Sol approved, no findings. Sol could not verify the Simulator debug fixture/Release launch-argument restriction in this diff; the accepted Task 10 brief explicitly owns that fixture and Release guard, so verify them there before Task 10 completion.
- Task 5: complete (commits `d9f13f3..2041c05`, review clean; Task 10 fixture/Release verification carried forward).
- Baseline integration: build succeeded; 5/6 existing WebSessionIntegrationTests passed, `test_real_web_url_and_native_object` failed `.pageChanged`. Local API /health and escalated GET localhost:4005 both return HTTP 200, so this failure is not explained by endpoint availability. A focused retry with `--skip-build` was rejected because the source fingerprint had changed while Task 1 work began; do not attribute it to a code regression yet. Revisit the test after Task 1 without concurrent Simulator runs. No test/prod was contacted.
- Task 6 Sol review round 1: Luna fixed final main-frame response origin validation (using `navigationResponse.response.url`) and prevented canceled user links such as `mailto:` from publishing document failure. Behavioral RED/GREEN, the initial local-file fixture regression/fix, exact test output, and completed local Simulator runs are appended to `task-6-report.md`. Final unit 122/122 and integration/local 12/12; inherited `test_real_web_url_and_native_object` passes again. Task 6 remains pending Sol re-review.
- Deferred Sol Minor for Task 7: current `test_file_fixture_has_no_real_session` checks only the JS object and document identity. Add a meaningful assertion that no real session is exposed when Task 7 introduces the actual bridge; do not treat the current test as proving this security property.

## Todo
- [x] Task 1 — BindingStore (Sol approved implementation and runner fix)
- [x] Task 2 — AuthClient (Sol approved implementation and follow-up fixes)
- [x] Task 3 — SessionManager shared operation (Sol approved implementation and follow-up fixes)
- [x] Task 4 — refresh/retry/activity (Sol approved fix round)
- [x] Task 5 — QR scanner/parser (Sol approved; Task 10 fixture verification carried forward)
- [ ] Task 6 — WebSession document lifecycle
- [ ] Task 7 — NativeBridge
- [ ] Task 8 — native screens/assets
- [ ] Task 9 — staged startup/hosted test isolation
- [ ] Task 10 — QR registration/cancel/reset
- [ ] Task 11 — readiness/recovery
- [ ] Task 12 — full reset/environment/diagnostics
- [ ] Task 13 — Simulator local E2E/release build/final review
- Baseline Python CLI suite: `python3 -m unittest discover -s scripts/tests` — 29 tests passed, before source implementation.
