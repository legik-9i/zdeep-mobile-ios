# Проверка инфраструктуры разработки

Этот документ фиксирует текущие команды проверки инфраструктуры разработки и исторические подтверждения задач 1–6. Он не является релизной инструкцией. Контур `prod` не используется автоматическими тестами.

## Тесты

Все автоматические наборы (`unit`, `integration`, `ui`, `all`) запускаются только в `local`. Получи доступный UDID симулятора:

```sh
xcrun simctl list devices available
```

Полный набор запускается один раз в конце задачи; `all` уже включает unit, integration и UI:

```sh
python3 scripts/zdeep.py test --environment local --suite all --simulator <SIMULATOR_UDID>
```

Повтор отдельного теста использует точный `nodeIdentifier` из `.xcresult`; запускай только для диагностики падения или проверки исправления:

```sh
python3 scripts/zdeep.py test --environment local --suite unit --only 'EnvironmentTests/test_testing_api_path_is_preserved()' --simulator <SIMULATOR_UDID> --skip-build
```

Для integration, UI и all local preflight требует `GET http://localhost:4002/health` и `GET http://localhost:4005` с HTTP 200. Unit и тесты Python runner не требуют живых API/Web. Автоматический прогон в `test` не поддерживается. Диагностика симулятора допускает `local`/`test`, физического iPhone — только `test`; test health и запрос корневого URL API для диагностики не нужны.

## Отладка WebView

На симуляторе допустимы `local` и `test`. На физическом iPhone используй исключительно `test`; приложение и WebView должны оставаться открытыми на переднем плане:

```sh
python3 scripts/zdeep.py device-launch --environment test --device <DEVICE_UDID>
python3 scripts/zdeep.py logs --target device --device <DEVICE_UDID>
python3 scripts/zdeep.py diagnose --target device --device <DEVICE_UDID> --environment test --js-stdin --timeout 45
```

Для последней команды передай JavaScript в stdin и заверши ввод EOF. Сначала запусти `device-launch`, затем вручную открой тестовую WebView. Инструкция не предполагает автоматического открытия WebView на iPhone. `logs` копирует фильтрованный журнал приложения, не весь системный лог и не текст/результат JS. При запуске UI с reader через `device-launch` команда завершает текущий процесс.

Исторический результат предыдущего этапа: при включённом Wi-Fi на iPhone в test успешно проверены `1+1 → 2`, ошибка JavaScript и DOM event. При выключенном Wi-Fi подтверждена проводная передача файлов CoreDevice; исполнение JS по этому пути осталось неподтверждённым. Один последующий запуск вернул SpringBoard `Locked`. Тогда дополнительная проверка не выполнялась по решению пользователя.

Подробности транспорта и команд: [iphone-diagnostics.md](iphone-diagnostics.md). Известные ограничения эксперимента: [отчёт USB diagnostics](../../experiments/usb-diagnostics/README.md).

## Stitch → SwiftUI

Для Stitch проекта ZDEEP (`1417382377358815087`) навыку `ios-stitch-implementation` требуется `stitch-design-pipeline`; актуальные HTML и theme/config конкретного экрана задают значения для реализации. Не преобразуй каждый Tailwind-класс в отдельный SwiftUI modifier: извлекай вычисленные значения в общие native tokens/styles и сравнивай результат со скриншотом при сопоставимом viewport.

У Welcome screen `bc93291bf18e4d78b737a9a035b30434` HTML указывает на светлую тему `Bento Grids`, а глобальная тема проекта `Autonomous Kinetic` сейчас тёмная и использует красный primary. Перед реализацией нативного экрана нужно уточнить у владельца Stitch, какая из тем является источником истины. В рамках этой инфраструктурной задачи экран не создавался.

## Проверка инструкций

Следующие записи — результаты прежних проверок навыков; их команды и правила автоматических прогонов заменены текущим контрактом выше. Описанные результаты прошлых запусков сохранены.

Навыки проверялись отдельными агентами в свежем контексте:

- `ios-testing`: агент выполнил полный `all` набор local/test; до исправления CLI точечный запуск с точным node ID ошибочно выполнял ноль тестов. Нормализация селектора исправлена с регрессионной проверкой; повтор выборочного unit-теста прошёл `1/1`. Python suite после исправления: `29` проверок пройдены.
- `ios-debugging`: агент использовал CLI на симуляторе в local/test; `1+1 → 2`, журнал показал `usb.command.completed` и `usb.command.acknowledged`. Устройство не запускалось.
- `ios-stitch-implementation`: свежий агент получил screen HTML и сверил CTA с theme/config; значения фона `#1D1D1F`, foreground `#FFFFFF`, radius `16px`, padding `16px/24px` совпали. Конфликт светлой screen theme с глобальной тёмной темой обнаружен и явно вынесен до native реализации.

## Финальный прогон

Следующий блок — исторический результат от 3 октября 2026 года. Команды и критерии приёмки, описанные в его bullets, отражают правила на дату запуска и заменены текущим контрактом выше; сами результаты сохранены без изменений.

3 октября 2026 года в симуляторе `0DDEE416-EECF-4BF3-8F15-BA93A980033A` выполнено:

- `python3 -m unittest discover -s scripts/tests` — 29/29 passed.
- Полный `all` в `local` — 43 Swift Testing + 10 UI = 53/53 passed; `/health` вернул HTTP 200.
- Полный `all` в `test` с `--skip-build` — 53/53 passed на той же сборке. Test API base URL ответил 404, что подтверждает HTTP-доступность сервиса и не является проверкой бизнесового API.
- Release-конфигурация успешно собрана для iOS Simulator без запуска приложения. `nm -gU` и `strings` не нашли символов/строк диагностического mailbox и debug UI в Release executable.

Result bundles: `.artifacts/runs/20261003-104914-1791013754755173000/Tests.xcresult` (local) и `.artifacts/runs/20261003-105157-1791013917820822000/Tests.xcresult` (test). Полный Release DerivedData, сборки и результаты запусков остаются в игнорируемом `.artifacts/`; они не входят в коммиты.
