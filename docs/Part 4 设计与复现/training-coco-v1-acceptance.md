# `training_coco_v1` 实现与验收

本文记录 2026-09-12 的实现边界和新鲜验收。新路径是 Endoscapes Source 的可选、自包含 COCO 训练交接包；旧 `training_update_v2`、`review_export_v1`、自动保存和 `model_round_v1` 交易语义保留。本次没有运行训练、生成权重或进行人工用户研究。

## 包契约

目录名为 `training_coco_v1_<media_id>_<round_id>_<package_id前12位>/`，包内只允许：

```text
manifest.json
images/<source-file-name>
labels/annotation_coco.json
reports/diff.json
```

`manifest.json` 的权威 schema 是 `core/feedback/training-coco-v1.schema.json`。主要字段如下：

- `package_type=training_coco_v1`、`task=detection|instance_segmentation`、`annotation_format=coco_instances`；
- `dataset.source_split` 保留 `train|val|test`，不把非训练 split 伪装为 train；
- `coverage` 默认为 `all_source_frames`，记录全部、已核验、纳入和排除的原始帧号；显式子集使用 `selected_source_frames`；
- `samples` 分开 `source_frame_id`、播放下标和 `dataset_sequence_index`，并通过 `review_status` / `label_source` 记录当前审核和标注来源；
- `annotation_links` 记录原生/生成对象 ID、geometry/area 来源和绑定方式；
- `provenance.source_files` 记录三个来源 JSON 的大小与 SHA-256；
- `artifacts` 列出每张图片、COCO 和 diff 的大小与 SHA-256；
- `package_id` 由内容决定，不包含时间、输出路径或请求 revision。

COCO 的 `images` / `annotations` / `categories` 是唯一训练标签入口。留空帧范围时，每个 Source 帧都进入包，不会因未审核、沿用上版标注或当前没有标注而消失。物化顺序是：当前修正、不可变的 imported/model 基线、空记录。空记录保留 `image` 且没有 `annotation`，在 COCO loader 中就是零目标负样本；导出器不会猜测“真无目标”还是“尚未标注”，而是用 `label_source=no_annotation` 和 `review_status=unverified` 保留这个风险。

导出保留原生类别顺序和 ID；编辑器中新输入的自由文本类别按名称排序，在最大原生 ID 后确定性追加，并以 `kind` 作为 `supercategory`；同名类别如被用于冲突的 `kind` 则显式阻断。导出包含所有纳入原图的原始字节，不重编码、不烧录覆盖层。每帧的所有最终对象都进入标签，不是只导出 diff 对象。

## UI 与 CLI 语义

Endoscapes Source 声明 `export.training_coco_v1` 能力后，Export 对话框默认选新格式；不声明该能力的普通 Source 仍只显示原有两种格式。帧范围留空表示全部 Source 帧；显式输入帧号才表示子集。UI 预览分别列出纳入、当前已审核、沿用旧版/未审核和零目标数量，确认文案明示零目标 COCO 语义。预览和发布只消费已保存、已冻结的 V3 会话；它们不会创建审核记录。用户必须单独确认范围语义，预览后编辑或换媒体会返回 `STALE_CONTEXT`。

检测允许当前有效 box，并显式记录 bbox area fallback。实例分割要求每个目标都有当前可信 mask；仅有 box、旧 mask 已因几何编辑失效、导入器跳过对象或未显式声明看过 mask 时都阻断，不降级成检测包。

```bash
source project_env.sh
"$PROJECT6_PYTHON" python/part4.py export \
  --session "/absolute/path/label/media.json" \
  --source-root "/absolute/path/endoscapes" \
  --output "/absolute/path/output-parent" \
  --kind training_coco_v1 --task detection

"$PROJECT6_PYTHON" python/part4.py validate-package PACKAGE_DIRECTORY
(cd /tmp && "/absolute/path/.venv/bin/python" \
  "/absolute/path/python/coco_package_smoke.py" PACKAGE_DIRECTORY)
```

不写 `--frame` 即为全部 Source 帧；如需子集，可重复添加 `--frame 6575 --frame 7325`。

`validate-package` 独立回读 schema、目录白名单、大小、hash、COCO 关联、图像尺寸、覆盖范围和 diff。`coco_package_smoke.py` 可从任意工作目录打开移动后的包，枚举所有图像/类别/对象并解码所有 polygon/RLE。

## E01–E48 验收矩阵

下表的 `PASS` 表示本轮实际执行的自动断言通过；不表示实际训练或人工效率评估。文件名均相对仓库根目录。

