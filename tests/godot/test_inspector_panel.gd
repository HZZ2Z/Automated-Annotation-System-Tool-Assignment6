extends RefCounted


const SCENE_PATH := "res://client/ui/inspector_panel.tscn"


func run(support: TestSupport, tree: SceneTree) -> void:
	var packed: PackedScene = ResourceLoader.load(SCENE_PATH)
	support.expect(packed != null, "InspectorPanel scene should load")
	if packed == null:
		return
	await _test_empty_and_population_are_safe(packed, support, tree)
	await _test_deep_snapshot_and_request_signals(packed, support, tree)
	await _test_inspector_remains_intent_only(packed, support, tree)
	await _test_polygon_disables_box_geometry(packed, support, tree)
	await _test_malformed_population_recovers_cleanly(packed, support, tree)


func _test_empty_and_population_are_safe(packed: PackedScene, support: TestSupport, tree: SceneTree) -> void:
	var panel := packed.instantiate()
	tree.root.add_child(panel)
	await tree.process_frame
	support.expect_equal(panel.call("get_region_snapshot"), {}, "inspector should start with a safe empty snapshot")
	var emissions := [0]
	for signal_name in ["relabel_requested", "fill_requested", "geometry_requested", "track_id_requested"]:
		panel.connect(signal_name, func(_a = null, _b = null): emissions[0] += 1)
	panel.call("set_taxonomy", _taxonomy())
	panel.call("populate", _box_record())
	support.expect_equal(emissions[0], 0, "populate and taxonomy sync must not emit edit requests")
	support.expect_equal(panel.get_node("Fields/RegionId").text, "box-1", "region ID should populate read-only")
	support.expect_equal(panel.get_node("Fields/Kind").text, "instrument", "kind should populate read-only")
	support.expect_equal(panel.get_node("Fields/Confidence").text, "0.90", "confidence should populate read-only")
	for path in ["Fields/ClassTaxonomy", "Fields/ClassFreeText", "Fields/TrackId", "Fields/BoxX", "Fields/BoxY", "Fields/BoxWidth", "Fields/BoxHeight", "Fields/Fill"]:
		var control := panel.get_node(path) as Control
		support.expect_equal(control.focus_mode, Control.FOCUS_ALL, "%s should participate in normal keyboard focus" % path)
	support.expect(panel.get_node_or_null("Fields/Delete") == null,
		"Inspector must not expose a whole-region Delete button")
	support.expect_equal((panel.get_node("Fields/Fill") as CheckButton).text, "Show overlay fill",
		"Inspector visibility control must not be labeled as geometry Fill")
	panel.queue_free()
	await tree.process_frame


func _test_inspector_remains_intent_only(packed: PackedScene, support: TestSupport, tree: SceneTree) -> void:
	var panel := packed.instantiate()
	tree.root.add_child(panel)
	await tree.process_frame
	for signal_name: String in [
		"relabel_requested", "fill_requested", "geometry_requested", "track_id_requested",
	]:
		support.expect(panel.has_signal(signal_name),
			"Inspector should expose the existing %s edit intent" % signal_name)
	support.expect(not panel.has_signal("delete_requested"),
		"Inspector must not acquire whole-region deletion ownership")
	support.expect(not panel.has_method("undo") and not panel.has_method("redo"),
		"Inspector must not acquire command-history ownership")
	support.expect(panel.get_node_or_null("Fields/Delete") == null,
		"Inspector intent surface must retain no Delete control")
	panel.queue_free()
	await tree.process_frame


func _test_deep_snapshot_and_request_signals(packed: PackedScene, support: TestSupport, tree: SceneTree) -> void:
	var panel := packed.instantiate()
	tree.root.add_child(panel)
	await tree.process_frame
	panel.call("set_taxonomy", _taxonomy())
	var caller := _box_record()
	panel.call("populate", caller)
	caller["id"] = "mutated-id"
	caller["box"][0] = 99
	support.expect_equal(panel.call("get_region_snapshot").id, "box-1", "populate should retain a deep region snapshot")
	support.expect_equal(panel.call("get_region_snapshot").box[0], 10, "nested geometry should be isolated from caller mutation")

	var relabels: Array = []
	var fills: Array = []
	var geometries: Array = []
	var tracks: Array = []
	panel.relabel_requested.connect(func(id: String, label: String): relabels.append([id, label]))
	panel.fill_requested.connect(func(id: String, filled: bool): fills.append([id, filled]))
	panel.geometry_requested.connect(func(id: String, box: Array): geometries.append([id, box.duplicate(true)]))
	panel.track_id_requested.connect(func(id: String, value: Variant): tracks.append([id, value]))

	var free_text := panel.get_node("Fields/ClassFreeText") as LineEdit
	free_text.text = "  custom label  "
	free_text.text_submitted.emit(free_text.text)
	support.expect_equal(relabels, [["box-1", "  custom label  "]], "free-text relabel should preserve all non-empty input verbatim")
	free_text.text = ""
	free_text.text_submitted.emit("")
	support.expect_equal(relabels.size(), 1, "empty class should be rejected instead of emitting")
	support.expect(not panel.get_node("Status").text.is_empty(), "local validation refusal should be visible")

	var class_option := panel.get_node("Fields/ClassTaxonomy") as OptionButton
	class_option.item_selected.emit(1)
	support.expect_equal(relabels.back(), ["box-1", "scissors"], "taxonomy choice should request one relabel")
	var track := panel.get_node("Fields/TrackId") as LineEdit
	track.text = ""
	track.text_submitted.emit("")
	track.text = "  T-raw  "
	track.text_submitted.emit(track.text)
	support.expect_equal(tracks, [["box-1", null], ["box-1", "  T-raw  "]], "blank track input should map to null and non-empty input should remain verbatim")

	var fill := panel.get_node("Fields/Fill") as CheckButton
	fill.toggled.emit(true)
	support.expect_equal(fills, [["box-1", true]], "fill toggle should emit the requested target state")
	var width := panel.get_node("Fields/BoxWidth") as SpinBox
	width.value = 25
	support.expect_equal(geometries, [["box-1", [10.0, 10.0, 25.0, 15.0]]], "one numeric edit should emit one complete target box")
	panel.queue_free()
	await tree.process_frame


