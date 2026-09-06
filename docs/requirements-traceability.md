# 要求追踪表

本台账将老师要求与实现证据分开。`PASS` 表示已实际运行直接自动证据或已完成指定文档交付；`BLOCKED` 表示该 Part 尚未作为完整交付范围验收。当前仓库声明完成 Part 1、Part 2.1 和 Part 3.1。Part 2.2/2.3 的七工具自动化证据已通过，但可见性能与人工 reviewer 仍待验证。Part 3.1 的导入、播放、显式 frame/time、对齐和长片测试均已通过。Part 3.2/3.3 及后续功能不提前记为完成。

| 要求来源 | 要求 | 实现 | 自动化证据 | 人工证据 | 状态 | 后续任务 |
|---|---|---|---|---|---|---|
| Part 1.1 Data contract | 版本化的逐图模型输出 Schema，包含 source/frame、可选 time_s 和 regions | `core/schemas/model_output_v1.schema.json` | `tests/python/test_part1_1_data_contract.py`; `tests/godot/test_model_output_validator.gd` | 已对照 Assignment 示例逐字段核验 | PASS | 完成 |
| Part 1.1 | Python validator | `python/validate_model_output.py`; `python/annotation_data/contracts.py` | `tests/python/test_part1_1_data_contract.py` | README 包含独立 CLI | PASS | 完成 |
| Part 1.1 | 具有字段路径错误且不使界面崩溃的 Godot validator | `client/domain/model_output_validator.gd` | `tests/godot/test_model_output_validator.gd`; Source/Store 测试 | 客户端通过错误数组保留可恢复状态 | PASS | 完成 |
| Part 1.1 | Contract version 1 和不可变 `model_output_vX` 基线 | `model_output_v1.jsonl`; `AnnotationStore` 分别保存模型基线和修正副本 | Python SHA-256 测试；Godot Store 摘要测试 | 架构文档记录所有权 | PASS | 完成 |
| Part 1.2 Reproducible sample | 固定种子的合成图像序列和匹配标注 | `python/make_sample_input.py`; `python/annotation_data/sample.py` | `test_sample_is_deterministic` | README 记录评审命令 | PASS | 完成 |
| Part 1.2 defects | Drifted regions（漂移区域） | 种子 6006 的第 12、13 帧 | `test_sample_contains_required_defects` | `expected_defects.json` | PASS | 完成 |
| Part 1.2 defects | Wrong class labels（错误类别） | 种子 6006 的第 24 帧 | `test_sample_contains_required_defects` | `expected_defects.json` | PASS | 完成 |
| Part 1.2 defects | Missed region（漏检区域） | 植入样本缺陷 | `test_sample_contains_required_defects` | `expected_defects.json` | PASS | 完成 |
| Part 1.2 defects | Hallucinated region（幻觉区域） | 植入样本缺陷 | `test_sample_contains_required_defects` | `expected_defects.json` | PASS | 完成 |
| Part 1.2 defects | Track-id swap（追踪 ID 交换） | 植入样本缺陷 | `test_sample_contains_required_defects` | `expected_defects.json` | PASS | 完成 |
| Part 1.2 sequence | Near-identical frames（近似相同帧） | 固定 40–59 帧段和 similarity scores | `test_similar_run_is_near_identical_with_distinguishable_boundaries` | Timeline 评审留待后续 batch 工作 | PASS | 完成 |
| Part 1.3 Frame source | 将任意 FFmpeg 可读视频解码为索引帧 | `python/frame_source.py`; `python/annotation_data/frame_source.py` | `tests/python/test_frame_source.py`；FFmpeg/FFprobe 真实视频集成测试 | 普通、多流、90° 显示旋转、负 PTS 和整段无 PTS 视频均被解码 | PASS | 完成 |
| Part 1.3 | 将视频、序列和 standalone image 统一为索引帧 | `image_sequence_source`; `single_image_source`; manifest contract | Source、单图和 playback 测试 | 1280×800 验收打开单图和 120 帧目录 | PASS | 完成 |
| Part 1.4 Source stage | 可替换的 frames + model annotations Source | `SourceStage`; `image_sequence_source`; `single_image_source`; plugin-owned `can_open` / `get_presentation` | Source、单图、多 root priority registry 和非文件 Main 集成测试 | 单图/目录/服务器式 locator 均由同一 indexed-frame Main 路径显示 | PASS | 完成 |
| Part 1.4 Render stage | 可替换的工作 Renderer | `RenderStage`; `canvas_region_renderer`; `null_renderer` | Renderer 与 viewport 注入测试 | 已显示区域、label、confidence 和选中轮廓 | PASS | 完成 |
| Part 1.4 Edit tools stage | 插件化 select/move/resize/relabel/add/delete/range propagate | `EditStage`; `basic_edit_tools`; `propagate_range_command.gd`; plugin tool descriptors | command、keyboard、range、ToolPanel 和集成测试 | Selection 合并 move/resize；Part 2.2 工具重建另列为待验证 | PASS | 完成 |
| Part 1.4 Export / Feedback stage | corrected dataset 与 training handoff package | `FeedbackStage`; `file_training_handoff`; Main Export wiring | Feedback checksum/atomic publish 与 playback 主界面导出测试 | 有效 Source 打开后 Export 启用；已有目标拒绝覆盖 | PASS | 完成 |
| Part 1.4 Plugin registry | 启动多目录发现、typed Stage、descriptor/factory、priority、能力/API/参数检查和错误隔离 | `plugin_descriptor.gd`; `plugin_registry.gd`; `export_presets.cfg` | registry 生产/错误/duck-typed 拒绝/重叠 priority/extension 测试 | README 列出四个 stage | PASS | 完成 |
| Part 1 deliverable | Plugin API document | `docs/plugin-api.md` | `tests/python/test_documentation.py` | 接口签名已对照代码 | PASS | 完成 |
| Part 1 deliverable | Architecture diagram | `docs/architecture.md` | `tests/python/test_documentation.py` | Mermaid 源码可读 | PASS | 完成 |
| Part 1 deliverable | README runbook、版本、命令、评审路径和快捷键 | `README.md` | `tests/python/test_documentation.py` | 已在参考主机复现 | PASS | 完成 |
| Part 1 verification | Zero-error sample validation | 样本生成器和 Model Output V1 验证器 | 种子 6006 生成 120 条记录和 120 帧；验证器状态 0 | 命令输出 `Validation errors: 0` | PASS | 完成 |
| Frontend layout | 左栏只读显示当前已接受数据集，中央保留真实 viewport | `DatasetExplorer`; `WorkspaceSplit`; `AnnotationViewport` | explorer、main boundary、playback 测试 | 单图显示 `Frames (1)`；数据集显示 `Frames (120)` | PASS | 完成 |
| Frontend layout | 右侧可滚动 Inspector 下固定无分类、四列工具区 | `InspectorScroll`; `ToolPanel` | frontend structure 与 tool panel 测试 | 描述子的图标、名称和 focus 属性可读 | PASS | 完成 |
| Tool inventory | 七工具：Add Box、Subtract、Lasso、Fill、Paint、Eraser、Select；Close Gaps、Region Growing、Live Wire 已移除 | `basic_edit_tools` descriptors/capabilities；`C/E/G/I` 未绑定 | advanced、ToolPanel、registry、keyboard gates | 七工具已在真实 UI 路径执行 | BLOCKED | 自动化通过；可见性能/人工复跑待完成 |
| Navigation safety | Explorer、timeline、previous/next、playback、seek 收敛到同一帧高亮；拒绝导航或替换时保留状态 | `AnnotationMain` 单向同步和失败原子 Source 事务 | playback、main boundary、explorer 测试 | 规范化数据集渲染显示帧与 timeline 对齐 | PASS | 完成 |
| Sparse review playback | 稀疏原始帧号按可调展示时钟连续评审，原始时间元数据保持只读 | `PlaybackController` review/max 时钟；顶部 Custom/3 s/1 s/Max 速度条；`PlaybackFpsMeter` 实际交付统计 | `test_playback_controller.gd`; `test_playback_fps_meter.gd`; `test_playback_speed_control.gd`; `test_workspace_integration.gd` | VID68 的 16→23 默认等待 1 s；Custom 2.5 s 和 Max 连续索引均通过，时间戳未改写 | PASS | 完成 |
| Workspace media | 递归打开外层或数据集文件夹，左树选中后才加载图片/序列或解析视频 | `WorkspaceCatalog`; `WorkspaceMediaController`; `WorkspaceSequenceSource`; `DatasetExplorer` | catalog、media controller、workspace integration 测试 | `Dataset_test` 及 `Dataset_test/cholect50-challenge-val` 只读扫描 | PASS | 完成 |
| Workspace labels | 每媒体仅最近数据集根的 `label/<media_id>.json`，上下文索引统一自动读写，源 `labels/` 只读，保留稀疏原始帧 ID | `WorkspaceCatalog`; `MediaLabelStore`; `WorkspaceSession`; `CholecT50LabelAdapter`; media-label-v1 Schema | Python contract、Godot nested label-root/integration 测试 | 从外层 `Dataset_test` 选择 VID68 恢复子数据集标注；`VID68_000016` 仍由媒体 ID 和原始帧 16 派生 | PASS | 完成 |
| Resize boundary | 两个侧栏可调整，不引入 docking 或文件管理行为 | 嵌套 `WorkspaceSplit` 与 `ContentSplit` | frontend structure 测试 | split offset 250/660 时中央仍可用 | PASS | 完成 |
| Part 1 integration | 数据契约、插件 API、三栏组合和现有编辑行为共同工作 | 完整仓库 | 2026-09-04 回归结果：Godot exit 0 且末行 `PASS`；Python `89 passed`；样本重生成 0 errors 且 SHA-256 一致 | 实际 Godot 4.7.2、X11/GL Compatibility 渲染 | PASS | 完成 |
| Part 2.1 Display | 原图与 regions 在保持宽高比的统一 zoom/pan/camera 下显示，并使用同一逆变换 picking | `ViewportTransform` 唯一 `Transform2D`；`AnnotationViewport` Fit、resize 中心保持和越界输入防护 | `test_viewport_transform.gd`; `test_annotation_viewport.gd` | 1280×800 可见窗口中自动执行 pan、zoom 和选择 | PASS | 完成 |
| Part 2.1 Display | box、polygon、complex polygon、分类颜色、label、confidence 和 opacity | `RegionGeometry`; `canvas_region_renderer`; polygon-first；fill-only opacity；对比 label background | `test_region_geometry.gd`; `test_renderer.gd`; `test_edit_commands.gd` | 正式样本每帧有一个 12 顶点凹 polygon，选中项全不透明 | PASS | 完成 |
| Part 2.1 sample evidence | 约 20 regions 的可复现混合几何样本 | `python/annotation_data/sample.py`; `sample/assignment_v1` | `test_sample_model_output_matches_assignment_contract`; Model Output V1 validation 0 errors | 20 regions 包含 box、4 个 polygon 和其中一个 complex concave polygon | PASS | 完成 |
| Part 2.1 performance | 拖动/缩放中平滑显示，平均至少 30 fps 且记录优化 | dirty redraw、image-space primitive cache、screen command rebuild、AABB culling、单一深拷贝边界 | `tests/benchmarks/godot/display_benchmark.gd`; `tests/benchmarks/results/part2_1_display.json` | X11/llvmpipe：175.27 fps，p95 9.572 ms，10 s/1753 frames，拖动误差 0.0 px | PASS | 仅对当前实测主机成立 |
| Part 2.1 deliverable | 坐标、polygon 边界、优化、设备、帧时间和限制记录 | 根目录 `RESULTS.md`; README Reviewer test script | `tests/python/test_documentation.py` 与 raw benchmark 一致性测试 | 命令可复跑，未新建额外 part2.1 report | PASS | 完成 |
| Part 2.2 Editing | Select 及高亮；move/resize handles；1/5/10 px nudge | Select 统一 direct manipulation | 真实 viewport、keyboard、undo/redo gates | 自动化通过 | BLOCKED | 可见性能/人工复跑待完成 |
| Part 2.2 Editing | Re-label list + free text；Add box/polygon；remove | 类别对话框、Sidebar、Select Delete/Backspace | Inspector、command、integration gates | 自动化通过 | BLOCKED | 人工复跑待完成 |
| Part 2.2 Editing | Add Box、Subtract、Lasso、Fill、Paint、Eraser、Select | Paint 多孔 WorkingMask 逐次 Fill 后生成一个实心对象；Lasso/Subtract 近距离自动闭合并接受多闭区轨迹；无选区 Subtract 原子删减多 region；右键取消选择并切回 Select | V1 refusal、WorkingMask、batch undo 和真实 UI gates | 自动化通过 | BLOCKED | 可见性能/人工复跑待完成 |
| Part 2.2 Editing | 每个 edit 的 undo/redo | 容量 200 的 command history | command、integration、keyboard gates | 自动化通过 | BLOCKED | 人工复跑待完成 |
| Part 2.2 Editing | 每个 edit 键盘可达，schema-invalid 编辑解释并原子拒绝 | `V/A/S/L/F/P/Shift+P`；`C/E/G/I` unbound；Lasso/Subtract 近距离松手自动吸附，Space 强制闭合 | keyboard/refusal gates | 自动化通过 | BLOCKED | 人工复跑待完成 |
| Part 2.2 deliverable | runnable client 与逐项 reviewer test script | 待实现与复跑 | Godot focused/full suite；`test_documentation.py` | 人工复跑尚未开始 | BLOCKED | 待验证 |
| Part 2.3 Design note | MITK 编辑交互的 emulated/adapted/dropped/why 决策 | `RESULTS.md` pending decision log | `tests/python/test_documentation.py` | 引用官方 MITK Segmentation View，不声称 MITK 等价 | BLOCKED | 待验证 |
| Part 3.1 Frame-accurate stream | Play/Pause、Previous/Next 单步、seek 和显式 frame/time；索引与 annotation 严格对齐 | `PlaybackController`、`PlaybackFpsMeter`、折叠式顶部速度调节、`AnnotationMain` 原子 `set_frame()`、manifest `time_s`；运行栏同时显示已提交帧的只读 `HH:MM:SS.mmm` 和 actual FPS | `test_playback_controller.gd`; `test_playback_fps_meter.gd`; `test_playback_speed_control.gd`; `test_playback.gd`; `test_workspace_integration.gd`; `tests/benchmarks/results/part3_1_playback.json` | X11/llvmpipe 基准交付 1–153 连续帧、0 跳帧；帧 0/7 与稀疏帧 16/23 的显式时间对齐；速度、时间和 FPS 显示不改动 Store/label/time_s | PASS | 完成 |
| Part 3.1 video import | Godot 后台将 FFmpeg 可读原视频归一化，显示进度、可取消，成功后自动打开 | `VideoImportController`; 固定 `.venv/bin/python`; Python progress/cancel/staging | Python 真实视频/取消测试；`test_video_import_controller.gd`; `tests/benchmarks/results/part3_1_import.json` | 640×360/90 帧 FFV1 真实导入+打开 0.789 s，107 个 UI heartbeat，旧数据集全程保留 | PASS | 完成 |
| Part 3.1 long clips | 图像像素按需加载且缓存有界，长片 UI 不逐帧物化 | 12-entry `FrameCache`; virtual timeline; Explorer >500 summary mode | `test_source_plugin.gd`; `test_dataset_explorer.gd`; `tests/benchmarks/results/part3_1_long_source.json` | 10,000 帧打开 1048.448 ms；0/5000/9999/137/8765 精确 seek；5 个 TreeItem；缓存 5/12 | PASS | 完成 |
| Part 3.1 deliverable | 索引保证、时间策略、导入、性能和限制记录 | 根目录 `RESULTS.md`; README Reviewer test script; architecture | `tests/python/test_documentation.py` 与三份 raw Part 3.1 benchmark 一致 | 未创建额外 part3.1 report | PASS | 完成 |
| Part 3.2 Batch labelling | similarity threshold、keyframe propagation、overwrite/merge marker、verified/unverified UX 和 auto-advance | 现有 Part 1 primitive 不代表该工作流已完成 | 未作为 Part 3.2 门禁评估 | 未评估 | BLOCKED | 后续阶段 |
| Part 3.3 Measurement | batch coverage、manual comparison、threshold 和边界质检 | 依赖 Part 3.2 完整工作流 | 未评估 | 未评估 | BLOCKED | Part 3.2 后完成 |
| Part 4 | Autosave、diff、完整 update package 工作流和协作协议 | Part 1.4 仅提供最小本地 checksummed handoff，不代表 Part 4 | 未作为 Part 4 门禁评估 | 未评估 | BLOCKED | 后续阶段 |
| Part 5 | 完整稳健性、smoke session、测量和失败分析 | 超出 Part 1 范围 | 未评估 | 未评估 | BLOCKED | 后续阶段 |

