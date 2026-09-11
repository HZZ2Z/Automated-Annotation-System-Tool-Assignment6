extends SceneTree

const SUPPORT := preload("res://tests/godot/test_support.gd")
const SOURCE := preload("res://client/plugins/source/image_sequence_source/plugin.gd")
const STORE := preload("res://client/domain/annotation_store.gd")
const HISTORY := preload("res://client/domain/command_history.gd")
const CONTROLLER_PATH := "res://client/services/batch_controller.gd"

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	var s = SUPPORT.new()
	s.expect(ResourceLoader.exists(CONTROLLER_PATH), "batch controller must implement the usable workflow")
	if ResourceLoader.exists(CONTROLLER_PATH):
		var script = load(CONTROLLER_PATH)
		if script != null and script.can_instantiate():
			_test_sample(s, script)
			_test_limits(s)
		else:
			s.expect(false, "batch controller must compile")
	if s.failures.is_empty():
		print("PASS batch workflow")
		quit(0)
	else:
		printerr(s.failure_report())
		quit(1)

func _test_sample(s, script) -> void:
	var source = SOURCE.new()
	s.expect_equal(source.open("res://sample/assignment_v1"), PackedStringArray(), "sample opens")
	var store = STORE.new()
	store.load_model_records(source.get_model_records())
	var history = HISTORY.new()
	var entries: Array = []
	for i in range(source.get_frame_count()):
		var entry: Dictionary = source.get_frame_entry(i)
		entry["frame_id"] = int(entry.get("frame_id", entry.frame))
		entries.append(entry)
	var batch = script.new()
	batch.configure(source, store, history, entries)
	s.expect_equal(batch.start_analysis(50, 0.02), PackedStringArray(), "analysis starts")
	var steps := 0
	while batch.is_analyzing() and steps < 100:
		batch.step_analysis()
		steps += 1
	var plan: Dictionary = batch.get_plan()
	s.expect_equal(plan.get("start_index"), 40, "left boundary excludes frame 39")
	s.expect_equal(plan.get("end_index"), 59, "right boundary excludes frame 60")
	var preview: Dictionary = batch.preview(40, 59, "overwrite")
	s.expect_equal(preview.get("changed_count"), 0, "original sample similar regions are already identical")
	s.expect(not batch.apply_preview().is_empty(), "no-op cannot create batch marker/history")
	s.expect_equal(history.get_undo_count(), 0, "no-op leaves history unchanged")
	var record: Dictionary = store.get_corrected_record(50)
	record.regions[0]["class"] = "batch-corrected"
	store.replace_corrected_record(50, record)
	s.expect(batch.get_plan().is_empty(), "editing invalidates pinned plan")
	batch.start_analysis(50, 0.02)
	while batch.is_analyzing():
		batch.step_analysis()
	preview = batch.preview(40, 59, "overwrite")
	s.expect_equal(preview.get("changed_count"), 19, "one correction reaches 19 targets")
	var before_apply: Dictionary = store.freeze_snapshot()
	s.expect_equal(store.get_corrected_record(40).regions[0]["class"], source.get_model_records()[40].regions[0]["class"], "preview is read-only")
	s.expect_equal(store.freeze_snapshot(), before_apply, "preview leaves records, reviews and revision untouched")
	batch.cancel()
	s.expect_equal(store.freeze_snapshot(), before_apply, "cancel leaves records, reviews and revision untouched")
	s.expect_equal(batch.start_analysis(50, 0.02), PackedStringArray(), "analysis restarts after transient preview cancellation")
	while batch.is_analyzing():
		batch.step_analysis()
	preview = batch.preview(40, 59, "overwrite")
	s.expect_equal(batch.apply_preview(), PackedStringArray(), "batch commits")
	s.expect_equal(store.freeze_snapshot().revision, int(before_apply.revision) + 1, "batch records and reviews increment revision once")
	s.expect_equal(history.get_undo_count(), 1, "batch is one history operation")
	s.expect_equal(store.get_corrected_record(59).regions[0]["class"], "batch-corrected", "right boundary corrected")
	for frame in range(40, 60):
		if frame != 50:
			s.expect(store.is_verified(frame), "changed target %d is verified atomically" % frame)
	s.expect_equal(store.get_corrected_record(60), source.get_model_records()[60], "outside untouched")
	var reviews_after: Dictionary = store.snapshot_review_state()
	s.expect_equal(history.try_undo(store), PackedStringArray(), "batch undo")
	s.expect_equal(store.get_corrected_record(59), source.get_model_records()[59], "undo restores boundary")
	s.expect_equal(store.snapshot_review_state(), before_apply.review_state, "undo restores exact review state")
	s.expect_equal(history.redo(store), PackedStringArray(), "batch redo")
	s.expect_equal(store.snapshot_review_state(), reviews_after, "redo restores exact verified review state")
	s.expect(not batch.preview(39, 59, "merge").get("errors", []).is_empty(), "range cannot expand")
	batch.configure(null, null, null, [])
	source.close()

