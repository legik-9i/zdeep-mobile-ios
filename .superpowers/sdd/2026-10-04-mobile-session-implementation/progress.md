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
- Task 6 initial implementation `379ed09` was Sol-reviewed. Luna fix round `babe0b4` addressed final main-frame response origin validation and canceled `.linkActivated` links; re-review found `.formSubmitted` still incorrectly failed. Repeat finding routed to Sol per AGENTS.md; Sol narrowed fix in `af5d263`, but scoped review found it treated scripted `requestSubmit()` as a user action. Apple iOS `WKNavigationAction` has no user-gesture bit, so ledger ruling records `.linkActivated` as the only user-action exemption. Luna fixed the new Important in `21abae2`, with test-first RED/GREEN and full verification; Sol one-time re-review approved the Luna production diff. Final Task 6 unit 122/122, integration/local 13/13, `git diff --check` clean; inherited `.pageChanged` test passes. RED/GREEN/test evidence is in `task-6-report.md`.
- Task 6 fix round 1: 1 finding addressed, 1 remained (`.formSubmitted` classification); Luna commit `379ed09..babe0b4`, then Sol narrow correction `af5d263` and Luna follow-up `21abae2`; final Sol re-review clean.
- Task 6: complete (commits `2041c05..21abae2`, review clean).
- Task 7 started with Luna. Deferred Task 6 Minor carries forward: strengthen `test_file_fixture_has_no_real_session` to assert no real session is exposed after the actual bridge is added. Brief `.superpowers/sdd/2026-10-04-mobile-session-implementation/task-7-brief.md`; base commit `21abae2`; scope: native message handler, bridge DTO/bootstrap, lifecycle and local WebKit integration.
- Deferred Sol Minor for Task 7: current `test_file_fixture_has_no_real_session` checks only the JS object and document identity. Add a meaningful assertion that no real session is exposed when Task 7 introduces the actual bridge; do not treat the current test as proving this security property.
- Task 7 implementation `e9b49d9`; Sol review initially found 4 production defects and a broad behavior-coverage gap. Luna fixed waiter lifecycle, expiry/recovery, and terminal identity-mismatch classification in `044a79f`, then added precommit ordering coverage in `48c642a`. Sol re-review found an in-flight expiry variant and remaining brief coverage gaps. This was a repeated finding: Luna's first expiry guard only rejected an expired published session when no refresh was active; during a failed refresh the manager emitted only `authorizationActivityChanged(false)`, leaving `getSession()` pending. The coverage finding also remained partly open because only a subset of the listed bridge boundaries had explicit tests.
- Per the stuck protocol, Sol made the narrow fix and added regressions in `1c55b80`: reject an expired published session irrespective of refresh activity (also in the post-subscription race check); cover cached-session reads during failed refresh, actual recovery attempts, invalid `reportReady`, prior initial-entry failure, fail/close commit gating, old-document/container, and `AbortError`. Sol did not run checks. Scoped final review approved the fix with no Critical/Important findings. The late-commit test exercises the `WebDocumentContext.commit` gate that `WebSession.didCommit` checks before releasing bridge calls.
- Luna verified the consolidated Task 7 changes on Simulator `0DDEE416-EECF-4BF3-8F15-BA93A980033A`, environment `local`: focused expiry/in-flight, precommit ordering, and prior-entry-failure integration tests passed; full unit **127/127**; full integration **25/25** with local `/health` HTTP 200; `git diff --check` passed. No real token or auth request body was printed or persisted. Detailed run results are recorded in `task-7-report.md`.
- Task 7: complete (commits `21abae2..1c55b80`, Sol approved).
- Task 8 prepared after Task 7 approval. Brief: `.superpowers/sdd/2026-10-04-mobile-session-implementation/task-8-brief.md`. Retrieved the planned Stitch screen `411b28d9024448b7a36d813cbf00b56c`; preserved HTML and source metadata under `docs/design/assets/native-error/`. Screen HTML background `#F5F5F7` matches accepted `WelcomeStyle.background`; global project theme is dark `#131313`, so the screen-specific HTML remains the source for Task 8.
- User approved both Task 8 assets. The source AppIcon PNG has an alpha channel but every alpha sample is 255; an exact deterministic RGB composite was created at `docs/design/assets/branding/ZDEEP_Mobile_1024_icon.png` and verified pixel-equal to source RGB at 1024×1024. Two altered ImageGen variants were discarded. Official JetBrains Mono `v2.304` Regular/Medium TTF and OFL 1.1 license are staged in `ZDEEP/ZDEEP/Fonts/`, with Cyrillic/code glyph checks passed. No source branding file was changed.
- Task 8 pure presentation-state slice committed as `12d023d`. Luna wrote the action-table test first (focused compile RED because state types did not exist), implemented `RetryContext` / `NativeErrorPresentation`, and passed focused GREEN plus full local Simulator unit **131/131**. The existing environment UI test now uses only `local` and still asserts welcome/closed WebView; no UI tests were run yet. Details: `task-8-presentation-report.md`.
- Task 8 implementation committed as `c0dbd63`; Luna's test-first native screen updates passed full local Simulator unit **134/134**, UI **18/18**, and focused Dynamic Type UI **1/1**. Sol's first review found diagnostic-code/message accessibility and button-label issues; Luna fixed all, and Sol's second review approved the diff. Full findings/evidence: `task-8-report.md`.
- Task 9 implementation committed as `5ffc48b`; staged startup, passive hosted-test isolation, first-frame-gated WebSession creation, hidden prepared WebView, and background execution adapter. Fresh local Simulator unit **144/144**, UI **18/18**, integration **25/25**, full `all` **187/187**; Python **34/34**.
- Sol review of Task 9 found five Important and one Minor. Luna's `98e1e8b` remediation closed the first-frame retry gate, kept a visible WebView visible after session expiry, reset/rebind only reached Welcome after `reset → restore nil`, matched JWT `carId` to restored binding, blocked unsafe environment switching until manager rebuild, and reflected actual debug WebView state. Fresh unit **152/152**, UI **18/18**, integration **25/25**, `all` **195/195**, Python **34/34**. Sol's remediation-only review found three further cleanup action edges; Luna fixed those in `db354a0`: initial registration StartOver avoids a second reset, post-reset restore failure retries restore, and cleanup failure cannot prepare WebSession on frame. Final Sol re-review approved `98e1e8b..db354a0` with no new findings. Final all **196/196**, Python **34/34**, `git diff --check` clean. Evidence and incomplete bundle disposition: `task-9-report.md`.
- Task 6: Ruling: classify only `.linkActivated` as a user-initiated external action; treat foreign `.formSubmitted`/`.formResubmitted` as automatic and fail the current document when canceled — Apple’s iOS `WKNavigationAction` exposes the request/source frame/navigation type but no user-gesture bit, while the accepted contract opens user-initiated external links and fails automatic foreign main-frame navigation. Cost if wrong: a genuine user-submitted foreign form may show a native document error instead of silently preserving the current page.

