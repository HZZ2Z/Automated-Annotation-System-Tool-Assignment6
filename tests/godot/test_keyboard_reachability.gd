extends SceneTree


const PLUGIN_SCRIPT := preload("res://client/plugins/edit/basic_edit_tools/plugin.gd")
const STORE_SCRIPT := preload("res://client/domain/annotation_store.gd")
const HISTORY_SCRIPT := preload("res://client/domain/command_history.gd")
const TRANSFORM_SCRIPT := preload("res://client/services/viewport_transform.gd")
const POLYGON_OPS := preload("res://client/domain/polygon_ops.gd")


class ViewportProbe extends RefCounted:
	signal edit_cancel_requested

	var records: Array[Dictionary] = []
	var selected_ids: Array[String] = []
	var overlays: Array[Dictionary] = []
	var transform = TRANSFORM_SCRIPT.new()
	var current_image: Image

	func _init(image: Image) -> void:
		current_image = image
		transform.configure(
			Vector2(image.get_width(), image.get_height()),
			Rect2(0, 0, 200, 160),
		)

	func set_record(record: Dictionary) -> void:
		records.append(record.duplicate(true))

	func set_selected_region_id(region_id: String) -> void:
		selected_ids.append(region_id)

	func get_image_transform():
		return transform

	func get_current_image() -> Image:
		return current_image

	func set_edit_overlay(state: Dictionary) -> void:
		overlays.append(state.duplicate(true))

	func clear_edit_overlay() -> void:
		overlays.append({})


var _failures: Array[String] = []


func _init() -> void:
	call_deferred("_run_tests")


func _run_tests() -> void:
	_test_navigation_and_direct_shortcuts()
	_test_keyboard_lasso_and_spatial_steps()
	_test_keyboard_subtract()
	_test_keyboard_subtract_refusal_can_be_corrected()
	_test_keyboard_paint()
	_test_keyboard_eraser()
	_test_escape_cancels_every_keyboard_spatial_mode()
	_test_history_shortcuts_are_main_owned()
	if _failures.is_empty():
		print("PASS: keyboard-only edit reachability")
		quit(0)
		return
	push_error("FAIL: keyboard-only edit reachability\n%s" % "\n".join(_failures))
	quit(1)


func _test_navigation_and_direct_shortcuts() -> void:
	var navigation := _fixture()
	if not _activate(navigation, "navigation shortcuts"):
		return
	var before: Dictionary = navigation.store.get_corrected_record(0)
	_expect(
		not navigation.plugin.handle_key(_key(KEY_TAB)),
		"Tab must remain unconsumed when no edit gesture is active so standard focus traversal works",
	)
	_expect_equal(navigation.store.get_corrected_record(0), before, "unconsumed Tab must not mutate Store")
	_expect_equal(navigation.history.get_undo_count(), 0, "unconsumed Tab must not create history")
	_expect(navigation.plugin.handle_key(_key(KEY_BRACKETRIGHT)), "] should cycle selection forward")
	_expect_equal(navigation.selected[0], "box-1", "] should select the first region from an empty selection")
	_expect(navigation.plugin.handle_key(_key(KEY_BRACKETRIGHT)), "] should cycle to the next region")
	_expect_equal(navigation.selected[0], "notch-1", "] should select the next region")
	_expect(navigation.plugin.handle_key(_key(KEY_BRACKETLEFT)), "[ should cycle selection backward")
	_expect_equal(navigation.selected[0], "box-1", "[ should return to the previous region")
	navigation.plugin.set_active_tool(&"lasso")
	_expect(navigation.plugin.handle_key(_key(KEY_V)), "V should activate Selection")
	_expect_equal(navigation.plugin.get_active_tool(), &"select", "V must make Selection authoritative")

	var added := _fixture()
	if _activate(added, "keyboard Box"):
		var count_before: int = added.store.get_corrected_record(0).regions.size()
		_expect(added.plugin.handle_key(_key(KEY_A)), "A should begin keyboard-only Box creation")
		_expect_equal(added.plugin.get_active_tool(), &"box", "A should also make Add Box the visible active tool")
		_expect(added.plugin.handle_key(_key(KEY_RIGHT)), "plain arrow should move the keyboard Box by one pixel")
		_expect(added.plugin.handle_key(_key(KEY_DOWN, true)), "Shift+arrow should move the keyboard Box by five pixels")
		_expect(added.plugin.handle_key(_key(KEY_ENTER)), "Enter should finish the keyboard Box geometry")
		_expect_equal(added.store.get_corrected_record(0).regions.size(), count_before,
			"A then Enter must keep the Box pending before class assignment")
		_expect_equal(added.history.get_undo_count(), 0,
			"pending keyboard Box must create no command")
		_expect_equal(_overlay(added).get("phase"), &"awaiting_class",
			"keyboard Box geometry must remain visible while awaiting class")
		var request: Dictionary = added.plugin.get("_session").pending_request()
		var confirm_errors: PackedStringArray = added.plugin.invoke(&"confirm_pending_region", {
			"candidate_token": request.get("candidate_token"),
			"class": "keyboard class",
			"kind": "free kind",
		})
		_expect(confirm_errors.is_empty(), "explicit keyboard Box class confirmation should succeed")
		_expect_equal(added.store.get_corrected_record(0).regions.size(), count_before + 1, "A then Enter should add one real region")
		_expect_equal(added.history.get_undo_count(), 1, "one keyboard Box gesture should create exactly one command")

	var filled := _fixture()
	if _activate(filled, "keyboard Fill"):
		var fill_before: Dictionary = _with_fill_boundaries(filled.store.get_corrected_record(0))
		filled.store.replace_corrected_record(0, fill_before)
		_expect(filled.plugin.handle_key(_key(KEY_F)), "F should enter standalone keyboard Fill")
		_press(filled, KEY_RIGHT, true, true)
		_press(filled, KEY_RIGHT, true, true)
		_press(filled, KEY_RIGHT, true)
		_press(filled, KEY_DOWN, true, true)
		_press(filled, KEY_DOWN, true, true)
		_expect(filled.plugin.handle_key(_key(KEY_ENTER)), "Enter should fill the enclosed blank area at the keyboard seed")
		_expect_equal(filled.store.get_corrected_record(0).regions.size(), fill_before.regions.size(), "keyboard Fill must remain pending before class assignment")
		_expect_equal(filled.class_requests.size(), 1, "keyboard Fill must request class assignment exactly once")
		_expect(_confirm_pending_polygon(filled, "keyboard fill", "fill kind").is_empty(), "keyboard Fill class confirmation should succeed")
		var fill_after: Dictionary = filled.store.get_corrected_record(0)
		_expect_equal(fill_after.regions.size(), fill_before.regions.size() + 1, "keyboard Fill should add exactly one real region")
		var fill_added: Dictionary = fill_after.regions.back() if fill_after.regions.size() == fill_before.regions.size() + 1 else {}
		_expect_equal(POLYGON_OPS.polygon_bounds(_polygon_from_value(fill_added.get("polygon", []))), Rect2(68, 53, 19, 17),
			"keyboard Fill should commit the connected enclosed blank component containing the moved seed")
		_expect_equal(_find_region(fill_after, "box-1").get("filled"), false,
			"toolbar/keyboard Fill must not change the existing region's overlay visibility")
		_expect_equal(filled.history.get_undo_count(), 1, "keyboard Fill should create exactly one AddPolygon command")

	var no_close := _fixture()
	if _activate(no_close, "removed keyboard Close Gaps"):
		var close_before: Dictionary = no_close.store.get_corrected_record(0)
		_expect(not no_close.plugin.handle_key(_key(KEY_C)), "C must be unbound after Close Gaps removal")
		_expect_equal(no_close.store.get_corrected_record(0), close_before, "unbound C must preserve Store")
		_expect_equal(no_close.history.get_undo_count(), 0, "unbound C must preserve History")

	var delete_before: Dictionary = navigation.store.get_corrected_record(0)
	_expect(not navigation.plugin.handle_key(_key(KEY_E)), "E must have no editing binding")
	_expect(not navigation.plugin.handle_key(_key(KEY_G)), "G must be unbound after Region Growing removal")
	_expect(not navigation.plugin.handle_key(_key(KEY_I)), "I must be unbound after Live Wire removal")
	_expect_equal(navigation.store.get_corrected_record(0), delete_before, "unbound E must not mutate Store")
	_expect_equal(navigation.history.get_undo_count(), 0, "unbound E must not create history")

	for deletion_key: Key in [KEY_DELETE, KEY_BACKSPACE]:
		var deleted := _fixture()
		deleted.selected[0] = "box-1"
		if not _activate(deleted, "keyboard deletion %s" % deletion_key):
			continue
		var count_before: int = deleted.store.get_corrected_record(0).regions.size()
		_expect(deleted.plugin.handle_key(_key(deletion_key)), "%s should delete the selected region" % deletion_key)
		_expect_equal(deleted.store.get_corrected_record(0).regions.size(), count_before - 1, "%s must remove exactly one selected region" % deletion_key)
		_expect_equal(deleted.history.get_undo_count(), 1, "%s should create exactly one delete command" % deletion_key)


