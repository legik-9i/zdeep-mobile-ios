import unittest
from pathlib import Path
import sys
from unittest.mock import Mock
from contextlib import redirect_stderr
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


if __name__ == "__main__":
    unittest.main()
