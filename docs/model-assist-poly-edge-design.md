# 单帧模型辅助工具与边缘感知 Poly 批量传播设计

**日期：** 2026-09-10

**状态：** 已批准，按计划实施中

**范围：** Project6 单帧编辑工具、批量相似帧判定、Poly 光流传播、局部边缘精修与人工验证

**取代：** `2026-09-09-sam-assisted-batch-design.md` 的 Batch-SAM 方案

## 1. 目标

本设计将两条用户流程重新分开：

1. **模型辅助**恢复为标注页的单帧编辑工具。SAM 2 只根据当前原图、正负点、提示框和可选初始 mask 产生候选；用户可用它创建 Poly，也可修正已有 Box/Poly。
2. **批量标注**不使用 SAM。它对同一组冻结帧先做相似度门控，再对通过的连续原始帧执行 Poly 光流传播，并在传播边界附近做有界的边缘精修。
3. **人工验证**仍是唯一确认入口。所有模型或图形算法结果都只是预览候选，不自动写入 `verified`。

完成标准不是“有一个按钮”，而是两条流程都能以合法的 Model Output V1 单环 Poly 完成预览、原子提交、撤销、保存和重开，且所有失败均不留半成品。

## 2. 非目标与不可破坏边界

- SAM 不是 Batch provider，不做跨帧跟踪或重新锚定。
- 不修改严格的 Model Output V1 Schema，不在 region 中保存 prompt、mask、算法质量或 Batch 诊断。
- 不自动下载、安装、更新或提交 SAM 权重，不保存 token，不使用云端推理。
- 不修复 NVIDIA 驱动，不把 CPU 功能验收冒充为 GPU 性能验收。
- 不强行填洞、删除连通分量或输出 multipolygon 以过安全门；无法无损表达为单环时必须拒绝或回退。
- 不把“边缘更强”解释为必然更准。边缘精修只在可测的改善与安全门同时通过时才被接受。
- 不删除已有固定坐标复制；它保留为可选基线，但不再是 Batch 默认算法。

## 3. 产品流程

### 3.1 单帧模型辅助

1. 用户在“标注”页选择“模型辅助”工具，快捷键为 `M`。
2. 未选中 region 时进入创建模式；选中合法 Box/Poly 时进入修正模式，原几何在原图分辨率栅格化为初始 mask。
3. 左键添加正点，Shift+左键添加负点，Ctrl+拖拽设置或替换唯一提示框，Backspace 撤回最后一次提示操作。
4. 每次 prompt revision 只接受最新请求的 1–3 个候选。用户可切换候选、继续加提示，或 Enter/Apply 提交；Escape/Cancel 放弃整个草稿。
5. 创建模式在 Apply 后进入现有类别对话框，类别确认后用一条 `AddPolygonCommand` 写入。修正模式用一条 `ReplaceRegionGeometryCommand` 替换几何，保留 ID、class、kind、track ID 和其他非几何字段；Box 修正后成为 Poly。

工具刚激活但尚无提示时不阻止切帧。选中 region 的初始 mask 此时只是可视参考，不会自动发起推理。第一个提示发起推理后，`draft_active=true` 且 `navigation_blocked=true`；切帧、播放、切工具、切 Batch、导入轮次及全局 undo/redo 都必须先 Apply 或 Cancel。

### 3.2 Poly 边缘传播 Batch

1. 用户在关键帧中修正标注，进入“批量”页。
2. 默认算法是“Poly 光流 + 边缘精修”；相似度阈值始终可见、可修改，默认为 `0.02`。
3. 分析在同一次冻结中获取最多 30 帧的 Source entry、图像与相关 Store/review 快照，然后异步生成候选段和每帧 Poly。
4. 用户只能缩短候选范围，不能跨过算法停止点；预览可以逐帧检查。
5. `覆盖` 使每个目标帧最终只保留本批传播得到的 Poly；`合并` 按 ID 更新或新增 Poly，保留目标帧其他 region。参考帧始终不被命令改写。
6. Apply 将选定范围作为一条原子批量命令提交。结果依然是“待检查”；确认本帧/本段和自动前进继续使用现有 Review 链路。

