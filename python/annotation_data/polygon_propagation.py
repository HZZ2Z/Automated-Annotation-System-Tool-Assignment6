# polygon 运动传播核心实现(poly-sim-flow-edge-v1 备选方法):门禁、光流候选与近似回退。
#
# 用途:以人工关键帧为锚点,把关键帧上的 V1 polygon region 沿相邻帧向左右
# 两个方向传播,生成逐帧可编辑、待人工检查的 polygon 候选(proposal)。
#
# 角色与协作:被 python/propagate_polygons.py 命令行外壳调起,进而由 Godot
# 客户端以子进程方式使用。请求与结果都是版本化 JSON 字典(schema 3):输入
# 是 Godot 预先冻结的至多 30 张只读 PNG 快照(带 SHA-256、连续 index 与
# frame_step 抽样步长)加关键帧上的 V1 polygon region;输出是 success/
# cancelled 状态、逐帧 proposals、质量诊断与左右方向的停止原因。协作模块:
# contracts(Model Output V1 校验)、similarity(相似度门禁)、polygon_flow
# (DIS 光流与逐像素证据)、polygon_edge_refinement(边缘精修)、
# polygon_geometry(mask 拓扑/面积与 polygon 转换门禁)。
#
# 安全策略:失败或取消丢弃全部临时结果,绝不静默降级;快照文件只读,本模块
# 不写文件、不持久化;取消通过 cancelled 回调以协作方式完成。
"""短段 polygon 光流基线；只产生候选，人工关键帧及输入文件始终只读。"""

from __future__ import annotations

from copy import deepcopy
from dataclasses import dataclass
import hashlib
import math
from pathlib import Path
import stat
import struct
from typing import Callable

import cv2
import numpy as np

from .contracts import validate_instance
from .polygon_edge_refinement import EdgeRefinement, refine
from .polygon_flow import MotionPair
from .polygon_geometry import candidate_mask_geometry, mask_iou, polygon_to_mask, single_mask_contour, validate_polygon
from .similarity import similarity_gate


# 度量/算法版本标识,原样写入成功结果,供客户端与审计追溯所用的传播方法。
METRIC_ID = "poly-sim-flow-edge-v1"
# 请求未显式给出 similarity_threshold 时的默认相似度门限(0..1,严格小于才通过)。
DEFAULT_SIMILARITY_THRESHOLD = 0.10
# 光流质量分数下限:外观/往返一致/纹理/锚点 IoU/锚点质量五项最小值低于该值
# 的候选 mask 被拒绝,进入亮区/固定回退。
FLOW_QUALITY_THRESHOLD = 0.25
# 单次请求允许的最大快照数(含关键帧),frames 超限即拒绝。
MAX_FRAMES = 30
# 分析分辨率长边上限:更大的快照在读入后等比缩小,polygon 仍映射回原图坐标。
MAX_ANALYSIS_SIDE = 1024
# 单张快照的像素数上限(约 32MP),超限视为不受支持的图像尺寸。
MAX_IMAGE_PIXELS = 32_000_000
# 单张 PNG 快照的字节数上限(64 MiB)。
MAX_IMAGE_BYTES = 64 * 1024 * 1024
# 全部 region mask 在关键帧分辨率下允许的工作内存预算(128 MiB)。
MAX_MASK_BYTES = 128 * 1024 * 1024


# 协作取消信号:check_cancel 回调在各阶段间隙轮询,命中即抛出;propagate
# 捕获后转为 cancelled=True 的结果字典,不会让异常冒泡到调用方。
class Cancelled(Exception):
    pass


# 一张只读 PNG 快照的完整身份(frozen dataclass,不可变,可直接比较):
#   path:快照文件路径(分析期间禁止变化);
#   size:从 PNG 头解析出的 (宽, 高);
#   digest:PNG 文件字节的 SHA-256(与请求中的 image_sha256 比对);
#   stat:(st_ino, st_size, st_mtime_ns, st_ctime_ns) 四元组,分析结束后
#     复查文件未被替换时使用。
@dataclass(frozen=True)
class Snapshot:
    path: Path
    size: tuple[int, int]
    digest: bytes
    stat: tuple[int, int, int, int]


# 读取文件的 stat 身份四元组 (inode, 大小, mtime_ns, ctime_ns)。
# 参数 path:待检查文件;返回四元组,供 Snapshot 记录与事后一致性复查。
# 异常:路径不是普通文件(目录、设备等)时抛 ValueError。
def _file_signature(path: Path) -> tuple[int, int, int, int]:
    details = path.stat()
    if not stat.S_ISREG(details.st_mode):
        raise ValueError("image snapshot must be a regular file")
    return details.st_ino, details.st_size, details.st_mtime_ns, details.st_ctime_ns


