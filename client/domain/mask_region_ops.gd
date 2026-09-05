class_name MaskRegionOps
extends RefCounted

const IMAGE_ALGORITHMS := preload("res://client/domain/image_region_algorithms.gd")

const MAX_MASK_PIXELS := 1048576
const VECTOR2I_MAX := 2147483647
const RASTER_PADDING := 2
const MAX_GAP_RADIUS := 8.0
const CARDINAL_OFFSETS := [
	Vector2i(1, 0),
	Vector2i(0, 1),
	Vector2i(-1, 0),
	Vector2i(0, -1),
]

const STATUS_SINGLE := &"single"
const STATUS_EMPTY := &"empty"
const STATUS_HOLE := &"hole"
const STATUS_MULTI_COMPONENT := &"multi_component"
const STATUS_OPEN := &"open"
const STATUS_NO_OP := &"no_op"
const STATUS_INVALID := &"invalid"
const STATUS_ROI_TOO_LARGE := &"roi_too_large"


static func rasterize_polygon(points: Variant, image_size: Vector2i) -> Dictionary:
	if not _valid_image_size(image_size):
		return _result(false, STATUS_INVALID, Rect2i(), PackedByteArray(), PackedVector2Array(), "Image size must be positive.")
	var polygon := _coerce_points(points)
	if polygon.size() < 3 or not _all_finite(polygon):
		return _result(false, STATUS_INVALID, Rect2i(), PackedByteArray(), PackedVector2Array(), "Polygon rasterization requires at least three finite points.")
	var bounds := _point_bounds(polygon, 0.0, image_size)
	if bounds == Rect2i():
		return _empty_result()
	var allocation_error := _allocation_error(bounds)
	if not allocation_error.is_empty():
		return allocation_error
	var mask := PackedByteArray()
	mask.resize(bounds.size.x * bounds.size.y)
	for local_y in range(bounds.size.y):
		for local_x in range(bounds.size.x):
			var image_point := bounds.position + Vector2i(local_x, local_y)
			var pixel_center := Vector2(image_point) + Vector2(0.5, 0.5)
			if Geometry2D.is_point_in_polygon(pixel_center, polygon):
				mask[local_y * bounds.size.x + local_x] = 1
	return to_v1_candidate({"roi": bounds, "mask": mask})


static func rasterize_stroke(samples: Variant, radius: float, image_size: Vector2i) -> Dictionary:
	var raw := rasterize_stroke_mask(samples, radius, image_size)
	if not bool(raw.get("ok", false)):
		return raw
	return to_v1_candidate(raw)


static func rasterize_stroke_mask(samples: Variant, radius: float, image_size: Vector2i) -> Dictionary:
	if not _valid_image_size(image_size):
		return _result(false, STATUS_INVALID, Rect2i(), PackedByteArray(), PackedVector2Array(), "Image size must be positive.")
	if not is_finite(radius) or radius <= 0.0:
		return _result(false, STATUS_INVALID, Rect2i(), PackedByteArray(), PackedVector2Array(), "Brush radius must be finite and positive.")
	var points := _coerce_points(samples)
	if points.is_empty() or not _all_finite(points):
		return _result(false, STATUS_INVALID, Rect2i(), PackedByteArray(), PackedVector2Array(), "A stroke requires at least one finite sample.")
	var bounds := _point_bounds(points, radius, image_size)
	if bounds == Rect2i():
		return _empty_result()
	var allocation_error := _allocation_error(bounds)
	if not allocation_error.is_empty():
		return allocation_error
	var mask := PackedByteArray()
	mask.resize(bounds.size.x * bounds.size.y)
	var radius_squared := radius * radius
	for local_y in range(bounds.size.y):
		for local_x in range(bounds.size.x):
			var image_point := bounds.position + Vector2i(local_x, local_y)
			var pixel_center := Vector2(image_point) + Vector2(0.5, 0.5)
			if _point_hits_stroke(pixel_center, points, radius_squared):
				mask[local_y * bounds.size.x + local_x] = 1
	return _result(true, STATUS_SINGLE, bounds, mask)


