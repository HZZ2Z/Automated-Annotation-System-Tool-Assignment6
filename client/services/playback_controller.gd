class_name PlaybackController
extends RefCounted

const CLOCK_SOURCE_TIME := &"source_time"
const CLOCK_REVIEW := &"review"
const CLOCK_MAX := &"max"
const DEFAULT_REVIEW_FPS := 25.0

var _times: Array[float] = []
var _nominal_fps := 0.0
var _accumulated_s := 0.0
var _playing := false
var _clock_mode: StringName = CLOCK_SOURCE_TIME
var _review_fps := DEFAULT_REVIEW_FPS


func configure(frames: Array, nominal_fps: float) -> PackedStringArray:
	pause()
	_times.clear()
	_nominal_fps = 0.0
	_clock_mode = CLOCK_SOURCE_TIME
	_review_fps = DEFAULT_REVIEW_FPS
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


func set_clock(mode: StringName, review_fps: float = DEFAULT_REVIEW_FPS) -> PackedStringArray:
	var errors := PackedStringArray()
	if mode != CLOCK_SOURCE_TIME and mode != CLOCK_REVIEW and mode != CLOCK_MAX:
		errors.append("Playback clock mode must be source_time, review, or max")
	if mode == CLOCK_REVIEW and (
		not is_finite(review_fps) or review_fps <= 0.0
	):
		errors.append("Playback review FPS must be finite and positive")
	if not errors.is_empty():
		return errors
	pause()
	_clock_mode = mode
	if mode == CLOCK_REVIEW:
		_review_fps = review_fps
	return errors


func get_effective_fps(current_frame: int) -> float:
	if current_frame < 0 or current_frame >= _times.size():
		return 0.0
	var interval := _frame_interval(current_frame)
	return 1.0 / interval if is_finite(interval) and interval > 0.0 else 0.0


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
	if _clock_mode == CLOCK_MAX:
		_accumulated_s = 0.0
		return current_frame + 1
	if is_finite(delta) and delta > 0.0:
		_accumulated_s += delta
	var interval := _frame_interval(current_frame)
	if _accumulated_s + 0.000000001 < interval:
		return -1
	# Discard excess elapsed time deliberately: slow loading slows playback instead
	# of causing a later tick to skip or catch up multiple explicit indices.
	_accumulated_s = 0.0
	return current_frame + 1


func is_playing() -> bool:
	return _playing


func _frame_interval(current_frame: int) -> float:
	if _clock_mode == CLOCK_REVIEW:
		return 1.0 / _review_fps
	var interval := 0.0
	if current_frame >= 0 and current_frame < _times.size() - 1:
		interval = _times[current_frame + 1] - _times[current_frame]
	elif current_frame > 0 and current_frame < _times.size():
		interval = _times[current_frame] - _times[current_frame - 1]
	if not is_finite(interval) or interval <= 0.0:
		interval = 1.0 / _nominal_fps if _nominal_fps > 0.0 else 0.0
	return interval


func _finite_non_negative(value: Variant) -> bool:
	return (typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT) \
		and is_finite(float(value)) and float(value) >= 0.0


func _logical_integer(value: Variant) -> bool:
	return (typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT) \
		and is_finite(float(value)) and float(value) == floorf(float(value))