# 读取、校验并解码一张 PNG 快照,返回分析分辨率下的灰度图与快照身份。
# 参数 path:PNG 快照路径;expected:可选的事先记录的 Snapshot——给定时与
#   本次读取结果逐字段比对,不一致即拒绝(方向分析阶段用于确认快照未变)。
# 返回:(uint8 灰度 ndarray(长边超过 MAX_ANALYSIS_SIDE 时等比缩小),
#   Snapshot) 二元组;副作用:只读文件。
# 异常(均为 ValueError):超过 64 MiB;不是 PNG(魔数/IHDR 不符);尺寸越界
#   (短边 <16 px、长边 >32768 px 或超过 32MP);读取期间文件身份或长度变化;
#   与 expected 不一致;cv2 解码失败或解码尺寸与 PNG 头不符。
def _load_image(path: Path, expected: Snapshot | None = None) -> tuple[np.ndarray, Snapshot]:
    signature = _file_signature(path)
    if signature[1] > MAX_IMAGE_BYTES:
        raise ValueError("PNG image exceeds the 64 MiB input limit")
    with path.open("rb") as stream:
        # 只读 24 字节头部即可校验 PNG 魔数与 IHDR 块,并直接取出宽高(解码前先做尺寸门禁)。
        header = stream.read(24)
        if len(header) != 24 or header[:8] != b"\x89PNG\r\n\x1a\n" or header[12:16] != b"IHDR":
            raise ValueError(f"image is not a PNG snapshot: {path.name}")
        width, height = struct.unpack(">II", header[16:24])
        # 尺寸门禁:短边至少 16 px、长边至多 32768 px,总像素不超过 32MP。
        if min(width, height) < 16 or max(width, height) > 32768 or width * height > MAX_IMAGE_PIXELS:
            raise ValueError("image dimensions exceed supported bounds (16px minimum, 32MP maximum)")
        # 读入全部字节(上限之外的字节不读)。
        data = header + stream.read(MAX_IMAGE_BYTES + 1 - len(header))
    # 复查 stat 身份与字节数:读取期间文件被替换或增长立即拒绝。
    if len(data) > MAX_IMAGE_BYTES or _file_signature(path) != signature:
        raise ValueError("image snapshot changed while being read")
    # 组装快照身份:SHA-256 覆盖读到的全部 PNG 字节。
    snapshot = Snapshot(path, (width, height), hashlib.sha256(data).digest(), signature)
    # 与调用方事先记录的身份逐字段比较,任何差异都说明快照在分析期间变了。
    if expected is not None and snapshot != expected:
        raise ValueError("image snapshot changed during analysis")
    # 解码为单通道灰度图,解码尺寸必须与 PNG 头声明一致。
    image = cv2.imdecode(np.frombuffer(data, np.uint8), cv2.IMREAD_GRAYSCALE)
    if image is None or image.shape != (height, width):
        raise ValueError(f"image PNG could not be decoded: {path.name}")
    # 长边超过分析分辨率上限时等比缩小(INTER_AREA 适合缩小采样)。
    scale = min(1.0, MAX_ANALYSIS_SIDE / max(width, height))
    if scale < 1:
        image = cv2.resize(image, (max(1, round(width * scale)), max(1, round(height * scale))), interpolation=cv2.INTER_AREA)
    return image, snapshot


# 校验一个值是「非负整数值」:只接受 int 或有限 float(且必须等于其整数截断),
# 显式拒绝 bool、非有限值、负数与小数。
# 参数 value:待校验值;name:错误信息中的字段名。返回 int(value)。
# 异常:不满足条件时抛 ValueError。
def _integer(value: object, name: str) -> int:
    if type(value) not in (int, float) or not math.isfinite(value) or value < 0 or int(value) != value:
        raise ValueError(f"{name} must be a nonnegative integer")
    return int(value)


