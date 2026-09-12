# annotation_data 包入口模块。
#
# 用途:本包是「Project 6 自动标注系统」的核心 Python 库,功能按子模块拆分:
# schema 合同校验(contracts)、JSONL 读写(jsonl)、工作区与 label 语义校验
# (workspace)、V3 审核会话校验(review_session)、帧相似度(similarity)、
# polygon 光流(polygon_flow)等;python/ 下的 worker 脚本与验收脚本通过
# `from annotation_data.<module> import ...` 按需引用。
#
# 本文件本身只声明包版本号,不做再导出,也没有任何初始化副作用。

# 包版本号:语义化版本字符串。
__version__ = "0.1.0"