func _test_history_shortcuts_are_main_owned() -> void:
	var fixture := _fixture()
	fixture.selected[0] = "box-1"
	if not _activate(fixture, "Main-owned history shortcuts"):
		return
	_expect(fixture.plugin.handle_key(_key(KEY_RIGHT)), "fixture arrow should create one real spatial command")
	var expected_record: Dictionary = fixture.store.get_corrected_record(0)
	for history_event: InputEventKey in [
		_key(KEY_Z, false, true),
		_key(KEY_Z, true, true),
		_key(KEY_Y, false, true),
	]:
		_expect(not fixture.plugin.handle_key(history_event),
			"plugin must not consume a normal Main-owned history shortcut")
		_expect_equal(fixture.store.get_corrected_record(0), expected_record,
			"plugin-level history shortcut must preserve Store")
		_expect_equal(fixture.history.get_undo_count(), 1,
			"plugin-level history shortcut must preserve undo history")
		_expect_equal(fixture.history.get_redo_count(), 0,
			"plugin-level history shortcut must preserve redo history")


func _test_keyboard_lasso_and_spatial_steps() -> void:
	var fixture := _fixture()
	if not _activate(fixture, "keyboard Lasso"):
		return
	fixture.selected[0] = ""
	var count_before: int = fixture.store.get_corrected_record(0).regions.size()
	_expect(fixture.plugin.handle_key(_key(KEY_L)), "L should enter keyboard Lasso spatial mode")
	_expect_equal(fixture.plugin.get_active_tool(), &"lasso", "L should activate the real Lasso tool")
	# Starting at image centre (50, 40), these literal steps draw a 16 x 5 rectangle.
	_press(fixture, KEY_RIGHT)
	_press(fixture, KEY_RIGHT, true)
	_press(fixture, KEY_RIGHT, true, true)
	_press(fixture, KEY_DOWN, true)
	_press(fixture, KEY_LEFT, true, true)
	_press(fixture, KEY_LEFT, true)
	_press(fixture, KEY_LEFT)
	var open_record: Dictionary = fixture.store.get_corrected_record(0)
	_expect(fixture.plugin.handle_key(_key(KEY_ENTER)), "an active keyboard Lasso should safely consume Enter")
	_expect_equal(fixture.class_requests.size(), 0, "Enter must not close keyboard Lasso")
	_expect_equal(fixture.store.get_corrected_record(0), open_record, "Enter must preserve an open keyboard Lasso")
	_expect(fixture.plugin.handle_key(_key(KEY_SPACE)), "Space should commit keyboard Lasso")
	_expect_equal(fixture.store.get_corrected_record(0).regions.size(), count_before, "keyboard Lasso must remain pending before class assignment")
	_expect_equal(fixture.class_requests.size(), 1, "keyboard Lasso must request class assignment exactly once")
	_expect(_confirm_pending_polygon(fixture, "keyboard lasso", "lasso kind").is_empty(), "keyboard Lasso class confirmation should succeed")
	var after: Dictionary = fixture.store.get_corrected_record(0)
	_expect_equal(after.regions.size(), count_before + 1, "keyboard Lasso should add exactly one region")
	var polygon := _polygon_from_value(after.regions.back().get("polygon", []))
	_expect_equal(POLYGON_OPS.polygon_bounds(polygon), Rect2(50, 40, 16, 5), "plain, Shift, and Ctrl+Shift arrows must move the spatial path by 1, 5, and 10 image pixels")
	_expect(POLYGON_OPS.validate_simple_polygon(polygon), "keyboard Lasso must commit one simple V1 polygon")
	_expect_equal(polygon, PackedVector2Array([
		Vector2(50, 40), Vector2(66, 40), Vector2(66, 45), Vector2(50, 45),
	]), "keyboard Space should explicitly close the open path without endpoint proximity")
	_expect_equal(fixture.history.get_undo_count(), 1, "one keyboard Lasso should create exactly one command")
	var added_id := str(after.regions.back().get("id", ""))
	_expect(not added_id.is_empty(), "keyboard Lasso should allocate one non-empty region ID")
	var expected_after := _record()
	expected_after.regions[0]["filled"] = false
	expected_after.regions.append({
		"id": added_id,
		"class": "keyboard lasso",
		"kind": "lasso kind",
		"polygon": [[50.0, 40.0], [66.0, 40.0], [66.0, 45.0], [50.0, 45.0]],
		"track_id": null,
	})
	_expect(fixture.history.undo(fixture.store), "keyboard Lasso should undo")
	var expected_before := _record()
	expected_before.regions[0]["filled"] = false
	_expect_equal(fixture.store.get_corrected_record(0), expected_before, "keyboard Lasso undo should restore the independent original record")
	_expect_equal(fixture.history.redo(fixture.store), PackedStringArray(), "keyboard Lasso should redo")
	_expect_equal(fixture.store.get_corrected_record(0), expected_after, "keyboard Lasso redo should restore the independently expected polygon record")


