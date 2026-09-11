# Project 6 自动标注系统

这是一个以 Godot 4 为主客户端的人机协作标注工具：读取图片序列或视频帧，在原图上显示模型区域，提供可撤销的 2D 修正、相似连续帧批量传播、审核状态与版本化文件交接。本仓库交付工具与合同，不交付训练好的模型。

![主标注界面](docs/前端标注.png)
![批量处理界面](docs/批量.png)

## 开发原则

- 以 Assignment 和 MITK 的手动编辑范式为交互参考，只适配到 2D 视频 region，不声称与 MITK 等价。
- 每一类状态只有一个明确所有权边界：Source 提供帧，Store 保管不可变基线与修正副本，History 只接受已验证命令。
- Source、Render、Edit、Feedback 通过清晰接口解耦，插件故障被隔离为可读错误，不让 UI 崩溃。
- 可维护和可复现优先于功能数量；生成样本、测试、基准和导出都必须可追溯。
- Part 1 边界是版本化数据合同、可复现样本、帧源和四类插件；不把批量元数据塞进严格的 Model Output V1。

## 交付目录

仓库根目录就是 Assignment 示例中的 `annot_tool/`。各阶段通过版本化接口解耦，生成数据与本地验收产物不进入 GitHub：

```text
Project6_test/
├── README.md          # 环境、安装、运行、reviewer 脚本和快捷键
├── pyproject.toml     # 唯一 Python 依赖定义
├── client/            # Godot 客户端、pipeline 接口与可替换 plugins
├── core/              # 跨语言 schema 与共享合同
├── python/            # 帧源、样本生成、验证及模型 worker
├── sample/            # 本地确定性生成，不提交大样本
├── tests/             # Python/Godot 测试、轻量 fixture 与 headless runner
└── RESULTS.md         # 设计决策、测量和失败分析
```

`tests/output/`、视频帧、模型权重、数据集、缓存、`.local-acceptance/` 和本地交接包均被排除；reviewer 可用 README 命令重新生成样本与测试结果。

## 快速开始

已验证环境：Ubuntu 22.04、Godot 4.7.2-stable、Python 3.14.7、FFmpeg 6.1+（本机 6.1.2）、`opencv-python-headless==4.14.0.94`。Python 支持 `>=3.12,<3.15`。`pyproject.toml` 是唯一 Python 依赖源，`project_env.sh` 只校验环境并设置当前 shell，不修改系统。

```bash
python3.14 -m venv .venv
.venv/bin/python -m pip install -e ".[dev]"
source project_env.sh
ffmpeg -version
```

生成固定种子的 120 帧样本并用独立验证器检查：

```bash
.venv/bin/python python/make_sample_input.py --output sample/assignment_v1 --seed 6006
.venv/bin/python python/validate_model_output.py sample/assignment_v1/model_output_v1.jsonl
```

预期最后一行为 `Validation errors: 0`。样本包含 drift、wrong class、missed region、hallucinated region、track-id swap 和连续近似帧；同一 seed 的核心文件 SHA-256 一致。

启动客户端：

```bash
"$GODOT_BIN" --editor --path .
# 在编辑器中运行 client/app/main.tscn
```

打开方式：

- “Open Source” 打开单张图像、带 `manifest.json` 的归一化目录，或由 `numeric_image_sequence_source` 识别的纯数字图片序列。
- “Open Video” 选择视频后按 `Start import`；FFmpeg 子进程原子发布为归一化目录，旧数据源在导入完成前不被替换。
- “Open Workspace” 读取普通工作区或标准 Endoscapes2023 根目录，并为每个媒体保持独立的 V3 审核会话。Endoscapes 会按 split/视频分组，而不是把原图与 `semseg`/`insseg` mask 递归展开为左树媒体。

## Reviewer 逐项验收

1. 打开 `sample/assignment_v1`，确认图像保持宽高比，box、polygon、class、confidence 可见；调整 `Overlay opacity`，尝试滚轮缩放、中键平移和 `Fit`。
2. 用 Select 点击、拖动、八柄缩放和键盘 1/5/10 px 微移；使用右侧列表或 `R` 重标签。
3. 依次验证 9 个工具：Add Box、Subtract、Lasso、Fill、Paint、Eraser、Select、Match、Model Assist。Lasso 中选中已保存 polygon 后可直接拖动实际轮廓顶点；Match 先点待修正区域 A，再点参考区域 B。
4. 对每种编辑执行 Undo/Redo；尝试自交 polygon 和会产生 hole/multipolygon 的操作，确认原子拒绝并显示原因。
5. 播放区依次点 `Previous`、`Play`、`Pause`、`Next`，尝试 `Custom`、`3 s/frame`、`1 s/frame`、`Max`；确认 `actual FPS` 只读，`Time HH:MM:SS.mmm` 与帧索引一起显示。
6. 用 `M` 进入 Model Assist：无选区时用正/负点和 box 创建 Poly，选中 Box/Poly 时只修正其几何；切换 candidate，检查 Apply/Cancel/Retry 以及一次 Undo/Redo。
7. 在批量页选中已提交的 Box/Poly region，显式确认它可作为锚点，用默认 SAM 2 Video 向后生成 1–30 帧；逐帧检查只读候选、分段停止和重新锚定，再确认并验证一次 undo/redo。
8. 触发 Save/Ctrl+S 和自动保存；在 Export 生成 verified-only 训练包和 all-frame 评审快照，检查 diff JSON/CSV、manifest 与 SHA-256。
9. 在 Model Round 先预览模型返回，再提交为独立新轮次；确认旧 V3 字节归档，新轮次的 verification/batch/history 为空。