批量只传播参考帧中有合法 `polygon` 的 region。参考帧无 Poly 时明确拒绝，不把 Box 静默转为 Poly。

## 4. 架构与所有权

```text
标注页
ToolPanel / Main
  └─ BasicEditToolsPlugin
       ├─ ModelAssistSession        提示、候选、草稿与 stale token
       ├─ ModelAssistService        子进程、job 目录、严格协议与超时
       │    └─ model_assist_worker.py → SAM2ImagePredictor
       └─ AddPolygon / ReplaceRegionGeometry → History → Store

批量页
BatchWorkflow
  └─ BatchController
       └─ PolyEdgeBatchProvider
            └─ PolygonPropagationService
                 └─ propagate_polygons.py
                      ├─ similarity.py
                      ├─ polygon_flow.py
                      ├─ polygon_edge_refinement.py
                      └─ polygon_geometry.py
       └─ ApplyPropagationCommand → History → Store
```

边界如下：

- `ToolPanel` 只渲染工具和已校验的通用 session action，不识别 SAM、Torch 或 mask tensor。
- Edit plugin 拥有单帧提示交互与原子命令；`ModelAssistService` 不读写 Store。
- SAM worker 只读取本 job 的冻结 PNG/mask，只写候选 mask，不读标签文件。
- `BatchWorkflow` 拥有范围、模式、预览和人工验证意图，不实现相似度、光流或边缘算法。
- Poly provider/service 负责冻结并重新校验 Source、Store 和 review 状态；Python worker 对准确相同的快照做相似度、传播和边缘精修。
- provider 输出只读 proposal；只有 command 可修改 AnnotationStore。WorkspaceSession/MediaLabelStore 继续负责原子保存。
- Review 与模型分数、相似度或边缘分数相互独立。

## 5. 单帧模型辅助详细设计

### 5.1 工具面板与覆盖层

`model_assist` 作为第八个真实 Edit tool descriptor 加入现有工具列表，保留现有工具 ID 和顺序。提示与候选控件不作为 SAM 特例硬编码在 Main：

- Edit state 新增经过校验的 `session_panel` 快照，只包含工具 ID、状态文本、徽标、提示/候选摘要和 action descriptor。
- ToolPanel 发出通用 `tool_action_requested(action_id)`，Main 统一调用 `EditStage.invoke()`。
- 现有 Fill Apply/Cancel 迁移到同一 session-action 通道，不同时保留两套所有权。
- 每个 action 只允许 `id`、`label`、`enabled` 和 `primary`；ToolPanel 不执行任意 callable。

`EditOverlay` 新增 image-space `positive_points`、`negative_points` 和可选 `prompt_box`。正点绿色带 `+`，负点红色带 `−`，框为青色虚线，候选 mask 和 Poly 使用绿色半透明填充与闭合轮廓。修正模式在草稿期抑制原 region 渲染，创建模式不抑制其他 region。

模型工具激活时把 viewport 的选择权交给 Edit plugin，提示点不得同时改变选中 region。第一个提示锁定当时的创建/修正模式和选区 ID；取消或提交前不能切换目标 region。退出该工具时无论成功、失败还是取消都必须恢复 viewport 默认选择行为。

### 5.2 状态机

| 状态 | 可提交 | 阻止导航 | 行为 |
|---|---:|---:|---|
| `unavailable` | 否 | 否 | 显示解释器/import/checkpoint/设备的具体失败 |
| `ready` | 否 | 否 | 等待第一个提示；可显示选中 region 的初始 mask |
| `requesting` | 否 | 是 | 已冻结最新 prompt revision；旧候选不可 Apply |
| `candidate` | 是 | 是 | 显示最新 revision 的安全 Poly，允许切换/追加/Apply |
| `invalid` | 否 | 是 | 最新候选无法表达；允许换候选、追加提示或 Cancel |
| `failed` | 否 | 是 | 保留提示，允许 Retry、Backspace 或 Cancel |
| `awaiting_class` | 否 | 是 | 创建模式复用现有类别对话框 |

