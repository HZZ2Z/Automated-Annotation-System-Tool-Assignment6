# Part 4 reviewer runbook

所有命令从仓库根目录执行。运行环境沿用 `project_env.sh`，演示不依赖本地 `tests/` 或已有 `sample/`。

## 完整 CLI 闭环

```bash
source project_env.sh
mkdir -p test
touch test/.gdignore
"$PROJECT6_PYTHON" python/part4.py demo --output test/part4-review
```

目标目录必须尚未存在；重跑时选择新名称。该入口生成 120 帧图像及模型输出，通过真实命令修改 12、13、24、36、72、90 帧，验证这些帧，等待自动保存，重开并导出，再导入明确标注为模拟的新模型轮次。`evidence.json` 给出实际文件路径和验证结果。

预期：geometry 2、label 1、added 1、deleted 1、attributes 2；6 个变化帧、7 个变化对象。训练包包含 6 帧，排除 114 帧；评审快照覆盖 120 帧。旧轮次归档，新轮次验证和批量状态为空。演示没有执行训练。

```bash
"$PROJECT6_PYTHON" python/part4.py validate-package PACKAGE_DIRECTORY
"$PROJECT6_PYTHON" python/part4.py export --session ARCHIVED_V3_JSON --output test/part4-repeated --kind training
"$PROJECT6_PYTHON" python/part4.py export --session ACTIVE_V3_JSON --output test/part4-review-export --kind review
"$PROJECT6_PYTHON" python/part4.py import-round --session V3_JSON --input ROUND_MANIFEST --parent-package PACKAGE_DIRECTORY
```

用 `evidence.json` 的 `archive_path` 重复导出，package ID 应与第一轮训练包相同；`active_session` 已是第二轮，尚无已验证帧，直接导出正式训练包应被拒绝。若要重演第二轮导入，先将归档复制到新的会话文件，避免重复导入同一轮次。

包输出到仓库 `output/` 时，后台任务会创建或保留 `output/.gdignore`，防止 Godot 将 CSV 报告当作翻译资源导入。标记位于包外，包内仍严格保留六个文件。其他项目内目标需要已有的普通 `.gdignore` 祖先文件；也可选择项目外目录。现有标记为目录或符号链接时会拒绝输出。原始 PNG 仍通过 Source 读取；仅含 JSON 的标签和轮次归档不受这项包输出限制。

