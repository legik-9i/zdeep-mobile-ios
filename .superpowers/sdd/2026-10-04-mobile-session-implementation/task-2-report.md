# Task 2 — подписанный mobile auth client

## Результат

Реализованы `AuthClient`, транспорт на `URLSession`, модели ошибок/сессии, монотонные часы и валидация ответа сервера. Один вызов `pair` или `token` отправляет ровно один подписанный запрос; redirects запрещены. Запрос подписывается над точными байтами `timestamp|body`. Проверяется JWT-контекст пользователя, машины и audience, а срок сессии вычисляется с учётом серверного времени и полной длительности HTTP-запроса. Валидная коррекция часов применяется только к следующему вызову клиента.

Добавлены детерминированные unit fixtures/tests, локальный integration сценарий с реальным Keychain service, временным маркером и свежим токеном машины, а также `@Suite(.serialized)`. Runner подписывает только Simulator test builds для `unit`, `integration` и `all` в `local`; остальные сборки остаются без ad-hoc подписи. Fingerprint учитывает signing mode, selector integration suite сохранён.

## TDD

**RED:** до добавления production API запущен выбранный Simulator unit suite. Swift Testing собрал новый код тестов и завершился compile errors на отсутствующих `AuthClient`, `AuthFailure`, `SessionClock`, `CancellationHandle` и `AuthHTTPTransport`; это ожидаемое отсутствие реализации. В test fixture затем снята default MainActor isolation со статического namespace, чтобы сохранить заданную изоляцию тестового API.

**GREEN:** после реализации локальные unit и integration проверки прошли в перечисленном ниже объёме. Отдельный тест покрывает malformed и non-finite сроки, HTTP 401/403/429/503 и redirects, ошибки таймаута/инвалидации, точную подпись body и отсутствие внутреннего retry.

## Проверки

1. `python3 -m unittest scripts.tests.test_build` — **17/17 passed**. Проверены signing для `unit/local`, `integration/local`, `all/local`; отсутствие signing для `unit/test`, `integration/test`, `all/test` и обычной `build`; сохранение suite selector и инструкция для `--skip-build`.
2. `python3 scripts/zdeep.py test --environment local --suite unit --simulator 0DDEE416-EECF-4BF3-8F15-BA93A980033A` — **63 tests / 12 suites passed**. Результат: `.artifacts/runs/20261004-145509-1791114909637013000/Tests.xcresult`. Первый вызов в sandbox остановлен после ошибки доступа к `CoreSimulatorService`/`simdiskimaged`; повтор разрешённого запуска на том же Simulator завершился успешно.
3. `python3 scripts/zdeep.py test --environment local --suite integration --only 'WebSessionIntegrationTests/test_local_pair_then_token_accepts_spki_and_der_signature()' --simulator 0DDEE416-EECF-4BF3-8F15-BA93A980033A` — **1/1 passed**. Реальный local endpoint вернул `TIMESTAMP_OUT_OF_RANGE` на первый вызов при искусственном сдвиге часов на +10 минут; тест подтвердил один send и HTTP 401, затем сделал отдельный вызов `pair`, подтвердил единственный второй send, HTTP 200 и timestamp в допуске серверного времени, после чего прошли `completeRegistration` и `token`. Токены и HTTP body не записывались в вывод или этот отчёт.
4. Финальный полный `python3 scripts/zdeep.py test --environment local --suite integration --simulator 0DDEE416-EECF-4BF3-8F15-BA93A980033A` — **7/7 passed**. Результат: `.artifacts/runs/20261004-145629-1791114989969115000/Tests.xcresult`. Сюда входит ранее focused-проверка реального local pair/token и проверки WebView/reset. Известная ошибка `.pageChanged` не воспроизвелась.
5. В предыдущем полном integration запуске до deterministic clock-offset фикстуры прошло **6/7**: auth запрос получил HTTP 401 `TIMESTAMP_OUT_OF_RANGE`; этот ожидаемый серверный отказ локализован, затем сценарий отдельно подтвердил применение offset на следующем явном вызове и в финальном полном запуске все 7 тестов прошли.
6. `git diff --check` — passed.

Unit suite не требует доступности API. Для integration используется только local endpoint согласно `docs/development/local-auth-test-data.md`, с новым carToken на тестовый сценарий. Simulator UDID во всех iOS проверках: `0DDEE416-EECF-4BF3-8F15-BA93A980033A`.

## Замечания

- Первый sandboxed unit build не мог подключиться к CoreSimulator; повтор с разрешённым доступом прошёл.
- Изменений project settings не делалось. Для локального real-Keychain simulator run signing задаётся только runner-ом по suite/environment.

## Review fix — безопасные числовые границы и отмена queued request

Sol review выявил потенциальные traps при преобразовании конечных, но слишком больших `Double` в `Int64`, и гонку, когда уже отменённый network task всё равно вызывал `transport.send`.

**TDD RED:**

- Тест timestamp `Double(Int64.max)` (равен `2^63`) воспроизвёл Swift fatal error: `Double value cannot be converted to Int64 because the result would be greater than Int64.max`.
- Регрессия queued launch дождалась обработки запуска после отмены и показала один нежелательный `POST /auth/mobile/pair` вместо нуля отправок; вызвавшая сторона уже получила `CancellationError`.
- Отдельные fixtures для очень больших конечных `exp` и `expiresIn` сначала прошли валидацию вместо `invalidResponse/BAD_RESPONSE` (два ожидаемых assertion failures).

**Изменения:**

- Перед обеими конверсиями `Double → Int64` добавлена проверка конечности, нижней границы и строгой верхней границы `< Double(Int64.max)`. Timestamp `2^63` теперь отвергается как `BAD_RESPONSE` до подписи/отправки.
- `exp` и `serverTime + expiresIn` должны находиться в диапазоне четырёхзначного ISO 8601 года. Формирование даты и RFC3339 строки проверяется на поддерживаемый диапазон; остаток срока проходит проверку `Int64` перед созданием `Duration`. Непредставимые значения возвращают `BAD_RESPONSE` без traps.
- До `transport.send` queued closure проверяет собственную cancellation, идентификатор активной попытки и монотонный deadline. `URLSessionAuthHTTPTransport` проверяет cancellation до создания task и внутри него до `session.data`.
- Тесты проверяют queued cancellation (ровно `CancellationError`, ноль отправок), уже отменённого caller в URLSession adapter, timestamp `2^63`, а также раздельно огромный конечный JWT `exp` и `expiresIn`.

**GREEN и финальная проверка:**

- Focused unit: queued cancellation — **1/1 passed** (`20261004-150834-1791115714062412000`); cancelled URLSession caller — **1/1 passed** (`20261004-150847-1791115727948457000`); большие сроки — **1/1 passed** (`20261004-151110-1791115870335276000`); timestamp `2^63` — **1/1 passed** (`20261004-150913-1791115753382820000`).
- `python3 scripts/zdeep.py test --environment local --suite unit --simulator 0DDEE416-EECF-4BF3-8F15-BA93A980033A` — **66/66 passed, 12 suites**; `.artifacts/runs/20261004-151123-1791115883315442000/Tests.xcresult`.
- `python3 scripts/zdeep.py test --environment local --suite integration --simulator 0DDEE416-EECF-4BF3-8F15-BA93A980033A` — **7/7 passed**; `.artifacts/runs/20261004-151149-1791115909895780000/Tests.xcresult`. Использовались только local endpoints; токены и тела запросов не выводились.
- `git diff --check` — passed.