在 `requesting` 中添加新提示时，先使旧 request token 失效，然后合并到最新 revision；旧响应只能被丢弃，不得恢复按钮或覆盖预览。

### 5.3 外部运行时与 `model-assist-v1`

项目 `.venv` 不增加 Torch/SAM。运行时通过环境变量注入，不在仓库硬编码用户路径：

- `PROJECT6_MODEL_PYTHON`：外部 Python 可执行文件绝对路径；
- `PROJECT6_SAM2_CONFIG`：官方 SAM 2 config 绝对路径；
- `PROJECT6_SAM2_CHECKPOINT`：本地 checkpoint 绝对路径；
- `PROJECT6_SAM2_DEVICE`：`auto`、`cpu` 或 `cuda`，默认 `auto`。

preflight 分别报告 Python、Torch、`sam2`、config、checkpoint、权重 SHA-256 和实际 device。CUDA 可用时优先 CUDA；CUDA 不可用时允许 CPU 功能验收，但界面必须持续显示“CPU，较慢”。不得在用户选定 CUDA 后静默回退。

service 按需启动一个持久 worker，使模型只加载一次，并缓存当前图像 embedding。切帧、图像 revision 变化或 Source 关闭时清除图像缓存；退出 Edit plugin 或程序退出时关闭 worker。

JSONL 协议顶层字段固定为 `protocol/request_id/op/context/data`，响应固定为 `protocol/request_id/ok/context/data/errors`。支持 `hello`、`set_image`、`predict`、`cancel` 和 `shutdown`；拒绝重复 key、额外字段、非有限数、未知 op 与超过 1 MiB 的行。

`predict` context 固定携带 session ID、frame ID、playback index、图像 SHA-256、Store record SHA-256、选区 ID 和 prompt revision。data 最多 64 个点、一个框和一个初始 mask。worker 返回最多三个候选；每个候选使用 job 目录内的二值 ROI PNG、ROI 坐标、SHA-256 与原始 model score，不把大 mask 内联到 JSON。

job 目录为 service 创建的唯一临时目录。所有输入/输出必须解析后位于该目录、为普通文件且非符号链接；哈希、尺寸、ROI 和二值像素都由 Godot 端重新校验。载模最多 180 秒，单次预测最多 60 秒；超时后只终止 service 自己创建的 PID。

### 5.4 mask 到 Poly 安全门

Godot 使用现有 mask/polygon 边界对每个 SAM 候选独立校验：

- mask 非空、非整图，像素值只有 0/255；
- 恰好一个连通分量、无洞，不越界；
- 外轮廓可表达为单个非退化、非自交简单环，最多 2048 顶点；
- Poly 重新栅格化与候选 mask 的 IoU 至少 0.99；
- 修正模式提交前必须重新比对原 before record 和选区 ID。

失败候选可显示具体原因，但不得被修补成另一个几何。

## 6. 相似度门控与 Poly 传播

### 6.1 同快照相似度

PolygonPropagationService 在一次分析中冻结完整 Source entry 元数据、参考/目标 record、review 状态与每帧独立 PNG。Python worker 严格对这些 PNG 先执行 `gray64-area-mad-v1`：

1. 将图像转为 64×64 灰度 `uint8`，缩放使用 OpenCV `INTER_AREA`；
2. 计算归一化平均绝对差，范围 `[0,1]`；
3. 每个目标同时必须满足 `adjacent_mad < threshold` 且 `keyframe_mad < threshold`；
4. 原始 frame ID 缺号、已确认目标帧、图像尺寸变化或 30 帧上限均截断对应方向。

相似度门不只决定 UI 范围；门外帧不得进入光流或边缘阶段。阈值改变必须使现有 plan 失效。

### 6.2 光流基线

通过相似度的连续帧继续使用已验证的 OpenCV DIS 正反向光流、反向 mask 映射、局部纹理/外观证据、不可靠连通块、相邻/关键帧面积门和固定关键帧锚点一致性。分析分辨率保持比例，长边最多 1024 像素。

