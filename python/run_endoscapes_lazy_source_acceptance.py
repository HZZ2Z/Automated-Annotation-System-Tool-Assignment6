# ---------------------------------------------------------------------------
# 文件用途:对 Endoscapes 懒加载帧源(endoscapes_video_source)做真实数据集
# 只读验收:驱动 headless Godot 运行 tests/manual/run_endoscapes_lazy_source_acceptance.gd,
# 校验其产出的验收报告,并用前后指纹证明源数据集在验收全程未被修改。
#
# 在项目中的角色:Endoscapes2023 懒加载帧源的自动化验收脚本。Godot 侧负责真实
# 行为(目录扫描、媒体选择、RLE->polygon 门禁转换、纹理 LRU 缓存与切换清理),
# 本脚本负责进程编排、指纹比对与逐项报告校验,失败不静默降级。
#
# 输入:--dataset-root(Endoscapes 数据集根目录,全程只读)、--output(验收输出
#       目录,必须不存在且位于数据集之外)。
# 输出:output/report.json(校验过的报告)、report.md(人工摘要)、godot.log 与
#       godot-process.log(Godot 日志);先写同级 staging,成功后原子改名发布。
# 典型运行方式:
#   source project_env.sh
#   "$PROJECT6_PYTHON" python/run_endoscapes_lazy_source_acceptance.py \
#       --dataset-root Dataset_test/endoscapes \
#       --output .local-acceptance/endoscapes-lazy-source-new
# 退出码:0 成功;1 失败(打印原因)。
# 协作模块:tests/manual/run_endoscapes_lazy_source_acceptance.gd(被驱动的
#           SceneTree 验收脚本);需 GODOT_BIN 环境变量或 PATH 上的 godot4/godot。
# ---------------------------------------------------------------------------
"""Run read-only real-data acceptance for the Endoscapes lazy Source."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import tempfile


# 仓库根目录(本文件位于 python/ 下,parents[1] 即仓库根),Godot 以 --path 指向它。
ROOT = Path(__file__).resolve().parents[1]
# 被 headless Godot 实际执行的 SceneTree 验收脚本,负责真实懒加载行为并产出报告。
RUNNER = ROOT / "tests/manual/run_endoscapes_lazy_source_acceptance.gd"
# 可移植 media_id 的形态:1-64 个字符,首尾必须是字母或数字,中间可含下划线。
MEDIA_ID_PATTERN = re.compile(r"^[A-Za-z0-9](?:[A-Za-z0-9_]{0,62}[A-Za-z0-9])?$")
# 导入统计的四个必需字段:导入区域总数、polygon 数、降级 box 数、跳过数。
STAT_FIELDS = (
    "imported_regions",
    "polygon_regions",
    "box_fallbacks",
    "skipped_regions",
)


# 计算目录树的确定性指纹:每个条目记一行 相对路径、种类(目录/文件/符号链接/
# 其他)、权限位、大小、纳秒级 mtime、符号链接目标,JSON 序列化后喂入 SHA-256。
# 关键约束:不读取任何文件内容,stat(follow_symlinks=False) 不跟随符号链接,
# 条目按原始文件名字节排序,保证结果确定且与平台 locale 无关。
# 验收前后各算一次,用于证明源数据集未被修改。
# 参数:root 必须是真实目录,否则抛 ValueError;返回 64 位小写十六进制摘要。
def fingerprint_tree(root: Path) -> str:
    """Hash names and lstat metadata without reading payloads or following links."""

    root = root.resolve()
    if not root.is_dir():
        raise ValueError("dataset root is not a directory")
    digest = hashlib.sha256()
    # 用手工栈实现深度优先遍历(避免深层目录递归),栈元素为 (绝对路径, 相对路径)。
    pending: list[tuple[Path, str]] = [(root, ".")]
    while pending:
        directory, relative_directory = pending.pop()
        # 目录内条目按原始文件名字节排序,与 locale 无关。
        with os.scandir(directory) as entries:
            ordered = sorted(entries, key=lambda item: os.fsencode(item.name))
        children: list[tuple[Path, str]] = []
        for entry in ordered:
            relative = (
                entry.name
                if relative_directory == "."
                else f"{relative_directory}/{entry.name}"
            )
            metadata = entry.stat(follow_symlinks=False)
            mode = metadata.st_mode
            if stat.S_ISLNK(mode):
                kind = "link"
                target = os.readlink(entry.path)
            elif stat.S_ISDIR(mode):
                kind = "directory"
                target = ""
                children.append((Path(entry.path), relative))
            elif stat.S_ISREG(mode):
                kind = "file"
                target = ""
            else:
                kind = "other"
                target = ""
            # 每个条目的指纹行:相对路径、种类、权限位、大小、纳秒 mtime、链接目标;
            # lstat 语义保证符号链接本身被原样记录,而不会跟随进入目标目录。
            row = (
                relative,
                kind,
                stat.S_IMODE(mode),
                metadata.st_size,
                metadata.st_mtime_ns,
                target,
            )
            digest.update(
                json.dumps(row, ensure_ascii=False, separators=(",", ":")).encode(
                    "utf-8"
                )
            )
            digest.update(b"\n")
        pending.extend(reversed(children))
    return digest.hexdigest()


# 逐项校验 Godot 验收报告,返回错误字符串列表(空列表 = 全部通过,不抛异常)。
# 判据分组:
#   总体:必须是 JSON 对象;可序列化为有限 JSON(禁止 NaN/Infinity);序列化文本
#         不得包含数据集绝对路径(验收报告不记录数据集绝对路径)。
#   完整性:必需字段齐全;缺字段时收集完所有缺失项立即返回。
#   概览:schema_version=1;evidence_type 固定;逻辑视频数恰为 201(真实数据集
#         预期值);media_id 无冲突;catalog 条目不保留任何工作区帧路径;扫描
#         耗时有限非负;扫描至少产生 1 次心跳(证明是异步逐帧扫描)。
#   选中/次要视频:两个 media_id 均可移植且不同;选中视频至少 13 帧且 Source
#         恰好保留其视频全部帧路径、帧号有序;选中视频至少导入 1 个区域且真实
#         走过 RLE 转换或安全 box 降级;次要视频是 box-only 基线(polygon 必须为 0)。
#   纹理与切换:缓存上限恒为 12;加载尝试/成功至少 13 且全部成功;峰值占用在
#         1..12 之间;切换后旧 Source 的帧路径与缓存必须全部归零。
#   追溯:三个哈希字段必须是小写 SHA-256;前后指纹一致;source_dataset_modified
#         必须为 false。
def validate_report(report: object, dataset_root: Path) -> list[str]:
    errors: list[str] = []
    if not isinstance(report, dict):
        return ["report must be a JSON object"]
    try:
    # 报告必须能序列化为有限 JSON(allow_nan=False),否则立即判无效。
        serialized = json.dumps(
            report,
            ensure_ascii=False,
            allow_nan=False,
            sort_keys=True,
            separators=(",", ":"),
        )
    except (TypeError, ValueError) as error:
        return [f"report is not finite JSON: {error}"]
    # 隐私约束:序列化后的报告文本不得包含数据集绝对路径。
    absolute_root = str(dataset_root.resolve())
    if absolute_root and absolute_root in serialized:
        errors.append("report must not contain the absolute dataset path")

    # 必需字段清单,与 Godot 侧 runner 产出的报告字段一一对应;缺字段时收集全部
    # 缺失项后立即返回,避免后续取值抛 KeyError。
    required = {
        "schema_version",
        "evidence_type",
        "logical_video_count",
        "media_id_collisions",
        "media_ids_sha256",
        "workspace_retained_frame_paths",
        "catalog_scan_elapsed_seconds",
        "catalog_scan_heartbeats",
        "selected_media_id",
        "selected_video_frame_count",
        "selected_source_retained_frame_paths",
        "selected_first_frame_id",
        "selected_last_frame_id",
        "selected_import_statistics",
        "secondary_media_id",
        "secondary_video_frame_count",
        "secondary_import_statistics",
        "texture_cache_limit",
        "texture_load_attempt_count",
        "texture_load_success_count",
        "texture_cache_peak",
        "old_source_retained_frame_paths_after_switch",
        "old_source_cache_size_after_switch",
        "source_fingerprint_before",
        "source_fingerprint_after",
        "source_dataset_modified",
    }
    for field in sorted(required - report.keys()):
        errors.append(f"missing report field: {field}")
    if errors:
        return errors

    # 概览判据:版本与证据类型固定;逻辑视频数必须恰为 201;media_id 无冲突;
    # catalog 条目一律不保留工作区帧路径;扫描耗时有限非负,且至少一次心跳。
    if report["schema_version"] != 1:
        errors.append("schema_version must be 1")
    if report["evidence_type"] != "endoscapes-lazy-source-acceptance":
        errors.append("evidence_type is invalid")
    _expect_exact_int(report, "logical_video_count", errors, minimum=201, maximum=201)
    _expect_exact_int(report, "media_id_collisions", errors, minimum=0, maximum=0)
    _expect_exact_int(
        report, "workspace_retained_frame_paths", errors, minimum=0, maximum=0
    )
    _expect_non_negative_number(report, "catalog_scan_elapsed_seconds", errors)
    _expect_exact_int(report, "catalog_scan_heartbeats", errors, minimum=1)
    # 两个 media_id 都必须是可移植 ID,且选中与次要视频不能是同一个。
    for field in ("selected_media_id", "secondary_media_id"):
        value = report[field]
        if not isinstance(value, str) or MEDIA_ID_PATTERN.fullmatch(value) is None:
            errors.append(f"{field} must be a portable media ID")
    if report["selected_media_id"] == report["secondary_media_id"]:
        errors.append("selected and secondary media IDs must differ")

    # 选中视频判据:帧数至少 13;Source 恰好保留其视频全部帧路径(retained ==
    # 帧数,懒加载只保留当前视频);首/末 frame_id 非负且有序(保留 Endoscapes
    # 原始帧号)。
    _expect_exact_int(report, "selected_video_frame_count", errors, minimum=13)
    _expect_exact_int(report, "secondary_video_frame_count", errors, minimum=1)
    _expect_exact_int(report, "selected_source_retained_frame_paths", errors, minimum=1)
    if (
        report["selected_source_retained_frame_paths"]
        != report["selected_video_frame_count"]
    ):
        errors.append("selected Source must retain exactly its selected video frame paths")
    _expect_exact_int(report, "selected_first_frame_id", errors, minimum=0)
    _expect_exact_int(report, "selected_last_frame_id", errors, minimum=0)
    if (
        type(report["selected_first_frame_id"]) is int
        and type(report["selected_last_frame_id"]) is int
        and report["selected_first_frame_id"] > report["selected_last_frame_id"]
    ):
        errors.append("selected frame IDs must be ordered")

    # 两组导入统计:字段齐全、非负整数,且 polygon/box 分量不得超过导入总数。
    # 选中视频必须导入至少一个区域,且至少发生一次 RLE->polygon 转换或安全
    # box 降级(polygon+fallback > 0),证明真实数据走过了几何门禁路径;
    # 次要视频是 box-only 基线:至少导入一个区域且 polygon 数必须为 0。
    for group in ("selected_import_statistics", "secondary_import_statistics"):
        _validate_statistics(report[group], group, errors)
    selected_statistics = report["selected_import_statistics"]
    if isinstance(selected_statistics, dict):
        if selected_statistics.get("imported_regions", 0) <= 0:
            errors.append("selected video must import at least one region")
        if (
            selected_statistics.get("polygon_regions", 0)
            + selected_statistics.get("box_fallbacks", 0)
            <= 0
        ):
            errors.append("selected video must exercise RLE conversion or safe fallback")
    secondary_statistics = report["secondary_import_statistics"]
    if isinstance(secondary_statistics, dict):
        if secondary_statistics.get("imported_regions", 0) <= 0:
            errors.append("secondary video must import at least one box region")
        if secondary_statistics.get("polygon_regions") != 0:
            errors.append("secondary video must exercise the box-only baseline")

    # 纹理与切换判据:LRU 缓存上限恒为 12;加载尝试与成功次数至少 13 且必须
    # 全部成功;峰值占用必须在 1..12 之间(既真的加载过,又从未超限);
    # 切换到次要视频并关闭旧 Source 后,旧 Source 的帧路径与缓存必须全部归零。
    _expect_exact_int(report, "texture_cache_limit", errors, minimum=12, maximum=12)
    _expect_exact_int(report, "texture_load_attempt_count", errors, minimum=13)
    _expect_exact_int(report, "texture_load_success_count", errors, minimum=13)
    if report["texture_load_success_count"] != report["texture_load_attempt_count"]:
        errors.append("every acceptance texture load must succeed")
    _expect_exact_int(report, "texture_cache_peak", errors, minimum=1, maximum=12)
    _expect_exact_int(
        report,
        "old_source_retained_frame_paths_after_switch",
        errors,
        minimum=0,
        maximum=0,
    )
    _expect_exact_int(
        report, "old_source_cache_size_after_switch", errors, minimum=0, maximum=0
    )

    # 追溯判据:三个哈希字段都必须是小写 64 位 SHA-256;前后指纹一致且
    # source_dataset_modified 为 false,证明验收全程源数据集只读未动。
    for field in ("media_ids_sha256", "source_fingerprint_before", "source_fingerprint_after"):
        value = report[field]
        if (
            not isinstance(value, str)
            or len(value) != 64
            or any(character not in "0123456789abcdef" for character in value)
        ):
            errors.append(f"{field} must be a lowercase SHA-256")
    if report["source_fingerprint_before"] != report["source_fingerprint_after"]:
        errors.append("source fingerprints differ")
    if report["source_dataset_modified"] is not False:
        errors.append("source_dataset_modified must be false")
    return errors


# 判定字段必须是严格 int(type 检查,布尔值不算),且可选地落在 [minimum, maximum]
# 闭区间内;不满足时把错误信息追加进 errors 列表(不抛异常)。
def _expect_exact_int(
    report: dict,
    field: str,
    errors: list[str],
    *,
    minimum: int | None = None,
    maximum: int | None = None,
) -> None:
    value = report[field]
    if type(value) is not int:
        errors.append(f"{field} must be an integer")
        return
    if minimum is not None and value < minimum:
        errors.append(f"{field} must be at least {minimum}")
    if maximum is not None and value > maximum:
        errors.append(f"{field} must be at most {maximum}")


# 判定字段必须是有限的非负数值(int/float,布尔值不算,NaN/Inf 拒绝)。
def _expect_non_negative_number(report: dict, field: str, errors: list[str]) -> None:
    value = report[field]
    if (
        type(value) not in (int, float)
        or not math.isfinite(float(value))
        or value < 0
    ):
        errors.append(f"{field} must be finite and non-negative")


# 校验一组导入统计:必须是对象;四个 STAT_FIELDS 字段齐全且都是非负整数;
# polygon_regions 与 box_fallbacks 都不得超过 imported_regions(分量不能大于总数)。
def _validate_statistics(value: object, name: str, errors: list[str]) -> None:
    if not isinstance(value, dict):
        errors.append(f"{name} must be an object")
        return
    for field in STAT_FIELDS:
        if field not in value:
            errors.append(f"{name} is missing {field}")
        elif type(value[field]) is not int or value[field] < 0:
            errors.append(f"{name}.{field} must be a non-negative integer")
    if all(field in value and type(value[field]) is int for field in STAT_FIELDS):
        if value["polygon_regions"] > value["imported_regions"]:
            errors.append(f"{name}.polygon_regions exceeds imported_regions")
        if value["box_fallbacks"] > value["imported_regions"]:
            errors.append(f"{name}.box_fallbacks exceeds imported_regions")


# 主流程:前置检查 -> 建 staging -> 记录数据集指纹 -> headless 运行 Godot 验收
# 脚本 -> 解析结果并补上指纹结论 -> 校验报告 -> 写 report.json/report.md ->
# staging 原子改名发布。
# 参数:dataset_root 数据集根目录(必须存在,全程只读);output 验收输出目录
# (必须不存在,且不能是数据集本身或位于数据集之内)。
# 返回:与 report.json 内容一致的报告字典(不含 runner 的 success/errors 信封)。
# 副作用:启动 Godot 子进程(600 秒超时);创建 staging;写 Godot 日志与报告文件;
# 失败(含 KeyboardInterrupt 等一切异常)时删除 staging 后原样抛出。
# 异常:ValueError(目录/输出/Godot 缺失、Godot 失败、报告不合法)、
# subprocess.TimeoutExpired(Godot 超时)等。
def run_acceptance(dataset_root: Path, output: Path) -> dict:
    dataset_root = dataset_root.resolve()
    output = output.resolve()
    # 前置门禁:数据集根必须存在;输出目录必须事先不存在(连同符号链接一起检查,
    # 保护既有结果),且不能是数据集本身或位于数据集之内。
    if not dataset_root.is_dir():
        raise ValueError("dataset root does not exist")
    if output.exists() or output.is_symlink():
        raise ValueError("acceptance output already exists; existing content was preserved")
    if output == dataset_root or dataset_root in output.parents:
        raise ValueError("acceptance output must remain outside the source dataset")
    # 定位 Godot 可执行文件:优先 GODOT_BIN 环境变量,其次 PATH 上的 godot4/godot。
    godot = os.environ.get("GODOT_BIN") or shutil.which("godot4") or shutil.which("godot")
    if not godot:
        raise ValueError("Godot is unavailable; source project_env.sh or set GODOT_BIN")

    # staging 临时目录建在 output 同级(带随机后缀);所有产物先落地,成功后整体改名。
    output.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(
        tempfile.mkdtemp(prefix=f".{output.name}.staging-", dir=output.parent)
    )
    try:
        # 运行前记录数据集树的元数据指纹(不读文件内容,保持验收本身对源只读)。
        fingerprint_before = fingerprint_tree(dataset_root)
        result_path = staging / "godot-result.json"
        log_path = staging / "godot.log"
        # 把 XDG 数据/配置目录重定向进 staging,避免 headless Godot 读写用户的
        # ~/.local/share 与 ~/.config。
        environment = os.environ.copy()
        environment["XDG_DATA_HOME"] = str(staging / "xdg-data")
        environment["XDG_CONFIG_HOME"] = str(staging / "xdg-config")
        # 运行 headless Godot:--path 指向仓库根,--script 指定验收脚本,
        # "--" 之后是传给脚本的用户参数(--dataset-root/--output);结果 JSON 由
        # 脚本写入 staging,stdout/stderr 被捕获,600 秒超时防止验收挂死。
        process = subprocess.run(
            [
                godot,
                "--headless",
                "--path",
                str(ROOT),
                "--log-file",
                str(log_path),
                "--script",
                str(RUNNER),
                "--",
                "--dataset-root",
                str(dataset_root),
                "--output",
                str(result_path),
            ],
            cwd=ROOT,
            capture_output=True,
            text=True,
            timeout=600,
            env=environment,
        )
        # 保存 Godot 进程输出,便于失败时人工排查(不参与自动判据)。
        (staging / "godot-process.log").write_text(
            process.stdout + process.stderr, encoding="utf-8"
        )
        # 运行后再次取指纹;两份指纹随报告落盘并决定 source_dataset_modified。
        fingerprint_after = fingerprint_tree(dataset_root)
        # 结果文件缺失,或 Godot 失败(非零退出码/success 非 true),都直接判失败
        # 并携带 Godot 报告的错误明细,不做静默降级。
        if not result_path.is_file():
            raise ValueError(
                f"Godot acceptance produced no result (exit {process.returncode})"
            )
        payload = json.loads(result_path.read_text(encoding="utf-8"))
        if process.returncode != 0 or payload.get("success") is not True:
            detail = "; ".join(payload.get("errors", []))
            raise ValueError(
                f"Godot acceptance failed (exit {process.returncode}): {detail}"
            )
        # 剥离 runner 的 success/errors 信封字段,补上指纹三件套后交给 validate_report。
        report = dict(payload)
        report.pop("success", None)
        report.pop("errors", None)
        report["source_fingerprint_before"] = fingerprint_before
        report["source_fingerprint_after"] = fingerprint_after
        report["source_dataset_modified"] = fingerprint_before != fingerprint_after
        # 报告判据校验:任何一条不满足都判验收失败并列出全部错误。
        errors = validate_report(report, dataset_root)
        if errors:
            raise ValueError("invalid acceptance report: " + "; ".join(errors))
        # 删除原始结果文件,重新写出排序缩进的 report.json(最终报告本体)。
        result_path.unlink()
        (staging / "report.json").write_text(
            json.dumps(
                report,
                ensure_ascii=False,
                allow_nan=False,
                indent=2,
                sort_keys=True,
            )
            + "\n",
            encoding="utf-8",
        )
        selected = report["selected_import_statistics"]
        secondary = report["secondary_import_statistics"]
        # 生成人工可读的 Markdown 摘要(只含关键指标,不含数据集绝对路径)。
        (staging / "report.md").write_text(
            "# Endoscapes lazy Source acceptance\n\n"
            f"- Logical videos: {report['logical_video_count']}\n"
            f"- Discovery elapsed: {report['catalog_scan_elapsed_seconds']:.6f} seconds\n"
            f"- Selected video frames: {report['selected_video_frame_count']}\n"
            f"- Selected labels: {selected['imported_regions']} regions, "
            f"{selected['polygon_regions']} polygons, "
            f"{selected['box_fallbacks']} box fallbacks, "
            f"{selected['skipped_regions']} skipped\n"
            f"- Box-only labels: {secondary['imported_regions']} regions\n"
            f"- Texture cache peak: {report['texture_cache_peak']} / "
            f"{report['texture_cache_limit']}\n"
            "- Source dataset modified: no\n",
            encoding="utf-8",
        )
        # 原子发布:staging 整体改名为 output(此前已确认 output 不存在)。
        staging.replace(output)
    except BaseException:
        # 兜底清理:任何异常都删除 staging 后原样抛出,不留下半成品目录。
        shutil.rmtree(staging, ignore_errors=True)
        raise
    return report


# 命令行参数:--dataset-root 数据集根目录(必填)、--output 验收输出目录(必填)。
def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dataset-root", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    return parser.parse_args(argv)


# 入口:执行验收并打印摘要 JSON。
# 退出码:0 成功;1 失败(捕获 OSError/ValueError/TypeError/KeyError/
# JSONDecodeError/TimeoutExpired,打印一行失败原因后返回)。
# 成功时打印五个关键字段:logical_video_count、catalog_scan_elapsed_seconds、
# selected_video_frame_count、texture_cache_peak、source_dataset_modified。
def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        report = run_acceptance(args.dataset_root, args.output)
    except (
        OSError,
        ValueError,
        TypeError,
        KeyError,
        json.JSONDecodeError,
        subprocess.TimeoutExpired,
    ) as error:
        print(f"Endoscapes lazy Source acceptance failed: {error}")
        return 1
    print(
        json.dumps(
            {
                key: report[key]
                for key in (
                    "logical_video_count",
                    "catalog_scan_elapsed_seconds",
                    "selected_video_frame_count",
                    "texture_cache_peak",
                    "source_dataset_modified",
                )
            },
            ensure_ascii=False,
            indent=2,
        )
    )
    return 0


# 以脚本方式运行时,用 main 的返回值作为进程退出码。
if __name__ == "__main__":
    raise SystemExit(main())
