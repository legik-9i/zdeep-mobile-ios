import unittest
from pathlib import Path
import sys
from unittest.mock import Mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from zdeep_tools.preflight import PreflightError, check_local_health, preflight


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


if __name__ == "__main__":
    unittest.main()
