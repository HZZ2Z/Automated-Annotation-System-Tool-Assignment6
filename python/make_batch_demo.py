# 批量审核(Batch Review)演示工作区生成脚本。
#
# 用途:从既有的 assignment_v1 合成样例复制出一份独立、可复现的批量审核
# 演示工作区,并人为注入可预期的模型基线缺陷:第 40-59 帧首条 region 的
# class 被改成 "batch_demo_wrong",box 的 x 原点整体右移 8 像素(polygon
# 不动)。注入缺陷前的原始 region 会深拷贝,连同源基线的 SHA-256 一起写入
# batch_demo_truth.json,作为核对批量传播结果是否还原正确的对照真值。
# 角色与协作:主要供 tests/godot/test_batch_ui.gd 驱动 Godot 批量审核 UI:
# 打开 batch_clip、修正关键帧 50,把修正批量传播到 40-59 帧后与真值比对。
# 输入:--source 样例目录(默认 sample/assignment_v1,必须是 120 帧的
# assignment_v1 样例);输出:--output 新目录,内含 batch_clip/(剔除样例
# 自带的哈希清单、缺陷真值与人工标注)和 batch_demo_truth.json。
# 典型运行方式:
#   .venv/bin/python python/make_batch_demo.py --output .local-acceptance/batch_demo
"""Create a separate, reproducible batch-review workspace from assignment_v1."""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import shutil


# 从 source 样例生成批量审核演示工作区,返回写入 batch_demo_truth.json 的证据字典
# (source_annotations_sha256 / defect / keyframe / start / end / truth_regions)。
# 参数 source:assignment_v1 样例目录(含 model_output_v1.jsonl);
#      output:要创建的演示目录,不得已存在,且不得等于 source 或位于 source
#      内部(违反即抛 ValueError)。
# 副作用:创建 output/batch_clip/(剔除 hashes.json、expected_defects.json 与
#      label/ 三类样例自带文件),并用注入缺陷后的记录重写其中的
#      model_output_v1.jsonl;再写 output/batch_demo_truth.json
#      (UTF-8、带缩进、结尾换行)。
def make_demo(source: Path, output: Path) -> dict:
    source, output = source.resolve(), output.resolve()
    if output.exists():
        raise ValueError("Output already exists; choose a new workspace directory")
    if source == output or source in output.parents:
        raise ValueError("Output must be outside the original sample")
    raw = (source / "model_output_v1.jsonl").read_bytes()
    records = [json.loads(line) for line in raw.splitlines() if line]
    if len(records) != 120 or any(records[i]["frame"] != i for i in range(120)):
        # 样例必须正好是 120 帧、frame 字段依次为 0..119,否则拒绝生成,
        # 保证演示工作区可复现、真值区间有意义。
        raise ValueError("Expected the 120-frame assignment_v1 sample")
    # 注入缺陷前把 40-59 帧首条 region 深拷贝为对照真值(键为帧号的十进制字符串)。
    truth = {str(i): copy.deepcopy(records[i]["regions"][0]) for i in range(40, 60)}
    # 注入演示缺陷:首条 region 的 class 改名;若带 box,则把 x 原点右移 8 像素。
    for i in range(40, 60):
        region = records[i]["regions"][0]
        region["class"] = "batch_demo_wrong"
        if "box" in region:
            region["box"][0] += 8
    clip = output / "batch_clip"
    shutil.copytree(source, clip, ignore=shutil.ignore_patterns("hashes.json", "expected_defects.json", "label"))
    # 用注入缺陷后的记录逐行重写 clip 内的模型基线 JSONL(紧凑 JSON,一行一条)。
    (clip / "model_output_v1.jsonl").write_text(
        "".join(json.dumps(record) + "\n" for record in records), encoding="utf-8")
    # 证据文件:源基线字节的 SHA-256 + 缺陷描述 + 关键帧/受影响帧闭区间 + 真值。
    evidence = {
        "source_annotations_sha256": hashlib.sha256(raw).hexdigest(),
        "defect": "First region: class batch_demo_wrong; box x +8 on frames 40-59",
        "keyframe": 50, "start": 40, "end": 59, "truth_regions": truth,
    }
    (output / "batch_demo_truth.json").write_text(json.dumps(evidence, indent=2) + "\n", encoding="utf-8")
    return evidence


if __name__ == "__main__":
    # 命令行入口:--source 默认指向标准样例 sample/assignment_v1,--output 必填。
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=Path("sample/assignment_v1"))
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    make_demo(args.source, args.output)
    # 证据字典已写入 batch_demo_truth.json;这里只打印给测试者的操作提示。
    print(f"Open workspace: {args.output.resolve()}; select batch_clip, correct frame 50.")
