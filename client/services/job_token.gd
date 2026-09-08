## Thread-safe cancellation and a bounded progress mailbox. Contains no UI objects.
extends RefCounted

var _mutex := Mutex.new()
var _cancelled := false
var _progress: Dictionary = {}

func cancel() -> void:
	_mutex.lock()
	_cancelled = true
	_mutex.unlock()

func is_cancelled() -> bool:
	_mutex.lock()
	var result := _cancelled
	_mutex.unlock()
	return result

func report_progress(value: Dictionary) -> void:
	var copy := value.duplicate(true)
	_mutex.lock()
	_progress = copy
	_mutex.unlock()

func take_progress() -> Dictionary:
	_mutex.lock()
	var result := _progress
	_progress = {}
	_mutex.unlock()
	return result