参考帧中每个 Poly 独立传播；单批参考 Poly 的输入顶点总数最多 4096，每个输出候选最多 2048 顶点。任一 Poly 的 raw-flow mask 无法通过现有证据或拓扑门时，该方向停在上一帧，不跳过失败帧。

## 7. 局部边缘精修

### 7.1 算法

新增 `polygon_edge_refinement.py`。对每个通过 raw-flow 安全门的 mask，在分析分辨率执行如下有界精修：

1. 以 raw mask 为 seed，用 6 analysis-pixel 半径做腐蚀和膨胀。腐蚀内部是确定前景，raw 内边带是可能前景，raw 外边带是可能背景，膨胀外是确定背景。
2. ROI 为膨胀 mask 包围框再外扩 8 analysis pixels，并裁剪到图像边界。确定前景为空、ROI 超过现有像素/内存上限或边带无法建立时，返回结构化 fallback。
3. 在 ROI 上运行固定 3 轮 OpenCV GrabCut mask 初始化，不使用整图矩形初始化，不连锁第三方分割模型。
4. 相邻传播和“关键帧直达当前帧”的 anchor mask 都独立运行相同精修函数，然后再做固定锚点 IoU 门。

### 7.2 接受门与回退

精修候选只有同时满足以下条件才替换 raw-flow mask：

- 恰好一个连通分量、无洞、不贴裁剪边界；
- 与 raw mask 的 IoU 至少 0.85，面积比在 `[0.80, 1.25]`；
- 双向边界 Hausdorff 距离不超过 6 analysis pixels；
- 一像素边界上的归一化 Sobel 梯度均值相比 raw mask 至少提高 `0.01`；
- 重新执行光流局部证据、相邻/关键帧面积、固定锚点一致性和最终单环 Poly 门仍全部通过。

预期性拒绝由精修函数返回 `accepted=false/reason/...scores`，当前帧改用 raw-flow mask 并继续传播；不把 fallback 误报成整批失败。图像解码、OpenCV 运行时异常或协议损坏不属于预期性拒绝，必须终止整个未应用 plan，不静默回退。

被接受的 refined mask 成为下一帧的传播 seed；fallback 时 raw-flow mask 成为 seed。该规则使累积漂移风险可被每帧锚点诊断捕获，不会暗中使用上一个被拒绝的边缘结果。

## 8. Batch 候选、提交与审计

provider 结果使用 `metric_id=poly-sim-flow-edge-v1`，并包含：

- key/start/end playback index 和真实 frame ID；
- 阈值、每帧 adjacent/keyframe MAD 及左右停止原因；
- 每帧 target regions，且 region 非几何字段与参考帧一致；
- 每帧每个 region 的 raw-flow 质量、edge attempted/accepted/fallback reason、raw/refined edge score；
- Source entry、图像、参考记录、目标 before record 和 review 状态摘要。

Batch operation marker 升级为内部 `schema_version=2`，同时继续读取 v1。v2 至少保存 mode、metric ID、threshold、keyframe、真实/播放范围、停止原因、changed/covered 数和有界 `edge_refinement` 摘要。详细数组最多 29 个目标帧×参考 Poly 数，每项只保存 frame ID、region ID、accepted/reason 和有限分数；不保存 mask、光流或像素数组。

Apply 前再比对所有摘要与 before 快照。任一 Source、图像、参考/目标 record 或 review 状态改变都使 plan 整体 stale。命令成功后仍不改变 review state；保存失败沿用现有可重试保存，不重跑算法来猜测已提交结果。

## 9. UI 文案与恢复行为

### 9.1 模型辅助

- 解释器无效：`模型辅助不可用：外部 Python 无法执行。`
- 缺少包：`模型辅助不可用：解释器中未安装 sam2。`
- 缺少权重：`模型辅助不可用：未配置可读的 SAM2 checkpoint。`
- CPU：`SAM2 已就绪 · CPU（较慢）`
- 推理失败：`推理失败，当前标注未修改；可重试或按 Escape 取消。`
- stale：`图像或标注已变化，旧候选已取消。`
- 非法候选：`候选无法表达为单环 Poly：<具体原因>。`

