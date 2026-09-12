# Poly 轮廓运动传播

`Poly 光流 + 边缘精修`（`polygon_flow` / `poly-sim-flow-edge-v1`）是 Batch 中必须由用户明确选择的备选，不再是默认路径。默认路径已由批准的 `2026-09-11-sam-video-batch-design.md` 改为 `sam_video`；SAM 失败不得静默回退到 Poly 或 copy。本文仍是 Poly 模式的权威算法、安全门与历史证据说明。

Poly 对真实 Source 帧做相似度门、DIS 光流和局部边缘精修，生成每帧独立、可编辑的 polygon 候选。它是当前 NumPy/OpenCV 环境可复现的保守基线；候选必须人工检查，真实手术视频的密集精度和人工节时尚未测量。

## 使用

1. 打开 Source，在参考帧绘制或修正至少一个 Poly。
2. 打开“批量”，在高级算法中明确选择“Poly 光流 + 边缘精修”，按需要调整可见的相似帧差异阈值（该模式默认 `0.10`），点击“分析 Poly 光流与边缘”。
3. 检查候选首末帧、抽样步长、逐帧预览、停止原因，以及光流/亮区/固定回退和边缘诊断；可以缩短范围，但必须包含参考帧。
4. 选择覆盖或合并后应用。应用保存为一个全局 undo/redo 命令，目标帧仍为待检查。
5. 逐帧检查后再确认；低 MAD、光流质量或边缘分数都不会自动确认标注。

只传播参考帧中带 `polygon` 的区域。覆盖模式只保留传播得到的参考 Poly；合并模式按同一 `id` 替换/增加参考 Poly，并保留目标帧独有区域。类别、kind、track/conf 等非几何字段来自参考区域；目标 record 的 source/frame/time 身份不变。若参考区域同时有 box，box 由最终 polygon 包围盒更新。固定坐标复制仍作为兼容/诊断选项保留，但不是默认算法。

## 同一快照上的相似度门

Godot 先把最多 30 张实际 Source 图像保存为任务私有的冻结 PNG，同时记录 PNG SHA-256、Source entry、源图像、当前标注和确认状态摘要。Python 只读取这些快照；Godot 在接受结果和提交前再次校验同一批像素及元数据。

每张灰度图用 OpenCV `INTER_AREA` 缩小到 64×64，MAD 为对应像素绝对差均值除以 255。每个目标同时要求：

- 相邻方向：上一步实际帧与目标帧 MAD 严格小于用户阈值；
- 固定锚点：人工参考帧与目标帧 MAD 也严格小于同一阈值。

任一条件失败，该方向立即停止，且该帧不会构造光流或运行边缘精修。相似度只是在全图外观上限制候选段，不证明对象位置或轮廓正确。

## 光流、边缘精修与停止规则

