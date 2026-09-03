# 要求追踪表

本台账将老师要求与实现证据分开。`PASS` 表示已实际运行直接自动化证据；`BLOCKED` 表示必需环境或手工验收门禁尚未完成。Part 1 不声明后续 Part 功能已完成。

| 要求来源 | 要求 | 实现 | 自动化证据 | 人工证据 | 状态 | 后续任务 |
|---|---|---|---|---|---|---|
| Part 1.1 Data contract | 版本化的逐图模型输出 Schema，包含 source/frame、可选 time_s 和 regions | `core/schemas/model_output_v1.schema.json` | `tests/python/test_part1_1_data_contract.py`; `tests/godot/test_model_output_validator.gd` | 已对照 Assignment 示例逐字段核验 | PASS | 完成 |
| Part 1.1 | Python validator | `python/validate_model_output.py`; `python/annotool/contracts.py` | `tests/python/test_part1_1_data_contract.py` | README 中包含独立 CLI | PASS | 完成 |
| Part 1.1 | 具有字段路径错误且不使界面崩溃的 Godot validator | `client/domain/model_output_validator.gd` | `tests/godot/test_model_output_validator.gd`; Source/Store 测试 | 客户端通过错误数组保留可恢复状态 | PASS | 完成 |
| Part 1.1 | Contract version 1 和不可变 `model_output_vX` 基线 | `model_output_v1.jsonl`; `AnnotationStore` 分别保存模型基线和修正副本 | `test_part1_1_data_contract.py` 的 SHA-256 测试；`test_annotation_store.gd` 摘要测试 | 架构文档所有权部分 | PASS | 完成 |
| Part 1.2 Reproducible sample | 固定种子的合成图像序列和匹配标注 | `python/make_sample_input.py`; `python/annotool/sample.py` | `tests/python/test_sample.py::test_sample_is_deterministic` | 已记录评审命令 | PASS | 完成 |
| Part 1.2 defects | Drifted regions（漂移区域） | 种子 6006 的第 12、13 帧 | `test_sample_contains_required_defects` | 生成后的 `expected_defects.json` | PASS | 完成 |
| Part 1.2 defects | Wrong class labels（错误类别） | 种子 6006 的第 24 帧 | `test_sample_contains_required_defects` | 生成后的 `expected_defects.json` | PASS | 完成 |
| Part 1.2 defects | Missed region（漏检区域） | 植入样本缺陷 | `test_sample_contains_required_defects` | 生成后的 `expected_defects.json` | PASS | 完成 |
| Part 1.2 defects | Hallucinated region（幻觉区域） | 植入样本缺陷 | `test_sample_contains_required_defects` | 生成后的 `expected_defects.json` | PASS | 完成 |
| Part 1.2 defects | Track-id swap（追踪 ID 交换） | 植入样本缺陷 | `test_sample_contains_required_defects` | 生成后的 `expected_defects.json` | PASS | 完成 |
| Part 1.2 sequence | Near-identical frames（近似相同帧） | 固定 40–59 帧段和 similarity scores | `test_similar_run_is_near_identical_with_distinguishable_boundaries` | Timeline 评审留待后续 batch 工作 | PASS | 完成 |
| Part 1.3 Frame source | 将任意 FFmpeg 可读视频解码为索引帧 | `python/frame_source.py`; `python/annotool/frame_source.py` | 2026-09-04 完整 Python 门禁：74 passed、0 skipped，FFmpeg/FFprobe 6.1.2 | 集成测试已解码三帧和多流无损视频 | PASS | 完成 |
| Part 1.3 | 将视频、序列和 standalone image 统一为索引帧 | `image_sequence_source`; `single_image_source`; manifest contract | `test_source_plugin.gd`; `test_single_image_source.gd`; `test_playback.gd` | 1280x800 验收已依次打开单张 PNG 和归一化 120 帧目录 | PASS | 完成 |
| Part 1.4 Source stage | 可用的归一化目录和单图插件 | `client/plugins/source` | Source 和单图插件测试 | 两条 Source 路由均在验收客户端成功显示 | PASS | 完成 |
| Part 1.4 Render stage | 可替换的工作 Renderer | `canvas_region_renderer` | `test_renderer.gd`;视口集成测试 | 已渲染样本区域、label、confidence 和选中轮廓 | PASS | 完成 |
| Part 1.4 Edit tools stage | 明确的 Edit plugin 边界 | `basic_edit_tools` | command、keyboard、ToolPanel 和集成测试 | 五个工具均已激活；Select 已可见填充 Inspector | PASS | 完成 |
| Part 1.4 Export / Feedback stage | 已验证 corrected JSONL 插件 | `file_training_handoff` | `test_feedback_plugin.gd` | Part 1 boundary 中 UI Export 保持禁用 | PASS | Task 12 后续集成完整 UI package |
| Part 1.4 Plugin registry | 目录发现、API 检查和错误隔离 | `client/pipeline/plugin_registry.gd` | `test_plugin_registry.gd`;前端发现测试 | README 已列出四个 stage | PASS | 完成 |
| Part 1 deliverable | Plugin API document | `docs/plugin-api.md` | `tests/python/test_documentation.py` | 接口签名已对照代码评审 | PASS | 完成 |
| Part 1 deliverable | Architecture diagram | `docs/architecture.md` | `tests/python/test_documentation.py` | Mermaid 源码对评审者可读 | PASS | 完成 |
| Part 1 deliverable | README runbook、版本、命令、评审路径和快捷键 | `README.md` | `tests/python/test_documentation.py` | 已在参考主机复现文档中的样本、验证、测试和打开路径 | PASS | 完成 |
| Part 1 verification | Zero-error sample validation | 样本生成器和独立 Model Output V1 验证器 | 种子 6006 已生成 120 条记录和 120 帧；`model_output_v1.jsonl` 以状态 0 通过 | 两个命令均输出 `Validation errors: 0` | PASS | 完成 |
| Part 2 | Region display、MITK-style editing 验收、设计说明和测量 | 现有 primitive 只是尚未声明完成的集成骨架 | 未作为完整 Part 2 门禁评估 | 未评估 | BLOCKED | Part 1 后明确批准 |
| Part 3 | Frame-accurate stream 和 batch labelling 工作流 | 超出 Part 1 范围 | 未评估 | 未评估 | BLOCKED | Task 10 |
| Part 4 | Autosave、diff、update package 和协作协议 | 超出 Part 1 范围 | 未评估 | 未评估 | BLOCKED | Tasks 11–12 |
| Part 5 | 完整稳健性、smoke session、测量和失败分析 | 超出 Part 1 范围 | 未评估 | 未评估 | BLOCKED | Tasks 13–14 |