func _test_keyboard_subtract() -> void:
	var fixture := _fixture()
	fixture.selected[0] = "box-1"
	if not _activate(fixture, "keyboard Subtract"):
		return
	var before := _region_polygon(fixture.store.get_corrected_record(0), "box-1")
	_expect(fixture.plugin.handle_key(_key(KEY_S)), "S should enter keyboard Subtract spatial mode")
	# From the selected box centre, draw a contour that removes its right half.
	_press(fixture, KEY_UP, true, true)
	_press(fixture, KEY_RIGHT, true, true)
	_press(fixture, KEY_RIGHT, true)
	_press(fixture, KEY_DOWN, true, true)
	_press(fixture, KEY_DOWN, true, true)
	_press(fixture, KEY_LEFT, true, true)
	_press(fixture, KEY_LEFT, true)
	var open_record: Dictionary = fixture.store.get_corrected_record(0)
	_expect(fixture.plugin.handle_key(_key(KEY_ENTER)), "an active keyboard Subtract should safely consume Enter")
	_expect_equal(fixture.history.get_undo_count(), 0, "Enter must not close keyboard Subtract")
	_expect_equal(fixture.store.get_corrected_record(0), open_record, "Enter must preserve an open keyboard Subtract")
	_expect(fixture.plugin.handle_key(_key(KEY_SPACE)), "Space should commit keyboard Subtract")
	var after := _region_polygon(fixture.store.get_corrected_record(0), "box-1")
	_expect(POLYGON_OPS.validate_simple_polygon(after), "keyboard Subtract must leave one V1-safe ring")
	_expect(_absolute_area(after) < _absolute_area(before), "keyboard Subtract should remove area from the selected region")
	_expect_equal(POLYGON_OPS.polygon_bounds(after), Rect2(20, 20, 10, 20), "keyboard Subtract should remove the hand-drawn right half only")
	_expect_equal(fixture.history.get_undo_count(), 1, "one keyboard Subtract should create exactly one command")
	var expected_after := _record()
	expected_after.regions[0]["filled"] = false
	expected_after.regions[0].erase("box")
	expected_after.regions[0]["polygon"] = [[30.0, 20.0], [30.0, 40.0], [20.0, 40.0], [20.0, 20.0]]
	_expect_equal(fixture.store.get_corrected_record(0), expected_after, "keyboard Subtract should commit the independently expected record")
	_expect(fixture.history.undo(fixture.store), "keyboard Subtract should undo")
	var expected_before := _record()
	expected_before.regions[0]["filled"] = false
	_expect_equal(fixture.store.get_corrected_record(0), expected_before, "keyboard Subtract undo should restore the independent original record")
	_expect_equal(fixture.history.redo(fixture.store), PackedStringArray(), "keyboard Subtract should redo")
	_expect_equal(fixture.store.get_corrected_record(0), expected_after, "keyboard Subtract redo should restore the independently expected record")


