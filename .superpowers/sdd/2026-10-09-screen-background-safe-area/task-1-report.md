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

На момент первого отчёта не проверены: движение welcome во время жеста с помещающимся содержимым (позднее проверено на симуляторе, см. дополнение P2), маленький физический экран, реальное сканирование камерой, геометрия сканера на устройстве при вырезе/повороте, VoiceOver на устройстве. Симулятор не имеет реальной камеры. Тесты gate проверяют однократную доставку результата и подавление результата после отмены; аппаратную отмену и camera errors отдельно не проверяли.

Полный unit baseline ранее завис на существующем `CoordinatorTests.test_select_prod_does_not_load_web`, это отражено в ledger; его не исправлял и успешный полный набор не заявляю. Integration/web/prod не запускал, согласно области Task 1. Новых зависимостей и дополнительных функций не добавлял.

Для последующего ревью/итогового прогона временно оставлены завершённые baseline/final xcresult и финальные сборки: `.artifacts/builds/1ba77e2f81a20d72f9f3d6506a1a932170d630a627dcb1b5698eae1f8a8bd7eb` (unit signed), `.artifacts/builds/968835ff6955696e0ba2f4cee9691c4fa10ba166c84461f958a5a58faff12799` (UI), а также screenshot/attachments в `/private/tmp/zdeep-task1-*`. Они нужны родительскому агенту для проверки результатов и повторов `--skip-build`; после итоговой проверки следует удалить только эти собственные артефакты. Промежуточная сборка и повторный ранний UI bundle удалены после разбора.

Commit включает только два исходных файла задачи и этот отчёт; push/merge/deploy не выполнялись.

## Проверка замечания P2: наблюдение welcome во время жеста

Замечание было об отсутствии эмпирической проверки, а не о дефекте кода. 2026-10-09 выполнена дополнительная проверка на том же iPhone 17e/F938. Production-код не менялся.

В `ZDEEPUITests.swift` временно добавлен `testTemporaryFittingWelcomeSlowDrag`: launch local/empty binding с `UICTContentSizeCategoryL`, проверка обеих hittable кнопок, затем `coordinate(withNormalizedOffset:)` от `(0.5, 0.55)` к `(0.5, 0.30)` и обратно. Каждый жест выполнялся `press(forDuration: 0.1, thenDragTo: ..., withVelocity: 60, thenHoldForDuration: 2)`. Точки находятся внутри ScrollView. XCTest log подтверждает `Synthesize event` и каждый шестисекундный drag/hold; проверка закончилась PASS 1/1.

Параллельно `subprocess.Popen` запустил `xcrun simctl io F938EC83-7903-4725-9E8C-B447EA6B941C recordVideo --codec=h264 /private/tmp/zdeep-task1-gesture/welcome-drag.mp4`. После завершения теста процессу записи передан SIGINT, `record_exit=0`. Wrapper `/private/tmp/zdeep-task1-record.py` сохранил stdout/stderr теста и записи, epoch старта записи и полный массив команды. Выполненная команда теста:

```sh
python3 scripts/zdeep.py test --environment local --suite ui --only 'ZDEEPUITests/testTemporaryFittingWelcomeSlowDrag()' --simulator F938EC83-7903-4725-9E8C-B447EA6B941C
```

Читаемый bundle: `.artifacts/runs/20261009-174136-1791556896419048000/Tests.xcresult`; вывод `TEST EXECUTE SUCCEEDED`. Эпоха старта процесса записи `1791556877.338860`; интервалы gesture в XCTest log: вверх `1791556908.488105–1791556914.526908`, вниз `1791556914.526925–1791556920.539653`. Относительно старта процесса записи это примерно `31.15–37.19` и `37.19–43.20` секунды; небольшая задержка начала записи не влияет на выбор кадров в середине жестов.

Видеофайл имеет размер кадра 1170×2532 и продолжительность 43.703 sec. Кадры извлечены командой:

```sh
ffmpeg -hide_banner -loglevel error -ss 28 -i /private/tmp/zdeep-task1-gesture/welcome-drag.mp4 -t 15 -vf fps=2 /private/tmp/zdeep-task1-gesture/frames/frame-%03d.png
```

Просмотрен `/private/tmp/zdeep-task1-gesture/contact-sheet.png`, включающий кадры `31, 33, 35, 37, 39, 41, 42.5` sec. На кадрах в середине обоих движений и удержания положение hero, заголовка и обеих кнопок одинаково; контент целиком помещается. Это наблюдение во время исполнения жеста, а не только сравнение до/после.

Дополнительно PIL сравнил crop `(0,300,1170,2450)`, исключающий status bar, у 22 кадров `31.5–42.0` sec: SHA-256 пикселей у всех кадров одинаков (`crop-sha256.txt`). От кадра 31.0 sec различия максимальны лишь 3/255 на канал, от H264-кодирования, а ориентиры не смещены. `ffprobe` сохранил исходные timestamps в `frame-times.txt`: после обновления в `31.436667` следующая исходная картинка появляется только в `42.393333` (смена часов status bar); simctl записывает обновления дисплея, поэтому извлечение с fps=2 дублирует неподвижную картинку между обновлениями. Видеодоказательство не показывает движущийся палец; факт исполнения жестов подтверждает XCTest log.

Вывод ограничен проверенным сценарным устройством: помещающийся welcome на iPhone 17e с обычным L не сдвигается во время медленного вертикального жеста в обе стороны. Проверка отсутствия ненужного bounce для этого случая выполнена. Физическое устройство, другие размеры экрана и аппаратная камера по-прежнему не проверены.

Временный тест полностью удалён восстановлением исходных bytes. `git diff -- ZDEEP/ZDEEPUITests/ZDEEPUITests.swift` пуст; production diff отсутствует. После удаления выполнен штатный регрессионный тест на текущем коде:

```sh
python3 scripts/zdeep.py test --environment local --suite ui --only 'ZDEEPUITests/testAccessibilityTextSizeKeepsWelcomeActionsReachable()' --simulator F938EC83-7903-4725-9E8C-B447EA6B941C --skip-build
```

PASS 1/1, `TEST EXECUTE SUCCEEDED`, API health 200, читаемый bundle `.artifacts/runs/20261009-174216-1791556936150927000/Tests.xcresult`. Полный stdout сохранён внутри bundle (`xcresult`), команда и результат приведены выше. Сборка временного теста `.artifacts/builds/ff25d2668148aa40c511fe611dccb5dff690a7e56562694f908a8ddb9b9efaa7` удалена после завершения записи и разбора. Для независимого ревью оставлены `/private/tmp/zdeep-task1-gesture/` (mp4, log, metadata, кадры, contact sheet, pixel/hash checks) и два новых xcresult; эти доказательства удалить после итогового ревью.
