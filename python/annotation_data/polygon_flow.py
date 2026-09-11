"""有图像证据的双向稠密光流；本模块不负责标注和持久化。"""

from __future__ import annotations

import cv2
import numpy as np


class MotionPair:
    """只保留当前图像对的 float32 光流和证据，不能跨帧积累场缓存。"""

    def __init__(self, source: np.ndarray, target: np.ndarray, check_cancel):
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
        yy, xx = np.mgrid[:source.shape[0], :source.shape[1]].astype(np.float32)
        grid = np.dstack((xx, yy))
        self.forward_map = forward + grid
        self.backward_map = backward + grid
        sampled_backward = cv2.remap(backward, self.forward_map, None, cv2.INTER_LINEAR, borderMode=cv2.BORDER_CONSTANT)
        self.roundtrip = np.linalg.norm(forward + sampled_backward, axis=2)
        self.tolerance = 1.5 + 0.05 * np.linalg.norm(forward, axis=2)
        warped_image = cv2.remap(target, self.forward_map, None, cv2.INTER_LINEAR, borderMode=cv2.BORDER_CONSTANT)
        self.appearance_error = np.abs(warped_image.astype(np.float32) - source.astype(np.float32))
        x, y = self.forward_map[:, :, 0], self.forward_map[:, :, 1]
        self.in_bounds = (x >= 0) & (y >= 0) & (x <= source.shape[1] - 1) & (y <= source.shape[0] - 1)
        pixels = source.astype(np.float32)
        mean = cv2.boxFilter(pixels, -1, (5, 5))
        self.local_std = np.sqrt(np.maximum(cv2.boxFilter(pixels * pixels, -1, (5, 5)) - mean * mean, 0))

    def warp_mask(self, mask: np.ndarray) -> np.ndarray:
        # 反向映射直接携带 8-bit 软边界，避免正向散点产生孔洞和重复轮廓简化。
        return cv2.remap(mask, self.backward_map, None, cv2.INTER_LINEAR, borderMode=cv2.BORDER_CONSTANT)

    def evidence(self, mask: np.ndarray) -> dict[str, float]:
        binary = np.asarray(mask >= 128, np.uint8)
        core = cv2.erode(binary, np.ones((5, 5), np.uint8)) > 0
        count = int(np.count_nonzero(core))
        if count < 36:
            raise ValueError("insufficient interior evidence at analysis resolution")
        texture_std = float(np.median(self.local_std[core]))
        if texture_std < 2:
            raise ValueError("weak texture: interior correspondence is not observable")
        if not self.in_bounds[binary > 0].all():
            raise ValueError("motion leaves image bounds")
        consistent = self.roundtrip <= self.tolerance
        visible = self.appearance_error <= 25
        support = float(np.mean((consistent & visible)[core]))
        if support < 0.05:
            raise ValueError(f"insufficient forward/backward or appearance evidence ({support:.3f}); possible occlusion or scene cut")
        # 整体均值可能掩盖局部遮挡；不把缺失区域补成原目标。
        bad = np.asarray(core & ~(consistent & visible), np.uint8)
        component_count, _, stats, _ = cv2.connectedComponentsWithStats(bad, connectivity=8)
        largest_bad = int(stats[1:, cv2.CC_STAT_AREA].max()) if component_count > 1 else 0
        if largest_bad >= max(64, 0.98 * count):
            raise ValueError("local evidence has an occluded or inconsistent component")
        appearance = float(np.mean(np.clip(1 - self.appearance_error[core] / 40, 0, 1)))
        fb = float(np.mean(np.clip(1 - self.roundtrip[core] / self.tolerance[core], 0, 1)))
        texture = min(1.0, texture_std / 8)
        return {"appearance": appearance, "fb_consistency": fb, "support": support,
                "texture": texture, "texture_std": texture_std,
                "largest_unsupported_fraction": largest_bad / count}