func _test_keyboard_subtract_refusal_can_be_corrected() -> void:
	var fixture := _fixture()
	fixture.selected[0] = "box-1"
	if not _activate(fixture, "keyboard Subtract correction"):
		return
	var expected_before := _record()
	expected_before.regions[0]["filled"] = false
	_expect(fixture.plugin.handle_key(_key(KEY_S)), "S should begin the retryable keyboard Subtract")
	# A 5 x 5 ring wholly inside the subject would create a V1-inexpressible hole.
	_press(fixture, KEY_RIGHT, true)
	_press(fixture, KEY_DOWN, true)
	_press(fixture, KEY_LEFT, true)
	_expect(fixture.plugin.handle_key(_key(KEY_SPACE)), "Space should attempt the hole subtraction")
	var invalid: Dictionary = fixture.viewport.overlays.back()
	var session: Variant = fixture.plugin.get("_session")
	_expect_equal(invalid.get("phase"), &"invalid", "keyboard hole refusal should remain Invalid")
	_expect_equal(invalid.get("path"), PackedVector2Array([
		Vector2(30, 30), Vector2(35, 30), Vector2(35, 35), Vector2(30, 35),
	]), "keyboard hole refusal should retain its exact open contour")
	_expect_equal(invalid.get("candidate_polygon"), PackedVector2Array([
		Vector2(30, 30), Vector2(35, 30), Vector2(35, 35), Vector2(30, 35),
	]), "keyboard hole refusal should retain a filled red candidate")
	_expect_equal(invalid.get("fill_color"), Color("#ef4444"), "keyboard hole refusal should remain red")
	_expect(not String(invalid.get("message", "")).is_empty(), "keyboard hole refusal should retain an explanation")
	_expect_equal(session.before, expected_before, "keyboard hole refusal should retain the exact frozen Store snapshot")
	_expect_equal(session.region_id, "box-1", "keyboard hole refusal should retain the frozen target")
	_expect_equal(fixture.plugin.get("_keyboard_tool"), &"subtract", "keyboard hole refusal should remain in Subtract correction mode")
	_expect_equal(fixture.plugin.get("_keyboard_before"), expected_before, "keyboard correction state should retain the exact original record")
	_expect_equal(fixture.plugin.get("_keyboard_region_id"), "box-1", "keyboard correction state should retain the target")
	_expect_equal(fixture.store.get_corrected_record(0), expected_before, "keyboard hole refusal must preserve Store")
	_expect_equal(fixture.selected[0], "box-1", "keyboard hole refusal must preserve selection")
	_expect_equal(fixture.history.get_undo_count(), 0, "keyboard hole refusal must preserve zero history")

	# Explicit Backspace corrections return to the start point; the replacement
	# contour then removes the right half and succeeds as exactly one command.
	_press(fixture, KEY_BACKSPACE)
	_press(fixture, KEY_BACKSPACE)
	_press(fixture, KEY_BACKSPACE)
	_press(fixture, KEY_UP, true, true)
	_press(fixture, KEY_RIGHT, true, true)
	_press(fixture, KEY_RIGHT, true)
	_press(fixture, KEY_DOWN, true, true)
	_press(fixture, KEY_DOWN, true, true)
	_press(fixture, KEY_LEFT, true, true)
	_press(fixture, KEY_LEFT, true)
	_expect(fixture.plugin.handle_key(_key(KEY_SPACE)), "Space should commit the corrected keyboard Subtract")
	var expected_after := expected_before.duplicate(true)
	expected_after.regions[0].erase("box")
	expected_after.regions[0]["polygon"] = [[30.0, 20.0], [30.0, 40.0], [20.0, 40.0], [20.0, 20.0]]
	_expect_equal(fixture.store.get_corrected_record(0), expected_after, "corrected keyboard Subtract should commit the independent expected record")
	_expect_equal(fixture.selected[0], "box-1", "corrected keyboard Subtract should keep its target selected")
	_expect_equal(fixture.history.get_undo_count(), 1, "only the corrected keyboard retry should create one command")
	_expect_equal(fixture.viewport.overlays.back(), {}, "successful keyboard retry should clear the retained refusal")


func _test_keyboard_paint() -> void:
	var fixture := _fixture()
	fixture.selected[0] = "box-1"
	if not _activate(fixture, "keyboard Paint"):
		return
	var before := _region_polygon(fixture.store.get_corrected_record(0), "box-1")
	_expect(fixture.plugin.handle_key(_key(KEY_P)), "P should enter keyboard Paint spatial mode")
	_press(fixture, KEY_RIGHT, true, true)
	_press(fixture, KEY_RIGHT, true)
	_press(fixture, KEY_RIGHT)
	_expect_equal(_overlay(fixture).get("path"), PackedVector2Array(), "keyboard Paint should show its generated mask instead of a trajectory")
	_expect(not _overlay(fixture).get("mask_preview", {}).is_empty(), "keyboard Paint should update its result mask before Enter")
	_expect(fixture.plugin.handle_key(_key(KEY_ENTER)), "Enter should commit keyboard Paint")
	var after := _region_polygon(fixture.store.get_corrected_record(0), "box-1")
	_expect(POLYGON_OPS.validate_simple_polygon(after), "keyboard Paint must keep one V1-safe ring")
	_expect(_absolute_area(after) > _absolute_area(before), "keyboard Paint should add visible brush area")
	_expect(POLYGON_OPS.polygon_bounds(after).end.x > 40.0, "keyboard Paint cursor path should extend beyond the original right edge")
	_expect_equal(fixture.history.get_undo_count(), 1, "one keyboard Paint stroke should create exactly one command")


func _test_keyboard_eraser() -> void:
	var fixture := _fixture()
	fixture.selected[0] = "box-1"
	if not _activate(fixture, "keyboard Eraser"):
		return
	fixture.plugin.invoke(&"set_tool_option", {"option_id": &"brush_radius", "value": 3.0})
	var before := _region_polygon(fixture.store.get_corrected_record(0), "box-1")
	_expect(fixture.plugin.handle_key(_key(KEY_P, true)), "Shift+P should enter keyboard Eraser spatial mode")
	_expect_equal(fixture.plugin.get_active_tool(), &"eraser", "Shift+P should make Eraser authoritative")
	_press(fixture, KEY_RIGHT, true, true)
	_press(fixture, KEY_RIGHT, true)
	_expect_equal(_overlay(fixture).get("path"), PackedVector2Array(), "keyboard Eraser should show its generated mask instead of a trajectory")
	_expect(not _overlay(fixture).get("mask_preview", {}).is_empty(), "keyboard Eraser should update its result mask before Enter")
	_expect(fixture.plugin.handle_key(_key(KEY_ENTER)), "Enter should commit keyboard Eraser")
	var after := _region_polygon(fixture.store.get_corrected_record(0), "box-1")
	_expect(POLYGON_OPS.validate_simple_polygon(after), "keyboard Eraser must keep one V1-safe ring")
	_expect(_absolute_area(after) > 0.0 and _absolute_area(after) < _absolute_area(before), "keyboard Eraser should remove brush area without deleting the whole region")
	_expect_equal(fixture.history.get_undo_count(), 1, "one keyboard Eraser stroke should create exactly one command")