class SyntheticSource extends RefCounted:
	var entries: Array = []
	var increment := 0.0
	var failed_index := -1
	var frame_step := 1
	func get_manifest() -> Dictionary:
		return {"frame_step": frame_step}
	func get_frame_entry(index: int) -> Dictionary:
		return entries[index].duplicate(true)
	func load_texture(index: int) -> Texture2D:
		if index == failed_index:
			return null
		var image := Image.create(8, 8, false, Image.FORMAT_RGB8)
		image.fill(Color(index * increment, index * increment, index * increment))
		return ImageTexture.create_from_image(image)

func _test_limits(s) -> void:
	var service = load("res://client/services/frame_similarity_service.gd").new()
	var source := SyntheticSource.new()
	var store = STORE.new()
	var records: Array = []
	for i in range(100):
		source.entries.append({"frame": i, "frame_id": i, "time_s": float(i)})
		records.append({"schema_version": 1, "frame": i, "source": "test", "time_s": float(i), "regions": []})
	store.load_model_records(records)
	service.begin(source, store, source.entries, 50, 0.02)
	while service.running:
		service.step()
	s.expect_equal(int(service.result.end_index) - int(service.result.start_index) + 1, 30, "long identical run is capped")
	s.expect("truncated" in service.result.left_stop or "truncated" in service.result.right_stop, "cap is explicitly reported")
	source.increment = 1.0 / 255.0
	service.begin(source, store, source.entries, 0, 0.02)
	while service.running:
		service.step()
	s.expect_equal(service.result.end_index, 5, "fixed anchor stops slow cumulative drift even with adjacent differences below threshold")
	var exact: float = service.distance(service.grayscale(source.load_texture(0).get_image()), service.grayscale(source.load_texture(1).get_image()))
	service.begin(source, store, source.entries, 0, exact)
	while service.running:
		service.step()
	s.expect_equal(service.result.end_index, 0, "equality to threshold stops the run")
	source.increment = 0.0
	source.entries[1].frame_id = 3
	service.begin(source, store, source.entries, 0, 0.02)
	while service.running:
		service.step()
	s.expect_equal(service.result.end_index, 0, "sparse original IDs stop propagation")
	s.expect_equal(service.result.right_stop, "missing original frame ID", "gap has clear reason")
	source.entries[1].frame_id = 1
	source.frame_step = 25
	for i in range(source.entries.size()):
		source.entries[i].frame_id = 29375 + i * 25
	service.begin(source, store, source.entries, 0, 0.02)
	while service.running:
		service.step()
	s.expect_equal(service.result.end_index, 29, "declared +25 sampling step is contiguous and still capped at 30 frames")
	s.expect("truncated" in service.result.right_stop, "sampled source reports the normal cap instead of a missing-ID stop")
	source.frame_step = 1
	for i in range(source.entries.size()):
		source.entries[i].frame_id = i
	var review = load("res://client/domain/commands/review_frames_command.gd").new([1], true)
	review.apply(store)
	service.begin(source, store, source.entries, 0, 0.02)
	while service.running:
		service.step()
	s.expect_equal(service.result.end_index, 0, "verified target protected")
	review.revert(store)
	source.failed_index = 1
	service.begin(source, store, source.entries, 0, 0.02)
	while service.running:
		service.step()
	s.expect(not service.result.errors.is_empty(), "failed frame cancels rather than silently truncating")
	service.cancel()
	s.expect(service.result.is_empty(), "cancel discards pending result")
