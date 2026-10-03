"""File mailbox commands for the explicitly opted-in Debug build."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
import time
import uuid
from pathlib import Path
from typing import Callable, TextIO


BUNDLE_ID = "ru.zdeep.mobile"
MAILBOX = "Library/Caches/ZdeepDiagnostics"


class DiagnosticError(RuntimeError):
    pass


def load_javascript(inline: str | None = None, source_file: Path | None = None, source_stream: TextIO | None = None) -> str:
    provided = sum(value is not None for value in (inline, source_file, source_stream))
    if provided != 1:
        raise DiagnosticError("Укажите ровно один источник JavaScript: --js, --js-file или --js-stdin")
    try:
        if inline is not None:
            javascript = inline
        elif source_file is not None:
            javascript = Path(source_file).read_text(encoding="utf-8")
        else:
            javascript = source_stream.read()
    except (OSError, UnicodeError) as exc:
        raise DiagnosticError(f"Не удалось прочитать JavaScript: {exc}") from exc
    if not javascript.strip():
        raise DiagnosticError("JS-команда не может быть пустой")
    if len(javascript.encode("utf-8")) > 128_000:
        raise DiagnosticError("JS-команда превышает предел 128 KB")
    return javascript


def decode_response(data: bytes, expected_session_id: str | None = None) -> dict:
    try:
        value = json.loads(data)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise DiagnosticError(f"Получен некорректный JSON ответа: {exc}") from exc
    if not isinstance(value, dict):
        raise DiagnosticError("Ответ диагностики должен быть JSON-объектом")
    required = {"id", "sessionId", "ok"}
    if not required.issubset(value) or not isinstance(value["ok"], bool):
        raise DiagnosticError("Ответ диагностики не содержит обязательные поля")
    try:
        uuid.UUID(value["id"])
    except (ValueError, TypeError, AttributeError) as exc:
        raise DiagnosticError("UUID ответа некорректен") from exc
    if expected_session_id is not None and value["sessionId"] != expected_session_id:
        raise DiagnosticError("Получен ответ от устаревшей WebView-сессии")
    if value["ok"] and "result" not in value:
        raise DiagnosticError("В успешном ответе отсутствует result")
    if not value["ok"] and not isinstance(value.get("error"), dict):
        raise DiagnosticError("В ответе с ошибкой отсутствует error")
    return value


class DiagnosticManager:
    def __init__(
        self,
        root: Path,
        runner: Callable = subprocess.run,
        poll_interval: float = 0.2,
        monotonic: Callable = time.monotonic,
        sleep: Callable = time.sleep,
    ):
        self.root = Path(root).resolve()
        self.runner = runner
        self.poll_interval = poll_interval
        self.monotonic = monotonic
        self.sleep = sleep
        self.temp_dir = self.root / ".artifacts" / "diagnostics-tmp"

    @staticmethod
    def validate_request_id(request_id: str, seen_ids: set[str]) -> str:
        try:
            normalized = str(uuid.UUID(request_id))
        except (ValueError, AttributeError) as exc:
            raise DiagnosticError("Нужен корректный UUID команды") from exc
        if normalized in seen_ids:
            raise DiagnosticError(f"UUID команды уже использован: {normalized}")
        return normalized

    @staticmethod
    def is_fresh_session_status(value: object, environment: str, *, now: float | None = None, max_age_seconds: float = 10) -> bool:
        if not isinstance(value, dict):
            return False
        if value.get("ready") is not True or value.get("environment") != environment:
            return False
        try:
            session_id = value.get("sessionId")
            if not isinstance(session_id, str) or str(uuid.UUID(session_id)) != session_id.lower():
                return False
            updated_at = value.get("updatedAt")
            if isinstance(updated_at, bool) or not isinstance(updated_at, (int, float)):
                return False
            age = (time.time() if now is None else now) - float(updated_at)
            return -30 <= age <= max_age_seconds
        except (ValueError, TypeError, AttributeError):
            return False

    def _run(self, command: list[str], *, timeout: float = 60) -> subprocess.CompletedProcess:
        try:
            result = self.runner(command, cwd=self.root, check=False, capture_output=True, text=True, timeout=timeout)
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise DiagnosticError(f"Устройство недоступно или команда не завершилась: {exc}") from exc
        if result.returncode != 0:
            detail = (result.stderr or result.stdout or "").strip()
            raise DiagnosticError(f"Команда устройства завершилась с кодом {result.returncode}: {detail}")
        return result

    def _app_path(self, target: str, target_id: str) -> Path:
        if target == "simulator":
            result = self._run(["xcrun", "simctl", "get_app_container", target_id, BUNDLE_ID, "data"])
            path = Path(result.stdout.strip())
            if not result.stdout.strip() or not path.is_dir():
                raise DiagnosticError(f"Не удалось определить app data container симулятора {target_id}")
            return path
        raise DiagnosticError("Для устройства путь доступен только через devicectl copy")

    def _copy_to(self, target: str, target_id: str, local: Path, remote: str) -> None:
        if target == "simulator":
            destination = self._app_path(target, target_id) / remote
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(local, destination)
            return
        self._run([
            "xcrun", "devicectl", "device", "copy", "to", "--device", target_id,
            "--source", str(local), "--destination", remote,
            "--domain-type", "appDataContainer", "--domain-identifier", BUNDLE_ID,
        ])

    def _copy_from(self, target: str, target_id: str, remote: str, local: Path) -> bool:
        if target == "simulator":
            source = self._app_path(target, target_id) / remote
            if not source.is_file():
                return False
            shutil.copyfile(source, local)
            return True
        try:
            self._run([
                "xcrun", "devicectl", "device", "copy", "from", "--device", target_id,
                "--source", remote, "--destination", str(local),
                "--domain-type", "appDataContainer", "--domain-identifier", BUNDLE_ID,
            ], timeout=15)
            return local.is_file()
        except DiagnosticError as exc:
            if "file node" in str(exc).lower() or "no such file" in str(exc).lower():
                return False
            raise

    def _simulator_has_active_session(self, target_id: str, environment: str) -> bool:
        try:
            status_path = self._app_path("simulator", target_id) / MAILBOX / "session.json"
            status = json.loads(status_path.read_text(encoding="utf-8"))
            return (
                self.is_fresh_session_status(status, environment, max_age_seconds=3)
            )
        except (DiagnosticError, OSError, ValueError, TypeError, json.JSONDecodeError):
            return False

    def _ensure_simulator_diagnostic_session(self, target_id: str, environment: str, web_url: str, api_url: str) -> None:
        if not self._simulator_has_active_session(target_id, environment):
            self.simulator_launch(target_id, environment, web_url, api_url, open_webview=True)

    def _wait_for_session(self, target: str, target_id: str, timeout: float, environment: str = "test") -> dict:
        deadline = self.monotonic() + timeout
        self.temp_dir.mkdir(parents=True, exist_ok=True)
        status = self.temp_dir / f"session-{uuid.uuid4()}.json"
        try:
            while self.monotonic() < deadline:
                try:
                    if self._copy_from(target, target_id, f"{MAILBOX}/session.json", status):
                        value = json.loads(status.read_text(encoding="utf-8"))
                        max_age = 10 if target == "device" else 3
                        if self.is_fresh_session_status(value, environment, max_age_seconds=max_age):
                            return value
                except (OSError, json.JSONDecodeError):
                    pass
                self.sleep(self.poll_interval)
            raise DiagnosticError("Тайм-аут ожидания активной WebView-сессии")
        finally:
            status.unlink(missing_ok=True)

    def _read_response(self, target: str, target_id: str, request_id: str, session_id: str, timeout: float) -> dict:
        deadline = self.monotonic() + timeout
        response = self.temp_dir / f"response-{request_id}.json"
        try:
            while self.monotonic() < deadline:
                if self._copy_from(target, target_id, f"{MAILBOX}/outbox/{request_id}.json", response):
                    try:
                        value = decode_response(response.read_bytes(), expected_session_id=session_id)
                        if value["id"] != request_id:
                            raise DiagnosticError("UUID ответа не совпадает с отправленной командой")
                    except DiagnosticError:
                        # The bytes are safely copied locally; acknowledge even a bad/stale response so
                        # the device does not retain an unreadable outbox entry forever.
                        try:
                            self._publish_ack(target, target_id, request_id)
                        except DiagnosticError:
                            pass
                        raise
                    return value
                self.sleep(self.poll_interval)
            raise DiagnosticError("Тайм-аут ожидания ответа диагностики")
        finally:
            response.unlink(missing_ok=True)

    def _publish_ack(self, target: str, target_id: str, request_id: str) -> None:
        self.temp_dir.mkdir(parents=True, exist_ok=True)
        payload = self.temp_dir / f"ack-{request_id}.uploading"
        ready = self.temp_dir / f"ack-{request_id}.ready"
        payload.write_text(request_id, encoding="utf-8")
        ready.write_bytes(b"")
        try:
            self._copy_to(target, target_id, payload, f"{MAILBOX}/inbox/{request_id}.ack.uploading")
            self._copy_to(target, target_id, ready, f"{MAILBOX}/inbox/{request_id}.ack.ready")
        finally:
            payload.unlink(missing_ok=True)
            ready.unlink(missing_ok=True)

    def diagnose(self, target: str, target_id: str, javascript: str, timeout: float = 30, *, environment: str = "test", web_url: str = "", api_url: str = "") -> dict:
        if target not in {"simulator", "device"}:
            raise DiagnosticError("Цель должна быть simulator или device")
        if not target_id:
            raise DiagnosticError("Укажите simulator/device ID")
        if not javascript.strip():
            raise DiagnosticError("JS-команда не может быть пустой")
        if timeout <= 0 or timeout > 300:
            raise DiagnosticError("Тайм-аут должен быть больше 0 и не более 300 секунд")
        if environment not in ({"local", "test"} if target == "simulator" else {"test"}):
            raise DiagnosticError("USB mailbox разрешён только для test на устройстве и local/test на симуляторе")

        if target == "simulator":
            if not web_url or not api_url:
                raise DiagnosticError("Для диагностики симулятора нужны web/api URL")
            self._ensure_simulator_diagnostic_session(target_id, environment, web_url, api_url)

        self.temp_dir.mkdir(parents=True, exist_ok=True)
        request_id = str(uuid.uuid4())
        seen: set[str] = set()
        request_id = self.validate_request_id(request_id, seen)
        request_file = self.temp_dir / f"request-{request_id}.json"
        ready_file = self.temp_dir / f"request-{request_id}.ready"
        operation_deadline = self.monotonic() + timeout
        session = self._wait_for_session(target, target_id, timeout, environment)
        remaining = max(0.001, operation_deadline - self.monotonic())
        payload = {
            "protocolVersion": 1,
            "id": request_id,
            "sessionId": session["sessionId"],
            "deadline": time.time() + remaining,
            "javascript": javascript,
        }
        request_file.write_text(json.dumps(payload, separators=(",", ":")), encoding="utf-8")
        ready_file.write_bytes(b"")
        try:
            self._copy_to(target, target_id, request_file, f"{MAILBOX}/inbox/{request_id}.uploading")
            # The independent marker is published only after the body copy succeeds.
            self._copy_to(target, target_id, ready_file, f"{MAILBOX}/inbox/{request_id}.ready")
            response = self._read_response(target, target_id, request_id, session["sessionId"], remaining)
            self._publish_ack(target, target_id, request_id)
            return response
        finally:
            request_file.unlink(missing_ok=True)
            ready_file.unlink(missing_ok=True)

    def device_install(self, device_id: str) -> Path:
        if not device_id:
            raise DiagnosticError("Укажите device ID")
        derived = self.root / ".artifacts" / "device-derived"
        self._run([
            "xcodebuild", "-project", str(self.root / "ZDEEP/ZDEEP.xcodeproj"),
            "-scheme", "ZDEEP", "-configuration", "Debug", "-destination", f"id={device_id}",
            "-derivedDataPath", str(derived), "build", "CODE_SIGNING_ALLOWED=YES",
        ], timeout=900)
        app = derived / "Build/Products/Debug-iphoneos/ZDEEP.app"
        if not app.is_dir():
            raise DiagnosticError(f"Debug app не найдена после сборки: {app}")
        self._run(["xcrun", "devicectl", "device", "install", "app", "--device", device_id, str(app)], timeout=180)
        return app

    def device_launch(self, device_id: str, environment: str = "test") -> None:
        if environment != "test":
            raise DiagnosticError("USB mailbox разрешён только для environment test")
        if not device_id:
            raise DiagnosticError("Укажите device ID")
        env = json.dumps({"ZDEEP_ENVIRONMENT": "test", "ZDEEP_USB_DIAGNOSTICS": "1"}, separators=(",", ":"))
        self._run([
            "xcrun", "devicectl", "device", "process", "launch", "--device", device_id,
            "--environment-variables", env, "--terminate-existing", BUNDLE_ID,
        ], timeout=120)

    def simulator_launch(self, simulator_id: str, environment: str, web_url: str, api_url: str, *, open_webview: bool = False) -> None:
        if environment not in {"local", "test"}:
            raise DiagnosticError("Simulator diagnostics разрешены только для local или test")
        if not simulator_id:
            raise DiagnosticError("Укажите simulator ID")
        command = [
            "xcrun", "simctl", "launch", "--terminate-running-process", simulator_id, BUNDLE_ID,
            "--environment", environment,
            "--web-url", web_url,
            "--api-url", api_url,
            "--usb-diagnostics",
        ]
        if open_webview:
            command.append("--usb-diagnostics-open-webview")
        self._run(command, timeout=120)

    def logs(self, target: str, target_id: str) -> str:
        if target == "simulator":
            data = self._app_path(target, target_id)
            path = data / "Library/Application Support/ZDEEP/diagnostic-events.jsonl"
            return path.read_text(encoding="utf-8") if path.is_file() else ""
        if target == "device":
            self.temp_dir.mkdir(parents=True, exist_ok=True)
            destination = self.temp_dir / f"events-{uuid.uuid4()}.jsonl"
            try:
                self._run([
                    "xcrun", "devicectl", "device", "copy", "from", "--device", target_id,
                    "--source", "Library/Application Support/ZDEEP/diagnostic-events.jsonl",
                    "--destination", str(destination), "--domain-type", "appDataContainer",
                    "--domain-identifier", BUNDLE_ID,
                ], timeout=60)
                return destination.read_text(encoding="utf-8")
            finally:
                destination.unlink(missing_ok=True)
        raise DiagnosticError("Цель должна быть simulator или device")
