import json
import re
import sys
import tempfile
import unittest
from io import StringIO
from pathlib import Path
from unittest.mock import Mock
from contextlib import redirect_stdout
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from zdeep_tools.diagnostics import DiagnosticError, DiagnosticManager, decode_response, load_javascript
from zdeep import main


class DiagnosticTests(unittest.TestCase):
    def test_javascript_can_be_read_from_file_or_stdin(self):
        root = Path(tempfile.mkdtemp())
        source = root / "diagnostic.js"
        source.write_text("1+1", encoding="utf-8")
        self.assertEqual(load_javascript(source_file=source), "1+1")
        self.assertEqual(load_javascript(source_stream=StringIO("1+1")), "1+1")

    def test_javascript_source_limit_is_enforced_for_file_and_stdin(self):
        oversized = "x" * 128_001
        with self.assertRaises(DiagnosticError):
            load_javascript(source_stream=StringIO(oversized))

    def test_stale_or_malformed_session_handshake_is_rejected(self):
        now = 1_800_000_000
        valid = {
            "ready": True,
            "environment": "test",
            "sessionId": "00000000-0000-4000-8000-000000000001",
            "updatedAt": now - 2,
        }
        self.assertTrue(DiagnosticManager.is_fresh_session_status(valid, "test", now=now))
        self.assertFalse(DiagnosticManager.is_fresh_session_status({**valid, "updatedAt": now - 11}, "test", now=now))
        self.assertFalse(DiagnosticManager.is_fresh_session_status({**valid, "sessionId": "old-session"}, "test", now=now))
        self.assertFalse(DiagnosticManager.is_fresh_session_status({**valid, "environment": "local"}, "test", now=now))

    def test_malformed_response_json_is_rejected(self):
        with self.assertRaises(DiagnosticError):
            decode_response(b"{not json")

    def test_duplicate_request_uuid_is_rejected(self):
        manager = DiagnosticManager(Path(tempfile.mkdtemp()), runner=Mock())
        with self.assertRaises(DiagnosticError):
            manager.validate_request_id("00000000-0000-4000-8000-000000000001", {"00000000-0000-4000-8000-000000000001"})

    def test_stale_session_response_is_rejected(self):
        response = {"id": "00000000-0000-4000-8000-000000000001", "sessionId": "old-session", "ok": True, "result": 2}
        with self.assertRaises(DiagnosticError):
            decode_response(json.dumps(response).encode(), expected_session_id="new-session")

    def test_unavailable_device_is_reported(self):
        runner = Mock(side_effect=FileNotFoundError("device not found"))
        manager = DiagnosticManager(Path(tempfile.mkdtemp()), runner=runner)
        with self.assertRaisesRegex(DiagnosticError, "device"):
            manager.device_install("missing-device")

    def test_missing_response_times_out_and_cleans_local_payload(self):
        root = Path(tempfile.mkdtemp())
        container = root / "simulator-data"
        container.mkdir()
        runner = Mock(return_value=Mock(returncode=0, stdout=str(container), stderr=""))
        manager = DiagnosticManager(root, runner=runner, poll_interval=0.001)
        with self.assertRaisesRegex(DiagnosticError, re.compile("тайм-аут", re.IGNORECASE)):
            manager.diagnose("simulator", "sim-id", "1+1", timeout=0.01, environment="local", web_url="https://web.invalid", api_url="https://api.invalid")
        self.assertFalse(list(manager.temp_dir.glob("*.json")))

    def test_response_is_copied_before_acknowledgement(self):
        root = Path(tempfile.mkdtemp())
        container = root / "simulator-data"
        container.mkdir()
        runner = Mock(return_value=Mock(returncode=0, stdout=str(container), stderr=""))
        manager = DiagnosticManager(root, runner=runner, poll_interval=0.001)
        manager._ensure_simulator_diagnostic_session = Mock()
        response = {"id": "00000000-0000-4000-8000-000000000002", "sessionId": "session", "ok": True, "result": 2}
        sequence = []
        manager._read_response = Mock(side_effect=lambda *args: sequence.append("copied-response") or response)
        manager._wait_for_session = Mock(return_value={"sessionId": "session", "url": "https://test.invalid"})
        original_ack = manager._publish_ack
        manager._publish_ack = lambda *args: (sequence.append("ack"), original_ack(*args))
        result = manager.diagnose("simulator", "sim-id", "1+1", timeout=1, environment="local", web_url="https://web.invalid", api_url="https://api.invalid")
        self.assertEqual(result["result"], 2)
        self.assertEqual(sequence, ["copied-response", "ack"])
        self.assertEqual(len(list((container / "Library/Caches/ZdeepDiagnostics/inbox").glob("*.ack.ready"))), 1)

    def test_device_id_is_selected_for_all_device_operations(self):
        runner = Mock(return_value=Mock(returncode=0, stdout="", stderr=""))
        root = Path(tempfile.mkdtemp())
        manager = DiagnosticManager(root, runner=runner)
        app = root / ".artifacts/device-derived/Build/Products/Debug-iphoneos/ZDEEP.app"
        app.mkdir(parents=True)
        manager.device_install("device-123")
        commands = [call.args[0] for call in runner.call_args_list]
        self.assertTrue(any("device-123" in command for command in commands))
        self.assertIn("device-123", commands[-1])

    def test_device_install_keeps_project_signing(self):
        runner = Mock(return_value=Mock(returncode=0, stdout="", stderr=""))
        root = Path(tempfile.mkdtemp())
        manager = DiagnosticManager(root, runner=runner)
        app = root / ".artifacts/device-derived/Build/Products/Debug-iphoneos/ZDEEP.app"
        app.mkdir(parents=True)
        manager.device_install("device-123")
        build = next(call.args[0] for call in runner.call_args_list if "xcodebuild" in call.args[0])
        self.assertIn("CODE_SIGNING_ALLOWED=YES", build)
        self.assertNotIn("CODE_SIGN_IDENTITY=-", build)

    def test_device_launch_keeps_test_environment_and_usb_opt_in(self):
        runner = Mock(return_value=Mock(returncode=0, stdout="", stderr=""))
        DiagnosticManager(Path(tempfile.mkdtemp()), runner=runner).device_launch("device-123", "test")
        command = runner.call_args.args[0]
        self.assertIn("--environment-variables", command)
        environment = json.loads(command[command.index("--environment-variables") + 1])
        self.assertEqual(environment, {"ZDEEP_ENVIRONMENT": "test", "ZDEEP_USB_DIAGNOSTICS": "1"})

    def test_diagnostics_keep_device_testing_contract(self):
        with patch("zdeep.preflight") as preflight, patch("zdeep.DiagnosticManager") as manager, redirect_stdout(StringIO()):
            manager.return_value.diagnose.return_value = {"ok": True, "result": 2}
            self.assertEqual(main(["device-launch", "--device", "DEVICE-1", "--environment", "test"]), 0)
            self.assertEqual(main(["diagnose", "--target", "device", "--device", "DEVICE-1", "--environment", "test", "--js", "1+1"]), 0)
        manager.return_value.device_launch.assert_called_once_with("DEVICE-1", "test")
        manager.return_value.diagnose.assert_called_once()
        self.assertEqual(manager.return_value.diagnose.call_args.kwargs["environment"], "test")
        preflight.assert_not_called()

    def test_explicit_simulator_diagnostic_open_is_separate_from_normal_launch(self):
        runner = Mock(return_value=Mock(returncode=0, stdout="", stderr=""))
        manager = DiagnosticManager(Path(tempfile.mkdtemp()), runner=runner)
        manager.simulator_launch("sim-123", "local", "https://web.invalid", "https://api.invalid")
        manager.simulator_launch("sim-123", "test", "https://web.invalid", "https://api.invalid", open_webview=True)
        normal, diagnostic = [call.args[0] for call in runner.call_args_list]
        self.assertNotIn("--usb-diagnostics-open-webview", normal)
        self.assertIn("--usb-diagnostics-open-webview", diagnostic)


if __name__ == "__main__":
    unittest.main()
