from __future__ import annotations

import urllib.error
import urllib.request


class PreflightError(RuntimeError):
    pass


class _RejectRedirectHandler(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise PreflightError(f"Локальный preflight не принимает HTTP redirect: {code}")


def _http_status(url: str, timeout: int = 5) -> int:
    request = urllib.request.Request(url, method="GET")
    try:
        with urllib.request.build_opener(_RejectRedirectHandler()).open(request, timeout=timeout) as response:
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


def preflight(
    environment: str,
    suite: str = "integration",
    api_base: str | None = None,
    request=_http_status,
    *,
    web_url: str | None = None,
) -> str:
    if environment != "local":
        raise PreflightError("Сетевой preflight разрешён только для local")
    if suite not in {"unit", "integration", "ui", "all"}:
        raise PreflightError(f"Неизвестный набор тестов: {suite}")
    if suite == "unit":
        return "unit: сетевые проверки не требуются"
    if not api_base:
        raise PreflightError("Не задан базовый адрес API")
    if not web_url:
        raise PreflightError("Не задан адрес local Web")

    check_local_health(api_base, request=request)
    try:
        status = request(web_url, timeout=5)
    except Exception as exc:
        raise PreflightError(f"Локальный Web недоступен: {exc}") from exc
    if status != 200:
        raise PreflightError(f"Локальный Web вернул HTTP {status}, ожидался 200")
    return "local API /health and Web: HTTP 200"
