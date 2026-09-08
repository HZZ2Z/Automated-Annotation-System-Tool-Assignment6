# Part 4 reviewer runbook

所有命令从仓库根目录执行。运行环境沿用 `project_env.sh`，演示不依赖本地 `tests/` 或已有 `sample/`。

## 完整 CLI 闭环

```bash
source project_env.sh
"$PROJECT6_PYTHON" python/part4.py demo --output output/part4-review
```

目标目录必须尚未存在；重跑时选择新名称。该入口生成 120 帧图像及模型输出，通过真实命令修改 12、13、24、36、72、90 帧，验证这些帧，等待自动保存，重开并导出，再导入明确标注为模拟的新模型轮次。`evidence.json` 给出实际文件路径和验证结果。

预期：geometry 2、label 1、added 1、deleted 1、attributes 2；6 个变化帧、7 个变化对象。训练包包含 6 帧，排除 114 帧；评审快照覆盖 120 帧。旧轮次归档，新轮次验证和批量状态为空。演示没有执行训练。

```bash
"$PROJECT6_PYTHON" python/part4.py validate-package PACKAGE_DIRECTORY
"$PROJECT6_PYTHON" python/part4.py export --session ARCHIVED_V3_JSON --output output/repeated --kind training
"$PROJECT6_PYTHON" python/part4.py export --session ACTIVE_V3_JSON --output output/review --kind review
"$PROJECT6_PYTHON" python/part4.py import-round --session V3_JSON --input ROUND_MANIFEST --parent-package PACKAGE_DIRECTORY
```

用 `evidence.json` 的 `archive_path` 重复导出，package ID 应与第一轮训练包相同；`active_session` 已是第二轮，尚无已验证帧，直接导出正式训练包应被拒绝。若要重演第二轮导入，先将归档复制到新的会话文件，避免重复导入同一轮次。

包输出到仓库 `output/` 时，后台任务会创建或保留 `output/.gdignore`，防止 Godot 将 CSV 报告当作翻译资源导入。标记位于包外，包内仍严格保留六个文件。其他项目内目标需要已有的普通 `.gdignore` 祖先文件；也可选择项目外目录。现有标记为目录或符号链接时会拒绝输出。原始 PNG 仍通过 Source 读取；仅含 JSON 的标签和轮次归档不受这项包输出限制。

若旧包已被编辑器加入 `.translation` 或 `.import` 文件，保留原目录并从对应归档 V3 导出到新的受保护目标，然后重新校验。不要将含额外文件的旧包当作有效交接包。Godot 的目录排除机制见[官方说明](https://docs.godotengine.org/en/stable/tutorials/best_practices/project_organization.html#ignoring-specific-folders)。

## Godot 界面

1. 执行 `"$GODOT_BIN" --path .`。Open 打开演示输出中的 `workspace`，从左栏选择 `demo`。直接打开 Source 也会获得确定的用户会话目录。
2. 修改并提交一个区域。顶部区分“未保存 / 保存中 / 已保存 / 保存失败”；Save 或 Ctrl+S 保存已提交内容。草稿需要明确完成或取消。
3. 在右侧“批量”页确认需要交接的帧。任何后续内容修改都会使相应验证失效。
4. Export 默认选择“训练交接包：仅已验证帧”。检查总数、包含/排除数和差异统计，再选择目标目录。切换到“全帧评审快照”可包含未审核帧及其真实状态。
5. 打包开始后可以继续编辑。再次点击顶部“取消导出”取消尚未发布的包。成功页显示覆盖数、路径以及打开目录/差异报告入口；导出不验证帧，也不清除更新的未保存状态。
6. 点击顶部轮次按钮，选择返回的轮次清单和对应父训练包目录，先校验预览，再确认导入。输入损坏、覆盖不符或保存失败时保留当前会话。成功后旧 V3 位于相邻 `rounds/<SHA256>.json`。
7. 旧标签显示“基线未绑定”。通过轮次入口明确选择完整原始模型 JSONL 绑定基线；不要将人工修正标签当作模型预测。完整覆盖规则和可选时间必须兼容。
8. 关闭或切换媒体时若仍有未保存内容，分别检查保存并继续、放弃尚未保存部分和取消。已经成功保存的版本不会被“放弃”回滚。

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

本机参考结果见根目录 `RESULTS.md`：120 帧自动保存 p95 0.868 秒；10,000 帧保存/导出输入响应 p95 15.2/13.4 ms。大样本保存及导出各需约 49 秒，峰值内存约 4.85 GiB，并有超过 100 ms 的尾延迟。300 ms 防抖和 2 秒请求期限均不保证大文件会在 2 秒内写完。
