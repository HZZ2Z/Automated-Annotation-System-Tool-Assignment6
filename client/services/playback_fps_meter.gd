class_name PlaybackFpsMeter
extends RefCounted

const WINDOW_USEC := 1_000_000

var _delivery_ticks_usec: Array[int] = []
var _running := false


func start(_started_at_usec: int) -> void:
	_delivery_ticks_usec.clear()
	_running = true


func stop() -> void:
	_running = false


func record_delivery(delivered_at_usec: int) -> bool:
	if not _running or delivered_at_usec < 0:
		return false
	if not _delivery_ticks_usec.is_empty() \
		and delivered_at_usec <= _delivery_ticks_usec[-1]:
		return false
	_delivery_ticks_usec.append(delivered_at_usec)
	_trim_window(delivered_at_usec)
	return true


func get_actual_fps() -> float:
	if not _running:
		return 0.0
	if _delivery_ticks_usec.size() < 2:
		return -1.0
	var elapsed_usec := _delivery_ticks_usec[-1] - _delivery_ticks_usec[0]
	if elapsed_usec <= 0:
		return -1.0
	return float(_delivery_ticks_usec.size() - 1) * 1_000_000.0 / float(elapsed_usec)


func _trim_window(latest_usec: int) -> void:
	var cutoff := latest_usec - WINDOW_USEC
	# Keep one sample before the window as an interval anchor. This also lets
	# deliberately slow clocks such as three seconds per frame report a cadence.
	while _delivery_ticks_usec.size() > 2 and _delivery_ticks_usec[1] < cutoff:
		_delivery_ticks_usec.pop_front()
