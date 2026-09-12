# ---------------------------------------------------------------------------
# 文件用途:对预先构建好的 Endoscapes fixture 运行 polygon 传播
# (poly-sim-flow-edge-v1),在本地渲染可人工审阅的定性验收证据:
# output/snapshots/(快照 PNG)、output/overlays/(raw 红、final 绿叠加图)、
# report.json 与 report.md,经同级 staging 目录原子发布。
# fixture 由 python/prepare_endoscapes_poly_fixture.py 构建;只有关键帧带
# polygon 种子,目标帧传播结果仅为定性评审证据,不是稠密 IoU 真值。
# 用法:
#   .venv/bin/python python/run_endoscapes_poly_acceptance.py \
#       --fixture .local-acceptance/endoscapes-poly-65 \
#       --output .local-acceptance/endoscapes-poly-65-evidence --threshold 0.10
# 退出码:0 成功;1 失败(打印原因)。
# 协作:annotation_data.contracts(schema 校验)、polygon_propagation(传播)、
#       polygon_edge_refinement(精修)、polygon_geometry、similarity(门限证据)。
# ---------------------------------------------------------------------------
"""Run Poly propagation on a prepared Endoscapes fixture and render local evidence."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import tempfile
import time

import cv2
import numpy as np

from annotation_data.contracts import validate_instance
from annotation_data.polygon_edge_refinement import refine
from annotation_data.polygon_propagation import propagate
from annotation_data.polygon_geometry import polygon_to_mask, validate_polygon
from annotation_data.similarity import similarity_gate


# 对任意 JSON 值计算确定性 SHA-256:键排序、紧凑分隔符、禁止 NaN、UTF-8 编码;
# 用于给 manifest 条目与模型记录生成可追溯的摘要字段。
def _digest(value: object) -> str:
    raw = json.dumps(value, ensure_ascii=False, allow_nan=False,
                     sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(raw).hexdigest()


# 以固定格式(缩进 2、键排序、行尾换行、UTF-8)写出 JSON 文件。
def _write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, ensure_ascii=False, allow_nan=False,
                               indent=2, sort_keys=True) + "\n", encoding="utf-8")


# 在原图上叠加掩码可视化:先按阈值把掩码二值化(像素最大值 > 1 视为 0/255 掩码,
# 阈值取 128;否则按 0/1 处理,阈值取 1),形状与图像不符时用最近邻插值缩放对齐。
# 掩码内部以 55:45 混合原图与纯色 tint(即 45% 颜色叠加),外轮廓用 2 像素
# 抗锯齿线描边。返回叠加后的副本,不改输入图像与掩码。
def _overlay(image: np.ndarray, mask: np.ndarray, color: tuple[int, int, int]) -> np.ndarray:
    mask = np.asarray(mask) >= (128 if np.asarray(mask).max() > 1 else 1)
    if mask.shape != image.shape[:2]:
        mask = cv2.resize(mask.astype(np.uint8), (image.shape[1], image.shape[0]),
                          interpolation=cv2.INTER_NEAREST) != 0
    output = image.copy()
    tint = np.zeros_like(output)
    tint[:] = color
    output[mask] = cv2.addWeighted(output, 0.55, tint, 0.45, 0)[mask]
    contours, _ = cv2.findContours(mask.astype(np.uint8), cv2.RETR_EXTERNAL,
                                   cv2.CHAIN_APPROX_SIMPLE)
    cv2.drawContours(output, contours, -1, color, 2, cv2.LINE_AA)
    return output


# edge_refiner 钩子的记录型包装:内部仍调用真实 refine(有界边缘精修)并原样
# 返回其结果,只是顺带搜集验收证据,不改变算法判定。
# 关键属性:
#   output       staging 目录(overlays/ 写在其下);
#   originals    playback_index -> 原始 BGR 图像(叠加底图);
#   analysis     灰度帧内容 SHA-256 -> playback_index 反查表(识别 target 属于哪帧);
#   original_ids playback_index -> Endoscapes 原始帧号(用于命名与报告);
#   counts       每帧已调用次数;overlays 最终写入 report.json 的证据列表。
# 调用约定:正常传播中每帧会调用两次精修——第 0 次(偶数次序)处理相邻光流候选
# (adjacent 角色),第 1 次(奇数次序)处理锚点候选(anchor 角色);
# 只有 adjacent 角色会写出 raw/final 两张叠加图并登记 overlays。
# 异常:target 无法归帧时抛 TypeError(防止证据错帧);写图失败抛 OSError。
class _RecordingRefiner:
    # 只保存引用并初始化计数器与证据列表,不做任何 I/O。
    def __init__(self, output: Path, originals: dict[int, np.ndarray],
                 analysis: dict[str, int], original_ids: dict[int, int]):
        self.output = output
        self.originals = originals
        self.analysis = analysis
        self.original_ids = original_ids
        self.counts: dict[int, int] = {}
        self.overlays: list[dict] = []

    # 先执行真实精修;再用 target 灰度内容的 SHA-256 反查帧序号,查不到说明
    # 出现了意外帧,抛 TypeError 而不是错误归档。按调用次序交替 adjacent/anchor
    # 角色;adjacent 角色把 raw 掩码(红色)与 final 掩码(绿色)各写一张叠加图,
    # 登记 accepted/reason 与两个相对路径,最后原样返回精修结果。
    def __call__(self, target: np.ndarray, raw_mask: np.ndarray):
        result = refine(target, raw_mask)
        key = hashlib.sha256(np.ascontiguousarray(target).tobytes()).hexdigest()
        if key not in self.analysis:
            raise TypeError("acceptance recorder could not identify the target frame")
        index = self.analysis[key]
        call = self.counts.get(index, 0)
        self.counts[index] = call + 1
        role = "adjacent" if call % 2 == 0 else "anchor"
        if role == "adjacent":
            original_id = self.original_ids[index]
            base = f"frame-{index:02d}-original-{original_id}"
            raw_path = self.output / "overlays" / f"{base}-raw.png"
            final_path = self.output / "overlays" / f"{base}-final.png"
            if not cv2.imwrite(str(raw_path), _overlay(self.originals[index], raw_mask, (0, 0, 255))):
                raise OSError("could not write raw acceptance overlay")
            if not cv2.imwrite(str(final_path), _overlay(self.originals[index], result.mask, (0, 255, 0))):
                raise OSError("could not write final acceptance overlay")
            self.overlays.append({
                "playback_index": index,
                "original_frame_id": original_id,
                "accepted": result.accepted,
                "reason": result.reason,
                "raw": raw_path.relative_to(self.output).as_posix(),
                "final": final_path.relative_to(self.output).as_posix(),
            })
        return result


# 主流程:校验 fixture -> 落盘帧快照并计算哈希 -> 组装 schema_version 3 的传播
# 请求 -> 运行 propagate(注入记录型精修钩子)-> 渲染种子/边缘证据 -> 写报告 ->
# staging 原子改名发布。
# 参数:fixture fixture 目录;output 证据输出目录(必须不存在);threshold 相似度
# 门限(必须为 (0, 1] 内的有限值)。
# 返回:与 report.json 内容一致的报告字典。
# 副作用:创建 staging 临时目录,写快照、叠加图、report.json、report.md,成功时
# 把 staging 改名为 output;失败(含 KeyboardInterrupt 等一切异常)时删除 staging
# 后原样抛出。本函数不启动子进程,传播在本进程内完成。
# 异常:ValueError(fixture/记录不合法、传播失败)、OSError(快照/叠加图写失败)、
# TypeError(精修证据无法归帧)等。
def run_acceptance(fixture: Path, output: Path, threshold: float = 0.10) -> dict:
    fixture, output = fixture.resolve(), output.resolve()
    # 前置门禁:输出目录必须不存在(连同符号链接一起检查),绝不覆盖既有证据;
    # fixture 必须是真实存在的目录。
    if output.exists() or output.is_symlink():
        raise ValueError("acceptance output already exists")
    if not fixture.is_dir():
        raise ValueError("fixture directory does not exist")
    # 阈值门禁:必须是有限数值且落在 (0, 1],与 propagate 对 similarity_threshold
    # 的约束一致。
    if not 0 < threshold <= 1 or not np.isfinite(threshold):
        raise ValueError("threshold must be finite and in (0, 1]")
    # 读取 fixture 三件套:manifest(数据集清单)、provenance(来源与种子信息)、
    # model_output_v1.jsonl(逐帧 Model Output V1 记录)。
    manifest = json.loads((fixture / "manifest.json").read_text(encoding="utf-8"))
    provenance = json.loads((fixture / "provenance.json").read_text(encoding="utf-8"))
    records = [json.loads(line) for line in
               (fixture / "model_output_v1.jsonl").read_text(encoding="utf-8").splitlines()
               if line]
    # 门禁:manifest 必须通过 dataset-manifest-v1 schema,且记录条数与
    # manifest.frame_count 一致,否则 fixture 本身不可信。
    errors = validate_instance(manifest, "dataset-manifest-v1.schema.json")
    if errors or len(records) != manifest.get("frame_count"):
        raise ValueError("fixture manifest/record count is invalid")
    # 门禁:每条记录必须通过 model_output_v1 schema,且 frame 字段等于其行号,
    # 保证记录与 playback index 一一对应。
    for index, record in enumerate(records):
        errors = validate_instance(record, "model_output_v1.schema.json")
        if errors or record.get("frame") != index:
            raise ValueError(f"fixture model record {index} is invalid")
    # 关键帧种子:provenance 的 keyframe_seed.playback_index 指向唯一带 polygon
    # 的记录;没有种子就无法进行传播验收。
    key = int(provenance["keyframe_seed"]["playback_index"])
    regions = records[key]["regions"]
    if not regions:
        raise ValueError("fixture keyframe has no polygon seed")

    # 在 output 同级创建 staging 临时目录(带随机后缀,不会与 output 重名),
    # 下设 snapshots/ 与 overlays/;全部产物就绪后一次性改名为 output。
    output.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix=f".{output.name}.staging-", dir=output.parent))
    try:
        (staging / "snapshots").mkdir()
        (staging / "overlays").mkdir()
        # playback_index -> 原始帧号映射:叠加图命名与报告都要还原 Endoscapes 原始帧号。
        original_ids = {int(item["playback_index"]): int(item["original_frame_id"])
                        for item in provenance["frames"]}
        originals: dict[int, np.ndarray] = {}
        gray: dict[int, np.ndarray] = {}
        request_frames = []
        # 逐帧处理:解码 fixture 图像并另存为快照 PNG,再回读快照文件计算字节
        # SHA-256 与灰度图——后续传播与相似度证据都以「落盘快照」为准,哈希描述的
        # 是实际被分析的文件而非内存解码结果。解码失败或写图失败都会中止验收。
        for index, entry in enumerate(manifest["frames"]):
            source = fixture / entry["image_path"]
            image = cv2.imread(str(source), cv2.IMREAD_COLOR)
            if image is None:
                raise ValueError(f"fixture frame {index} could not be decoded")
            snapshot = staging / "snapshots" / f"frame_{index:06d}.png"
            if not cv2.imwrite(str(snapshot), image):
                raise OSError(f"could not write frame {index} snapshot")
            data = snapshot.read_bytes()
            originals[index] = image
            snapshot_gray = cv2.imread(str(snapshot), cv2.IMREAD_GRAYSCALE)
            if snapshot_gray is None:
                raise OSError(f"could not verify frame {index} snapshot")
            gray[index] = snapshot_gray
            # 快照身份:图像 SHA-256 加上 manifest 条目与模型记录的 JSON 摘要,
            # 构成可追溯的逐帧字段;verified 固定为 False(本脚本不做人工核验)。
            request_frames.append({
                "index": index,
                "frame_id": index,
                "image_path": str(snapshot),
                "image_sha256": hashlib.sha256(data).hexdigest(),
                "entry_digest": _digest(entry),
                "record_digest": _digest(records[index]),
                "verified": False,
            })
        # 灰度内容 SHA-256 -> 帧序号的反查表,供 _RecordingRefiner 把精修调用归帧;
        # 出现重复灰度帧时证据归属有歧义,直接拒绝。
        analysis_lookup = {
            hashlib.sha256(np.ascontiguousarray(image).tobytes()).hexdigest(): index
            for index, image in gray.items()
        }
        if len(analysis_lookup) != len(gray):
            raise ValueError("fixture contains duplicate grayscale frames; evidence mapping is ambiguous")
        recorder = _RecordingRefiner(staging, originals, analysis_lookup, original_ids)
        # 组装 schema_version 3 传播请求:frame_step 1(播放序号连续)、关键帧序号、
        # 相似度门限、逐帧快照身份与关键帧 polygon 种子(regions)。
        request = {
            "schema_version": 3,
            "frame_step": 1,
            "key_index": key,
            "similarity_threshold": float(threshold),
            "frames": request_frames,
            "regions": regions,
        }
        # 相似度证据(仅写入报告,不参与传播控制——propagate 内部会自行重新判门):
        # 对每个非关键帧,取其朝向关键帧一侧的相邻帧 previous,计算它与该帧的
        # adjacent_mad 以及它与关键帧的 keyframe_mad;两者都低于阈值才记 accepted。
        similarities = []
        for index in range(len(gray)):
            if index == key:
                continue
            previous = index - 1 if index > key else index + 1
            scores = similarity_gate(gray[previous], gray[index], gray[key], threshold)
            similarities.append({
                "playback_index": index,
                "original_frame_id": original_ids[index],
                "toward_keyframe_index": previous,
                **scores,
            })
        # 运行传播并注入记录型精修钩子同步产出叠加证据;计时只覆盖 propagate 本身。
        started = time.perf_counter()
        result = propagate(request, edge_refiner=recorder)
        elapsed = time.perf_counter() - started
        # 传播失败不静默降级:success=False 时携带原因直接抛错终止验收。
        if not result.get("success"):
            raise ValueError("propagation failed: " + str(result.get("error", "unknown error")))

        # 由关键帧种子 polygon 重栅格化出种子掩码(先过 validate_polygon 校验),
        # 写出青色种子叠加图作为真值参照。
        seed_mask = polygon_to_mask(
            validate_polygon(regions[0]["polygon"], (manifest["width"], manifest["height"])),
            (manifest["width"], manifest["height"]),
            (manifest["height"], manifest["width"]),
        )
        seed_path = staging / "overlays" / f"frame-{key:02d}-original-{original_ids[key]}-seed.png"
        if not cv2.imwrite(str(seed_path), _overlay(originals[key], seed_mask, (255, 255, 0))):
            raise OSError("could not write keyframe seed overlay")
        # 汇总每个 proposal 中每个 region 的边缘精修判定:相邻/关键帧 MAD、
        # accepted 与原因、raw/refined 边缘得分、raw IoU、面积比、Hausdorff 距离
        # 与最终得分;accepted=False 即 raw-flow fallback(精修被拒、沿用 raw 掩码)。
        edge_summary = []
        for proposal in result["proposals"]:
            for region_id, quality in proposal["quality"].items():
                edge = quality["edge"]
                edge_summary.append({
                    "playback_index": proposal["index"],
                    "original_frame_id": original_ids[proposal["index"]],
                    "region_id": region_id,
                    "adjacent_mad": quality["adjacent_mad"],
                    "keyframe_mad": quality["keyframe_mad"],
                    "accepted": edge["accepted"],
                    "reason": edge["reason"],
                    "raw_edge_score": edge["raw_edge_score"],
                    "refined_edge_score": edge["refined_edge_score"],
                    "raw_iou": edge["raw_iou"],
                    "area_ratio": edge["area_ratio"],
                    "hausdorff": edge["hausdorff"],
                    "final_score": quality["score"],
                })
        # 证据报告:candidate_range 为候选播放帧闭区间 [start_index, end_index];
        # left_stop/right_stop 记录左右两个方向的停止原因;evidence_limit 原样
        # 携带 provenance 的证据边界声明;manual_ui_checklist 是待人工执行的
        # Godot UI 检查项,manual_ui_status 初始为 pending。
        report = {
            "schema_version": 1,
            "evidence_type": "endoscapes-poly-qualitative-acceptance",
            "fixture_id": manifest["dataset_id"],
            "metric_id": result["metric_id"],
            "threshold": result["threshold"],
            "elapsed_seconds": elapsed,
            "key_playback_index": key,
            "key_original_frame_id": original_ids[key],
            "candidate_range": [result["start_index"], result["end_index"]],
            "proposal_indices": [proposal["index"] for proposal in result["proposals"]],
            "left_stop": result["left_stop"],
            "right_stop": result["right_stop"],
            "similarities": similarities,
            "edge_results": edge_summary,
            "overlays": recorder.overlays,
            "seed_overlay": seed_path.relative_to(staging).as_posix(),
            "evidence_limit": provenance["evidence_limit"],
            "manual_ui_checklist": [
                "Open the copied fixture in Main and select the keyframe.",
                "Preview every proposed target and apply once.",
                "Undo once, redo once, save/reopen, confirm, then verify auto-next.",
            ],
            "manual_ui_status": "pending",
        }
        _write_json(staging / "report.json", report)
        # 统计边缘判定的接受/回退数量,供 Markdown 摘要展示。
        accepted = sum(1 for item in edge_summary if item["accepted"])
        fallback = len(edge_summary) - accepted
        markdown = f"""# Endoscapes Poly acceptance (local evidence)\n\n\