static func combine(left_state: Dictionary, right_state: Dictionary, operation: StringName) -> Dictionary:
	var raw := combine_masks(left_state, right_state, operation)
	if not bool(raw.get("ok", false)):
		return raw
	return to_v1_candidate(raw)


static func combine_masks(left_state: Dictionary, right_state: Dictionary, operation: StringName) -> Dictionary:
	var left_validation := _validate_state(left_state)
	if not left_validation["valid"]:
		return _validation_refusal(left_validation)
	var right_validation := _validate_state(right_state)
	if not right_validation["valid"]:
		return _validation_refusal(right_validation)
	var left_roi: Rect2i = left_validation["roi"]
	var left_mask: PackedByteArray = left_validation["mask"]
	if operation not in [&"union", &"subtract"]:
		return _result(false, STATUS_INVALID, left_roi, left_mask, PackedVector2Array(), "Mask operation must be union or subtract.")
	var right_roi: Rect2i = right_validation["roi"]
	var right_mask: PackedByteArray = right_validation["mask"]
	var output_roi := _merged_roi(left_roi, right_roi)
	if output_roi == Rect2i():
		return _empty_result()
	var allocation_error := _allocation_error(output_roi)
	if not allocation_error.is_empty():
		return allocation_error
	var output := PackedByteArray()
	output.resize(output_roi.size.x * output_roi.size.y)
	for local_y in range(output_roi.size.y):
		for local_x in range(output_roi.size.x):
			var image_point := output_roi.position + Vector2i(local_x, local_y)
			var left_byte := _byte_at(left_roi, left_mask, image_point)
			var right_byte := _byte_at(right_roi, right_mask, image_point)
			var index := local_y * output_roi.size.x + local_x
			if operation == &"union":
				output[index] = maxi(left_byte, right_byte)
			elif right_byte == 0:
				output[index] = left_byte
	return _result(true, STATUS_SINGLE, output_roi, output)


static func masks_overlap(left_state: Dictionary, right_state: Dictionary) -> bool:
	var left_validation := _validate_state(left_state)
	var right_validation := _validate_state(right_state)
	if not left_validation["valid"] or not right_validation["valid"]:
		return false
	var left_roi: Rect2i = left_validation["roi"]
	var right_roi: Rect2i = right_validation["roi"]
	var overlap_roi := left_roi.intersection(right_roi)
	if overlap_roi == Rect2i():
		return false
	var left_mask: PackedByteArray = left_validation["mask"]
	var right_mask: PackedByteArray = right_validation["mask"]
	for image_y in range(overlap_roi.position.y, overlap_roi.end.y):
		for image_x in range(overlap_roi.position.x, overlap_roi.end.x):
			var image_point := Vector2i(image_x, image_y)
			if _byte_at(left_roi, left_mask, image_point) != 0 and _byte_at(right_roi, right_mask, image_point) != 0:
				return true
	return false


