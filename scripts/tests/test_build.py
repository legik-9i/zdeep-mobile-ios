import plistlib
import tempfile
import unittest
from pathlib import Path
import sys
from unittest.mock import Mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from zdeep_tools.build import BuildManager, BuildError


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
            (products / "ZDEEP_iphonesimulator.xctestrun").write_bytes(plistlib.dumps({"TestConfigurations": [{"TestTargets": [{"TestBundlePath": "ZDEEPTests.xctest"}]}]}))
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


if __name__ == "__main__":
    unittest.main()
