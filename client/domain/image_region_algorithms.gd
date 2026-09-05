class_name ImageRegionAlgorithms
extends RefCounted

const POLYGON_OPS := preload("res://client/domain/polygon_ops.gd")

const MAX_REGION_ROI_PIXELS := 1048576
const MAX_LIVE_WIRE_ROI_PIXELS := 262144
const MAX_BOUNDARY_EDGES := 16384
const MAX_OUTPUT_POLYGON_VERTICES := 2048
const EDGE_COST_FLOOR := 0.05
const DISTANCE_EPSILON := 0.000000001
const CARDINAL_OFFSETS := [
	Vector2i(1, 0),
	Vector2i(0, 1),
	Vector2i(-1, 0),
	Vector2i(0, -1),
]
const LIVE_WIRE_OFFSETS := [
	Vector2i(-1, -1),
	Vector2i(0, -1),
	Vector2i(1, -1),
	Vector2i(-1, 0),
	Vector2i(1, 0),
	Vector2i(-1, 1),
	Vector2i(0, 1),
	Vector2i(1, 1),
]


static func region_grow(
	image: Image,
	seed: Vector2i,
	tolerance: float,
	requested_roi: Rect2i = Rect2i(),
) -> Dictionary:
	var image_error := _validate_image(image)
	if not image_error.is_empty():
		return image_error
	if not is_finite(tolerance) or tolerance < 0.0:
		return _refusal(&"invalid_tolerance", "Color-distance tolerance must be finite and non-negative.")
	var roi_result := _resolve_roi(image, requested_roi, MAX_REGION_ROI_PIXELS)
	if not roi_result.get("ok", false):
		return roi_result
	var roi: Rect2i = roi_result["roi"]
	if not roi.has_point(seed):
		return _refusal(&"invalid_seed", "The region-growing seed must lie inside the image ROI.")
	var seed_color := image.get_pixelv(seed)
	if seed_color.a <= 0.0:
		return _refusal(&"empty_region", "The seed pixel is transparent, so no V1 region can be created.")
	return _region_grow_core(image, seed, seed_color, tolerance, roi)


static func region_grow_expanding(
	image: Image,
	seed: Vector2i,
	tolerance: float,
	luminance_bias: float,
	initial_half_size: int = 32,
) -> Dictionary:
	var image_error := _validate_image(image)
	if not image_error.is_empty():
		return _with_region_metadata(image_error, Rect2i(), tolerance, luminance_bias, 0)
	if not is_finite(tolerance) or tolerance < 0.0:
		return _with_region_metadata(
			_refusal(&"invalid_tolerance", "Color-distance tolerance must be finite and non-negative."),
			Rect2i(), tolerance, luminance_bias, 0,
		)
	if not is_finite(luminance_bias):
		return _with_region_metadata(
			_refusal(&"invalid_bias", "Luminance bias must be finite."),
			Rect2i(), tolerance, luminance_bias, 0,
		)
	if initial_half_size <= 0:
		return _with_region_metadata(
			_refusal(&"invalid_half_size", "Initial ROI half-size must be positive."),
			Rect2i(), tolerance, luminance_bias, 0,
		)
	var image_rect := Rect2i(Vector2i.ZERO, image.get_size())
	if not image_rect.has_point(seed):
		return _with_region_metadata(
			_refusal(&"invalid_seed", "The region-growing seed must lie inside the image."),
			Rect2i(), tolerance, luminance_bias, 0,
		)
	var seed_color := image.get_pixelv(seed)
	if seed_color.a <= 0.0:
		return _with_region_metadata(
			_refusal(&"empty_region", "The seed pixel is transparent, so no V1 region can be created."),
			_centered_roi(image_rect, seed, initial_half_size), tolerance, luminance_bias, 0,
		)
	var reference_color := Color(
		clampf(seed_color.r + luminance_bias, 0.0, 1.0),
		clampf(seed_color.g + luminance_bias, 0.0, 1.0),
		clampf(seed_color.b + luminance_bias, 0.0, 1.0),
		seed_color.a,
	)
	var half_size := initial_half_size
	var expansion_count := 0
	while true:
		var roi := _centered_roi(image_rect, seed, half_size)
		if _roi_exceeds_pixel_limit(roi, MAX_REGION_ROI_PIXELS):
			return _with_region_metadata(
				_refusal(&"roi_too_large", "The next region-growing ROI exceeds the 1,048,576-pixel responsiveness limit."),
				roi, tolerance, luminance_bias, expansion_count,
			)
		var result := _region_grow_core(image, seed, reference_color, tolerance, roi)
		if result.get("ok", false):
			var raw_polygon := _packed_polygon(result.get("polygon", []))
			if (
				raw_polygon.is_empty()
				or not POLYGON_OPS.validate_simple_polygon(raw_polygon)
				or not POLYGON_OPS.points_fit_image(raw_polygon, Vector2(image.get_size()))
			):
				result = _refusal(&"invalid_polygon", "Region growing did not produce one bounded simple polygon.")
			else:
				var smoothed := POLYGON_OPS.simplify_pixel_boundary(raw_polygon, 1.0)
				if (
					not smoothed.is_empty()
					and POLYGON_OPS.validate_simple_polygon(smoothed)
					and POLYGON_OPS.points_fit_image(smoothed, Vector2(image.get_size()))
					and smoothed != raw_polygon
				):
					result["polygon"] = _polygon_array(smoothed)
			return _with_region_metadata(result, roi, tolerance, luminance_bias, expansion_count)
		if StringName(result.get("code", &"")) != &"roi_truncated" or roi == image_rect:
			return _with_region_metadata(result, roi, tolerance, luminance_bias, expansion_count)
		expansion_count += 1
		if half_size >= maxi(image_rect.size.x, image_rect.size.y):
			return _with_region_metadata(result, roi, tolerance, luminance_bias, expansion_count)
		half_size = mini(half_size * 2, maxi(image_rect.size.x, image_rect.size.y))
	return _with_region_metadata(
		_refusal(&"roi_truncated", "Region growing stopped before completing the connected component."),
		Rect2i(), tolerance, luminance_bias, expansion_count,
	)


