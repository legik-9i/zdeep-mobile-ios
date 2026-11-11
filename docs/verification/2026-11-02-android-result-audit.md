# Аудит итогового Android-порта

Проверка исходников и сохранённых отчётов 2026-11-02. Код не менялся, тесты заново не запускались. Область: runtime Kotlin, UI/bridge/session/storage/camera, Gradle и содержимое основных JVM/platform/localbackend тестов. Источники находятся в `/Users/oleg/projects/zdeep-mobile/android`; пути ниже относительно этой папки. Web-репозиторий не менялся. Все тесты побайтно не разобраны, mutation testing не выполнялся; поэтому утверждение «бесполезный» ограничено доказанным дублем или явно слабым assertion.

Уточнение пользователя после аудита: Back внутри сайта/модалов и Android-тема Stackflow полностью исключены из этой задачи. Они реализуются отдельно в веб-проекте. Их отсутствие не является незавершённостью native Android-порта.

## 1. Runtime: масштаб и лишняя сложность

28 Kotlin файлов, 3395 строк. Один app module; Compose, CameraX/ML Kit, OkHttp и AndroidX WebKit. Не обнаружены DI framework, универсальный SDK, многомодульная архитектура или альтернативный навигационный стек. Большие SessionManager/BindingStore в основном реализуют реальные требования iOS: один общий запрос, сохранение ключа до публикации JWT, отмену и crash-safe cleanup. Удалять эти гарантии под видом упрощения нельзя.

1. **Лишний альтернативный вход событий в ViewModel.** `AppViewModel.kt:212` принимает событие без явного request/session и сам достраивает происхождение; runtime `AppRoot.kt:133` всегда вызывает трёхаргументный вход. Одноаргументный путь используется тестами. `reportReady` также имеет необязательные source IDs, хотя runtime всегда их передаёт (`AppViewModel.kt:285`, `AppRoot.kt:131`). Минимальное упрощение: единый строгий runtime API, а короткие вызовы вынести в fixture тестов. Сейчас тесты поддерживают дополнительный production-контракт, которого у приложения нет.

2. **Мёртвые настройки и ветки.** `WebSession.kt:43–45`: appVersion, bridgeVersion, launchTheme сохраняются, но нигде в классе не читаются. URL реально строится в `AppViewModel.kt:330`. `refresh(current, webRetry)` вызывается только с false (`:304`, `:345`), `resetBinding(showWelcome)` — только с true (`:312`, `:317`, `:377`). Удалить неиспользуемые параметры и недостижимые альтернативы; оставить одного владельца launch URL.

3. **Лишний жизненный цикл scheduler.** `SessionClock.kt:74` создаёт executor на каждый clock; API его закрытия отсутствует. MainActivity создаёт clock при создании ViewModel, а onCleared отменяет handles, не executor (`AppViewModel.kt:505`). Повторные полноценные открытия Activity после уничтожения ViewModel могут оставлять idle threads. Плюс два дедлайна проверяются секундным polling. Нужен один понятный владелец scheduler; сам по себе контроль монотонного deadline полезен, удалять его вслепую нельзя.

## 2. Runtime: что не закончено / не доказано

4. **P1: гонка readiness timeout с UI.** Production clock выполняет action на executor (`SessionClock.kt:75–79`). `AppViewModel.kt:466` напрямую вызывает readinessTimeout, который читает и пишет поля ViewModel и экран (`:488–498`), одновременно изменяемые UI main thread. Конкретное допустимое чередование: timer проходит guards, main принимает reportReady либо запускает unlink, затем timer выставляет ERROR. Generation guard не делает проверку и запись атомарными. Статически подтверждена разная потоковая принадлежность; реальное проявление не воспроизводилось. Минимальный фикс: доставлять readiness callback на main до чтения/изменения полей, тестировать конфликт завершения с таймером. Текущие ReadinessTest используют виртуальное однопоточное время и это не доказывают.

5. **Тёмная launch theme не реализована.** `AppViewModel.kt:330` жёстко строит theme=light; AppRoot передаёт ещё один неиспользуемый light (`:129`). iOS обновляет launch theme из colorScheme (`/Users/oleg/projects/zdeep-mobile/ios/ZDEEP/ZDEEP/App/AppCoordinator.swift:117`). WebLaunchUrlTest проверяет сериализацию вручную переданного dark, не реальный выбор host. Нет зелёной проверки dark запуска/смены темы. Это отдельная проблема от Stackflow android/cupertino.

6. **Back и Android-тема Stackflow не реализованы в веб-слое.** NativeBridge отправляет back (`web/NativeBridge.kt:75`), AppRoot вызывает dispatchBack (`:111`), но согласованный web adapter/modal guards отложен по запрету пользователя. Модалы → stack pop → root no-op не имеют end-to-end зелёной проверки. По последующему уточнению пользователя это отдельная веб-задача, не функциональный остаток текущего native Android-порта.

7. **TLS PREPARING same-URL сценарий не зелёный.** `WebNavigationTest.kt:112` содержит Ignore. Production `WebSession.kt:287` при PREPARING и совпадении URL отменяет TLS и переводит документ в failure, не умея отличить same-URL subresource. TLS не обходится; ограничение — возможная лишняя ошибка всего экрана. Пропущенный тест нельзя считать PASS.

8. **Ошибки камеры при выданном разрешении не обработаны явно.** `camera/QrScanner.kt:37–57` подключает controller и analyzer, но не показывает отдельную ошибку/действие при недоступной камере; нет обработки camera state/error. Спека §4 требует системное ограничение камеры. Deny/settings тесты этот случай не покрывают. Возможный пользовательский результат — scanner без работающего preview; конкретное поведение на AVD/телефоне не воспроизводилось.

