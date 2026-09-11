extends SceneTree

const SUPPORT := preload("res://tests/godot/test_support.gd")
const STORE := preload("res://client/domain/annotation_store.gd")
const HISTORY := preload("res://client/domain/command_history.gd")
const CONTROLLER := preload("res://client/services/batch_controller.gd")

class MotionSource extends RefCounted:
	var entries: Array = []
	var images: Array[Image] = []
	var failed_index := -1
	var frame_step := 1
	func get_manifest() -> Dictionary:
		return {"frame_step": frame_step}
	func get_frame_entry(index: int) -> Dictionary:
		return entries[index].duplicate(true)
	func load_texture(index: int) -> Texture2D:
		if index == failed_index:
			return null
		return ImageTexture.create_from_image(images[index])

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	var s = SUPPORT.new()
	var batch = CONTROLLER.new()
	s.expect(batch.has_method("start_polygon_analysis"), "controller exposes polygon motion analysis")
	if batch.has_method("start_polygon_analysis"):
		await _end_to_end(s, batch)
		await _sampled_endoscapes_ids(s, batch)
	if s.failures.is_empty():
		print("PASS polygon batch integration")
		quit(0)
	else:
		printerr(s.failure_report())
		quit(1)

func _polygon(dx: int) -> Array:
	return [[30+dx,30],[80+dx,30],[80+dx,45],[48+dx,45],[48+dx,85],[30+dx,85]]

func _fixture(frame_step: int = 1, first_frame_id: int = 0) -> Dictionary:
	var source := MotionSource.new()
	source.frame_step = frame_step
	var records: Array = []
	for index in range(6):
		var frame_id := first_frame_id + index * frame_step
		source.entries.append({"frame": index, "frame_id": frame_id, "time_s": index * 0.04})
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
		records.append({"schema_version": 1, "source": "motion", "frame": frame_id, "time_s": index * 0.04,
			"regions": [{"id":"poly", "class":"grasper", "kind":"instrument", "track_id":"T1", "polygon":_polygon(8)},
				{"id":"unrelated", "class":"tissue", "kind":"anatomy", "box":[125,20,15,15]}]})
	var store = STORE.new()
	store.load_model_records(records)
	return {"source":source, "store":store, "records":records, "history":HISTORY.new()}

func _sampled_endoscapes_ids(s, batch) -> void:
	var f := _fixture(25, 29325)
	batch.configure(f.source, f.store, f.history, f.source.entries)
	batch._providers[&"polygon_flow"].service.job_root = "/tmp/poly-sampled-%d-%d" % [OS.get_process_id(),Time.get_ticks_usec()]
	s.expect_equal(batch.start_polygon_analysis(2, 1.0), PackedStringArray(),
		"sampled Poly starts at original frame 29375")
	await _finish(batch)
	var plan: Dictionary = batch.get_plan()
	s.expect(not plan.is_empty(), "sampled Poly returns a plan: %s" % batch.last_error)
	if not plan.is_empty():
		s.expect_equal(plan.get("frame_step"), 25, "sampled Poly carries frame_step through the worker")
		s.expect_equal(plan.get("end_index"), 5, "29375 to 29400 is not mistaken for a missing frame")
		s.expect(plan.get("target_regions", {}).has(29400), "proposal remains keyed by original frame 29400")
		s.expect_equal(batch.preview(2, 3, "merge").get("errors"), PackedStringArray(), "sampled Poly previews one target")
		s.expect_equal(batch.apply_preview(), PackedStringArray(), "sampled Poly applies one target")
		var operations: Array = f.store.snapshot_batch_operations()
		s.expect_equal(operations.size(), 1, "sampled Poly creates one audit marker")
		if operations.size() == 1:
			s.expect_equal(operations[0].get("frame_step"), 25, "sampled Poly audit stores source frame step")
	batch.cancel()

func _finish(batch) -> int:
	var started := Time.get_ticks_msec()
	var ticks := 0
	while batch.is_analyzing() and Time.get_ticks_msec() - started < 30000:
		batch.step_analysis()
		ticks += 1
		await create_timer(0.01).timeout
	return ticks

