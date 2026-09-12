# 仓库根目录定位模块。
#
# 用途:以本包源码文件的安装位置为锚点,推导仓库根目录的绝对路径,供需要
# 访问仓库内资源(如 core/schemas、sample)的代码使用,结果不依赖进程启动
# 时的工作目录。
#
# 角色与协作:annotation_data 包内的公共小工具;推导方式与 contracts.ROOT
# 一致(源文件路径向上回溯得到仓库根)。
#
# 输入:无(只读取本模块的 __file__);输出:仓库根目录的 Path。

from pathlib import Path


# 返回仓库根目录:对 __file__ 取绝对路径后向上回溯两级(第一级是
# annotation_data 包目录,第二级是 python/)即到仓库根。
# 无副作用,不抛异常;若包被移动到别的层级,结果随源文件位置改变。
def repository_root() -> Path:
    """Return the repository root derived from this installed source file."""
    return Path(__file__).resolve().parents[2]