static func _region_grow_core(
	image: Image,
	seed: Vector2i,
	reference_color: Color,
	tolerance: float,
	roi: Rect2i,
) -> Dictionary:

	var mask := PackedByteArray()
	mask.resize(roi.size.x * roi.size.y)
	var visited := PackedByteArray()
	visited.resize(mask.size())
	var queue := PackedInt32Array()
	queue.resize(mask.size())
	queue[0] = _roi_index(seed, roi)
	visited[_roi_index(seed, roi)] = 1
	var cursor := 0
	var queue_size := 1
	var selected_count := 0
	var tolerance_squared := tolerance * tolerance
	while cursor < queue_size:
		var point := _point_from_roi_index(queue[cursor], roi)
		cursor += 1
		var color := image.get_pixelv(point)
		if color.a <= 0.0 or _rgb_distance_squared(color, reference_color) > tolerance_squared + DISTANCE_EPSILON:
			continue
		var point_index := _roi_index(point, roi)
		mask[point_index] = 1
		selected_count += 1
		for offset: Vector2i in CARDINAL_OFFSETS:
			var neighbor := point + offset
			if not roi.has_point(neighbor):
				if (
					neighbor.x >= 0
					and neighbor.y >= 0
					and neighbor.x < image.get_width()
					and neighbor.y < image.get_height()
				):
					var outside_color := image.get_pixelv(neighbor)
					if (
						outside_color.a > 0.0
						and _rgb_distance_squared(outside_color, reference_color)
							<= tolerance_squared + DISTANCE_EPSILON
					):
						return _refusal(
							&"roi_truncated",
							"The seed-connected region continues beyond the bounded ROI; refusing a silently clipped polygon.",
						)
				continue
			var neighbor_index := _roi_index(neighbor, roi)
			if visited[neighbor_index] != 0:
				continue
			visited[neighbor_index] = 1
			queue[queue_size] = neighbor_index
			queue_size += 1

	if selected_count == 0:
		return _refusal(&"empty_region", "Region growing selected no opaque pixels.")
	var result := polygonize_mask(mask, roi.size, roi.position)
	if result.get("ok", false):
		result["pixel_count"] = selected_count
	return result


static func _centered_roi(image_rect: Rect2i, seed: Vector2i, half_size: int) -> Rect2i:
	if half_size >= maxi(image_rect.size.x, image_rect.size.y):
		return image_rect
	var left := maxi(image_rect.position.x, seed.x - half_size)
	var top := maxi(image_rect.position.y, seed.y - half_size)
	var right := mini(image_rect.end.x, seed.x + half_size + 1)
	var bottom := mini(image_rect.end.y, seed.y + half_size + 1)
	return Rect2i(left, top, right - left, bottom - top)


