## 有界、逐帧执行的相似段扫描；像素经现有 Source 缓存访问。
class_name FrameSimilarityService
extends RefCounted

const METRIC_ID := "godot-rgb64-bilinear-mad-v1"
const MAX_FRAMES := 30
var result: Dictionary = {}
var running := false
var _source: Variant
var _store: Variant
var _entries: Array = []
var _anchor := PackedFloat32Array()
var _neighbor := PackedFloat32Array()
var _size := Vector2i.ZERO
var _direction := -1
var _next := -1
var _key := -1
var _threshold := 0.02

func begin(source: Variant, store: Variant, entries: Array, key: int, threshold: float) -> PackedStringArray:
	running = false
	result = {}
	if source == null or key < 0 or key >= entries.size() or not is_finite(threshold) or threshold <= 0.0 or threshold > 1.0:
		return PackedStringArray(["Select a source frame and a difference threshold in (0, 1]"])
	_source = source
	_store = store
	_entries = entries.duplicate(true)
	_key = key
	_threshold = threshold
	var image := _image(key)
	if image == null:
		return PackedStringArray(["Keyframe image could not be loaded"])
	_size = image.get_size()
	_anchor = grayscale(image)
	_neighbor = _anchor
	_direction = -1
	_next = key - 1
	result = {"key_index": key, "start_index": key, "end_index": key,
		"metric_id": METRIC_ID, "threshold": threshold, "max_frames": MAX_FRAMES,
		"left_stop": "", "right_stop": "", "scores": [], "errors": PackedStringArray()}
	running = true
	return PackedStringArray()

func step() -> void:
	if not running:
		return
	if _next < 0 or _next >= _entries.size():
		_stop("source boundary")
		return
	if int(result.end_index) - int(result.start_index) + 1 >= MAX_FRAMES:
		_stop("30-frame cap (truncated)")
		return
	var neighbor_index := _next - _direction
	var frame_id := int(_entries[_next].frame_id)
	if frame_id - int(_entries[neighbor_index].frame_id) != _direction:
		_stop("missing original frame ID")
		return
	if _store.has_method("is_verified") and _store.is_verified(frame_id):
		_stop("verified frame protected")
		return
	var image := _image(_next)
	if image == null:
		result.errors.append("Frame %d could not be loaded; analysis cancelled" % frame_id)
		running = false
		return
	if image.get_size() != _size:
		_stop("image dimensions changed")
		return
	var gray := grayscale(image)
	var adjacent := distance(gray, _neighbor)
	var anchor := distance(gray, _anchor)
	result.scores.append({"index": _next, "adjacent": adjacent, "anchor": anchor})
	if adjacent >= _threshold or anchor >= _threshold:
		_stop("difference %.6f / keyframe %.6f" % [adjacent, anchor])
		return
	result["start_index" if _direction < 0 else "end_index"] = _next
	_neighbor = gray
	_next += _direction

func cancel() -> void:
	running = false
	result = {}
	_source = null
	_store = null
	_entries.clear()
	_anchor.clear()
	_neighbor.clear()

func _stop(reason: String) -> void:
	result["left_stop" if _direction < 0 else "right_stop"] = reason
	if _direction < 0:
		_direction = 1
		_next = _key + 1
		_neighbor = _anchor
	else:
		running = false

func _image(index: int) -> Image:
	var actual: Dictionary = _source.get_frame_entry(index)
	actual["frame_id"] = int(actual.get("frame_id", actual.get("frame", -1)))
	if actual != _entries[index]:
		return null
	var texture: Variant = _source.load_texture(index)
	return texture.get_image() if texture is Texture2D else null

static func grayscale(image: Image) -> PackedFloat32Array:
	var small := image.duplicate() as Image
	small.convert(Image.FORMAT_RGB8)
	small.resize(64, 64, Image.INTERPOLATE_BILINEAR)
	var pixels := small.get_data()
	var values := PackedFloat32Array()
	values.resize(4096)
	for i in range(4096):
		values[i] = (0.299 * pixels[i * 3] + 0.587 * pixels[i * 3 + 1] + 0.114 * pixels[i * 3 + 2]) / 255.0
	return values

static func distance(left: PackedFloat32Array, right: PackedFloat32Array) -> float:
	var total := 0.0
	for i in range(left.size()):
		total += absf(left[i] - right[i])
	return total / float(left.size())