人工验收请记录设备、日期、步骤和结果。自动化与可见脚本不等同于真实 reviewer 的主观交互验收；该边界在 `docs/requirements-traceability.md` 中保持为待验证。

## 快捷键

| 操作 | 快捷键 |
|---|---|
| Select / Add Box / Subtract / Lasso / Fill / Paint / Eraser | `V` / `A` / `S` / `L` / `F` / `P` / `Shift+P` |
| Match | 工具栏按钮（先 A 后 B） |
| Model Assist | `M`（只切换工具；首个鼠标提示才发起请求） |
| 选择上一/下一区域 | `[` / `]` |
| 重标签 / 删除区域 | `R` / `Delete` |
| 撤销 / 重做 | `Ctrl+Z` / `Ctrl+Shift+Z` 或 `Ctrl+Y` |
| 移动 1/5/10 image px | `Arrow` / `Shift+Arrow` / `Ctrl+Shift+Arrow` |
| 缩放选中区域 1/5/10 image px | `Alt+Arrow` / `Alt+Shift+Arrow` / `Ctrl+Alt+Shift+Arrow` |
| 闭合 Lasso/Subtract | `Space` |
| 确认草稿 / 删除最后顶点 / 取消 | `Enter` / `Backspace` / `Escape` |
| 缩放 / 平移 / 恢复适配 | 滚轮 / 鼠标中键 / `Fit` |

`Tab`/`Shift+Tab` 遍历工具、标注列表、类别对话框与 Fill 候选按钮。草稿期间 `Escape` 只取消草稿；空闲 Select 中右键或 `Escape` 清除选区。

## 视图与播放实现

`ViewportTransform` 向绘制与命中测试提供同一个 `Transform2D`。Renderer 缓存 image-space primitives 和 AABB，只在图像、record、selection、opacity 或 transform 变化时 dirty redraw，并裁剪完全离开视口的 primitive。可复现基准在 1280×800、20 regions 和 llvmpipe 上记录 175.27 fps 平均值和 9.572 ms p95；这是本机结果，不外推到其他 GPU。complex polygon 按单环非自交处理，hole 和 multipolygon 不属于 Model Output V1。完整方法和数据见 `RESULTS.md`。

Part 3.1 整体为 **PASS**。视频由 `VideoImportController` 通过 `OS.create_process()` 无丢帧解码；`PlaybackController` 只请求 `current + 1`，不追钟跳帧；`PlaybackFpsMeter` 只统计已提交帧。显示为 explicit frame/time，实测对 10,000 帧源的缓存不超过 12 张纹理。

## Endoscapes 按视频懒加载

在 “Open Workspace” 中选择 Endoscapes2023 根目录即可直接打开，不需要预先拷贝、重命名或生成 manifest。扫描在 `WorkspaceCatalogController` 后台任务中运行；顶部会显示“正在建立视频索引…”和“Cancel scan”，取消、失败或陈旧 generation 都不替换当前工作区。发现结果只保留 split/视频级条目，左树不持有未选中视频的逐帧路径。

选中一个视频后，`WorkspaceMediaController` 才在后台打开 `endoscapes_video_source`。它只保留当前视频的有序帧路径和记录，播放位置连续，`frame_id` 保留 Endoscapes 原始帧号，像素纹理使用上限 12 的 LRU。切换或关闭时旧 Source 的帧表、标注和缓存会被清空，但不删除任何源文件。

官方 COCO `bbox` 转为 Model Output V1 box；compressed RLE 只在当前视频内解码，并且只有通过单连通域、无孔、非触边和几何有效性门禁后才添加 polygon。不安全的 mask 保留合法 box 并计入降级摘要；两种几何都无效时才跳过区域。官方标注是 `imported_labels` 种子，不伪造模型置信度或已审核状态；重开时，Project6 已保存标签和显式 `labels/<media_id>.json` 均优先于官方基线。

