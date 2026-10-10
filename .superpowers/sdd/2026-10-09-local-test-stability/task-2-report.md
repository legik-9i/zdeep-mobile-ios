# Task 2 — строгий local readiness

## Изменения

- `preflight()` принимает `web_url` keyword-only, пропускает unit без адресов и запросов, а для сетевых наборов требует успешные HTTP 200 от API `/health` и настроенного local Web.
- API URL сохраняет base prefix. Штатный редирект проверяет финальный HTTP 200; смена origin при редиректе отклоняется.
- Удалена ветка проверки test API и принятия любого статуса ниже 500. `preflight` разрешает только `local`.
- CLI `preflight`, `test`, `simulator-launch` и local simulator `diagnose` передают configured Web URL. Testing диагностика по-прежнему не вызывает preflight.
- Добавлены проверки статусов 301/401/403/404/500 для API и Web, транспортных ошибок/тайм-аутов, unit без сети, redirect policy, передачу Web URL callers и запрет `BuildManager.run` при провале preflight.

## RED / GREEN

- RED: `python3 -m unittest scripts.tests.test_preflight scripts.tests.test_build` — 40 тестов; новые проверки падали из-за отсутствующего `web_url`, принятия внешнего редиректа и отсутствующего Web аргумента в CLI.
- GREEN: `python3 -m unittest scripts.tests.test_preflight scripts.tests.test_build` — 41 тест, OK.
- Все Python tests scripts: `python3 -m unittest discover -s scripts/tests` — 55 тестов, OK.
- Реальный local preflight: `python3 scripts/zdeep.py preflight --environment local --suite integration` — `local API /health and Web: HTTP 200`.
- `git diff --check` — без замечаний.

## Самопроверка

Просмотрены все вызовы `preflight()` в CLI и тестах. `test` передаёт Web только для сетевых наборов; unit ветка сохраняет отсутствие запросов. Local diagnostic callers передают configured Web, device testing diagnostics preflight не добавляют. Провал preflight в CLI завершается до создания/вызова `BuildManager.run`.

## Ограничения и риски

Xcode, iOS suites и полный local `all` не запускались по заданному ограничению этой задачи. Проверка redirect policy фиксирует допустимый redirect на том же origin; локальный live preflight завершился напрямую успешным HTTP 200.

## Fix round 1 — redirect до проверки origin

- Причина замечания подтверждена: RED `python3 -m unittest scripts.tests.test_preflight.PreflightTests.test_redirect_is_checked_before_requesting_destination` упал с `external_hits == ['/target']`; `urlopen()` успел отправить запрос за редиректом.
- Исправление: `_LocalRedirectHandler.redirect_request()` сверяет origin назначения с исходным до того, как urllib создаёт следующий запрос. Редирект в пределах origin проходит и возвращает финальный статус.
- GREEN: `python3 -m unittest scripts.tests.test_preflight scripts.tests.test_build` — 40 тестов, OK. Регрессия использует два loopback HTTP-сервера; внешний сервер не получает запрос, same-origin редирект завершён HTTP 200.
- `git diff --check` — без замечаний.
