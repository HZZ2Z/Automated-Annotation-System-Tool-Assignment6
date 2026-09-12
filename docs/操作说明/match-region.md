# Match 区域匹配工具与验收

实现日期：2026-09-09。Match 为四列工具栏的第八个按钮。先点 A，再点 B；A 用橙色标记，悬停 B 用青色标记并显示 class / kind。完成后保留工具，进入下一轮。只处理当前帧已有的 box / polygon。

## 规则与职责

- 合法单环并集：A 并入 B，删除 A；保留 B 的 id、class、kind、conf、track_id。合并结果使用 polygon，移除可能失真的旧 box。
- 间隙不超过 1 个图像像素：最近边界点间生成宽 1 像素的局部圆头连接带，裁剪到图像范围后求并集。只检查新增部分是否侵入第三个区域；不改动无关区域。
- 距离过大、孔洞、自交、仅角点接触等无法形成合法单环，或第三个区域阻挡：只同步 A.class / kind，并显示未合并原因；A 的其余字段和 B 均保持原样。
- 同标签仍进行合并判断。真正无变化的命令不增加历史，也不清空 redo。
- 空白或重复点击 A 不提交；按实际面积从小到大命中，同面积优先最后绘制的区域。
- Esc 清除待选 A 并保持 Match；右键遵循现有取消流程返回 Select。换帧、换工具、切换源、撤销/重做、记录变化均清除两次点击状态。

`region_match_controller.gd` 管理临时交互、命中缓存和快照核对；`RegionMatchSolver` 负责纯几何/标签计算；`MatchRegionCommand` 保存整帧前后快照，原子提交和撤销。Main 比较鼠标按键事件前后的 Store revision，统一刷新区域列表、画布和保存状态，并保留具体结果提示。EditOverlay 绘制双高亮并避让标签；离开图像时仅清除候选 B。Model Output V1 与必需 EditStage 接口保持兼容。

## 自动化验收

| 要求 | 直接证据 | 结果 |
| --- | --- | --- |
| 第八个按钮、四列工具栏、注册与鼠标路由 | `test_tool_panel.gd`、`test_advanced_edit_tools.gd`、`test_main_boundaries.gd` | 通过 |
| 两次点击、连续修正、空白/重复 A、真实面积和同面积顺序 | `test_region_match_ui.gd` 的 cycle / smallest_hit | 通过 |
| A/B 高亮、class/kind 提示、鼠标离开清除 B | 同上；离开视口/图像边缘回归；X11 窗口截图 | 通过 |
| 共边、重叠、包含、绕向、polygon 优先于旧 box | `test_region_match.gd` 的 exact_merges | 通过 |
| 0.5 / 1.0 / 1.01 px、欧氏距离、局部连接带及图像边界 | domain gap_limit_and_locality；UI gap_under_transforms | 通过 |
| 缩放和平移不改变输出 | UI 对不同变换下的完整结果逐项比较 | 通过 |
| 孔洞、非法轮廓、角点接触、第三个区域阻挡回退 | domain fallbacks_preserve_geometry；比较完整标签同步结果和原因 | 通过 |
| 字段保留、区域数减一、整帧撤销/重做、无变化历史 | domain atomic_history_and_export / noop_and_stale_commands；UI cycle | 通过 |
| 拖动不误选、Esc/右键、切工具、换帧、空历史撤销、记录变化、切换数据源 | UI cancellation_and_staleness；真实 Main 挂载 | 通过 |
| 保存、重开及实际导出文件一致 | UI persistence；Endoscapes X11 验收；Godot + Python 包校验 | 通过 |
| 完整回归 | `bash tests/run_tests.sh`：399 Python tests passed；Godot 完整套件与全部专用脚本退出 0 | 通过 |

完整回归日志保存在 `tmp/match-acceptance/full-suite.log`；补充数据源切换测试日志为 `final-ui.log`。独立只读审查发现的候选高亮残留、A/B 文字重叠均已修正，并完成回归/渲染检查。测试中的损坏图片与受限网络诊断属于故意构造的现有路径，完整运行退出码为 0。

## Endoscapes 实际窗口验收

使用本地 Endoscapes 数据：`<ENDOSCAPES_ROOT>/test_seg/165_23650.jpg` 和同目录 `annotation_coco.json`。验收副本保存在 `tmp/match-acceptance/endoscapes/`，原始数据未修改。

这份数据是 **真实图像与 COCO 标注，不是模型预测**。参考胆囊区域从 RLE 解码，按 0.75 px 近似为 102 顶点单环；其他区域保留原 COCO 框。副本中人为加入一个 8×8、误标为 cystic_duct 的小区域，明确标识为 `injected-defect`。因此本次证据属于真实图像上的受控瑕疵验收，不能代替真实模型预测错误的自然样本评估。

X11 / Godot 4.7.2 / OpenGL compatibility / llvmpipe 窗口中，自动输入实际经过工具栏和画布：点击小块 A，再点胆囊 B，记录数 **6 → 5**，一次撤销 **5 → 6**，重做恢复 **5**。保存重开与导出 `data/corrected_annotations.jsonl` 中的全部区域一致；导出 source 按现有协议标为 `human_corrected`。Godot 导出校验和独立 Python `validate_training_package()` 均通过。

- [修正前截图](../tmp/match-acceptance/Endoscapes_Before.png)
- [修正后截图](../tmp/match-acceptance/Endoscapes_After.png)
- [相邻标签避让截图（合成高亮，不写入记录）](../tmp/match-acceptance/Label_Collision_Check.png)
- [机器验收结果](../tmp/match-acceptance/endoscapes-result.json)
- [数据来源与注入说明](../tmp/match-acceptance/endoscapes/provenance.json)

一次窗口点击提交耗时见结果 JSON，仅代表这一张图和本机环境，不是通用性能保证。尚未做真实模型预测错误的批量效果评估，也未测量人工操作耗时。

## 复跑

```bash
source project_env.sh
bash tests/run_tests.sh
# 按本机下载目录重新生成独立验收副本：
"$PROJECT6_PYTHON" tmp/match-acceptance/prepare_endoscapes.py
# 本机图形会话中自动截图、撤销重做、保存重开和导出：
"$GODOT_BIN" --display-driver x11 --rendering-method gl_compatibility \
  --path . --script tmp/match-acceptance/check_endoscapes.gd
```

验收副本、图片、导出与脚本属于本地验收产物。仓库现有规则忽略 `tests/` 和数据输出目录；本次未更改这些规则，也未进行 Git 提交。
