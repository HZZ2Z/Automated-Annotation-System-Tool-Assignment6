extends RefCounted

const TIMELINE_SCENE_PATH := "res://client/ui/timeline.tscn"


func run(support, tree: SceneTree) -> void:
	var packed := load(TIMELINE_SCENE_PATH) as PackedScene
	support.expect(packed != null, "Timeline scene should load")
	if packed == null:
		return
	var timeline := packed.instantiate() as Control
	timeline.set_anchors_preset(Control.PRESET_TOP_LEFT)
	timeline.size = Vector2(140, 60)
	tree.root.add_child(timeline)
	await tree.process_frame

	timeline.call("configure", 5)
	support.expect(timeline.call("set_current_frame", 2), "valid current frame should be accepted")
	support.expect(timeline.call("set_verified", 0, true), "frame zero should accept verified state")
	support.expect(timeline.call("set_verified", 2, true), "frame two should accept verified state")
	timeline.call("set_batch_ranges", [{"start_frame": 1, "end_frame": 3}])
	support.expect_equal(timeline.call("get_frame_state", 0), {"current": false, "verified": true, "in_batch": false}, "verified frame outside a batch should keep independent flags")
	support.expect_equal(timeline.call("get_frame_state", 1), {"current": false, "verified": false, "in_batch": true}, "unverified batch frame should expose both states")
	support.expect_equal(timeline.call("get_frame_state", 2), {"current": true, "verified": true, "in_batch": true}, "current, verified, and batch flags should overlay")
	support.expect_equal(timeline.call("get_frame_state", 4), {"current": false, "verified": false, "in_batch": false}, "default frame state should be unverified and outside batches")
	support.expect_equal(timeline.call("get_frame_state", -1), {}, "negative state lookup should be rejected")
	support.expect_equal(timeline.call("get_frame_state", 5), {}, "past-end state lookup should be rejected")
	var before: Dictionary = timeline.call("get_frame_state", 2)
	support.expect(not timeline.call("set_current_frame", -1), "negative current frame should be rejected")
	support.expect(not timeline.call("set_current_frame", 5), "past-end current frame should be rejected")
	support.expect(not timeline.call("set_verified", -1, true), "negative verified frame should be rejected")
	support.expect(not timeline.call("set_verified", 5, true), "past-end verified frame should be rejected")
	support.expect_equal(timeline.call("get_frame_state", 2), before, "invalid setters should not mutate timeline state")

	timeline.call("set_batch_ranges", [
		{"start_frame": -2, "end_frame": 1},
		{"start_frame": 4, "end_frame": 9},
		{"start_frame": -9, "end_frame": -2},
		{"start_frame": 9, "end_frame": 12},
		{"start_frame": 3, "end_frame": 2},
		{"start_frame": 2.5, "end_frame": 3},
		{"start": 1, "end": 3},
	])
	support.expect(timeline.call("get_frame_state", 0).get("in_batch"), "overlapping negative-start range should clamp to frame zero")
	support.expect(timeline.call("get_frame_state", 1).get("in_batch"), "clamped start range should include its valid end")
	support.expect(not timeline.call("get_frame_state", 2).get("in_batch"), "malformed and reversed ranges should be ignored")
	support.expect(timeline.call("get_frame_state", 4).get("in_batch"), "overlapping past-end range should clamp to the last frame")

	timeline.call("configure", 5)
	for index in range(5):
		var state: Dictionary = timeline.call("get_frame_state", index)
		support.expect_equal(state, {"current": index == 0, "verified": false, "in_batch": false}, "configure with the same count should reset frame state %d" % index)
	var scroll := timeline.get_node_or_null("ScrollBar") as HScrollBar
	support.expect(scroll != null, "Timeline should contain one horizontal scrollbar")
	if scroll != null:
		support.expect_equal(scroll.value, 0.0, "configure should reset scroll position")

	timeline.size = Vector2(100, 60)
	timeline.call("configure", 1000)
	await tree.process_frame
	scroll = timeline.get_node_or_null("ScrollBar") as HScrollBar
	if scroll != null:
		scroll.value = 137.0
	var requested: Array[int] = []
	timeline.frame_requested.connect(func(index: int): requested.append(index))
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	click.position = Vector2(2.0 * float(timeline.get("cell_width")) + 1.0, 5.0)
	timeline.call("_gui_input", click)
	support.expect_equal(requested, [139], "timeline click should include the horizontal scroll offset and emit an exact zero-based index")
	var frame_buttons := timeline.find_children("*", "Button", true, false)
	support.expect_equal(frame_buttons.size(), 0, "long timelines should remain one self-drawn control rather than create frame buttons")
	if timeline.has_method("get_visible_frame_indices"):
		support.expect_equal(timeline.call("get_visible_frame_indices", 90.0, 0.0), PackedInt32Array([0, 1, 2, 3, 4]), "exact five-cell width should draw exactly five indices")
		support.expect_equal(timeline.call("get_visible_frame_indices", 91.0, 0.0), PackedInt32Array([0, 1, 2, 3, 4, 5]), "non-integral width should include the one partially visible cell")
		support.expect_equal(timeline.call("get_visible_frame_indices", 90.0, NAN), PackedInt32Array(), "non-finite scroll offsets should return no visible indices safely")
		support.expect_equal(timeline.call("get_visible_frame_indices", 90.0, INF), PackedInt32Array(), "infinite scroll offsets should return no visible indices safely")
	else:
		support.expect(false, "Timeline should expose its visible-index calculation for exact boundary regression coverage")

	timeline.queue_free()
	await tree.process_frame
