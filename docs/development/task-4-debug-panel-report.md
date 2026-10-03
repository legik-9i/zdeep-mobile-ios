# Задача 4: Debug-панель и сохраняемая диагностика

## Изменения

- Добавлен ограниченный JSONL-журнал с ротацией старейших записей, экспортом снимка и фильтрацией секретных полей, bearer/JWT значений и секретных query-параметров URL.
- Добавлены перемещаемая кнопка Debug и нативная панель с выбором контура, состоянием WebView, reload, сбросом клиентских данных и явным выполнением JavaScript. Результат произвольного JS показывается в панели и автоматически не сохраняется.
- Полный сброс закрывает текущую сессию, очищает `WKWebsiteDataStore.default()` и persistent domain настроек приложения. Переход `test` ↔ `prod` сохраняет данные; переход через границу базы вызывает существующий сброс.
- В Release кнопка, панель, выбор контура и исполнитель JS исключены условной компиляцией. Release-конфигурация выбирает `prod`; WebView всё ещё открывается только явным действием.
- Добавлены unit, UI и hosted integration проверки, включая cookie/localStorage до и после сброса.

## Проверки

Симулятор: `0DDEE416-EECF-4BF3-8F15-BA93A980033A`.

```sh
python3 scripts/zdeep.py test --environment local --suite unit --only 'DiagnosticEventStoreTests/test_secrets_are_removed_from_fields_and_urls()' --simulator 0DDEE416-EECF-4BF3-8F15-BA93A980033A
python3 scripts/zdeep.py test --environment local --suite ui --only DebugPanelUITests/test_debug_panel_remains_available_while_loading_and_after_navigation_error --simulator 0DDEE416-EECF-4BF3-8F15-BA93A980033A
python3 scripts/zdeep.py test --environment local --suite all --simulator 0DDEE416-EECF-4BF3-8F15-BA93A980033A
python3 scripts/zdeep.py test --environment test --suite all --simulator 0DDEE416-EECF-4BF3-8F15-BA93A980033A
xcodebuild -project ZDEEP/ZDEEP.xcodeproj -scheme ZDEEP -configuration Release -destination 'generic/platform=iOS Simulator' -derivedDataPath .artifacts/release-audit CODE_SIGNING_ALLOWED=NO build
nm -a .artifacts/release-audit/Build/Products/Release-iphonesimulator/ZDEEP.app/ZDEEP | rg 'DebugOverlay|DebugPanel|DiagnosticExecutor|executeJavaScript|waitForNavigation|isShowingDebugPanel'
strings .artifacts/release-audit/Build/Products/Release-iphonesimulator/ZDEEP.app/ZDEEP | rg 'debug-button|environment-picker|reload-webview|reset-client-data|js-input|execute-js|js-result|DebugPanel|DebugOverlay|DiagnosticExecutor|isShowingDebugPanel'
```

- Sanitizer test: 1 из 1 пройден.
- Scoped UI error/loading test: пройден.
- `suite all` / `local`: 33 Swift Testing + 6 UI tests (39 всего), пройден; `http://localhost:4002/health` вернул HTTP 200.
- `suite all` / `test`: 33 Swift Testing + 6 UI tests (39 всего), пройден; разрешённый test API ответил HTTP 404, что принимается как доступный сервис.
- Release build: `BUILD SUCCEEDED`. Оба поиска символов и строк не нашли debug-панель, кнопку, переключатель, JS-кнопки или исполнитель.
- Release-приложение не запускалось; запросов к prod не выполнялось.
