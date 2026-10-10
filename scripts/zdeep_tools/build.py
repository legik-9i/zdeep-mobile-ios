from __future__ import annotations

import hashlib
import json
import plistlib
import subprocess
import time
from pathlib import Path
from typing import Callable


class BuildError(RuntimeError):
    pass


class BuildManager:
    def __init__(self, root: Path, runner: Callable = subprocess.run, toolchain: str | None = None):
        self.root = Path(root).resolve()
        self.runner = runner
        self.toolchain = toolchain or self._toolchain_version()
        self.artifacts = self.root / ".artifacts"
        self.builds = self.artifacts / "builds"
        self.runs = self.artifacts / "runs"
        self.cache: dict[str, Path] = {}

    def _toolchain_version(self) -> str:
        try:
            result = subprocess.run(["xcodebuild", "-version"], check=True, capture_output=True, text=True)
            return result.stdout.strip()
        except (OSError, subprocess.CalledProcessError) as exc:
            raise BuildError(f"Не удалось получить версию Xcode: {exc}") from exc

    def fingerprint(self, simulator: str, code_signing: bool = True) -> str:
        digest = hashlib.sha256()
        included = (self.root / "ZDEEP", self.root / "scripts")
        for base in included:
            if base.is_file():
                paths = [base]
            elif base.exists():
                paths = sorted(
                    path for path in base.rglob("*")
                    if path.is_file()
                    and ".artifacts" not in path.parts
                    and "__pycache__" not in path.parts
                    and path.suffix not in {".pyc", ".pyo"}
                    and path.name != ".DS_Store"
                )
            else:
                continue
            for path in paths:
                digest.update(path.relative_to(self.root).as_posix().encode())
                digest.update(path.read_bytes())
        digest.update(json.dumps({
            "toolchain": self.toolchain,
            "simulator": simulator,
            "scheme": "ZDEEP",
            "configuration": "Debug",
            "sdk": "iphonesimulator",
            "codeSigning": code_signing,
        }, sort_keys=True).encode())
        return digest.hexdigest()

    def new_results_directory(self) -> Path:
        self.runs.mkdir(parents=True, exist_ok=True)
        path = self.runs / f"{time.strftime('%Y%m%d-%H%M%S')}-{time.time_ns()}"
        path.mkdir()
        return path

    def build(self, simulator: str, code_signing: bool = True) -> Path:
        fingerprint = self.fingerprint(simulator, code_signing=code_signing)
        destination = self.builds / fingerprint
        derived = destination / "DerivedData"
        destination.mkdir(parents=True, exist_ok=True)
        command = ["xcodebuild", "build-for-testing", "-project", str(self.root / "ZDEEP/ZDEEP.xcodeproj"), "-scheme", "ZDEEP", "-destination", f"platform=iOS Simulator,id={simulator}", "-derivedDataPath", str(derived)]
        if code_signing:
            command.extend(["CODE_SIGNING_ALLOWED=YES", "CODE_SIGN_IDENTITY=-"])
        else:
            command.append("CODE_SIGNING_ALLOWED=NO")
        self.runner(command, cwd=self.root, check=True)
        xctestruns = sorted(
            path for path in (derived / "Build/Products").glob("*.xctestrun")
            if "-zdeep-run-" not in path.name
        )
        if not xctestruns:
            raise BuildError("xcodebuild завершился без .xctestrun")
        metadata = {
            "fingerprint": fingerprint,
            "xctestrun": str(xctestruns[-1].relative_to(self.root)),
            "simulator": simulator,
            "codeSigning": code_signing,
        }
        (destination / "build.json").write_text(json.dumps(metadata, indent=2))
        self.cache[fingerprint] = xctestruns[-1]
        return xctestruns[-1]

    @staticmethod
    def _configure_xctestrun(source: Path, destination: Path, runtime_settings: dict[str, str]) -> None:
        data = plistlib.loads(source.read_bytes())

        def visit(value):
            if isinstance(value, dict):
                if "TestBundlePath" in value:
                    variables = dict(value.get("EnvironmentVariables", {}))
                    variables.update({key: setting for key, setting in runtime_settings.items()
                                      if key != "ZDEEP_PASSIVE_TEST_HOST"})
                    bundle_name = Path(str(value["TestBundlePath"])).name
                    if bundle_name == "ZDEEPTests.xctest" and runtime_settings.get("ZDEEP_PASSIVE_TEST_HOST") == "1":
                        variables["ZDEEP_PASSIVE_TEST_HOST"] = "1"
                    value["EnvironmentVariables"] = variables
                for nested in value.values():
                    visit(nested)
            elif isinstance(value, list):
                for nested in value:
                    visit(nested)

        visit(data)
        destination.write_bytes(plistlib.dumps(data))

    @staticmethod
    def validate_test_report(report: dict, only: str | None = None) -> list[dict]:
        if not isinstance(report, dict) or not isinstance(report.get("testNodes"), list):
            raise BuildError("xcresult содержит некорректный отчёт тестов")
        nodes = []

        def visit(node):
            if not isinstance(node, dict):
                raise BuildError("xcresult содержит некорректный узел тестов")
            nodes.append(node)
            children = node.get("children", [])
            if not isinstance(children, list):
                raise BuildError("xcresult содержит некорректный список тестов")
            for child in children:
                visit(child)

        for node in report.get("testNodes", []):
            visit(node)

        test_cases = [node for node in nodes if node.get("nodeType") == "Test Case"]
        valid_results = {"Passed", "Failed", "Expected Failure", "Skipped"}
        for node in test_cases:
            result = node.get("result")
            if not isinstance(result, str) or result not in valid_results:
                raise BuildError("xcresult содержит некорректный результат теста")
        failed = [node for node in test_cases if node.get("result") == "Failed"]
        if failed:
            raise BuildError(f"xcresult содержит Failed: {failed[0].get('nodeIdentifier', '<unknown>')}")
        skipped = [node for node in test_cases if node.get("result") == "Skipped"]
        if skipped:
            raise BuildError(f"xcresult содержит неожиданный Skipped: {skipped[0].get('nodeIdentifier', '<unknown>')}")
        executed = [
            node for node in test_cases
            if node.get("result") in {"Passed", "Failed", "Expected Failure"}
        ]
        if not executed:
            raise BuildError("xcresult содержит ноль выполненных тестов для выбранного набора")
        if only is not None:
            selected = [node for node in executed if node.get("nodeIdentifier") == only]
            if len(selected) != 1:
                raise BuildError(f"--only {only!r} не совпал с ровно одним тестом в xcresult")
            if len(executed) != 1:
                raise BuildError(f"Для --only ожидался ровно один выбранный тест; выполнено: {len(executed)}")
        return executed

    def _validate_result_bundle(self, result_bundle: Path, only: str | None = None) -> list[dict]:
        command = ["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", str(result_bundle)]
        try:
            result = self.runner(command, cwd=self.root, check=True, capture_output=True, text=True)
        except subprocess.CalledProcessError as exc:
            raise BuildError(
                f"Не удалось прочитать xcresult {result_bundle}: "
                f"xcresulttool завершился с кодом {exc.returncode}"
            ) from exc
        try:
            report = json.loads(result.stdout)
        except (AttributeError, json.JSONDecodeError) as exc:
            raise BuildError(f"xcresulttool вернул некорректный JSON для {result_bundle}: {exc}") from exc
        return self.validate_test_report(report, only)

    def run(self, suite: str, environment: str, simulator: str, only: str | None = None, skip_build: bool = False, runtime_settings: dict[str, str] | None = None) -> Path:
        if suite not in {"unit", "integration", "ui", "all"}:
            raise BuildError(f"Неизвестный набор тестов: {suite}")
        if environment != "local":
            raise BuildError("Тестовый запуск разрешён только для local")
        result_only = only
        integration_selector = None
        if only is not None and suite == "integration":
            target_prefix = "ZDEEPTests/"
            result_only = only.removeprefix(target_prefix)
            integration_prefix = "WebSessionIntegrationTests/"
            if not result_only.startswith(integration_prefix) or len(result_only) == len(integration_prefix):
                raise BuildError("--only для integration не принадлежит WebSessionIntegrationTests")
            integration_selector = f"{target_prefix}{result_only}"
        elif only is not None and suite == "unit":
            result_only = only.removeprefix("ZDEEPTests/")
        code_signing = True
        fingerprint = self.fingerprint(simulator, code_signing=code_signing)
        if skip_build:
            artifact = self.cache.get(fingerprint)
            if artifact is None:
                for metadata_path in self.builds.glob("*/build.json"):
                    metadata = json.loads(metadata_path.read_text())
                    if metadata.get("fingerprint") == fingerprint:
                        candidate = self.root / metadata["xctestrun"]
                        if candidate.is_file():
                            artifact = candidate
                            break
            if artifact is None:
                raise BuildError(
                    f"Нет актуальной подписанной Simulator-сборки для {suite}/local; "
                    "запустите `build-tests` или `test` без `--skip-build`"
                )
        else:
            artifact = self.build(simulator, code_signing=code_signing)

        results = self.new_results_directory()
        # Xcode resolves __TESTROOT__ and related markers relative to the
        # .xctestrun file. Keep the configured copy beside the original in
        # Build/Products; only the result bundle belongs in the run directory.
        configured = artifact.with_name(f"{artifact.stem}-zdeep-run-{results.name}.xctestrun")
        settings = runtime_settings or {"ZDEEP_ENVIRONMENT": environment}
        if suite in {"unit", "integration", "all"}:
            settings = {**settings, "ZDEEP_PASSIVE_TEST_HOST": "1"}
        self._configure_xctestrun(artifact, configured, settings)
        command = ["xcodebuild", "test-without-building", "-xctestrun", str(configured), "-destination", f"platform=iOS Simulator,id={simulator}", "-resultBundlePath", str(results / "Tests.xcresult")]
        selectors = {
            "unit": ["ZDEEPTests"],
            "integration": ["ZDEEPTests/WebSessionIntegrationTests"],
            "ui": ["ZDEEPUITests"],
            "all": ["ZDEEPTests", "ZDEEPUITests"],
        }[suite]
        if integration_selector is not None:
            # Swift Testing's xcresult nodeIdentifier omits the target name;
            # xcodebuild selectors include it.
            selectors = [integration_selector]
        for target in selectors:
            if suite == "unit":
                command.append("-skip-testing:ZDEEPTests/WebSessionIntegrationTests")
            selected_target = target if integration_selector is not None else target + ("/" + result_only if result_only else "")
            command.append(f"-only-testing:{selected_target}")
        try:
            self.runner(command, cwd=self.root, check=True)
        except subprocess.CalledProcessError as exc:
            raise BuildError(
                f"xcodebuild test завершился с кодом {exc.returncode}; "
                f"run: {results}; result bundle: {results / 'Tests.xcresult'}"
            ) from exc
        self._validate_result_bundle(results / "Tests.xcresult", result_only)
        return results
