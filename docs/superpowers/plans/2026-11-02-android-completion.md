# Android Native Completion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to execute this plan task-by-task. Track the checkboxes; do not restart the original port plan.

**Goal:** Finish the native Android port with a fast verification workflow and a verified Testing Debug APK.
**Architecture:** Keep the existing single app module and native/web boundary. Simplify verification first; then fix confirmed native defects and remove narrowly proven dead code. Preserve auth, storage and document security guarantees.
**Tech Stack:** Existing Kotlin/Compose, AndroidX WebKit, CameraX/ML Kit, OkHttp, JUnit4 and Python standard-library scripts.
**Spec:** `docs/superpowers/specs/2026-11-02-android-completion-design.md` (initially in the iOS checkout; copy into Android before execution).

## Global Constraints

- Work in `/Users/oleg/projects/zdeep-mobile/android`; all task paths below are relative to that directory.
- All native Android sources, including `app/src/main/java/ru/zdeep/mobile/web/**`, are authorized. Never modify `/Users/oleg/projects/zdeep-webview2`.
- Website Back/modal guards and Stackflow theme are outside this goal. Do not make them completion blockers.
- API 36 emulator target, minSdk 30; use existing JBR 21 and prepared dedicated AVD with host GPU. Do not modify unrelated AVDs.
- No production Release assembly/signing/publication, automated testing-backend traffic, or physical-device requirement.
- No new frameworks, dependencies or general runner. Reuse Gradle and scripts. Preserve nonzero test discovery and failure handling.
- Native implementation: Luna High; normal review: Terra medium. One final Sol High review after these five tasks. Keep reviews bounded to actual changes; no repeated whole-repo audit without a concrete defect.
- No GitHub operations. Android checkout currently lacks `.git`; do not initialize a repository or fabricate commits. If Git remains absent, record this and skip commit/worktree steps.
- Update authoritative Android documentation only after copying this addendum. Mark iOS originals as pointers; do not maintain competing current-state summaries.

## Review Focus

1. Fast suite must not silently omit required build-contract assertions (Task 1).
2. Install optimization must preserve force-stop/install-over/scope/reinstall acceptance boundaries (Task 1).
3. A late readiness callback must not overwrite ready/cleanup state (Task 2).
4. Theme change must affect the next load without reloading current business content (Task 3).
5. Unknown TLS frame attribution must never lead to trusting a bad certificate (Task 3).

## Task 1: Fast, explicit verification workflow

**Files:** modify `app/build.gradle.kts`, `scripts/check-process-restart.sh`, `scripts/check-platform-api36.sh`, `scripts/tests/test_process_camera_driver.py`, `app/src/test/java/ru/zdeep/mobile/tests/unit/{SessionRefreshTest,BuildContractTest}.kt`, `app/src/androidTest/java/ru/zdeep/mobile/tests/platform/{WebNavigationTest,SystemBackTest}.kt`, README/AGENTS; create `.codex/skills/android-testing/SKILL.md`.
**Interfaces:** Gradle `:app:testFastLocalDebug`, `:app:testHttpLocalDebug`, `:app:checkDebugEnvironments`; existing class/package/method Android selectors remain available. Existing full platform/process scripts remain the final acceptance entry points. No new test runner.

- [ ] Copy approved spec/plan into Android docs. Inventory actual current task names, filters and driver calls before editing.
- [ ] Define `testFastLocalDebug` as a standard Gradle Test task reusing localDebug test output/runtime classpath, excluding `component.AuthClientTest` and `unit.BuildContractTest`. Define `testHttpLocalDebug` selecting only AuthClientTest. Define `checkDebugEnvironments` to run only local/QA BuildContract cases using their correct variant outputs. Keep existing standard full JVM tasks intact; verify actual selected XML test names, not just BUILD SUCCESSFUL.
- [ ] Remove only `SessionRefreshTest.refreshLeadAndBackoffAreExact`, which duplicates the policy test. Retain manager scheduling tests and the real 30-second transport deadline test.
- [ ] Add/update script regression checks before optimizing installs: same installed variant may skip reinstall, explicit same-scope install-over must still install, local→QA must install QA, uninstall must be followed by a real fresh install. Implement install state ownership in the host driver, not runtime. Retain separate instrumentation where process boundaries are the subject of the test.
- [ ] Strengthen `automaticForeignNavigationAndServerRedirectAreBlocked`: observe the redirect request/decision before asserting trusted content and no committed foreign page. Do not replace waiting with a longer sleep. Add a keyboard-before-host-Back assertion through actual MainActivity/AppRoot; use test fixtures without adding product bypass hooks or requiring Stackflow changes.
- [ ] Run `./gradlew :app:testFastLocalDebug :app:testHttpLocalDebug :app:checkDebugEnvironments`; inspect nonzero XML selectors and record elapsed times. Run `python3 -m unittest discover -s scripts/tests`. Run only changed WebNavigation/SystemBack class selectors on API36 at this stage, not the entire device suite.
- [ ] Write Russian skill and README: edit→minimal tests, actual shell commands, JBR/SDK/AVD/local prerequisites, explicit slow suite, expected counts/skips and expansion triggers. Use the existing skill-creator instructions when creating the skill. Update the platform script's fixed expected test count only if test discovery actually changed. Do not delete harness tests before deleting the code they protect.

## Task 2: Main-thread readiness and scheduler lifetime