func _test_keyboard_region_growing() -> void:
	var steps := _fixture()
	if not _activate(steps, "keyboard Region Growing parameter controls"):
		return
	steps.selected[0] = ""
	var steps_before: Dictionary = steps.store.get_corrected_record(0)
	_expect(steps.plugin.handle_key(_key(KEY_G)), "G should enter keyboard Region Growing with an immediate live preview")
	var initial := _overlay(steps)
	_expect_overlay_contract(initial, "keyboard Region Growing preview")
	_expect_equal(initial.get("cursor"), Vector2(50, 40), "keyboard Region Growing should start at the image centre pixel")
	_expect_equal(steps.store.get_corrected_record(0), steps_before, "G preview must not mutate Store")
	_expect_equal(steps.history.get_undo_count(), 0, "G preview must create zero history")
	_press(steps, KEY_RIGHT)
	_expect_equal(_overlay(steps).get("cursor"), Vector2(51, 40), "plain arrow should move the seed by one pixel")
	_press(steps, KEY_RIGHT, true)
	_expect_equal(_overlay(steps).get("cursor"), Vector2(56, 40), "Shift+arrow should move the seed by five pixels")
	_press(steps, KEY_RIGHT, true, true)
	_expect_equal(_overlay(steps).get("cursor"), Vector2(66, 40), "Ctrl+Shift+arrow should move the seed by ten pixels")
	var seed_before_alt: Vector2 = _overlay(steps).get("cursor", Vector2.ZERO)
	_expect(steps.plugin.handle_key(_key(KEY_UP, false, false, true)), "Alt+Up should adjust tolerance before generic seed movement")
	_expect_equal(_overlay(steps).get("cursor"), seed_before_alt, "Alt+Up must not move the Region Growing seed")
	_expect(String(_overlay(steps).get("message", "")).contains("tolerance 0.09"), "Alt+Up should increase tolerance by exactly 0.01")
	_expect(steps.plugin.handle_key(_key(KEY_RIGHT, false, false, true)), "Alt+Right should adjust brightness bias before generic seed movement")
	_expect_equal(_overlay(steps).get("cursor"), seed_before_alt, "Alt+Right must not move the Region Growing seed")
	_expect(String(_overlay(steps).get("message", "")).contains("bias 0.01"), "Alt+Right should increase luminance bias by exactly 0.01")
	for _index in range(4):
		_press(steps, KEY_RIGHT, true, true)
		_press(steps, KEY_DOWN, true, true)
	_expect_equal(_overlay(steps).get("cursor"), Vector2(99, 79), "keyboard seed must clamp to width-1 and height-1 pixel indices")
	_expect_equal(steps.store.get_corrected_record(0), steps_before, "all keyboard adjustments must remain preview-only")
	_expect_equal(steps.history.get_undo_count(), 0, "all keyboard adjustments must stay outside history")

	var fixture := _fixture()
	if not _activate(fixture, "keyboard Region Growing commit"):
		return
	fixture.selected[0] = ""
	var before: Dictionary = fixture.store.get_corrected_record(0)
	_expect(fixture.plugin.handle_key(_key(KEY_G)), "G should enter keyboard Region Growing spatial mode")
	_press(fixture, KEY_RIGHT, true)
	_press(fixture, KEY_DOWN, true)
	var displayed := _overlay(fixture)
	_expect_equal(displayed.get("phase"), &"candidate", "moving the seed onto the red component should show a green candidate")
	var displayed_polygon: PackedVector2Array = displayed.get("candidate_polygon", PackedVector2Array()).duplicate()
	_expect_equal(fixture.store.get_corrected_record(0), before, "candidate navigation must not commit early")
	_expect(fixture.plugin.handle_key(_key(KEY_ENTER)), "Enter should commit the displayed keyboard candidate")
	_expect_equal(fixture.store.get_corrected_record(0), before, "keyboard Region Growing must remain pending before class assignment")
	_expect_equal(fixture.class_requests.size(), 1, "keyboard Region Growing must request class assignment exactly once")
	_expect(_confirm_pending_polygon(fixture, "keyboard growth", "growth kind").is_empty(), "keyboard Region Growing class confirmation should succeed")
	var after: Dictionary = fixture.store.get_corrected_record(0)
	var count_before: int = before.regions.size()
	_expect_equal(after.regions.size(), count_before + 1, "keyboard Region Growing should add one seed-connected region")
	var polygon := _polygon_from_value(after.regions.back().get("polygon", []))
	_expect_equal(polygon, displayed_polygon, "Enter must commit the candidate already displayed before confirmation")
	_expect_equal(POLYGON_OPS.polygon_bounds(polygon), Rect2(54, 44, 10, 10), "keyboard Region Growing should use the cursor moved to the red component")
	_expect(POLYGON_OPS.validate_simple_polygon(polygon), "keyboard Region Growing must commit one V1-safe polygon")
	_expect_equal(fixture.history.get_undo_count(), 1, "one keyboard Region Growing confirmation should create exactly one command")

	var stale := _fixture()
	if _activate(stale, "keyboard Region Growing stale Store guard"):
		_expect(stale.plugin.handle_key(_key(KEY_G)), "G should start the stale-snapshot fixture")
		_press(stale, KEY_RIGHT, true)
		_press(stale, KEY_DOWN, true)
		var external: Dictionary = stale.store.get_corrected_record(0)
		external.regions[0]["class"] = "clip"
		_expect(stale.store.replace_corrected_record(0, external).is_empty(), "the independent keyboard intervening edit should be valid")
		_expect(stale.plugin.handle_key(_key(KEY_ENTER)), "Enter should consume a stale keyboard confirmation")
		_expect_equal(stale.store.get_corrected_record(0), external, "stale keyboard confirmation must not overwrite Store")
		_expect_equal(stale.history.get_undo_count(), 0, "stale keyboard confirmation must create zero commands")
		_expect_equal(_overlay(stale).get("phase"), &"invalid", "stale keyboard confirmation should remain visibly red")

