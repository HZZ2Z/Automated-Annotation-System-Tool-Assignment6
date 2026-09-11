# Model Assist 真实 SAM 2 验收

这套流程只验证标注页的单帧 Model Assist 工具；它的 image predictor 会话与 Batch 的 video predictor 会话完全隔离。新的 Batch SAM 2 Video smoke、case allowlist 和五分区证据见 [SAM 2 Video Batch 有界验收](sam-video-batch-acceptance.md)，两套结果不能互相替代；Batch 的 `functional` 只有在 `runtime_smoke` 与显式绑定的可见 UI 八项检查都 PASS 时才可 PASS。Poly 光流与边缘精修仍作为明确命名的高级/降级策略保留，但不再是 Batch 默认路径。

## 运行时边界

Model Assist 只使用用户明确指定的外部 Conda Python、Meta 官方 `sam2` config 和官方 checkpoint。项目 `.venv` 不安装 Torch/SAM 2，工具也不会自动下载、覆盖或替换权重。安装 `sam2` 或下载 checkpoint 前必须先确认目标环境和官方来源。

官方源：

- 代码与安装说明：<https://github.com/facebookresearch/sam2>
- SAM 2.1 checkpoint 目录：<https://dl.fbaipublicfiles.com/segment_anything_2/092824/>

UI 需要以下四个变量：

```bash
export PROJECT6_MODEL_PYTHON=/absolute/conda/env/bin/python
export PROJECT6_SAM2_CONFIG=/absolute/site-packages/sam2/configs/sam2.1/sam2.1_hiera_t.yaml
export PROJECT6_SAM2_CHECKPOINT=/absolute/checkpoints/sam2.1_hiera_tiny.pt
export PROJECT6_SAM2_DEVICE=auto
```

`PROJECT6_SAM2_CONFIG` 的 UI 合同是绝对路径；worker 校验它位于已安装 `sam2` 包的 `configs/` 下，再转换为官方 Hydra 需要的 `configs/...` 包内名称。不接受包外的同名 YAML。`auto` 在 CUDA 可用时选 CUDA，否则选 CPU；显式要求 `cuda` 但不可用时必须失败。

## 只读 smoke

先用项目 Python 启动验收驱动，再由 `--python` 选中的外部解释器运行生产 worker：

```bash
.venv/bin/python python/model_assist_smoke.py \
  --python /absolute/conda/env/bin/python \
  --config /absolute/site-packages/sam2/configs/sam2.1/sam2.1_hiera_t.yaml \
  --checkpoint /absolute/checkpoints/sam2.1_hiera_tiny.pt \
  --image /absolute/local/surgical-frame.png \
  --output-dir .local-acceptance/model-assist-real-001 \
  --device auto \
  --positive-point 420,260 \
  --negative-point 610,300 \
  --box 330,170,700,430
```

`--positive-point` 和 `--negative-point` 可重复，总数不超过 64；`--box` 最多一个。全部坐标是原图像素坐标。未给任何提示时，驱动只添加一个图像中心正点。

输出目录必须不存在；如果同名目录已有内容，驱动立即拒绝，不复用也不覆盖。位于仓库内的输出还必须是 `.local-acceptance/` 的下级目录；仓库外的显式绝对路径也可使用。它只在新目录中写入 `input.png`、`worker.stderr.log`、candidate PNG 和 `report.json`。运行时探针记录 Python/Torch/Torchvision/NumPy/OpenCV/SAM 2 版本、CUDA 状态；报告同时记录 config/checkpoint/图像 SHA-256、实际设备、提示坐标、阶段耗时、candidate score/ROI/SHA-256/前景像素数和 worker PID/会话所有权。

PASS 需要 `hello -> set_image -> predict -> shutdown` 全链路通过，candidate 为输出目录内的非链接二值 PNG，其尺寸、ROI 和 SHA-256 相互一致。smoke PASS 证明真实 SAM image predictor 协议闭环，不代替下面的 UI 验收。

### 本机实测（2026-09-10 至 2026-09-11）

已在 Conda 环境 `project6` 中使用 Meta 官方 SAM 2 代码（commit `2b90b9f5ceec907a1c18123530e92e794ad901a4`）和 SAM 2.1 Tiny checkpoint 运行本地手术帧 `Dataset_test/cholect50-challenge-val/videos/VID68/000016.png`。CPU 的真实 `hello -> set_image -> predict -> shutdown` 结果为 **PASS**：总时间 9.665959 s，模型加载 3.178170 s，image embedding 1.404518 s，prediction 0.072461 s，产生 3 个通过二值 PNG/ROI/SHA-256 门禁的 candidate，worker exit code 为 0 且 stderr 为空。checkpoint SHA-256 为 `7402e0d864fa82708a20fbd15bc84245c2f26dff0eb43a4b5b93452deb34be69`，完整报告在 `.local-acceptance/model-assist-real-20260910-cpu/report.json`。

2026-09-11 又在同一官方 checkpoint 和本地手术帧上完成 CUDA smoke **PASS**。运行时为 Python 3.10.0、Torch 2.11.0+cu128、SAM 2 distribution 1.0，实际设备为 `NVIDIA GeForce RTX 5070 Ti Laptop GPU`；模型加载 2.416052 s、image embedding 0.324668 s、prediction 0.191926 s，产生 3 个通过 PNG/ROI/SHA-256 门禁的 candidate，worker exit code 为 0。审计报告保留在本地忽略目录 `.local-acceptance/model-assist-user-check-003/report.json`，不上传输入图像、模型权重或运行产物。

这证明单帧生产 worker 的真实 SAM 2 CUDA 推理闭环。Godot 当前可以加载该运行时，但下面的完整可见真模型 UI 清单尚未形成逐项证据，因此仍与 smoke 分开记录。

## 真实 UI 闭环

保留上述四个环境变量，启动并把日志写到同一个验收目录：

```bash
source project_env.sh
"$GODOT_BIN" --path . \
  --log-file .local-acceptance/model-assist-real-001/godot-ui.log
```

在一个本地外科帧工作区中逐项验收：

1. 进入 Edit，选择第九个 `Model Assist`（第八个是 Match）或按无修饰键 `M`；记录工具显示的 CPU/CUDA badge。
2. 不选区域：左键正点、Shift+左键负点、Ctrl+拖动唯一 box，切换 candidate 后 Apply，在类别对话框中完成新 Poly。确认一次 undo 撤销整个创建，一次 redo 整体恢复。
3. 选一个已有 Box 或 Poly：添加首个提示后更正目标被冻结；Apply 只替换该区域几何，保留 ID/类别/属性。再验证一次原子 undo/redo。
4. 在一次请求中点 Cancel，再立即新建提示；旧结果不得覆盖新会话。候选期切换帧、工具或 Batch 时必须先取消/拒绝导航，不得将草稿带到新上下文。
5. 等待保存，关闭后重新打开同一 Source；确认创建和修正的 Poly 均持久化。检查 `godot-ui.log` 无 `SCRIPT ERROR`、未处理异常或非预期 `ERROR:`。

最终记录将三类证据分开：自动 fake-worker 回归、真实 SAM smoke、人工可见 UI 闭环。当前单帧真实 SAM 2 CUDA smoke 已 PASS；它不等于完整 UI 人工清单，也不替代 SAM Video Batch 的功能、质量、效率或逐帧 CUDA 性能证据。没有官方 config/checkpoint 或没有 `sam2` 时，真实模型验收仍是 PENDING，不能用 fake worker 代替。
