# Part 4 文件交接 CLI:Godot 端负责全部业务操作,Python 端只负责独立校验。
#
# 用途:为 V3 审核会话交接提供四个子命令——
#   demo:             运行合成编辑、autosave、重开、导出包并模拟新轮次导入的完整演示;
#   export:           经 Godot GUI 的包服务,把已保存的 V3 会话导出为训练包或评审包;
#   validate-package: 纯 Python 独立校验 training_update_v2 / review_export_v1 包工件;
#   import-round:     校验模型回传轮次后,归档旧 V3 会话并替换为活动会话。
#
# 输入/输出:除 validate-package 完全在 Python 内完成外,其余子命令把参数序列化为
# request.json 交给 headless Godot(client/cli/part4_runner.gd)执行并读回 result.json;
# 最终向 stdout 打印一行 JSON 结果(demo 成功时还会把同一结果写入 --output/evidence.json)。
# 退出码:成功 0,失败 1;预期错误全部折叠进结果 JSON 的 errors 字段。
#
# 典型运行方式(需先 source project_env.sh 提供 GODOT_BIN,见 docs/Part 4 设计与复现/part4-review.md):
#   .venv/bin/python python/part4.py demo --output test/part4-review
#   .venv/bin/python python/part4.py validate-package PACKAGE_DIRECTORY
#   .venv/bin/python python/part4.py export --session SESSION_V3_JSON --output OUT_DIR --kind training
#   .venv/bin/python python/part4.py import-round --session V3_JSON --input ROUND_MANIFEST --parent-package PKG_DIR
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

# 仓库根目录:作为 Godot 的 --path 工程根,保证 runner 以本工程身份启动。
ROOT = Path(__file__).resolve().parents[1]
# 包类型别名 → 规范名:CLI 的 --kind 接受简写 training/review 或规范包类型名,
# 发送给 Godot 前统一归一化为规范名(见 main 的 export 分支)。
KINDS = {
    "training": "training_update_v2",
    "review": "review_export_v1",
    "training_update_v2": "training_update_v2",
    "review_export_v1": "review_export_v1",
    "training_coco_v1": "training_coco_v1",
}


# argparse 子类:把用法错误(缺必填参数、非法取值等)从默认的"打印后退出 2"
# 改为抛 ValueError,让 main() 统一捕获并折叠为退出码 1 的失败结果。
class Parser(argparse.ArgumentParser):
    # 参数 message:argparse 生成的用法错误描述;原样包装成 ValueError 上抛。
    def error(self, message):
        raise ValueError(message)


# 定义并解析四个子命令的参数;参数 argv 为 None 时使用 sys.argv[1:]。
# 返回 argparse.Namespace;vars() 展开即构造请求字段(Path 值由 main 统一
# 转为绝对路径字符串)。
# 抛出 ValueError:用法错误经 Parser.error 改写后上抛,不再直接退出进程。
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
    export.add_argument(
        "--task",
        choices=("detection", "instance_segmentation"),
        default="detection",
    )
    export.add_argument("--source-root", type=Path)
    export.add_argument(
        "--frame",
        dest="frames",
        type=int,
        action="append",
        help="Include one content-verified source frame; repeat to select a subset",
    )
    export.add_argument("--segmentation-attested", action="store_true")
    export.add_argument("--allow-box-only-fallback", action="store_true")
    validate = sub.add_parser("validate-package", help="Independently validate training/review package artifacts")
    validate.add_argument("directory", type=Path)
    ingest = sub.add_parser("import-round", help="Validate a model return, archive old V3 and replace active session")
    ingest.add_argument("--session", type=Path, required=True)
    ingest.add_argument("--input", type=Path, required=True)
    ingest.add_argument("--parent-package", type=Path, required=True)
    return parser.parse_args(argv)


def _strict_json(path: Path):
    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                raise ValueError(f"duplicate JSON key: {key}")
            result[key] = value
        return result

    def constant(value):
        raise ValueError(f"nonfinite JSON number: {value}")

    return json.loads(
        path.read_text(encoding="utf-8"),
        object_pairs_hook=pairs,
        parse_constant=constant,
    )


def validate_supported_package(directory: Path) -> tuple[str, list[str], list[dict]]:
    """Select a frozen validator by the package's declared type."""

    package_type = ""
    try:
        manifest = _strict_json(directory / "manifest.json")
        if isinstance(manifest, dict) and isinstance(manifest.get("package_type"), str):
            package_type = manifest["package_type"]
    except (OSError, UnicodeError, ValueError, json.JSONDecodeError):
        pass
    if package_type == "training_coco_v1":
        from annotation_data.coco_package_validator import validate_coco_package

        issues = validate_coco_package(directory)
        errors = [f"{item['code']}: {item['message']}" for item in issues]
        return package_type, errors, issues
    errors = validate_training_package(directory)
    issues = [{"code": "PACKAGE_INVALID", "message": message} for message in errors]
    return package_type, errors, issues


