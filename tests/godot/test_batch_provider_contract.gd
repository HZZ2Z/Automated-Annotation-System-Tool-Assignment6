extends SceneTree

const SUPPORT := preload("res://tests/godot/test_support.gd")
const STORE := preload("res://client/domain/annotation_store.gd")
const BASE_PROVIDER := preload("res://client/services/batch_propagation_provider.gd")
const POLY_PROVIDER := preload("res://client/services/poly_batch_provider.gd")
const POLYGON_SERVICE := preload("res://client/services/polygon_propagation_service.gd")
const CONTROLLER := preload("res://client/services/batch_controller.gd")

class MotionSource extends RefCounted:
	var entries: Array = []
	var images: Array[Image] = []

	func get_frame_entry(index: int) -> Dictionary:
		return entries[index].duplicate(true)

	func load_texture(index: int) -> Texture2D:
		return ImageTexture.create_from_image(images[index])


class IncompleteProvider extends RefCounted:
	func provider_id() -> StringName: return &"incomplete"


func _initialize() -> void:
	call_deferred("run")


func run() -> void:
	var s = SUPPORT.new()
	_test_base_contract(s)
	await _test_poly_adapter(s)
	_test_controller_registration(s)
	_test_sam_adapter(s)
	if s.failures.is_empty():
		print("PASS batch propagation provider contract")
		quit(0)
	else:
		printerr(s.failure_report())
		quit(1)


func _test_base_contract(s) -> void:
	var provider = BASE_PROVIDER.new()
	s.expect_equal(provider.provider_id(), &"", "base provider has no strategy identity")
	s.expect_equal(provider.begin({}), PackedStringArray(["Provider is not implemented"]), "base provider refuses work")
	s.expect(not provider.availability().available, "base provider is unavailable")
	s.expect_equal(provider.get_result(), {}, "idle base does not publish a candidate")


func _test_poly_adapter(s) -> void:
	var f := _fixture()
	var expected_service = POLYGON_SERVICE.new()
	expected_service.job_root = "/tmp/poly-provider-baseline-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	s.expect_equal(expected_service.begin(f.source, f.store, f.source.entries, 2, 0.123), PackedStringArray(), "direct Poly baseline starts")
	await _finish(expected_service)
	var expected_regions: Array = expected_service.result.get("target_regions", {}).get(5, []).duplicate(true)
	s.expect(not expected_regions.is_empty(), "direct Poly baseline produced frame 5 candidates")
	expected_service.cancel()
	var provider = POLY_PROVIDER.new()
	provider.service.job_root = "/tmp/poly-provider-contract-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	var context := {"source": f.source, "store": f.store, "entries": f.source.entries,
		"key_index": 2, "region_id": "poly", "max_entries": 30, "similarity_threshold": 0.123}
	s.expect_equal(provider.provider_id(), &"polygon_flow", "adapter identifies the strategy")
	s.expect(provider.availability().available, "existing Poly worker remains available")
	s.expect_equal(provider.begin(context), PackedStringArray(), "adapter starts from common context")
	s.expect_equal(provider.get_result(), {}, "running provider must not publish partial results")
	s.expect_equal(provider.service._threshold, 0.123, "adapter forwards the visible similarity threshold")
	var started := Time.get_ticks_msec()
	while provider.is_running() and Time.get_ticks_msec() - started < 30000:
		provider.step()
		await create_timer(0.01).timeout
	var result: Dictionary = provider.get_result()
	s.expect(not provider.is_running(), "adapter finishes within the worker deadline")
	s.expect_equal(result.get("provider_id"), "polygon_flow", "result uses the common provider identity")
	s.expect_equal(result.get("target_regions", {}).get(5), expected_regions, "adapter preserves real Poly candidates")
	provider.cancel()


func _finish(worker) -> void:
	var started := Time.get_ticks_msec()
	while worker.running and Time.get_ticks_msec() - started < 30000:
		worker.step()
		await create_timer(0.01).timeout


