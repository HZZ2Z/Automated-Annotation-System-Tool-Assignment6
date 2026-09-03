# 要求追踪表

本台账将老师要求与实现证据分开。`PASS` 表示已实际运行直接证据；`BLOCKED` 表示该 Part 尚未作为完整交付范围验收。当前仓库只声明完成 Part 1，不把后续功能提前记为完成。

| 要求来源 | 要求 | 实现 | 自动化证据 | 人工证据 | 状态 | 后续任务 |
|---|---|---|---|---|---|---|
| Part 1.1 Data contract | 版本化的逐图模型输出 Schema，包含 source/frame、可选 time_s 和 regions | `core/schemas/model_output_v1.schema.json` | `tests/python/test_part1_1_data_contract.py`; `tests/godot/test_model_output_validator.gd` | 已对照 Assignment 示例逐字段核验 | PASS | 完成 |
| Part 1.1 | Python validator | `python/validate_model_output.py`; `python/annotool/contracts.py` | `tests/python/test_part1_1_data_contract.py` | README 包含独立 CLI | PASS | 完成 |
| Part 1.1 | 具有字段路径错误且不使界面崩溃的 Godot validator | `client/domain/model_output_validator.gd` | `tests/godot/test_model_output_validator.gd`; Source/Store 测试 | 客户端通过错误数组保留可恢复状态 | PASS | 完成 |
| Part 1.1 | Contract version 1 和不可变 `model_output_vX` 基线 | `model_output_v1.jsonl`; `AnnotationStore` 分别保存模型基线和修正副本 | Python SHA-256 测试；Godot Store 摘要测试 | 架构文档记录所有权 | PASS | 完成 |
| Part 1.2 Reproducible sample | 固定种子的合成图像序列和匹配标注 | `python/make_sample_input.py`; `python/annotool/sample.py` | `test_sample_is_deterministic` | README 记录评审命令 | PASS | 完成 |
| Part 1.2 defects | Drifted regions（漂移区域） | 种子 6006 的第 12、13 帧 | `test_sample_contains_required_defects` | `expected_defects.json` | PASS | 完成 |
| Part 1.2 defects | Wrong class labels（错误类别） | 种子 6006 的第 24 帧 | `test_sample_contains_required_defects` | `expected_defects.json` | PASS | 完成 |
| Part 1.2 defects | Missed region（漏检区域） | 植入样本缺陷 | `test_sample_contains_required_defects` | `expected_defects.json` | PASS | 完成 |
| Part 1.2 defects | Hallucinated region（幻觉区域） | 植入样本缺陷 | `test_sample_contains_required_defects` | `expected_defects.json` | PASS | 完成 |
| Part 1.2 defects | Track-id swap（追踪 ID 交换） | 植入样本缺陷 | `test_sample_contains_required_defects` | `expected_defects.json` | PASS | 完成 |
| Part 1.2 sequence | Near-identical frames（近似相同帧） | 固定 40–59 帧段和 similarity scores | `test_similar_run_is_near_identical_with_distinguishable_boundaries` | Timeline 评审留待后续 batch 工作 | PASS | 完成 |
| Part 1.3 Frame source | 将任意 FFmpeg 可读视频解码为索引帧 | `python/frame_source.py`; `python/annotool/frame_source.py` | 完整 Python 门禁；FFmpeg/FFprobe 集成测试 | 三帧和多流无损视频均被解码 | PASS | 完成 |
| Part 1.3 | 将视频、序列和 standalone image 统一为索引帧 | `image_sequence_source`; `single_image_source`; manifest contract | Source、单图和 playback 测试 | 1280×800 验收打开单图和 120 帧目录 | PASS | 完成 |
| Part 1.4 Source stage | 可用的归一化目录和单图插件 | `client/plugins/source` | Source 和单图插件测试 | 两条 Source 路由均成功显示 | PASS | 完成 |
| Part 1.4 Render stage | 可替换的工作 Renderer | `canvas_region_renderer` | Renderer 与 viewport 集成测试 | 已显示区域、label、confidence 和选中轮廓 | PASS | 完成 |
| Part 1.4 Edit tools stage | 明确的 Edit plugin 边界 | `basic_edit_tools` | command、keyboard、ToolPanel 和集成测试 | 五个可用工具与七个预留控件清楚分离 | PASS | 完成 |
| Part 1.4 Export / Feedback stage | 已验证的 corrected JSONL 插件 | `file_training_handoff` | `test_feedback_plugin.gd` | Part 1 中 UI Export 保持禁用 | PASS | 后续接入完整 UI package |
| Part 1.4 Plugin registry | 目录发现、API 检查和错误隔离 | `client/pipeline/plugin_registry.gd` | registry 与前端发现测试 | README 列出四个 stage | PASS | 完成 |
| Part 1 deliverable | Plugin API document | `docs/plugin-api.md` | `tests/python/test_documentation.py` | 接口签名已对照代码 | PASS | 完成 |
| Part 1 deliverable | Architecture diagram | `docs/architecture.md` | `tests/python/test_documentation.py` | Mermaid 源码可读 | PASS | 完成 |
| Part 1 deliverable | README runbook、版本、命令、评审路径和快捷键 | `README.md` | `tests/python/test_documentation.py` | 已在参考主机复现 | PASS | 完成 |
| Part 1 verification | Zero-error sample validation | 样本生成器和 Model Output V1 验证器 | 种子 6006 生成 120 条记录和 120 帧；验证器状态 0 | 命令输出 `Validation errors: 0` | PASS | 完成 |
| Frontend layout | 左栏只读显示当前已接受数据集，中央保留真实 viewport | `DatasetExplorer`; `WorkspaceSplit`; `AnnotationViewport` | explorer、main boundary、playback 测试 | 单图显示 `Frames (1)`；数据集显示 `Frames (120)` | PASS | 完成 |
| Frontend layout | 右侧可滚动 Inspector 下固定无分类、四列、十二槽工具区 | `InspectorScroll`; `ToolPanel` | frontend structure 与 tool panel 测试 | 1280×800 渲染中十二个图标和名称均可读 | PASS | 完成 |
| Tool inventory | Add Box、Fill、Erase、Selection、Move / Resize 可用；其余七项只显示 `待开发` | `ToolPanel.TOOL_DEFINITIONS`; Edit plugin；不可用信号 | 测试覆盖十二个位置、五条功能路由、七条不可用路由及非变更状态 | 渲染脚本触发 Subtract 后精确显示 `待开发` | PASS | 完成 |
| Navigation safety | Explorer、timeline、previous/next、playback、seek 收敛到同一帧高亮；拒绝导航或替换时保留状态 | `AnnotationMain` 单向同步和失败原子 Source 事务 | playback、main boundary、explorer 测试 | 规范化数据集渲染显示帧与 timeline 对齐 | PASS | 完成 |
| Resize boundary | 两个侧栏可调整，不引入 docking 或文件管理行为 | 嵌套 `WorkspaceSplit` 与 `ContentSplit` | frontend structure 测试 | split offset 250/660 时中央仍可用 | PASS | 完成 |
| Part 1 integration | 数据契约、插件 API、三栏组合和现有编辑行为共同工作 | 完整仓库 | 2026-09-04 合并结果：Godot exit 0 且末行 `PASS`；Python `74 passed`；静态检查通过 | 实际 Godot 4.7.2、X11/GL Compatibility 渲染 | PASS | 完成 |
| Part 2 | Region display、MITK-style editing 设计说明和测量 | 现有 primitive 仅为尚未声明完成的基础 | 未作为完整 Part 2 门禁评估 | 未评估 | BLOCKED | Part 1 后明确批准 |
| Part 3 | Frame-accurate stream 和 batch labelling 工作流 | 超出 Part 1 范围 | 未评估 | 未评估 | BLOCKED | 后续阶段 |
| Part 4 | Autosave、diff、update package 和协作协议 | 超出 Part 1 范围 | 未评估 | 未评估 | BLOCKED | 后续阶段 |
| Part 5 | 完整稳健性、smoke session、测量和失败分析 | 超出 Part 1 范围 | 未评估 | 未评估 | BLOCKED | 后续阶段 |

## 前端验收证据边界

- **真实渲染观察：**1280×800 的单图和规范化数据集会话显示了已接受数据集浏览器、中央视口、可滚动 Inspector、固定十二槽工具区、真实 metadata 列表、分隔条调整，以及脚本触发 Subtract 后的 `待开发`。
- **自动交互证据：**`test_tool_panel.gd` 覆盖五条可用路由和七条不可用路由；`test_playback.gd` 覆盖工具/选择/标注/手势/历史保持、各导航入口同步和失败替换原子性。
- 不声称人工逐个点击了每个预留控件、每条导航路径或无效替换场景；这些行为由上述自动测试证明。
