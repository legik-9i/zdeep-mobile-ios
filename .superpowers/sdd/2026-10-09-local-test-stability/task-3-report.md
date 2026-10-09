# Отчёт по задаче 3: изоляция unit-тестов Coordinator

## Изменения

Изолировал от application storage все семь выявленных сценариев `AppCoordinator`, которые вызывают `start`, reset или смену database scope. Менялся только `ZDEEP/ZDEEPTests/CoordinatorTests.swift`; производственный код и adapters не менялись.

Инвентаризация до правок:

| Тест | Риск до правок |
|---|---|
| `test_select_prod_does_not_load_web` | Не был передан fake binding store или cleaner; local → prod очищает data scope. |
| `test_environment_cleanup_failure_keeps_old_configuration_and_target` | Был fake cleaner, но binding store оставался production default. |
| `test_same_scope_switch_still_discards_memory_jwt_and_old_document` | `start` и test → prod использовали production default store и cleaner. |
| `test_full_reset_failure_retries_only_remaining_data_before_auth` | Был fake cleaner, но reset/recovery restore использовали production default binding store. |
| `test_cross_database_switch_requests_clear` | Смена local → test использовала production default binding store. |
| `test_suspended_environment_clear_blocks_open_and_stale_switches` | Смена local → test использовала production default binding store. |
| `test_test_prod_switch_preserves_store` | Смена test → prod использовала production default binding store. |

В эти тесты внедрены существующие `CoordinatorBindingStore`, `CoordinatorSessionManager`, `FakeWebSessionFactory` и `makeOwnedDataAdapters()`. Проверяются зарегистрированная или пустая привязка после восстановления, отсутствие очистки в общем пространстве test/prod и ожидаемые `cleanCount` всех fake-адаптеров для успешной, неуспешной и повторной очистки. Подмена Web factory исключает использование WebKit storage. Добавлены проверки, что переход test → prod не вызывает очистку.

## Проверки

Первый сборочный запуск выявил порядок named arguments в одном конструкторе (`sessionManager` должен предшествовать `ownedClientDataCleaner`); дополнительная ошибка `.prod` была каскадной. Порядок исправлен. До правок отдельный baseline не запускался, поэтому исходный RED не заявляется.

Одна успешная сборка с тестом, затем восемь запусков с `--skip-build`. Все выполнялись в `local`, на симуляторе `0DDEE416-EECF-4BF3-8F15-BA93A980033A`, Xcode 27.0 (27A266a). Для каждого `--only` CLI подтвердил ровно один выполненный тест; всего прошло 9/9:

| Точный `--only` selector | Результат bundle |
|---|---|
| `CoordinatorTests/test_select_prod_does_not_load_web()` | `.artifacts/runs/20261009-185847-1791561527355818000/Tests.xcresult` |
| `CoordinatorTests/test_environment_cleanup_failure_keeps_old_configuration_and_target()` | `.artifacts/runs/20261009-185918-1791561558802436000/Tests.xcresult` |
| `CoordinatorTests/test_same_scope_switch_still_discards_memory_jwt_and_old_document()` | `.artifacts/runs/20261009-185927-1791561567824783000/Tests.xcresult` |
| `CoordinatorTests/test_full_reset_failure_retries_only_remaining_data_before_auth()` | `.artifacts/runs/20261009-185935-1791561575934306000/Tests.xcresult` |
| `CoordinatorTests/test_cross_database_switch_requests_clear()` | `.artifacts/runs/20261009-185941-1791561581690992000/Tests.xcresult` |
| `CoordinatorTests/test_suspended_environment_clear_blocks_open_and_stale_switches()` | `.artifacts/runs/20261009-185947-1791561587213824000/Tests.xcresult` |
| `CoordinatorTests/test_test_prod_switch_preserves_store()` | `.artifacts/runs/20261009-185952-1791561592509508000/Tests.xcresult` |
| `BindingStoreTests/test_keychain_adapter_round_trips_and_restores_durable_data()` | `.artifacts/runs/20261009-185958-1791561598251927000/Tests.xcresult` |
| `OwnedClientDataCleanerTests/test_keychain_cleanup_removes_only_records_for_explicit_app_service()` | `.artifacts/runs/20261009-190004-1791561604357153000/Tests.xcresult` |

Команды запускались по одному тесту на каждый точный selector:

```sh
python3 scripts/zdeep.py test --environment local --suite unit --only '<selector>' --simulator 0DDEE416-EECF-4BF3-8F15-BA93A980033A
python3 scripts/zdeep.py test --environment local --suite unit --only '<selector>' --simulator 0DDEE416-EECF-4BF3-8F15-BA93A980033A --skip-build
```

Дополнительно: `git diff --check` прошёл. Полные наборы unit, integration, UI и `all` в этой задаче не запускались. Общий прогон оставлен финальной задаче плана.

## Самопроверка и ограничения

- Изменения кода ограничены указанным файлом тестов; новые helper/container, production condition, adapter и dependency не добавлялись.
- Переделки `BindingStoreTests.swift` и `OwnedClientDataCleanerTests.swift` не потребовались; выполнены их два прямых Keychain теста.
- Первый диагностический build завершился ошибкой порядка параметров; следующая сборка прошла. Xcode также выводил существующие Swift warnings вне изменённых строк.
- Фактическое обращение к application storage до изменений не проверялось запуском baseline; инвентаризация основана на production default зависимостях конструктора и путях выполнения тестов. После изменений все затронутые сценарии используют fake-инъекции.
