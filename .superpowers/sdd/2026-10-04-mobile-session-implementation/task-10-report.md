# Task 10 — QR-регистрация, отмена и перепривязка

## Реализация

- Добавлены camera permission provider и состояния scanner/denied/restricted. Coordinator связывает permission, возврат из Settings, отмену и результат QR через актуальный scenario/intent; поздние результаты игнорируются.
- Регистрация использует parser из Task 5. Повторный QR не запускает вторую пару. Ошибка pair очищает незавершённую привязку до показа исходной ошибки; ошибка очистки оставляет только retry cleanup. Ошибка авторизации после сохранения binding сохраняет его для token retry.
- Cancel, rebind и reset инвалидируют сценарий до async storage, останавливают SessionManager и закрывают WebSession. Welcome отображается только после reset и подтверждённого `restore() == nil`; сбои остаются в cleanup/restore-контексте с повтором нужной операции.
- Подготовка WebSession при `.loading` теперь требует сохранённый binding. При QR-регистрации WebSession подготавливается после успешного сохранения binding, а не во время pending save.
- Добавлен явный DEBUG+Simulator UI launch fixture с fake store/session manager/permission и synthetic QR-кнопкой; аргумент содержит только название сценария. Обычный launch и Release не используют эту ветку.
- Добавлены fake-dependency Coordinator tests и Authorization UI tests для permission/back, synthetic QR, повторного QR, cancel во время save и после JWT, registered binding, cleanup/marker retry и подтверждения rebind.

## RED → GREEN

- Первичный Coordinator RED: focused build выявил отсутствующие `CameraPermissionProviding`, camera injection и scanner/permission states/API. Компиляция завершилась до исполнения тестов, поэтому xcresult для этого RED не создавался.
- Первичный UI RED: `AuthorizationUITests/test_rebindDeclineKeepsRegistrationAndConfirmResetsOnce()` упал на отсутствии UI rebind в прежнем fixture: `.artifacts/runs/20261005-082925-1791178165533132000/Tests.xcresult`.
- Cancel-during-save запуск `.artifacts/runs/20261005-082607-1791177967138722000` был остановлен после того, как тест ожидал gate до запуска async регистрации. Это ошибка последовательности теста, не production regression. После замены на Task + gate его исправленный focused прогон прошёл: `.artifacts/runs/20261005-082734-1791178054645778000`.
- Первый `AuthorizationUITests` class показал 2 pass и synthetic QR fixture failure: URL не соответствовал parser contract. Исправлен только fake QR формат; повторный XCTest class выполнил 3/3 без failures: `.artifacts/runs/20261005-083652-1791178612900890000/Tests.xcresult`. Обёртка `zdeep.py` вернула 1, потому что class selector сопоставляет один тест; сам xcodebuild завершился `TEST EXECUTE SUCCEEDED`.
- Дополнительный test-first regression: `test_cancel_during_save_cleans_late_registered_result()` обнаружил WebSession, созданный до завершения binding save: `.artifacts/runs/20261005-083946-1791178786562255000`. После ограничения подготовки на сохранённый binding и переноса подготовки после успешного save тест прошёл 1/1: `.artifacts/runs/20261005-084050-1791178850049247000`.
- `--skip-build` однажды отклонён runner-ом из-за отсутствия актуальной signed Simulator-сборки. Это ошибка fingerprint/build availability, не результат теста; повтор выполнен со свежей сборкой.

## Проверки

Simulator: iPhone 18 Pro, `0DDEE416-EECF-4BF3-8F15-BA93A980033A`; во всех командах использован `--environment local`.

- `python3 scripts/zdeep.py test --environment local --suite unit --simulator 0DDEE416-EECF-4BF3-8F15-BA93A980033A` — PASS, 167/167, bundle `.artifacts/runs/20261005-084110-1791178870725576000/Tests.xcresult`.
- `python3 scripts/zdeep.py test --environment local --suite ui --simulator 0DDEE416-EECF-4BF3-8F15-BA93A980033A` — PASS, 21/21, bundle `.artifacts/runs/20261005-084143-1791178903270829000/Tests.xcresult`.
- `git diff --check` — PASS.
- Python suite не запускался: Task 10 не меняет Python tooling/scripts.
- Test/prod и физическое устройство не использовались.

