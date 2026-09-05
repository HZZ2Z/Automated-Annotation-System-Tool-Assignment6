class_name PolygonOps
extends RefCounted

const STATUS_SINGLE := &"single"
const STATUS_EMPTY := &"empty"
const STATUS_MULTI_COMPONENT := &"multi_component"
const STATUS_UNSUPPORTED_TOPOLOGY := &"unsupported_topology"

const POINT_EPSILON := 0.00001
const POINT_EPSILON_SQUARED := POINT_EPSILON * POINT_EPSILON
const CROSS_EPSILON := 0.00001
const AREA_EPSILON := 0.00001
const MAX_PIXEL_BOUNDARY_VERTICES := 2048


static func sanitize_freehand(points: Variant, simplify_tolerance := 0.0, close_distance := 0.0) -> PackedVector2Array:
	var ring := _coerce_points(points)
	if ring.is_empty() or not _all_finite(ring):
		return PackedVector2Array()
	var requested_close_distance := maxf(0.0, float(close_distance))
	if (
		requested_close_distance > 0.0
		and ring.size() > 1
		and ring[0].distance_squared_to(ring[-1])
			> requested_close_distance * requested_close_distance
	):
		return PackedVector2Array()
	ring = _deduplicate_ring(ring, requested_close_distance)
	if ring.size() < 3:
		return PackedVector2Array()
	if float(simplify_tolerance) > 0.0 and ring.size() > 3:
		ring = _simplify_closed_ring(ring, float(simplify_tolerance))
		ring = _deduplicate_ring(ring, 0.0)
	return ring if validate_simple_polygon(ring) else PackedVector2Array()


static func validate_simple_polygon(points: Variant) -> bool:
	var ring := _coerce_points(points)
	if ring.size() < 3 or not _all_finite(ring):
		return false
	for first in range(ring.size()):
		for second in range(first + 1, ring.size()):
			if ring[first].distance_squared_to(ring[second]) <= POINT_EPSILON_SQUARED:
				return false
	if absf(_signed_twice_area(ring)) <= AREA_EPSILON:
		return false
	for current in range(ring.size()):
		var previous_point := ring[(current - 1 + ring.size()) % ring.size()]
		var current_point := ring[current]
		var next_point := ring[(current + 1) % ring.size()]
		var incoming := current_point - previous_point
		var outgoing := next_point - current_point
		if absf(incoming.cross(outgoing)) <= CROSS_EPSILON and incoming.dot(outgoing) < 0.0:
			return false
	for first_edge in range(ring.size()):
		var first_end := (first_edge + 1) % ring.size()
		for second_edge in range(first_edge + 1, ring.size()):
			var second_end := (second_edge + 1) % ring.size()
			if first_edge == second_end or first_end == second_edge:
				continue
			if _segments_intersect(ring[first_edge], ring[first_end], ring[second_edge], ring[second_end]):
				return false
	return true


static func box_to_polygon(box: Variant) -> PackedVector2Array:
	var rect := Rect2()
	if box is Rect2:
		rect = box
	elif box is Array and box.size() == 4:
		for coordinate: Variant in box:
			if not _finite_number(coordinate):
				return PackedVector2Array()
		rect = Rect2(float(box[0]), float(box[1]), float(box[2]), float(box[3]))
	else:
		return PackedVector2Array()
	if not rect.position.is_finite() or not rect.size.is_finite() or rect.size.x <= 0.0 or rect.size.y <= 0.0:
		return PackedVector2Array()
	return PackedVector2Array([
		rect.position,
		Vector2(rect.end.x, rect.position.y),
		rect.end,
		Vector2(rect.position.x, rect.end.y),
	])


static func polygon_bounds(points: Variant) -> Rect2:
	var ring := _coerce_points(points)
	if ring.is_empty() or not _all_finite(ring):
		return Rect2()
	var minimum := ring[0]
	var maximum := ring[0]
	for point: Vector2 in ring:
		minimum.x = minf(minimum.x, point.x)
		minimum.y = minf(minimum.y, point.y)
		maximum.x = maxf(maximum.x, point.x)
		maximum.y = maxf(maximum.y, point.y)
	return Rect2(minimum, maximum - minimum)