# 校验传播请求的整体合同(字段、类型、帧序列与 region),纯内存检查,不做 IO。
# 参数 request:调用方传入的版本化请求字典。
# 返回:(frames, regions, key, threshold, frame_step)——frames 为快照描述
#   列表(原样透传);regions 为 V1 polygon region 列表(原样透传);key 为
#   关键帧 index;threshold 为 float 相似度阈值(缺省 0.10);frame_step 为
#   int 抽样步长。
# 异常(均为 ValueError):请求不是 dict 或含未知/缺失字段;schema_version
#   不是 3;threshold 不在 (0,1];frame_step < 1;frames 不含 1..30 帧或
#   index/frame_id 不满足步长关系;每帧字段集合不符、image_path 非绝对路径、
#   三个 digest 非 64 位小写十六进制、verified 非 bool;key_index 不在 frames
#   中;regions 为空、未通过 Model Output V1 校验、含无 polygon 的 region
#   或 id 重复。
def _validate_request(request: object) -> tuple[list[dict], list[dict], int, float, int]:
    # 字段白名单:只允许版本化协议字段,similarity_threshold 是唯一可缺省项。
    allowed = {"schema_version", "key_index", "similarity_threshold", "frame_step", "frames", "regions"}
    required = allowed - {"similarity_threshold"}
    if not isinstance(request, dict) or set(request) - allowed or not required <= set(request):
        raise ValueError("request must be an object with only the versioned protocol fields")
    if _integer(request.get("schema_version"), "schema_version") != 3:
        raise ValueError("unsupported schema_version")
    key = _integer(request.get("key_index"), "key_index")
    threshold = request.get("similarity_threshold", DEFAULT_SIMILARITY_THRESHOLD)
    if type(threshold) not in (int, float) or not math.isfinite(threshold) or not 0 < threshold <= 1:
        raise ValueError("similarity_threshold must be a finite score in (0, 1]")
    frame_step = _integer(request.get("frame_step"), "frame_step")
    if frame_step < 1:
        raise ValueError("frame_step must be a positive integer")
    frames = request.get("frames")
    if not isinstance(frames, list) or not 1 <= len(frames) <= MAX_FRAMES:
        raise ValueError("frames must contain 1 to 30 consecutive snapshots")
    frame_fields = {"index", "frame_id", "image_path", "image_sha256", "entry_digest", "record_digest", "verified"}
    # 逐帧校验身份字段:除首帧外 index 必须逐帧 +1、frame_id 必须按
    # frame_step 等差,保证抽到的确实是「连续条目的等间隔采样」。
    for i, frame in enumerate(frames):
        if not isinstance(frame, dict) or set(frame) != frame_fields:
            raise ValueError("each frame must contain only the v2 snapshot identity fields")
        index = _integer(frame["index"], "frame index")
        frame_id = _integer(frame["frame_id"], "frame_id")
        if i and (index != frames[i - 1]["index"] + 1 or frame_id != frames[i - 1]["frame_id"] + frame_step):
            raise ValueError("frame indices and sampled original frame IDs must match frame_step")
        path = frame["image_path"]
        if not isinstance(path, str) or not path or not Path(path).is_absolute():
            raise ValueError("image_path must be an absolute PNG snapshot path")
        # 三个 digest 字段都必须是 64 位小写十六进制(SHA-256)。
        for field in ("image_sha256", "entry_digest", "record_digest"):
            value = frame[field]
            if not isinstance(value, str) or len(value) != 64 or any(character not in "0123456789abcdef" for character in value):
                raise ValueError(f"{field} must be a lowercase SHA-256 digest")
        if type(frame["verified"]) is not bool:
            raise ValueError("verified must be a boolean snapshot")
    # 关键帧必须落在这次给出的快照序列内。
    if key not in [frame["index"] for frame in frames]:
        raise ValueError("key_index is not present in frames")
    regions = request.get("regions")
    if not isinstance(regions, list) or not regions:
        raise ValueError("regions must contain at least one V1 polygon region")
    # 把 regions 包装成一份最小 V1 实例,复用 Model Output V1 schema 的全量
    # 校验(box/polygon 结构、坐标范围等),不合格的 region 直接拒绝。
    errors = validate_instance({"schema_version": 1, "source": "polygon-propagation", "frame": 0, "regions": regions}, "model_output_v1.schema.json")
    if errors:
        raise ValueError("invalid V1 polygon region: " + errors[0])
    # 传播只处理带 polygon 的 region。
    if any("polygon" not in region for region in regions):
        raise ValueError("every region must contain a polygon")
    # id 唯一,保证候选与质量诊断能按 region 精确对应。
    if len({region["id"] for region in regions}) != len(regions):
        raise ValueError("polygon region IDs must be unique")
    return frames, regions, key, float(threshold), frame_step


# 对一对图像构造运动模型,并逐 region 计算光流证据与映射后的候选 mask。
# 参数 source/target:前/后两帧的分析分辨率灰度图;masks:(region, mask)
#   列表;check_cancel:协作取消回调;motion_factory:运动模型工厂(默认
#   polygon_flow.MotionPair,可注入替身)。
# 返回:(motion, warped, evidence)——运动模型、与 masks 对齐的映射后 mask
#   列表、与 masks 对齐的证据字典列表。
# 异常:光流或证据计算抛出的 ValueError 附上 region id 后重新抛出。
def _analyse_pair(source, target, masks, check_cancel, motion_factory):
    motion = motion_factory(source, target, check_cancel)
    warped, evidence = [], []
    for region, mask in masks:
        check_cancel()
        try:
            evidence.append(motion.evidence(mask))
            warped.append(motion.warp_mask(mask))
        except ValueError as error:
            raise ValueError(f"region {region['id']}: {error}") from error
    return motion, warped, evidence


# 边缘精修诊断必须且只能给出的五个分数字段(集合精确匹配,防止返回结构漂移)。
_EDGE_SCORE_FIELDS = {"raw_edge_score", "refined_edge_score", "raw_iou", "area_ratio", "hausdorff"}