缺少运行时时工具仍可见，用户选中后可看到上述具体 preflight 原因和 Recheck，但画布提示输入不会启动。

### 9.2 Batch

主摘要始终显示候选帧数、相似度停止、光流停止和 edge 接受/fallback 统计，不把停止原因只放在“高级设置”。

- 仅参考帧：隐藏或禁用范围和 Apply，直接显示双向停止原因。
- 原始帧号缺失：显示下一个 Source frame ID 和缺号区间，可“跳到下一段连续帧”，不允许跨越。
- edge fallback：预览仍可用，明示 `边缘精修 X 帧，光流回退 Y 帧`；逐帧诊断可展开。
- 批次预览中禁止普通编辑；关闭预览后恢复。

`_show_tab(true)` 必须先通过编辑导航门。模型辅助草稿、Fill 草稿或类别对话框活动时，保留“标注”页且显示完成/取消提示，不能只隐藏工具面板。

## 10. 错误、取消与生命周期

- SAM 请求失败、超时、崩溃、越界路径、哈希不一致、畸形响应或 stale token：不修改 Store/history，清理临时输出，并保留可恢复 UI。
- Batch 的预期 edge refusal 仅回退 raw-flow；协议、解码、Source 或 Store 一致性错误取消整个 plan。
- 用户 Cancel 先使本地 token/plan 失效，再请求子进程停止；晚到输出无条件丢弃。
- service 只能终止它创建且 PID 与 session 匹配的进程，只能删除它创建的精确 job 目录。
- Source 关闭、工作区切换、Edit plugin deactivate 和程序退出都必须使请求失效、关闭 worker、清除覆盖层与临时文件。
- 存储失败只由现有 WorkspaceSession 重试；不为了重建已提交结果而重跑 SAM 或 Poly 算法。

## 11. 实施迁移

当前隔离分支中的中间工作按如下处理：

- 保留 Poly 传播基线、无候选/稀疏端点 UI 修复和通用 Batch provider seam；
- 删除或替换未接入产品的 `sam-batch-v1` 协议、worker 与相关测试，不继续构建 SamBatchProvider；
- 把 Poly provider 升级为相似度 + 光流 + edge 的单一策略，不再另走一次 Source 图像扫描；
- 修复 `test_polygon_batch_ui.gd` 访问已移除私有字段却仍打印 PASS 的假阳性，验收 harness 必须将任何 `SCRIPT ERROR` 视为失败。

不在主脏工作区上实施。所有变更继续位于已创建的 `test/sam-assisted-batch` 隔离分支，最终再经用户决定如何集成。

## 12. 测试与完成门槛

### 12.1 模型辅助工具

- descriptor、`M` 快捷键、创建/修正模式、正负点、提示框、Backspace、候选切换、Apply/Cancel 的插件和真实 Main UI 测试；
- preflight 缺失、CPU/CUDA 徽标、子进程超时/崩溃、畸形/过大协议、路径/哈希及清理测试；
- 在飞行请求竞争、切帧、选区/Store 变化、Source 切换的 stale 响应拒绝；
- mask 空/整图/多分量/洞/越界/自交/超顶点与安全候选测试；
- 创建和修正分别只产生一条命令，undo/redo 往返一致，非法/取消路径 Store/history 完全不变；
- 保存、重开、Model Output V1 投影和原始模型摘要不变。

fake worker 用于穷尽协议和 UI 分支，但不足以声明模型工具完成。至少需在用户允许的外部 Conda 环境中用官方 SAM 2 图像 predictor 和本地 checkpoint 完成一次 CPU 或 CUDA 真实创建、修正、取消、undo/redo、保存/重开闭环。若只能使用 CPU，GPU 性能仍明确为未验证。

### 12.2 Poly 边缘传播