static func find_enclosed_blank(boundary_state: Dictionary, seed: Variant, image_size: Vector2i) -> Dictionary:
	if not _valid_image_size(image_size):
		return _result(false, STATUS_INVALID, Rect2i(), PackedByteArray(), PackedVector2Array(), "Image size must be positive.")
	var validation := _validate_state(boundary_state)
	if not validation["valid"]:
		return _validation_refusal(validation)
	var seed_result := _coerce_image_point(seed)
	if not seed_result["valid"]:
		return _result(false, STATUS_INVALID, Rect2i(), PackedByteArray(), PackedVector2Array(), "Fill seed must be a finite image point.")
	var seed_point: Vector2i = seed_result["point"]
	var image_rect := Rect2i(Vector2i.ZERO, image_size)
	if not image_rect.has_point(seed_point):
		return _result(false, STATUS_INVALID, Rect2i(), PackedByteArray(), PackedVector2Array(), "Fill seed must stay inside the current image.")
	var boundary_roi: Rect2i = validation["roi"]
	var boundary_mask: PackedByteArray = validation["mask"]
	var open_message := "No closed region was found around the selected blank area."
	if boundary_roi == Rect2i():
		return _result(false, STATUS_OPEN, Rect2i(), PackedByteArray(), PackedVector2Array(), open_message)
	var search_roi := boundary_roi.grow(1).intersection(image_rect)
	if search_roi == Rect2i() or not search_roi.has_point(seed_point):
		return _result(false, STATUS_OPEN, boundary_roi, boundary_mask, PackedVector2Array(), open_message)
	var allocation_error := _allocation_error(search_roi)
	if not allocation_error.is_empty():
		return allocation_error
	var search_mask := PackedByteArray()
	search_mask.resize(search_roi.size.x * search_roi.size.y)
	for local_y in range(search_roi.size.y):
		for local_x in range(search_roi.size.x):
			var image_point := search_roi.position + Vector2i(local_x, local_y)
			search_mask[local_y * search_roi.size.x + local_x] = _byte_at(boundary_roi, boundary_mask, image_point)
	var seed_index := _roi_index(seed_point, search_roi)
	if search_mask[seed_index] != 0:
		return _result(false, STATUS_INVALID, search_roi, search_mask, PackedVector2Array(), "Fill requires a blank area inside annotation boundaries.")
	var component := _background_component(search_mask, search_roi.size, seed_index)
	if component["touches_border"]:
		return _result(false, STATUS_OPEN, search_roi, search_mask, PackedVector2Array(), open_message)
	var component_mask := PackedByteArray()
	component_mask.resize(search_mask.size())
	for index: int in component["indices"]:
		component_mask[index] = 1
	return to_v1_candidate({"roi": search_roi, "mask": component_mask})


static func fill_all_enclosed(boundary_state: Dictionary, image_size: Vector2i) -> Dictionary:
	if not _valid_image_size(image_size):
		return _result(false, STATUS_INVALID, Rect2i(), PackedByteArray(), PackedVector2Array(), "Image size must be positive.")
	var validation := _validate_state(boundary_state)
	if not validation["valid"]:
		return _validation_refusal(validation)
	var boundary_roi: Rect2i = validation["roi"]
	var boundary_mask: PackedByteArray = validation["mask"]
	var open_message := "The gesture does not enclose a fillable area."
	if boundary_roi == Rect2i():
		return _result(false, STATUS_OPEN, boundary_roi, boundary_mask, PackedVector2Array(), open_message)
	var search_roi := boundary_roi.grow(1).intersection(Rect2i(Vector2i.ZERO, image_size))
	if search_roi == Rect2i():
		return _result(false, STATUS_OPEN, boundary_roi, boundary_mask, PackedVector2Array(), open_message)
	var allocation_error := _allocation_error(search_roi)
	if not allocation_error.is_empty():
		return allocation_error
	var working := PackedByteArray()
	working.resize(search_roi.size.x * search_roi.size.y)
	for local_y in range(search_roi.size.y):
		for local_x in range(search_roi.size.x):
			var image_point := search_roi.position + Vector2i(local_x, local_y)
			working[local_y * search_roi.size.x + local_x] = _byte_at(boundary_roi, boundary_mask, image_point)
	var visited := PackedByteArray()
	visited.resize(working.size())
	var filled_components := 0
	for seed_index in range(working.size()):
		if working[seed_index] != 0 or visited[seed_index] != 0:
			continue
		var queue: Array[int] = [seed_index]
		var component: Array[int] = []
		visited[seed_index] = 1
		var cursor := 0
		var touches_border := false
		while cursor < queue.size():
			var index := queue[cursor]
			cursor += 1
			component.append(index)
			var point := Vector2i(index % search_roi.size.x, index / search_roi.size.x)
			if point.x == 0 or point.y == 0 or point.x == search_roi.size.x - 1 or point.y == search_roi.size.y - 1:
				touches_border = true
			for offset: Vector2i in CARDINAL_OFFSETS:
				var neighbor := point + offset
				if not _local_point_in_size(neighbor, search_roi.size):
					continue
				var neighbor_index := neighbor.y * search_roi.size.x + neighbor.x
				if working[neighbor_index] != 0 or visited[neighbor_index] != 0:
					continue
				visited[neighbor_index] = 1
				queue.append(neighbor_index)
		if touches_border:
			continue
		filled_components += 1
		for index: int in component:
			working[index] = 1
	if filled_components == 0:
		return _result(false, STATUS_OPEN, search_roi, working, PackedVector2Array(), open_message)
	return to_v1_candidate({"roi": search_roi, "mask": working})