# 防御性校验边缘精修回调的返回值,并整理成诊断字典(精修器是可插拔回调,
# 输出必须逐项核对,防止非法结构流入下游)。
# 参数 result:edge_refiner 的返回值;raw_mask:精修前的原始 mask。
# 返回:(candidate, diagnostics)——candidate 为 mask 的 ndarray 副本;
#   diagnostics 含 attempted(恒 True)、accepted、reason 与五个分数字段。
# 异常(均为 TypeError):返回类型不是 EdgeRefinement;accepted/reason 字段
#   非法(reason 长度须在 1..160 且不含控制字符);mask 形状与 raw_mask 不一致
#   或非二维;mask 数值非数值类型或含非有限值;声称拒绝却改动了 raw_mask;
#   scores 字段集合不匹配或存在非数值/非有限分数。
def _validated_edge_result(result: object, raw_mask: np.ndarray) -> tuple[np.ndarray, dict]:
    if not isinstance(result, EdgeRefinement):
        raise TypeError("edge refinement returned an invalid result type")
    if type(result.accepted) is not bool or not isinstance(result.reason, str) or not 1 <= len(result.reason) <= 160:
        raise TypeError("edge refinement returned invalid status fields")
    if any(ord(character) < 32 for character in result.reason):
        raise TypeError("edge refinement reason contains control characters")
    candidate = np.asarray(result.mask)
    if candidate.shape != raw_mask.shape or candidate.ndim != 2:
        raise TypeError("edge refinement returned an invalid mask shape")
    if not np.issubdtype(candidate.dtype, np.number) or not np.isfinite(candidate).all():
        raise TypeError("edge refinement returned invalid mask values")
    # 预期性拒绝必须原样返回 raw mask(逐元素一致),改动即视为精修器违约。
    if not result.accepted and not np.array_equal(candidate, raw_mask):
        raise TypeError("edge refinement fallback changed the raw mask")
    # 分数字段必须与约定集合完全一致(不多不少)。
    if not isinstance(result.scores, dict) or set(result.scores) != _EDGE_SCORE_FIELDS:
        raise TypeError("edge refinement returned invalid score fields")
    scores = {}
    for field in sorted(_EDGE_SCORE_FIELDS):
        value = result.scores[field]
        if isinstance(value, (bool, np.bool_)) or not isinstance(value, (int, float, np.integer, np.floating)):
            raise TypeError("edge refinement returned a nonnumeric score")
        value = float(value)
        if not math.isfinite(value):
            raise TypeError("edge refinement returned a non-finite score")
        scores[field] = value
    # 汇总诊断字典:attempted 恒为 True(确实执行过精修),附结果与全部分数。
    diagnostics = {"attempted": True, "accepted": result.accepted,
                   "reason": result.reason, **scores}
    return candidate.copy(), diagnostics


# 调用边缘精修回调并校验其返回结果。
# 参数 edge_refiner:精修回调(默认 refine);target:目标帧灰度图;
#   raw_mask:待精修 mask。
# 返回:与 _validated_edge_result 相同的 (candidate, diagnostics) 二元组。
# 异常:cv2.error(OpenCV 运行异常)原样上抛,由 propagate 使整份计划失败;
#   精修器内部拒绝自己的输入(ValueError)统一转成 TypeError——那属于
#   实现错误,而不是可近似回退的数据问题。
def _run_edge_refinement(edge_refiner, target: np.ndarray,
                         raw_mask: np.ndarray) -> tuple[np.ndarray, dict]:
    try:
        result = edge_refiner(target, raw_mask)
    except cv2.error:
        raise
    except ValueError as error:
        raise TypeError("edge refinement rejected its internal inputs") from error
    return _validated_edge_result(result, raw_mask)


# 亮区模板回退:内镜图像的高亮目标常比周围组织亮,在上一候选附近的有界 ROI
# 内做带掩码的灰度模板匹配,估计一个整体平移;证据不足时保持原坐标。
# 参数 source/target:前/后帧的分析分辨率灰度图;prior:上一候选 mask。
# 返回:(candidate mask, mode, score) 三元组——mode 为 "bright-template
#   fallback"(发生平移)或 "fixed fallback"(保持原坐标);score 为匹配
#   质量分(fixed 回退时为 0.0)。
# 异常:prior 二值化后为空时抛 ValueError。
def _bright_template_mask(source: np.ndarray, target: np.ndarray,
                          prior: np.ndarray) -> tuple[np.ndarray, str, float]:
    """弱纹理时只估计局部平移；亮度证据不足便保持原坐标。"""
    binary = np.asarray(prior >= 128, np.uint8)
    ys, xs = np.where(binary > 0)
    if not len(xs):
        raise ValueError("reference mask is empty")
    # prior 前景的包围盒(bounding box)。
    x0, x1, y0, y1 = xs.min(), xs.max() + 1, ys.min(), ys.max() + 1
    height, width = source.shape
    # 搜索 ROI:包围盒四周外扩 padding(至少 12 px 且不小于包围盒边长)并裁剪到图像内。
    padding = max(12, x1 - x0, y1 - y0)
    sx0, sx1 = max(0, x0 - padding), min(width, x1 + padding)
    sy0, sy1 = max(0, y0 - padding), min(height, y1 + padding)
    # outside 为 ROI 内、prior 之外的环形区域,用作背景亮度参照。
    local = np.zeros_like(binary)
    local[sy0:sy1, sx0:sx1] = 1
    outside = (local > 0) & (binary == 0)
    # 对比度证据:prior 内部与外围背景的中位灰度之差。
    inside_level = float(np.median(source[binary > 0]))
    outside_level = float(np.median(source[outside])) if outside.any() else inside_level
    source_contrast = inside_level - outside_level
    # 源对比度不足 12 级:亮区特征不可靠,保持原坐标。
    if source_contrast < 12:
        return prior.copy(), "fixed fallback", 0.0
    # 模板与掩码取包围盒内部;search 为外扩后的目标帧 ROI。
    template = source[y0:y1, x0:x1]
    template_mask = binary[y0:y1, x0:x1] * 255
    search = target[sy0:sy1, sx0:sx1]
    if search.shape[0] < template.shape[0] or search.shape[1] < template.shape[1]:
        return prior.copy(), "fixed fallback", 0.0
    # 带掩码的归一化平方差模板匹配:只统计 prior 内部像素,得分越小越贴合。
    scores = cv2.matchTemplate(search, template, cv2.TM_SQDIFF_NORMED,
                               mask=template_mask)
    finite = np.isfinite(scores)
    if not finite.any():
        return prior.copy(), "fixed fallback", 0.0
    # 非有限分数(掩码/除零等产生)替换为 +inf 后取最优位置。
    safe_scores = np.where(finite, scores, np.inf)
    best_y, best_x = np.unravel_index(int(np.argmin(safe_scores)), safe_scores.shape)
    # 匹配质量分:1 - SQDIFF,截断到 [0,1]。
    score = float(max(0.0, 1.0 - safe_scores[best_y, best_x]))
    # 由 ROI 偏移换算整体平移量 (dx, dy)。
    dx, dy = sx0 + best_x - x0, sy0 + best_y - y0
    # 最近邻插值整体平移 prior,保持二值边界不被插值模糊。
    candidate = cv2.warpAffine(prior, np.float32([[1, 0, dx], [0, 1, dy]]),
                               (width, height), flags=cv2.INTER_NEAREST,
                               borderMode=cv2.BORDER_CONSTANT)
    candidate_binary = candidate >= 128
    # 目标帧上候选区域的中位亮度必须比背景高出 max(10, 源对比度的 1/4),
    # 否则视为目标在当前帧定位证据不足,保持原坐标。
    target_level = float(np.median(target[candidate_binary])) if candidate_binary.any() else 0.0
    if target_level - outside_level < max(10.0, source_contrast * 0.25):
        return prior.copy(), "fixed fallback", 0.0
    return candidate, "bright-template fallback", score