static func _roi_exceeds_pixel_limit(roi: Rect2i, limit: int) -> bool:
	return roi.size.x <= 0 or roi.size.y <= 0 or roi.size.x > limit / roi.size.y


static func _with_region_metadata(
	result: Dictionary,
	roi: Rect2i,
	tolerance: float,
	luminance_bias: float,
	expansion_count: int,
) -> Dictionary:
	var snapshot := result.duplicate(true)
	if not snapshot.has("message"):
		snapshot["message"] = ""
	snapshot["roi"] = roi
	snapshot["tolerance"] = tolerance
	snapshot["luminance_bias"] = luminance_bias
	snapshot["expansion_count"] = expansion_count
	return snapshot


static func _packed_polygon(value: Variant) -> PackedVector2Array:
	var result := PackedVector2Array()
	if not value is Array:
		return result
	for point: Variant in value:
		if not point is Array or point.size() != 2:
			return PackedVector2Array()
		result.append(Vector2(float(point[0]), float(point[1])))
	return result


static func _polygon_array(points: PackedVector2Array) -> Array:
	var result: Array = []
	for point: Vector2 in points:
		result.append([point.x, point.y])
	return result


static func polygonize_mask(
	mask: PackedByteArray,
	size: Vector2i,
	origin: Vector2i = Vector2i.ZERO,
) -> Dictionary:
	if size.x <= 0 or size.y <= 0 or origin.x < 0 or origin.y < 0:
		return _refusal(&"invalid_mask", "Mask size must be positive and its image origin non-negative.")
	var area := size.x * size.y
	if area > MAX_REGION_ROI_PIXELS:
		return _refusal(&"roi_too_large", "The mask exceeds the bounded region-growing ROI.")
	if mask.size() != area:
		return _refusal(&"invalid_mask", "Mask byte count does not match its declared dimensions.")
	var component_count := _foreground_component_count(mask, size)
	if component_count == 0:
		return _refusal(&"empty_region", "The binary mask contains no selected pixels.")
	if component_count > 1:
		return _refusal(&"multiple_components", "Model Output V1 cannot store this mask as one polygon because it has multiple components.")
	if _mask_has_hole(mask, size):
		return _refusal(&"hole_topology", "Model Output V1 cannot store polygon holes without losing geometry.")
	return _trace_simple_boundary(mask, size, origin)


static func live_wire(
	image: Image,
	start: Vector2i,
	goal: Vector2i,
	requested_roi: Rect2i = Rect2i(),
	max_expansions: int = 0,
) -> Dictionary:
	var image_error := _validate_image(image)
	if not image_error.is_empty():
		return image_error
	if max_expansions < 0:
		return _refusal(&"invalid_limit", "Live-wire expansion limit must be zero or positive.")
	var roi_result := _resolve_roi(image, requested_roi, MAX_LIVE_WIRE_ROI_PIXELS)
	if not roi_result.get("ok", false):
		return roi_result
	var roi: Rect2i = roi_result["roi"]
	if not roi.has_point(start) or not roi.has_point(goal):
		return _refusal(&"invalid_anchor", "Both live-wire anchors must lie inside the image ROI.")
	if start == goal:
		return {"ok": true, "points": PackedVector2Array([Vector2(start)]), "cost": 0.0}

	var area := roi.size.x * roi.size.y
	var expansion_budget := area if max_expansions == 0 else mini(max_expansions, area)
	var distances := PackedFloat64Array()
	distances.resize(area)
	distances.fill(INF)
	var predecessors := PackedInt32Array()
	predecessors.resize(area)
	predecessors.fill(-1)
	var settled := PackedByteArray()
	settled.resize(area)
	var gradients := PackedFloat32Array()
	gradients.resize(area)
	gradients.fill(-1.0)
	var start_index := _roi_index(start, roi)
	var goal_index := _roi_index(goal, roi)
	distances[start_index] = 0.0
	var heap_indices: Array[int] = []
	var heap_costs: Array[float] = []
	_heap_push(heap_indices, heap_costs, start_index, 0.0)
	var expansions := 0

	while not heap_indices.is_empty():
		var current_entry := _heap_pop(heap_indices, heap_costs)
		var current_index: int = current_entry["index"]
		var current_cost: float = current_entry["cost"]
		if settled[current_index] != 0 or current_cost > distances[current_index] + DISTANCE_EPSILON:
			continue
		settled[current_index] = 1
		expansions += 1
		if current_index == goal_index:
			var path := _reconstruct_path(predecessors, current_index, roi)
			if path.size() > MAX_OUTPUT_POLYGON_VERTICES:
				return _refusal(
					&"too_complex",
					"The live-wire path exceeds the 2,048-point interaction limit; place a closer anchor.",
				)
			return {
				"ok": true,
				"points": path,
				"cost": distances[current_index],
			}
		if expansions >= expansion_budget:
			return _refusal(&"search_limit", "Live wire stopped before the goal because its expansion budget was exhausted.")

		var current_point := _point_from_roi_index(current_index, roi)
		var current_gradient := _gradient_at(image, current_point, gradients, roi)
		for offset: Vector2i in LIVE_WIRE_OFFSETS:
			var neighbor := current_point + offset
			if not roi.has_point(neighbor):
				continue
			var neighbor_index := _roi_index(neighbor, roi)
			if settled[neighbor_index] != 0:
				continue
			var neighbor_gradient := _gradient_at(image, neighbor, gradients, roi)
			var edge_strength := (current_gradient + neighbor_gradient) * 0.5
			var step_length := sqrt(2.0) if offset.x != 0 and offset.y != 0 else 1.0
			var step_cost := step_length * (EDGE_COST_FLOOR + 1.0 - edge_strength)
			var candidate := distances[current_index] + step_cost
			if candidate + DISTANCE_EPSILON >= distances[neighbor_index]:
				continue
			distances[neighbor_index] = candidate
			predecessors[neighbor_index] = current_index
			_heap_push(heap_indices, heap_costs, neighbor_index, candidate)

	return _refusal(&"no_path", "No live-wire path exists between the anchors inside the ROI.")


