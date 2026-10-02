import plistlib
import tempfile
import unittest
from pathlib import Path
import sys
import plistlib
import subprocess
from contextlib import redirect_stderr
from io import StringIO
from unittest.mock import Mock
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from zdeep_tools.build import BuildManager, BuildError
from zdeep import main


class BuildManagerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "ZDEEP").mkdir()
        (self.root / "ZDEEP" / "source.swift").write_text("let value = 1")
        self.runner = Mock(side_effect=self.fake_xcodebuild)
        self.manager = BuildManager(self.root, runner=self.runner, toolchain="Xcode 27")

    def fake_xcodebuild(self, command, **kwargs):
        if "build-for-testing" in command:
            derived = Path(command[command.index("-derivedDataPath") + 1])
            products = derived / "Build" / "Products"
            products.mkdir(parents=True, exist_ok=True)
            (products / "ZDEEP_iphonesimulator.xctestrun").write_bytes(plistlib.dumps({
                "TestConfigurations": [{"TestTargets": [{
                    "TestBundlePath": "__TESTROOT__/PlugIns/ZDEEPTests.xctest",
                    "TestHostPath": "__TESTROOT__/ZDEEP.app/ZDEEP",
                    "UITargetAppPath": "__TESTROOT__/ZDEEP.app",
                    "EnvironmentVariables": {"ORIGINAL_FLAG": "kept"},
                }]}]
            }))
        return Mock(returncode=0)

    def test_build_once_for_suite(self):
        self.manager.run("all", "local", "SIM-1")
        build_calls = [call for call in self.runner.call_args_list if "build-for-testing" in call.args[0]]
        test_calls = [call for call in self.runner.call_args_list if "test-without-building" in call.args[0]]
        self.assertEqual(len(build_calls), 1)
        self.assertEqual(len(test_calls), 1)

    def test_skip_build_rejects_changed_sources(self):
        self.manager.run("unit", "local", "SIM-1")
        (self.root / "ZDEEP" / "source.swift").write_text("let value = 2")
        with self.assertRaises(BuildError):
            self.manager.run("unit", "local", "SIM-1", skip_build=True)

    def test_results_are_unique(self):
        first = self.manager.new_results_directory()
        second = self.manager.new_results_directory()
        self.assertNotEqual(first, second)
        self.assertTrue(first.is_dir())
        self.assertTrue(second.is_dir())

    def test_xctestrun_copy_keeps_xcode_relative_product_paths(self):
        self.manager.run("ui", "test", "SIM-1")
        source = next(
            path for path in self.root.glob(".artifacts/builds/*/DerivedData/Build/Products/*.xctestrun")
            if "-zdeep-run-" not in path.name
        )
        original_bytes = source.read_bytes()
        test_calls = [call for call in self.runner.call_args_list if "test-without-building" in call.args[0]]
        command = test_calls[0].args[0]
        configured = Path(command[command.index("-xctestrun") + 1])
        self.assertNotEqual(configured, source)
        self.assertEqual(configured.parent.resolve(), source.parent.resolve())
        result = plistlib.loads(configured.read_bytes())["TestConfigurations"][0]["TestTargets"][0]
        self.assertEqual(result["TestBundlePath"], "__TESTROOT__/PlugIns/ZDEEPTests.xctest")
        self.assertEqual(result["TestHostPath"], "__TESTROOT__/ZDEEP.app/ZDEEP")
        self.assertEqual(result["UITargetAppPath"], "__TESTROOT__/ZDEEP.app")
        self.assertEqual(result["EnvironmentVariables"], {"ORIGINAL_FLAG": "kept", "ZDEEP_ENVIRONMENT": "test"})
        self.assertEqual(source.read_bytes(), original_bytes)
        self.assertEqual(self.manager.build("SIM-1"), source.resolve())

    def test_cli_formats_xcodebuild_failure_without_traceback(self):
        failure = subprocess.CalledProcessError(65, ["xcodebuild"], output="internal output")
        stderr = StringIO()
        with patch("zdeep.BuildManager") as manager, redirect_stderr(stderr):
            manager.return_value.build.side_effect = failure
            result = main(["build-tests", "--simulator", "SIM-1"])
        self.assertEqual(result, 1)
        self.assertIn("xcodebuild завершился с кодом 65", stderr.getvalue())
        self.assertNotIn("Traceback", stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