# 光流门禁失败后的近似回退:对每个 region 用亮区平移/固定坐标重新定位候选,
# 再走同一套边缘精修与几何门,产出显式标记 fallback 的 proposal。
# 参数 previous:上一帧(或关键帧)灰度图;target:当前帧灰度图;masks:
#   (region, 上一候选 mask) 列表;anchor_masks:关键帧 (region, mask) 列表;
#   frame:当前快照描述;size:原图 (宽, 高);check_cancel:取消回调;
#   edge_refiner:精修回调;similarity:similarity_gate 的结果字典;reason:
#   触发回退的原始错误(截断后写入 quality["fallback_reason"])。
# 返回:(proposal, next_masks)——proposal 含 index/frame_id/regions/quality,
#   next_masks 为 (region, 本帧候选 mask) 列表,供下一帧继续传播。
# 副作用:无(纯内存计算);异常:fixed 回退也过不了边缘精修或几何门时,
#   ValueError 直接上抛(propagate 中会使整份计划失败,不静默跳帧)。
# 质量字段说明:回退候选没有可信光流证据,fb_consistency/support 恒为 0、
#   largest_unsupported_fraction 恒为 1,appearance 用模板匹配分,texture 按
#   prior 内部灰度标准差/8 归一(封顶 1),score 即匹配分。
def _fallback_candidate_frame(previous, target, masks, anchor_masks, frame, size,
                              check_cancel, edge_refiner, similarity, reason):
    output_regions, quality_by_id, next_masks = [], {}, []
    for i, (region, prior) in enumerate(masks):
        check_cancel()
        # 先尝试亮区平移定位。
        raw_candidate, mode, match_score = _bright_template_mask(previous, target, prior)
        try:
            candidate, edge = _run_edge_refinement(edge_refiner, target, raw_candidate)
            polygon, geometry = candidate_mask_geometry(
                candidate, prior, anchor_masks[i][1], size
            )
        except ValueError:
            # 亮区候选过不了边缘精修/几何门时,退回 fixed(保持上一候选坐标)重试。
            raw_candidate = prior.copy()
            mode, match_score = "fixed fallback", 0.0
            candidate, edge = _run_edge_refinement(edge_refiner, target, raw_candidate)
            polygon, geometry = candidate_mask_geometry(
                candidate, prior, anchor_masks[i][1], size
            )
        # 纹理证据:prior 内部灰度标准差。
        texture_std = float(np.std(previous[prior >= 128]))
        evidence = {
            "appearance": match_score, "fb_consistency": 0.0, "support": 0.0,
            "texture": min(1.0, texture_std / 8.0), "texture_std": texture_std,
            "largest_unsupported_fraction": 1.0,
        }
        # 与关键帧 mask 的 IoU:衡量回退候选相对固定锚点的漂移。
        anchor_iou = mask_iou(candidate, anchor_masks[i][1])
        raw_quality = {**evidence, **geometry, "anchor_iou": anchor_iou,
                       "anchor_quality": 0.0, "score": match_score}
        quality = {
            **evidence, **geometry, "anchor_iou": anchor_iou,
            "anchor_quality": 0.0, "adjacent_mad": similarity["adjacent_mad"],
            "keyframe_mad": similarity["keyframe_mad"], "raw_flow": raw_quality,
            "edge": edge, "score": match_score, "propagation_mode": mode,
            "fallback_reason": str(reason)[:160],
        }
        # 深拷贝 region 只替换 polygon;带 box 的参考区域由最终 polygon 包围盒更新。
        updated = deepcopy(region)
        updated["polygon"] = polygon
        # box 以 [x, y, width, height] 存储。
        if "box" in updated:
            vertices = np.asarray(polygon)
            updated["box"] = [*vertices.min(axis=0).tolist(), *np.ptp(vertices, axis=0).tolist()]
        output_regions.append(updated)
        quality_by_id[region["id"]] = quality
        # next_masks 携带本帧候选 mask,供下一帧继续传播。
        next_masks.append((region, candidate))
    return {"index": int(frame["index"]), "frame_id": int(frame["frame_id"]),
            "regions": output_regions, "quality": quality_by_id}, next_masks