static func fill_enclosed(state: Dictionary, seed: Variant, max_gap_radius: float) -> Dictionary:
	var validation := _validate_state(state)
	if not validation["valid"]:
		return _validation_refusal(validation)
	if not is_finite(max_gap_radius) or max_gap_radius < 0.0 or max_gap_radius > MAX_GAP_RADIUS:
		return _result(false, STATUS_INVALID, validation["roi"], validation["mask"], PackedVector2Array(), "Fill gap radius must be finite and between zero and eight pixels.")
	var seed_result := _coerce_image_point(seed)
	if not seed_result["valid"]:
		return _result(false, STATUS_INVALID, validation["roi"], validation["mask"], PackedVector2Array(), "Fill seed must be a finite image point.")
	var roi: Rect2i = validation["roi"]
	var mask: PackedByteArray = validation["mask"]
	var seed_point: Vector2i = seed_result["point"]
	if roi == Rect2i() or not roi.has_point(seed_point):
		return _result(false, STATUS_INVALID, roi, mask, PackedVector2Array(), "Fill seed must lie inside the bounded mask ROI.")
	var working := mask.duplicate()
	if max_gap_radius > 0.0:
		var integer_gap_radius := floori(max_gap_radius)
		if integer_gap_radius > 0:
			working = _close_bounded_gaps(working, roi.size, integer_gap_radius)
	var seed_index := _roi_index(seed_point, roi)
	if working[seed_index] != 0:
		return _result(false, STATUS_INVALID, roi, mask, PackedVector2Array(), "Fill seed must select background enclosed by the contour.")
	var component := _background_component(working, roi.size, seed_index)
	if component["touches_border"]:
		return _result(false, STATUS_OPEN, roi, mask, PackedVector2Array(), "Contour is still open; complete its boundary before filling.")
	for index: int in component["indices"]:
		working[index] = 1
	return to_v1_candidate({"roi": roi, "mask": working})


static func close_gaps(state: Dictionary, focus: Variant, radius: float) -> Dictionary:
	var validation := _validate_state(state)
	if not validation["valid"]:
		return _validation_refusal(validation)
	if not is_finite(radius) or radius < 1.0 or radius > MAX_GAP_RADIUS:
		return _result(false, STATUS_INVALID, validation["roi"], validation["mask"], PackedVector2Array(), "Close Gaps radius must be finite and between one and eight pixels.")
	var focus_result := _coerce_image_point(focus)
	if not focus_result["valid"]:
		return _result(false, STATUS_INVALID, validation["roi"], validation["mask"], PackedVector2Array(), "Close Gaps focus must be a finite image point.")
	var roi: Rect2i = validation["roi"]
	var source: PackedByteArray = validation["mask"]
	var focus_point: Vector2i = focus_result["point"]
	if roi == Rect2i() or not roi.has_point(focus_point):
		return _result(false, STATUS_INVALID, roi, source, PackedVector2Array(), "Close Gaps focus must lie inside the bounded mask ROI.")
	var integer_radius := maxi(1, floori(radius))
	var neighborhood := Rect2i(
		focus_point - Vector2i(integer_radius, integer_radius),
		Vector2i(integer_radius * 2 + 1, integer_radius * 2 + 1),
	).intersection(roi)
	var context_reach := integer_radius + 1
	var context := Rect2i(
		neighborhood.position - Vector2i(context_reach, context_reach),
		neighborhood.size + Vector2i(context_reach * 2, context_reach * 2),
	).intersection(roi)
	var context_mask := _extract_mask(source, roi, context)
	var closed := _close_bounded_gaps(context_mask, context.size, integer_radius)
	var output := source.duplicate()
	var changed := false
	for image_y in range(neighborhood.position.y, neighborhood.end.y):
		for image_x in range(neighborhood.position.x, neighborhood.end.x):
			var image_point := Vector2i(image_x, image_y)
			if Vector2(image_point).distance_squared_to(Vector2(focus_point)) > radius * radius:
				continue
			var index := _roi_index(image_point, roi)
			var closed_byte := closed[_roi_index(image_point, context)]
			if output[index] == closed_byte:
				continue
			output[index] = closed_byte
			changed = true
	if not changed:
		var original_candidate := to_v1_candidate({"roi": roi, "mask": source})
		return _result(false, STATUS_NO_OP, roi, source, original_candidate["polygon"], "No small gap found.")
	return to_v1_candidate({"roi": roi, "mask": output})


