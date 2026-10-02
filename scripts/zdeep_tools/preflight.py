from __future__ import annotations

import urllib.error
import urllib.request


class PreflightError(RuntimeError):
    pass


def _http_status(url: str, timeout: int = 5) -> int:
    request = urllib.request.Request(url, method="GET")
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.status
    except urllib.error.HTTPError as exc:
        return exc.code
    except (OSError, urllib.error.URLError) as exc:
        raise PreflightError(f"Сервис недоступен: {exc}") from exc


def check_local_health(api_base: str, request=_http_status) -> int:
    url = api_base.rstrip("/") + "/health"
    try:
        status = request(url, timeout=5)
    except Exception as exc:
        raise PreflightError(f"Локальный API не прошёл /health: {exc}") from exc
    if status != 200:
        raise PreflightError(f"Локальный API /health вернул HTTP {status}, ожидался 200")
    return status


def preflight(environment: str, suite: str = "integration", api_base: str | None = None, request=_http_status) -> str:
    if environment not in {"local", "test"}:
        raise PreflightError("Сетевой preflight разрешён только для local или test")
    if suite not in {"unit", "integration", "ui", "all"}:
        raise PreflightError(f"Неизвестный набор тестов: {suite}")
    if suite == "unit":
        return "unit: сетевые проверки не требуются"
    if not api_base:
        raise PreflightError("Не задан базовый адрес API")
    if environment == "local":
        check_local_health(api_base, request=request)
        return "local API /health: HTTP 200"
    if not api_base.startswith("https://"):
        raise PreflightError("Для test разрешён только HTTPS API")
    try:
        status = request(api_base, timeout=10)
    except Exception as exc:
        raise PreflightError(f"Тестовый API недоступен: {exc}") from exc
    if status >= 500:
        raise PreflightError(f"Тестовый API вернул HTTP {status}")
    return f"test API ответил HTTP {status}; бизнесовая готовность не проверяется"