func _test_keyboard_live_wire() -> void:
	var fixture := _fixture()
	if not _activate(fixture, "keyboard Live Wire"):
		return
	fixture.selected[0] = ""
	var before: Dictionary = fixture.store.get_corrected_record(0)
	var count_before: int = fixture.store.get_corrected_record(0).regions.size()
	_expect(fixture.plugin.handle_key(_key(KEY_I)), "I should enter keyboard Live Wire spatial mode")
	_expect(fixture.plugin.handle_key(_key(KEY_ENTER)), "Enter should place the first keyboard Live Wire anchor")
	_press(fixture, KEY_RIGHT, true, true)
	var first_hover: Dictionary = _overlay(fixture)
	_expect_equal(first_hover.get("cursor"), Vector2(60, 40), "keyboard arrow movement should move the hover cursor by the established 10-pixel step")
	_expect_equal(first_hover.get("path"), PackedVector2Array([
		Vector2(50, 40), Vector2(60, 40),
	]), "keyboard arrows should publish one direct straight segment before Enter appends it")
	var cache_before_pointer := {
		"image": fixture.plugin.get("_live_wire_cache_image"),
		"start": fixture.plugin.get("_live_wire_cache_start"),
		"goal": fixture.plugin.get("_live_wire_cache_goal"),
		"result": fixture.plugin.get("_live_wire_cache_result").duplicate(true),
		"hits": fixture.plugin.get("_live_wire_cache_hits"),
		"misses": fixture.plugin.get("_live_wire_cache_misses"),
	}
	var keyboard_cursor_before_pointer: Vector2 = fixture.plugin.get("_keyboard_cursor")
	var anchors_before_pointer: PackedVector2Array = fixture.plugin.get("_live_wire_anchors").duplicate()
	var fixed_path_before_pointer: PackedVector2Array = fixture.plugin.get("_live_wire_points").duplicate()
	var enter_arm_before_pointer: bool = fixture.plugin.get("_live_wire_enter_armed")
	_hover_pointer(fixture, Vector2(77, 63))
	_expect_equal(_overlay(fixture), first_hover, "incidental pointer hover must not replace the displayed keyboard Live Wire preview")
	_expect(is_same(fixture.plugin.get("_live_wire_cache_image"), cache_before_pointer.image), "incidental pointer hover must preserve the keyboard Live Wire cache image identity")
	_expect_equal(fixture.plugin.get("_live_wire_cache_start"), cache_before_pointer.start, "incidental pointer hover must preserve the keyboard Live Wire cache start")
	_expect_equal(fixture.plugin.get("_live_wire_cache_goal"), cache_before_pointer.goal, "incidental pointer hover must preserve the keyboard Live Wire cache goal")
	_expect_equal(fixture.plugin.get("_live_wire_cache_result"), cache_before_pointer.result, "incidental pointer hover must preserve the exact keyboard Live Wire cached path")
	_expect_equal(fixture.plugin.get("_live_wire_cache_hits"), cache_before_pointer.hits, "incidental pointer hover must not count a keyboard Live Wire cache hit")
	_expect_equal(fixture.plugin.get("_live_wire_cache_misses"), cache_before_pointer.misses, "incidental pointer hover must not count a keyboard Live Wire cache miss")
	_expect_equal(fixture.plugin.get("_keyboard_cursor"), keyboard_cursor_before_pointer, "incidental pointer hover must preserve the keyboard cursor")
	_expect_equal(fixture.plugin.get("_live_wire_anchors"), anchors_before_pointer, "incidental pointer hover must preserve keyboard anchors")
	_expect_equal(fixture.plugin.get("_live_wire_points"), fixed_path_before_pointer, "incidental pointer hover must preserve the fixed keyboard path")
	_expect_equal(fixture.plugin.get("_live_wire_enter_armed"), enter_arm_before_pointer, "incidental pointer hover must preserve the keyboard Enter arm")
	_expect(fixture.plugin.handle_key(_key(KEY_ENTER)), "Enter should place the second keyboard Live Wire anchor")
	_expect_equal(fixture.plugin.get("_live_wire_points"), first_hover.get("path"), "Enter must append exactly the keyboard preview displayed before incidental pointer movement")
	_press(fixture, KEY_DOWN, true, true)
	_expect(fixture.plugin.handle_key(_key(KEY_ENTER)), "Enter should place the third keyboard Live Wire anchor")
	_expect_equal(fixture.history.get_undo_count(), 0, "Live Wire anchors must remain preview-only before contextual closure")
	_expect(fixture.plugin.handle_key(_key(KEY_ENTER)), "a second unchanged Enter should close a three-anchor keyboard Live Wire contour without Ctrl")
	_expect_equal(fixture.store.get_corrected_record(0), before, "keyboard Live Wire must remain pending before class assignment")
	_expect_equal(fixture.class_requests.size(), 1, "keyboard Live Wire must request class assignment exactly once")
	_expect(_confirm_pending_polygon(fixture, "keyboard wire", "wire kind").is_empty(), "keyboard Live Wire class confirmation should succeed")
	var after: Dictionary = fixture.store.get_corrected_record(0)
	_expect_equal(after.regions.size(), count_before + 1, "keyboard Live Wire should add exactly one region")
	var polygon := _polygon_from_value(after.regions.back().get("polygon", []))
	_expect_equal(polygon, PackedVector2Array([
		Vector2(50, 40), Vector2(60, 40), Vector2(60, 50),
	]), "keyboard Live Wire should commit the independently expected three-anchor ring")
	_expect_equal(fixture.history.get_undo_count(), 1, "one confirmed keyboard Live Wire should create exactly one command")
	_expect(fixture.history.undo(fixture.store), "keyboard Live Wire should undo its one AddPolygon command")
	_expect_equal(fixture.store.get_corrected_record(0), before, "keyboard Live Wire undo should restore the exact independent before record")
	_expect_equal(fixture.history.redo(fixture.store), PackedStringArray(), "keyboard Live Wire should redo its one AddPolygon command")
	_expect_equal(fixture.store.get_corrected_record(0), after, "keyboard Live Wire redo should restore the exact committed record")

	var modal := _fixture()
	if _activate(modal, "keyboard Live Wire modal anchor removal"):
		modal.selected[0] = "box-1"
		var modal_before: Dictionary = modal.store.get_corrected_record(0)
		_expect(modal.plugin.handle_key(_key(KEY_I)), "I should enter the modal keyboard Live Wire fixture")
		_expect(modal.plugin.handle_key(_key(KEY_ENTER)), "the modal fixture should place its first anchor")
		_press(modal, KEY_RIGHT, true, true)
		_expect(modal.plugin.handle_key(_key(KEY_ENTER)), "the modal fixture should place its second anchor")
		_press(modal, KEY_DOWN, true, true)
		_expect(modal.plugin.handle_key(_key(KEY_ENTER)), "the modal fixture should place its third anchor")
		var exact_three_anchor_path: PackedVector2Array = modal.plugin.get("_live_wire_points").duplicate()
		_press(modal, KEY_LEFT, true, true)
		_expect(modal.plugin.handle_key(_key(KEY_ENTER)), "moving then Enter should append a fourth full cached segment")
		_expect(modal.plugin.handle_key(_key(KEY_BACKSPACE)), "modal keyboard Backspace should be consumed")
		_expect_equal(modal.plugin.get("_live_wire_anchors").size(), 3, "keyboard Backspace should remove exactly one anchor")
		_expect_equal(modal.plugin.get("_live_wire_points"), exact_three_anchor_path, "keyboard Backspace should restore the exact prior fixed path")
		_expect(modal.plugin.handle_key(_key(KEY_DELETE)), "modal keyboard Delete should be consumed")
		_expect_equal(modal.store.get_corrected_record(0), modal_before, "modal keyboard Delete must never delete the selected region")
		_expect_equal(modal.history.get_undo_count(), 0, "keyboard anchor correction must stay outside history")
		_expect(modal.plugin.handle_key(_key(KEY_ESCAPE)), "Escape should clear the corrected keyboard Live Wire transaction")
		_expect_equal(_overlay(modal), {}, "Escape should be the explicit path that clears the keyboard Live Wire overlay")

	var clamped := _fixture()
	if _activate(clamped, "keyboard Live Wire pixel clamp"):
		_expect(clamped.plugin.handle_key(_key(KEY_I)), "I should enter the keyboard pixel-clamp fixture")
		for _index in range(6):
			_press(clamped, KEY_RIGHT, true, true)
			_press(clamped, KEY_DOWN, true, true)
		_expect_equal(_overlay(clamped).get("cursor"), Vector2(99, 79), "keyboard Live Wire cursor must clamp to width-1 and height-1 pixel indices")


