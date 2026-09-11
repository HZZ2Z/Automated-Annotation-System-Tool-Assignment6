class_name RegionMatchSolver
extends RefCounted

const GEOMETRY := preload("res://client/domain/region_geometry.gd")
const POLYGONS := preload("res://client/domain/polygon_ops.gd")
const MAX_GAP := 1.0
const BRIDGE_RADIUS := 0.5
const EPSILON := 0.00001


# 纯计算：只修改 A 的标签，或将 A 的几何并入 B；输入快照始终保持原样。
static func solve(record: Dictionary, source_id: String, reference_id: String, image_size: Vector2) -> Dictionary:
	var source_index := _index(record, source_id)
	var reference_index := _index(record, reference_id)
	if source_index < 0 or reference_index < 0 or source_id == reference_id:
		return _result(&"invalid", record, "请选择两个不同的已有区域")
	var a: Dictionary = record.regions[source_index]
	var b: Dictionary = record.regions[reference_index]
	for field: String in ["class", "kind"]:
		if typeof(b.get(field)) != TYPE_STRING or String(b[field]).is_empty():
			return _result(&"invalid", record, "参考区域的 class / kind 无效")
	var first := polygon_for_region(a)
	var second := polygon_for_region(b)
	if not POLYGONS.validate_simple_polygon(first) or not POLYGONS.validate_simple_polygon(second):
		return _relabel(record, source_index, b, "区域轮廓不是合法单环")
	if not GEOMETRY.fits_image(a, image_size) or not GEOMETRY.fits_image(b, image_size):
		return _relabel(record, source_index, b, "区域轮廓超出图像边界")
	var united := POLYGONS.union(first, second)
	if united.status == POLYGONS.STATUS_SINGLE:
		return _merged(record, source_index, reference_index, united.polygon, image_size)
	# 孔洞、自交和仅角点接触的并集不通过补缝修整，避免擅自修改真实边界。
	if united.status != POLYGONS.STATUS_MULTI_COMPONENT:
		return _relabel(record, source_index, b, "并集包含孔洞或不能保存为单环")
	var nearest := _nearest_pair(first, second)
	if float(nearest.distance) > MAX_GAP + EPSILON:
		return _relabel(record, source_index, b, "区域间距大于 1 个图像像素")
	var stroke := POLYGONS.stroke_polygon(PackedVector2Array([nearest.first, nearest.second]), BRIDGE_RADIUS)
	if stroke.status != POLYGONS.STATUS_SINGLE:
		return _relabel(record, source_index, b, "无法生成局部连接带")
	# 裁剪的对象只有连接带，原 A/B 不光栅化、不膨胀、不重描边。
	var clipped := Geometry2D.intersect_polygons(
		stroke.polygon, POLYGONS.box_to_polygon(Rect2(Vector2.ZERO, image_size)))
	if clipped.size() != 1 or not POLYGONS.validate_simple_polygon(clipped[0]):
		return _relabel(record, source_index, b, "图像边界处无法安全补缝")
	var bridge: PackedVector2Array = clipped[0]
	if _bridge_hits_other(record, source_index, reference_index, first, second, bridge):
		return _relabel(record, source_index, b, "补缝会侵入第三个区域")
	var connected := POLYGONS.union(first, bridge)
	if connected.status == POLYGONS.STATUS_SINGLE:
		connected = POLYGONS.union(connected.polygon, second)
	if connected.status != POLYGONS.STATUS_SINGLE:
		return _relabel(record, source_index, b, "补缝后仍不能保存为合法单环")
	return _merged(record, source_index, reference_index, connected.polygon, image_size)


static func polygon_for_region(region: Dictionary) -> PackedVector2Array:
	var polygon := GEOMETRY.polygon_points(region)
	return polygon if polygon.size() >= 3 else POLYGONS.box_to_polygon(region.get("box"))


static func polygon_area(points: PackedVector2Array) -> float:
	var twice := 0.0
	for index in range(points.size()):
		twice += points[index].cross(points[(index + 1) % points.size()])
	return absf(twice) * 0.5


static func _index(record: Dictionary, region_id: String) -> int:
	var regions: Variant = record.get("regions", [])
	if region_id.is_empty() or not regions is Array:
		return -1
	for index in range(regions.size()):
		if regions[index] is Dictionary and regions[index].get("id") == region_id:
			return index
	return -1


static func _nearest_pair(first: PackedVector2Array, second: PackedVector2Array) -> Dictionary:
	var result := {"distance": INF, "first": Vector2.ZERO, "second": Vector2.ZERO}
	var best_squared := INF
	# 已确认两环分离；最短距离必由一侧顶点到另一侧线段取得。
	for pass_index in range(2):
		var vertices := first if pass_index == 0 else second
		var edges := second if pass_index == 0 else first
		for vertex: Vector2 in vertices:
			for index in range(edges.size()):
				var closest := Geometry2D.get_closest_point_to_segment(vertex, edges[index], edges[(index + 1) % edges.size()])
				var squared := vertex.distance_squared_to(closest)
				if squared < best_squared:
					best_squared = squared
					result.first = vertex if pass_index == 0 else closest
					result.second = closest if pass_index == 0 else vertex
	result.distance = sqrt(best_squared)
	return result


static func _bridge_hits_other(
	record: Dictionary, source_index: int, reference_index: int,
	first: PackedVector2Array, second: PackedVector2Array, bridge: PackedVector2Array,
) -> bool:
	var bounds := POLYGONS.polygon_bounds(bridge)
	for index in range(record.regions.size()):
		if index in [source_index, reference_index]:
			continue
		var region: Dictionary = record.regions[index]
		if not bounds.intersects(GEOMETRY.image_bounds(region), true):
			continue
		var other := polygon_for_region(region)
		if not POLYGONS.validate_simple_polygon(other):
			return true
		# 此分支的 A/B 无面积重叠。只检查连接带新增面积，允许原有的重叠关系。
		for overlap: PackedVector2Array in Geometry2D.intersect_polygons(bridge, other):
			var added_area := polygon_area(overlap)
			for original: PackedVector2Array in [first, second]:
				for existing: PackedVector2Array in Geometry2D.intersect_polygons(overlap, original):
					added_area -= polygon_area(existing)
			if added_area > EPSILON:
				return true
	return false


static func _merged(record: Dictionary, source_index: int, reference_index: int, polygon: PackedVector2Array, image_size: Vector2) -> Dictionary:
	var b: Dictionary = record.regions[reference_index]
	if not POLYGONS.validate_simple_polygon(polygon) or not POLYGONS.points_fit_image(polygon, image_size):
		return _relabel(record, source_index, b, "合并轮廓无效或超出图像边界")
	var after := record.duplicate(true)
	var points: Array = []
	for point: Vector2 in polygon:
		points.append([point.x, point.y])
	after.regions[reference_index].erase("box")
	after.regions[reference_index]["polygon"] = points
	after.regions.remove_at(source_index)
	return _result(&"merged", after, "已将 %s 并入 %s；点击下一块待修正区域" % [record.regions[source_index].id, b.id])


static func _relabel(record: Dictionary, source_index: int, reference: Dictionary, reason: String) -> Dictionary:
	var after := record.duplicate(true)
	after.regions[source_index]["class"] = reference["class"]
	after.regions[source_index]["kind"] = reference["kind"]
	var prefix := "标签已一致" if after == record else "已同步 class / kind"
	return _result(&"relabeled", after, "%s；未合并：%s。点击下一块待修正区域" % [prefix, reason])


static func _result(status: StringName, record: Dictionary, message: String) -> Dictionary:
	return {"status": status, "record": record.duplicate(true), "message": message}
