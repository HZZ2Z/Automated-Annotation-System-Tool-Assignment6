# polygon 传播后台 worker:由 Godot 客户端(client/services/
# polygon_propagation_service.gd)作为独立进程调起,对不可变 PNG 快照运行
# 有界 polygon 传播(poly-sim-flow-edge-v1),产出候选 region 的连续闭区间。
#
# 文件协议(进程间唯一交互方式,四个路径均必填):
#   --request       请求 JSON(schema_version 3:frames 快照清单 + 关键帧 regions);
#   --result        结果 JSON(成功含 proposals/left_stop/right_stop 等,失败含 error);
#   --cancel-file   取消哨兵:文件存在即表示请求取消,worker 轮询并尽快中止;
#   --progress-file 进度 JSON({"completed","total","message"}),原子写入。
# 所有输入(请求文件与 PNG 快照)全程只读;输出路径与输入路径冲突时拒绝运行。
# 退出码:0 成功;1 失败(含用法错误、路径冲突、请求非法、结果写失败);130 已取消。
#
# 典型运行方式(通常由 Godot 服务在其任务目录中自动调起):
#   .venv/bin/python python/propagate_polygons.py --request req.json \
#       --result result.json --cancel-file cancel --progress-file progress.json
#
# 协作模块:annotation_data.polygon_propagation.propagate(传播核心:请求校验、
# 相似度门禁、光流候选、边缘精修)。
"""Run bounded polygon propagation against immutable PNG snapshots."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import sys
import tempfile

from annotation_data.polygon_propagation import propagate


# 输出路径冲突异常:四个协议路径互相重复,或 result/progress 路径与某帧输入
# 图像是同一文件时抛出;此时不执行分析,也绝不写任何输出文件。
class OutputCollision(ValueError):
    """错误结果也不能写入受保护输入路径。"""


# 路径门禁:确保 worker 不会把输出写进受保护的输入位置。
# 参数 args:已解析的 CLI 参数(含 request/result/cancel_file/progress_file);
#       request:可选的已解析请求字典,提供时追加检查每帧的 image_path。
# 行为:1) 四个路径 resolve() 后必须互不相同;2) 任何一帧 image_path 解析后
#       不得等于 result 或 progress 路径(request/cancel 不参与这项比对)。
# 抛出 OutputCollision:任一条件不满足。
def _check_output_paths(args, request=None):
    named = [args.request, args.result, args.cancel_file, args.progress_file]
    resolved = [path.resolve() for path in named]
    if len(set(resolved)) != len(resolved):
        raise OutputCollision("request, result, cancel and progress paths must be distinct")
    if isinstance(request, dict) and isinstance(request.get("frames"), list):
        for frame in request["frames"]:
            if isinstance(frame, dict) and isinstance(frame.get("image_path"), str):
                image = Path(frame["image_path"]).resolve()
                if image in (resolved[1], resolved[3]):
                    raise OutputCollision("result or progress path aliases an input image")


# 参数 path:目标文件;payload:可 JSON 序列化的字典。
# 抛出 ValueError(payload 含 NaN/Infinity)、TypeError(payload 含不可序列化
#     对象)或 OSError(磁盘/权限)。
def atomic_json(path: Path, payload: dict) -> None:
    """同目录临时文件写完后替换，调用方只能观察到完整 JSON。"""
    temporary = None
    try:
        # 临时文件建在目标同目录:与目标同处一个文件系统,替换才具备原子性。
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=path.parent,
                                         prefix=f".{path.name}.", suffix=".tmp", delete=False) as stream:
            temporary = Path(stream.name)
            # allow_nan=False:payload 一旦含 NaN/Infinity 就直接失败,绝不写出损坏 JSON。
            json.dump(payload, stream, ensure_ascii=False, allow_nan=False, separators=(",", ":"))
            stream.write("\n")
            # flush + fsync:内容确认落盘后才允许替换,崩溃也不会留下半截文件。
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    # 兜底清理:无论成功失败都尝试删除临时文件(成功时已被改名,此处幂等)。
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


# json.loads 的 parse_constant 钩子:请求 JSON 出现 NaN/Infinity/-Infinity 即拒绝。
def _reject_constant(value):
    raise ValueError(f"non-finite JSON number: {value}")


# json.loads 的 object_pairs_hook:JSON 对象出现重复字段名即拒绝,
# 杜绝"同名键后者静默覆盖前者"的歧义输入。
# 参数 items:单个 JSON 对象的 (键, 值) 对列表;按原顺序构造字典返回。
def _unique_fields(items):
    result = {}
    for key, value in items:
        if key in result:
            raise ValueError(f"duplicate JSON field: {key}")
        result[key] = value
    return result


# worker 主流程:解析参数 → 路径/请求门禁 → 执行传播 → 原子写出结果。
# 参数 argv:命令行参数;None 表示使用 sys.argv[1:]。
# 返回退出码:0 成功;1 失败;130 已取消。
# 副作用:写 result/progress 文件;诊断信息一律走 stderr,不污染协议文件。
# 异常折叠:OutputCollision 直接退出 1 且不写结果;其余请求阶段错误
#         (ValueError/OSError/UnicodeError/RecursionError)折转为
#         schema_version 3 的失败结果字典,仍走统一的原子写出。
def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--request", required=True, type=Path)
    parser.add_argument("--result", required=True, type=Path)
    parser.add_argument("--cancel-file", required=True, type=Path)
    parser.add_argument("--progress-file", required=True, type=Path)
    try:
        args = parser.parse_args(argv)
    except SystemExit as error:
        # argparse 的用法错误默认退出 2；本协议统一使用失败码 1，help 仍为 0。
        return 0 if error.code == 0 else 1
    try:
        # 必须在进度回调和最终结果写入之前检查，原子替换本身不保护输入文件。
        _check_output_paths(args)
        if not args.request.is_file():
            raise ValueError("request JSON must be a regular file")
        # 8 MiB 硬上限:请求只含快照清单与 polygon 坐标,超限即视为异常输入。
        if args.request.stat().st_size > 8 * 1024 * 1024:
            raise ValueError("request JSON exceeds the 8 MiB limit")
        # 严格解析:拒绝 NaN/Infinity 常量与重复字段名(见 _reject_constant/_unique_fields)。
        request = json.loads(args.request.read_text(encoding="utf-8"), parse_constant=_reject_constant, object_pairs_hook=_unique_fields)
        # 解析完成后补一次路径门禁:覆盖 image_path 与输出路径撞车的情况。
        _check_output_paths(args, request)
        # 取消哨兵在启动前就已存在:跳过分析,直接产出"已取消"结果。
        if args.cancel_file.exists():
            result = {"schema_version": 3, "success": False, "cancelled": True, "error": "polygon analysis cancelled"}
        else:
            # propagate 对分析期失败/取消自行折转为结果字典(返回而非抛出);
            # cancelled 是轮询取消哨兵的回调,progress 把 {"completed","total",
            # "message"} 原子写入进度文件,供 UI 实时展示。
            result = propagate(request, cancelled=args.cancel_file.exists,
                               progress=lambda payload: atomic_json(args.progress_file, payload))
    except OutputCollision as error:
        print(f"Cannot write polygon output: {error}", file=sys.stderr)
        return 1
    # 若取消哨兵已出现,则按"已取消"上报失败结果。
    except (ValueError, OSError, UnicodeError, RecursionError) as error:
        is_cancelled = args.cancel_file.exists()
        result = {"schema_version": 3, "success": False, "cancelled": is_cancelled,
                  "error": "polygon analysis cancelled" if is_cancelled else str(error)}
    # 无论成功、失败还是取消,最终结果一律原子写到 --result。
    try:
        atomic_json(args.result, result)
    except (ValueError, OSError) as error:
        print(f"Cannot write polygon result: {error}", file=sys.stderr)
        return 1
    return 130 if result["cancelled"] else (0 if result["success"] else 1)


# 进程入口:以 main() 的返回值作为退出码。
if __name__ == "__main__":
    raise SystemExit(main())
