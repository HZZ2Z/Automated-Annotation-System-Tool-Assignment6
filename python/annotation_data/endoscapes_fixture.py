# Endoscapes2023 多边形验收夹具(poly fixture)构建器(annotation_data 包核心库)。
#
# 用途:把官方 Endoscapes2023 数据集中指定视频的 5-30 帧(原生帧号步长 25)
# 整理为一个小型、可复现、可审计的本地验收工作区,全程不修改数据集本体:
# 输出 manifest.json(dataset-manifest-v1 清单)+ frames/ 帧图 + 每个播放帧
# 一条的 Model Output V1 记录 JSONL(仅关键帧带种子 polygon)+
# provenance.json 溯源文件。
#
# 角色与协作:唯一入口 build_fixture 由 python/prepare_endoscapes_poly_fixture.py
# 命令行脚本调用;生成的夹具目录随后供 Godot Main(严格 Source 插件)与
# python/run_endoscapes_poly_acceptance.py 消费。种子 mask -> polygon 转换
# 依赖 annotation_data.polygon_geometry 的 mask_to_polygon /
# polygon_to_mask / mask_iou(单环拓扑门禁与 IoU 度量);发布前全部产出经
# annotation_data.contracts.validate_instance 过 JSON Schema 门禁。
#
# 工程约定:源数据只读、同级 staging + 原子改名发布、SHA-256 全程追溯、
# 门禁失败直接抛 ValueError 不静默降级、溯源文件不记录数据集绝对路径。
"""Build a small, auditable Endoscapes workspace without modifying the dataset."""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path
import shutil
import tempfile

import cv2
import numpy as np

from .contracts import validate_instance
from .polygon_geometry import mask_iou, mask_to_polygon, polygon_to_mask


# 相邻取样帧的原生帧号步长:start_frame 与 end_frame 的差值必须是它的整数倍。
FRAME_STEP = 25
# 夹具允许的帧数上下限:验收流程只针对 5-30 帧的小型工作区。
MIN_FRAMES = 5
MAX_FRAMES = 30
# 种子 mask 触及图像边界时向内收缩的像素数:移除外围 2 像素得到有界的 V1
# 种子(2 像素是 Godot 解码后传播仍不触边的实测余量;1 像素会被光流推回
# 边界,3 像素则额外扩大候选范围)。该收缩在 provenance.json 中声明为有损转换。
BOUNDARY_INSET_PIXELS = 2
# Model Output V1 记录文件的文件名基名:夹具内 JSONL 落盘为 <MODEL_VERSION>.jsonl。
MODEL_VERSION = "model_output_v1"
# 写入 manifest 的分类体系(taxonomy)版本标识。
TAXONOMY_VERSION = "endoscapes2023-insseg-v1"
# Endoscapes2023 实例分割类别 ID -> (类别名, region kind) 映射;类别名与
# kind(anatomy=解剖结构 / tool=手术器械)直接用作 V1 region 的 class 与
# kind 字段。关键帧 CSV 标签中的类别 ID 必须落在此映射内。
CATEGORIES = {
    1: ("cystic_plate", "anatomy"),
    2: ("calot_triangle", "anatomy"),
    3: ("cystic_artery", "anatomy"),
    4: ("cystic_duct", "anatomy"),
    5: ("gallbladder", "anatomy"),
    6: ("tool", "tool"),
}


# 构建请求(不可变 frozen dataclass):一次夹具构建的全部选择参数。
# 关键属性:dataset_root=官方数据集根目录(需含 train/ 图像与 insseg/ 的
# .npy mask 堆叠与 .csv 类别标签);output=要新建的夹具目录;
# video_id/start_frame/end_frame/key_frame/instance_index=选择视频、步长 25
# 的帧区间、关键帧原生帧号与关键帧上的实例序号;copy_images=True 时把帧图
# 复制进夹具,默认 False 只放指向原图的符号链接。
@dataclass(frozen=True)
class BuildRequest:
    dataset_root: Path
    output: Path
    video_id: int
    start_frame: int
    end_frame: int
    key_frame: int
    instance_index: int
    copy_images: bool = False


# 流式计算单个文件的 SHA-256 摘要。
# 参数 path:任意已存在文件;返回:64 位小写十六进制摘要字符串。
# 按 1 MiB 分块读取,避免大文件一次性载入内存;文件不可读时抛 OSError。
# 用于帧图与关键帧 mask/CSV 的内容追溯(写入 manifest/provenance)。
def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