func _end_to_end(s, batch) -> void:
	var f := _fixture()
	batch.configure(f.source, f.store, f.history, f.source.entries)
	batch._providers[&"polygon_flow"].service.job_root = "/tmp/poly-integration-%d-%d" % [OS.get_process_id(),Time.get_ticks_usec()]
	s.expect_equal(batch.start_polygon_analysis(2, 1.0), PackedStringArray(), "poly analysis starts on a concave target")
	var ticks := await _finish(batch)
	var plan: Dictionary = batch.get_plan()
	s.expect(not batch.is_analyzing(), "background worker finishes within deadline")
	s.expect(ticks > 6, "main loop advances while Python analyzes")
	s.expect(not plan.is_empty(), "real Python produced a plan: %s" % batch.last_error)
	if plan.is_empty():
		batch.cancel()
		return
	s.expect_equal(plan.start_index, 0, "backward propagation reaches first frame")
	s.expect_equal(plan.end_index, 5, "forward propagation reaches last frame: %s" % plan.right_stop)
	if plan.start_index != 0 or plan.end_index != 5:
		batch.cancel()
		return
	s.expect(not batch.preview(-1,5,"merge").get("errors",[]).is_empty(), "preview range cannot expand beyond candidate")
	s.expect_equal(batch.preview(1,4,"merge").get("errors"), PackedStringArray(), "preview range may shrink while retaining keyframe")
	var overwrite: Dictionary = batch.preview(0,5,"overwrite")
	s.expect_equal(overwrite.get("errors"), PackedStringArray(), "poly overwrite preview validates")
	var overwritten: Dictionary = batch.proposed_record(5)
	s.expect_equal(overwritten.regions.size(), 1, "poly overwrite removes target-only regions")
	s.expect_equal(overwritten.regions[0].id, "poly", "poly overwrite keeps the propagated reference ID")
	var before_preview: Dictionary = f.store.freeze_snapshot()
	var preview: Dictionary = batch.preview(0,5,"merge")
	s.expect_equal(preview.get("errors"), PackedStringArray(), "motion preview validates")
	s.expect_equal(f.store.freeze_snapshot(), before_preview, "motion preview leaves records, reviews and revision untouched")
	var last: Dictionary = batch.proposed_record(5)
	s.expect(not last.is_empty(), "last frame has a distinct proposal")
	if last.is_empty():
		return
	var min_x := 1000.0
	for point: Array in last.regions[0].polygon:
		min_x = minf(min_x, point[0])
	s.expect(min_x > 46.0 and min_x < 54.0, "polygon follows 20-pixel motion, rather than copying keyframe x=38")
	s.expect(last.regions[0].polygon.size() > 4, "concavity is retained")
	s.expect_equal(last.regions[1], f.records[5].regions[1], "unrelated box remains unchanged")
	s.expect_equal(f.store.get_corrected_record(5), f.records[5], "preview leaves stored annotations unchanged")
	var reviews_before: Dictionary = f.store.snapshot_review_state()
	s.expect_equal(batch.apply_preview(), PackedStringArray(), "motion preview applies atomically")
	s.expect_equal(f.store.get_corrected_record(5), last, "committed result is exactly the preview")
	s.expect_equal(f.store.get_corrected_record(2), f.records[2], "manual keyframe vertices stay unchanged")
	s.expect_equal(f.history.get_undo_count(), 1, "one undo for all motion updates")
	s.expect(f.store.is_verified(5), "motion output is verified with its committed digest")
	var reviews_after: Dictionary = f.store.snapshot_review_state()
	s.expect(reviews_after.size() > reviews_before.size(), "Poly apply installs review state with annotations")
	var marker: Dictionary = f.store.snapshot_batch_operations()[0]
	s.expect_equal(marker.get("schema_version"), 2, "poly audit uses marker v2")
	s.expect_equal(marker.get("mode"), "merge", "poly audit preserves preview mode")
	s.expect(marker.get("edge_refinement", {}).get("attempted", 0) > 0, "poly audit contains bounded edge diagnostics")
	s.expect_equal(f.history.try_undo(f.store), PackedStringArray(), "undo motion batch")
	s.expect_equal(f.store.get_corrected_record(5), f.records[5], "undo restores original")
	s.expect_equal(f.store.snapshot_review_state(), reviews_before, "undo motion batch restores exact reviews")
	s.expect_equal(f.history.redo(f.store), PackedStringArray(), "redo motion batch")
	s.expect_equal(f.store.get_corrected_record(5), last, "redo restores exact per-frame polygon")
	s.expect_equal(f.store.snapshot_review_state(), reviews_after, "redo motion batch restores verified reviews")
	var validation_records := {}
	for frame: int in range(6):
		validation_records[frame] = f.store.get_corrected_record(frame)
	var state_errors: PackedStringArray = STORE.validate_workflow_state({}, f.store.snapshot_batch_operations(), validation_records)
	s.expect_equal(state_errors, PackedStringArray(), "motion audit fits existing persistence schema")
	var mapping := _fixture()
	batch.configure(mapping.source, mapping.store, mapping.history, mapping.source.entries)
	batch._providers[&"polygon_flow"].service.job_root = "/tmp/poly-mapping-%d-%d" % [OS.get_process_id(),Time.get_ticks_usec()]
	batch.start_polygon_analysis(2, 1.0)
	batch.step_analysis()
	batch.cancel()
	s.expect(not batch.is_analyzing() and batch.get_plan().is_empty(), "cancel discards snapshots and pending results")
	batch.start_polygon_analysis(2, 1.0)
	mapping.source.entries[1].time_s = 9.0
	await _finish(batch)
	s.expect(batch.get_plan().is_empty() and not batch.last_error.is_empty(), "changed Source mapping rejects analysis")
	var stale := _fixture()
	batch.configure(stale.source, stale.store, stale.history, stale.source.entries)
	batch._providers[&"polygon_flow"].service.job_root = "/tmp/poly-stale-apply-%d-%d" % [OS.get_process_id(),Time.get_ticks_usec()]
	batch.start_polygon_analysis(2, 1.0)
	await _finish(batch)
	var stale_plan: Dictionary = batch.get_plan()
	if not stale_plan.is_empty():
		batch.preview(stale_plan.start_index, stale_plan.end_index, "merge")
		stale.source.images[2].set_pixel(0, 0, Color.WHITE)
		s.expect(not batch.apply_preview().is_empty(), "source image mutation after preview blocks apply")
		s.expect_equal(stale.history.get_undo_count(), 0, "stale image leaves history untouched")
	batch.configure(null,null,null,[])