本机最终真实数据集只读验收发现 201 个逻辑视频、0 个 media ID 冲突，扫描 0.428190 s；选中视频 004 时只保留其 633 条帧路径，导入 98 个区域（39 polygon、59 box fallback、0 跳过），15/15 次纹理加载成功且缓存峰值为 12。切换后旧 Source 的帧路径与缓存均为 0，源树元数据指纹前后一致。这些是当前主机的自动证据，不替代 1280×800 可见 UI 操作、逐帧人工对齐或其他硬件性能验收。复跑命令：

```bash
source project_env.sh
"$PROJECT6_PYTHON" python/run_endoscapes_lazy_source_acceptance.py \
  --dataset-root Dataset_test/endoscapes \
  --output .local-acceptance/endoscapes-lazy-source-new
```

输出目录必须事先不存在；验收报告不记录数据集绝对路径。模块所有权见 `docs/architecture.md`，真实数据边界见 `docs/endoscapes-poly-acceptance.md`。

## 单帧 Model Assist

`Model Assist` 是标注页的第九个单帧工具，不是 Batch 算法；第八个保留给 Match。无选区时它生成待分类新 Poly；选中已有 Box/Poly 时只修正该区域的几何，保留 ID、类别和属性。左键添加正点，`Shift+左键` 添加负点，`Ctrl+拖动` 设置唯一 box，`Backspace` 撤销最后一个提示。

首个提示会冻结原始帧 ID、连续播放索引、图像 SHA-256、record SHA-256 和修正目标。过期或已取消结果不能写入 Store；候选 mask 必须是 worker 任务目录内的有哈希二值 PNG，并转换为无孔、单连通、非自交的 Model Output V1 Poly。创建与修正都只以一条命令进入 undo/redo。

运行时只从 `PROJECT6_MODEL_PYTHON`、`PROJECT6_SAM2_CONFIG`、`PROJECT6_SAM2_CHECKPOINT` 和 `PROJECT6_SAM2_DEVICE=auto|cpu|cuda` 读取显式配置。非阻塞 preflight 会在工具状态中显示 CPU/CUDA badge；工具不会为用户自动安装 `sam2` 或下载 checkpoint。可复用的 `model-assist-v1` 真实模型验收入口是 `python/model_assist_smoke.py`；本机已用 Meta 官方 SAM 2.1 Tiny 和 RTX 5070 Ti Laptop GPU 在本地手术帧上完成 CUDA `hello -> set_image -> predict -> shutdown` smoke PASS，生成 3 个受门禁候选。Godot 已可使用该运行时，但尚未把下列全部人工 UI 步骤记录为正式验收。命令、报告字段与边界见 [Model Assist 真实 SAM 2 验收](docs/model-assist-acceptance.md)。fake-worker 自动证据与真实 SAM PASS 始终分开记录。

## 数据合同与插件

`core/schemas/model_output_v1.schema.json` 是严格的 JSON Schema Draft 2020-12；`python/annotation_data/contracts.py` 与 `python/validate_model_output.py` 是 Python 验证边界，`client/domain/model_output_validator.gd` 实现 Godot 等价校验。`source: sample_v1` 属于合法模型样本；人工导出使用 `"source":"human_corrected"`。模型基线字节始终不可变。

Registry 启动时扫描 `client/plugins` 并验证 manifest、API version、Stage 类型和入口脚本。当前工作插件：

- Source：`image_sequence_source`、`numeric_image_sequence_source`、`single_image_source`、`endoscapes_video_source`；
- Render：`canvas_region_renderer`；
- Edit：`basic_edit_tools`；
- Export / Feedback：`file_training_handoff`。

新增插件只需在相应 stage 下添加 `plugin.json` 与 Stage 实现，不修改 Registry 或 core。精确字段、方法签名、生命周期、深拷贝与故障隔离见 `docs/plugin-api.md`，整体所有权见 `docs/architecture.md`。

## 批量标注与训练交接

Batch 默认策略是 `sam_video`（官方 SAM 2 Video Predictor）。先在关键帧提交一个 Box/Poly region，选中它并勾选“我已确认当前 region 可作为传播起点”，再按 Source 顺序向后请求 1–30 个目标；关键帧不计入目标。候选在预览期间为只读临时状态，不写 Store、review、标签文件或训练包；“确认并写入”才使用一条 `ApplyPropagationCommand` 按 region ID 原子合并所有目标，一次 undo/redo 同时恢复 records、review 和 batch audit。

