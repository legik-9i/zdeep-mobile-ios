import json
import plistlib
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from contextlib import redirect_stderr, redirect_stdout
from io import StringIO
from unittest.mock import Mock, patch

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
        self.test_report = {
            "testNodes": [{
                "nodeType": "Test Plan",
                "children": [{
                    "nodeType": "Unit test bundle",
                    "children": [{
                        "nodeType": "Test Suite",
                        "children": [{
                            "nodeType": "Test Case",
                            "nodeIdentifier": "example()",
                            "result": "Passed",
                        }],
                    }],
                }],
            }]
        }
        self.manager = BuildManager(self.root, runner=self.runner, toolchain="Xcode 27")

    def fake_xcodebuild(self, command, **kwargs):
        if command[:3] == ["xcrun", "xcresulttool", "get"]:
            return Mock(returncode=0, stdout=json.dumps(self.test_report))
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

    def test_ad_hoc_signing_is_limited_to_local_unit_simulator_builds(self):
        self.manager.run("unit", "local", "SIM-1")
        local_unit = next(call.args[0] for call in self.runner.call_args_list if "build-for-testing" in call.args[0])
        self.assertIn("CODE_SIGNING_ALLOWED=YES", local_unit)
        self.assertIn("CODE_SIGN_IDENTITY=-", local_unit)

        self.runner.reset_mock()
        self.manager.run("unit", "test", "SIM-1")
        test_unit = next(call.args[0] for call in self.runner.call_args_list if "build-for-testing" in call.args[0])
        self.assertIn("CODE_SIGNING_ALLOWED=NO", test_unit)
        self.assertNotIn("CODE_SIGN_IDENTITY=-", test_unit)

        self.runner.reset_mock()
        self.manager.run("integration", "local", "SIM-1")
        local_integration = next(call.args[0] for call in self.runner.call_args_list if "build-for-testing" in call.args[0])
        self.assertIn("CODE_SIGNING_ALLOWED=YES", local_integration)
        self.assertIn("CODE_SIGN_IDENTITY=-", local_integration)
        integration_run = next(call.args[0] for call in self.runner.call_args_list if "test-without-building" in call.args[0])
        self.assertIn("-only-testing:ZDEEPTests/WebSessionIntegrationTests", integration_run)

        self.runner.reset_mock()
        self.manager.run("integration", "test", "SIM-1")
        test_integration = next(call.args[0] for call in self.runner.call_args_list if "build-for-testing" in call.args[0])
        self.assertIn("CODE_SIGNING_ALLOWED=NO", test_integration)
        self.assertNotIn("CODE_SIGN_IDENTITY=-", test_integration)

        self.runner.reset_mock()
        self.manager.run("all", "local", "SIM-1")
        local_all = next(call.args[0] for call in self.runner.call_args_list if "build-for-testing" in call.args[0])
        self.assertIn("CODE_SIGNING_ALLOWED=YES", local_all)
        self.assertIn("CODE_SIGN_IDENTITY=-", local_all)

        self.runner.reset_mock()
        self.manager.run("all", "test", "SIM-1")
        test_all = next(call.args[0] for call in self.runner.call_args_list if "build-for-testing" in call.args[0])
        self.assertIn("CODE_SIGNING_ALLOWED=NO", test_all)
        self.assertNotIn("CODE_SIGN_IDENTITY=-", test_all)

        self.runner.reset_mock()
        self.manager.build("SIM-1")
        direct_build = next(call.args[0] for call in self.runner.call_args_list if "build-for-testing" in call.args[0])
        self.assertIn("CODE_SIGNING_ALLOWED=NO", direct_build)
        self.assertNotIn("CODE_SIGN_IDENTITY=-", direct_build)

    def test_skip_build_rejects_changed_sources(self):
        self.manager.run("unit", "local", "SIM-1")
        (self.root / "ZDEEP" / "source.swift").write_text("let value = 2")
        with self.assertRaises(BuildError):
            self.manager.run("unit", "local", "SIM-1", skip_build=True)

    def test_skip_build_guides_local_unit_to_signed_build(self):
        with self.assertRaisesRegex(BuildError, "без `--skip-build`"):
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

    def test_cli_unit_suite_skips_network_preflight(self):
        with patch("zdeep.preflight") as preflight, patch("zdeep.BuildManager") as manager, redirect_stdout(StringIO()):
            manager.return_value.run.return_value = self.root / "results"
            result = main([
                "test", "--environment", "local", "--suite", "unit",
                "--simulator", "SIM-1", "--skip-build",
            ])
        self.assertEqual(result, 0)
        preflight.assert_not_called()

    def test_only_filter_uses_xcresult_swift_testing_node_identifier(self):
        self.manager.run("unit", "local", "SIM-1", only="ZDEEPTests/example()")
        command = next(call.args[0] for call in self.runner.call_args_list if "test-without-building" in call.args[0])
        self.assertIn("-only-testing:ZDEEPTests/example()", command)

    def test_unit_only_target_prefixed_swift_testing_identifier(self):
        case_id = "EnvironmentTests/test_testing_api_path_is_preserved()"
        self.test_report["testNodes"][0]["children"][0]["children"][0]["children"] = [{
            "nodeType": "Test Case",
            "nodeIdentifier": case_id,
            "result": "Passed",
        }]

        self.manager.run(
            "unit", "local", "SIM-1",
            only=f"ZDEEPTests/{case_id}",
        )

        command = next(call.args[0] for call in self.runner.call_args_list if "test-without-building" in call.args[0])
        selectors = [arg for arg in command if arg.startswith("-only-testing:")]
        self.assertEqual(
            selectors,
            ["-only-testing:ZDEEPTests/EnvironmentTests/test_testing_api_path_is_preserved()"],
        )

    def test_empty_test_report_is_rejected(self):
        self.test_report = {"testNodes": []}
        with self.assertRaisesRegex(BuildError, "ноль выполненных тестов"):
            self.manager.run("unit", "local", "SIM-1")

    def test_only_filter_must_match_exactly_one_reported_case(self):
        with self.assertRaisesRegex(BuildError, "не совпал с ровно одним тестом в xcresult"):
            self.manager.run("unit", "local", "SIM-1", only="ZDEEPTests/missing()")

    def test_only_filter_rejects_extra_executed_cases(self):
        self.test_report["testNodes"].append({
            "nodeType": "Test Case",
            "nodeIdentifier": "another()",
            "result": "Passed",
        })
        with self.assertRaisesRegex(BuildError, "ожидался ровно один выбранный тест"):
            self.manager.run("unit", "local", "SIM-1", only="ZDEEPTests/example()")

    def test_integration_only_rejects_unit_identifier(self):
        with self.assertRaisesRegex(BuildError, "не принадлежит WebSessionIntegrationTests"):
            self.manager.run("integration", "local", "SIM-1", only="ZDEEPTests/example()")
        self.runner.assert_not_called()

    def test_integration_only_constructs_suite_scoped_selector(self):
        integration_id = "WebSessionIntegrationTests/test_real_web_url_and_native_object()"
        self.test_report["testNodes"][0]["children"][0]["children"][0]["children"] = [{
            "nodeType": "Test Case",
            "nodeIdentifier": integration_id,
            "result": "Passed",
        }]
        self.manager.run("integration", "test", "SIM-1", only=integration_id)
        command = next(call.args[0] for call in self.runner.call_args_list if "test-without-building" in call.args[0])
        self.assertIn(f"-only-testing:ZDEEPTests/{integration_id}", command)

    def test_integration_only_accepts_target_prefixed_identifier_but_validates_result_id(self):
        integration_id = "WebSessionIntegrationTests/test_real_web_url_and_native_object()"
        self.test_report["testNodes"][0]["children"][0]["children"][0]["children"] = [{
            "nodeType": "Test Case",
            "nodeIdentifier": integration_id,
            "result": "Passed",
        }]
        self.manager.run("integration", "test", "SIM-1", only=f"ZDEEPTests/{integration_id}")
        command = next(call.args[0] for call in self.runner.call_args_list if "test-without-building" in call.args[0])
        self.assertIn(f"-only-testing:ZDEEPTests/{integration_id}", command)

    def test_integration_only_rejects_suite_identifier_without_test_name(self):
        with self.assertRaisesRegex(BuildError, "не принадлежит WebSessionIntegrationTests"):
            self.manager.run("integration", "test", "SIM-1", only="WebSessionIntegrationTests/")
        self.runner.assert_not_called()


if __name__ == "__main__":
    unittest.main()