static func points_fit_image(points: Variant, image_size: Vector2) -> bool:
	if not image_size.is_finite() or image_size.x <= 0.0 or image_size.y <= 0.0:
		return false
	var ring := _coerce_points(points)
	if ring.is_empty():
		return false
	for point: Vector2 in ring:
		if not point.is_finite() or point.x < 0.0 or point.y < 0.0 or point.x > image_size.x or point.y > image_size.y:
			return false
	return true


static func equivalent_ring(first_value: Variant, second_value: Variant, epsilon := POINT_EPSILON) -> bool:
	var tolerance := float(epsilon)
	if (
		not is_finite(tolerance)
		or tolerance < 0.0
	):
		return false
	var first := _equivalence_ring(first_value, tolerance)
	var second := _equivalence_ring(second_value, tolerance)
	if first.size() != second.size() or first.is_empty() or second.is_empty():
		return false
	var tolerance_squared := tolerance * tolerance
	for second_start in range(second.size()):
		if first[0].distance_squared_to(second[second_start]) > tolerance_squared:
			continue
		for direction in [1, -1]:
			var matches := true
			for index in range(first.size()):
				var second_index := posmod(second_start + direction * index, second.size())
				if first[index].distance_squared_to(second[second_index]) > tolerance_squared:
					matches = false
					break
			if matches:
				return true
	return false


static func simplify_pixel_boundary(points: Variant, max_deviation := 1.0) -> PackedVector2Array:
	var tolerance := float(max_deviation)
	var ring := _coerce_points(points)
	if (
		not is_finite(tolerance)
		or tolerance < 0.0
		or tolerance > 1.0
		or ring.size() < 3
		or ring.size() > MAX_PIXEL_BOUNDARY_VERTICES
		or not validate_simple_polygon(ring)
	):
		return PackedVector2Array()
	if tolerance == 0.0 or ring.size() == 3:
		return ring
	var simplified := _deduplicate_ring(_simplify_closed_ring(ring, tolerance), 0.0)
	if not validate_simple_polygon(simplified):
		return ring
	for point: Vector2 in ring:
		var closest := INF
		for edge in range(simplified.size()):
			closest = minf(
				closest,
				_distance_to_segment(point, simplified[edge], simplified[(edge + 1) % simplified.size()]),
			)
		if closest > tolerance + POINT_EPSILON:
			return ring
	return simplified


static func _equivalence_ring(value: Variant, tolerance: float) -> PackedVector2Array:
	var source := _coerce_points(value)
	if source.is_empty() or not _all_finite(source):
		return PackedVector2Array()
	var tolerance_squared := tolerance * tolerance
	var ring := PackedVector2Array()
	for point: Vector2 in source:
		if ring.is_empty() or ring[-1].distance_squared_to(point) > tolerance_squared:
			ring.append(point)
	if ring.size() > 1 and ring[0].distance_squared_to(ring[-1]) <= tolerance_squared:
		ring.remove_at(ring.size() - 1)
	if ring.size() < 3:
		return PackedVector2Array()
	var changed := true
	while changed and ring.size() > 3:
		changed = false
		for index in range(ring.size()):
			var previous := ring[(index - 1 + ring.size()) % ring.size()]
			var current := ring[index]
			var next := ring[(index + 1) % ring.size()]
			if (
				_distance_to_segment(current, previous, next) <= tolerance
				and (current - previous).dot(next - current) >= -tolerance_squared
			):
				ring.remove_at(index)
				changed = true
				break
	return ring