**Files:** `app/src/main/java/ru/zdeep/mobile/{AppViewModel,MainActivity}.kt`, `session/SessionClock.kt`; `app/src/test/java/ru/zdeep/mobile/tests/unit/{ReadinessTest,SessionRefreshPolicyTest}.kt`.
**Interfaces:** `SessionClock.schedule(deadlineMs, action)` retains monotonic semantics and cancellation. ViewModel readiness mutations must execute on main. Scheduler ownership must not leave a new idle executor for each destroyed ViewModel.

- [ ] Add a regression that releases a production-like worker callback after ready or cleanup has already been accepted; assert no late ERROR, no restored binding/document state. Observe the main dispatcher before state mutation; deterministic synchronization, no timing lottery.
- [ ] Run the targeted test red; route readiness callback to `viewModelScope` main before all guards and writes. Keep generation checks inside that delivery. Do not move the whole SessionManager to a new architecture.
- [ ] Choose the smallest scheduler lifetime fix after tracing all consumers: one process-owned scheduler, or explicit lifecycle ownership if simpler in current code. Preserve elapsed realtime rechecks across sleep, stale callback cancellation and exact deadlines. Do not substitute wall time.
- [ ] Run `./gradlew :app:testFastLocalDebug` and scheduler/readiness cases with nonzero results. No full device regression for this intermediate step unless a failure exposes an Android-only concern.

## Task 3: Close native functional gaps

**Files:** `AppRoot.kt`, `AppViewModel.kt`, `camera/QrScanner.kt`, `web/{WebSession,WebLaunchUrl}.kt`; related JVM/platform tests and camera fixtures.
**Interfaces:** host supplies current light/dark to launch URL creation; next load uses the latest theme, current page remains loaded. Public JS methods/DTOs unchanged.

- [ ] Add host-level initial dark and next-load theme-change assertions; retain existing URL serialization tests. Implement one launch-theme owner, with the same next-load behavior as iOS. A theme toggle alone must not change the current load request or recreate WebView.
- [ ] Exercise camera-unavailable behavior with permission granted. If no useful error/exit exists, handle the error through existing native UI conventions and release camera resources. Add one focused regression; do not add a camera abstraction framework.
- [ ] Add real business-WebView user-link tests for target=_blank routing: external links open externally, trusted links follow existing policy, automatic foreign navigation remains blocked. Investigate multiple-window settings and fix only what the test demonstrates.
- [ ] Replace the ignored same-URL PREPARING TLS expectation with a feasible documented native policy: always cancel bad TLS; during PREPARING, same-resource ambiguity may fail the prepared document, while committed-page subresource failures do not fail the whole page. Update the regression to prove that policy and remove its Ignore; retain real bad-certificate main/subresource tests. No trust-all/proceed.
- [ ] Run fast JVM and the changed Android navigation/camera/host cases. Record risk disproved versus defect fixed. Update platform expected count/skip handling from discovered results; do not reduce mandatory assertions to make the gate green.

## Task 4: Remove proven dead runtime code

**Files:** `AppViewModel.kt`, `AppRoot.kt`, `web/WebSession.kt`, callers and `tests/{unit,support}` fixtures.
**Interfaces:** production event entry points require explicit request/session provenance. Test helpers can assemble those arguments but cannot silently grant production authority.

- [ ] Search all callers before edits; remove unused WebSession appVersion/bridgeVersion/launchTheme constructor parameters, constant boolean alternatives, and the tests-only one-argument ViewModel event entry point. Require explicit IDs in reportReady calls; move short fixture syntax into test support.
- [ ] Preserve stale-source and null-identity renderer handling on the strict runtime path. Keep runtime ordering tests for events arriving before Compose session registration.
- [ ] Run `./gradlew :app:testFastLocalDebug :app:assembleLocalDebug :app:assembleTestingDebug :app:assembleLocalDebugAndroidTest :app:assembleQaDebugAndroidTest :app:lintLocalDebug :app:lintTestingDebug`. Update affected fixtures and tests rather than retaining production compatibility solely for test convenience.

## Task 5: Final native acceptance and delivery

**Files:** README, verification ledger, build outputs; final source changes only for demonstrated failures.
**Interfaces:** Testing artifact `app/build/outputs/apk/testing/debug/app-testing-debug.apk`; version/hash and rebuild/install commands identify the verified source and artifact.

- [ ] Run one bounded final Sol High review of these changes and requirements; address concrete findings with focused checks. No fresh general audit loop.
- [ ] Run fast JVM, HTTP and both build-contract checks; Python helpers; Debug lint/build. Record actual results. Run `scripts/check-platform-api36.sh` once and `scripts/check-process-restart.sh` once using the explicit existing Debug/test APK environment variables documented in README. The final runtime TLS regression must no longer be ignored. Separate remaining infrastructure skips from mandatory driver phases.
- [ ] On failure, isolate the failing case/environment first. Rerun the whole affected suite only after a change that can invalidate its previous coverage; never rerun solely because a prior observation timed out.
- [ ] Restore Testing Debug on dedicated API36 AVD, verify installed APK hash against delivery artifact, package version/min/target and visible native launch. No testing QR/login or production build.
- [ ] Publish one concise current ledger mapping native requirements to final-source evidence; mark original unchecked plan steps historical rather than falsely claiming old red-phase execution. State website Back/Stackflow and production release exclusions explicitly.
- [ ] Stop when approved native scope is green and artifact verified. Mark the persistent goal complete only after the final requirement audit; excluded web/release work is not a reason to start more audits.
