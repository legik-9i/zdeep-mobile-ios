import unittest
from pathlib import Path
import sys
from unittest.mock import Mock
from contextlib import redirect_stderr, redirect_stdout
from io import StringIO
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from zdeep_tools.preflight import PreflightError, check_local_health, preflight
from zdeep import DEFAULTS, main


class PreflightTests(unittest.TestCase):
    def test_local_health_requires_200(self):
        request = Mock(return_value=503)
        with self.assertRaises(PreflightError):
            check_local_health("http://127.0.0.1:8080", request=request)
        request.assert_called_once_with("http://127.0.0.1:8080/health", timeout=5)

    def test_prod_integration_is_rejected_without_request(self):
        request = Mock()
        with self.assertRaises(PreflightError):
            preflight("prod", "integration", "https://example.invalid", request=request)
        request.assert_not_called()

    def test_prod_endpoints_are_constants_but_cli_never_requests_prod(self):
        self.assertEqual(DEFAULTS["web"]["prod"], "https://webview2.zdeep.ru")
        self.assertEqual(DEFAULTS["api"]["prod"], "https://api.zdeep.ru")
        with patch("zdeep.preflight") as request, redirect_stderr(StringIO()):
            for command in (
                ["preflight", "--environment", "prod"],
                ["test", "--environment", "prod", "--suite", "integration"],
            ):
                with self.assertRaises(SystemExit):
                    main(command)
            request.assert_not_called()

    def test_test_contour_is_rejected_without_external_calls(self):
        with patch("zdeep.preflight") as request, redirect_stderr(StringIO()):
            for command in (
                ["preflight", "--environment", "test"],
                ["test", "--environment", "test", "--suite", "integration"],
            ):
                with self.subTest(command=command), self.assertRaises(SystemExit):
                    main(command)
            request.assert_not_called()

    def test_local_preflight_checks_api_prefix_and_configured_web_url(self):
        request = Mock(return_value=200)
        result = preflight(
            "local", "integration", "http://localhost:4002/api/", request=request,
            web_url="http://localhost:4005/app",
        )
        self.assertEqual(result, "local API /health and Web: HTTP 200")
        self.assertEqual(request.call_args_list, [
            unittest.mock.call("http://localhost:4002/api/health", timeout=5),
            unittest.mock.call("http://localhost:4005/app", timeout=5),
        ])

    def test_local_preflight_rejects_non_200_from_api_or_web(self):
        for endpoint, url in (("API", "http://localhost:4002/health"), ("Web", "http://localhost:4005")):
            for status in (301, 401, 403, 404, 500):
                with self.subTest(endpoint=endpoint, status=status):
                    request = Mock(side_effect=[200, status] if endpoint == "Web" else [status])
                    with self.assertRaises(PreflightError):
                        preflight("local", "integration", "http://localhost:4002", request=request,
                                  web_url="http://localhost:4005")
                    self.assertEqual(request.call_args_list[-1].args[0], url)

    def test_local_preflight_stops_on_transport_errors(self):
        for endpoint in ("API", "Web"):
            for failure in (TimeoutError("timed out"), OSError("connection refused")):
                with self.subTest(endpoint=endpoint, failure=failure):
                    request = Mock(side_effect=[200, failure] if endpoint == "Web" else failure)
                    with self.assertRaises(PreflightError):
                        preflight("local", "integration", "http://localhost:4002", request=request,
                                  web_url="http://localhost:4005")
                    self.assertEqual(request.call_count, 2 if endpoint == "Web" else 1)

    def test_unit_preflight_does_not_need_network_endpoints(self):
        request = Mock()
        self.assertIn("unit", preflight("local", "unit", request=request))
        request.assert_not_called()

    def test_redirect_cannot_leave_local_origin(self):
        from zdeep_tools import preflight as module
        response = Mock(status=200, geturl=lambda: "https://api.zdeep.ru/health")
        with patch.object(module.urllib.request, "urlopen") as urlopen:
            urlopen.return_value.__enter__.return_value = response
            with self.assertRaises(PreflightError):
                module._http_status("http://localhost:4002/health")

    def test_redirect_within_origin_returns_final_status(self):
        from zdeep_tools import preflight as module
        response = Mock(status=200, geturl=lambda: "http://localhost:4002/health/ready")
        with patch.object(module.urllib.request, "urlopen") as urlopen:
            urlopen.return_value.__enter__.return_value = response
            self.assertEqual(module._http_status("http://localhost:4002/health"), 200)


    def test_local_diagnostic_callers_pass_configured_web_url(self):
        with patch("zdeep.preflight", return_value="ready") as preflight, patch("zdeep.DiagnosticManager") as manager, redirect_stdout(StringIO()):
            manager.return_value.simulator_launch.return_value = None
            self.assertEqual(main(["simulator-launch", "--simulator", "SIM-1", "--environment", "local"]), 0)
        preflight.assert_called_once_with("local", "integration", "http://localhost:4002", web_url="http://localhost:4005")

        with patch("zdeep.preflight", return_value="ready") as preflight, patch("zdeep.DiagnosticManager") as manager, redirect_stdout(StringIO()):
            manager.return_value.diagnose.return_value = {"ok": True}
            self.assertEqual(main(["diagnose", "--target", "simulator", "--simulator", "SIM-1", "--environment", "local", "--js", "1"]), 0)
        preflight.assert_called_once_with("local", "integration", "http://localhost:4002", web_url="http://localhost:4005")


if __name__ == "__main__":
    unittest.main()
