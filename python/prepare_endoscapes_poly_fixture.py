# Endoscapes Poly 验收夹具准备脚本(真实数据集 Endoscapes2023 的本地验收入口)。
#
# 用途:从本地 Endoscapes2023 数据集抽取 5-30 帧(起止原始帧号之差必须是 25 的
# 倍数,每 25 帧取一帧),生成验收工作区,包含:
#   frames/                源帧图片(默认符号链接以避免复制私有图片;--copy 时真实复制);
#   manifest.json          数据集清单(schema 1,播放索引 0..N-1、宽高、帧数等);
#   model_output_v1.jsonl  每个播放帧一条 Model Output V1 记录,仅关键帧带种子 polygon;
#   provenance.json        原始帧号、逐帧 SHA-256、mask 转换声明(2 像素边界内缩等)追溯信息。
#
# 角色与协作:本文件只是 CLI 外壳;帧数约束、种子掩码提取、输出校验与同级
# staging 原子发布全部在 annotation_data.endoscapes_fixture.build_fixture 中实现。
#
# 输入:--dataset-root 指向的只读数据集与帧/实例参数;输出:--output 指定的
# 新目录(已存在则拒绝覆盖),并向 stdout 打印结果摘要 JSON。
# 典型运行方式:
#   .venv/bin/python python/prepare_endoscapes_poly_fixture.py \
#       --dataset-root /absolute/endoscapes --output .local-acceptance/endoscapes-poly-65 \
#       --video-id 65 --start-frame 11775 --end-frame 11875 \
#       --key-frame 11800 --instance-index 0 --copy
"""Prepare a 5-30 frame Endoscapes Poly acceptance workspace."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from annotation_data.endoscapes_fixture import BuildRequest, build_fixture


# 解析命令行参数;除 --copy 开关外所有选项均为必填。
# --dataset-root:Endoscapes2023 数据集根目录(只读)。
# --output:要创建的夹具目录,必须不存在、且不能位于数据集目录内部。
# --video-id / --start-frame / --end-frame / --key-frame / --instance-index:
#     选定视频、起止原始帧号(差值须为 25 的倍数)、必须落在该帧序列中的
#     种子关键帧,以及 insseg 实例编号(决定用哪个实例掩码做种子 polygon)。
# --copy:改用真实复制而非符号链接;严格 UI Source 插件会拒绝符号链接,
#     要在 Godot Main 中打开夹具时必须加此开关。
# 返回:argparse.Namespace;其字段名与 BuildRequest 数据类字段一一对应,
#     因此 main() 可以直接 **vars(args) 展开构造请求。
def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dataset-root", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--video-id", required=True, type=int)
    parser.add_argument("--start-frame", required=True, type=int)
    parser.add_argument("--end-frame", required=True, type=int)
    parser.add_argument("--key-frame", required=True, type=int)
    parser.add_argument("--instance-index", required=True, type=int)
    parser.add_argument("--copy", action="store_true", dest="copy_images",
                        help="copy images so the strict UI source plugin can open the fixture")
    return parser.parse_args(argv)


# CLI 主入口:构建夹具并以可读 JSON 打印结果摘要。
# 参数 argv:测试可注入的参数序列,None 时读真实命令行。
# 副作用:经 build_fixture 在 --output 处原子发布工作区;成功时向 stdout 打印
#     摘要(输出路径、帧数、关键帧播放索引与原始帧号、类别、边界内缩像素、
#     retained_iou 等诊断值)。
# 异常处理:数据集不存在、输出已存在、帧参数非法、掩码不可读等以
#     OSError/ValueError 抛出,这里捕获后打印一行失败信息,不打印 traceback。
# 返回:进程退出码,0 成功,1 失败。
def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        result = build_fixture(BuildRequest(**vars(args)))
    except (OSError, ValueError) as error:
        print(f"Endoscapes fixture preparation failed: {error}")
        return 1
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