| ID | 状态 | 直接证据 |
|---|---|---|
| E01 | PASS | `test_e01_e03_e04_e05_all_source_frames_keep_review_provenance` 默认按 Source 顺序投影当前视频的全部帧 |
| E02 | PASS | `test_e02_full_final_frame_not_only_changed_object` 断言同帧全部最终对象 |
| E03 | PASS | E01/E03/E04/E05 组合用例纳入已审核且未修改帧，并保留 `verified_current` |
| E04 | PASS | 同一用例也纳入未审核帧，并保留 `unverified` 与 `UNVERIFIED_FRAMES_INCLUDED` |
| E05 | PASS | 同一用例保留零目标帧 image，annotation 为零 |
| E06 | PASS | `test_e06_e07_stale_review_is_included_but_not_reapproved` 断言修改后 review digest 失效，帧仍纳入但标为未审核 |
| E07 | PASS | 同一用例断言全帧导出不会伪造审核状态；旧 `training_update_v2` 的 `verified_only` 拒绝逻辑未改 |
| E08 | PASS | `tests/godot/test_coco_export_controller.gd` 和 `test_coco_export_ui.gd`；范围确认不改 review state |
| E09 | PASS | `test_e09_e10_source_frame_and_dataset_sequence_index_are_distinct` 对齐三份原生视图 |
| E10 | PASS | 同一用例保留稀疏原始帧号和原 image ID |
| E11 | PASS | `test_e11_source_and_dataset_order_remain_independent` 分离 Source 顺序和 dataset index |
| E12 | PASS | `test_e12_conflicting_source_views_never_use_last_writer` 返回 `CONFLICTING_SOURCE_METADATA` |
| E13 | PASS | `test_e13_e14_e16_e18_native_and_generated_ids_are_stable` 保留未改原生 ID |
| E14 | PASS | 同一用例断言生成 ID 不随列表位置/范围漂移 |
| E15 | PASS | `test_e15_generated_id_collision_is_an_error` |
| E16 | PASS | E13/E14/E16/E18 组合用例断言完整类别表不重排 |
| E17 | PASS | `test_e17_free_text_category_is_appended_without_renumbering_native_table`；另覆盖范围稳定 ID 与同名冲突 `kind` 拒绝 |
| E18 | PASS | E13/E14/E16/E18 组合用例保留原生 `supercategory` |
| E19 | PASS | `test_e19_e20_native_rle_with_hole_and_boundary_is_preserved` 保留原 RLE 且解码面积一致 |
| E20 | PASS | 同一用例保留孔洞/触边 mask，不裁成最大轮廓 |
| E21 | PASS | `test_e21_label_only_change_preserves_native_mask` |
| E22 | PASS | `test_e22_box_edit_never_reuses_stale_native_mask` |
| E23 | PASS | `test_e23_polygon_without_box_produces_coco_geometry` |
| E24 | PASS | `test_e24_mixed_mask_and_box_only_frame_blocks_segmentation` |
| E25 | PASS | `test_e25_unmodified_native_area_is_not_replaced_by_bbox_area` |
| E26 | PASS | `test_e26_rle_dimensions_are_not_swapped_to_fit_image` |
| E27 | PASS | `test_e27_missing_or_corrupt_image_does_not_publish` 及同名不同 ID 用例 |
| E28 | PASS | `test_e28_e40_package_is_minimal_byte_exact_and_movable` 对照原/复制 JPG SHA |
| E29 | PASS | `test_e29_unicode_paths_work_but_source_and_package_links_do_not` 及 `test_e29_descriptor_paths_are_bound_to_the_declared_split` |
| E30 | PASS | `tests/godot/test_coco_export_controller.gd` 预览后编辑返回 `STALE_CONTEXT` |
| E31 | PASS | 同一 controller 用例断言包含冻结几何，后续 dirty 编辑留在 Store |
| E32 | PASS | `test_e32_source_change_after_prepare_never_mixes_versions` 及显式 dataset-root 元数据复查 |
| E33 | PASS | `test_coco_package_v1.py` 的 insufficient-space/write/permission 三个用例及 Godot save refusal |
| E34 | PASS | 复制中取消与独立校验中取消两用例，只清自有 staging |
| E35 | PASS | `test_e35_cancel_observed_after_atomic_publish_never_deletes_package` 及 `test_coco_export_service.gd` |
| E36 | PASS | 重复导出的 content ID/COCO bytes 与完整校验后复用用例 |
| E37 | PASS | 目标冲突用例与两个真实并发 publisher 用例 |
| E38 | PASS | `test_e38_independent_validator_rejects_tampering_and_foreign_files` 覆盖图片/COCO/diff/额外文件 |
| E39 | PASS | 非法 COCO 数值、bool ID、Unicode + CRLF 转规范 UTF-8/LF 用例 |
| E40 | PASS | `tests/python/test_coco_package_loader.py`；移动包、删除合成 Source 后 API/CLI 均回读 |
| E41 | PASS | `tests/python/test_part4_cli.py::test_e41_ui_worker_and_cli_have_identical_coco_semantics` |
| E42 | PASS | 旧包/CLI 聚焦回归 47/47；旧六文件清单未改 |
| E43 | PASS | `tests/python/test_coco_round_integration.py` 9/9；新父包全校验后再校验媒体/基线/轮次/覆盖 |
| E44 | PASS | 同一集成组断言失败会话字节不变，成功才归档并清空新轮状态 |
| E45 | PASS | 能力驱动 UI 用例、旧 export UI 用例与当前 Python 全量回归（见下方新鲜证据） |
| E46 | PASS | `output/coco-export-acceptance-20260912/performance-120.json` 与 `performance-10000.json` |
| E47 | PASS | `test_e47_non_train_split_is_preserved_with_a_usage_warning` |
| E48 | PASS | `test_e48_native_object_missing_from_imported_baseline_blocks_frame` |

