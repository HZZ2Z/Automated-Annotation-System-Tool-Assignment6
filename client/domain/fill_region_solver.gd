class_name FillRegionSolver
extends RefCounted

const OPS := preload("res://client/domain/mask_region_ops.gd")


static func solve(boundary: Dictionary, seed: Vector2, image_size: Vector2i, gap_radius: int, cumulative: bool) -> Dictionary:
	if boundary.has("ok") and not boundary.ok:
		return _decorate(boundary)
	if gap_radius < 0 or gap_radius > 3:
		return _failure(&"invalid", "Fill gap radius must be 0, 1, 2 or 3 image pixels.")
	if image_size.x <= 0 or image_size.y <= 0 or not seed.is_finite():
		return _failure(&"invalid", "Fill requires a valid image and a finite seed.")
	var validation := OPS._validate_state(boundary)
	if not validation.valid:
		return _decorate(OPS._validation_refusal(validation))
	var roi: Rect2i = validation.roi
	var image_rect := Rect2i(Vector2i.ZERO, image_size)
	if not Rect2(Vector2.ZERO, Vector2(image_size)).has_point(seed):
		return _failure(&"invalid", "Fill seed must stay inside the current image.")
	if roi == Rect2i():
		return _failure(&"open", "No annotation boundary encloses this seed.")
	if not image_rect.encloses(roi):
		return _failure(&"invalid", "Fill boundary extends outside the current image.")
	# 保留外侧空白，避免把裁剪边界当作封闭轮廓。
	var padded := roi.grow(2 * gap_radius + 1).intersection(image_rect)
	var allocation := OPS._allocation_error(padded)
	if not allocation.is_empty():
		return _decorate(allocation)
	var original := _place_mask(boundary, padded)
	var strict := _fill(original, seed, image_size, cumulative)
	if strict.status != OPS.STATUS_OPEN or gap_radius == 0:
		return _decorate(strict)
	var source: PackedByteArray = original.mask
	var closed := _morph(_morph(source, padded.size, gap_radius, true), padded.size, gap_radius, false)
	for i in range(source.size()):
		closed[i] = maxi(closed[i], source[i])
	var enclosed := OPS.find_enclosed_blank({"roi": padded, "mask": closed}, seed, image_size)
	if enclosed.status != OPS.STATUS_SINGLE:
		return _decorate(enclosed)
	var blank := _place_mask(enclosed, padded)
	var changes := PackedByteArray()
	changes.resize(source.size())
	for i in range(source.size()):
		changes[i] = 1 if closed[i] != 0 and source[i] == 0 else 0
	# 只保留与本次填充相邻的修补连通块，其他对象保持原状。
	var repair := _adjacent_repairs(changes, blank.mask, padded.size)
	var repaired := source.duplicate()
	for i in range(repaired.size()):
		repaired[i] = maxi(repaired[i], repair[i])
	var result := _decorate(_fill({"roi": padded, "mask": repaired}, seed, image_size, cumulative))
	if result.status in [OPS.STATUS_SINGLE, OPS.STATUS_HOLE]:
		result.requires_confirmation = true
		result.repair_mask = {"roi": padded, "mask": repair}
		result.message = "Gap repair preview: Enter or Apply fill confirms; Escape returns to the contour."
	return result


static func _fill(state: Dictionary, seed: Vector2, image_size: Vector2i, cumulative: bool) -> Dictionary:
	return OPS.fill_enclosed(state, seed, 0.0) if cumulative else OPS.find_enclosed_blank(state, seed, image_size)


static func _place_mask(state: Dictionary, roi: Rect2i) -> Dictionary:
	var result := PackedByteArray()
	result.resize(roi.size.x * roi.size.y)
	var source_roi: Rect2i = state.roi
	var source: PackedByteArray = state.mask
	var overlap := source_roi.intersection(roi)
	for y in range(overlap.position.y, overlap.end.y):
		var from := (y - source_roi.position.y) * source_roi.size.x + overlap.position.x - source_roi.position.x
		var to := (y - roi.position.y) * roi.size.x + overlap.position.x - roi.position.x
		for x in range(overlap.size.x):
			result[to + x] = source[from + x]
	return {"roi": roi, "mask": result}


static func _morph(source: PackedByteArray, size: Vector2i, radius: int, dilate: bool) -> PackedByteArray:
	# 可分离方形核的滑动计数，每次形态学操作为 O(ROI 像素数)。
	var horizontal := _window(source, size.x, size.y, radius, dilate, false)
	return _window(horizontal, size.y, size.x, radius, dilate, true)


static func _window(source: PackedByteArray, length: int, lines: int, radius: int, dilate: bool, vertical: bool) -> PackedByteArray:
	var output := PackedByteArray()
	output.resize(source.size())
	var stride := lines if vertical else 1
	for line in range(lines):
		var start := line if vertical else line * length
		var count := 0
		for p in range(mini(radius, length - 1) + 1):
			count += 1 if source[start + p * stride] != 0 else 0
		for p in range(length):
			output[start + p * stride] = int(count > 0 if dilate else count == 2 * radius + 1)
			var leaving := p - radius
			var entering := p + radius + 1
			if leaving >= 0:
				count -= 1 if source[start + leaving * stride] != 0 else 0
			if entering < length:
				count += 1 if source[start + entering * stride] != 0 else 0
	return output


static func _adjacent_repairs(changes: PackedByteArray, blank: PackedByteArray, size: Vector2i) -> PackedByteArray:
	var kept := PackedByteArray()
	kept.resize(changes.size())
	var visited := PackedByteArray()
	visited.resize(changes.size())
	for seed in range(changes.size()):
		if changes[seed] == 0 or visited[seed] != 0:
			continue
		var queue: Array[int] = [seed]
		visited[seed] = 1
		var cursor := 0
		var adjacent := false
		while cursor < queue.size():
			var index := queue[cursor]
			cursor += 1
			var x := index % size.x
			var y := index / size.x
			for dy in range(-1, 2):
				for dx in range(-1, 2):
					if x + dx < 0 or x + dx >= size.x or y + dy < 0 or y + dy >= size.y:
						continue
					var neighbor := (y + dy) * size.x + x + dx
					adjacent = adjacent or blank[neighbor] != 0
					if changes[neighbor] != 0 and visited[neighbor] == 0:
						visited[neighbor] = 1
						queue.append(neighbor)
		if adjacent:
			for index: int in queue:
				kept[index] = 1
	return kept


static func _decorate(result: Dictionary) -> Dictionary:
	var output := result.duplicate(true)
	output.requires_confirmation = false
	output.repair_mask = {}
	return output


static func _failure(status: StringName, message: String) -> Dictionary:
	return _decorate(OPS._result(false, status, Rect2i(), PackedByteArray(), PackedVector2Array(), message))
