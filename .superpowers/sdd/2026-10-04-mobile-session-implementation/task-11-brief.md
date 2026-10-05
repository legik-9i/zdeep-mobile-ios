# Task 11 — готовность WebSession, повторы и восстановление процесса

Источник требований: принятый план `docs/superpowers/plans/2026-10-04-mobile-session-implementation.md`, раздел Task 11. Brief фиксирует его без расширения проектных решений.

## Объём

- Добавить readiness coordination с проверкой scenario, WebSession container, attempt и document identity, текущей привязки/сессии, foreground и допустимого web screen (`content`/`error`). DOM-ready и diagnostic mailbox state не считаются принятым `reportReady`.
- Ограничить ожидание ready 60 секундами активного времени через тот же `SessionClock`, который использует auth/session manager. Ставить бюджет на паузу в background, продолжать с остатка при foreground. Redirect и refresh не начинают бюджет заново. Принятый ready отменяет timeout, в том числе если WebView пока скрыт.
- Сохранить явные retry-контексты: authorization retry всегда делает token attempt, затем создаёт новый web document; web retry при действующем JWT создаёт новый document без HTTP. Пассивные auth failure/success не должны заменять уже показанную нативную ошибку. Старые ready/waiter identities отзываются немедленно.
- Для полной навигации начинать новый readiness attempt с отменой; сохранять SessionManager working mode. Реальное завершение WebKit content process восстанавливать автоматически один раз на независимое завершение; после ошибки/timeout показывать Retry/Rebind. До первого reveal process death сразу является ошибкой.
- Integration проверяет публичный WebKit reload/reinjection и смену document ID; не использовать private/closed API для вызова process termination.

## Обязательные проверки

- `test_reveal_requires_ready_valid_session_and_foreground`
- `test_readiness_budget_counts_60_active_seconds`
- `test_refresh_and_redirect_do_not_restart_budget`
- `test_accepted_ready_cancels_budget_even_when_hidden`
- `test_auth_retry_after_background_ready_replaces_document`
- `test_web_retry_uses_valid_jwt_without_http`
- `test_native_error_survives_passive_auth_failure_and_success`
- `test_full_navigation_preserves_working_mode_and_shows_cancel`
- `test_process_death_gets_one_recovery_then_error`
- WebKit integration для reload/reinjection после публичного восстановления.

Все проверки запускать только в `local` на Simulator `0DDEE416-EECF-4BF3-8F15-BA93A980033A`; test/prod и физические устройства исключены.
