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
from zdeep_tools.preflight import PreflightError
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

    def test_all_suites_disable_automatic_simulator_diagnostics(self):
        for suite in ("unit", "integration", "ui", "all"):
            with self.subTest(suite=suite):
                self.runner.reset_mock()
                self.manager.run(suite, "local", "SIM-1")
                command = next(call.args[0] for call in self.runner.call_args_list if "test-without-building" in call.args[0])
                self.assertIn(["-collect-test-diagnostics", "never"], [command[i:i + 2] for i in range(len(command) - 1)])

    def test_all_test_suites_use_ad_hoc_signed_build(self):
        for suite in ("unit", "integration", "ui", "all"):
            with self.subTest(suite=suite):
                self.runner.reset_mock()
                self.manager.run(suite, "local", "SIM-1")
                build = next(call.args[0] for call in self.runner.call_args_list if "build-for-testing" in call.args[0])
                self.assertIn("CODE_SIGNING_ALLOWED=YES", build)
                self.assertIn("CODE_SIGN_IDENTITY=-", build)
        self.runner.reset_mock()
        self.manager.build("SIM-1")
        build = next(call.args[0] for call in self.runner.call_args_list if "build-for-testing" in call.args[0])
        self.assertIn("CODE_SIGNING_ALLOWED=YES", build)
        self.assertIn("CODE_SIGN_IDENTITY=-", build)

    def test_build_tests_is_reusable_by_every_suite(self):
        self.manager.build("SIM-1")
        self.runner.reset_mock()
        for suite in ("unit", "integration", "ui", "all"):
            self.manager.run(suite, "local", "SIM-1", skip_build=True)
        commands = [call.args[0] for call in self.runner.call_args_list]
        self.assertFalse(any("build-for-testing" in command for command in commands))
        self.assertEqual(sum("test-without-building" in command for command in commands), 4)

    def test_test_contour_is_rejected_without_external_calls(self):
        with self.assertRaisesRegex(BuildError, "только для local"):
            self.manager.run("integration", "test", "SIM-1")
        self.runner.assert_not_called()

    def test_fingerprint_ignores_python_bytecode_but_tracks_sources(self):
        scripts = self.root / "scripts"
        scripts.mkdir()
        source = scripts / "example.py"
        source.write_text("value = 1")
        fingerprint = self.manager.fingerprint("SIM-1")
        cache = scripts / "__pycache__"
        cache.mkdir()
        (cache / "example.cpython-312.pyc").write_bytes(b"bytecode one")
        self.assertEqual(self.manager.fingerprint("SIM-1"), fingerprint)
        (cache / "example.cpython-312.pyc").write_bytes(b"bytecode two")
        self.assertEqual(self.manager.fingerprint("SIM-1"), fingerprint)
        source.write_text("value = 2")
        self.assertNotEqual(self.manager.fingerprint("SIM-1"), fingerprint)

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
        self.manager.run("ui", "local", "SIM-1")
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
        self.assertEqual(result["EnvironmentVariables"], {"ORIGINAL_FLAG": "kept", "ZDEEP_ENVIRONMENT": "local"})
        self.assertEqual(source.read_bytes(), original_bytes)
        self.assertEqual(self.manager.build("SIM-1"), source.resolve())

    def test_ui_only_accepts_xcode_target_prefixed_node_identifier(self):
        identifier = "AuthorizationUITests/test_example()"
        self.test_report = {
            "testNodes": [{"nodeType": "Test Case", "nodeIdentifier": identifier, "result": "Passed"}]
        }

        self.manager.run("ui", "local", "SIM-1", only=f"ZDEEPUITests/{identifier}")

        command = next(call.args[0] for call in self.runner.call_args_list if "test-without-building" in call.args[0])
        self.assertIn(f"-only-testing:ZDEEPUITests/{identifier}", command)

    def test_passive_host_flag_is_scoped_to_hosted_target(self):
        layouts = [
            {"TestConfigurations": [{"TestTargets": [
                {"TestBundlePath": "__TESTROOT__/PlugIns/ZDEEPTests.xctest", "EnvironmentVariables": {"KEEP": "unit"}},
                {"TestBundlePath": "__TESTROOT__/PlugIns/ZDEEPUITests.xctest", "EnvironmentVariables": {"KEEP": "ui"}},
            ]}]},
            {"__xctestrun_metadata__": {"FormatVersion": 2}, "ZDEEPTests": {
                "TestBundlePath": "ZDEEPTests.xctest", "EnvironmentVariables": {"KEEP": "unit"}},
                "ZDEEPUITests": {"TestBundlePath": "/tmp/ZDEEPUITests.xctest", "EnvironmentVariables": {"KEEP": "ui"}}},
        ]
        for index, data in enumerate(layouts):
            with self.subTest(layout=index):
                source = self.root / f"layout-{index}.xctestrun"
                destination = self.root / f"configured-{index}.xctestrun"
                source.write_bytes(plistlib.dumps(data))
                BuildManager._configure_xctestrun(
                    source, destination,
                    {"ZDEEP_ENVIRONMENT": "local", "ZDEEP_PASSIVE_TEST_HOST": "1"},
                )
                configured = plistlib.loads(destination.read_bytes())
                encoded = plistlib.dumps(configured)
                self.assertIn(b"ZDEEPTests.xctest", encoded)
                self.assertIn(b"ZDEEPUITests.xctest", encoded)
                def targets(value):
                    if isinstance(value, dict):
                        if "TestBundlePath" in value:
                            yield value
                        for nested in value.values():
                            yield from targets(nested)
                    elif isinstance(value, list):
                        for nested in value:
                            yield from targets(nested)
                by_bundle = {Path(item["TestBundlePath"]).name: item for item in targets(configured)}
                self.assertEqual(by_bundle["ZDEEPTests.xctest"]["EnvironmentVariables"], {
                    "KEEP": "unit", "ZDEEP_ENVIRONMENT": "local", "ZDEEP_PASSIVE_TEST_HOST": "1",
                })
                self.assertEqual(by_bundle["ZDEEPUITests.xctest"]["EnvironmentVariables"], {
                    "KEEP": "ui", "ZDEEP_ENVIRONMENT": "local",
                })

    def test_app_entry_passive_host_skips_production_root(self):
        source = (Path(__file__).resolve().parents[2] / "ZDEEP/ZDEEP/ZDEEPApp.swift").read_text()
        self.assertIn("ZDEEP_PASSIVE_TEST_HOST", source)
        self.assertIn("PassiveHostedTestRoot", source)
        self.assertLess(source.index("PassiveHostedTestRoot"), source.index("AppRootView"))

    def test_all_suite_configures_passive_unit_host(self):
        self.manager.run("all", "local", "SIM-1")
        command = next(call.args[0] for call in self.runner.call_args_list if "test-without-building" in call.args[0])
        configured = Path(command[command.index("-xctestrun") + 1])
        data = plistlib.loads(configured.read_bytes())
        targets = data["TestConfigurations"][0]["TestTargets"]
        unit = next(target for target in targets if Path(target["TestBundlePath"]).name == "ZDEEPTests.xctest")
        self.assertEqual(unit["EnvironmentVariables"]["ZDEEP_PASSIVE_TEST_HOST"], "1")

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

    def test_cli_network_preflight_failure_does_not_run_build_manager(self):
        with patch("zdeep.preflight", side_effect=PreflightError("blocked")), patch("zdeep.BuildManager") as manager, redirect_stderr(StringIO()):
            result = main(["test", "--environment", "local", "--suite", "integration", "--simulator", "SIM-1"])
        self.assertEqual(result, 1)
        manager.return_value.run.assert_not_called()

    def test_cli_network_preflight_receives_configured_local_web_url(self):
        with patch("zdeep.preflight", return_value="ready") as preflight, patch("zdeep.BuildManager") as manager, redirect_stdout(StringIO()):
            manager.return_value.run.return_value = self.root / "results"
            self.assertEqual(main(["test", "--environment", "local", "--suite", "integration", "--simulator", "SIM-1"]), 0)
        preflight.assert_called_once_with("local", "integration", "http://localhost:4002", web_url="http://localhost:4005")

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

    def test_failed_and_skipped_cases_are_rejected(self):
        for result in ("Failed", "Skipped"):
            with self.subTest(result=result):
                report = {"testNodes": [
                    {"nodeType": "Test Case", "nodeIdentifier": "passed()", "result": "Passed"},
                    {"nodeType": "Test Case", "nodeIdentifier": "example()", "result": result},
                ]}
                with self.assertRaisesRegex(BuildError, result):
                    self.manager.validate_test_report(report)

    def test_malformed_test_reports_are_rejected(self):
        reports = (
            {},
            {"testNodes": "invalid"},
            None,
            {"testNodes": [
                {"nodeType": "Test Case", "result": "Passed"},
                {"nodeType": "Test Case"},
            ]},
            {"testNodes": [
                {"nodeType": "Test Case", "result": "Passed"},
                {"nodeType": "Test Case", "result": "Unexpected"},
            ]},
            {"testNodes": [{"nodeType": "Test Case", "result": []}]},
        )
        for report in reports:
            with self.subTest(report=report):
                with self.assertRaises(BuildError):
                    self.manager.validate_test_report(report)

    def test_xcodebuild_failure_includes_created_run_and_bundle_paths(self):
        self.runner.side_effect = lambda command, **kwargs: (
            (_ for _ in ()).throw(subprocess.CalledProcessError(65, command))
            if "test-without-building" in command else self.fake_xcodebuild(command, **kwargs)
        )
        with self.assertRaises(BuildError) as raised:
            self.manager.run("unit", "local", "SIM-1")
        results = next(self.root.glob(".artifacts/runs/*"))
        self.assertIn(str(results), str(raised.exception))
        self.assertIn(str(results / "Tests.xcresult"), str(raised.exception))

    def test_incomplete_result_bundle_has_distinct_error(self):
        self.runner.side_effect = lambda command, **kwargs: (
            (_ for _ in ()).throw(subprocess.CalledProcessError(65, command))
            if command[:3] == ["xcrun", "xcresulttool", "get"] else self.fake_xcodebuild(command, **kwargs)
        )
        with self.assertRaisesRegex(BuildError, "Не удалось прочитать xcresult"):
            self.manager.run("unit", "local", "SIM-1")

    def test_invalid_result_json_is_rejected(self):
        self.runner.side_effect = lambda command, **kwargs: (
            Mock(returncode=0, stdout="not json")
            if command[:3] == ["xcrun", "xcresulttool", "get"] else self.fake_xcodebuild(command, **kwargs)
        )
        with self.assertRaisesRegex(BuildError, "некорректный JSON"):
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
        self.manager.run("integration", "local", "SIM-1", only=integration_id)
        command = next(call.args[0] for call in self.runner.call_args_list if "test-without-building" in call.args[0])
        self.assertIn(f"-only-testing:ZDEEPTests/{integration_id}", command)

    def test_integration_only_accepts_target_prefixed_identifier_but_validates_result_id(self):
        integration_id = "WebSessionIntegrationTests/test_real_web_url_and_native_object()"
        self.test_report["testNodes"][0]["children"][0]["children"][0]["children"] = [{
            "nodeType": "Test Case",
            "nodeIdentifier": integration_id,
            "result": "Passed",
        }]
        self.manager.run("integration", "local", "SIM-1", only=f"ZDEEPTests/{integration_id}")
        command = next(call.args[0] for call in self.runner.call_args_list if "test-without-building" in call.args[0])
        self.assertIn(f"-only-testing:ZDEEPTests/{integration_id}", command)

    def test_integration_only_rejects_suite_identifier_without_test_name(self):
        with self.assertRaisesRegex(BuildError, "не принадлежит WebSessionIntegrationTests"):
            self.manager.run("integration", "local", "SIM-1", only="WebSessionIntegrationTests/")
        self.runner.assert_not_called()


if __name__ == "__main__":
    unittest.main()