static func to_v1_candidate(state: Dictionary) -> Dictionary:
	var validation := _validate_state(state)
	if not validation["valid"]:
		return _validation_refusal(validation)
	var roi: Rect2i = validation["roi"]
	var mask: PackedByteArray = validation["mask"]
	if roi == Rect2i():
		return _empty_result()
	var polygonized: Dictionary = IMAGE_ALGORITHMS.polygonize_mask(mask, roi.size, roi.position)
	if not polygonized.get("ok", false):
		var source_status := StringName(polygonized.get("code", &"invalid_mask"))
		var status := source_status
		match source_status:
			&"empty_region":
				status = STATUS_EMPTY
			&"hole_topology":
				status = STATUS_HOLE
			&"multiple_components":
				status = STATUS_MULTI_COMPONENT
		return _result(false, status, roi, mask, PackedVector2Array(), str(polygonized.get("message", "Mask cannot be represented as one Model Output V1 ring.")))
	var polygon := PackedVector2Array()
	var json_points: Variant = polygonized.get("polygon", [])
	if not json_points is Array:
		return _result(false, STATUS_INVALID, roi, mask, PackedVector2Array(), "Polygonizer returned an invalid point array.")
	for value: Variant in json_points:
		if not value is Array or value.size() != 2 or not _finite_number(value[0]) or not _finite_number(value[1]):
			return _result(false, STATUS_INVALID, roi, mask, PackedVector2Array(), "Polygonizer returned an invalid point.")
		polygon.append(Vector2(float(value[0]), float(value[1])))
	if polygon.size() < 3:
		return _result(false, STATUS_INVALID, roi, mask, PackedVector2Array(), "Polygonizer did not return one simple ring.")
	return _result(true, STATUS_SINGLE, roi, mask, polygon)


static func _result(
	ok: bool,
	status: StringName,
	roi: Rect2i,
	mask: PackedByteArray,
	polygon: PackedVector2Array = PackedVector2Array(),
	message: String = "",
) -> Dictionary:
	return {
		"ok": ok,
		"status": status,
		"roi": roi,
		"mask": mask.duplicate(),
		"polygon": polygon.duplicate(),
		"message": String(message),
	}


static func _empty_result() -> Dictionary:
	return _result(false, STATUS_EMPTY, Rect2i(), PackedByteArray(), PackedVector2Array(), "The clipped mask contains no selected pixels.")


static func _allocation_error(roi: Rect2i) -> Dictionary:
	if roi.size.x * roi.size.y <= MAX_MASK_PIXELS:
		return {}
	return _result(false, STATUS_ROI_TOO_LARGE, roi, PackedByteArray(), PackedVector2Array(), "Mask ROI exceeds the 1,048,576 pixel safety limit.")


