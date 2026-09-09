# Poly 轮廓运动传播

批量页提供 `Poly 轮廓运动`，用真实相邻图像估计目标运动，生成各帧独立的可编辑 polygon。它是当前 NumPy/OpenCV 环境可运行的保守基线；真实手术视频的精度和人工节时尚未测量。

## 使用

1. 打开 Source，在参考帧绘制或修正 Poly。
2. 打开“批量”，选择“Poly 轮廓运动”，点击“分析 Poly 轮廓运动”。
3. 检查候选首末帧和传播预览；可缩短范围，但必须包含参考帧。
4. 应用后逐帧检查，再人工确认。应用会保存，整批支持一次撤销和重做。

只传播参考帧中带 `polygon` 的区域，按同一 `id` 合并，保留目标帧的其他区域。参考帧的顶点、顺序、类别和记录保持不变。默认算法仍为“固定坐标复制”。Poly 模式采用自己的固定质量门槛，不使用固定复制的灰度差异阈值。

## 算法与停止规则

关键帧 polygon 仅在初始化时栅格化。后续保留灰度 mask，通过 [OpenCV DIS 光流](https://docs.opencv.org/4.x/dc/d6b/group__video__track.html)和[反向映射](https://docs.opencv.org/4.x/da/d54/group__imgproc__transform.html)传播：

`M_t(x) = M_(t-1)(x + B_t(x))`，其中 `B_t` 表示当前帧到前一帧的光流。

正反向一致性检查 `F(x) + B(x + F(x))` 是否接近零，同时核查目标内部的纹理、重映射后的灰度证据和局部不可靠分量。每个非相邻目标帧另与固定人工关键帧直接匹配，检查逐帧传播与直接传播的 mask IoU，避免只用上一步预测自我验证。

| 条件 | 当前版本规则 |
|---|---|
| 分析分辨率 | 保持比例，长边最多 1024 像素；输出映射回原图坐标 |
| 可见证据 | 内部有效像素至少 36；纹理标准差至少 4；前后向与外观联合支持率至少 0.92 |
| 局部异常 | 不可靠连通块达到 `max(16, 内部面积×0.015)` 时停止 |
| 面积变化 | 相邻 mask 比例 0.75–1.33，相对关键帧 0.60–1.67 |
| 固定锚点 | 逐帧与直接传播的 mask IoU 至少 0.85 |
| 质量门槛 | 外观、一致性、纹理、锚点 IoU、锚点质量取最小值，至少 0.65 |
| 轮廓输出 | 单个简单外环、最多 2048 点；近似 mask IoU 至少 0.99，拒绝孔洞、分量、退化、自交或贴边截断 |
| 批次范围 | 含关键帧最多 30 个连续原始帧号；两侧分别停止 |

质量分数是规则性诊断量，没有经过概率校准。大幅形变、无纹理、遮挡、细长目标、相机运动或光照变化可能使算法提前停止；停止不等于已确认真实遮挡。任意一个 Poly 失败便停止该方向的整批，不跳过失败帧，也不自动确认候选。

已确认帧、原始帧号缺口和图像尺寸变化会截断相应方向；读图失败或 Source 元数据变化使整个计划失效。算法只使用实际图像快照，没有插帧或模型生成的“观测”。

## 模块边界

| 模块 | 职责与输出 |
|---|---|
| `polygon_propagation_service.gd` | 经 Source 逐步取得独立 PNG，管理可取消子进程；校验帧映射、候选 ID、属性和几何 |
| `polygon_flow.py` | 图像对的双向光流、mask 映射和局部证据 |
| `polygon_geometry.py` | 简单环校验、mask 初始化和受限轮廓提取 |
| `polygon_propagation.py` | 请求、预算、双向传播、固定锚点及停止规则；不访问 Store |
| `propagate_polygons.py` | 严格 JSON CLI、取消、原子进度和结果文件 |
| `batch_controller.gd` | 只读逐帧预览和同 ID 合并 |
| `apply_propagation_command.gd` | 检查关键帧与全部目标快照，将预览原样一次性提交，支持 undo/redo |

Store、审核与保存仍是现有链路。候选不扩展 Model Output V1；audit 使用原批量 marker 字段，`metric_id=poly-flow-mask-v1` 标识算法及固定参数版本。`filled` 仅在 Godot 内保留，不进入 V1 协议；若源区域同时带 box，候选 box 随 polygon 更新。

任务仅删除自己创建的临时快照目录。取消停止本服务创建的进程；超时为 180 秒。Python 限制单张 PNG 为 64 MiB、原图为 32MP，并在计算前对三组持久 mask 检查 128 MiB 预算；该预算不代表进程总内存上限，图像解码、光流和几何临时数组还有开销。人工输入最多 4096 点，不为满足候选上限而改写关键帧。

## 验证入口

从仓库根执行，`project_env.sh` 负责定位本地 Godot：

```bash
source project_env.sh
.venv/bin/python -m pytest tests/python/test_polygon_propagation.py -q
.venv/bin/python tests/python/polygon_benchmark.py --output tmp/poly-benchmark.json
"$GODOT_BIN" --headless --log-file /tmp/poly-command.log --path . --script tests/godot/test_polygon_batch_command.gd
"$GODOT_BIN" --headless --log-file /tmp/poly-integration.log --path . --script tests/godot/test_polygon_batch.gd
"$GODOT_BIN" --headless --log-file /tmp/poly-service.log --path . --script tests/godot/test_polygon_service.gd
"$GODOT_BIN" --headless --log-file /tmp/poly-ui.log --path . --script tests/godot/test_polygon_batch_ui.gd
```

量化结果和当前验收证据见 [RESULTS.md](../RESULTS.md)。合成平移、旋转、形变真值由独立几何变换生成；应同时报告预期目标帧的接受率和 IoU。该证据不能替代真实手术视频、人工修改量和使用时间的评测。

当前已用 headless Main 场景验证实际控件、预览、保存与重开，并检查默认窗口下主要审核控件的布局边界。本轮另在 X11/GL Compatibility 下重新生成可见 Batch/Poly 截图并检查交付画面；脚本化可见截图仍不等于真实 reviewer 的人工视觉验收。
