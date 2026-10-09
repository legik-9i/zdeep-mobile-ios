#!/usr/bin/env python3
"""Reproducible build and test commands for ZDEEP."""

import argparse
import json
import subprocess
import sys
from pathlib import Path

from zdeep_tools.build import BuildError, BuildManager
from zdeep_tools.diagnostics import DiagnosticError, DiagnosticManager, load_javascript
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
    test = commands.add_parser("test", help="Запустить автоматические тесты в local")
    test.add_argument("--environment", choices=["local"], required=True)
    test.add_argument("--suite", choices=["unit", "integration", "ui", "all"], required=True)
    test.add_argument("--only", help="nodeIdentifier из xcresult, например WebSessionIntegrationTests/test_example()")
    test.add_argument("--skip-build", action="store_true")
    test.add_argument("--simulator", help="UDID, переопределяет конфигурацию")
    pre = commands.add_parser("preflight", help="Проверить доступность выбранного API")
    pre.add_argument("--environment", choices=["local"], required=True)
    pre.add_argument("--suite", choices=["unit", "integration", "ui", "all"], default="integration")
    install = commands.add_parser("device-install", help="Собрать Debug и установить его на iPhone")
    install.add_argument("--device", help="UDID устройства; по умолчанию берётся из .local/development.json")
    launch = commands.add_parser("device-launch", help="Запустить Debug в test с USB mailbox")
    launch.add_argument("--device", help="UDID устройства; по умолчанию берётся из .local/development.json")
    launch.add_argument("--environment", choices=["test"], default="test")
    sim_launch = commands.add_parser("simulator-launch", help="Запустить Debug с mailbox на симуляторе")
    sim_launch.add_argument("--simulator", help="UDID симулятора; по умолчанию берётся из .local/development.json")
    sim_launch.add_argument("--environment", choices=["local", "test"], default="local")
    diagnose = commands.add_parser("diagnose", help="Выполнить JavaScript через файловый mailbox")
    diagnose.add_argument("--target", choices=["simulator", "device"], required=True)
    diagnose.add_argument("--simulator", help="UDID симулятора")
    diagnose.add_argument("--device", help="UDID устройства")
    diagnose.add_argument("--environment", choices=["local", "test"], default="local")
    js_source = diagnose.add_mutually_exclusive_group(required=True)
    js_source.add_argument("--js", help="JavaScript как аргумент (может попасть в shell history и список процессов)")
    js_source.add_argument("--js-file", type=Path, help="Прочитать JavaScript из файла")
    js_source.add_argument("--js-stdin", action="store_true", help="Прочитать JavaScript из stdin")
    diagnose.add_argument("--timeout", type=float, default=30, help="Тайм-аут ожидания, до 300 секунд")
    logs = commands.add_parser("logs", help="Скопировать фильтрованный журнал приложения")
    logs.add_argument("--target", choices=["simulator", "device"], required=True)
    logs.add_argument("--simulator", help="UDID симулятора")
    logs.add_argument("--device", help="UDID устройства")
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
        elif args.command in {"device-install", "device-launch"}:
            device = args.device or config.get("device")
            if not device:
                raise DiagnosticError("Укажите --device или device в .local/development.json")
            manager = DiagnosticManager(ROOT)
            if args.command == "device-install":
                print(f"Установлено: {manager.device_install(device)}")
            else:
                manager.device_launch(device, args.environment)
                print("Приложение запущено в test. Откройте WebView вручную для диагностики.")
        elif args.command == "simulator-launch":
            simulator = args.simulator or config.get("simulator")
            if not simulator:
                raise DiagnosticError("Укажите --simulator или simulator в .local/development.json")
            if args.environment == "local":
                print(preflight("local", "integration", config["api"]["local"]))
            DiagnosticManager(ROOT).simulator_launch(
                simulator, args.environment,
                config["web"][args.environment], config["api"][args.environment]
            )
            print(f"Симулятор запущен в {args.environment}; откройте WebView вручную.")
        elif args.command == "diagnose":
            javascript = load_javascript(
                inline=args.js,
                source_file=args.js_file,
                source_stream=sys.stdin if args.js_stdin else None,
            )
            target_id = (args.simulator or config.get("simulator")) if args.target == "simulator" else (args.device or config.get("device"))
            if not target_id:
                raise DiagnosticError(f"Укажите {'--simulator' if args.target == 'simulator' else '--device'} или настройте .local/development.json")
            if args.target == "device" and args.environment != "test":
                raise DiagnosticError("Диагностика физического устройства разрешена только в test")
            if args.target == "simulator" and args.environment == "local":
                print(preflight("local", "integration", config["api"]["local"]))
            response = DiagnosticManager(ROOT).diagnose(
                args.target, target_id, javascript, args.timeout,
                environment=args.environment,
                web_url=config["web"][args.environment],
                api_url=config["api"][args.environment],
            )
            print(json.dumps(response, ensure_ascii=False, indent=2))
            if not response["ok"]:
                return 1
        elif args.command == "logs":
            target_id = (args.simulator or config.get("simulator")) if args.target == "simulator" else (args.device or config.get("device"))
            if not target_id:
                raise DiagnosticError(f"Укажите {'--simulator' if args.target == 'simulator' else '--device'} или настройте .local/development.json")
            print(DiagnosticManager(ROOT).logs(args.target, target_id), end="")
    except subprocess.CalledProcessError as exc:
        print(f"Ошибка: xcodebuild завершился с кодом {exc.returncode}", file=sys.stderr)
        return 1
    except (BuildError, DiagnosticError, PreflightError, OSError, json.JSONDecodeError) as exc:
        print(f"Ошибка: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