static func _validate_image(image: Image) -> Dictionary:
	if image == null or image.is_empty() or image.get_width() <= 0 or image.get_height() <= 0:
		return _refusal(&"invalid_image", "A non-empty Image is required.")
	return {}


static func _resolve_roi(image: Image, requested_roi: Rect2i, max_pixels: int) -> Dictionary:
	var image_rect := Rect2i(Vector2i.ZERO, Vector2i(image.get_width(), image.get_height()))
	var roi := image_rect if requested_roi == Rect2i() else requested_roi
	if (
		roi.size.x <= 0
		or roi.size.y <= 0
		or roi.position.x < 0
		or roi.position.y < 0
		or roi.end.x > image_rect.end.x
		or roi.end.y > image_rect.end.y
	):
		return _refusal(&"invalid_roi", "ROI must be a positive rectangle fully contained in the image.")
	if _roi_exceeds_pixel_limit(roi, max_pixels):
		return _refusal(&"roi_too_large", "ROI is too large for the bounded image algorithm; provide a smaller ROI.")
	return {"ok": true, "roi": roi}


static func _rgb_distance_squared(left: Color, right: Color) -> float:
	var red := left.r - right.r
	var green := left.g - right.g
	var blue := left.b - right.b
	return red * red + green * green + blue * blue


static func _foreground_component_count(mask: PackedByteArray, size: Vector2i) -> int:
	var visited := PackedByteArray()
	visited.resize(mask.size())
	var queue := PackedInt32Array()
	queue.resize(mask.size())
	var count := 0
	for index in range(mask.size()):
		if mask[index] == 0 or visited[index] != 0:
			continue
		count += 1
		if count > 1:
			return count
		queue[0] = index
		visited[index] = 1
		var cursor := 0
		var queue_size := 1
		while cursor < queue_size:
			var current := queue[cursor]
			cursor += 1
			var x := current % size.x
			var y := current / size.x
			for offset: Vector2i in CARDINAL_OFFSETS:
				var neighbor := Vector2i(x, y) + offset
				if neighbor.x < 0 or neighbor.y < 0 or neighbor.x >= size.x or neighbor.y >= size.y:
					continue
				var neighbor_index := neighbor.y * size.x + neighbor.x
				if mask[neighbor_index] == 0 or visited[neighbor_index] != 0:
					continue
				visited[neighbor_index] = 1
				queue[queue_size] = neighbor_index
				queue_size += 1
	return count