func _test_escape_cancels_every_keyboard_spatial_mode() -> void:
	var modes := [
		{"key": KEY_L, "tool": &"lasso", "shift": false},
		{"key": KEY_F, "tool": &"fill", "shift": false},
		{"key": KEY_S, "tool": &"subtract", "shift": false},
		{"key": KEY_P, "tool": &"paint", "shift": false},
		{"key": KEY_P, "tool": &"eraser", "shift": true},
	]
	for mode: Dictionary in modes:
		var fixture := _fixture()
		fixture.selected[0] = "box-1"
		if not _activate(fixture, "Escape cancellation for %s" % mode.tool):
			continue
		var before: Dictionary = fixture.store.get_corrected_record(0)
		_expect(fixture.plugin.handle_key(_key(mode.key, mode.shift)), "%s shortcut should enter keyboard spatial mode" % mode.tool)
		_expect_equal(fixture.plugin.get_active_tool(), mode.tool, "%s shortcut should activate its real tool" % mode.tool)
		_expect(fixture.plugin.handle_key(_key(KEY_RIGHT, true)), "%s spatial cursor should accept Shift+arrow" % mode.tool)
		_expect_equal(fixture.store.get_corrected_record(0), before, "%s preview must not mutate Store before cancellation" % mode.tool)
		_expect_equal(fixture.history.get_undo_count(), 0, "%s preview must not enter history before cancellation" % mode.tool)
		_expect(fixture.plugin.handle_key(_key(KEY_ESCAPE)), "Escape should cancel keyboard %s" % mode.tool)
		_expect_equal(fixture.store.get_corrected_record(0), before, "Escape must leave Store unchanged for keyboard %s" % mode.tool)
		_expect_equal(fixture.history.get_undo_count(), 0, "Escape must leave history unchanged for keyboard %s" % mode.tool)
		if not fixture.viewport.records.is_empty():
			_expect_equal(fixture.viewport.records.back(), before, "Escape should restore committed viewport data for keyboard %s" % mode.tool)


func _fixture() -> Dictionary:
	var image := _image()
	var store = STORE_SCRIPT.new()
	var load_errors: PackedStringArray = store.load_model_records([_record()])
	if load_errors.is_empty():
		var corrected: Dictionary = store.get_corrected_record(0)
		corrected.regions[0]["filled"] = false
		load_errors.append_array(store.replace_corrected_record(0, corrected))
	var history = HISTORY_SCRIPT.new()
	var viewport := ViewportProbe.new(image)
	var frame := [0]
	var selected := [""]
	var statuses: Array[String] = []
	var class_requests: Array[Dictionary] = []
	var context := {
		"store": store,
		"history": history,
		"viewport": viewport,
		"current_frame": func(): return frame[0],
		"selected_region": func(): return selected[0],
		"set_selected_region": func(value: String): selected[0] = value,
		"status": func(message: String): statuses.append(message),
		"request_class_assignment": func(request: Dictionary): class_requests.append(request.duplicate(true)),
		"taxonomy": {"classes": [{"id": "unknown", "kind": "region"}]},
		"get_current_image": func(): return image,
	}
	return {
		"plugin": PLUGIN_SCRIPT.new(),
		"store": store,
		"history": history,
		"viewport": viewport,
		"frame": frame,
		"selected": selected,
		"statuses": statuses,
		"class_requests": class_requests,
		"context": context,
		"load_errors": load_errors,
	}


