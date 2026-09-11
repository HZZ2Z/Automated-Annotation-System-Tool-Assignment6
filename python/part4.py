"""Part 4 file handoff CLI. Godot owns business operations; Python validates packages."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

from annotation_data.training_package import validate_training_package

ROOT = Path(__file__).resolve().parents[1]
KINDS = {"training": "training_update_v2", "review": "review_export_v1",
         "training_update_v2": "training_update_v2", "review_export_v1": "review_export_v1"}


class Parser(argparse.ArgumentParser):
    def error(self, message):
        raise ValueError(message)


def parse_args(argv=None):
    parser = Parser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    demo = sub.add_parser("demo", help="Run synthetic edits, autosave, reopen, packages and simulated round import")
    demo.add_argument("--output", type=Path, required=True, help="New output directory; existing content is preserved")
    demo.add_argument("--prepare-only", action="store_true", help="Keep saved round1 and prepare a simulated round2 return for UI replay")
    export = sub.add_parser("export", help="Export a saved V3 session through the GUI package service")
    export.add_argument("--session", type=Path, required=True)
    export.add_argument("--output", type=Path, required=True)
    export.add_argument("--kind", choices=KINDS, default="training")
    validate = sub.add_parser("validate-package", help="Independently validate training/review package artifacts")
    validate.add_argument("directory", type=Path)
    ingest = sub.add_parser("import-round", help="Validate a model return, archive old V3 and replace active session")
    ingest.add_argument("--session", type=Path, required=True)
    ingest.add_argument("--input", type=Path, required=True)
    ingest.add_argument("--parent-package", type=Path, required=True)
    return parser.parse_args(argv)


def run_godot(options: dict) -> dict:
    godot = os.environ.get("GODOT_BIN") or shutil.which("godot4") or shutil.which("godot")
    if not godot:
        raise ValueError("Godot is unavailable; source project_env.sh or set GODOT_BIN")
    with tempfile.TemporaryDirectory(prefix="project6-part4-") as directory:
        temp = Path(directory)
        request, result = temp / "request.json", temp / "result.json"
        request.write_text(json.dumps(options, ensure_ascii=False), encoding="utf-8")
        process = subprocess.run(
            [godot, "--headless", "--path", str(ROOT), "--log-file", str(temp / "godot.log"),
             "--script", "res://client/cli/part4_runner.gd", "--", str(request), str(result)],
            cwd=ROOT, capture_output=True, text=True, timeout=300,
        )
        if not result.is_file():
            raise ValueError(f"Godot runner failed ({process.returncode}): {(process.stderr or process.stdout)[-6000:]}")
        payload = json.loads(result.read_text(encoding="utf-8"))
        if process.returncode != 0 and payload.get("success"):
            raise ValueError(f"Godot exited {process.returncode} despite a successful result")
        return payload


def main(argv=None) -> int:
    try:
        args = parse_args(argv)
        options = {k: str(v.absolute()) if isinstance(v, Path) else v for k, v in vars(args).items()}
        if args.command == "validate-package":
            errors = validate_training_package(args.directory)
            result = {"success": not errors, "errors": errors, "directory": options["directory"]}
        else:
            if args.command == "export":
                options["kind"] = KINDS[options["kind"]]
            # The return parent gets independent semantic validation before Godot's
            # transactional identity/integrity validation. No annotations are rewritten.
            if args.command == "import-round":
                errors = validate_training_package(args.parent_package)
                if errors:
                    raise ValueError("Invalid parent package: " + "; ".join(errors))
            result = run_godot(options)
            if result.get("success") and args.command in {"demo", "export"}:
                paths = [result["training_package"], result["review_package"]] if args.command == "demo" else [result["output_path"]]
                errors = [f"{path}: {error}" for path in paths for error in validate_training_package(path)]
                result["independent_validation"] = not errors
                result["errors"].extend(errors)
                result["success"] = not errors
            if args.command == "demo" and result.get("success"):
                evidence = args.output / "evidence.json"
                result["evidence_path"] = str(evidence.absolute())
                evidence.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    except (ValueError, OSError, subprocess.TimeoutExpired) as exc:
        result = {"success": False, "errors": [str(exc)]}
    print(json.dumps(result, ensure_ascii=False))
    return 0 if result.get("success") else 1


if __name__ == "__main__":
    raise SystemExit(main())
