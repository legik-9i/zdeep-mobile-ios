#!/usr/bin/env python3
"""Reproducible build and test commands for ZDEEP."""

import argparse
import json
import subprocess
import sys
from pathlib import Path

from zdeep_tools.build import BuildError, BuildManager
from zdeep_tools.preflight import PreflightError, preflight

ROOT = Path(__file__).resolve().parent.parent
DEFAULTS = {
    "web": {
        "local": "http://localhost:4005",
        "test": "https://5e9afe68-2ddd-4e58-8e57-5942cfa16099.website.twcstorage.ru",
        "prod": "https://webview2.zdeep.ru",
    },
    "api": {
        "local": "http://localhost:4002",
        "test": "https://api.zdeep.ru/testing/",
        "prod": "https://api.zdeep.ru",
    }
}


def load_config():
    config_path = ROOT / ".local" / "development.json"
    if config_path.exists():
        user = json.loads(config_path.read_text())
    else:
        user = {}
    return {
        "simulator": user.get("simulator"),
        "device": user.get("device"),
        "web": {**DEFAULTS["web"], **user.get("web", {})},
        "api": {**DEFAULTS["api"], **user.get("api", {})},
    }


def parser():
    root = argparse.ArgumentParser(prog="zdeep.py")
    commands = root.add_subparsers(dest="command", required=True)
    build = commands.add_parser("build-tests", help="Собрать тестовые targets")
    build.add_argument("--simulator", required=True, help="UDID симулятора")
    test = commands.add_parser("test", help="Запустить тесты local или test")
    test.add_argument("--environment", choices=["local", "test"], required=True)
    test.add_argument("--suite", choices=["unit", "integration", "ui", "all"], required=True)
    test.add_argument("--only", help="Полный nodeIdentifier из xcresult, например ZDEEPTests/example() или MyTests/testExample")
    test.add_argument("--skip-build", action="store_true")
    test.add_argument("--simulator", help="UDID, переопределяет конфигурацию")
    pre = commands.add_parser("preflight", help="Проверить доступность выбранного API")
    pre.add_argument("--environment", choices=["local", "test"], required=True)
    pre.add_argument("--suite", choices=["unit", "integration", "ui", "all"], default="integration")
    return root


def main(argv=None):
    args = parser().parse_args(argv)
    config = load_config()
    try:
        if args.command == "build-tests":
            artifact = BuildManager(ROOT).build(args.simulator)
            print(f"Тестовая сборка сохранена: {artifact}")
        elif args.command == "preflight":
            if args.suite == "unit":
                print("Для unit-набора проверка доступности API не требуется")
            else:
                print(preflight(args.environment, args.suite, config["api"][args.environment]))
        elif args.command == "test":
            simulator = args.simulator or config.get("simulator")
            if not simulator:
                raise BuildError("Укажите --simulator или simulator в .local/development.json")
            if args.suite == "unit":
                print("Для unit-набора проверка доступности API не требуется")
            else:
                print(preflight(args.environment, args.suite, config["api"][args.environment]))
            runtime_settings = {
                "ZDEEP_ENVIRONMENT": args.environment,
                "ZDEEP_WEB_URL": config["web"][args.environment],
                "ZDEEP_API_URL": config["api"][args.environment],
            }
            results = BuildManager(ROOT).run(args.suite, args.environment, simulator, args.only, args.skip_build, runtime_settings)
            print(f"Результаты: {results}")
    except subprocess.CalledProcessError as exc:
        print(f"Ошибка: xcodebuild завершился с кодом {exc.returncode}", file=sys.stderr)
        return 1
    except (BuildError, PreflightError, OSError, json.JSONDecodeError) as exc:
        print(f"Ошибка: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
