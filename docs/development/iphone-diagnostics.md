# Диагностика WebView по кабелю

## Подготовка

Команды запускаются из корня репозитория. Для сборки на физическое устройство Xcode использует уже настроенную подпись пользователя; скрипт не меняет signing team и provisioning profile.

Настройте ID в `.local/development.json` либо передавайте его аргументом:

```json
{
  "simulator": "0DDEE416-EECF-4BF3-8F15-BA93A980033A",
  "device": "00008101-001A25963AC2001E"
}
```

Симулятор запускается с `local` по умолчанию. Перед локальной диагностикой CLI проверяет `http://localhost:4002/health` и требует HTTP 200; веб локального приложения доступен по `http://localhost:4005`. Test окружение использует `https://5e9afe68-2ddd-4e58-8e57-5942cfa16099.website.twcstorage.ru` и `https://api.zdeep.ru/testing/`. Физическое устройство принимает только `test`.

## Установка и запуск iPhone

```sh
python3 scripts/zdeep.py device-install --device 00008101-001A25963AC2001E
python3 scripts/zdeep.py device-launch --environment test --device 00008101-001A25963AC2001E
```

`device-launch` включает reader переменной `ZDEEP_USB_DIAGNOSTICS=1`. Reader создаётся только в Debug-сборке и только при окружении `test`. После старта откройте приложение и вручную нажмите «Открыть WebView». Выбор контура или старт приложения сам WebView не загружает.

Reader живёт в `AppCoordinator` вместе с активной `WebSession`. При закрытии WebView он останавливается. В mailbox передаются только команды UUID для текущего session ID и с неистёкшим deadline. Handshake `session.json` сообщает session ID и очищенный URL страницы без userinfo, query и fragment. JavaScript source, результат и текст ошибки не добавляются в `DiagnosticEventStore`.

## Диагностические команды

Обычный `simulator-launch` включает mailbox, но оставляет начальный экран приложения без открытой WebView:

```sh
python3 scripts/zdeep.py simulator-launch --environment local --simulator 0DDEE416-EECF-4BF3-8F15-BA93A980033A
```

Команда `diagnose --target simulator` является явным действием диагностики. Если в приложении нет свежей handshake-записи для выбранного окружения, CLI запускает Debug-приложение с отдельным флагом `--usb-diagnostics-open-webview`; этот флаг работает только в DEBUG-сборке симулятора и только для `local`/`test`. При наличии активной сессии CLI использует её. Обычный запуск приложения и `device-launch` не открывают WebView автоматически. На физическом iPhone WebView по-прежнему нужно открыть вручную.

Примеры последовательных команд на симуляторе:

```sh
python3 scripts/zdeep.py diagnose --target simulator --environment local --js-file .artifacts/diagnostic.js --timeout 30
python3 scripts/zdeep.py diagnose --target simulator --environment test --js-file .artifacts/diagnostic.js --timeout 30
```

Для телефона замените target и ID; сначала выполните `device-launch`, затем вручную откройте WebView:

```sh
python3 scripts/zdeep.py diagnose --target device --device 00008101-001A25963AC2001E --environment test --js-file .artifacts/diagnostic.js --timeout 30
python3 scripts/zdeep.py logs --target device --device 00008101-001A25963AC2001E
```

Для команд выше заранее положите исходный текст в файл `.artifacts/diagnostic.js` с помощью редактора. Либо запустите команду с `--js-stdin` и вставьте JS после запуска программы; завершите ввод EOF (`Ctrl-D`). Эти варианты не помещают исходный текст в командную строку процесса или shell history. Удобный флаг `--js '...'` передаёт исходный текст в argv и может сохранить его shell history или показать в списке процессов, поэтому используйте его только для коротких несекретных выражений. При работе CLI сериализует JS во временный локальный `.artifacts/diagnostics-tmp/` исключительно для файловой передачи; результат выводится в терминал по прямому запросу. Не включайте секреты в вывод JS: результат произвольного кода может содержать любые данные страницы.

`logs` копирует фильтрованный JSONL журнал событий из app data container. Он не включает историю команд и их JS-ответы.

## Обмен файлами и очистка

Папка приложения — `Library/Caches/ZdeepDiagnostics/` в app data container. CLI сначала копирует тело `<uuid>.uploading`, затем отдельный `<uuid>.ready` marker. Reader обрабатывает только команду с marker, проверяет UUID, активную сессию и deadline, исполняет код через `WebSession.executeJavaScript`, после чего атомарно публикует JSON-ответ в `outbox/<uuid>.json`.

CLI проверяет, что handshake содержит корректный UUID сессии, ожидаемое окружение и недавно обновлённое время; без свежего handshake запрос не публикуется. После копирования ответа CLI проверяет JSON и session ID, затем публикует двухфазный acknowledgement. Reader удаляет файлы только если существуют ответ и соответствующее содержимое acknowledgement. UUID уже принятых команд сохраняются до закрытия WebSession, поэтому повторная публикация в той же сессии отвергается. Недоставленный или не скопированный ответ остаётся доступен для повторного `copy from`; истёкшая/отклонённая команда не запускает JS. Команда ожидания ограничена 300 секундами.

Симулятор использует прямые файлы контейнера из `simctl get_app_container`. Физический iPhone использует `devicectl device copy` с доменом `appDataContainer`; скрипт не подключается к веб-серверу для доставки mailbox. iOS может приостановить приложение в фоне, поэтому оставляйте приложение на переднем плане и WebView открытым до ответа. Фоновый режим не запрашивается.

Если устройство недоступно или приложение не видит активную WebView-сессию, команда завершается ошибкой или тайм-аутом. Для iPhone откройте WebView вручную и повторите команду. Номер UDID передаётся всем операциям устройства явно или берётся из `.local/development.json`.
