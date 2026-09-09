## 单帧模型候选入口：只把 job 内、哈希一致的二值 ROI mask 转为安全 V1 Poly。
class_name ModelAssistCandidate
extends RefCounted

const MASK_OPS := preload("res://client/domain/mask_region_ops.gd")
const POLYGON_OPS := preload("res://client/domain/polygon_ops.gd")
const MAX_VERTICES := 2048
const MIN_RASTER_IOU := 0.99
const DESCRIPTOR_FIELDS := ["path", "roi", "score", "sha256"]


static func validate_file(
	job_dir: String,
	descriptor: Dictionary,
	image_size: Vector2i,
) -> Dictionary:
	if image_size.x <= 0 or image_size.y <= 0:
		return _refusal("Current image dimensions are invalid.")
	var fields: Array = descriptor.keys()
	fields.sort()
	if fields != DESCRIPTOR_FIELDS:
		return _refusal("Candidate descriptor has missing or unknown fields.")
	var score_value: Variant = descriptor.get("score")
	if not (score_value is int or score_value is float) or not is_finite(float(score_value)):
		return _refusal("Candidate score must be finite.")
	var roi_result := _roi(descriptor.get("roi"), image_size)
	if not roi_result.get("ok", false):
		return _refusal(roi_result.get("reason", "Candidate ROI is invalid."))
	var roi: Rect2i = roi_result["roi"]
	var digest: Variant = descriptor.get("sha256")
	if not digest is String or not _digest_valid(digest):
		return _refusal("Candidate SHA-256 must be lower-case hexadecimal.")
	var path_result := _candidate_path(job_dir, descriptor.get("path"))
	if not path_result.get("ok", false):
		return _refusal(path_result.get("reason", "Candidate path is invalid."))
	var path: String = path_result["path"]
	if FileAccess.get_sha256(path) != digest:
		return _refusal("Candidate file hash does not match its descriptor.")
	var source_bytes := FileAccess.get_file_as_bytes(path)
	if source_bytes.is_empty():
		return _refusal("Candidate PNG is empty or unreadable.")
	var image := Image.new()
	var load_error := image.load(path)
	if load_error != OK or image.is_empty():
		return _refusal("Candidate PNG could not be decoded.")
	if image.get_format() not in [Image.FORMAT_L8, Image.FORMAT_R8, Image.FORMAT_RGB8, Image.FORMAT_RGBA8]:
		return _refusal("Candidate PNG uses an unsupported pixel format.")
	if image.get_size() != roi.size:
		return _refusal("Candidate PNG dimensions do not match its ROI.")
	var mask_result := _binary_mask(image)
	if not mask_result.get("ok", false):
		return _refusal(mask_result.get("reason", "Candidate mask is not binary."))
	var mask: PackedByteArray = mask_result["mask"]
	var selected := 0
	for value: int in mask:
		if value != 0:
			selected += 1
	if selected == 0:
		return _refusal("Candidate mask is empty.")
	if roi == Rect2i(Vector2i.ZERO, image_size) and selected == image_size.x * image_size.y:
		return _refusal("Candidate mask selects the full image.")
	var state := {"roi": roi, "mask": mask}
	var candidate: Dictionary = MASK_OPS.to_v1_candidate(state)
	if not candidate.get("ok", false):
		return _refusal("Candidate cannot be represented as one V1 ring: %s" % candidate.get("message", "invalid topology"))
	var polygon: PackedVector2Array = candidate.get("polygon", PackedVector2Array())
	if polygon.size() > MAX_VERTICES:
		return _refusal("Candidate polygon exceeds the 2,048-vertex limit.")
	if not POLYGON_OPS.validate_simple_polygon(polygon):
		return _refusal("Candidate polygon is degenerate or self-intersecting.")
	if not POLYGON_OPS.points_fit_image(polygon, Vector2(image_size)):
		return _refusal("Candidate polygon leaves the current image.")
	var rerasterized: Dictionary = MASK_OPS.rasterize_polygon_mask(polygon, image_size)
	if not rerasterized.get("ok", false):
		return _refusal("Candidate polygon could not be re-rasterized safely.")
	var overlap := MASK_OPS.mask_iou(state, rerasterized)
	if overlap < MIN_RASTER_IOU:
		return _refusal("Candidate polygon raster round-trip IoU %.6f is below 0.99." % overlap)
	# Recheck immutable bytes after decode and geometry work to catch file swaps.
	if FileAccess.get_file_as_bytes(path) != source_bytes or FileAccess.get_sha256(path) != digest:
		return _refusal("Candidate file changed during validation.")
	return {
		"ok": true,
		"polygon": polygon.duplicate(),
		"mask": {"roi": roi, "mask": mask.duplicate()},
		"reason": "",
		"score": float(score_value),
	}