- Fixture: `{manifest['dataset_id']}`; keyframe {key} (original {original_ids[key]})\n\
- Algorithm: `{result['metric_id']}`; similarity threshold `{threshold:.6f}`\n\
- Candidate range: `{result['start_index']}..{result['end_index']}`; proposals `{report['proposal_indices']}`\n\
- Stop reasons: left `{result['left_stop']}`; right `{result['right_stop']}`\n\
- Edge decisions: {accepted} accepted, {fallback} raw-flow fallback\n\
- Elapsed: {elapsed:.6f} seconds\n\
- Manual UI status: pending\n\n\
The keyframe mask is the only ground-truth seed. Target overlays are qualitative reviewer evidence, not dense target-frame IoU evidence.\n"""
        (staging / "report.md").write_text(markdown, encoding="utf-8")
        # 原子发布:staging 整体改名为 output(此前已确认 output 不存在)。
        staging.replace(output)
    except BaseException:
        # 兜底清理:任何异常(包括 KeyboardInterrupt)都删除 staging 后原样抛出,
        # 不留下半成品证据目录。
        shutil.rmtree(staging, ignore_errors=True)
        raise
    return report


# 命令行参数:--fixture fixture 目录(必填)、--output 证据输出目录(必填)、
# --threshold 相似度门限(浮点,默认 0.10)。
def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixture", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--threshold", type=float, default=0.10)
    return parser.parse_args(argv)


# 入口:执行验收并打印摘要。
# 退出码:0 成功;1 失败(捕获 OSError/ValueError/KeyError/TypeError/
# JSONDecodeError,打印一行失败原因后返回)。
# 成功时把报告的摘要字段(metric_id、candidate_range、proposal_indices、
# left_stop/right_stop、elapsed_seconds、manual_ui_status)以 JSON 打印到 stdout。
def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        report = run_acceptance(args.fixture, args.output, args.threshold)
    except (OSError, ValueError, KeyError, TypeError, json.JSONDecodeError) as error:
        print(f"Endoscapes Poly acceptance failed: {error}")
        return 1
    print(json.dumps({key: report[key] for key in (
        "metric_id", "candidate_range", "proposal_indices", "left_stop", "right_stop",
        "elapsed_seconds", "manual_ui_status")}, ensure_ascii=False, indent=2))
    return 0


# 以脚本方式运行时,用 main 的返回值作为进程退出码。
if __name__ == "__main__":
    raise SystemExit(main())