static func resize_by_handle(points: Variant, handle: int, target: Vector2, min_size := 1.0) -> PackedVector2Array:
	var ring := _coerce_points(points)
	var minimum_size := float(min_size)
	if (
		handle < 0
		or handle > 7
		or not target.is_finite()
		or not is_finite(minimum_size)
		or minimum_size <= 0.0
		or not validate_simple_polygon(ring)
	):
		return PackedVector2Array()
	var old_bounds := polygon_bounds(ring)
	if old_bounds.size.x <= POINT_EPSILON or old_bounds.size.y <= POINT_EPSILON:
		return PackedVector2Array()
	var new_minimum := old_bounds.position
	var new_maximum := old_bounds.end
	if handle in [0, 6, 7]:
		new_minimum.x = minf(target.x, old_bounds.end.x - minimum_size)
	elif handle in [2, 3, 4]:
		new_maximum.x = maxf(target.x, old_bounds.position.x + minimum_size)
	if handle in [0, 1, 2]:
		new_minimum.y = minf(target.y, old_bounds.end.y - minimum_size)
	elif handle in [4, 5, 6]:
		new_maximum.y = maxf(target.y, old_bounds.position.y + minimum_size)
	var scale := (new_maximum - new_minimum) / old_bounds.size
	var resized := PackedVector2Array()
	for point: Vector2 in ring:
		resized.append(new_minimum + (point - old_bounds.position) * scale)
	return resized


static func union(first: Variant, second: Variant) -> Dictionary:
	return _boolean_operation(first, second, true)


static func difference(subject: Variant, clip: Variant) -> Dictionary:
	return _boolean_operation(subject, clip, false)


static func close_polygon(points: Variant, radius: float) -> Dictionary:
	var ring := _coerce_points(points)
	if not is_finite(radius) or radius <= 0.0 or not validate_simple_polygon(ring):
		return _result(
			STATUS_UNSUPPORTED_TOPOLOGY,
			[],
			"Closing requires a finite positive radius and one simple polygon.",
		)
	var expanded := _classify_boolean_rings(
		Geometry2D.offset_polygon(ring, radius, Geometry2D.JOIN_ROUND)
	)
	if expanded.get("status") != STATUS_SINGLE:
		return expanded
	return _classify_boolean_rings(
		Geometry2D.offset_polygon(expanded["polygon"], -radius, Geometry2D.JOIN_ROUND)
	)


static func stroke_polygon(points: Variant, radius: float) -> Dictionary:
	var line := _coerce_points(points)
	if not is_finite(radius) or radius <= 0.0 or line.is_empty() or not _all_finite(line):
		return _result(
			STATUS_UNSUPPORTED_TOPOLOGY,
			[],
			"A brush stroke requires finite points and a positive radius.",
		)
	var deduplicated := PackedVector2Array()
	for point: Vector2 in line:
		if deduplicated.is_empty() or deduplicated[-1].distance_squared_to(point) > POINT_EPSILON_SQUARED:
			deduplicated.append(point)
	if deduplicated.size() == 1:
		var circle := PackedVector2Array()
		for index in range(16):
			var angle := TAU * float(index) / 16.0
			circle.append(deduplicated[0] + Vector2(cos(angle), sin(angle)) * radius)
		return _result(STATUS_SINGLE, [circle])
	return _classify_boolean_rings(
		Geometry2D.offset_polyline(
			deduplicated,
			radius,
			Geometry2D.JOIN_ROUND,
			Geometry2D.END_ROUND,
		)
	)


static func _boolean_operation(first_value: Variant, second_value: Variant, merge: bool) -> Dictionary:
	var first := _coerce_points(first_value)
	var second := _coerce_points(second_value)
	if not validate_simple_polygon(first) or not validate_simple_polygon(second):
		return _result(
			STATUS_UNSUPPORTED_TOPOLOGY,
			[],
			"Boolean operation requires two finite, simple, non-self-intersecting polygons.",
		)
	var raw_rings: Array[PackedVector2Array]
	if merge:
		raw_rings = Geometry2D.merge_polygons(first, second)
	else:
		raw_rings = Geometry2D.clip_polygons(first, second)
	return _classify_boolean_rings(raw_rings)