def export_training_coco(args: argparse.Namespace) -> dict:
    if args.source_root is None:
        raise ValueError("--source-root is required for --kind training_coco_v1")
    from annotation_data.coco_export import build_endoscapes_context
    from annotation_data.coco_package import export_coco_package

    snapshot = _strict_json(args.session)
    if not isinstance(snapshot, dict):
        raise ValueError("Session document must be a JSON object")
    context = build_endoscapes_context(
        snapshot,
        args.source_root,
        task=args.task,
        selected_frame_ids=args.frames,
        segmentation_attested=args.segmentation_attested,
        allow_box_only_fallback=args.allow_box_only_fallback,
    )
    result = export_coco_package(context, args.output)
    if result.get("success"):
        package_type, errors, issues = validate_supported_package(
            Path(result["output_path"])
        )
        result["independent_validation"] = not errors
        if errors:
            result["success"] = False
            result.setdefault("errors", []).extend(errors)
            result.setdefault("issues", []).extend(issues)
        if package_type != "training_coco_v1":
            raise ValueError("COCO exporter produced an unexpected package type")
    return result


# 子进程封装:调起 headless Godot 执行一次业务操作。
# 参数 options:发给 Godot 的请求字典(含 command 及该子命令的全部参数)。
# 返回:result.json 解析出的结果字典(约定含 success 与 errors 字段)。
# 副作用:在专用临时目录写 request.json,由 Godot 写 result.json 与 godot.log,
#         with 块退出时整体删除;Godot 以仓库根为工程路径运行 part4_runner.gd。
# 抛出 ValueError:找不到 Godot 可执行文件;runner 未产出 result.json(附带
#         stderr/stdout 末尾 6000 字符帮助定位);退出码非 0 却声称成功。
# 子进程 300 秒超时:TimeoutExpired 由 main 捕获并折叠为失败结果。
def run_godot(options: dict) -> dict:
    godot = os.environ.get("GODOT_BIN") or shutil.which("godot4") or shutil.which("godot")
    if not godot:
        raise ValueError("Godot is unavailable; source project_env.sh or set GODOT_BIN")
    with tempfile.TemporaryDirectory(prefix="project6-part4-") as directory:
        temp = Path(directory)
        request, result = temp / "request.json", temp / "result.json"
        request.write_text(json.dumps(options, ensure_ascii=False), encoding="utf-8")
        # "--" 之后是 runner 脚本的用户参数:请求 JSON 路径与结果 JSON 路径。
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


# CLI 主流程:分发子命令,按需调用 Godot,并用 Python 端独立校验器复核产出。
# 参数 argv:命令行参数;None 表示使用 sys.argv[1:]。
# 返回退出码:成功 0;任何失败(含捕获的 ValueError/OSError/子进程超时)均为 1。
# 副作用:向 stdout 打印一行结果 JSON(ensure_ascii=False);demo 成功时把
#         同一结果字典写进 --output/evidence.json(UTF-8、缩进、结尾换行)。
def main(argv=None) -> int:
    try:
        args = parse_args(argv)
        options = {k: str(v.absolute()) if isinstance(v, Path) else v for k, v in vars(args).items()}
        if args.command == "validate-package":
            package_type, errors, issues = validate_supported_package(args.directory)
            result = {
                "success": not errors,
                "errors": errors,
                "issues": issues,
                "directory": options["directory"],
                "package_type": package_type,
            }
        else:
            if args.command == "export":
                options["kind"] = KINDS[options["kind"]]
                if options["kind"] == "training_coco_v1":
                    result = export_training_coco(args)
                    print(json.dumps(result, ensure_ascii=False))
                    return 0 if result.get("success") else 1
                options = {
                    "command": "export",
                    "session": str(args.session.absolute()),
                    "output": str(args.output.absolute()),
                    "kind": options["kind"],
                }
            # The return parent gets independent semantic validation before Godot's
            # transactional identity/integrity validation. No annotations are rewritten.
            # 失败即中止:父训练包不合法时直接抛 ValueError,不进入 Godot 阶段。
            if args.command == "import-round":
                _package_type, errors, _issues = validate_supported_package(
                    args.parent_package
                )
                if errors:
                    raise ValueError("Invalid parent package: " + "; ".join(errors))
            result = run_godot(options)
            # Godot 报成功后,用独立校验器复核产出的包:demo 复核训练包与评审包,
            # export 复核输出包。复核结论写入 independent_validation 字段,错误
            # 并入 errors,任何复核失败都会把 success 改写为 False。
            if result.get("success") and args.command in {"demo", "export"}:
                paths = [result["training_package"], result["review_package"]] if args.command == "demo" else [result["output_path"]]
                errors = [
                    f"{path}: {error}"
                    for path in paths
                    for error in validate_supported_package(Path(path))[1]
                ]
                result["independent_validation"] = not errors
                result["errors"].extend(errors)
                result["success"] = not errors
            # demo 落地 evidence.json:记录实际文件路径与验证结果,供人工核对与复跑。
            if args.command == "demo" and result.get("success"):
                evidence = args.output / "evidence.json"
                result["evidence_path"] = str(evidence.absolute())
                evidence.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    except (ValueError, OSError, subprocess.TimeoutExpired) as exc:
        result = {"success": False, "errors": [str(exc)]}
    # 唯一的机器可读输出:一行 JSON 结果(至少含 success 与 errors 字段)。
    print(json.dumps(result, ensure_ascii=False))
    return 0 if result.get("success") else 1


if __name__ == "__main__":
    raise SystemExit(main())