## Remediation по Sol review

### RED → GREEN

- Item 1, холодное восстановление и token retry должны быть отменяемыми: `test_cancel_cold_restore_token_attempt_before_and_after_retry()` и `AuthorizationUITests/test_coldRestoreLoadingCanCancelAndClearsStoredBinding()`. Unit RED `.artifacts/runs/20261005-090311-1791180191964946000/Tests.xcresult` показал недоступную отмену, отсутствие очистки/остановки и позднюю публикацию auth ошибки поверх Welcome. UI RED `.artifacts/runs/20261005-085710-1791179830248839000/Tests.xcresult` зафиксировал отсутствующую кнопку «Отмена»; этот запуск был остановлен при незавершённом xcodebuild finalization. Focused GREEN: unit 1/1 `.artifacts/runs/20261005-090632-1791180392415248000/Tests.xcresult`, UI 1/1 `.artifacts/runs/20261005-090708-1791180428167355000/Tests.xcresult`. Сценарий проверяет также игнорирование позднего refresh failure после успешной отмены.
- Item 2, повторная проверка camera permission и неактивные callbacks: `test_foreground_rechecksScannerPermissionAndIgnoresInactiveRequestResult()`. RED `.artifacts/runs/20261005-090351-1791180231347587000/Tests.xcresult` обнаружил scanner после отказа в permission, открытие scanner пока приложение было неактивно и принятие QR в неактивном состоянии. Focused GREEN 1/1 `.artifacts/runs/20261005-090942-1791180582979246000/Tests.xcresult`.
- Item 3, поздний результат `beginRegistration` не должен сбрасывать новую привязку: `test_lateBeginRegistrationCannotResetNewScenarioBinding()`. RED `.artifacts/runs/20261005-090433-1791180273213595000/Tests.xcresult` показал лишний второй reset и потерю новой привязки. Удалён stale reset; focused GREEN 1/1 `.artifacts/runs/20261005-091032-1791180632900610000/Tests.xcresult`.
- Item 4, retry после cleanup должен завершить restore до auth: `test_restoreRetryWithUnexpectedBindingStaysInRestoreWithoutAuthOrWeb()`. RED `.artifacts/runs/20261005-090502-1791180302942932000/Tests.xcresult` показал переход из restore-контекста и вызов SessionManager при неожиданно найденной привязке. Сохранены cleanup completion context и restore failure; auth/WebSession остаются закрыты до `restore() == nil`. Focused GREEN 1/1 `.artifacts/runs/20261005-091209-1791180729146908000/Tests.xcresult`.

### Итоговые проверки remediation

- `python3 scripts/zdeep.py test --environment local --suite unit --simulator 0DDEE416-EECF-4BF3-8F15-BA93A980033A` — PASS, 171/171, `.artifacts/runs/20261005-091403-1791180843284252000/Tests.xcresult`.
- `python3 scripts/zdeep.py test --environment local --suite ui --simulator 0DDEE416-EECF-4BF3-8F15-BA93A980033A` — PASS, 22/22, `.artifacts/runs/20261005-091440-1791180880765878000/Tests.xcresult`.
- Первый полный unit запуск в ограниченном sandbox завершился до разрешения package graph: CoreSimulatorService и пользовательские SwiftPM/Clang cache оказались недоступны. Это не тестовый результат; повторённая команда после разрешённого доступа к Simulator/cache дала указанный PASS.
- `git diff --check` — PASS. Python tooling не менялся, поэтому Python suite не запускался. Integration suite не затронут: remediation изменяет только coordinator, permission/reset flow и их unit/UI tests.
- Все проверки выполнялись только на локальном Simulator и с `--environment local`; test/prod и физическое устройство не использовались.
