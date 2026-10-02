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

    def fingerprint(self, simulator: str) -> str:
        digest = hashlib.sha256()
        included = (self.root / "ZDEEP", self.root / "scripts")
        for base in included:
            if base.is_file():
                paths = [base]
            elif base.exists():
                paths = sorted(path for path in base.rglob("*") if path.is_file() and ".artifacts" not in path.parts)
            else:
                continue
            for path in paths:
                digest.update(path.relative_to(self.root).as_posix().encode())
                digest.update(path.read_bytes())
        digest.update(json.dumps({"toolchain": self.toolchain, "simulator": simulator, "scheme": "ZDEEP", "configuration": "Debug", "sdk": "iphonesimulator"}, sort_keys=True).encode())
        return digest.hexdigest()

    def new_results_directory(self) -> Path:
        self.runs.mkdir(parents=True, exist_ok=True)
        path = self.runs / f"{time.strftime('%Y%m%d-%H%M%S')}-{time.time_ns()}"
        path.mkdir()
        return path

    def build(self, simulator: str) -> Path:
        fingerprint = self.fingerprint(simulator)
        destination = self.builds / fingerprint
        derived = destination / "DerivedData"
        destination.mkdir(parents=True, exist_ok=True)
        command = ["xcodebuild", "build-for-testing", "-project", str(self.root / "ZDEEP/ZDEEP.xcodeproj"), "-scheme", "ZDEEP", "-destination", f"platform=iOS Simulator,id={simulator}", "-derivedDataPath", str(derived), "CODE_SIGNING_ALLOWED=NO"]
        self.runner(command, cwd=self.root, check=True)
        xctestruns = sorted(
            path for path in (derived / "Build/Products").glob("*.xctestrun")
            if "-zdeep-run-" not in path.name
        )
        if not xctestruns:
            raise BuildError("xcodebuild завершился без .xctestrun")
        metadata = {"fingerprint": fingerprint, "xctestrun": str(xctestruns[-1].relative_to(self.root)), "simulator": simulator}
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
                    variables.update(runtime_settings)
                    value["EnvironmentVariables"] = variables
                for nested in value.values():
                    visit(nested)
            elif isinstance(value, list):
                for nested in value:
                    visit(nested)

        visit(data)
        destination.write_bytes(plistlib.dumps(data))

    def run(self, suite: str, environment: str, simulator: str, only: str | None = None, skip_build: bool = False, runtime_settings: dict[str, str] | None = None) -> Path:
        if suite not in {"unit", "integration", "ui", "all"}:
            raise BuildError(f"Неизвестный набор тестов: {suite}")
        if environment not in {"local", "test"}:
            raise BuildError("Тестовый запуск разрешён только для local или test")
        fingerprint = self.fingerprint(simulator)
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
                raise BuildError("Нет актуальной сборки для этих исходников; выполните build-tests")
        else:
            artifact = self.build(simulator)

        results = self.new_results_directory()
        # Xcode resolves __TESTROOT__ and related markers relative to the
        # .xctestrun file. Keep the configured copy beside the original in
        # Build/Products; only the result bundle belongs in the run directory.
        configured = artifact.with_name(f"{artifact.stem}-zdeep-run-{results.name}.xctestrun")
        self._configure_xctestrun(artifact, configured, runtime_settings or {"ZDEEP_ENVIRONMENT": environment})
        command = ["xcodebuild", "test-without-building", "-xctestrun", str(configured), "-destination", f"platform=iOS Simulator,id={simulator}", "-resultBundlePath", str(results / "Tests.xcresult")]
        selectors = {
            "unit": [("only", "ZDEEPTests")],
            "integration": [("only", "ZDEEPTests/WebSessionIntegrationTests")],
            "ui": [("only", "ZDEEPUITests")],
            "all": [("only", "ZDEEPTests"), ("only", "ZDEEPUITests")],
        }[suite]
        for kind, target in selectors:
            if suite == "unit":
                command.append("-skip-testing:ZDEEPTests/WebSessionIntegrationTests")
            selected_target = target + ("/" + only if only else "")
            command.append(f"-{kind}-testing:{selected_target}")
        self.runner(command, cwd=self.root, check=True)
        return results