# 判断光流阶段的 ValueError 是否属于「允许近似回退」的预期失败。
# 参数 error:_candidate_frame 抛出的 ValueError。
# 返回:True 表示可进入亮区/固定回退——弱纹理、前后向/外观证据不足、质量分
#   不达标、锚点分歧、面积越界、mask 含孔/多分量、polygon 逼近失败等;
#   False 表示其他数据问题,应终止该方向而不是回退。
def _allows_approximate_fallback(error: ValueError) -> bool:
    message = str(error).lower()
    return any(fragment in message for fragment in (
        "weak texture", "insufficient forward/backward", "local evidence",
        "quality", "fixed anchor disagreement", "area changed", "mask contains a hole",
        "mask contains multiple components", "polygon approximation",
    ))


# 主传播路径:对 (previous → target) 计算光流候选,逐 region 通过锚点一致、
# 质量分、边缘精修与几何四道门后输出 proposal。
# 参数 previous/target:上一帧与当前帧灰度图;anchor:固定关键帧灰度图;
#   masks:(region, 上一帧 mask) 列表;anchor_masks:关键帧 (region, mask)
#   列表;frame:当前快照描述;size:原图 (宽, 高);adjacent:True 表示
#   target 紧邻 previous(锚点证据复用本次光流),False 表示另从关键帧直接
#   分析(避免只用上一步预测自我验证);check_cancel:取消回调;motion_factory:
#   光流工厂;edge_refiner:精修回调;similarity:similarity_gate 结果(其
#   MAD 分数只写入诊断,门禁本身已由调用方判定)。
# 返回:(proposal, next_masks):proposal 含 index/frame_id/regions(更新后
#   polygon 与 box)/quality(逐 region 诊断);next_masks 为 (region, 候选
#   mask) 列表。
# 异常:任一道门失败抛 ValueError(消息带 region id),由调用方决定终止方向
#   或进入回退;cv2.error 等其他异常直接上抛使整份计划失败。
def _candidate_frame(previous, target, anchor, masks, anchor_masks, frame, size,
                     adjacent, check_cancel, motion_factory, edge_refiner, similarity):
    """局部作用域释放临时光流；同时持有关键帧、上一步和当前 mask 状态。"""
    motion, warped, qualities = _analyse_pair(previous, target, masks, check_cancel, motion_factory)
    # 锚点证据来源:相邻帧复用 previous→target 的光流;非相邻帧另从固定关键帧
    # 直接分析,避免只用上一步预测自我验证。
    if adjacent:
        anchor_motion, anchor_warped, anchor_qualities = motion, warped, qualities
    else:
        anchor_motion, anchor_warped, anchor_qualities = _analyse_pair(
            anchor, target, anchor_masks, check_cancel, motion_factory
        )
    output_regions, quality_by_id = [], {}
    next_masks = []
    for i, ((region, prior), raw_candidate, raw_anchor_candidate) in enumerate(
            zip(masks, warped, anchor_warped)):
        check_cancel()
        try:
            # 第一道门:raw 光流候选的几何(面积比)与固定锚点一致性。
            _, raw_geometry = candidate_mask_geometry(
                raw_candidate, prior, anchor_masks[i][1], size
            )
            # raw 候选与「关键帧直接传播候选」的 IoU 至少 0.85。
            raw_anchor_iou = mask_iou(raw_candidate, raw_anchor_candidate)
            if raw_anchor_iou < 0.85:
                raise ValueError(f"fixed anchor disagreement ({raw_anchor_iou:.3f})")
            # 锚点质量:关键帧直接传播证据中外观/往返一致/纹理的最小值。
            raw_anchor_quality = min(
                anchor_qualities[i][field] for field in ("appearance", "fb_consistency", "texture")
            )
            raw_quality = {
                **qualities[i], **raw_geometry, "anchor_iou": raw_anchor_iou,
                "anchor_quality": raw_anchor_quality,
            }
            # 综合质量分取五项证据的最小值(任何一项弱即整体弱)。
            raw_quality["score"] = min(
                raw_quality[field] for field in
                ("appearance", "fb_consistency", "texture", "anchor_iou", "anchor_quality")
            )
            # 低于 0.25 的 raw 候选拒绝并进入回退。
            if raw_quality["score"] < FLOW_QUALITY_THRESHOLD:
                raise ValueError(
                    f"quality {raw_quality['score']:.3f} below threshold {FLOW_QUALITY_THRESHOLD:.3f}"
                )

            # 对 raw 候选与关键帧直接传播候选分别做边缘精修。
            check_cancel()
            candidate, edge = _run_edge_refinement(edge_refiner, target, raw_candidate)
            check_cancel()
            anchor_candidate, _ = _run_edge_refinement(
                edge_refiner, target, raw_anchor_candidate
            )
            check_cancel()

            # 第二道门:精修后候选的几何门(拓扑、面积比、polygon 转换)。
            polygon, final_geometry = candidate_mask_geometry(
                candidate, prior, anchor_masks[i][1], size
            )
            # 精修后复核锚点一致性(IoU 至少 0.85)。
            anchor_iou = mask_iou(candidate, anchor_candidate)
            if anchor_iou < 0.85:
                raise ValueError(f"fixed anchor disagreement ({anchor_iou:.3f})")
            # 光流证据定义在 source 坐标；选择 refined/fallback 后重新执行相同证据门。
            final_evidence = motion.evidence(prior)
            final_anchor_evidence = anchor_motion.evidence(anchor_masks[i][1])
            anchor_quality = min(
                final_anchor_evidence[field]
                for field in ("appearance", "fb_consistency", "texture")
            )
            quality = {
                **final_evidence, **final_geometry, "anchor_iou": anchor_iou,
                "anchor_quality": anchor_quality, "adjacent_mad": similarity["adjacent_mad"],
                "keyframe_mad": similarity["keyframe_mad"], "raw_flow": raw_quality,
                "edge": edge,
                "propagation_mode": "flow", "fallback_reason": "",
            }
            quality["score"] = min(
                quality[field] for field in
                ("appearance", "fb_consistency", "texture", "anchor_iou", "anchor_quality")
            )
            if quality["score"] < FLOW_QUALITY_THRESHOLD:
                raise ValueError(
                    f"quality {quality['score']:.3f} below threshold {FLOW_QUALITY_THRESHOLD:.3f}"
                )
            # 深拷贝 region 只替换 polygon;带 box 的参考区域由最终 polygon 包围盒更新。
            updated = deepcopy(region)
            updated["polygon"] = polygon
            if "box" in updated:
                vertices = np.asarray(polygon)
                updated["box"] = [*vertices.min(axis=0).tolist(), *np.ptp(vertices, axis=0).tolist()]
            output_regions.append(updated)
            quality_by_id[region["id"]] = quality
            next_masks.append((region, candidate))
        except ValueError as error:
            # 任何一道门失败都附上 region id 抛出,由调用方决定终止方向或回退。
            raise ValueError(f"region {region['id']}: {error}") from error
    proposal = {"index": int(frame["index"]), "frame_id": int(frame["frame_id"]),
                "regions": output_regions, "quality": quality_by_id}
    return proposal, next_masks


