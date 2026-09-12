# 合成标注样例(assignment_v1)生成脚本。
#
# 用途:生成一份确定性的合成标注样例工作区,作为评审/审核流程的标准输入;
# 同一随机种子总是产出完全相同的样例,便于回归测试与评审复现。
# 输入:命令行可选的 --output 与 --seed;输出:新的样例目录(已存在则拒绝
# 覆盖),控制台打印生成路径与校验结果(错误信息走 stderr)。
# 典型运行方式:
#   .venv/bin/python python/make_sample_input.py
"""生成确定性合成标注样例的命令行入口。

不传参时使用评审流程要求的标准输出目录和固定随机种子。图像渲染、
错误注入等可复用逻辑由 ``annotation_data.sample`` 负责；本文件只负责
解析命令行参数、返回退出码和输出可读的运行结果。
"""

import argparse
from pathlib import Path
import sys
from typing import Sequence

from annotation_data.sample import generate_sample


# 无参调用时使用的标准输出位置和随机种子。
DEFAULT_OUTPUT = Path("sample/assignment_v1")
DEFAULT_SEED = 6006


# 参数 argv:测试可注入的参数序列,None 时读取真实命令行。
# 返回:argparse.Namespace(output: Path, seed: int),缺省为
#     DEFAULT_OUTPUT / DEFAULT_SEED;参数非法时 argparse 直接结束进程。
def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    """解析可选的输出目录和随机种子参数。

    默认值对应固定种子的标准评审调用；测试或自动化代码可传入
    ``argv`` 复用同一套参数规则。
    """
    parser = argparse.ArgumentParser(
        description="Generate the deterministic synthetic annotation sample."
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=DEFAULT_OUTPUT,
        help=f"new sample output directory (default: {DEFAULT_OUTPUT})",
    )
    parser.add_argument(
        "--seed",
        type=int,
        default=DEFAULT_SEED,
        help=f"deterministic seed (default: {DEFAULT_SEED})",
    )
    return parser.parse_args(argv)


# CLI 主流程:调用 generate_sample 生成样例,并把预期错误折叠为退出码。
# 返回:0 成功;1 输出目录已存在(FileExistsError)或写盘/数据校验失败
#     (OSError、ValueError);预期错误不暴露 traceback。
def main(argv: Sequence[str] | None = None) -> int:
    """执行样例生成流程，成功返回 ``0``，已处理的错误返回 ``1``。

    Args:
        argv: 可选的命令行参数序列；为 ``None`` 时读取实际命令行。

    Returns:
        ``0`` 表示生成和校验成功，``1`` 表示输出目录冲突或生成失败。

    输出目录已存在时会拒绝覆盖，从而保留上一次可重复的生成结果。
    """
    args = parse_args(argv)
    try:
        generate_sample(args.output, seed=args.seed)
    except FileExistsError:
        print(f"error: output directory already exists: {args.output}", file=sys.stderr)
        return 1
    except (OSError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1

    print(f"Generated sample at {args.output}")
    print("Validation errors: 0")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
