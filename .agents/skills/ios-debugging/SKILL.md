---
name: ios-debugging
description: Use when diagnosing a ZDEEP iPhone or simulator WebView, USB mailbox timeout, missing JavaScript response, or app diagnostic log.
---

# Отладка ZDEEP iOS и WebView

Применяй этот skill, когда нужно получить фильтрованный журнал приложения, выполнить JavaScript в активном WebView или разобраться с тайм-аутом USB mailbox. Подробности протокола и установки находятся в [iphone-diagnostics.md](../../../docs/development/iphone-diagnostics.md).

## Ограничения контуров

- Физический iPhone диагностируй только в `test`. Всегда передавай `--environment test`: CLI по умолчанию выбирает `local`, и команда на устройстве с этим значением будет отклонена.
- Симулятор разрешено использовать в `local` и `test`. Для Local сначала проверь API `http://localhost:4002/health` → HTTP 200.
- Не открывай WebView в `prod`, не отправляй запросы к продовым адресам.
- Оставь приложение на переднем плане и WebView открытым, пока выполняется команда. Фоновый режим не включён.

## Сначала собери журнал

Проверь UDID iPhone в `.local/development.json` или укажи его явно. Перед повтором диагностики скопируй отфильтрованный журнал приложения:

```sh
python3 scripts/zdeep.py logs --target device --device <DEVICE_UDID>
```

На симуляторе используй `--target simulator --simulator <SIMULATOR_UDID>`. Команда возвращает записи `DiagnosticEventStore` из app data container. Это не полный системный журнал iOS и не console output. Журнал содержит timestamp, категорию и operation ID; он не сохраняет произвольный JS, результат или payload ошибки выполнения JS. Другие события приложения могут содержать отфильтрованные сообщения об ошибках.

Для USB mailbox смотри на категории:

- `usb.mailbox.start.failed` — reader не запустился;
- `usb.command.rejected` — reader получил, но отклонил запрос (например, из-за неактуальной сессии, UUID или deadline);
- `usb.command.completed` — JS исполнен успешно;
- `usb.command.failed` — JS завершился ошибкой;
- `usb.command.acknowledged` — ответ был скопирован Mac и mailbox очищен.

Если CLI вернул JSON-ответ, сверяй его `id` с `operationID` в журнале. При тайм-ауте CLI не печатает UUID запроса; сопоставляй записи по времени и категории, не придумывай ID. Если после свежего запроса нет события `usb.command.*`, приложение, вероятно, не читает mailbox или нужная WebView-сессия не активна; сам журнал не доказывает состояние файлового handshake.

## Выполни безопасную JS-проверку

Передавай исходник через файл или stdin, чтобы не класть его в argv процесса. Для физического iPhone используй только `test`:

```sh
python3 scripts/zdeep.py diagnose \
  --target device \
  --device <DEVICE_UDID> \
  --environment test \
  --js-file .artifacts/diagnostic.js \
  --timeout 45
```

Для короткой проверки без подготовки файла:

```sh
printf '1+1\n' | python3 scripts/zdeep.py diagnose \
  --target device \
  --device <DEVICE_UDID> \
  --environment test \
  --js-stdin \
  --timeout 45
```

Ожидаемый ответ — `2`. Чтобы проверить ошибки WebKit, читай структурированный результат команды и категорию события, а не ищи JS-текст в журнале. Не выводи секреты из страницы: произвольный JS может вернуть любые доступные ей данные.

На симуляторе выбирай `--target simulator`, `--simulator <SIMULATOR_UDID>` и явно `--environment local` или `test`. `diagnose` — явное действие: если свежей сессии ещё нет, команда может открыть WebView на симуляторе. На физическом телефоне сначала вручную открой WebView.

## Разбери тайм-аут

1. Прочитай `logs` и проверь последние записи по времени и категориям. При тайм-ауте CLI не выводит UUID запроса, поэтому не пытайся сопоставить неизвестный ID.
2. Убедись, что iPhone разблокирован, приложение на переднем плане, а тестовая WebView-сессия открыта.
3. Если reader не был включён при старте или приложение перезапускалось, `device-launch --environment test` включает его в Debug-сборке. Эта команда завершает работающий процесс (`--terminate-existing`); после запуска нужно вручную нажать «Открыть WebView» и дождаться тестовой страницы.
4. Повтори JS-команду только после открытия новой сессии `test`. Не используй `device-launch`, если активная сессия уже работает с reader: перезапуск уничтожит её.

Для получения JS-канала после нового запуска команда должна была включить `ZDEEP_USB_DIAGNOSTICS=1`. Сам факт, что WebView видна на экране, не подтверждает, что активный процесс запущен с reader. Если устройство заблокировано или SpringBoard отвечает `Locked`, сначала попроси владельца разблокировать телефон; не повторяй launch вслепую.

## Известная граница

На iPhone ранее прошли `1+1`, JS exception и DOM event в Test при включённом Wi-Fi. При выключенном Wi-Fi подтверждена проводная передача файлов через CoreDevice, но исполнение JS не подтверждено: видимое приложение работало без opt-in reader, а повторный `device-launch` был отклонён SpringBoard как `Locked`. Поэтому не делай вывод, что полный JS mailbox работает без Wi-Fi. Текущий протокол можно использовать на симуляторе local/test; актуальные факты и ограничения сверяй с [экспериментальным отчётом](../../../experiments/usb-diagnostics/README.md).
