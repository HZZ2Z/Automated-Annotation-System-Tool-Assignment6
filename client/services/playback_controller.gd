class_name PlaybackController
extends RefCounted

var _times: Array[float] = []
var _nominal_fps := 0.0
var _accumulated_s := 0.0
var _playing := false


func configure(frames: Array, nominal_fps: float) -> PackedStringArray:
	pause()
	_times.clear()
	_nominal_fps = 0.0
	var errors := PackedStringArray()
	if frames.is_empty():
		errors.append("Playback frames must be a non-empty Array")
		return errors
	if not is_finite(nominal_fps) or nominal_fps <= 0.0:
		errors.append("Playback nominal_fps must be finite and positive")
		return errors
	var previous_time := -1.0
	for index in range(frames.size()):
		var value: Variant = frames[index]
		if not value is Dictionary:
			errors.append("Playback frame %d must be a Dictionary" % index)
			break
		var frame_value: Variant = value.get("frame")
		var time_value: Variant = value.get("time_s")
		if not _logical_integer(frame_value) or int(frame_value) != index:
			errors.append("Playback frame index must be contiguous at %d" % index)
			break
		if not _finite_non_negative(time_value):
			errors.append("Playback frame %d time_s must be finite and non-negative" % index)
			break
		var time_s := float(time_value)
		if time_s < previous_time:
			errors.append("Playback timestamps must be non-decreasing")
			break
		_times.append(time_s)
		previous_time = time_s
	if not errors.is_empty():
		_times.clear()
		return errors
	_nominal_fps = nominal_fps
	return errors


func play(current_frame: int) -> bool:
	_accumulated_s = 0.0
	if current_frame < 0 or current_frame >= _times.size() - 1 or _nominal_fps <= 0.0:
		_playing = false
		return false
	_playing = true
	return true


func pause() -> void:
	_playing = false
	_accumulated_s = 0.0


func tick(delta: float, current_frame: int) -> int:
	if not _playing:
		return -1
	if current_frame < 0 or current_frame >= _times.size() - 1:
		pause()
		return -1
	if is_finite(delta) and delta > 0.0:
		_accumulated_s += delta
	var interval := _times[current_frame + 1] - _times[current_frame]
	if not is_finite(interval) or interval <= 0.0:
		interval = 1.0 / _nominal_fps
	if _accumulated_s + 0.000000001 < interval:
		return -1
	# Discard excess elapsed time deliberately: slow loading slows playback instead
	# of causing a later tick to skip or catch up multiple explicit indices.
	_accumulated_s = 0.0
	return current_frame + 1


func is_playing() -> bool:
	return _playing


func _finite_non_negative(value: Variant) -> bool:
	return (typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT) \
		and is_finite(float(value)) and float(value) >= 0.0


func _logical_integer(value: Variant) -> bool:
	return (typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT) \
		and is_finite(float(value)) and float(value) == floorf(float(value))