static func _classify_boolean_rings(raw_rings: Array[PackedVector2Array]) -> Dictionary:
	var rings: Array[PackedVector2Array] = []
	var invalid_output := false
	for raw_ring: PackedVector2Array in raw_rings:
		var ring := _deduplicate_ring(raw_ring, 0.0)
		rings.append(ring)
		if not validate_simple_polygon(ring):
			invalid_output = true
	if rings.is_empty():
		return _result(STATUS_EMPTY, rings, "The boolean operation removed all geometry.")
	if invalid_output:
		return _result(
			STATUS_UNSUPPORTED_TOPOLOGY,
			rings,
			"Geometry2D returned a degenerate or self-intersecting ring.",
		)
	if rings.size() == 1:
		return _result(STATUS_SINGLE, rings)
	# V1 只能保存单个外环；先保留全部环，再判断孔洞或其他异常拓扑。
	for first in range(rings.size()):
		for second in range(first + 1, rings.size()):
			if _rings_intersect(rings[first], rings[second]):
				return _result(
					STATUS_UNSUPPORTED_TOPOLOGY,
					rings,
					"Boolean output rings touch or intersect and cannot be represented safely by V1.",
				)
			if _point_in_polygon(rings[first][0], rings[second]) or _point_in_polygon(rings[second][0], rings[first]):
				return _result(
					STATUS_UNSUPPORTED_TOPOLOGY,
					rings,
					"Boolean output contains a hole or nested ring that V1 cannot represent.",
				)
	return _result(
		STATUS_MULTI_COMPONENT,
		rings,
		"Boolean output contains multiple disconnected components that V1 cannot store as one polygon.",
	)


static func _result(status: StringName, rings: Array, message := "") -> Dictionary:
	var snapshots: Array[PackedVector2Array] = []
	for ring: PackedVector2Array in rings:
		snapshots.append(ring.duplicate())
	var primary := PackedVector2Array()
	if status == STATUS_SINGLE and snapshots.size() == 1:
		primary = snapshots[0].duplicate()
	return {
		"status": status,
		"polygon": primary,
		"polygons": snapshots,
		"message": String(message),
	}


static func _simplify_closed_ring(ring: PackedVector2Array, tolerance: float) -> PackedVector2Array:
	if ring.size() <= 3:
		return ring.duplicate()
	# 从首点和最远点切成两条开放链，避免闭环首尾相同令 RDP 退化。
	var split_index := 1
	var farthest_distance := ring[0].distance_squared_to(ring[1])
	for index in range(2, ring.size()):
		var distance := ring[0].distance_squared_to(ring[index])
		if distance > farthest_distance:
			farthest_distance = distance
			split_index = index
	if split_index <= 0 or split_index >= ring.size():
		return ring.duplicate()
	var first_chain := PackedVector2Array()
	for index in range(split_index + 1):
		first_chain.append(ring[index])
	var second_chain := PackedVector2Array()
	for index in range(split_index, ring.size()):
		second_chain.append(ring[index])
	second_chain.append(ring[0])
	var first_simplified := _rdp_open(first_chain, tolerance)
	var second_simplified := _rdp_open(second_chain, tolerance)
	var result := first_simplified.duplicate()
	for index in range(1, second_simplified.size() - 1):
		result.append(second_simplified[index])
	return result


static func _rdp_open(points: PackedVector2Array, tolerance: float) -> PackedVector2Array:
	if points.size() <= 2:
		return points.duplicate()
	var furthest_index := -1
	var furthest_distance := -1.0
	for index in range(1, points.size() - 1):
		var distance := _distance_to_segment(points[index], points[0], points[points.size() - 1])
		if distance > furthest_distance:
			furthest_distance = distance
			furthest_index = index
	if furthest_distance <= tolerance or furthest_index < 0:
		return PackedVector2Array([points[0], points[points.size() - 1]])
	var left := PackedVector2Array()
	for index in range(furthest_index + 1):
		left.append(points[index])
	var right := PackedVector2Array()
	for index in range(furthest_index, points.size()):
		right.append(points[index])
	var left_result := _rdp_open(left, tolerance)
	var right_result := _rdp_open(right, tolerance)
	var result := left_result.duplicate()
	for index in range(1, right_result.size()):
		result.append(right_result[index])
	return result


static func _deduplicate_ring(points: PackedVector2Array, close_distance: float) -> PackedVector2Array:
	var result := PackedVector2Array()
	for point: Vector2 in points:
		if result.is_empty() or result[result.size() - 1].distance_squared_to(point) > POINT_EPSILON_SQUARED:
			result.append(point)
	if result.size() > 1:
		var snap_distance := maxf(close_distance, POINT_EPSILON)
		if result[0].distance_squared_to(result[result.size() - 1]) <= snap_distance * snap_distance:
			result.remove_at(result.size() - 1)
	return result