static func _validate_state(state: Dictionary) -> Dictionary:
	var roi_value: Variant = state.get("roi")
	var mask_value: Variant = state.get("mask")
	if not roi_value is Rect2i or not mask_value is PackedByteArray:
		return {"valid": false, "status": STATUS_INVALID, "roi": Rect2i(), "mask": PackedByteArray(), "message": "Mask state requires a Rect2i ROI and PackedByteArray mask."}
	var roi: Rect2i = roi_value
	var mask: PackedByteArray = mask_value
	if roi == Rect2i() and mask.is_empty():
		return {"valid": true, "roi": roi, "mask": mask.duplicate()}
	if roi.position.x < 0 or roi.position.y < 0 or roi.size.x <= 0 or roi.size.y <= 0:
		return {"valid": false, "status": STATUS_INVALID, "roi": Rect2i(), "mask": PackedByteArray(), "message": "Mask ROI must be positive and use a non-negative image origin."}
	var end_x: int = int(roi.position.x) + int(roi.size.x)
	var end_y: int = int(roi.position.y) + int(roi.size.y)
	if end_x > VECTOR2I_MAX or end_y > VECTOR2I_MAX:
		return {"valid": false, "status": STATUS_INVALID, "roi": Rect2i(), "mask": PackedByteArray(), "message": "Mask ROI end coordinates exceed the Vector2i image-coordinate range."}
	var area := roi.size.x * roi.size.y
	if area > MAX_MASK_PIXELS:
		return {"valid": false, "status": STATUS_ROI_TOO_LARGE, "roi": roi, "mask": PackedByteArray(), "message": "Mask ROI exceeds the 1,048,576 pixel safety limit."}
	if mask.size() != area:
		return {"valid": false, "status": STATUS_INVALID, "roi": roi, "mask": PackedByteArray(), "message": "Mask byte count does not match its bounded ROI."}
	return {"valid": true, "roi": roi, "mask": mask.duplicate()}


static func _validation_refusal(validation: Dictionary) -> Dictionary:
	return _result(
		false,
		validation.get("status", STATUS_INVALID),
		validation.get("roi", Rect2i()),
		validation.get("mask", PackedByteArray()),
		PackedVector2Array(),
		validation.get("message", "Invalid bounded mask state."),
	)


static func _valid_image_size(size: Vector2i) -> bool:
	return size.x > 0 and size.y > 0


static func _coerce_points(value: Variant) -> PackedVector2Array:
	if value is PackedVector2Array:
		return value.duplicate()
	if not value is Array:
		return PackedVector2Array()
	var points := PackedVector2Array()
	for item: Variant in value:
		if item is Vector2:
			points.append(item)
		elif item is Vector2i:
			points.append(Vector2(item))
		elif item is Array and item.size() == 2 and _finite_number(item[0]) and _finite_number(item[1]):
			points.append(Vector2(float(item[0]), float(item[1])))
		else:
			return PackedVector2Array()
	return points


static func _all_finite(points: PackedVector2Array) -> bool:
	for point: Vector2 in points:
		if not point.is_finite():
			return false
	return true


static func _finite_number(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value))


static func _point_bounds(points: PackedVector2Array, radius: float, image_size: Vector2i) -> Rect2i:
	var minimum := points[0]
	var maximum := points[0]
	for point: Vector2 in points:
		minimum.x = minf(minimum.x, point.x)
		minimum.y = minf(minimum.y, point.y)
		maximum.x = maxf(maximum.x, point.x)
		maximum.y = maxf(maximum.y, point.y)
	var reach := ceili(radius) + RASTER_PADDING
	var start := Vector2i(floori(minimum.x) - reach, floori(minimum.y) - reach)
	var finish := Vector2i(ceili(maximum.x) + reach, ceili(maximum.y) + reach)
	var requested := Rect2i(start, finish - start)
	return requested.intersection(Rect2i(Vector2i.ZERO, image_size))


static func _point_hits_stroke(
	point: Vector2,
	samples: PackedVector2Array,
	radius_squared: float,
) -> bool:
	if samples.size() == 1:
		return point.distance_squared_to(samples[0]) <= radius_squared
	for index in range(samples.size() - 1):
		if _distance_squared_to_segment(point, samples[index], samples[index + 1]) <= radius_squared:
			return true
	return false


