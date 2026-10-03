# Проверка инфраструктуры разработки

Этот документ фиксирует принятый рабочий процесс и подтверждения для инфраструктурных задач 1–6. Он не является релизной инструкцией. Контур `prod` не используется интеграционными тестами.

## Тесты

Из корня репозитория получи доступный UDID симулятора:

```sh
xcrun simctl list devices available
```

Первый полный прогон собирает тестовые targets и проверяет local; последующий использует ту же сборку в test:

```sh
python3 scripts/zdeep.py test --environment local --suite all --simulator <SIMULATOR_UDID>
python3 scripts/zdeep.py test --environment test --suite all --simulator <SIMULATOR_UDID> --skip-build
```

Выборочный повтор использует точный `nodeIdentifier` из `.xcresult` и не собирает повторно при неизменном fingerprint:

```sh
python3 scripts/zdeep.py test --environment local --suite unit --only 'EnvironmentTests/test_testing_api_path_is_preserved()' --simulator <SIMULATOR_UDID> --skip-build
```

Для local preflight требует `GET http://localhost:4002/health` → 200; WebView открывает `http://localhost:4005`. Test использует сайт `https://5e9afe68-2ddd-4e58-8e57-5942cfa16099.website.twcstorage.ru` и API base `https://api.zdeep.ru/testing/`. HTTP 404 на базовом API URL означает, что HTTPS-сервис ответил, но не проверяет бизнесовый метод. CLI для сетевых тестов принимает только `local` и `test`. `prod` разрешено выбирать на начальном экране для проверки констант, но prod-сайт не открывается.

## Отладка WebView

На симуляторе допустимы `local` и `test`. На физическом iPhone используй исключительно `test`; приложение и WebView должны оставаться открытыми на переднем плане:

```sh
python3 scripts/zdeep.py device-launch --environment test --device <DEVICE_UDID>
python3 scripts/zdeep.py logs --target device --device <DEVICE_UDID>
python3 scripts/zdeep.py diagnose --target device --device <DEVICE_UDID> --environment test --js-stdin --timeout 45
```

Для последней команды передай JavaScript в stdin и заверши ввод EOF. Сначала запусти `device-launch`, затем вручную открой тестовую WebView. Инструкция не предполагает автоматического открытия WebView на iPhone. `logs` копирует фильтрованный журнал приложения, не весь системный лог и не текст/результат JS. При запуске UI с reader через `device-launch` команда завершает текущий процесс.

Физическая приёмка текущего этапа пользователем принята. Ранее при включённом Wi-Fi на iPhone в test успешно проверены `1+1 → 2`, ошибка JavaScript и DOM event. При выключенном Wi-Fi подтверждена проводная передача файлов CoreDevice; исполнение JS по этому пути осталось неподтверждённым. Один последующий запуск вернул SpringBoard `Locked`. Дополнительные действия с телефоном не выполнялись по решению пользователя считать текущую физическую проверку достаточной.

Подробности транспорта и команд: [iphone-diagnostics.md](iphone-diagnostics.md). Известные ограничения эксперимента: [отчёт USB diagnostics](../../experiments/usb-diagnostics/README.md).

## Stitch → SwiftUI

Для Stitch проекта ZDEEP (`1417382377358815087`) навыку `ios-stitch-implementation` требуется `stitch-design-pipeline`; актуальные HTML и theme/config конкретного экрана задают значения для реализации. Не преобразуй каждый Tailwind-класс в отдельный SwiftUI modifier: извлекай вычисленные значения в общие native tokens/styles и сравнивай результат со скриншотом при сопоставимом viewport.

У Welcome screen `bc93291bf18e4d78b737a9a035b30434` HTML указывает на светлую тему `Bento Grids`, а глобальная тема проекта `Autonomous Kinetic` сейчас тёмная и использует красный primary. Перед реализацией нативного экрана нужно уточнить у владельца Stitch, какая из тем является источником истины. В рамках этой инфраструктурной задачи экран не создавался.

## Проверка инструкций

Навыки проверялись отдельными агентами в свежем контексте:

- `ios-testing`: агент выполнил полный `all` набор local/test; до исправления CLI точечный запуск с точным node ID ошибочно выполнял ноль тестов. Нормализация селектора исправлена с регрессионной проверкой; повтор выборочного unit-теста прошёл `1/1`. Python suite после исправления: `29` проверок пройдены.
- `ios-debugging`: агент использовал CLI на симуляторе в local/test; `1+1 → 2`, журнал показал `usb.command.completed` и `usb.command.acknowledged`. Устройство не запускалось.
- `ios-stitch-implementation`: свежий агент получил screen HTML и сверил CTA с theme/config; значения фона `#1D1D1F`, foreground `#FFFFFF`, radius `16px`, padding `16px/24px` совпали. Конфликт светлой screen theme с глобальной тёмной темой обнаружен и явно вынесен до native реализации.

## Финальный прогон

3 октября 2026 года в симуляторе `0DDEE416-EECF-4BF3-8F15-BA93A980033A` выполнено:

- `python3 -m unittest discover -s scripts/tests` — 29/29 passed.
- Полный `all` в `local` — 43 Swift Testing + 10 UI = 53/53 passed; `/health` вернул HTTP 200.
- Полный `all` в `test` с `--skip-build` — 53/53 passed на той же сборке. Test API base URL ответил 404, что подтверждает HTTP-доступность сервиса и не является проверкой бизнесового API.
- Release-конфигурация успешно собрана для iOS Simulator без запуска приложения. `nm -gU` и `strings` не нашли символов/строк диагностического mailbox и debug UI в Release executable.

Result bundles: `.artifacts/runs/20261003-104914-1791013754755173000/Tests.xcresult` (local) и `.artifacts/runs/20261003-105157-1791013917820822000/Tests.xcresult` (test). Полный Release DerivedData, сборки и результаты запусков остаются в игнорируемом `.artifacts/`; они не входят в коммиты.