func _test_controller_registration(s) -> void:
	var batch = CONTROLLER.new()
	s.expect(not batch.configure_provider(&"", BASE_PROVIDER.new()).is_empty(), "empty provider ID is rejected")
	s.expect(not batch.configure_provider(&" ", BASE_PROVIDER.new()).is_empty(), "whitespace-only provider ID is rejected")
	s.expect(not batch.configure_provider(&"incomplete", IncompleteProvider.new()).is_empty(), "incomplete provider is rejected")
	s.expect_equal(batch.configure_provider(&"test", BASE_PROVIDER.new()), PackedStringArray(), "complete provider registers")
	s.expect(not batch.configure_provider(&"test", BASE_PROVIDER.new()).is_empty(), "duplicate provider ID is rejected")
	s.expect(not batch.configure_provider(&"sam_video", BASE_PROVIDER.new()).is_empty(), "SAM is registered by default")
	if not batch.has_method("provider_availability") or not batch.has_method("step_provider_availability"):
		s.expect(false, "Controller exposes provider-neutral availability query and advancement")
		return
	for id in [&"", &" ", &"unknown", &"copy"]:
		for method in ["provider_availability", "step_provider_availability"]:
			var state: Dictionary = batch.call(method, id)
			s.expect(not state.get("available", true) and not str(state.get("reason", "")).is_empty(), "invalid availability ID is actionable: " + str(id))
	s.expect(batch.provider_availability(&" polygon_flow ").available, "availability uses registration ID normalization")
	s.expect(not batch.is_analyzing() and batch.get_plan().is_empty(), "availability does not create an analysis")


class FakeSamService extends RefCounted:
	var running := false
	var context: Dictionary = {}
	func preflight() -> Dictionary: return {"ok": false, "busy": false, "message": "fixture unavailable"}
	func begin(value: Dictionary, _source, _entries: Array, _mask: Dictionary) -> PackedStringArray:
		context = value.duplicate(true)
		running = true
		return PackedStringArray()
	func step() -> void: running = false
	func cancel() -> void: running = false
	func is_running() -> bool: return running
	func progress_text() -> String: return "fixture progress"
	func get_result() -> Dictionary: return {"errors": ["fixture model fault"]}
	func validate_source() -> PackedStringArray: return PackedStringArray(["fixture changed"])


func _test_sam_adapter(s) -> void:
	var path := "res://client/services/sam_video_batch_provider.gd"
	if not ResourceLoader.exists(path):
		s.expect(false, "SAM provider must exist and adapt the service")
		return
	var provider = load(path).new()
	provider.service = FakeSamService.new()
	s.expect_equal(provider.provider_id(), &"sam_video", "SAM strategy identity")
	s.expect_equal(provider.availability().reason, "fixture unavailable", "availability preserves actionable service reason")
	var context := {"key_index": 0, "region_id": "r", "propagation_count": 1,
		"entries": [{"frame_id": 0}, {"frame_id": 1}], "target_entries": [{"frame_id": 1}],
		"region": {"id": "r", "box": [1, 1, 3, 3]}, "session_snapshot": {}, "review_state": {},
		"service_context": {"session_id": "s"}}
	s.expect_equal(provider.begin(context), PackedStringArray(), "SAM lifecycle begins")
	s.expect_equal(provider.get_result(), {}, "SAM hides running result even if service exposes one")
	s.expect_equal(provider.progress_text(), "fixture progress", "SAM progress is observable")
	provider.step()
	var result: Dictionary = provider.get_result()
	s.expect_equal(result.get("provider_id"), "sam_video", "failed result retains SAM identity")
	s.expect(not result.has("store") and not result.has("history"), "SAM result has no Store/history capability")
	s.expect_equal(provider.validate_source(), PackedStringArray(["fixture changed"]), "SAM Source validation is retained")
	provider.cancel()
	s.expect_equal(provider.get_result(), {}, "cancel retires service result")


func _polygon(dx: int) -> Array:
	return [[30+dx,30],[80+dx,30],[80+dx,45],[48+dx,45],[48+dx,85],[30+dx,85]]


func _fixture() -> Dictionary:
	var source := MotionSource.new()
	var records: Array = []
	for index in range(6):
		source.entries.append({"frame": index, "frame_id": index, "time_s": index * 0.04})
		var image := Image.create(160, 120, false, Image.FORMAT_RGB8)
		var points := PackedVector2Array()
		for p: Array in _polygon(index * 4):
			points.append(Vector2(p[0], p[1]))
		for y in range(120):
			for x in range(160):
				var value := 0.06 + 0.025 * float((x / 8 + y / 8) % 2)
				if Geometry2D.is_point_in_polygon(Vector2(x, y), points):
					value = 0.45 + 0.4 * float(posmod((x-index*4)*31 + y*17, 37)) / 36.0
				image.set_pixel(x, y, Color(value, value, value))
		source.images.append(image)
		records.append({"schema_version": 1, "source": "motion", "frame": index, "time_s": index * 0.04,
			"regions": [{"id":"poly", "class":"grasper", "kind":"instrument", "track_id":"T1", "polygon":_polygon(8)},
				{"id":"unrelated", "class":"tissue", "kind":"anatomy", "box":[125,20,15,15]}]})
	var store = STORE.new()
	store.load_model_records(records)
	return {"source":source, "store":store}