static func _binary_mask(source: Image) -> Dictionary:
	var image := source.duplicate()
	image.convert(Image.FORMAT_RGBA8)
	var bytes: PackedByteArray = image.get_data()
	var mask := PackedByteArray()
	mask.resize(image.get_width() * image.get_height())
	for index in range(mask.size()):
		var offset := index * 4
		var red: int = bytes[offset]
		var green: int = bytes[offset + 1]
		var blue: int = bytes[offset + 2]
		var alpha: int = bytes[offset + 3]
		if alpha != 255 or red != green or red != blue or red not in [0, 255]:
			return {"ok": false, "reason": "Candidate mask pixels must be opaque binary 0/255."}
		mask[index] = 1 if red == 255 else 0
	return {"ok": true, "mask": mask}


static func _roi(value: Variant, image_size: Vector2i) -> Dictionary:
	if not value is Array or value.size() != 4:
		return {"ok": false, "reason": "Candidate ROI must be [x, y, width, height]."}
	for coordinate: Variant in value:
		if not coordinate is int:
			return {"ok": false, "reason": "Candidate ROI coordinates must be integers."}
	var roi := Rect2i(int(value[0]), int(value[1]), int(value[2]), int(value[3]))
	if roi.position.x < 0 or roi.position.y < 0 or roi.size.x <= 0 or roi.size.y <= 0:
		return {"ok": false, "reason": "Candidate ROI must be positive and non-negative."}
	if roi.size.x > MASK_OPS.MAX_MASK_PIXELS / roi.size.y:
		return {"ok": false, "reason": "Candidate ROI exceeds the bounded mask limit."}
	var image_rect := Rect2i(Vector2i.ZERO, image_size)
	if roi.intersection(image_rect) != roi:
		return {"ok": false, "reason": "Candidate ROI leaves the current image."}
	return {"ok": true, "roi": roi}


static func _candidate_path(job_dir: String, path_value: Variant) -> Dictionary:
	var root := ProjectSettings.globalize_path(job_dir).simplify_path().trim_suffix("/")
	if root.is_empty() or root == "/" or not DirAccess.dir_exists_absolute(root) or _is_link(root):
		return {"ok": false, "reason": "Candidate job directory is invalid or symbolic."}
	if not path_value is String or path_value.is_empty() or path_value.is_absolute_path():
		return {"ok": false, "reason": "Candidate path must be a relative PNG path."}
	if path_value != path_value.simplify_path() or path_value.get_extension().to_lower() != "png":
		return {"ok": false, "reason": "Candidate path contains traversal or is not PNG."}
	var parts: PackedStringArray = path_value.split("/", false)
	if parts.is_empty():
		return {"ok": false, "reason": "Candidate path is empty."}
	var current := root
	for index in range(parts.size()):
		var part: String = parts[index]
		if part in ["", ".", ".."]:
			return {"ok": false, "reason": "Candidate path contains traversal."}
		var directory := DirAccess.open(current)
		if directory == null or directory.is_link(part):
			return {"ok": false, "reason": "Candidate path contains a symbolic link."}
		current = current.path_join(part)
		if index < parts.size() - 1 and not DirAccess.dir_exists_absolute(current):
			return {"ok": false, "reason": "Candidate path directory is missing."}
	if current.simplify_path().get_base_dir().begins_with(root + "/") or current.get_base_dir() == root:
		if FileAccess.file_exists(current) and not DirAccess.dir_exists_absolute(current):
			return {"ok": true, "path": current}
	return {"ok": false, "reason": "Candidate path is not a regular file inside the job directory."}


static func _digest_valid(value: String) -> bool:
	if value.length() != 64 or value != value.to_lower():
		return false
	for character: String in value:
		if character not in "0123456789abcdef":
			return false
	return true


static func _is_link(path: String) -> bool:
	var parent := DirAccess.open(path.get_base_dir())
	return parent != null and parent.is_link(path.get_file())


static func _refusal(reason: String) -> Dictionary:
	return {
		"ok": false,
		"polygon": PackedVector2Array(),
		"mask": {"roi": Rect2i(), "mask": PackedByteArray()},
		"reason": reason,
		"score": 0.0,
	}