static func _rings_intersect(first: PackedVector2Array, second: PackedVector2Array) -> bool:
	for first_edge in range(first.size()):
		var first_end := (first_edge + 1) % first.size()
		for second_edge in range(second.size()):
			var second_end := (second_edge + 1) % second.size()
			if _segments_intersect(first[first_edge], first[first_end], second[second_edge], second[second_end]):
				return true
	return false


static func _segments_intersect(first_start: Vector2, first_end: Vector2, second_start: Vector2, second_end: Vector2) -> bool:
	var first_cross_start := (first_end - first_start).cross(second_start - first_start)
	var first_cross_end := (first_end - first_start).cross(second_end - first_start)
	var second_cross_start := (second_end - second_start).cross(first_start - second_start)
	var second_cross_end := (second_end - second_start).cross(first_end - second_start)
	if (
		((first_cross_start > CROSS_EPSILON and first_cross_end < -CROSS_EPSILON) or (first_cross_start < -CROSS_EPSILON and first_cross_end > CROSS_EPSILON))
		and ((second_cross_start > CROSS_EPSILON and second_cross_end < -CROSS_EPSILON) or (second_cross_start < -CROSS_EPSILON and second_cross_end > CROSS_EPSILON))
	):
		return true
	return (
		(absf(first_cross_start) <= CROSS_EPSILON and _point_on_segment(second_start, first_start, first_end))
		or (absf(first_cross_end) <= CROSS_EPSILON and _point_on_segment(second_end, first_start, first_end))
		or (absf(second_cross_start) <= CROSS_EPSILON and _point_on_segment(first_start, second_start, second_end))
		or (absf(second_cross_end) <= CROSS_EPSILON and _point_on_segment(first_end, second_start, second_end))
	)


static func _point_on_segment(point: Vector2, start: Vector2, finish: Vector2) -> bool:
	return (
		point.x >= minf(start.x, finish.x) - POINT_EPSILON
		and point.x <= maxf(start.x, finish.x) + POINT_EPSILON
		and point.y >= minf(start.y, finish.y) - POINT_EPSILON
		and point.y <= maxf(start.y, finish.y) + POINT_EPSILON
	)


static func _point_in_polygon(point: Vector2, polygon: PackedVector2Array) -> bool:
	var inside := false
	var previous := polygon.size() - 1
	for current in range(polygon.size()):
		var start := polygon[previous]
		var finish := polygon[current]
		if (start.y > point.y) != (finish.y > point.y):
			var crossing_x := (finish.x - start.x) * (point.y - start.y) / (finish.y - start.y) + start.x
			if point.x < crossing_x:
				inside = not inside
		previous = current
	return inside


static func _distance_to_segment(point: Vector2, start: Vector2, finish: Vector2) -> float:
	var segment := finish - start
	var length_squared := segment.length_squared()
	if length_squared <= POINT_EPSILON_SQUARED:
		return point.distance_to(start)
	var amount := clampf((point - start).dot(segment) / length_squared, 0.0, 1.0)
	return point.distance_to(start + segment * amount)


static func _signed_twice_area(ring: PackedVector2Array) -> float:
	var area := 0.0
	for index in range(ring.size()):
		area += ring[index].cross(ring[(index + 1) % ring.size()])
	return area


static func _all_finite(points: PackedVector2Array) -> bool:
	for point: Vector2 in points:
		if not point.is_finite():
			return false
	return true


static func _coerce_points(value: Variant) -> PackedVector2Array:
	if value is PackedVector2Array:
		return value.duplicate()
	var result := PackedVector2Array()
	if not value is Array:
		return result
	for item: Variant in value:
		if item is Vector2:
			result.append(item)
		elif item is Vector2i:
			result.append(Vector2(item))
		elif item is Array and item.size() == 2 and _finite_number(item[0]) and _finite_number(item[1]):
			result.append(Vector2(float(item[0]), float(item[1])))
		else:
			return PackedVector2Array()
	return result


static func _finite_number(value: Variant) -> bool:
	return (typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT) and is_finite(float(value))