# 把对象写成规范化 JSON 文件:UTF-8、两空格缩进、键排序、结尾换行;
# ensure_ascii=False 保留非 ASCII 字符,allow_nan=False 在值含 NaN/Infinity
# 时抛 ValueError(从写入端保证 JSON 合法)。
# 参数 path:目标文件;value:任意可 JSON 序列化对象;副作用:覆盖写入 path。
def _write_json(path: Path, value: object) -> None:
    path.write_text(
        json.dumps(value, ensure_ascii=False, allow_nan=False, indent=2, sort_keys=True)
        + "\n",
        encoding="utf-8",
    )


# 在数据集 train/ 目录递归定位某帧的唯一图像文件。
# 参数 root:数据集根目录;video_id/frame:构成文件名主干 <video_id>_<frame>。
# 门禁(违反抛 ValueError):命中为空(missing frame)或多于一个(duplicate
# frame)都拒绝,保证帧身份无歧义;只接受 .jpg/.jpeg/.png(大小写不敏感)
# 的常规文件。返回:匹配到的唯一路径;副作用:无。
def _discover_image(root: Path, video_id: int, frame: int) -> Path:
    stem = f"{video_id}_{frame}"
    matches = sorted(
        path for path in (root / "train").rglob(f"{stem}.*")
        if path.is_file() and path.suffix.lower() in {".jpg", ".jpeg", ".png"}
    )
    if not matches:
        raise ValueError(f"missing frame {stem} in dataset train directory")
    if len(matches) != 1:
        raise ValueError(f"duplicate frame {stem}: expected one image, found {len(matches)}")
    return matches[0]


# 校验请求的帧选择约束,并展开为取样帧号列表。
# 参数 request:构建请求(只读)。
# 返回:从 start_frame 到 end_frame(含)按 FRAME_STEP 步长展开的帧号列表。
# 逐条门禁(违反抛 ValueError):video_id/start_frame/end_frame/key_frame/
# instance_index 必须是精确 int 的非负数(bool 不算);end 不得早于 start;
# start/end 差值必须是 25 的整数倍;展开帧数必须落在 5-30 之间;key_frame
# 必须属于展开后的帧序列。副作用:无。
def _frame_numbers(request: BuildRequest) -> list[int]:
    # 五个整型字段逐一检查:type 精确匹配 int,bool 会被拒绝。
    for name in ("video_id", "start_frame", "end_frame", "key_frame", "instance_index"):
        value = getattr(request, name)
        if type(value) is not int or value < 0:
            raise ValueError(f"{name} must be a nonnegative integer")
    if request.end_frame < request.start_frame:
        raise ValueError("end frame must not precede start frame")
    if (request.end_frame - request.start_frame) % FRAME_STEP:
        raise ValueError("start/end frame difference must be in multiples of 25")
    # 按步长 25 展开闭区间 [start, end] 内的全部取样帧号。
    frames = list(range(request.start_frame, request.end_frame + 1, FRAME_STEP))
    # 帧数门禁:夹具只承载 5-30 帧的小工作区。
    if not MIN_FRAMES <= len(frames) <= MAX_FRAMES:
        raise ValueError("fixture must contain 5 to 30 frames")
    # 关键帧必须恰好落在取样序列上,否则无法定位种子。
    if request.key_frame not in frames:
        raise ValueError("key frame must belong to the requested step-25 range")
    return frames