关键帧 polygon 只在初始化时栅格化。后续用 [OpenCV DIS 光流](https://docs.opencv.org/4.x/dc/d6b/group__video__track.html)和[反向映射](https://docs.opencv.org/4.x/da/d54/group__imgproc__transform.html)传播上一帧已接受 mask：

`M_t(x) = M_(t-1)(x + B_t(x))`，其中 `B_t` 是当前帧到前一帧的光流。

正反向一致性检查 `F(x) + B(x + F(x))`，同时核查目标内部纹理、重映射灰度证据和局部不可靠分量。每个非相邻目标另从固定人工参考帧直接估计并与逐帧结果比较，避免只用上一步预测自我验证。

| 条件 | 当前固定规则 |
|---|---|
| 分析分辨率 | 保持比例，长边最多 1024 px；输出映射回原图坐标 |
| 相似度 | 64×64 `INTER_AREA` 灰度 MAD；相邻与固定关键帧都严格 `<` UI 阈值，默认 0.10 |
| 可见证据 | 内部有效像素至少 36；纹理标准差至少 2；前后向与外观联合支持率至少 0.05 |
| 局部异常 | 不可靠连通块达到 `max(64, 内部面积×0.98)` 时才拒绝光流并进入回退 |
| 面积变化 | 相邻 mask 比例 0.75–1.33，相对关键帧 0.60–1.67 |
| 固定锚点 | 逐帧与直接传播 mask IoU 至少 0.85 |
| 光流质量 | 外观、一致性、纹理、锚点 IoU、锚点质量的最小值至少 0.25；失败时丢弃坏 mask 并进入回退 |
| 亮区回退 | 在上一候选附近的有界 ROI 内，用参考 mask 做灰度模板匹配；参考区域须比周围中位亮度至少高 12 |
| 固定回退 | 亮度对比或定位证据不足时保持上一候选坐标，并明确标为待检查 fallback |
| 边缘搜索 | 原始 mask 周围 6 px 带；局部 ROI 另加 8 px；GrabCut 3 次迭代；Sobel 归一化边缘图 |
| 接受边缘精修 | 单连通、无孔、不贴裁剪边界；raw IoU ≥0.85；面积比 0.80–1.25；Hausdorff ≤6 px；边缘分数增益 ≥0.01 |
| 轮廓输出 | 一个简单无孔外环、最多 2048 点；近似 mask IoU ≥0.99；拒绝分量、退化、自交或贴图像边界截断 |
| 批次范围 | 含关键帧最多 30 个连续播放条目；原始帧号必须匹配 Source 声明的 `frame_step`，左右方向分别停止；审计记录显式保存该步长，旧记录缺省时按 1 读取 |

边缘精修的预期性拒绝必须返回输入 mask 的精确副本并记录原因；它与传播模式的 fallback 分开显示。光流产生孔洞、多分量、面积异常或锚点/质量失败时，坏 mask 会被丢弃，再从原有简单环尝试亮区平移或固定坐标回退；最终候选仍必须通过无孔单环、边界和顶点上限。OpenCV 运行异常、非有限诊断、非法返回结构或声称 fallback 却修改 mask 仍会丢弃整份计划。

相似度失败、最终 fallback 仍无法满足 V1 几何、已确认帧、偏离声明抽样步长或尺寸变化会截断相应方向；读图失败、Source 映射/图像/标注/确认状态变化使整份计划失效。算法只使用实际图像快照，没有插帧、生成帧或模型推理。

## 模块与所有权

| 模块 | 职责与输出 |
|---|---|
| `poly_batch_provider.gd` | 把通用 Batch provider 生命周期适配到生产 Poly 服务 |
| `polygon_propagation_service.gd` | 从 Source 逐步冻结 PNG，管理可取消子进程；校验帧映射、像素、候选身份、诊断和 stale 状态 |
| `similarity.py` | 在同一冻结图像上计算 `gray64-area-mad-v1` 相邻/固定锚点门 |
| `polygon_flow.py` | 图像对双向 DIS 光流、mask 映射和局部质量证据 |
| `polygon_edge_refinement.py` | 局部 GrabCut/Sobel 精修；安全接受或精确 raw-flow fallback |
| `polygon_geometry.py` | 简单环、mask 初始化、面积/锚点门和受限轮廓提取 |
| `polygon_propagation.py` | v3 请求（含 `frame_step`）、相似度、双向传播、亮区/固定回退、边缘调用和停止规则；不访问 Store |
| `propagate_polygons.py` | 严格 JSON CLI、取消、原子 progress/result 文件 |
| `batch_controller.gd` | 只读计划/逐帧预览、覆盖/同 ID 合并和提交前校验 |
| `apply_propagation_command.gd` | 将已预览记录一次性写入，保留身份和 v2 marker，支持原子 undo/redo |

Store、审核与保存仍由现有链路拥有。候选不扩展 Model Output V1；schema-v2 batch marker 使用 `metric_id=poly-sim-flow-edge-v1`，记录阈值、范围、停止原因和有界边缘 accepted/fallback 摘要。`filled` 只在 Godot 内保留，不进入 V1 协议。

任务只删除自己创建的临时快照目录。取消终止本服务创建的进程；超时为 180 秒。Python 限制单张 PNG 为 64 MiB、原图为 32 MP，并在计算前对三组持久 mask 检查 128 MiB 预算；图像解码、光流和几何临时数组仍有额外开销。人工输入最多 4096 点，输出最多 2048 点；系统不会为满足输出限制而改写关键帧。

## 自动化与合成基准

以下 `tests/` 命令属于完整本地开发工作区，按发布边界不随 GitHub 版本上传：

```bash
source project_env.sh
.venv/bin/python -m pytest tests/python/test_polygon_propagation.py -q
.venv/bin/python tests/python/polygon_benchmark.py --output /tmp/poly-edge-benchmark.json
"$GODOT_BIN" --headless --log-file /tmp/poly-command.log --path . --script tests/godot/test_polygon_batch_command.gd
bash tests/check_godot_log.sh /tmp/poly-command.log
"$GODOT_BIN" --headless --log-file /tmp/poly-integration.log --path . --script tests/godot/test_polygon_batch.gd
bash tests/check_godot_log.sh /tmp/poly-integration.log
"$GODOT_BIN" --headless --log-file /tmp/poly-service.log --path . --script tests/godot/test_polygon_service.gd
bash tests/check_godot_log.sh /tmp/poly-service.log
"$GODOT_BIN" --headless --log-file /tmp/poly-ui.log --path . --script tests/godot/test_polygon_batch_ui.gd
bash tests/check_godot_log.sh /tmp/poly-ui.log
```

合成平移、反向平移、旋转、形变和边界偏移的真值由独立几何 fixture 生成。基准分别报告 raw 光流/最终/固定复制 IoU、边缘接受/回退次数、质量停止原因和时间。只有这组独立合成数据支持 IoU 数值结论；它不能替代真实手术视频精度、人工修改量或标注时间评测。最新实测值见 [RESULTS.md](../RESULTS.md)。

## Endoscapes 本地定性验收

数据集保持只读；fixture 和证据必须写入已忽略的 `.local-acceptance/`。Main 的严格 Source 需要实际文件，因此 UI fixture 使用 `--copy`；默认不加该选项时只建立符号链接。

```bash
.venv/bin/python python/prepare_endoscapes_poly_fixture.py \
  --dataset-root /absolute/endoscapes \
  --output .local-acceptance/endoscapes-poly-65 \
  --video-id 65 --start-frame 11775 --end-frame 11875 \
  --key-frame 11800 --instance-index 0 --copy

.venv/bin/python python/run_endoscapes_poly_acceptance.py \
  --fixture .local-acceptance/endoscapes-poly-65 \
  --output .local-acceptance/endoscapes-poly-65-evidence \
  --threshold 0.10
```

构建器要求 5–30 帧、原始帧号按 25 递增、尺寸一致，并核对关键帧 `.npy`/`.csv` 实例数。`manifest.json` 使用连续 playback index；`provenance.json` 单独记录原始帧 ID、源文件 SHA-256、类别和转换。目标存在时拒绝覆盖，所有输出先在同级 staging 完成再原子改名。

视频 65、实例 0 的 keyframe 11800 是类别 5 `gallbladder`。原 mask 同时触碰上下边界，无法直接表示为安全 V1 单环；fixture 明确移除外围 2 像素，并把 `lossless: false`、保留 IoU 和回栅格 IoU 写入 provenance。这个转换是有损、可审计的验收准备，不是对原 mask 的无损声明。

2026-09-10 在阈值 `0.10` 重新运行五帧夹具，仍返回 playback 2（原帧 11825），候选范围 `1..2`；两侧随后因候选触及图像边界停止。另用真实 Video001 的当前 polygon 对 `29375 → 29400` 只读实测，v3 请求保留 `frame_step=25` 和真实帧号，返回 frame 29400 候选；坏光流孔洞被丢弃后采用 `bright-template fallback`。这些均是可运行性证据，不是目标帧真值精度。

只有 keyframe 11800 有实例 mask，目标帧没有独立密集真值。因此 Endoscapes 结果只是实际数据路径和人工可审查性的定性证据，不能声称目标帧 IoU、普遍边缘提升或自动验证。图片、mask、绝对数据集路径、叠加图和验收产物均不进入 Git；详细复现边界见 [Endoscapes Poly 验收流程](Endoscapes%20真实数据源/endoscapes-poly-acceptance.md)。