static func _distance_squared_to_segment(point: Vector2, start: Vector2, finish: Vector2) -> float:
	var segment := finish - start
	var length_squared := segment.length_squared()
	if length_squared <= 0.000000001:
		return point.distance_squared_to(start)
	var progress := clampf((point - start).dot(segment) / length_squared, 0.0, 1.0)
	return point.distance_squared_to(start + segment * progress)


static func _merged_roi(left: Rect2i, right: Rect2i) -> Rect2i:
	if left == Rect2i():
		return right
	if right == Rect2i():
		return left
	return left.merge(right)


static func _byte_at(roi: Rect2i, mask: PackedByteArray, image_point: Vector2i) -> int:
	if roi == Rect2i() or not roi.has_point(image_point):
		return 0
	return mask[_roi_index(image_point, roi)]


static func _roi_index(image_point: Vector2i, roi: Rect2i) -> int:
	var local := image_point - roi.position
	return local.y * roi.size.x + local.x


static func _extract_mask(source: PackedByteArray, source_roi: Rect2i, target_roi: Rect2i) -> PackedByteArray:
	var extracted := PackedByteArray()
	extracted.resize(target_roi.size.x * target_roi.size.y)
	for local_y in range(target_roi.size.y):
		for local_x in range(target_roi.size.x):
			var image_point := target_roi.position + Vector2i(local_x, local_y)
			extracted[local_y * target_roi.size.x + local_x] = source[_roi_index(image_point, source_roi)]
	return extracted


static func _coerce_image_point(value: Variant) -> Dictionary:
	if value is Vector2i:
		return {"valid": true, "point": value}
	if value is Vector2 and value.is_finite():
		return {"valid": true, "point": Vector2i(floori(value.x), floori(value.y))}
	return {"valid": false, "point": Vector2i.ZERO}


static func _close_bounded_gaps(mask: PackedByteArray, size: Vector2i, max_gap_length: int) -> PackedByteArray:
	if max_gap_length <= 0:
		return mask.duplicate()
	var output := mask.duplicate()
	var directions: Array[Vector2i] = [
		Vector2i(1, 0),
		Vector2i(0, 1),
		Vector2i(1, 1),
		Vector2i(1, -1),
	]
	for y in range(size.y):
		for x in range(size.x):
			var start := Vector2i(x, y)
			if mask[y * size.x + x] == 0:
				continue
			for direction: Vector2i in directions:
				var gap: Array[int] = []
				var current := start + direction
				while _local_point_in_size(current, size) and mask[current.y * size.x + current.x] == 0:
					gap.append(current.y * size.x + current.x)
					if gap.size() > max_gap_length:
						break
					current += direction
				if gap.is_empty() or gap.size() > max_gap_length:
					continue
				if not _local_point_in_size(current, size) or mask[current.y * size.x + current.x] == 0:
					continue
				for index: int in gap:
					output[index] = 1
	return output


static func _local_point_in_size(point: Vector2i, size: Vector2i) -> bool:
	return point.x >= 0 and point.y >= 0 and point.x < size.x and point.y < size.y


static func _background_component(mask: PackedByteArray, size: Vector2i, seed_index: int) -> Dictionary:
	var visited := PackedByteArray()
	visited.resize(mask.size())
	var queue: Array[int] = [seed_index]
	var indices: Array[int] = []
	visited[seed_index] = 1
	var cursor := 0
	var touches_border := false
	while cursor < queue.size():
		var index := queue[cursor]
		cursor += 1
		indices.append(index)
		var point := Vector2i(index % size.x, index / size.x)
		if point.x == 0 or point.y == 0 or point.x == size.x - 1 or point.y == size.y - 1:
			touches_border = true
		for offset: Vector2i in CARDINAL_OFFSETS:
			var neighbor := point + offset
			if neighbor.x < 0 or neighbor.y < 0 or neighbor.x >= size.x or neighbor.y >= size.y:
				continue
			var neighbor_index := neighbor.y * size.x + neighbor.x
			if mask[neighbor_index] != 0 or visited[neighbor_index] != 0:
				continue
			visited[neighbor_index] = 1
			queue.append(neighbor_index)
	return {"indices": indices, "touches_border": touches_border}