- 相似度必须同时测试 adjacent/keyframe 门、等于阈值的拒绝、原始帧号缺失、已确认帧保护、尺寸变化和 30 帧上限；
- edge 单元测试覆盖可接受边界、弱边缘、细小目标、多分量、洞、贴边、超移动、面积漂移与 OpenCV 异常；
- 合成平移、旋转、非刚性形变、遮挡和弱纹理序列分别比较 raw-flow 与 edge-refined IoU，必须至少有一类边界偏移样本展示可重复的 IoU 改善，且不安全样本正确 fallback；
- 正反向停止、多 Poly 失败、候选范围缩短、覆盖/合并、预览、一次 apply/undo/redo、verified 保护和 stale 拒绝；
- v1 marker 兼容、v2 marker 严格校验、edge 摘要保存/重开和 V1 输出不污染；
- 真实 Main 场景验证默认算法、阈值可见、模式文案、无候选、预览、保存、重开、确认和自动前进。

### 12.3 Endoscapes 真实连续帧验收

- 优先使用本地 Endoscapes2023 的 1 fps 连续帧做真实 Batch smoke test；数据集根目录由命令行参数传入，不在仓库中硬编码用户路径。
- 新增可重复的 fixture 准备脚本，只把选定片段链接或复制到本地忽略目录，生成播放索引连续的 manifest，并在独立 provenance JSON 中保留 Endoscapes video ID、原始 frame number、文件相对路径与 SHA-256。不改写原数据集，不提交图像或标注。
- 默认确定性 smoke 片段为 video `65`、原始 frame `11775..11875`、步长 `25`，关键帧为 `11800`。当前数据快照在默认阈值 `0.02` 下可覆盖 5 帧；这是真实路径可运行性证据，不是固定精度基准。
- 另可准备同一 video 内最多 30 帧的连续窗口，用于验证相似度停止、光流停止、范围上限和诊断；不要求 30 帧全部通过默认阈值。
- 以 `insseg/65_11800.npy` 及匹配 CSV 中的实例作为关键帧 seed，记录每帧 raw/refined 边界、edge accepted/fallback 原因与人工判读。因 Endoscapes-Seg50 只对稀疏帧有真值，未额外人工标注的目标帧只做定性验收；可量化 IoU 改善仍以合成序列为主。

### 12.4 回归与证据边界

- 修复所有会在出现 `SCRIPT ERROR` 后仍输出 PASS 的 focused harness；验收必须同时检查进程状态和日志。
- 运行完整 Python 套件、完整 Godot 套件和所有新增 focused gates；任何失败、未处理异常或 `SCRIPT ERROR` 都不得声明完成。
- 更新 README、architecture、plugin API、Poly 文档、RESULTS 和 requirements traceability，明确分开实现、自动证据、真实 SAM 运行、真实手术视频精度与 GPU 性能。
- 按 12.3 的 Endoscapes 片段做可见 Batch 预览，记录边缘接受/fallback 和人工检查边界。没有人工真值时只报告定性结果，不声称手术数据准确率已被证明。

## 13. 当前环境边界

设计批准时的实测状态为：

- 项目 `.venv` 为 Python 3.14，有 NumPy/OpenCV，无 Torch/SAM2；
- `VLM1` 与 `project6` Conda 环境有 `torch 2.11.0+cu128`，但都无 `sam2`；
- 当前 `/dev/nvidia0` 和 `/dev/nvidiactl` 不存在，`nvidia-smi` 无法连接驱动，PyTorch 报告 `cuda_available=false`；
- 未在本机发现 SAM 2 config/checkpoint。

因此实施可先完成无模型 TDD、Poly edge 全链路与 CPU 运行时接入；真实 SAM 闭环需在用户授权后向一个外部 Conda 环境安装 `sam2` 并配置本地官方 checkpoint。GPU 性能验收继续依赖系统驱动恢复。

## 14. 实施后的用户可见边界

实施可以宣称：

- 模型辅助是可撤销、可取消、有严格 stale 保护的单帧 Poly 工具；
- Batch 的默认路径确实先验证相似帧，再用光流传播 Poly，并仅在安全且有可测边缘改善时接受精修；
- 算法候选、人工确认、Model Output V1 和持久化审计仍有清晰所有权。

在完成真实评测前不得宣称：

- SAM2 已在当前机器通过 CUDA 性能验收；
- 边缘精修在所有手术场景都比 raw flow 更准；
- 未经人工确认的传播帧已是可信 ground truth。
