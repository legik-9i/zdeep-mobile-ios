# Task 1 — Welcome и QR-сканер

Статус: реализация завершена, целевые автоматические проверки прошли; готово к независимому ревью Sol. Аппаратные и динамические визуальные проверки остаются ограничениями, перечисленными ниже.

## Область изменений

Изменены только `WelcomeView.swift` и `QRScannerView.swift`. Прочитаны оба caller в `ContentView.swift`, существующие `CameraPermissionTests` и UI-тест Dynamic Type. `WelcomeView(onScan:)`, `QRScannerView(onResult:onCancel:)`, `ScannerResultGate`, обработка ошибки и однократная доставка сохранены. Чужие исходные изменения и файлы Task 2 не редактировались.

Welcome сохраняет ScrollView и получает `.scrollBounceBehavior(.basedOnSize)`. Камера отдельно получает `.ignoresSafeArea(.container)`; управляющая кнопка остаётся в безопасной области и получает белый текст на тёмной капсуле. Центральная квадратная рамка рассчитывается от доступной ширины/высоты, содержит белые угловые маркеры, затемнение вокруг и подпись «Поместите QR-код в рамку». Декорация не перехватывает события (`allowsHitTesting(false)`), графика скрыта от accessibility, текст подсказки доступен. Область распознавания CodeScanner не менялась.

## Baseline и визуальные наблюдения

До правки исходный ScrollView не имел настройки bounce. Реальный bounce во время жеста не наблюдался, поэтому отсутствие/наличие движения не заявляется как визуально доказанное.

Baseline UI-тест с Accessibility XXXL прошёл 1/1. Из его xcresult извлечён и просмотрен screenshot: обе кнопки полностью видимы после прокрутки. После правки тот же тест прошёл; просмотренный screenshot также показывает полностью видимые кнопки. На окончательной версии дополнительно запущен обычный размер L через simctl и просмотрен `/private/tmp/zdeep-task1-normal.png`: изображение, текст и обе кнопки помещаются целиком на iPhone 17e. Это статический screenshot и не доказательство отсутствия bounce во время жеста.

## Проверки и команды

Все команды выполнялись из `/private/tmp/zdeep-ios-screen-fixes`, simulator `F938EC83-7903-4725-9E8C-B447EA6B941C` (iPhone 17e). Другие симуляторы не использовались. Local UI preflight: API `/health` HTTP 200. Первый sandbox-запуск был остановлен ограничением localhost (`Operation not permitted`); та же команда успешно повторена с разрешённым доступом. Unit не требует API.

Общий префикс команд: `python3 scripts/zdeep.py test --environment local --simulator F938EC83-7903-4725-9E8C-B447EA6B941C`.

| Сценарий / аргументы к префиксу | Результат | Каталог `.artifacts/runs/` |
|---|---|---|
| Baseline: `--suite ui --only 'ZDEEPUITests/testAccessibilityTextSizeKeepsWelcomeActionsReachable()' --skip-build` | PASS 1/1, читаемый xcresult | `20261009-173336-1791556416466147000` |
| После изменения: `--suite ui --only 'ZDEEPUITests/testAccessibilityTextSizeKeepsWelcomeActionsReachable()'` | PASS 1/1 | `20261009-173452-1791556492227741000` |
| Финальный код: `--suite unit --only 'CameraPermissionTests/test_scanner_completion_is_delivered_once()'` | PASS 1/1 | `20261009-173546-1791556546225160000` |
| Финальный код: `--suite unit --only 'CameraPermissionTests/test_scanner_completion_after_cancel_is_ignored()' --skip-build` | PASS 1/1 | `20261009-173558-1791556558723152000` |
| Финальный код: `--suite ui --only 'ZDEEPUITests/testAccessibilityTextSizeKeepsWelcomeActionsReachable()'` | PASS 1/1 | `20261009-173638-1791556598212527000` |

Попытки `--skip-build` после изменения fingerprint и для UI после подписанной unit-сборки корректно отвергнуты CLI; выполнены необходимые пересборки. Повтор финального UI нужен был после удаления лишнего игнорирования safe area с затемнения: safe area игнорирует только камера. `git diff --check` прошёл.

## Ограничения и передача

Не проверены: движение welcome во время жеста с помещающимся содержимым, маленький физический экран, реальное сканирование камерой, геометрия сканера на устройстве при вырезе/повороте, VoiceOver на устройстве. Симулятор не имеет реальной камеры. Тесты gate проверяют однократную доставку результата и подавление результата после отмены; аппаратную отмену и camera errors отдельно не проверяли.

Полный unit baseline ранее завис на существующем `CoordinatorTests.test_select_prod_does_not_load_web`, это отражено в ledger; его не исправлял и успешный полный набор не заявляю. Integration/web/prod не запускал, согласно области Task 1. Новых зависимостей и дополнительных функций не добавлял.

Для последующего ревью/итогового прогона временно оставлены завершённые baseline/final xcresult и финальные сборки: `.artifacts/builds/1ba77e2f81a20d72f9f3d6506a1a932170d630a627dcb1b5698eae1f8a8bd7eb` (unit signed), `.artifacts/builds/968835ff6955696e0ba2f4cee9691c4fa10ba166c84461f958a5a58faff12799` (UI), а также screenshot/attachments в `/private/tmp/zdeep-task1-*`. Они нужны родительскому агенту для проверки результатов и повторов `--skip-build`; после итоговой проверки следует удалить только эти собственные артефакты. Промежуточная сборка и повторный ранний UI bundle удалены после разбора.

Commit включает только два исходных файла задачи и этот отчёт; push/merge/deploy не выполнялись.