# 加载关键帧实例 mask 与 CSV 类别标签,生成可作为单个 V1 polygon 的种子。
# 参数 request:构建请求;size:源图像 (width, height)。
# 返回:(polygon, seed_info) 二元组:polygon 是过 polygon_geometry 全部门禁
# 的浮点顶点列表;seed_info 是溯源/度量字典(源文件相对路径与 SHA-256、
# 实例序号、类别、像素计数、边界收缩量、lossless 标志、保留 IoU、polygon
# 回栅格 IoU、触边警告文案),原样并入 provenance.json 的 keyframe_seed。
# 逐条门禁(违反抛 ValueError):mask/CSV 必须配对存在且可读;mask 形状与
# 源图一致、数值有限、严格 0/1 二值;CSV 行数与 mask 实例数一致;
# instance_index 不得越界;所选实例类别 ID 必须在 CATEGORIES 内;种子必须
# 能提取为单个合法 V1 外环。副作用:无(数据集只读)。
def _load_seed(request: BuildRequest, size: tuple[int, int]) -> tuple[list[list[float]], dict]:
    stem = f"{request.video_id}_{request.key_frame}"
    mask_path = request.dataset_root / "insseg" / f"{stem}.npy"
    labels_path = request.dataset_root / "insseg" / f"{stem}.csv"
    if not mask_path.is_file() or not labels_path.is_file():
        raise ValueError(f"key frame mask/CSV pair is missing for {stem}")
    # .npy 存全部实例的 0/1 mask 堆叠,.csv 存逐实例类别 ID;np.load 禁用
    # pickle(allow_pickle=False)防反序列化执行,np.loadtxt 的 ndmin=1 保证
    # 单实例 CSV 也读成一维数组。
    try:
        masks = np.load(mask_path, allow_pickle=False)
        labels = np.loadtxt(labels_path, delimiter=",", ndmin=1)
    except (OSError, ValueError) as error:
        raise ValueError(f"could not read key frame mask/CSV: {error}") from error
    # mask 堆叠必须是 (N, H, W) 三维数组,且 H/W 与源图一致。
    if masks.ndim != 3 or masks.shape[1:] != (size[1], size[0]):
        raise ValueError("key frame mask dimensions do not match the source images")
    # mask 值必须是有限数字,且严格 0/1 二值。
    if not np.issubdtype(masks.dtype, np.number) or not np.isfinite(masks).all():
        raise ValueError("key frame masks must contain finite numeric values")
    if not np.all((masks == 0) | (masks == 1)):
        raise ValueError("key frame masks must be binary 0/1 arrays")
    # CSV 每行一个实例的类别 ID,行数必须与 mask 实例数一致。
    if labels.ndim != 1 or len(labels) != len(masks):
        raise ValueError("mask/CSV count mismatch for key frame instances")
    if request.instance_index >= len(masks):
        raise ValueError("instance index is outside the key frame mask array")
    # 类别 ID 以 float 读入,必须恰为整数值且在 Endoscapes 类别映射内。
    label = float(labels[request.instance_index])
    if not label.is_integer() or int(label) not in CATEGORIES:
        raise ValueError("selected instance category is not in the Endoscapes taxonomy")

    # 取出所选实例 mask 的独立副本作为度量基准 original;seed 是用于提取
    # polygon 的种子,触边时会在其上收缩,original 保持原样用于算 IoU。
    original = masks[request.instance_index].astype(np.uint8, copy=True)
    seed = original.copy()
    # 检查种子是否触及图像四边(任一边界行/列含前景)。
    touches = bool(
        seed[0].any() or seed[-1].any() or seed[:, 0].any() or seed[:, -1].any()
    )
    # 触边即向内收缩 BOUNDARY_INSET_PIXELS 像素得到有界种子;未触边零收缩。
    inset = BOUNDARY_INSET_PIXELS if touches else 0
    if touches:
        seed[:inset, :] = 0
        seed[-inset:, :] = 0
        seed[:, :inset] = 0
        seed[:, -inset:] = 0
    # 原 mask 与收缩后种子的 IoU:量化触边裁切造成的损失。
    retained_iou = mask_iou(original * 255, seed * 255)
    # 尝试把种子提取为单个合法 V1 外环:单连通、无孔、不触边、近似还原
    # IoU 达标、顶点数受限等门禁都在 mask_to_polygon 内;失败则拒绝构建,
    # 不静默降级为 box 或跳过。
    try:
        polygon = mask_to_polygon(seed * 255, size)
    except ValueError as error:
        raise ValueError(f"selected instance cannot form one V1 polygon: {error}") from error
    # polygon 回栅格化后再算一次 IoU:量化多边形对种子的拟合精度。
    raster = polygon_to_mask(np.asarray(polygon, np.float64), size, seed.shape)
    polygon_iou = mask_iou(raster, seed * 255)
    category_id = int(label)
    category, kind = CATEGORIES[category_id]
    # seed_info 各字段:源文件相对路径与内容 SHA-256(SHA-256 追溯)、实例
    # 序号与类别、原/种子像素计数、收缩量、无损标志、两个 IoU 与触边警告
    # (触边时声明有损转换,未触边时为空串)。
    return polygon, {
        "source_mask_file": f"insseg/{stem}.npy",
        "source_mask_sha256": _sha256(mask_path),
        "source_labels_file": f"insseg/{stem}.csv",
        "source_labels_sha256": _sha256(labels_path),
        "instance_index": request.instance_index,
        "category_id": category_id,
        "category": category,
        "kind": kind,
        "source_pixel_count": int(np.count_nonzero(original)),
        "seed_pixel_count": int(np.count_nonzero(seed)),
        "boundary_inset_pixels": inset,
        # 未触边才算无损;触边即声明有损(见 warning)。
        "lossless": not touches,
        "retained_iou": retained_iou,
        "polygon_raster_iou": polygon_iou,
        "warning": (
            "Source mask touched the image boundary; a two-pixel outer border was removed "
            "to create a bounded V1 seed. This is a declared lossy fixture transform."
            if touches else ""
        ),
    }