func _test_polygon_disables_box_geometry(packed: PackedScene, support: TestSupport, tree: SceneTree) -> void:
	var panel := packed.instantiate()
	tree.root.add_child(panel)
	await tree.process_frame
	panel.call("populate", {"id": "poly", "class": "gallbladder", "kind": "anatomy", "polygon": [[1, 1], [5, 1], [3, 4]], "filled": false})
	for path in ["Fields/BoxX", "Fields/BoxY", "Fields/BoxWidth", "Fields/BoxHeight"]:
		support.expect(panel.get_node(path).editable == false, "polygon selection should disable %s" % path)
	panel.call("populate", {"id": "hybrid", "class": "gallbladder", "kind": "anatomy", "box": [0, 0, 10, 10], "polygon": [[1, 1], [5, 1], [3, 4]]})
	for path in ["Fields/BoxX", "Fields/BoxY", "Fields/BoxWidth", "Fields/BoxHeight"]:
		support.expect(panel.get_node(path).editable == false, "polygon-first hybrid selection should disable fallback-box editing in %s" % path)
	support.expect_equal(panel.get_node("Status").text, "", "a schema-valid region with both geometries should not be reported as invalid")
	support.expect(panel.get_node("Fields/Fill").button_pressed, "a schema-valid region without filled should reflect its visible default overlay")
	panel.call("populate", _box_record())
	for path in ["Fields/BoxX", "Fields/BoxY", "Fields/BoxWidth", "Fields/BoxHeight"]:
		support.expect(panel.get_node(path).editable == true, "box selection should enable %s" % path)
	panel.queue_free()
	await tree.process_frame


func _test_malformed_population_recovers_cleanly(packed: PackedScene, support: TestSupport, tree: SceneTree) -> void:
	var panel := packed.instantiate()
	tree.root.add_child(panel)
	await tree.process_frame
	var request_count := [0]
	for signal_name in ["relabel_requested", "fill_requested", "geometry_requested", "track_id_requested"]:
		panel.connect(signal_name, func(_a = null, _b = null): request_count[0] += 1)
	var malformed_cases := [
		{"field": "box", "value": null, "geometry_editable": false},
		{"field": "box", "value": [1, 2, 3], "geometry_editable": false},
		{"field": "box", "value": [1, 2, null, 4], "geometry_editable": false},
		{"field": "box", "value": [1, 2, "wide", 4], "geometry_editable": false},
		{"field": "box", "value": [1, 2, NAN, 4], "geometry_editable": false},
		{"field": "box", "value": [1, 2, INF, 4], "geometry_editable": false},
		{"field": "filled", "value": "yes", "geometry_editable": true},
		{"field": "conf", "value": "high", "geometry_editable": true},
		{"field": "track_id", "value": 42, "geometry_editable": true},
	]
	for case: Dictionary in malformed_cases:
		var malformed := _box_record()
		malformed[case.field] = case.value
		panel.call("populate", malformed)
		support.expect_equal(panel.get_node("Fields/BoxWidth").editable, case.geometry_editable, "malformed %s should leave geometry in a deterministic enabled state" % case.field)
		support.expect(not panel.get_node("Status").text.is_empty(), "malformed %s should show a clear status" % case.field)
		if case.field == "filled":
			support.expect_equal(panel.get_node("Fields/Fill").button_pressed, false, "non-boolean filled should use a safe false fallback")
	support.expect_equal(request_count[0], 0, "malformed population must suppress every edit request")

	panel.call("populate", _box_record())
	support.expect(panel.get_node("Fields/BoxWidth").editable, "valid population after malformed input should restore geometry editing")
	support.expect_equal(panel.get_node("Status").text, "", "valid population after malformed input should clear validation status")
	panel.get_node("Fields/BoxWidth").value = 26
	support.expect_equal(request_count[0], 1, "signal wiring should recover after malformed population without a stuck syncing guard")
	panel.queue_free()
	await tree.process_frame


func _box_record() -> Dictionary:
	return {"id": "box-1", "class": "grasper", "kind": "instrument", "box": [10, 10, 20, 15], "conf": 0.9, "track_id": "T01", "filled": false}


func _taxonomy() -> Dictionary:
	return {"classes": [{"id": "grasper", "kind": "instrument"}, {"id": "scissors", "kind": "instrument"}]}