static func _mask_has_hole(mask: PackedByteArray, size: Vector2i) -> bool:
	var external := PackedByteArray()
	external.resize(mask.size())
	var queue := PackedInt32Array()
	queue.resize(mask.size())
	var queue_size := 0
	for x in range(size.x):
		queue_size = _enqueue_background(mask, external, queue, queue_size, x, 0, size)
		queue_size = _enqueue_background(mask, external, queue, queue_size, x, size.y - 1, size)
	for y in range(size.y):
		queue_size = _enqueue_background(mask, external, queue, queue_size, 0, y, size)
		queue_size = _enqueue_background(mask, external, queue, queue_size, size.x - 1, y, size)
	var cursor := 0
	while cursor < queue_size:
		var current := queue[cursor]
		cursor += 1
		var point := Vector2i(current % size.x, current / size.x)
		for offset: Vector2i in CARDINAL_OFFSETS:
			var neighbor := point + offset
			if neighbor.x < 0 or neighbor.y < 0 or neighbor.x >= size.x or neighbor.y >= size.y:
				continue
			queue_size = _enqueue_background(
				mask, external, queue, queue_size, neighbor.x, neighbor.y, size,
			)
	for index in range(mask.size()):
		if mask[index] == 0 and external[index] == 0:
			return true
	return false


static func _enqueue_background(
	mask: PackedByteArray,
	external: PackedByteArray,
	queue: PackedInt32Array,
	queue_size: int,
	x: int,
	y: int,
	size: Vector2i,
) -> int:
	var index := y * size.x + x
	if mask[index] == 0 and external[index] == 0:
		external[index] = 1
		queue[queue_size] = index
		return queue_size + 1
	return queue_size


static func _trace_simple_boundary(mask: PackedByteArray, size: Vector2i, origin: Vector2i) -> Dictionary:
	var stride := size.x + 1
	var outgoing: Dictionary = {}
	for y in range(size.y):
		for x in range(size.x):
			if mask[y * size.x + x] == 0:
				continue
			if y == 0 or mask[(y - 1) * size.x + x] == 0:
				if not _add_boundary_edge(outgoing, _vertex_key(x, y, stride), _vertex_key(x + 1, y, stride)):
					return _non_simple_refusal()
			if x == size.x - 1 or mask[y * size.x + x + 1] == 0:
				if not _add_boundary_edge(outgoing, _vertex_key(x + 1, y, stride), _vertex_key(x + 1, y + 1, stride)):
					return _non_simple_refusal()
			if y == size.y - 1 or mask[(y + 1) * size.x + x] == 0:
				if not _add_boundary_edge(outgoing, _vertex_key(x + 1, y + 1, stride), _vertex_key(x, y + 1, stride)):
					return _non_simple_refusal()
			if x == 0 or mask[y * size.x + x - 1] == 0:
				if not _add_boundary_edge(outgoing, _vertex_key(x, y + 1, stride), _vertex_key(x, y, stride)):
					return _non_simple_refusal()
			if outgoing.size() > MAX_BOUNDARY_EDGES:
				return _complexity_refusal()
	if outgoing.is_empty():
		return _refusal(&"empty_region", "The binary mask has no traceable boundary.")

	var start_key := -1
	for value: Variant in outgoing.keys():
		var key := int(value)
		if start_key < 0 or key < start_key:
			start_key = key
	var raw_points: Array[Vector2i] = []
	var visited_edges: Dictionary = {}
	var current_key := start_key
	for _step in range(outgoing.size() + 1):
		if visited_edges.has(current_key):
			break
		visited_edges[current_key] = true
		raw_points.append(_vertex_from_key(current_key, stride))
		if not outgoing.has(current_key):
			return _non_simple_refusal()
		current_key = int(outgoing[current_key])
		if current_key == start_key:
			break
	if current_key != start_key or visited_edges.size() != outgoing.size():
		return _non_simple_refusal()

	var simplified: Array[Vector2i] = []
	for index in range(raw_points.size()):
		var previous := raw_points[(index - 1 + raw_points.size()) % raw_points.size()]
		var current := raw_points[index]
		var following := raw_points[(index + 1) % raw_points.size()]
		var first := current - previous
		var second := following - current
		if first.x * second.y - first.y * second.x != 0:
			simplified.append(current)
	if simplified.size() < 3:
		return _non_simple_refusal()
	if simplified.size() > MAX_OUTPUT_POLYGON_VERTICES:
		return _complexity_refusal()
	var polygon: Array = []
	for point: Vector2i in simplified:
		var image_point := point + origin
		polygon.append([image_point.x, image_point.y])
	return {"ok": true, "polygon": polygon}