# 发布前的 schema 门禁:manifest 与全部 Model Output V1 记录逐条过合同校验。
# 参数 manifest:待发布的 dataset-manifest-v1 字典;records:逐帧记录列表。
# 返回:无;任何一条校验错误都以 ValueError 抛出(消息附第一条错误),
# 保证只有合法数据会进入 staging 发布,失败不静默。
def _validate_outputs(manifest: dict, records: list[dict]) -> None:
    errors = validate_instance(manifest, "dataset-manifest-v1.schema.json")
    if errors:
        raise ValueError("generated manifest is invalid: " + errors[0])
    # 逐条记录过 model_output_v1.schema.json;index 用于错误消息定位。
    for index, record in enumerate(records):
        errors = validate_instance(record, "model_output_v1.schema.json")
        if errors:
            raise ValueError(f"generated model record {index} is invalid: {errors[0]}")


# 构建一份 Endoscapes 多边形验收夹具(功能见英文 docstring)。
# 参数 request:构建请求;返回:人可读结果摘要字典(末尾 return 的八键:
# 输出路径、帧数、关键帧播放下标/原始帧号、类别 ID/名、收缩像素数、保留 IoU)。
# 前置约束(违反抛 ValueError):数据集根目录必须是存在的目录;output 不得
# 已存在(含符号链接),拒绝覆盖;output 不得等于数据集根目录或位于其内部。
# 副作用:在 output 同级创建临时 staging 目录,写完全部夹具文件后原子改名
# 为 output;任何失败都删除 staging 并原样抛出;源数据全程只读。
def build_fixture(request: BuildRequest) -> dict:
    """Create one fixture by sibling staging + rename; all dataset inputs stay read-only."""
    # 把两个路径解析为绝对真实路径,并用解析结果重建请求,后续比较与写入
    # 全部基于规范路径。
    dataset_root = request.dataset_root.resolve()
    output = request.output.resolve()
    request = BuildRequest(dataset_root, output, request.video_id, request.start_frame,
                           request.end_frame, request.key_frame, request.instance_index,
                           request.copy_images)
    if not dataset_root.is_dir():
        raise ValueError("dataset root does not exist")
    # 拒绝覆盖:目标已存在(含悬空符号链接)即失败,夹具目录只能新建。
    if output.exists() or output.is_symlink():
        raise ValueError("output already exists; choose a new destination")
    # 保护源数据:目标不得就是数据集根目录,也不得嵌在数据集内部。
    if output == dataset_root or dataset_root in output.parents:
        raise ValueError("output must be outside the source dataset")
    # 展开并校验帧号,再逐帧定位唯一源图像。
    frames = _frame_numbers(request)
    sources = [_discover_image(dataset_root, request.video_id, frame) for frame in frames]
    # OpenCV 解码全部帧图(IMREAD_COLOR 强制三通道),任一解码失败即拒绝。
    decoded = [cv2.imread(str(path), cv2.IMREAD_COLOR) for path in sources]
    if any(image is None for image in decoded):
        raise ValueError("one or more source frames could not be decoded")
    # 所有帧必须同尺寸,关键帧 mask 的尺寸门禁依赖该公共 (width, height)。
    height, width = decoded[0].shape[:2]
    if any(image.shape[:2] != (height, width) for image in decoded):
        raise ValueError("all source frames must have identical dimensions")
    # 加载关键帧实例并生成种子 polygon(含全部溯源度量)。
    polygon, seed_info = _load_seed(request, (width, height))

    # 逐帧溯源条目:播放下标(0..N-1)、原始帧号、相对路径与文件 SHA-256。
    frame_info = [
        {
            "playback_index": index,
            "original_frame_id": frame,
            "source_file": f"train/{path.name}",
            "sha256": _sha256(path),
        }
        for index, (frame, path) in enumerate(zip(frames, sources))
    ]
    # 源身份摘要:按帧序把 "帧号\0SHA-256\n" 喂入同一个 SHA-256,使一个摘要
    # 同时绑定各帧的内容与顺序。
    source_hasher = hashlib.sha256()
    for info in frame_info:
        source_hasher.update(f"{info['original_frame_id']}\0{info['sha256']}\n".encode())
    # 数据集与来源的稳定标识(只含视频与帧区间,不含绝对路径)。
    dataset_id = f"endoscapes-{request.video_id}-{request.start_frame}-{request.end_frame}"
    source_name = f"endoscapes-video-{request.video_id}"
    # dataset-manifest-v1 清单:帧以连续播放索引 0..N-1 表示,nominal_fps=1.0
    # 即播放下标视为秒;原始帧号与逐帧 SHA-256 只进 provenance.json。
    manifest = {
        "schema_version": 1,
        "dataset_id": dataset_id,
        "source_name": source_name,
        "source_sha256": source_hasher.hexdigest(),
        "width": width,
        "height": height,
        "frame_count": len(frames),
        "nominal_fps": 1.0,
        "frames": [
            {"frame": index, "time_s": float(index),
             "image_path": f"frames/frame_{index:06d}{path.suffix.lower()}"}
            for index, path in enumerate(sources)
        ],
        "model_version": MODEL_VERSION,
        "taxonomy_version": TAXONOMY_VERSION,
    }
    # 关键帧在播放序列中的下标;region id 由原始帧号与实例序号构成,便于回溯。
    key_index = frames.index(request.key_frame)
    # 唯一一条种子 region:类别与 kind 来自 Endoscapes 映射,几何是过门禁的
    # polygon;它就是这份夹具的模型基线标注。
    region = {
        "id": f"endoscapes-{request.video_id}-{request.key_frame}-instance-{request.instance_index}",
        "class": seed_info["category"],
        "kind": seed_info["kind"],
        "polygon": polygon,
    }
    # 每个播放帧一条 Model Output V1 记录;只有关键帧带种子 polygon,其余帧
    # regions 为空,等待后续人工/模型补标。
    records = [
        {
            "schema_version": 1,
            "source": source_name,
            "frame": index,
            "time_s": float(index),
            "regions": [region] if index == key_index else [],
        }
        for index in range(len(frames))
    ]
    # 发布前 schema 门禁:失败则不会产生任何输出。
    _validate_outputs(manifest, records)
    # 溯源文件:夹具类型、数据集名/ID、帧步长、复制模式、逐帧原始信息与
    # 关键帧种子度量;evidence_limit 声明只有关键帧有实例 mask,目标帧证据
    # 只是定性审查,不充当密集 IoU 真值。
    provenance = {
        "schema_version": 1,
        "fixture_type": "endoscapes-poly-acceptance",
        "dataset_name": "Endoscapes2023",
        "dataset_id": dataset_id,
        "frame_step": FRAME_STEP,
        "copy_mode": "copy" if request.copy_images else "symlink",
        "frames": frame_info,
        "keyframe_seed": {"original_frame_id": request.key_frame,
                          "playback_index": key_index, **seed_info},
        "evidence_limit": (
            "Only the keyframe has an instance mask. Target-frame propagation is qualitative "
            "review evidence and is not dense-IoU ground truth."
        ),
    }

    # 原子发布:staging 建在 output 同级(保证 rename 在同一文件系统内原子),
    # 写完全部内容后一次性改名;中途任何异常都会清理 staging 并原样抛出。
    output.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix=f".{output.name}.staging-", dir=output.parent))
    try:
        (staging / "frames").mkdir()
        # 帧图默认放符号链接引用原图(数据集零复制),copy_images=True 才真正复制。
        for source, entry in zip(sources, manifest["frames"]):
            destination = staging / entry["image_path"]
            if request.copy_images:
                shutil.copyfile(source, destination)
            else:
                destination.symlink_to(source)
        _write_json(staging / "manifest.json", manifest)
        # Model Output V1 记录:紧凑 JSON 一行一条,写完 flush + fsync 确保落盘。
        with (staging / f"{MODEL_VERSION}.jsonl").open("w", encoding="utf-8") as stream:
            for record in records:
                stream.write(json.dumps(record, ensure_ascii=False, allow_nan=False,
                                        sort_keys=True, separators=(",", ":")) + "\n")
            stream.flush()
            os.fsync(stream.fileno())
        _write_json(staging / "provenance.json", provenance)
        # 同目录原子改名:输出要么完整存在,要么不存在,不留半写状态。
        staging.replace(output)
    except BaseException:
        # 任何失败(包括 KeyboardInterrupt)都删除 staging 并原样抛出,不静默吞错。
        shutil.rmtree(staging, ignore_errors=True)
        raise
    # 构建结果摘要:关键帧身份、类别、有损转换量与保留 IoU,供命令行打印。
    return {
        "output": str(output),
        "frame_count": len(frames),
        "key_playback_index": key_index,
        "key_original_frame_id": request.key_frame,
        "category_id": seed_info["category_id"],
        "category": seed_info["category"],
        "boundary_inset_pixels": seed_info["boundary_inset_pixels"],
        "retained_iou": seed_info["retained_iou"],
    }