若旧包已被编辑器加入 `.translation` 或 `.import` 文件，保留原目录并从对应归档 V3 导出到新的受保护目标，然后重新校验。不要将含额外文件的旧包当作有效交接包。Godot 的目录排除机制见[官方说明](https://docs.godotengine.org/en/stable/tutorials/best_practices/project_organization.html#ignoring-specific-folders)。

## 4.1 逐条验收（本地测试入口）

```bash
"$PROJECT6_PYTHON" test/part4_1/run_audit.py
```

此入口将新日志、执行副本、合成 Source、导出包和崩溃文件统一写入 `test/part4_1/runs/`，保留所有运行记录。检查每条修正记录的 V1 schema 与 `human_corrected` 来源、定时原子保存、真实窗口关闭信号、保存失败、全帧 JSONL、稀疏帧号及可选时间戳。逐条结论见本地 `test/part4_1/REPORT.md`。该测试入口按现有规则仅在本地保留；上面的生产 CLI 演示不依赖它。

此前主工作区的 Part 4 测试产物已移入 `test/part4/history/output/`；`test/part4/history/path-map.json` 保存原路径、新路径和逐文件摘要。历史 JSON 内的绝对路径保留为原始证据，可用同目录 `resolve_path.py` 解析。所有这些合成数据都明确标记为测试用途，不能直接作为正式训练真值。

## 4.2 逐条验收（本地测试入口）

```bash
"$PROJECT6_PYTHON" test/part4_2/run_audit.py
```

此入口将合成输入、手工预期、执行副本、JSON/CSV 报告及日志写入 `test/part4_2/runs/`，用途标注为 TEST ONLY。检查四项必需事件、按类转入/转出、box/polygon、稀疏帧号、精确数值、CSV 特殊字符、撤销/重做、保存重开和 UI/CLI 内容一致性。逐项结论见本地 `test/part4_2/REPORT.md`。

完整模型对比需有可信模型基线，并选择全帧评审快照；训练包报告仅覆盖已验证帧。包内 `data/corrected_annotations.jsonl` 与 `reports/diff.json`、`reports/diff.csv`、`reports/summary_by_class.csv` 来自同一冻结快照。JSON 列出无变化帧的零计数，CSV 仅列真实事件。旧 Plugin API V1 兼容导出没有完整 diff，4.2 验收使用当前 Part 4 UI 或上面的生产 CLI。

## 4.3 严格验收（本地测试入口）

```bash
"$PROJECT6_PYTHON" test/part4_3/run_audit.py
```

所有新日志、合成包、故障夹具和输入响应测量位于 `test/part4_3/` 的独立运行目录，标注 TEST ONLY。入口根据真实断言返回状态；任一必要检查失败均退出非零。旧失败日志和测试源备份继续保留，报告见本地 `test/part4_3/REPORT.md`。

客户端按钮和 `await Main.export_package(output_parent, kind)` 共用异步控制器；kind 默认训练包，也可选择 `review_export_v1`。参数表示父目录，实际包目录读取结果的 `output_path`。准备时先等待保存；取消后异步排空；后台发布期间可以继续编辑。程序入口更新共享快照时，旧对话框预览失效，需重新打开确认覆盖范围。底层插件 V1 接口保留。

新训练/评审包有严格 UTC 秒格式 `created_at`，旧包缺失时仍可原样验证复用。接收方先升级校验器，兼容规则见协作协议。

大型门禁现已通过：内存优化后，10,000 帧、每帧 20 region 三次完整运行峰值约 1.57 GiB。入口检查至少 4 GiB MemAvailable，并持续限制测试子进程 RSS/HWM 为 3 GiB、保留系统 1 GiB 余量。超限只终止该测试子进程；资源不足、运行时错误、必要指标缺失或有效输入样本不足均返回非零。没有加载全量图像，也不关闭其他程序或清理用户数据。原失败记录继续保留。

## 接口命名、兼容和事务细节

**Directory naming.** Publish as
`training_update_v2_<media_id>_<safe_round_id>_<package_id_first12>/`;
full review uses `review_export_v1_` with the same suffix fields. `safe_round_id`
replaces each character outside `[A-Za-z0-9_.-]` with `_` and keeps the first
80 characters. Read the original round ID and full 64-character package ID from
the manifest, rather than trying to split underscore-delimited directory names.
Package schema versions are 2 (training) and 1 (review); annotation schema stays V1.

**Creation-time extension (2026-09-08).** New training and review manifests include
`created_at: "YYYY-MM-DDTHH:MM:SSZ"`, generated once in UTC by the publishing worker.
Both validators require a real Gregorian date, year 0001–9999, and exact seconds;
null, offsets, fractions and leap seconds are rejected. The field is excluded from
the content ID. Legacy packages may omit it (creation time unknown); validated
reuse preserves the original manifest bytes, including a missing timestamp.
接收方须先同步升级 Godot/Python 校验规则，再接收带 `created_at` 的包；旧校验器
会拒绝这一新增字段。此次扩展保持包类型、版本、目录前缀和六文件布局不变。


**Transaction and legacy binding.** Save the old active V3 first. Preparation
validates the candidate without publishing. Commit revalidates unchanged inputs,
archives exact prior V3 bytes as `label/rounds/<sha256>.json`, then atomically
replaces the active V3. Failures preserve old active data; a valid orphan archive
is harmless. New rounds have independent session identity, revision zero, and
empty verification/batch/undo state. Explicit binding of an unknown legacy
baseline retains the explicit correction/review/batch evidence and its explicit
frame set. Implicit display placeholders initialize from the bound raw model and
remain unannotated, rather than becoming negative corrections. Explicit correction
timestamps must retain compatible optional presence. Binding atomically increments
revision; known baselines cannot be rebound.


## Godot 界面

先生成独立的第一轮起点（目标必须不存在）：

```bash
"$PROJECT6_PYTHON" python/part4.py demo --prepare-only --output test/part4-ui-start
"$GODOT_BIN" --path .
```

`--prepare-only` 执行同样的真实编辑、验证、保存、重开和两种导出，停在 round1，生成匹配该训练包的 round2 模拟返回。`evidence.json` 提供 `workspace`、`training_package`、`round_manifest`；`current_round_id` 为 round1，`returned_round_id` 为 round2。普通 demo 已到 round2，不能再次导入它自己的 round2 返回。旧版本生成的摘要不一致 demo 请保留，使用新目录重新生成。

1. Open 打开 `test/part4-ui-start/workspace`，从左栏选择 `demo`。第一次复跑先保持已有标注：Export 选择训练包并导出至 `test/part4-ui-export`，其 package ID 应与 evidence 的 `training_package_id` 一致。
2. 点击顶部轮次按钮，选择 evidence 的 `round_manifest` 和 `training_package`，校验预览后确认导入。应显示 round2、已保存；旧 V3 归档，验证/批量/撤销状态重置。此次返回只对应准备时的父包；若先改动内容并重新验证导出，需要模型组基于新包生成新返回。
3. 在导入后的 round2 上继续下列编辑、保存、验证和导出检查。
4. 修改并提交一个区域。顶部区分“未保存 / 保存中 / 已保存 / 保存失败”；Save 或 Ctrl+S 保存已提交内容。草稿需要明确完成或取消。
5. 在右侧“批量”页确认需要交接的帧。任何后续内容修改都会使相应验证失效。
6. Export 默认选择“训练交接包：仅已验证帧”。检查总数、包含/排除数和差异统计，再选择目标目录。切换到“全帧评审快照”可包含未审核帧及其真实状态。
7. 打包开始后可以继续编辑。再次点击顶部“取消导出”取消尚未发布的包。成功页显示覆盖数、路径以及打开目录/差异报告入口；导出不验证帧，也不清除更新的未保存状态。
8. 对实际后续模型返回，点击顶部轮次按钮，选择返回的轮次清单和对应父训练包目录，先校验预览，再确认导入。输入损坏、覆盖不符或保存失败时保留当前会话。成功后旧 V3 位于相邻 `rounds/<SHA256>.json`。
9. 旧标签显示“基线未绑定”。通过轮次入口明确选择完整原始模型 JSONL 绑定基线；不要将人工修正标签当作模型预测。完整覆盖规则和可选时间必须兼容。
10. 关闭或切换媒体时若仍有未保存内容，分别检查保存并继续、放弃尚未保存部分和取消。已经成功保存的版本不会被“放弃”回滚。

## 本地故障与响应检查

本仓库按现有规则忽略 `tests/` 与运行输出。本地测试保留；共享仓库的可运行交付入口是上面的生产 CLI。

```bash
"$PROJECT6_PYTHON" tests/run_part4.py
"$GODOT_BIN" --headless --path . --script tests/godot/test_runner.gd
"$GODOT_BIN" --headless --path . --script tests/godot/test_part4_lifecycle.gd
"$GODOT_BIN" --headless --path . --script tests/godot/test_part4_export_ui.gd
"$GODOT_BIN" --headless --path . --script tests/godot/test_part4_round_ui.gd
PYTHONPATH="$PWD/python" "$PROJECT6_PYTHON" tests/benchmarks/part4_crash.py
"$GODOT_BIN" --headless --path . --script tests/godot/benchmark_part4_io.gd -- 120 15
"$PROJECT6_PYTHON" tests/benchmarks/part4_large.py
```

崩溃测试只终止自己创建的写入子进程，并保留测试文件。它检查临时写入、写后校验、替换前和替换后四个阶段。保证范围是本地文件系统上的进程崩溃与最近一次成功保存，不包括断电恢复或多用户并发写入。

响应测量由独立线程每 10 ms 发出请求，再由 SceneTree 派发 InputEventKey，计入主线程排队延迟；记录快照、自动保存、差异和导出耗时。大样本测量不加载图像。真实界面截图和交互回归作为独立证据；它不是人工用户研究。

历史参考（4.3 本次修复之前，不能作为当前验收）：120 帧自动保存 p95 0.868 秒；10,000 帧保存/导出输入响应 p95 15.2/13.4 ms，峰值内存约 4.85 GiB。最新标准样本 20 次编辑保存 p95 约 0.80 秒；10,000 × 20 保存/导出输入 p95 约 13.4 ms。大样本保存约 40 秒，个别事件尾延迟仍超过 100 ms；复杂多边形压力夹具的保存耗时另列，不套用标准 box 样本的 1 秒目标。当前证据以 `test/part4_3/REPORT.md` 为准。300 ms 防抖和 2 秒请求期限均不保证大文件会在 2 秒内写完。