## 前端验收证据边界

- **真实渲染观察：**1280×800 的单图和规范化数据集会话已观察数据集浏览器、中央视口、Inspector、metadata、分隔条和 Part 2.1 overlay。不把旧运行时的预留工具观察当成 Part 2.2/2.3 重建的人工证据。
- **Part 2.2 门禁：**七工具、真实 viewport、keyboard、undo/redo 和 V1 拒绝路径已通过自动化；可见编辑性能和人工 reviewer 仍待验证。
- **Part 2.2 人工边界：**正式 reviewer script 尚未在重建运行时复跑，不声称这些点击已被人工观察。
- **Part 2.1 可见基准：**1280×800、20 regions 的 X11/GL Compatibility 会话自动执行 pan、zoom 和真实 region drag；帧间隔与设备信息保存在 `tests/benchmarks/results/part2_1_display.json`。基准后的 framebuffer 截图已人工核对 letterbox、20 个 overlay/对比 label、选中高亮和 12 顶点凹 polygon。
- **Part 3.1 真实导入：**Godot 后台处理 640×360、90 帧 FFV1 视频，观测到四个 progress stage 和 107 个 UI process heartbeat；完成后自动打开 frame 0。原始数据在导入全程保留。
- **Part 3.1 可见播放：**640×360、20 regions 的 X11/llvmpipe 会话运行 10.026 s，实际 15.26 fps，从帧 1 到 153 严格连续且 0 跳帧。帧状态读取已提交 Source entry 的 `time_s` 而不是墙钟时间；这是“慢下来而不跳帧”策略的可见证据，不是对所有设备的播放速率承诺。
- **Part 3.1 长片压测：**10,000 帧源的五个跨段 seek 全部精确，LRU 缓存为 5/12，Explorer 只有 5 个 TreeItem，Timeline 没有逐帧 Button。
- 不声称人工逐个点击了每个当前工具、每条导航路径或无效替换场景；未复跑的人工操作不充当 PASS 的伪造证据。