static func _add_boundary_edge(outgoing: Dictionary, start: int, finish: int) -> bool:
	if outgoing.has(start):
		return false
	outgoing[start] = finish
	return true


static func _non_simple_refusal() -> Dictionary:
	return _refusal(
		&"non_simple_topology",
		"The pixel boundary touches or branches and cannot be represented as one simple Model Output V1 polygon.",
	)


static func _complexity_refusal() -> Dictionary:
	return _refusal(
		&"too_complex",
		"The pixel boundary is too detailed for responsive single-ring V1 editing; use a smaller ROI or simplify the source.",
	)


static func _vertex_key(x: int, y: int, stride: int) -> int:
	return y * stride + x


static func _vertex_from_key(key: int, stride: int) -> Vector2i:
	return Vector2i(key % stride, key / stride)


static func _roi_index(point: Vector2i, roi: Rect2i) -> int:
	return (point.y - roi.position.y) * roi.size.x + point.x - roi.position.x


static func _point_from_roi_index(index: int, roi: Rect2i) -> Vector2i:
	return Vector2i(index % roi.size.x, index / roi.size.x) + roi.position


static func _gradient_at(
	image: Image,
	point: Vector2i,
	cache: PackedFloat32Array,
	roi: Rect2i,
) -> float:
	var index := _roi_index(point, roi)
	if cache[index] >= 0.0:
		return cache[index]
	var left_x := maxi(0, point.x - 1)
	var right_x := mini(image.get_width() - 1, point.x + 1)
	var top_y := maxi(0, point.y - 1)
	var bottom_y := mini(image.get_height() - 1, point.y + 1)
	var horizontal := image.get_pixel(right_x, point.y).get_luminance() - image.get_pixel(left_x, point.y).get_luminance()
	var vertical := image.get_pixel(point.x, bottom_y).get_luminance() - image.get_pixel(point.x, top_y).get_luminance()
	var magnitude := clampf(sqrt(horizontal * horizontal + vertical * vertical), 0.0, 1.0)
	cache[index] = magnitude
	return magnitude


static func _heap_push(
	indices: Array[int],
	costs: Array[float],
	index: int,
	cost: float,
) -> void:
	indices.append(index)
	costs.append(cost)
	var child := indices.size() - 1
	while child > 0:
		var parent := (child - 1) / 2
		if not _heap_entry_less(costs[child], indices[child], costs[parent], indices[parent]):
			break
		_swap_heap_entries(indices, costs, child, parent)
		child = parent


static func _heap_pop(indices: Array[int], costs: Array[float]) -> Dictionary:
	var result := {"index": indices[0], "cost": costs[0]}
	var last_index: int = indices.pop_back()
	var last_cost: float = costs.pop_back()
	if indices.is_empty():
		return result
	indices[0] = last_index
	costs[0] = last_cost
	var parent := 0
	while true:
		var left := parent * 2 + 1
		if left >= indices.size():
			break
		var right := left + 1
		var smaller := left
		if right < indices.size() and _heap_entry_less(costs[right], indices[right], costs[left], indices[left]):
			smaller = right
		if not _heap_entry_less(costs[smaller], indices[smaller], costs[parent], indices[parent]):
			break
		_swap_heap_entries(indices, costs, parent, smaller)
		parent = smaller
	return result


static func _heap_entry_less(left_cost: float, left_index: int, right_cost: float, right_index: int) -> bool:
	if left_cost == right_cost:
		return left_index < right_index
	return left_cost < right_cost


static func _swap_heap_entries(
	indices: Array[int],
	costs: Array[float],
	left: int,
	right: int,
) -> void:
	var index_value := indices[left]
	indices[left] = indices[right]
	indices[right] = index_value
	var cost_value := costs[left]
	costs[left] = costs[right]
	costs[right] = cost_value


static func _reconstruct_path(
	predecessors: PackedInt32Array,
	goal_index: int,
	roi: Rect2i,
) -> PackedVector2Array:
	var reversed: Array[Vector2] = []
	var current := goal_index
	while current >= 0:
		reversed.append(Vector2(_point_from_roi_index(current, roi)))
		current = predecessors[current]
	reversed.reverse()
	return PackedVector2Array(reversed)


static func _refusal(code: StringName, message: String) -> Dictionary:
	return {"ok": false, "code": code, "message": message}
