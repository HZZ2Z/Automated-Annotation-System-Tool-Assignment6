# 图像对双向稠密光流(DIS)与逐像素运动证据计算模块。
#
# 用途:对一对 uint8 图像(source -> target)计算正向与反向稠密光流,派生
# cv2.remap 采样坐标图、往返一致性、外观误差、越界掩码与局部纹理等证据,
# 并回答「某个 mask 能否被可靠地映射到下一帧」。
#
# 角色与协作:poly-sim-flow-edge-v1 polygon 传播流水线(备选方法,仅用户
# 明确选择时使用)的底层算法件,由 polygon_propagation 以 MotionPair 工厂
# 实例化;只消费调用方冻结好的图像与 mask,本模块不读写文件、不持久化、
# 也不做标注。
#
# 输入:source/target uint8 图像对与待映射/待评估的 mask;输出:float32
# 映射图、warped mask 与 evidence() 质量分数字典。所有失败(非有限光流、
# 证据不足、遮挡、纹理过弱、运动越界)一律抛 ValueError,不做静默降级;
# 协作式取消通过构造参数 check_cancel 注入。
"""有图像证据的双向稠密光流；本模块不负责标注和持久化。"""

from __future__ import annotations

import cv2
import numpy as np


# 一对图像的运动证据容器:构造时一次性算完双向光流并派生全部逐像素证据,
# 之后各属性只读。
# 关键属性:
#   forward_map / backward_map:正向/反向位移叠加到像素坐标网格后的映射图
#       (H×W×2 float32),可直接作为 cv2.remap 的 map 参数;
#   roundtrip / tolerance:前后向往返误差,以及随位移幅度放大的逐像素容差;
#   appearance_error:target 按正向映射拉回 source 帧后的逐像素绝对差;
#   in_bounds:正向落点仍在图像范围内的布尔掩码;
#   local_std:source 的 5×5 局部标准差,衡量局部纹理是否可跟踪。
# 生命周期:不跨帧积累场缓存,每对图像新建一个实例;内部无线程,取消由
#   构造参数 check_cancel 以回调方式协作完成。
class MotionPair:
    """只保留当前图像对的 float32 光流和证据，不能跨帧积累场缓存。"""

    # 计算并缓存一对图像的全部光流证据。
    # 参数 source/target:图像对中相邻的两帧 uint8 ndarray(source 在前);
    #      check_cancel:无参回调,在光流计算的关键节点被调用,由调用方决定
    #      是否以及如何取消(本模块不定义取消异常)。
    # 异常:正向或反向光流出现非有限值时抛 ValueError,计算失败不静默。
    def __init__(self, source: np.ndarray, target: np.ndarray, check_cancel):
        # DIS 光流参数:MEDIUM 预设、最细金字塔尺度 0、8 px patch、步长 3、
        # 25 次梯度下降迭代与 5 次变分精修,在速度与精度之间折中;均值归一化
        # 与空间传播用于改善弱纹理区域的稳定性。
        estimator = cv2.DISOpticalFlow_create(cv2.DISOPTICAL_FLOW_PRESET_MEDIUM)
        estimator.setFinestScale(0)
        estimator.setPatchSize(8)
        estimator.setPatchStride(3)
        estimator.setGradientDescentIterations(25)
        estimator.setVariationalRefinementIterations(5)
        estimator.setUseMeanNormalization(True)
        estimator.setUseSpatialPropagation(True)
        check_cancel()
        forward = estimator.calc(source, target, None)
        check_cancel()
        backward = estimator.calc(target, source, None)
        check_cancel()
        if not np.isfinite(forward).all() or not np.isfinite(backward).all():
            raise ValueError("optical flow is non-finite")
        # 把位移场叠加到像素坐标网格,得到 cv2.remap 可直接使用的采样坐标图
        # (每个输出像素应到另一幅图的哪个坐标取样)。
        yy, xx = np.mgrid[:source.shape[0], :source.shape[1]].astype(np.float32)
        grid = np.dstack((xx, yy))
        self.forward_map = forward + grid
        self.backward_map = backward + grid
        # 往返一致性:在正向映射的落点处采样反向位移;正反位移之和理想为 0,
        # 其范数即往返误差 roundtrip,容差取 1.5 px 基准再加位移幅度的 5%。
        sampled_backward = cv2.remap(backward, self.forward_map, None, cv2.INTER_LINEAR, borderMode=cv2.BORDER_CONSTANT)
        self.roundtrip = np.linalg.norm(forward + sampled_backward, axis=2)
        self.tolerance = 1.5 + 0.05 * np.linalg.norm(forward, axis=2)
        # 外观证据:按正向映射把 target 重采样回 source 帧,与 source 求逐像素
        # 绝对差;差小说明该处画面内容确实互相对应。
        warped_image = cv2.remap(target, self.forward_map, None, cv2.INTER_LINEAR, borderMode=cv2.BORDER_CONSTANT)
        self.appearance_error = np.abs(warped_image.astype(np.float32) - source.astype(np.float32))
        # 越界掩码:任一正向落点跑出图像范围即标记为越界(运动把内容移出画面)。
        x, y = self.forward_map[:, :, 0], self.forward_map[:, :, 1]
        self.in_bounds = (x >= 0) & (y >= 0) & (x <= source.shape[1] - 1) & (y <= source.shape[0] - 1)
        # 5×5 局部标准差:按 E[X²]-E[X]² 用 boxFilter 计算,负的舍入误差截为 0;
        # 平坦区域(标准差小)的光流对应关系不可信。
        pixels = source.astype(np.float32)
        mean = cv2.boxFilter(pixels, -1, (5, 5))
        self.local_std = np.sqrt(np.maximum(cv2.boxFilter(pixels * pixels, -1, (5, 5)) - mean * mean, 0))

    # 把 source 帧坐标系的 mask 映射到 target 帧。
    # 参数 mask:与 source 同尺寸的 8-bit mask(ndarray)。
    # 返回:同尺寸的映射后 mask,越界处补 0;线性插值保留软边界灰度。
    def warp_mask(self, mask: np.ndarray) -> np.ndarray:
        # 反向映射直接携带 8-bit 软边界，避免正向散点产生孔洞和重复轮廓简化。
        return cv2.remap(mask, self.backward_map, None, cv2.INTER_LINEAR, borderMode=cv2.BORDER_CONSTANT)

    # 评估一个 mask 覆盖区域是否具备可信的运动与外观证据(传播门禁的输入)。
    # 参数 mask:source 帧坐标系下的 mask,按阈值 128 二值化使用。
    # 返回:质量分数字典——appearance(外观一致度)、fb_consistency(前后向
    #      一致度)、support(联合支持率)、texture(纹理得分,封顶 1)、
    #      texture_std(核心区局部标准差中位数)、
    #      largest_unsupported_fraction(最大不可靠连通块占核心区比例)。
    # 异常:核心像素过少、纹理过弱、运动越界、联合支持率过低(疑似遮挡或
    #      场景切换)、或存在整片不可靠连通块时抛 ValueError(具体阈值见
    #      各分支注释);失败不静默,回退策略由上层决定。
    def evidence(self, mask: np.ndarray) -> dict[str, float]:
        # 以 128 为阈值二值化,再腐蚀 5×5 得到「核心区」:排除软边界,
        # 只在 mask 内部像素上取证。
        binary = np.asarray(mask >= 128, np.uint8)
        core = cv2.erode(binary, np.ones((5, 5), np.uint8)) > 0
        count = int(np.count_nonzero(core))
        if count < 36:
            raise ValueError("insufficient interior evidence at analysis resolution")
        # 纹理门禁:核心区局部标准差中位数 <2 视为画面过平,像素对应关系
        # 无法观测,直接拒绝。
        texture_std = float(np.median(self.local_std[core]))
        if texture_std < 2:
            raise ValueError("weak texture: interior correspondence is not observable")
        # 越界门禁:mask 内任何像素的正向落点出画即拒绝。
        if not self.in_bounds[binary > 0].all():
            raise ValueError("motion leaves image bounds")
        # 联合支持率门禁:核心区内「往返一致且外观一致(绝对差 ≤25)」的
        # 像素占比不足 0.05 时,判定存在遮挡或镜头切换。
        consistent = self.roundtrip <= self.tolerance
        visible = self.appearance_error <= 25
        support = float(np.mean((consistent & visible)[core]))
        if support < 0.05:
            raise ValueError(f"insufficient forward/backward or appearance evidence ({support:.3f}); possible occlusion or scene cut")
        # 整体均值可能掩盖局部遮挡；不把缺失区域补成原目标。
        bad = np.asarray(core & ~(consistent & visible), np.uint8)
        # 对「证据缺失」像素做 8-连通分析:只要最大缺失块达到
        # max(64, 核心面积×0.98),就认定存在整片遮挡/不一致区域而拒绝。
        component_count, _, stats, _ = cv2.connectedComponentsWithStats(bad, connectivity=8)
        largest_bad = int(stats[1:, cv2.CC_STAT_AREA].max()) if component_count > 1 else 0
        if largest_bad >= max(64, 0.98 * count):
            raise ValueError("local evidence has an occluded or inconsistent component")
        # 汇总输出分数:外观按满差 40、一致性按逐像素容差、纹理按标准差 8
        # 分别线性压到 [0,1],便于上层用统一的最小值门槛比较。
        appearance = float(np.mean(np.clip(1 - self.appearance_error[core] / 40, 0, 1)))
        fb = float(np.mean(np.clip(1 - self.roundtrip[core] / self.tolerance[core], 0, 1)))
        texture = min(1.0, texture_std / 8)
        return {"appearance": appearance, "fb_consistency": fb, "support": support,
                "texture": texture, "texture_std": texture_std,
                "largest_unsupported_fraction": largest_bad / count}