func _activate(fixture: Dictionary, behavior: String) -> bool:
	_expect(fixture.load_errors.is_empty(), "%s fixture should be schema-valid" % behavior)
	if not fixture.load_errors.is_empty():
		return false
	var errors: PackedStringArray = fixture.plugin.activate(fixture.context)
	_expect(errors.is_empty(), "%s should activate with the normal edit context" % behavior)
	return errors.is_empty()


func _confirm_pending_polygon(fixture: Dictionary, class_label: String, kind: String) -> PackedStringArray:
	var request: Dictionary = fixture.plugin.get("_session").pending_request()
	return fixture.plugin.invoke(&"confirm_pending_region", {
		"candidate_token": request.get("candidate_token"),
		"class": class_label,
		"kind": kind,
	})


func _press(fixture: Dictionary, code: Key, shift := false, ctrl := false) -> void:
	_expect(
		fixture.plugin.handle_key(_key(code, shift, ctrl)),
		"active keyboard spatial mode should consume %s" % code,
	)


func _hover_pointer(fixture: Dictionary, image_position: Vector2) -> void:
	var event := InputEventMouseMotion.new()
	event.button_mask = 0
	fixture.plugin.handle_pointer(event, image_position)


func _key(code: Key, shift := false, ctrl := false, alt := false) -> InputEventKey:
	var event := InputEventKey.new()
	event.keycode = code
	event.pressed = true
	event.shift_pressed = shift
	event.ctrl_pressed = ctrl
	event.alt_pressed = alt
	return event


func _record() -> Dictionary:
	return {
		"schema_version": 1,
		"source": "sample_v1",
		"frame": 0,
		"regions": [
			{
				"id": "box-1",
				"class": "grasper",
				"kind": "instrument",
				"box": [20, 20, 20, 20],
				"conf": 0.9,
				"track_id": "T01",
			},
			{
				"id": "notch-1",
				"class": "gallbladder",
				"kind": "anatomy",
				"polygon": [
					[40, 38], [47, 38], [47, 39], [48, 39],
					[48, 38], [54, 38], [54, 42], [40, 42],
				],
				"conf": 0.8,
				"track_id": null,
			},
		],
	}


func _with_fill_boundaries(record: Dictionary) -> Dictionary:
	var result := record.duplicate(true)
	for region: Dictionary in [
		{"id": "fill-top", "class": "boundary", "kind": "region", "box": [65, 50, 25, 3]},
		{"id": "fill-bottom", "class": "boundary", "kind": "region", "box": [65, 70, 25, 3]},
		{"id": "fill-left", "class": "boundary", "kind": "region", "box": [65, 53, 3, 17]},
		{"id": "fill-right", "class": "boundary", "kind": "region", "box": [87, 53, 3, 17]},
	]:
		result.regions.append(region)
	return result


func _image() -> Image:
	var image := Image.create(100, 80, false, Image.FORMAT_RGBA8)
	image.fill(Color.BLACK)
	for y in range(44, 54):
		for x in range(54, 64):
			image.set_pixel(x, y, Color.RED)
	return image


func _find_region(record: Dictionary, region_id: String) -> Dictionary:
	for value: Variant in record.get("regions", []):
		if value is Dictionary and value.get("id") == region_id:
			return value
	return {}


func _region_polygon(record: Dictionary, region_id: String) -> PackedVector2Array:
	var region := _find_region(record, region_id)
	if region.has("polygon"):
		return _polygon_from_value(region.polygon)
	if region.has("box"):
		return POLYGON_OPS.box_to_polygon(region.box)
	return PackedVector2Array()


func _install_working_mask(fixture: Dictionary, state: Dictionary) -> void:
	var session: Variant = fixture.plugin.get("_session")
	session.begin(&"paint", 0, "", fixture.store.get_corrected_record(0))
	session.set_working_mask(state, "ready for Fill")
	fixture.plugin.call("_push_session_overlay")


func _overlay(fixture: Dictionary) -> Dictionary:
	return fixture.viewport.overlays.back() if not fixture.viewport.overlays.is_empty() else {}


func _expect_overlay_contract(overlay: Dictionary, behavior: String) -> void:
	var actual: Array = overlay.keys()
	actual.sort()
	var expected := [
		"brush_radius",
		"candidate_polygon",
		"cursor",
		"fill_color",
		"mask_preview",
		"message",
		"path",
		"phase",
	]
	expected.sort()
	_expect_equal(actual, expected, "%s should publish exactly the eight EditOverlay keys" % behavior)


func _outline_state(roi: Rect2i, first: int, last: int, top_gaps: Array) -> Dictionary:
	var mask := PackedByteArray()
	mask.resize(roi.size.x * roi.size.y)
	for x in range(first, last + 1):
		if x not in top_gaps:
			mask[first * roi.size.x + x] = 1
		mask[last * roi.size.x + x] = 1
	for y in range(first, last + 1):
		mask[y * roi.size.x + first] = 1
		mask[y * roi.size.x + last] = 1
	return {"roi": roi, "mask": mask}


func _polygon_from_value(value: Variant) -> PackedVector2Array:
	var result := PackedVector2Array()
	if not value is Array:
		return result
	for point: Variant in value:
		if point is Array and point.size() == 2:
			result.append(Vector2(float(point[0]), float(point[1])))
	return result


func _absolute_area(points: PackedVector2Array) -> float:
	if points.size() < 3:
		return 0.0
	var twice_area := 0.0
	for index in range(points.size()):
		twice_area += points[index].cross(points[(index + 1) % points.size()])
	return absf(twice_area) * 0.5


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


func _expect_equal(actual: Variant, expected: Variant, message: String) -> void:
	_expect(actual == expected, "%s (expected %s, got %s)" % [message, str(expected), str(actual)])