# 传播主入口:校验请求 → 载入并核对全部快照 → 关键帧 mask 初始化 → 左右两个
# 方向逐帧传播(相似度门 → 光流候选 → 允许时近似回退)→ 复查快照未变 →
# 排序输出。任何时刻取消或失败,全部临时结果立即丢弃且不写任何文件。
# 参数 request:版本化请求字典(合同见 _validate_request);cancelled:无参
#   回调,返回 True 表示外部请求取消;progress:接收进度字典的回调(completed/
#   total/message);motion_factory/edge_refiner:可注入的光流与精修回调。
# 返回:schema_version 3 的结果字典——成功时含 success=True、cancelled=False、
#   metric_id、threshold、frame_step、key_index、start_index/end_index(含
#   关键帧的连续闭区间端点)、left_stop/right_stop(各方向停止原因)与按
#   index 升序的 proposals;取消时 {"cancelled": True, "error": ...};失败时
#   {"success": False, "cancelled": False, "error": <原因>}。本函数不抛异常。
# 副作用:只读快照文件并调用 progress 回调;不写文件、不删除任何数据。
def propagate(request: dict, *, cancelled: Callable[[], bool] | None = None,
              progress: Callable[[dict], None] | None = None,
              motion_factory=MotionPair, edge_refiner=refine) -> dict:
    """消耗独立图像快照，返回连续候选闭区间；失败/取消丢弃全部临时结果。"""
    # 取消检查:在各阶段间隙轮询外部回调,命中即抛 Cancelled(最外层转为结果字典)。
    def check_cancel():
        if cancelled is not None and cancelled():
            raise Cancelled("polygon analysis cancelled")

    # 进度上报:上报前后各检查一次取消,回调内抛出的异常原样上抛。
    def report(completed, total, message):
        check_cancel()
        if progress is not None:
            progress({"completed": completed, "total": total, "message": message})
        check_cancel()

    try:
        check_cancel()
        frames, regions, key, threshold, frame_step = _validate_request(request)
        # 关键帧在 frames 中的下标,左右两个方向从这里出发。
        key_position = next(i for i, frame in enumerate(frames) if frame["index"] == key)
        # total 为待分析帧数(不含关键帧);completed 统计已处理帧。
        total, completed = len(frames) - 1, 0
        report(0, total, "Validating immutable PNG snapshots")
        snapshots = []
        # 每张图都先验证，坏图使整份计划失效；预检和方向分析最多保留 3 张灰度图。
        for frame in frames:
            check_cancel()
            image, snapshot = _load_image(Path(frame["image_path"]))
            # 快照实际内容必须与请求声明的 image_sha256 一致,否则整份计划失效。
            if snapshot.digest.hex() != frame["image_sha256"]:
                raise ValueError("image_sha256 differs from the PNG snapshot")
            snapshots.append(snapshot)
            if frame["index"] == key:
                anchor = image
            del image
        # 分析尺寸以关键帧快照的 (宽, 高) 为准。
        size = snapshots[key_position].size
        # 内存预算:region 数 × 关键帧像素数 × 3 字节不得超过 128 MiB。
        if len(regions) * anchor.size * 3 > MAX_MASK_BYTES:
            raise ValueError("polygon masks exceed the 128 MiB working-mask budget")
        # 关键帧 polygon 一次性栅格化为分析分辨率 mask 并过拓扑门(单环、无孔、
        # 不贴边);之后各帧都从 mask 传播,不再重栅格化。
        anchor_masks = []
        for region in regions:
            check_cancel()
            points = validate_polygon(region["polygon"], size)
            mask = polygon_to_mask(points, size, anchor.shape)
            single_mask_contour(mask)
            anchor_masks.append((region, mask))
        proposals = []
        # 左右方向的停止原因;初值为到达序列边界。
        stops = {"left": "source boundary", "right": "source boundary"}
        # 两个方向独立传播:masks 是「上一步」mask 状态,anchor_masks 恒为关键帧。
        for direction, name in ((-1, "left"), (1, "right")):
            previous = anchor
            masks = anchor_masks
            next_masks = anchor_masks
            target = anchor
            position = key_position + direction
            while 0 <= position < len(frames):
                check_cancel()
                frame = frames[position]
                # 尺寸与关键帧不一致:终止该方向,不产出该帧候选。
                if snapshots[position].size != size:
                    stops[name] = f"frame {frame['index']}: image dimensions changed"
                    break
                # 重新读图并与预检 Snapshot 逐字段比对,期间被替换即失败。
                target, _ = _load_image(snapshots[position].path, snapshots[position])
                # 相似度门:与上一帧、与固定关键帧的距离都必须严格小于阈值。
                similarity = similarity_gate(previous, target, anchor, threshold)
                if not similarity["accepted"]:
                    # 停止原因记录两项 MAD 与阈值,供客户端展示与审计。
                    stops[name] = (
                        f"frame {frame['index']}: similarity adjacent "
                        f"{similarity['adjacent_mad']:.6f} / keyframe "
                        f"{similarity['keyframe_mad']:.6f} >= threshold {threshold:.6f}"
                    )
                    completed += 1
                    report(completed, total, stops[name])
                    break
                try:
                    # 构造该帧候选;adjacent 标记是否紧邻上一帧(决定锚点证据来源)。
                    proposal, next_masks = _candidate_frame(previous, target, anchor, masks, anchor_masks,
                                                            frame, size, abs(position - key_position) == 1,
                                                            check_cancel, motion_factory, edge_refiner, similarity)
                    proposals.append(proposal)
                except ValueError as error:
                    # 只有预期性失败(见 _allows_approximate_fallback)才回退,其余终止方向。
                    if not _allows_approximate_fallback(error):
                        stops[name] = f"frame {frame['index']}: {error}"
                        completed += 1
                        report(completed, total, stops[name])
                        break
                    # 回退 proposal 照常计入结果,并显式携带 fallback 标记与原因。
                    proposal, next_masks = _fallback_candidate_frame(
                        previous, target, masks, anchor_masks, frame, size,
                        check_cancel, edge_refiner, similarity, error,
                    )
                    proposals.append(proposal)
                completed += 1
                report(completed, total, f"Analysed frame {frame['index']}")
                # 推进到下一帧:上一帧状态替换为当前帧。
                previous = target
                masks = next_masks
                position += direction
        # 分析结束后统一复查全部快照 stat 身份:期间被替换则整份计划失效。
        check_cancel()
        if any(_file_signature(snapshot.path) != snapshot.stat for snapshot in snapshots):
            raise ValueError("image snapshot changed during analysis")
        # 两个方向的 proposal 按帧 index 升序合并。
        proposals.sort(key=lambda proposal: proposal["index"])
        # 输出连续闭区间端点:含关键帧与全部产出 proposal 的 index。
        indices = [key] + [proposal["index"] for proposal in proposals]
        return {"schema_version": 3, "success": True, "cancelled": False, "metric_id": METRIC_ID,
                "threshold": threshold, "frame_step": frame_step, "key_index": key, "start_index": min(indices), "end_index": max(indices),
                "left_stop": stops["left"], "right_stop": stops["right"], "proposals": proposals}
    except Cancelled as error:
        # 协作取消:转为 cancelled 终态结果,不抛出。
        return {"schema_version": 3, "success": False, "cancelled": True, "error": str(error)}
    except (ValueError, TypeError, OSError, OverflowError, cv2.error) as error:
        # 其余一切校验/解码/文件错误:转为失败终态结果,错误信息随字典返回。
        return {"schema_version": 3, "success": False, "cancelled": False, "error": str(error)}
