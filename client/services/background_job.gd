## Runs a pure-data callable on a worker. Owners must await completion before
## freeing this node; callables must not access the active SceneTree or live Store.
extends Node

signal progress(value: Dictionary)
signal finished(result: Dictionary)

const TOKEN := preload("res://client/services/job_token.gd")

var _thread: Thread
var _token: RefCounted
var _last_result: Dictionary = {}

func _ready() -> void:
	set_process(false)

## The worker receives arguments followed by its cancellation/progress token.
## Arguments must already be detached immutable snapshots (no large main-thread copy).
func start(work: Callable, arguments: Array = []) -> PackedStringArray:
	if is_running():
		return PackedStringArray(["A background task is already running"])
	if not work.is_valid():
		return PackedStringArray(["Background task callable is invalid"])
	_token = TOKEN.new()
	_last_result = {}
	var args := arguments.duplicate()
	args.append(_token)
	_thread = Thread.new()
	var error := _thread.start(work.callv.bind(args))
	if error != OK:
		_thread = null
		_token = null
		return PackedStringArray(["Cannot start background task: %s" % error_string(error)])
	set_process(true)
	return PackedStringArray()

func cancel() -> void:
	if _token != null:
		_token.cancel()

func is_running() -> bool:
	return _thread != null

func get_result() -> Dictionary:
	return _last_result.duplicate(true)

func _process(_delta: float) -> void:
	if _thread == null:
		set_process(false)
		return
	var update: Dictionary = _token.take_progress()
	if not update.is_empty():
		progress.emit(update)
	if _thread.is_alive():
		return
	# This join cannot wait on IO: is_alive() is already false.
	var result: Variant = _thread.wait_to_finish()
	_thread = null
	_token = null
	set_process(false)
	_last_result = result if result is Dictionary else {
		"success": false, "errors": ["Background task did not return a result object"]}
	finished.emit(_last_result)
