# Part 4 持久化与交接内存设计

范围为 Part 4.1–4.3 共用的数据路径。文件契约、内容身份、原子发布及完整回读校验保持不变；不包含训练、图片复制、流式 JSON 解析器、WAL 或增量存储格式。

## 所有权与内存边界

- AnnotationStore 对模型基线和已提交帧递归冻结。未修改帧可共享同一份不可变数据；修改时替换该帧。外部可变容器必须隔离，单独冻结外层不能作为共享依据。
- ReviewSessionCodec 将内部 source 投影为 human_corrected，去掉显示字段 filled。投影只复制必要容器。纯校验按帧检查与索引，不创建临时 AnnotationStore；新会话及 V3 重开只创建一份实际 Store。
- 基线摘要按原始帧号排序引用，逐帧规范化并增量计算 SHA-256。历史精度摘要和当前全精度摘要的字节规则不变。
- StreamJson 以 64 KiB 缓冲向同目录临时文件输出紧凑、排序、全精度 JSON。原子写入仍完整回读，检查语义、与冻结输入等价、摘要及磁盘版本后替换；失败保留旧文件，清理本任务的临时文件。
- PackageArtifactStream 逐帧或逐事件生成五项 artifact。先计算摘要以确定 package ID、检查已有包，再逐项写入新包；第二遍摘要必须与第一遍相同。两遍计算减少驻留数据，保留重复交接先验证并复用已有包的行为。
- 后台任务只读冻结数据。保存 revision、会话检查、取消、外部修改冲突和发布后取消规则沿用原实现。

64 KiB 是输出缓冲上限，不是整个进程或单帧的内存上限。Store、冻结快照、diff 事件和严格回读的解析对象仍占用内存；单个巨大字符串或多边形也会产生单帧编码数据。总内存仍随帧数、region 数和几何复杂度增长。当前方案减少重复数据，不能把任意数据量变为常量内存。

## 算法优化与降低上限的区别

| 处理 | 改变数据算法 | 可完成同一输入 | 用途 |
|---|---|---|---|
| 只把子进程上限降低到 3 GiB | 否 | 原算法超过上限时会更早终止 | 防止测试挤占桌面资源 |
| 共享不可变帧、纯校验、逐帧摘要及分块输出 | 是 | 由完整运行和内容一致性验证 | 降低实际峰值及重复计算 |
| 优化后仍保留 3 GiB 上限和 1 GiB 系统余量 | 是 | 完整运行才算通过 | 同时检查正确性与资源预算 |

测试启动前要求至少 4 GiB MemAvailable。监视器记录子进程 VmRSS/VmHWM、系统余量、阶段耗时和输入响应；资源不足、超时或指标缺失均返回非零，未测指标保留 null。保护器只终止自己启动的测试子进程，不关闭用户程序或清理数据。

## 验证与复跑

所有合成输入、报告、故障注入和性能输出均位于本地 `test/part4_3/memory/`，显式标记 TEST ONLY。同输入比较五项 artifact 字节和 package ID；manifest 仅允许创建时间不同。错误注入包括首次大块写入失败、取消和不合法快照，防止退出路径挂起或校验异常被 Godot 的零退出码掩盖。

```bash
source project_env.sh
"$PROJECT6_PYTHON" test/part4_3/measure_response.py --project "$PWD" --output "$PWD/test/part4_3/memory/manual-10000" --frames 10000 --regions 20 --samples 1
"$PROJECT6_PYTHON" test/part4_3/run_audit.py
"$PROJECT6_PYTHON" test/part4_3/verify_artifacts.py
```

目标目录必须尚未存在。实际测量和最终验收状态见 `RESULTS.md` 与本地 `test/part4_3/REPORT.md`；设计本身不代表性能目标已经通过。