无法表达为 Model Output V1 单环 Poly 的某一帧会在该帧分段停止，保留之前的合法候选；用户可在停止帧用单帧 Model Assist 修正、提交并重新确认锚点，然后开启新 Batch。协议、路径、hash、Source/Store/review/session 不一致或进程错误使整批作废。SAM 失败时不会静默改用其他算法；`polygon_flow`/`poly-sim-flow-edge-v1` 与 `copy` 仅作为用户明确选择的备选。Poly 方法的历史证据和独立门禁见 `docs/poly-propagation.md`。

SAM Video 与单帧 Model Assist 共用且只读取四个外部配置：`PROJECT6_MODEL_PYTHON`、`PROJECT6_SAM2_CONFIG`、`PROJECT6_SAM2_CHECKPOINT` 和 `PROJECT6_SAM2_DEVICE=auto|cpu|cuda`；客户端不自动安装或下载。本轮新鲜全量与聚焦门禁均通过，因此“自动协议/安全”记为 **PASS**。真实 SAM Video 功能、可见 UI、独立真值精度、配对人工效率与 CUDA 性能均仍为 **NOT RUN**；既有的单图 SAM CPU smoke 不是视频证据。验收合同见 `docs/sam-video-batch-acceptance.md`。

Part 4 用 V3 会话分离不可变模型基线、人工修正、verification 与 batch metadata。Save 使用同目录临时文件、flush、回读验证和原子替换。默认 `training_update_v2` 只包含已验证帧；`review_export_v1` 用于全帧评审快照。模型回传的 `model_round_v1` 必须指向真实父训练包，预览后才能创建独立新轮次。详见 `docs/part4-protocol.md` 和 `docs/part4-review.md`。

一键训练导出仍停留在原有 Task 4 review boundary，当时未解决的 review issues 保持原状；SAM Video Batch 未修复、升级或宣称完成该流程。

CLI 全环演示（目标目录必须不存在）：

```bash
source project_env.sh
"$PROJECT6_PYTHON" python/part4.py demo --output /tmp/project6-part4-demo
"$PROJECT6_PYTHON" python/part4.py validate-package /tmp/project6-part4-demo/handoff/training_update_v2_*
```

## 测试与基准

完整自动化：

```bash
source project_env.sh
bash tests/run_tests.sh
```

单独基准入口：

```bash
"$GODOT_BIN" --path . --script tests/benchmarks/godot/display_benchmark.gd -- --output /tmp/part2_display.json --warmup 2 --duration 10
"$PROJECT6_PYTHON" tests/benchmarks/make_part3_sources.py --playback-output /tmp/part3-playback --stress-output /tmp/part3-stress
"$GODOT_BIN" --path . --script tests/benchmarks/godot/playback_benchmark.gd -- --source /tmp/part3-playback --output /tmp/part3_playback.json --duration 10
"$GODOT_BIN" --headless --path . --script tests/benchmarks/godot/long_source_benchmark.gd -- --source /tmp/part3-stress --output /tmp/part3_long.json
"$GODOT_BIN" --headless --path . --script tests/benchmarks/godot/video_import_benchmark.gd -- --input /tmp/input.mkv --output /tmp/part3-import --result /tmp/part3_import.json
```

临时输出目录必须预先不存在。Godot 的 corrupt-PNG 恢复 fixture 会故意打印解码错误；应以最终 `PASS: complete Godot test suite` 和进程状态 0 为准。

## 完成度与边界

根 README、RESULTS 和需求台账是 GitHub 交付的权威文档；本地 `交付/` 不上传。当前自动化与单帧真实模型 smoke 通过不代表真实 SAM Video 精度或通用人机功效已被证明。Part 2.2/2.3 的最终人工 reviewer 复跑、Model Assist 完整可见 UI 清单以及 SAM Video 的真实功能/质量/效率验收仍需分别记录。演示视频仅保留在本地交接包中，不进入 GitHub。

不在本次交付范围：3D 体数据、hole/multipolygon 合同、真实训练服务、实际重训结果、Close Gaps、Region Growing 和 Live Wire。

## 文档索引

- `RESULTS.md`：设计决策、测量与失败分析。
- `docs/architecture.md`：架构图、所有权和数据流。
- `docs/plugin-api.md`：API version 1 插件合同。
- `docs/requirements-traceability.md`：Assignment 逐条追踪与状态。
- `docs/part4-protocol.md`：模型组与工具组的协作接口。
- `docs/part4-review.md`：Part 4 CLI/UI 复现流程。
- `docs/poly-propagation.md`：可编辑 polygon 运动传播的边界和门禁。
- `docs/sam-video-batch-acceptance.md`：SAM 2 Video 真实功能、UI、精度、效率与 CUDA 的分类验收合同。
- `docs/model-assist-acceptance.md`：真实 SAM 2 smoke 与人工 UI 验收边界。
- `docs/endoscapes-poly-acceptance.md`：Endoscapes 真实数据与 Poly 传播验收边界。