- Task 10 complete: implementation `c598dc4`, Sol-requested remediation `1576aee`, and foreground permission race fix `d12efda`. Sol approved both remediation reviews. Luna verified local Simulator unit **172/172**, UI **22/22**, focused race **1/1**, and `git diff --check`; integration/Python were not needed for coordinator-only changes. RED/GREEN evidence is in `task-10-report.md`.
- Task 11 complete: implementation `de89bc4`, Luna remediation `1e4a1d9`, Sol stuck-protocol patch verified by Luna in `8c47478`. Three initial Important findings were covered test-first; two repeated findings persisted because the timer did not fire before document preparation and auth fallback dropped the navigation URL. Sol added the narrow fixes/regression tests; Luna verified focused tests plus local Simulator unit **190/190**, integration **26/26**, UI **22/22**, and `git diff --check`. Full history and evidence: `task-11-report.md`.
- Task 12 complete: cleaner/environment/diagnostics implementation `1e6c9bb`; Sol review remediation `42f0938` and `54d665a`; coordinator diagnostics eligibility seam `298e3d0` approved by Sol. A cleanup-bypass finding repeated because the switch guard handled `.fullReset` but omitted `.environment` pending progress; Sol added the narrow guard/test and Luna verified it. Luna also replaced a mailbox test fixture that could load a prod URL with a fake no-load handle; earlier unsafe-fixture run bundles are explicitly superseded. Final safe local Simulator unit **203/203**, integration **26/26**, UI **22/22**, Release build/nm no debug markers, `git diff --check`. Details: `task-12-report.md`.
- Task 13 complete: local end-to-end registration/rebind/WebView/bridge, ordinary-reset storage persistence, loopback HTTP failure/retry/malformed/offline paths, and native authorization UI evidence committed as `142418f`; final verification report updated in `a655979`. Full local iPhone 18 Pro Simulator `--suite all` on final source passed **254/254** (unit 203, integration 29, UI 22; 0 failures/skips), xcresult `.artifacts/runs/20261005-175918-1791212358542160000/Tests.xcresult`; Release Simulator build passed without launching the app. An earlier retry with a temporary second screenshot attachment showed ~900s XCTest timing anomaly and was stopped; attachment was removed, and the final full run then completed normally (~290s). Sol final review of `9efec72..a655979` approved with no code findings after the all-suite gate closed. Verification report: `docs/development/mobile-session-verification.md`.

## Todo
- [x] Task 1 — BindingStore (Sol approved implementation and runner fix)
- [x] Task 2 — AuthClient (Sol approved implementation and follow-up fixes)
- [x] Task 3 — SessionManager shared operation (Sol approved implementation and follow-up fixes)
- [x] Task 4 — refresh/retry/activity (Sol approved fix round)
- [x] Task 5 — QR scanner/parser (Sol approved; Task 10 fixture verification carried forward)
- [x] Task 6 — WebSession document lifecycle (Sol approved; Task 7 session assertion carried forward)
- [x] Task 7 — NativeBridge (Sol approved stuck-protocol fix)
- [x] Task 8 — native screens/assets (Sol approved)
- [x] Task 9 — staged startup/hosted test isolation (Sol approved; remediation commits `98e1e8b`, `db354a0`)
- [x] Task 10 — QR registration/cancel/reset (Sol approved remediation and permission-race fix)
- [x] Task 11 — readiness/recovery (review findings resolved; Sol stuck-protocol patch verified by Luna)
- [x] Task 12 — full reset/environment/diagnostics (Sol findings resolved; repeated cleanup bypass patched and verified by Luna)
- [x] Task 13 — Simulator local E2E/release build/final review (Sol approved)
- Baseline Python CLI suite: `python3 -m unittest discover -s scripts/tests` — 29 tests passed, before source implementation.
