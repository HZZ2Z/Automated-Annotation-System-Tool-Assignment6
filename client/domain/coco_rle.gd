class_name CocoRle
extends RefCounted

const MAX_MASK_PIXELS := 1048576
const MAX_SHIFT := 30


static func decode(segmentation: Dictionary) -> Dictionary:
	var size_value: Variant = segmentation.get("size")
	if not size_value is Array or size_value.size() != 2:
		return _failure("COCO RLE size must contain [height, width]")
	if not _logical_integer(size_value[0]) or not _logical_integer(size_value[1]):
		return _failure("COCO RLE size values must be integers")
	var height := int(size_value[0])
	var width := int(size_value[1])
	if width <= 0 or height <= 0:
		return _failure("COCO RLE size values must be positive")
	if width > MAX_MASK_PIXELS / height:
		return _failure("COCO RLE size exceeds the 1,048,576-pixel limit")
	var area := width * height
	var counts_value: Variant = segmentation.get("counts")
	if typeof(counts_value) != TYPE_STRING:
		return _failure("COCO RLE counts must be a compressed string")
	var text := String(counts_value)
	if text.is_empty():
		return _failure("COCO RLE counts total does not fill the declared size")

	var runs := PackedInt64Array()
	var cursor := 0
	var total := 0
	while cursor < text.length():
		var value := 0
		var shift := 0
		var more := true
		var code := 0
		while more:
			if cursor >= text.length() or shift > MAX_SHIFT:
				return _failure("COCO RLE count is truncated or exceeds 31 bits")
			code = text.unicode_at(cursor) - 48
			cursor += 1
			if code < 0 or code > 0x3f:
				return _failure("COCO RLE contains an invalid byte")
			value |= (code & 0x1f) << shift
			more = (code & 0x20) != 0
			shift += 5
		if (code & 0x10) != 0:
			value |= -1 << shift
		if runs.size() > 2:
			value += runs[runs.size() - 2]
		if value < 0:
			return _failure("COCO RLE contains a negative run length")
		if value > area - total:
			return _failure("COCO RLE run total exceeds the declared size")
		runs.append(value)
		total += value
	if total != area:
		return _failure("COCO RLE run total does not fill the declared size")

	var mask := PackedByteArray()
	mask.resize(area)
	var column_major_index := 0
	var foreground := false
	for run: int in runs:
		if foreground:
			for offset in range(run):
				var position := column_major_index + offset
				var x: int = position / height
				var y := position % height
				mask[y * width + x] = 1
		column_major_index += run
		foreground = not foreground
	return {"ok": true, "size": Vector2i(width, height), "mask": mask}


static func _logical_integer(value: Variant) -> bool:
	return (
		(typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT)
		and is_finite(float(value))
		and float(value) == floorf(float(value))
	)


static func _failure(message: String) -> Dictionary:
	return {"ok": false, "error": message}