9. **Новые окна бизнес-WebView не подтверждены.** WebSession устанавливает onCreateWindow (`web/WebSession.kt:82`), но в нём нет setSupportMultipleWindows(true), который есть у About (`ui/AboutSheet.kt:101`). Platform WebNavigationTest не содержит настоящего target=_blank/window.open сценария для бизнес-WebView. Нужна проверка пользовательского клика и маршрутизации; один callback в коде не доказывает работу функции. Это проверяемый риск, а не воспроизведённый дефект.

10. **Production и testing пользовательская приёмка.** Release/R8/подпись не собирались по явному решению пользователя. Testing APK установлен и запускается, но login пользовательским QR не выполнялся. Это намеренно отложенные проверки. API 30/minSdk поддержка заявлена, исполнение проверялось только на API 36 по согласованной матрице.

## 3. Тесты: текущие результаты и полезность

Проверены фактические XML в `app/build/test-results/testLocalDebugUnitTest/` и `testQaDebugUnitTest/`: 99/99 в каждом, failures/errors/skipped=0. Между наборами 98 общих test case IDs, по одному уникальному BuildContract test. Это 100 уникальных JVM test IDs, не 198 разных сценариев.

Последний полный platform report `app/build/task11-reports/platform-api36-host/run-20261101T160103Z-97953/instrumentation.txt:550`: OK (37 tests); один известный TLS ignore отдельно, всего 38 discovered. Он предшествует последнему небольшому изменению unlink callback в AppRoot. После этого изменения есть focused AppLocalFlow и полный ordered process driver. Все 13 instrumentation-фаз `app/build/task10-reports/process-restart/run-20261101T172612Z-9698/` содержат OK; это подтверждает реальные pair/token, восстановление процесса, install-over, offline scope cleanup, renderer recovery, reinstall и свежий camera QR→business content. Предыдущие неуспешные прогоны не исчезают: зелёный сохранённый run не доказывает стабильность каждого следующего запуска.

11. **Точный дубль, удалить один.** `unit/SessionRefreshPolicyTest.kt:18` и `unit/SessionRefreshTest.kt:25` проверяют те же 780000, 5/10/20/30/30 и cap100. Достаточно policy-теста. Остальные SessionRefreshTest проверяют реальный manager и нужны.

12. **Повтор общего JVM suite для каждого окружения.** 98 одинаковых кейсов запускаются дважды при local+QA. Для обычного быстрого прохода достаточно общего набора один раз плюс BuildContract для обоих окружений. Это экономия запусков, не основание удалять хорошие тесты из исходников; при изменении flavor/config оба варианта остаются релевантными.

13. **Слабая проверка redirect может быть зелёной до самого перехода.** `platform/WebNavigationTest.kt:60–75`: после `harness.load("/foreign-redirect")` сразу проверяется текущий URL/список events. `WebSessionTestHarness.kt:61` лишь вызывает applyLoad, не ждёт server redirect. Если разрешить foreign redirect в runtime, эти проверки способны пройти до его обработки, затем finally закроет WebView. Исправить ожиданием наблюдаемой попытки/решения и проверкой foreign fixture requests; фиксированный Thread.sleep в первой половине также слабее наблюдаемого события.

14. **Keyboard Back проверяет тестовый host, не AppRoot.** `platform/SystemBackTest.kt:29–60` устанавливает собственный OnBackPressedCallback. Это полезная проверка Android IME и bridge, но удаление/поломка AppRoot keyboard branch не обязано её сломать. Нужна одна проверка на MainActivity с настоящим AppRoot; текущую нельзя выдавать за полную интеграцию keyboard-before-web-Back.

15. **Малоценный recreation smoke.** `platform/ActivityRecreationTest.kt:14` проверяет retained ViewModel/SessionManager на пустом native flow. Более содержательные InFlightActivityRecreationTest уже проверяют retention при pair/save, а ReadyActivityRecreationTest — реальный бизнесовый WebView. Первый smoke — кандидат на удаление после проверки, что раннее состояние отдельно не нужно; это не такой строгий дубль, как пункт 11.

16. **Тестовая инфраструктура тестирует сама себя.** `localbackend/LocalAppFlowSupportTest.kt` — восемь тестов deadline/poll/evaluate; `harness/WebSessionTestHarnessDeadlineTest.kt` и Python suites проверяют runners/эмулятор. Они не добавляют восемь продуктовых гарантий. Пока свой сложный harness существует, проверки ошибок и deadlines полезны: удалять их первыми нельзя. Сначала упрощать сам harness/driver и затем удалять освободившиеся тесты. Camera hash test и camera pairing не полные дубли: первый выявляет неправильный fixture, второй доказывает полный пользовательский вход.

Пример полезного overlap: JVM readiness/state-machine + настоящий bridge test + один локальный E2E проверяют разные границы; их совместное наличие оправдано. Race/save/signature/старый document tests нельзя выкидывать только из-за похожих названий.

## Итог

Runtime не требует новой архитектуры: есть локальный мусор и тестовые обходы в production API. Приоритет — закрыть реальную гонку таймера и уточнить функциональные остатки, затем узко убрать мёртвые параметры/ветки. Основная тестовая проблема — слишком тяжёлое исполнение и несколько проверок, обещающих больше, чем доказывают. Количественную экономию строк и времени без изменений и повторной проверки не оцениваем.