## 新鲜运行证据

- Python COCO + V3 聚焦：104/104；包含全帧物化、上版基线、未审核子集、零目标、warning 一致性和独立校验器篡改拒绝。
- 权威 `tests/run_tests.sh` 当前回归：889 项 Python 全部通过（56.60 s）；脚本中 28 次 Godot 调用全部退出 0 并通过严格日志审计。先前 28/30 的 Part 4 快照和 Model Assist/SAM 退出错误仅保留为历史失败证据，不再代表当前 checkout。
- 打开回归：合成包覆盖 SourceFactory 路由、完整校验、RLE 安全回退、取消、篡改拒绝、可编辑会话与包外保存；挂载 Main 通过上级目录列出并打开包，新会话 `review_state` 为空。两个真实包实测分别为 94 帧/94 regions/0 负帧与 153 帧/104 regions/49 负帧，均由 `training_coco_package_source` 路由，包内文件未改写。
- 120 帧：UI dispatch p95 8.982 ms，cancel p95 294.905 ms，峰值 RSS 59.707 MiB，最大同时解码 1 张。
- 10,000 帧：UI dispatch p95 97.973 ms，cancel p95 264.781 ms，峰值 RSS 141.285 MiB，最大同时解码 1 张；prepare 4.170 s，publish 25.149 s，独立 loader 2.401 s。磁盘耗时是本机实测，不设脱离硬件的通用秒数门槛。

## 真实与合成包

当前用户会话 `endoscapes_train_video_001.json` 在 revision 59 的只读预检（未生成包、未修改标注）：检测任务成功覆盖 153/153 Source 帧，排除 0 帧，共 115 个对象、47 个零目标帧和 10 个类别；94 帧的当前审核有效，59 帧显式标为未审核。同一冻结快照的实例分割预检在原始帧 32350 和 33100 上共有 11 个对象缺少当前有效 mask，因此正确返回 `SEGMENTATION_REQUIRED`。

真实 Endoscapes 检测包：

`output/coco-real-acceptance-20260912/training_coco_v1_endoscapes_test_video_162_initial_fa27f2cd66e5`

- package ID：`fa27f2cd66e5eeb765d4ca35bf329f141fa06b494adaf53c3781b5f8ea7f7f2e`；
- 原始 `test` split，4 张字节级复制 JPEG，24 个检测标注，6 个完整类别；
- 独立 validator 和移动式 loader 通过；
- `visual-checks/four-frame-contact-sheet.png` 已实际打开检查，四帧腔镜图像可读，box/标签与图像对齐合理。这是工程视觉抽查，不是医学真值认证。

对同一真实会话请求 `instance_segmentation` 时，24 个 bbox-only 对象均返回 `SEGMENTATION_REQUIRED`，退出 1，没有发布包。因此本轮是“合成 mask 契约/端到端测试 PASS，真实检测包 PASS，真实实例分割数据不足并正确阻断”。

以下最小合成示例是改为默认全帧之前生成的历史显式子集包：

`output/coco-synthetic-example-20260912/training_coco_v1_endoscapes_train_video_001_benchmark-round_53a50fccee53`

它包含 2 张已核验负样本和 6 个类别，package ID 为 `53a50fccee532c4aa8c8fd528e7633c54b64cb86448c5cfe02e3d8b2bb469375`；在 `/tmp` 工作目录中执行独立 loader 已通过。

## 文件边界与回退

新增主要是适配层：Python 的投影/写包/独立校验/回读模块，Godot 的子进程 service 和新父包 validator，以及两份严格 schema。现有 Feedback V2 实现没有重写；`TrainingExportController`、Export 对话框、Endoscapes Source 和 `ModelRoundController` 只增加能力分发。

如需回退，仅撤回本文“文件变更表”对应的新格式文件和各个文件中的 `training_coco_v1` 分支；保留旧 Feedback 插件、旧 schema、V3 会话和所有原数据。不需要删除原始 Endoscapes、重置 Git 或清理本地历史。

| 边界 | 文件 |
|---|---|
| 合同 | `core/feedback/training-coco-v1.schema.json`、`coco-export-context-v1.schema.json`、`python/annotation_data/contracts.py` |
| 纯投影/发布/校验/消费 | `python/annotation_data/coco_export.py`、`coco_package.py`、`coco_package_validator.py`、`coco_package_loader.py` |
| 进程入口 | `python/coco_export.py`、`python/coco_package_smoke.py`、`python/part4.py` |
| Source 元数据 | `client/plugins/source/endoscapes_video_source/{endoscapes_coco_adapter,endoscapes_dataset,plugin}.gd`、`plugin.json` |
| UI/控制/回灌 | `client/services/{coco_export_service,coco_parent_validator,training_export_controller}.gd`、`client/ui/training_export_dialog.gd`、`client/workspace/model_round_controller.gd` |
| 测试/性能 | `tests/python/test_coco_*.py`、`tests/godot/test_coco_*.gd`、`tests/benchmarks/coco_export_benchmark.py` |
