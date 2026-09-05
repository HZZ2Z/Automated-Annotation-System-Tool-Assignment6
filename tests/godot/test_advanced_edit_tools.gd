extends SceneTree


const PLUGIN_SCRIPT := preload("res://client/plugins/edit/basic_edit_tools/plugin.gd")
const STORE_SCRIPT := preload("res://client/domain/annotation_store.gd")
const HISTORY_SCRIPT := preload("res://client/domain/command_history.gd")
const ADD_POLYGON_COMMAND := preload("res://client/domain/commands/add_polygon_command.gd")
const TRANSFORM_SCRIPT := preload("res://client/services/viewport_transform.gd")
const POLYGON_OPS := preload("res://client/domain/polygon_ops.gd")

const REQUIRED_TOOL_IDS := [
	&"box",
	&"subtract",
	&"lasso",
	&"fill",
	&"paint",
	&"eraser",
	&"select",
]

const PAINT_OVERLAY_COLOR := Color("#22d3ee")
const ERASER_OVERLAY_COLOR := Color("#a855f7")
const WORKING_MASK_COLOR := Color("#f97316")
const INVALID_COLOR := Color("#ef4444")


class ViewportProbe extends RefCounted:
	signal edit_cancel_requested

	var records: Array[Dictionary] = []
	var selected_ids: Array[String] = []
	var overlays: Array[Dictionary] = []
	var transform = TRANSFORM_SCRIPT.new()
	var current_image: Image

	func _init(image: Image) -> void:
		current_image = image
		transform.configure(Vector2(image.get_width(), image.get_height()), Rect2(0, 0, 200, 160))

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


class RejectOnceStore extends RefCounted:
	var delegate: Variant
	var reject_next_replace := false

	func _init(next_delegate: Variant) -> void:
		delegate = next_delegate

	func get_corrected_record(frame: int) -> Dictionary:
		return delegate.get_corrected_record(frame)

	func replace_corrected_record(frame: int, record: Variant) -> PackedStringArray:
		if reject_next_replace:
			reject_next_replace = false
			return PackedStringArray(["forced replacement rejection"])
		return delegate.replace_corrected_record(frame, record)


var _failures: Array[String] = []


func _init() -> void:
	call_deferred("_run_tests")


func _run_tests() -> void:
	_test_visible_tool_contract()
	_test_brush_cursor_is_visible_before_drawing()
	_test_space_is_the_only_keyboard_contour_closure()
	_test_brushes_preview_the_result_mask_without_a_trajectory()
	_test_unselected_paint_adds_one_simple_region()
	_test_paint_outline_fill_commits_without_losing_working_mask()
	_test_figure_eight_paint_fill_accumulates_into_one_solid_object()
	_test_selected_paint_disjoint_adds_a_new_region()
	_test_unselected_paint_overlap_repairs_one_existing_region()
	_test_paint_multi_overlap_requires_or_honors_selection()
	_test_fill_finds_the_clicked_smallest_enclosed_blank_region()
	_test_fill_refuses_open_or_occupied_blank_regions()
	_test_selection_affine_resizes_polygon_by_handle()
	_test_selection_alt_arrow_affine_resizes_polygon()
	_test_selection_move_and_nudge_never_request_class()
	_test_lasso_adds_one_polygon_and_cancel_restores_preview()
	_test_every_polygon_creation_path_waits_for_class_assignment()
	_test_lasso_anchor_hover_threshold_double_click_and_round_trip()
	_test_lasso_freehand_strict_threshold_and_proximity()
	_test_lasso_auto_closes_a_near_release_and_accepts_multiple_enclosures()
	_test_lasso_retains_filled_invalid_candidates_for_correction()
	_test_freehand_preview_is_bounded_before_commit_validation()
	_test_subtract_commits_one_v1_safe_ring()
	_test_subtract_refuses_holes_and_multiple_components_atomically()
	_test_subtract_refuses_empty_noop_invalid_and_out_of_bounds_atomically()
	_test_unselected_subtract_deletes_across_regions_atomically()
	_test_subtract_auto_closes_a_near_release_and_deletes_multiple_enclosures()
	_test_subtract_command_failure_retains_retryable_transaction()
	_test_brush_radius_contract_and_distinct_overlay_colors()
	_test_paint_unions_one_brush_stroke()
	_test_eraser_requires_an_explicit_selection()
	_test_eraser_subtracts_and_refuses_v1_inexpressible_results()
	if _failures.is_empty():
		print("PASS: advanced edit tools")
		quit(0)
		return
	push_error("FAIL: advanced edit tools\n%s" % "\n".join(_failures))
	quit(1)


func _test_visible_tool_contract() -> void:
	var plugin = PLUGIN_SCRIPT.new()
	var descriptors: Array = plugin.get_tool_descriptors()
	_expect_equal(descriptors.size(), 7, "the toolbar should expose exactly its seven distinct real tools")
	var ids: Array[StringName] = []
	for value: Variant in descriptors:
		if not value is Dictionary:
			_failures.append("every tool descriptor should be a Dictionary")
			continue
		var descriptor: Dictionary = value
		var tool_id := StringName(descriptor.get("id", ""))
		ids.append(tool_id)
		_expect(bool(descriptor.get("implemented", false)), "%s should be available instead of showing the pending-development path" % tool_id)
	_expect_equal(ids, REQUIRED_TOOL_IDS, "the visible tools should keep their established order and IDs")
	_expect(not ids.has(&"move"), "Move / Resize must stay merged into Selection")
	_expect(not ids.has(&"close_gaps"), "Close Gaps must not remain in the visible or activatable tool contract")
	_expect(not ids.has(&"region_growing"), "Region Growing must not remain in the visible tool contract")
	_expect(not ids.has(&"live_wire"), "Live Wire must not duplicate Lasso in the visible tool contract")
	var fixture := _base_fixture()
	var activation_errors: PackedStringArray = fixture.plugin.activate(fixture.context)
	_expect(activation_errors.is_empty(), "the complete tool contract should activate with the normal edit context")
	if not activation_errors.is_empty():
		return
	for tool_id: StringName in REQUIRED_TOOL_IDS:
		_expect(fixture.plugin.set_active_tool(tool_id).is_empty(), "%s should be selectable as a real tool" % tool_id)
	_expect(not fixture.plugin.set_active_tool(&"close_gaps").is_empty(), "the removed Close Gaps ID must be refused")
	_expect(not fixture.plugin.set_active_tool(&"region_growing").is_empty(), "the removed Region Growing ID must be refused")
	_expect(not fixture.plugin.set_active_tool(&"live_wire").is_empty(), "the removed Live Wire ID must be refused")


func _test_brush_cursor_is_visible_before_drawing() -> void:
	var fixture := _base_fixture()
	if not _activate_tool(fixture, &"paint", "idle Paint cursor"):
		return
	var before: Dictionary = fixture.store.get_corrected_record(0)
	var overlay := _overlay(fixture)
	_expect_equal(overlay.get("phase"), &"brush_cursor", "selecting Paint should immediately show an idle brush cursor")
	_expect_equal(overlay.get("cursor"), Vector2(50, 40), "a first-use brush cursor should start at image centre")
	_expect_equal(overlay.get("brush_radius"), 8.0, "the idle brush cursor should use the current shared radius")
	_expect_equal(overlay.get("path"), PackedVector2Array(), "the idle brush cursor must not contain a trajectory or centre point")
	_expect_equal(overlay.get("mask_preview"), {}, "the idle brush cursor must not fabricate a result mask")
	_expect_equal(fixture.plugin.get_edit_state().get("navigation_blocked"), false, "an idle brush cursor must not block frame navigation")

	_hover(fixture.plugin, Vector2(73, 19), fixture.viewport)
	overlay = _overlay(fixture)
	_expect_equal(overlay.get("cursor"), Vector2(73, 19), "the idle Paint cursor should follow pointer hover before drawing")
	fixture.plugin.invoke(&"set_tool_option", {"option_id": &"brush_radius", "value": 13.0})
	_expect_equal(_overlay(fixture).get("brush_radius"), 13.0, "changing brush size should update the visible cursor immediately")

	_expect(fixture.plugin.set_active_tool(&"eraser").is_empty(), "Eraser should remain selectable without drawing")
	overlay = _overlay(fixture)
	_expect_equal(overlay.get("phase"), &"brush_cursor", "selecting Eraser should immediately retain a visible brush cursor")
	_expect_equal(overlay.get("cursor"), Vector2(73, 19), "Paint and Eraser should share the last valid image pointer")
	_expect_equal(overlay.get("brush_radius"), 13.0, "Paint and Eraser should share the visible brush radius")
	_expect_equal(fixture.store.get_corrected_record(0), before, "idle brush cursor changes must preserve Store")
	_expect_equal(fixture.history.get_undo_count(), 0, "idle brush cursor changes must preserve History")


func _test_space_is_the_only_keyboard_contour_closure() -> void:
	var lasso := _base_fixture()
	if _activate_tool(lasso, &"lasso", "Space-only Lasso closure"):
		_gesture(lasso.plugin, lasso.viewport, [
			Vector2(60, 10), Vector2(80, 10), Vector2(80, 30), Vector2(60, 30),
		])
		var before: Dictionary = lasso.store.get_corrected_record(0)
		_expect(lasso.plugin.handle_key(_key(KEY_ENTER)), "an active Lasso should consume Enter without closing")
		_expect_equal(lasso.class_requests.size(), 0, "Enter must not close or classify a Lasso contour")
		_expect_equal(lasso.store.get_corrected_record(0), before, "Enter must preserve Store for an active Lasso")
		_expect(lasso.plugin.handle_key(_key(KEY_SPACE)), "Space should close an active Lasso contour")
		_expect_equal(lasso.class_requests.size(), 1, "Space should move one valid Lasso contour to class assignment")
		_expect_equal(_overlay(lasso).get("phase"), &"awaiting_class", "Space-closed Lasso should retain its filled pending polygon")

	var subtract := _base_fixture()
	subtract.selected[0] = "box-1"
	if _activate_tool(subtract, &"subtract", "Space-only Subtract closure"):
		_gesture(subtract.plugin, subtract.viewport, [
			Vector2(25, 5), Vector2(35, 5), Vector2(35, 30), Vector2(25, 30),
		])
		var before: Dictionary = subtract.store.get_corrected_record(0)
		_expect(subtract.plugin.handle_key(_key(KEY_ENTER)), "an active Subtract contour should consume Enter without closing")
		_expect_equal(subtract.store.get_corrected_record(0), before, "Enter must not apply an active Subtract contour")
		_expect_equal(subtract.history.get_undo_count(), 0, "Enter must not create Subtract history")
		_expect(subtract.plugin.handle_key(_key(KEY_SPACE)), "Space should close an active Subtract contour")
		_expect(subtract.store.get_corrected_record(0) != before, "Space should apply the valid Subtract contour")
		_expect_equal(subtract.history.get_undo_count(), 1, "Space-closed Subtract should create exactly one history command")


func _test_brushes_preview_the_result_mask_without_a_trajectory() -> void:
	for tool_id: StringName in [&"paint", &"eraser"]:
		var fixture := _base_fixture()
		fixture.selected[0] = "box-1"
		if not _activate_tool(fixture, tool_id, "%s real-time result preview" % tool_id):
			continue
		fixture.plugin.invoke(&"set_tool_option", {"option_id": &"brush_radius", "value": 3.0})
		var before: Dictionary = fixture.store.get_corrected_record(0)
		_pointer(fixture.plugin, true, Vector2(29, 17), fixture.viewport)
		var pressed := _overlay(fixture)
		_expect_equal(pressed.get("phase"), &"drawing", "%s press should immediately publish a result preview" % tool_id)
		_expect_equal(pressed.get("path"), PackedVector2Array(), "%s must not draw a trajectory or one-point centre dot" % tool_id)
		_expect(not pressed.get("mask_preview", {}).is_empty(), "%s press should render the actual combined region mask" % tool_id)
		_expect_equal(pressed.get("suppress_region_id"), "box-1", "%s preview should replace the committed region visually" % tool_id)
		var pressed_mask: Dictionary = pressed.get("mask_preview", {}).duplicate(true)
		_motion(fixture.plugin, Vector2(35, 17), fixture.viewport)
		var moved := _overlay(fixture)
		_expect_equal(moved.get("path"), PackedVector2Array(), "%s motion must remain trajectory-free" % tool_id)
		_expect(moved.get("mask_preview", {}) != pressed_mask, "%s motion should update the generated shape before release" % tool_id)
		_expect_equal(fixture.store.get_corrected_record(0), before, "%s live preview must not mutate Store" % tool_id)
		_expect_equal(fixture.history.get_undo_count(), 0, "%s live preview must not enter History" % tool_id)
		fixture.plugin.cancel()

	var unselected := _base_fixture()
	if _activate_tool(unselected, &"paint", "unselected Paint new-object preview"):
		var before: Dictionary = unselected.store.get_corrected_record(0)
		_pointer(unselected.plugin, true, Vector2(70, 17), unselected.viewport)
		var preview := _overlay(unselected)
		_expect_equal(preview.get("phase"), &"drawing", "unselected Paint should immediately preview a new brush object")
		_expect_equal(preview.get("path"), PackedVector2Array(), "unselected Paint must remain trajectory-free")
		_expect(not preview.get("mask_preview", {}).is_empty(), "unselected Paint should preview the generated object mask")
		_expect(not preview.has("suppress_region_id"), "a disjoint Paint object must not suppress an existing region")
		_expect_equal(unselected.store.get_corrected_record(0), before, "unselected Paint preview must preserve Store")
		unselected.plugin.cancel()


func _test_fill_finds_the_clicked_smallest_enclosed_blank_region() -> void:
	var fixture := _fixture(_enclosed_blank_record(), _flat_image())
	if not _activate_tool(fixture, &"fill", "clicked enclosed-blank Fill"):
		return
	var before: Dictionary = fixture.store.get_corrected_record(0)
	_click(fixture.plugin, fixture.viewport, Vector2(40, 40))
	_expect_equal(fixture.store.get_corrected_record(0), before, "clicked Fill should remain pending before class assignment")
	var overlay := _overlay(fixture)
	_expect_equal(overlay.get("phase"), &"awaiting_class", "an enclosed blank component should become a filled candidate after one click")
	_expect_equal(POLYGON_OPS.polygon_bounds(overlay.get("candidate_polygon", PackedVector2Array())), Rect2(25, 25, 30, 30),
		"Fill should choose only the smallest connected blank component surrounding the click")
	_expect_equal(fixture.class_requests.size(), 1, "clicked Fill should request class assignment exactly once")
	_expect(_confirm_pending_polygon(fixture, "filled target", "region").is_empty(), "clicked Fill class confirmation should succeed")
	var after: Dictionary = fixture.store.get_corrected_record(0)
	_expect_equal(after.regions.size(), before.regions.size() + 1, "clicked Fill should add one region")
	_expect(POLYGON_OPS.validate_simple_polygon(_polygon_from_value(after.regions.back().get("polygon", []))), "Fill should commit one simple V1 ring")
	_expect_equal(fixture.history.get_undo_count(), 1, "one clicked Fill should create one command after classification")


func _test_fill_refuses_open_or_occupied_blank_regions() -> void:
	var open := _base_fixture()
	if _activate_tool(open, &"fill", "open blank Fill refusal"):
		var before: Dictionary = open.store.get_corrected_record(0)
		_click(open.plugin, open.viewport, Vector2(70, 20))
		_expect_equal(open.store.get_corrected_record(0), before, "open Fill refusal must preserve Store")
		_expect_equal(open.history.get_undo_count(), 0, "open Fill refusal must not enter History")
		_expect_equal(_overlay(open).get("phase"), &"invalid", "open Fill refusal should remain visibly invalid")
		_expect(String(_overlay(open).get("message", "")).contains("No closed region"),
			"open Fill refusal should explain that no closed region was found")

	var occupied := _fixture(_enclosed_blank_record(), _flat_image())
	if _activate_tool(occupied, &"fill", "occupied Fill refusal"):
		_click(occupied.plugin, occupied.viewport, Vector2(30, 22))
		_expect_equal(_overlay(occupied).get("phase"), &"invalid", "Fill on existing annotation pixels should be refused visibly")
		_expect(String(_overlay(occupied).get("message", "")).contains("blank"),
			"occupied Fill refusal should ask for a blank area")


func _test_live_wire_segments_are_straight_between_anchors() -> void:
	var fixture := _base_fixture()
	if not _activate_tool(fixture, &"live_wire", "straight Live Wire"):
		return
	_click(fixture.plugin, fixture.viewport, Vector2(10, 10))
	_hover(fixture.plugin, Vector2(17, 14), fixture.viewport)
	_expect_equal(
		_overlay(fixture).get("path"),
		PackedVector2Array([Vector2(10, 10), Vector2(17, 14)]),
		"Live Wire hover must contain only the two endpoints of one straight segment",
	)
	_click(fixture.plugin, fixture.viewport, Vector2(17, 14))
	_hover(fixture.plugin, Vector2(21, 25), fixture.viewport)
	_expect_equal(
		_overlay(fixture).get("path"),
		PackedVector2Array([Vector2(10, 10), Vector2(17, 14), Vector2(21, 25)]),
		"each additional Live Wire anchor should append one direct straight segment",
	)


func _test_selection_affine_resizes_polygon_by_handle() -> void:
	var fixture := _base_fixture()
	fixture.selected[0] = "poly-1"
	if not _activate_tool(fixture, &"select", "polygon handle resize"):
		return
	var before: Dictionary = fixture.store.get_corrected_record(0)
	_pointer(fixture.plugin, true, Vector2(55, 55), fixture.viewport)
	_motion(fixture.plugin, Vector2(70, 70), fixture.viewport)
	_pointer(fixture.plugin, false, Vector2(70, 70), fixture.viewport)
	var after: Dictionary = fixture.store.get_corrected_record(0)
	var polygon := _region_polygon(after, "poly-1")
	_expect_equal(
		polygon,
		PackedVector2Array([Vector2(40, 40), Vector2(70, 40), Vector2(50, 70)]),
		"dragging the polygon bottom-right bounds handle should scale every vertex about the opposite corner",
	)
	_expect_equal(fixture.history.get_undo_count(), 1, "one polygon-handle drag should create exactly one command")
	_expect_equal(fixture.class_requests, [], "Select resize must never request a new-region class")
	_expect(after != before, "a polygon handle resize should change the corrected snapshot")
	_expect_equal(_find_region(after, "poly-1").get("class"), "gallbladder", "polygon resize should preserve region metadata")


func _test_selection_alt_arrow_affine_resizes_polygon() -> void:
	var fixture := _base_fixture()
	fixture.selected[0] = "poly-1"
	if not _activate_tool(fixture, &"select", "polygon keyboard resize"):
		return
	var handled: bool = fixture.plugin.handle_key(_key(KEY_RIGHT, false, false, true))
	var polygon := _region_polygon(fixture.store.get_corrected_record(0), "poly-1")
	_expect(handled, "Alt+arrow should be consumed by Selection's keyboard resize")
	_expect_equal(POLYGON_OPS.polygon_bounds(polygon), Rect2(40, 40, 16, 15), "Alt+Right should grow a polygon bounds width by one image pixel")
	_expect(POLYGON_OPS.validate_simple_polygon(polygon), "keyboard affine resize must keep a V1-safe simple polygon")
	_expect_equal(fixture.history.get_undo_count(), 1, "one Alt+arrow polygon resize should create exactly one command")
	_expect_equal(fixture.class_requests, [], "Select keyboard nudge/resize must never request a new-region class")


func _test_selection_move_and_nudge_never_request_class() -> void:
	var moved := _base_fixture()
	moved.selected[0] = "box-1"
	if _activate_tool(moved, &"select", "Select pointer move without class request"):
		_pointer(moved.plugin, true, Vector2(20, 17), moved.viewport)
		_motion(moved.plugin, Vector2(22, 19), moved.viewport)
		_pointer(moved.plugin, false, Vector2(22, 19), moved.viewport)
		var region := _find_region(moved.store.get_corrected_record(0), "box-1")
		_expect_equal([region.get("class"), region.get("kind")], ["grasper", "instrument"], "Select move must preserve class and kind")
		_expect_equal(moved.class_requests, [], "Select move must never request a new-region class")

	var nudged := _base_fixture()
	nudged.selected[0] = "box-1"
	if _activate_tool(nudged, &"select", "Select keyboard nudge without class request"):
		_expect(nudged.plugin.handle_key(_key(KEY_RIGHT)), "plain arrow should nudge the selected region")
		var region := _find_region(nudged.store.get_corrected_record(0), "box-1")
		_expect_equal([region.get("class"), region.get("kind")], ["grasper", "instrument"], "Select nudge must preserve class and kind")
		_expect_equal(nudged.class_requests, [], "Select nudge must never request a new-region class")


func _test_lasso_adds_one_polygon_and_cancel_restores_preview() -> void:
	var fixture := _base_fixture()
	if not _activate_tool(fixture, &"lasso", "Lasso"):
		return
	var before: Dictionary = fixture.store.get_corrected_record(0)
	_pointer(fixture.plugin, true, Vector2(15, 12), fixture.viewport)
	for point: Vector2 in [Vector2(25, 12), Vector2(25, 22), Vector2(15, 22), Vector2(15, 12)]:
		_motion(fixture.plugin, point, fixture.viewport)
	var drawing_candidate := _overlay(fixture)
	_expect_equal(drawing_candidate.get("phase"), &"candidate", "a closed freehand Lasso should become a visible candidate before release")
	_expect(not drawing_candidate.get("candidate_polygon", PackedVector2Array()).is_empty(), "freehand Lasso should visibly fill its interior while the pointer is still held")
	_expect_equal(drawing_candidate.get("fill_color"), Color("#22c55e"), "a valid pre-release freehand candidate should be green")
	_expect_equal(fixture.store.get_corrected_record(0), before, "a visible freehand fill remains transient before release")
	_expect_equal(fixture.history.get_undo_count(), 0, "a visible freehand fill must not enter history before release")
	_pointer(fixture.plugin, false, Vector2(15, 12), fixture.viewport)
	_expect(_confirm_pending_polygon(fixture).is_empty(), "closed Lasso should accept class assignment")
	var after: Dictionary = fixture.store.get_corrected_record(0)
	_expect_equal(after.regions.size(), before.regions.size() + 1, "one closed Lasso gesture should add exactly one region")
	var added: Dictionary = after.regions.back() if after.regions.size() > before.regions.size() else {}
	_expect(POLYGON_OPS.validate_simple_polygon(_polygon_from_value(added.get("polygon", []))), "Lasso should commit a finite simple polygon")
	_expect(not added.has("box"), "Lasso should not add fallback box geometry")
	_expect_equal(fixture.history.get_undo_count(), 1, "one Lasso gesture should create exactly one command")
	_expect_equal(after.regions[0], before.regions[0], "an overlapping Lasso must not alter the first existing region")
	_expect_equal(after.regions[1], before.regions[1], "an overlapping Lasso must not alter any other existing region")
	var filled_candidate := _latest_overlay_with_phase(fixture, &"candidate")
	_expect(not filled_candidate.get("candidate_polygon", PackedVector2Array()).is_empty(), "freehand Lasso should publish a filled candidate before commit")
	_expect_equal(filled_candidate.get("fill_color"), Color("#22c55e"), "freehand Lasso candidate should be green")

	var cancelled := _base_fixture()
	if not _activate_tool(cancelled, &"lasso", "Lasso cancellation"):
		return
	var cancelled_before: Dictionary = cancelled.store.get_corrected_record(0)
	var initial_record_count: int = cancelled.viewport.records.size()
	_pointer(cancelled.plugin, true, Vector2(60, 10), cancelled.viewport)
	_motion(cancelled.plugin, Vector2(80, 10), cancelled.viewport)
	_motion(cancelled.plugin, Vector2(80, 30), cancelled.viewport)
	_motion(cancelled.plugin, Vector2(60, 30), cancelled.viewport)
	_expect_equal(cancelled.viewport.records.size(), initial_record_count, "an in-progress Lasso must not publish a fake record")
	_expect_equal(_overlay(cancelled).get("phase"), &"drawing", "an in-progress Lasso should publish a transient EditOverlay path")
	cancelled.plugin.cancel()
	_expect_equal(cancelled.store.get_corrected_record(0), cancelled_before, "cancelling Lasso must leave Store unchanged")
	_expect_equal(cancelled.history.get_undo_count(), 0, "cancelling Lasso must not enter history")
	_expect_equal(_overlay(cancelled), {}, "cancelling Lasso should clear only its transient overlay")


func _test_every_polygon_creation_path_waits_for_class_assignment() -> void:
	var lasso_freehand := _base_fixture()
	if _activate_tool(lasso_freehand, &"lasso", "pending freehand Lasso"):
		var before: Dictionary = lasso_freehand.store.get_corrected_record(0)
		_gesture(lasso_freehand.plugin, lasso_freehand.viewport, [
			Vector2(60, 10), Vector2(80, 10), Vector2(80, 30), Vector2(60, 30), Vector2(60, 10),
		])
		_expect_pending_polygon_transaction(lasso_freehand, before, &"lasso", " lasso lesion ", " lasso kind ")

	var lasso_space := _base_fixture()
	if _activate_tool(lasso_space, &"lasso", "pending anchored Lasso Space"):
		var before: Dictionary = lasso_space.store.get_corrected_record(0)
		for anchor: Vector2 in [Vector2(60, 10), Vector2(80, 10), Vector2(80, 30), Vector2(60, 30)]:
			_click(lasso_space.plugin, lasso_space.viewport, anchor)
		_expect(lasso_space.plugin.handle_key(_key(KEY_SPACE)), "anchored Lasso Space should complete geometry")
		_expect_pending_polygon_transaction(lasso_space, before, &"lasso", "anchor lesion", "anchor kind")

	var lasso_double := _base_fixture()
	if _activate_tool(lasso_double, &"lasso", "pending anchored Lasso double-click"):
		var before: Dictionary = lasso_double.store.get_corrected_record(0)
		for anchor: Vector2 in [Vector2(60, 10), Vector2(80, 10), Vector2(80, 30)]:
			_click(lasso_double.plugin, lasso_double.viewport, anchor)
		_pointer(lasso_double.plugin, true, Vector2(60, 30), lasso_double.viewport, true)
		_pointer(lasso_double.plugin, false, Vector2(60, 30), lasso_double.viewport, true)
		_expect_pending_polygon_cancel(lasso_double, before, &"lasso")



func _test_lasso_anchor_hover_threshold_double_click_and_round_trip() -> void:
	var fixture := _base_fixture()
	if not _activate_tool(fixture, &"lasso", "anchored Lasso lifecycle"):
		return
	var expected_before := _record()
	_pointer(fixture.plugin, true, Vector2(60, 10), fixture.viewport)
	_motion(fixture.plugin, Vector2(62, 10), fixture.viewport)
	_pointer(fixture.plugin, false, Vector2(62, 10), fixture.viewport)
	var one_anchor := _overlay(fixture)
	_expect_equal(one_anchor.get("phase"), &"drawing", "exactly two image pixels must remain a click-anchor gesture")
	_expect_equal(one_anchor.get("path"), PackedVector2Array([Vector2(60, 10)]), "click jitter should retain the pressed image-space anchor")
	_expect_equal(one_anchor.get("fill_color"), Color("#22d3ee"), "one-point Lasso press/anchor state should remain cyan")
	_expect_equal(fixture.history.get_undo_count(), 0, "one anchor remains transient")

	_hover(fixture.plugin, Vector2(80, 10), fixture.viewport)
	_expect_equal(
		_overlay(fixture).get("path"),
		PackedVector2Array([Vector2(60, 10), Vector2(80, 10)]),
		"no-button hover should draw the open segment from the last Lasso anchor",
	)
	_click(fixture.plugin, fixture.viewport, Vector2(80, 10))
	_click(fixture.plugin, fixture.viewport, Vector2(80, 30))
	_hover(fixture.plugin, Vector2(60, 30), fixture.viewport)
	var anchored_candidate := _overlay(fixture)
	_expect_equal(anchored_candidate.get("phase"), &"candidate", "three anchors plus hover should expose the impending filled polygon")
	_expect_equal(anchored_candidate.get("candidate_polygon"), PackedVector2Array([
		Vector2(60, 10), Vector2(80, 10), Vector2(80, 30), Vector2(60, 30),
	]), "anchored hover should fill the candidate while retaining the open segment")
	_expect_equal(anchored_candidate.get("path"), PackedVector2Array([
		Vector2(60, 10), Vector2(80, 10), Vector2(80, 30), Vector2(60, 30),
	]), "anchored candidate should keep its visible hover path")
	_pointer(fixture.plugin, true, Vector2(60, 30), fixture.viewport, true)
	_pointer(fixture.plugin, false, Vector2(60, 30), fixture.viewport, true)
	_expect(_confirm_pending_polygon(fixture).is_empty(), "anchored Lasso should accept class assignment")
	var after: Dictionary = fixture.store.get_corrected_record(0)
	_expect_equal(after.regions.size(), 3, "double-click closure should add exactly one polygon despite its trailing release")
	var added: Dictionary = after.regions[2] if after.regions.size() == 3 else {}
	var added_id := str(added.get("id", ""))
	_expect(not added_id.is_empty(), "successful Lasso should allocate one non-empty region ID")
	_expect_equal(_polygon_from_value(added.get("polygon", [])), PackedVector2Array([
		Vector2(60, 10), Vector2(80, 10), Vector2(80, 30), Vector2(60, 30),
	]), "anchored Lasso should preserve the four explicit image-space anchors")
	_expect_equal(fixture.selected[0], added_id, "successful Lasso should select the new region")
	_expect_equal(fixture.history.get_undo_count(), 1, "double-click press/release must finalize only once")
	var candidate := _latest_overlay_with_phase(fixture, &"candidate")
	_expect_equal(candidate.get("candidate_polygon"), PackedVector2Array([
		Vector2(60, 10), Vector2(80, 10), Vector2(80, 30), Vector2(60, 30),
	]), "Lasso should publish the filled candidate before its command")
	_expect_equal(candidate.get("fill_color"), Color("#22c55e"), "a valid Lasso candidate should be green")
	_expect_equal(after.regions[0], expected_before.regions[0], "Lasso overlap must not alter the first existing region")
	_expect_equal(after.regions[1], expected_before.regions[1], "Lasso overlap must not alter the second existing region")

	var expected_after := expected_before.duplicate(true)
	expected_after.regions.append({
		"id": added_id,
		"class": "unknown",
		"kind": "region",
		"polygon": [[60.0, 10.0], [80.0, 10.0], [80.0, 30.0], [60.0, 30.0]],
		"track_id": null,
	})
	_expect(fixture.history.undo(fixture.store), "anchored Lasso should undo")
	_expect_equal(fixture.store.get_corrected_record(0), expected_before, "anchored Lasso undo should restore the independent original record")
	_expect_equal(fixture.history.redo(fixture.store), PackedStringArray(), "anchored Lasso should redo")
	_expect_equal(fixture.store.get_corrected_record(0), expected_after, "anchored Lasso redo should restore the independently expected record")


func _test_lasso_retains_filled_invalid_candidates_for_correction() -> void:
	var out_of_bounds := _base_fixture()
	if _activate_tool(out_of_bounds, &"lasso", "out-of-bounds anchored Lasso"):
		for point: Vector2 in [Vector2(60, 10), Vector2(80, 10), Vector2(80, 30), Vector2(101, 30)]:
			_click(out_of_bounds.plugin, out_of_bounds.viewport, point)
		_expect(out_of_bounds.plugin.handle_key(_key(KEY_SPACE)), "Space should attempt the out-of-bounds closure")
		var invalid := _overlay(out_of_bounds)
		_expect_equal(invalid.get("phase"), &"invalid", "an out-of-bounds candidate should remain Invalid")
		var retained: Variant = invalid.get("candidate_polygon", PackedVector2Array())
		_expect(retained is PackedVector2Array and retained.size() == 4, "an out-of-bounds candidate should remain filled and editable")
		var invalid_message := String(invalid.get("message", ""))
		_hover(out_of_bounds.plugin, Vector2(70, 40), out_of_bounds.viewport)
		var hovered_invalid := _overlay(out_of_bounds)
		_expect_equal(hovered_invalid.get("phase"), &"invalid", "hover alone must not downgrade an out-of-bounds Lasso to Drawing")
		_expect_equal(hovered_invalid.get("fill_color"), INVALID_COLOR, "hover alone must keep an out-of-bounds Lasso red")
		_expect_equal(hovered_invalid.get("message"), invalid_message, "hover alone must preserve the image-bound refusal message")
		_expect_equal(hovered_invalid.get("candidate_polygon"), retained, "hover alone must preserve the explicitly invalid out-of-bounds candidate")
		_expect_equal(out_of_bounds.store.get_corrected_record(0), _record(), "out-of-bounds Lasso must preserve Store")
		_expect_equal(out_of_bounds.history.get_undo_count(), 0, "out-of-bounds Lasso must create zero commands")

	var working := _base_fixture()
	if _activate_tool(working, &"paint", "WorkingMask before Lasso/Subtract"):
		_install_working_mask(working, _outline_state(Rect2i(55, 10, 13, 13), 3, 9, [6, 7]), "protected")
		var mask_before := _session_snapshot(working.plugin)
		for blocked_tool: StringName in [&"lasso", &"subtract"]:
			_expect(not working.plugin.set_active_tool(blocked_tool).is_empty(), "%s activation should be refused before mutating a WorkingMask" % blocked_tool)
			_expect_equal(_session_snapshot(working.plugin), mask_before, "%s refusal must preserve every WorkingMask byte and session field" % blocked_tool)


func _test_lasso_freehand_strict_threshold_and_proximity() -> void:
	var fixture := _base_fixture()
	if not _activate_tool(fixture, &"lasso", "strict freehand threshold"):
		return
	_pointer(fixture.plugin, true, Vector2(60, 10), fixture.viewport)
	_motion(fixture.plugin, Vector2(62, 10), fixture.viewport)
	_expect_equal(_overlay(fixture).get("path"), PackedVector2Array([Vector2(60, 10)]), "movement equal to two image pixels must not become freehand")
	_motion(fixture.plugin, Vector2(62.01, 10), fixture.viewport)
	_expect_equal(_overlay(fixture).get("path"), PackedVector2Array([
		Vector2(60, 10), Vector2(62.01, 10),
	]), "movement greater than two image pixels must become freehand")
	_motion(fixture.plugin, Vector2(80, 10), fixture.viewport)
	_motion(fixture.plugin, Vector2(80, 30), fixture.viewport)
	_motion(fixture.plugin, Vector2(60, 30), fixture.viewport)
	_pointer(fixture.plugin, false, Vector2(60, 30), fixture.viewport)
	var retained_invalid := _overlay(fixture)
	_expect_equal(retained_invalid.get("phase"), &"invalid", "freehand release farther than the explicit close radius should remain a retained Invalid candidate")
	var retained_message := String(retained_invalid.get("message", ""))
	var retained_candidate: PackedVector2Array = retained_invalid.get("candidate_polygon", PackedVector2Array())
	_hover(fixture.plugin, Vector2(60, 10), fixture.viewport)
	_expect_equal(_overlay(fixture).get("phase"), &"candidate", "a tentatively valid hover may preview the retained anchors in green")
	_expect_equal(_overlay(fixture).get("fill_color"), Color("#22c55e"), "tentatively valid hover should use the candidate fill")
	_hover(fixture.plugin, Vector2(70, 5), fixture.viewport)
	var invalid_again := _overlay(fixture)
	_expect_equal(invalid_again.get("phase"), &"invalid", "moving the tentative hover back to invalid geometry must restore Invalid")
	_expect_equal(invalid_again.get("fill_color"), INVALID_COLOR, "moving the tentative hover back to invalid geometry must restore red")
	_expect_equal(invalid_again.get("message"), retained_message, "invalid hover must restore the retained refusal message")
	_expect_equal(invalid_again.get("candidate_polygon"), retained_candidate, "hover must never mutate the retained anchors")
	_expect_equal(fixture.store.get_corrected_record(0), _record(), "an open freehand Lasso must preserve Store")
	_expect_equal(fixture.history.get_undo_count(), 0, "an open freehand Lasso must create zero commands")


func _test_lasso_auto_closes_a_near_release_and_accepts_multiple_enclosures() -> void:
	var near := _base_fixture()
	if _activate_tool(near, &"lasso", "near-release Lasso auto-close"):
		_gesture(near.plugin, near.viewport, [
			Vector2(60, 10), Vector2(80, 10), Vector2(80, 30),
			Vector2(60, 30), Vector2(60, 15),
		])
		_expect_equal(_overlay(near).get("phase"), &"awaiting_class", "a five-image-pixel release gap should auto-close at the current two-times view scale")
		_expect(_confirm_pending_polygon(near, "near lasso", "region").is_empty(), "an auto-closed Lasso should accept class assignment")
		_expect_equal(near.history.get_undo_count(), 1, "an auto-closed Lasso should create one undo item")

	var multi := _base_fixture()
	if not _activate_tool(multi, &"lasso", "multi-enclosure Lasso"):
		return
	_gesture(multi.plugin, multi.viewport, _figure_eight_gesture())
	var pending := _overlay(multi)
	_expect_equal(pending.get("phase"), &"awaiting_class", "one continuous Lasso with two enclosed lobes should become a valid solid candidate")
	var candidate: PackedVector2Array = pending.get("candidate_polygon", PackedVector2Array())
	_expect(Geometry2D.is_point_in_polygon(Vector2(20, 18), candidate), "the multi-enclosure Lasso should include its left lobe")
	_expect(Geometry2D.is_point_in_polygon(Vector2(60, 18), candidate), "the multi-enclosure Lasso should include its right lobe")
	_expect(_confirm_pending_polygon(multi, "two lobes", "region").is_empty(), "the multi-enclosure Lasso should use one class assignment")
	_expect_equal(multi.history.get_undo_count(), 1, "a multi-enclosure Lasso should remain one undoable edit")


func _test_freehand_preview_is_bounded_before_commit_validation() -> void:
	var image := Image.create(220, 180, false, Image.FORMAT_RGBA8)
	image.fill(Color.BLACK)
	var fixture := _fixture(_record(), image)
	if not _activate_tool(fixture, &"lasso", "bounded Lasso preview"):
		return
	var point_count := 160
	var points: Array[Vector2] = []
	for index in range(point_count):
		var angle := TAU * float(index) / float(point_count)
		points.append(Vector2(110, 90) + Vector2(cos(angle), sin(angle)) * 45.0)
	_pointer(fixture.plugin, true, points[0], fixture.viewport)
	for index in range(1, points.size()):
		_motion(fixture.plugin, points[index], fixture.viewport)
	var preview: Dictionary = _overlay(fixture)
	var contour: PackedVector2Array = preview.get("path", PackedVector2Array())
	_expect(not contour.is_empty(), "a long Lasso gesture should still show a contour preview")
	_expect(
		contour.size() <= 128,
		"freehand preview validation must stay bounded instead of becoming O(n^3) across the full gesture",
	)
	fixture.plugin.cancel()

	# Index 4 is omitted by the 160 -> 128 preview sampler.  Final validation
	# must still inspect this raw out-of-bounds point before simplification.
	var raw_fixture := _fixture(_record(), image)
	if not _activate_tool(raw_fixture, &"lasso", "raw Lasso validation"):
		return
	points[4] = Vector2(221, 105)
	_pointer(raw_fixture.plugin, true, points[0], raw_fixture.viewport)
	for index in range(1, points.size()):
		_motion(raw_fixture.plugin, points[index], raw_fixture.viewport)
	_pointer(raw_fixture.plugin, false, points.back(), raw_fixture.viewport)
	var invalid := _overlay(raw_fixture)
	_expect_equal(invalid.get("phase"), &"invalid", "an unsampled out-of-bounds raw point must invalidate the full gesture")
	_expect(String(invalid.get("message", "")).contains("inside"), "raw-path refusal should explain the image boundary")
	_expect_equal(raw_fixture.store.get_corrected_record(0), _record(), "raw-path validation refusal must preserve Store")
	_expect_equal(raw_fixture.history.get_undo_count(), 0, "raw-path validation refusal must preserve history")


func _test_subtract_commits_one_v1_safe_ring() -> void:
	var fixture := _base_fixture()
	fixture.selected[0] = "box-1"
	if not _activate_tool(fixture, &"subtract", "Subtract"):
		return
	_gesture(fixture.plugin, fixture.viewport, [
		Vector2(25, 5),
		Vector2(35, 5),
		Vector2(35, 30),
		Vector2(25, 30),
		Vector2(25, 5),
	])
	var after: Dictionary = fixture.store.get_corrected_record(0)
	var region := _find_region(after, "box-1")
	var polygon := _polygon_from_value(region.get("polygon", []))
	_expect(POLYGON_OPS.validate_simple_polygon(polygon), "Subtract should replace the subject with one V1-safe simple ring")
	_expect(not region.has("box"), "Subtract should remove stale box geometry after a polygon result")
	_expect_equal(POLYGON_OPS.polygon_bounds(polygon), Rect2(10, 10, 15, 15), "Subtract should remove only the overlapping right strip")
	_expect(is_equal_approx(_absolute_area(polygon), 225.0), "Subtract should preserve the hand-derived remaining area")
	_expect_equal(region.get("conf"), 0.9, "Subtract should preserve confidence metadata")
	_expect_equal(region.get("track_id"), "T01", "Subtract should preserve track metadata")
	_expect_equal(fixture.history.get_undo_count(), 1, "one successful Subtract gesture should create exactly one command")
	_expect_equal(fixture.class_requests, [], "Subtract on an existing region must never request a new-region class")
	var expected_after := _record()
	expected_after.regions[0].erase("box")
	expected_after.regions[0]["polygon"] = [[25.0, 25.0], [10.0, 25.0], [10.0, 10.0], [25.0, 10.0]]
	_expect_equal(after, expected_after, "successful Subtract should commit the independently expected record")
	_expect(fixture.history.undo(fixture.store), "successful Subtract should undo")
	_expect_equal(fixture.store.get_corrected_record(0), _record(), "Subtract undo should restore the independent original record")
	_expect_equal(fixture.history.redo(fixture.store), PackedStringArray(), "successful Subtract should redo")
	var redone: Dictionary = fixture.store.get_corrected_record(0)
	_expect_equal(redone, expected_after, "Subtract redo should restore the independently expected record")


func _test_subtract_refuses_holes_and_multiple_components_atomically() -> void:
	var cases := [
		{
			"name": "hole",
			"points": [Vector2(15, 13), Vector2(20, 13), Vector2(20, 18), Vector2(15, 18), Vector2(15, 13)],
		},
		{
			"name": "multiple components",
			"points": [Vector2(19, 5), Vector2(21, 5), Vector2(21, 30), Vector2(19, 30), Vector2(19, 5)],
		},
	]
	for case: Dictionary in cases:
		var fixture := _base_fixture()
		fixture.selected[0] = "box-1"
		if not _activate_tool(fixture, &"subtract", "Subtract %s refusal" % case.name):
			continue
		_gesture(fixture.plugin, fixture.viewport, case.points)
		_expect_retained_subtract(fixture, case.points, _record(), "box-1", "refused %s" % case.name)
		_expect_equal(fixture.store.get_corrected_record(0), _record(), "Subtract must refuse a %s without losing the independently expected geometry" % case.name)
		_expect_equal(fixture.selected[0], "box-1", "a refused %s subtraction must preserve selection" % case.name)
		_expect_equal(fixture.history.get_undo_count(), 0, "a refused %s subtraction must not enter history" % case.name)
		_expect(not fixture.statuses.is_empty(), "a refused %s subtraction should explain the V1 boundary" % case.name)


func _test_subtract_refuses_empty_noop_invalid_and_out_of_bounds_atomically() -> void:
	var cases := [
		{
			"name": "full/empty",
			"points": [Vector2(5, 5), Vector2(35, 5), Vector2(35, 30), Vector2(5, 30), Vector2(5, 5)],
		},
		{
			"name": "disjoint equivalent with extra collinear vertices",
			"points": [Vector2(60, 60), Vector2(70, 60), Vector2(80, 60), Vector2(80, 70), Vector2(70, 70), Vector2(60, 70), Vector2(60, 60)],
		},
		{
			"name": "self-intersecting",
			"points": [Vector2(12, 12), Vector2(28, 23), Vector2(12, 23), Vector2(28, 12), Vector2(12, 12)],
		},
		{
			"name": "out-of-bounds",
			"points": [Vector2(20, 10), Vector2(101, 10), Vector2(101, 20), Vector2(20, 20), Vector2(20, 10)],
		},
	]
	for case: Dictionary in cases:
		var fixture := _base_fixture()
		fixture.selected[0] = "box-1"
		if not _activate_tool(fixture, &"subtract", "Subtract %s" % case.name):
			continue
		_gesture(fixture.plugin, fixture.viewport, case.points)
		_expect_retained_subtract(fixture, case.points, _record(), "box-1", "refused %s" % case.name)
		_expect_equal(fixture.store.get_corrected_record(0), _record(), "Subtract %s refusal must preserve the independently expected Store" % case.name)
		_expect_equal(fixture.selected[0], "box-1", "Subtract %s refusal must preserve selection" % case.name)
		_expect_equal(fixture.history.get_undo_count(), 0, "Subtract %s refusal must create zero commands" % case.name)
		_expect(not fixture.statuses.is_empty(), "Subtract %s refusal/no-op should explain why nothing committed" % case.name)


func _test_unselected_subtract_deletes_across_regions_atomically() -> void:
	var record := {
		"schema_version": 1,
		"source": "sample_v1",
		"frame": 0,
		"regions": [
			{"id": "left", "class": "tissue", "kind": "region", "box": [10, 10, 20, 20], "track_id": null},
			{"id": "right", "class": "tool", "kind": "instrument", "box": [40, 10, 20, 20], "track_id": "T02"},
		],
	}
	var fixture := _fixture(record, _flat_image())
	if not _activate_tool(fixture, &"subtract", "unselected multi-region Subtract"):
		return
	var contour := [
		Vector2(5, 5), Vector2(50, 5), Vector2(50, 35),
		Vector2(5, 35), Vector2(5, 5),
	]
	_gesture(fixture.plugin, fixture.viewport, contour)
	var after: Dictionary = fixture.store.get_corrected_record(0)
	_expect(_find_region(after, "left").is_empty(), "unselected Subtract should delete a fully covered object")
	var remaining := _find_region(after, "right")
	_expect(not remaining.is_empty(), "unselected Subtract should retain a partially covered object")
	_expect_equal(remaining.get("track_id"), "T02", "unselected Subtract should preserve metadata on a partially covered object")
	_expect_equal(POLYGON_OPS.polygon_bounds(_polygon_from_value(remaining.get("polygon", []))), Rect2(50, 10, 10, 20), "unselected Subtract should keep the independently expected right-hand remainder")
	_expect_equal(fixture.selected[0], "", "unselected Subtract should remain unselected after its batch commit")
	_expect_equal(fixture.history.get_undo_count(), 1, "one multi-region Subtract gesture should create exactly one history command")
	_expect(fixture.history.undo(fixture.store), "one undo should restore every object changed by unselected Subtract")
	_expect_equal(fixture.store.get_corrected_record(0), record, "batch Subtract undo should restore the exact original record")

	var refusal := _fixture(record, _flat_image())
	if not _activate_tool(refusal, &"subtract", "unselected atomic Subtract refusal"):
		return
	var hole := [Vector2(15, 15), Vector2(20, 15), Vector2(20, 20), Vector2(15, 20), Vector2(15, 15)]
	_gesture(refusal.plugin, refusal.viewport, hole)
	_expect_equal(refusal.store.get_corrected_record(0), record, "one V1-inexpressible batch result must reject the entire unselected Subtract")
	_expect_equal(refusal.history.get_undo_count(), 0, "an atomically refused unselected Subtract must create no history")
	_expect_equal(_overlay(refusal).get("phase"), &"invalid", "an atomically refused unselected Subtract should retain its contour for correction")


func _test_subtract_auto_closes_a_near_release_and_deletes_multiple_enclosures() -> void:
	var near_record := {
		"schema_version": 1,
		"source": "sample_v1",
		"frame": 0,
		"regions": [
			{"id": "near", "class": "tissue", "kind": "region", "box": [60, 12, 12, 12], "track_id": null},
		],
	}
	var near := _fixture(near_record, _flat_image())
	if _activate_tool(near, &"subtract", "near-release Subtract auto-close"):
		_gesture(near.plugin, near.viewport, [
			Vector2(55, 8), Vector2(78, 8), Vector2(78, 28),
			Vector2(55, 28), Vector2(55, 13),
		])
		_expect(_find_region(near.store.get_corrected_record(0), "near").is_empty(), "a small release gap should auto-close and delete the fully enclosed object")
		_expect_equal(near.history.get_undo_count(), 1, "near-release Subtract should commit once")

	var multi_record := {
		"schema_version": 1,
		"source": "sample_v1",
		"frame": 0,
		"regions": [
			{"id": "left", "class": "tissue", "kind": "region", "box": [16, 14, 8, 8], "track_id": null},
			{"id": "right", "class": "tool", "kind": "instrument", "box": [56, 14, 8, 8], "track_id": null},
		],
	}
	var multi := _fixture(multi_record, _flat_image())
	if not _activate_tool(multi, &"subtract", "multi-enclosure Subtract"):
		return
	_gesture(multi.plugin, multi.viewport, _figure_eight_gesture())
	var after: Dictionary = multi.store.get_corrected_record(0)
	_expect_equal(after.regions.size(), 0, "all enclosed lobes in one Subtract gesture should be applied, even when the path repeats its crossing")
	_expect_equal(multi.history.get_undo_count(), 1, "multi-enclosure Subtract should create one atomic undo item")
	_expect(multi.history.undo(multi.store), "multi-enclosure Subtract should undo")
	_expect_equal(multi.store.get_corrected_record(0), multi_record, "one undo should restore every region removed by all enclosed lobes")


func _test_subtract_command_failure_retains_retryable_transaction() -> void:
	var fixture := _base_fixture()
	var rejecting_store := RejectOnceStore.new(fixture.store)
	fixture.store = rejecting_store
	fixture.context["store"] = rejecting_store
	fixture.selected[0] = "box-1"
	if not _activate_tool(fixture, &"subtract", "Subtract command failure"):
		return
	var strip := [Vector2(25, 5), Vector2(35, 5), Vector2(35, 30), Vector2(25, 30), Vector2(25, 5)]
	_pointer(fixture.plugin, true, strip[0], fixture.viewport)
	for index in range(1, strip.size()):
		_motion(fixture.plugin, strip[index], fixture.viewport)
	rejecting_store.reject_next_replace = true
	_pointer(fixture.plugin, false, strip.back(), fixture.viewport)
	_expect_retained_subtract(fixture, strip, _record(), "box-1", "command failure")
	_expect_equal(rejecting_store.get_corrected_record(0), _record(), "a rejected Replace command must preserve Store exactly")
	_expect_equal(fixture.selected[0], "box-1", "a rejected Replace command must preserve selection")
	_expect_equal(fixture.history.get_undo_count(), 0, "a rejected Replace command must not enter history")
	_expect(String(_overlay(fixture).get("message", "")).contains("forced replacement rejection"), "a command failure should retain its concrete error")

	_gesture(fixture.plugin, fixture.viewport, strip)
	_expect(rejecting_store.get_corrected_record(0) != _record(), "a new pointer contour should retry successfully after a retained command failure")
	_expect_equal(fixture.selected[0], "box-1", "pointer retry success should keep the committed target selected")
	_expect_equal(fixture.history.get_undo_count(), 1, "only the successful pointer retry should create one command")
	_expect_equal(_overlay(fixture), {}, "successful pointer retry should clear the retained refusal")


func _test_brush_radius_contract_and_distinct_overlay_colors() -> void:
	var descriptors: Array = PLUGIN_SCRIPT.new().get_tool_descriptors()
	for tool_id: StringName in [&"paint", &"eraser"]:
		var descriptor := _descriptor(descriptors, tool_id)
		var options: Variant = descriptor.get("options", [])
		_expect(options is Array and options.size() == 1, "%s should expose exactly the shared brush-radius option" % tool_id)
		if not options is Array or options.size() != 1:
			continue
		var option: Dictionary = options[0]
		_expect_equal(option.get("min"), 1.0, "%s radius minimum should be one image pixel" % tool_id)
		_expect_equal(option.get("max"), 40.0, "%s radius maximum should be forty image pixels" % tool_id)
		_expect_equal(option.get("default"), 8.0, "%s radius default should be eight image pixels" % tool_id)
		_expect_equal(option.get("shared_key"), &"brush_radius", "%s should use the shared radius state" % tool_id)

	var fixture := _base_fixture()
	fixture.selected[0] = "box-1"
	if not _activate_tool(fixture, &"paint", "Paint radius and overlay"):
		return
	var before: Dictionary = fixture.store.get_corrected_record(0)
	_pointer(fixture.plugin, true, Vector2(28, 17), fixture.viewport)
	var default_overlay := _overlay(fixture)
	_expect_equal(default_overlay.get("brush_radius"), 8.0, "Paint should preview the default eight-image-pixel circle")
	_expect_equal(default_overlay.get("fill_color"), PAINT_OVERLAY_COLOR, "Paint should use the additive overlay color")
	fixture.plugin.cancel()

	_expect(fixture.plugin.invoke(&"set_tool_option", {"option_id": &"brush_radius", "value": 1.0}).is_empty(), "the shared brush radius should accept one image pixel")
	_pointer(fixture.plugin, true, Vector2(28, 17), fixture.viewport)
	_expect_equal(_overlay(fixture).get("brush_radius"), 1.0, "Paint should preview a one-image-pixel circle exactly")
	fixture.plugin.cancel()

	_expect(fixture.plugin.invoke(&"set_tool_option", {"option_id": &"brush_radius", "value": 40.0}).is_empty(), "the shared brush radius should accept forty image pixels")
	_expect(fixture.plugin.set_active_tool(&"eraser").is_empty(), "Eraser should activate after changing Paint's shared radius")
	_pointer(fixture.plugin, true, Vector2(28, 17), fixture.viewport)
	var eraser_overlay := _overlay(fixture)
	_expect_equal(eraser_overlay.get("brush_radius"), 40.0, "Eraser should inherit Paint's forty-image-pixel radius")
	_expect_equal(eraser_overlay.get("fill_color"), ERASER_OVERLAY_COLOR, "Eraser should use the subtractive overlay color")
	_expect(eraser_overlay.get("fill_color") != default_overlay.get("fill_color"), "Paint and Eraser overlays must remain visibly distinct")
	fixture.plugin.cancel()
	_expect_equal(fixture.store.get_corrected_record(0), before, "radius previews must not mutate Store")
	_expect_equal(fixture.history.get_undo_count(), 0, "radius previews must not enter history")


func _test_paint_unions_one_brush_stroke() -> void:
	var fixture := _base_fixture()
	fixture.selected[0] = "box-1"
	if not _activate_tool(fixture, &"paint", "Paint"):
		return
	fixture.plugin.invoke(&"set_tool_option", {"option_id": &"brush_radius", "value": 4.0})
	var before: Dictionary = fixture.store.get_corrected_record(0)
	var record_preview_count: int = fixture.viewport.records.size()
	_pointer(fixture.plugin, true, Vector2(27, 17), fixture.viewport)
	_motion(fixture.plugin, Vector2(35, 17), fixture.viewport)
	_motion(fixture.plugin, Vector2(40, 17), fixture.viewport)
	_expect_equal(fixture.store.get_corrected_record(0), before, "Paint motion should update only transient path and circle state")
	_expect_equal(fixture.history.get_undo_count(), 0, "Paint motion should not enter history before release")
	_expect_equal(fixture.viewport.records.size(), record_preview_count, "Paint motion must not publish a fake preview record")
	_expect_equal(_overlay(fixture).get("phase"), &"drawing", "Paint motion should remain a drawing session")
	_pointer(fixture.plugin, false, Vector2(40, 17), fixture.viewport)
	var after: Dictionary = fixture.store.get_corrected_record(0)
	var polygon := _region_polygon(after, "box-1")
	_expect(POLYGON_OPS.validate_simple_polygon(polygon), "Paint should union its brush stroke into one simple polygon")
	_expect(_absolute_area(polygon) > _absolute_area(_region_polygon(before, "box-1")), "Paint should add area outside the original 20x15 box")
	_expect(POLYGON_OPS.polygon_bounds(polygon).end.x > 30.0, "Paint should extend geometry along the visible brush stroke")
	_expect_equal(fixture.history.get_undo_count(), 1, "one Paint stroke should create exactly one command")
	_expect_equal(fixture.class_requests, [], "selected Paint must preserve metadata without requesting a class")
	_expect(after != before, "Paint should change the corrected snapshot only on release")
	var idle_cursor := _overlay(fixture)
	_expect_equal(idle_cursor.get("phase"), &"brush_cursor", "successful Paint should immediately restore its idle brush cursor")
	_expect_equal(idle_cursor.get("cursor"), Vector2(40, 17), "restored Paint cursor should stay at the release point")
	_expect_equal(idle_cursor.get("path"), PackedVector2Array(), "restored Paint cursor must not retain the completed trajectory")


func _test_unselected_paint_adds_one_simple_region() -> void:
	var fixture := _base_fixture()
	if not _activate_tool(fixture, &"paint", "unselected Paint"):
		return
	fixture.plugin.invoke(&"set_tool_option", {"option_id": &"brush_radius", "value": 3.0})
	var before: Dictionary = fixture.store.get_corrected_record(0)
	_gesture(fixture.plugin, fixture.viewport, [Vector2(60, 15), Vector2(68, 15), Vector2(75, 15)])
	_expect(_confirm_pending_polygon(fixture).is_empty(), "unselected Paint should accept class assignment")
	var after: Dictionary = fixture.store.get_corrected_record(0)
	_expect_equal(after.regions.size(), before.regions.size() + 1, "unselected Paint should add one real region")
	var added: Dictionary = after.regions.back() if after.regions.size() > before.regions.size() else {}
	_expect(POLYGON_OPS.validate_simple_polygon(_polygon_from_value(added.get("polygon", []))), "unselected Paint should commit one simple V1 polygon")
	_expect(not added.has("box") and not added.has("mask") and not added.has("holes"), "unselected Paint must not persist fallback boxes, masks, or holes")
	_expect_equal(fixture.selected[0], str(added.get("id", "")), "unselected Paint should select the newly added region")
	_expect_equal(fixture.history.get_undo_count(), 1, "one unselected Paint stroke should create exactly one command")
	_expect_equal(_overlay(fixture).get("phase"), &"brush_cursor", "class-confirmed Paint should immediately restore its idle brush cursor")


func _test_paint_outline_fill_commits_without_losing_working_mask() -> void:
	var fixture := _base_fixture()
	if not _activate_tool(fixture, &"paint", "Paint outline to Fill"):
		return
	fixture.plugin.invoke(&"set_tool_option", {"option_id": &"brush_radius", "value": 2.0})
	var before: Dictionary = fixture.store.get_corrected_record(0)
	_gesture(fixture.plugin, fixture.viewport, [
		Vector2(60, 10), Vector2(80, 10), Vector2(80, 35),
		Vector2(60, 35), Vector2(60, 10),
	])
	var working := _overlay(fixture).duplicate(true)
	_expect_equal(working.get("phase"), &"working_mask", "a closed Paint outline should become a reusable WorkingMask")
	_expect_equal(working.get("fill_color"), WORKING_MASK_COLOR, "the retained Paint outline should use the orange WorkingMask color")
	_expect(not working.get("mask_preview", {}).is_empty(), "the retained Paint outline should preserve its exact mask bytes")
	_expect(String(working.get("message", "")).contains("Fill"), "the retained Paint outline should explain that Fill is the next action")
	_expect_equal(fixture.store.get_corrected_record(0), before, "a Paint outline must remain transient until Fill and class confirmation")
	_expect_equal(fixture.history.get_undo_count(), 0, "a Paint outline must not enter history before it becomes one V1 polygon")

	_expect(fixture.plugin.set_active_tool(&"fill").is_empty(), "Fill should activate without clearing a Paint WorkingMask")
	_expect_equal(_overlay(fixture), working, "switching from a Paint outline to Fill must preserve every WorkingMask byte")
	_click(fixture.plugin, fixture.viewport, Vector2(50, 10))
	_expect_equal(_overlay(fixture).get("phase"), &"working_mask", "a failed Fill click must keep the Paint WorkingMask retryable")
	_expect_equal(_overlay(fixture).get("mask_preview"), working.get("mask_preview"), "a failed Fill click must not replace or clear the retained mask")
	_expect_equal(fixture.store.get_corrected_record(0), before, "a failed Fill click must preserve Store")
	_expect_equal(fixture.history.get_undo_count(), 0, "a failed Fill click must preserve history")

	_click(fixture.plugin, fixture.viewport, Vector2(70, 20))
	_expect_equal(_overlay(fixture).get("phase"), &"awaiting_class", "Fill inside the retained outline should produce one pending V1 polygon")
	_expect_equal(fixture.class_requests.size(), 1, "successful WorkingMask Fill should request class assignment exactly once")
	_expect(_confirm_pending_polygon(fixture, "paint-fill", "region").is_empty(), "the filled Paint outline should accept class confirmation")
	var after: Dictionary = fixture.store.get_corrected_record(0)
	_expect_equal(after.regions.size(), before.regions.size() + 1, "confirmed WorkingMask Fill should add exactly one object")
	var added: Dictionary = after.regions.back() if after.regions.size() == before.regions.size() + 1 else {}
	var polygon := _polygon_from_value(added.get("polygon", []))
	_expect(POLYGON_OPS.validate_simple_polygon(polygon), "WorkingMask Fill must persist one simple V1 polygon")
	_expect(Geometry2D.is_point_in_polygon(Vector2(70, 20), polygon), "the filled polygon should contain the clicked enclosed area")
	_expect_equal(fixture.history.get_undo_count(), 1, "Paint outline plus Fill plus class confirmation should create one undoable command")


func _test_figure_eight_paint_fill_accumulates_into_one_solid_object() -> void:
	var fixture := _base_fixture()
	if not _activate_tool(fixture, &"paint", "figure-eight Paint Fill"):
		return
	var before: Dictionary = fixture.store.get_corrected_record(0)
	_install_working_mask(fixture, _double_outline_state(), "Fill both enclosed lobes")
	_expect(fixture.plugin.set_active_tool(&"fill").is_empty(), "Fill should take ownership of the figure-eight WorkingMask")

	_click(fixture.plugin, fixture.viewport, Vector2(60, 16))
	var after_first := _overlay(fixture)
	_expect_equal(after_first.get("phase"), &"working_mask", "filling the first figure-eight lobe must keep the cumulative WorkingMask")
	_expect_equal(fixture.class_requests.size(), 0, "the first lobe must not request a class while another enclosed blank remains")
	_expect_equal(_mask_at(after_first.get("mask_preview", {}), Vector2i(60, 16)), 1, "the first clicked lobe should become foreground in the retained mask")
	_expect_equal(_mask_at(after_first.get("mask_preview", {}), Vector2i(60, 30)), 0, "the unclicked second lobe should remain blank and fillable")
	_expect_equal(fixture.store.get_corrected_record(0), before, "the partially filled figure-eight must remain transient")

	_click(fixture.plugin, fixture.viewport, Vector2(60, 30))
	var completed := _overlay(fixture)
	_expect_equal(completed.get("phase"), &"awaiting_class", "filling the second lobe should complete one solid candidate")
	_expect_equal(fixture.class_requests.size(), 1, "the completed solid figure-eight should request class assignment once")
	var candidate: PackedVector2Array = completed.get("candidate_polygon", PackedVector2Array())
	_expect(Geometry2D.is_point_in_polygon(Vector2(60, 16), candidate), "the final candidate should contain the first filled lobe")
	_expect(Geometry2D.is_point_in_polygon(Vector2(60, 30), candidate), "the final candidate should contain the second filled lobe")
	_expect(_confirm_pending_polygon(fixture, "gourd", "region").is_empty(), "the solid figure-eight should accept one class confirmation")
	var after: Dictionary = fixture.store.get_corrected_record(0)
	_expect_equal(after.regions.size(), before.regions.size() + 1, "two Fill clicks should create one object, not two inner objects")
	_expect_equal(fixture.history.get_undo_count(), 1, "the cumulative Paint and Fill workflow should create one undo item")


func _test_unselected_paint_outline_becomes_a_guarded_working_mask() -> void:
	var fixture := _base_fixture()
	if not _activate_tool(fixture, &"paint", "Paint outline WorkingMask"):
		return
	fixture.plugin.invoke(&"set_tool_option", {"option_id": &"brush_radius", "value": 2.0})
	var before: Dictionary = fixture.store.get_corrected_record(0)
	_gesture(fixture.plugin, fixture.viewport, [
		Vector2(55, 10), Vector2(80, 10), Vector2(80, 35),
		Vector2(55, 35), Vector2(55, 10),
	])
	var working := _overlay(fixture)
	_expect_equal(working.get("phase"), &"working_mask", "a bounded unselected Paint outline should remain a WorkingMask")
	_expect_equal(working.get("fill_color"), WORKING_MASK_COLOR, "a Paint WorkingMask should be visibly orange")
	_expect(not working.get("mask_preview", {}).is_empty(), "a Paint WorkingMask should preserve its bounded raw mask")
	_expect_equal(working.get("message"), "Paint outline is waiting for Fill, Close Gaps, or Escape", "the WorkingMask should explain its next valid actions")
	_expect_equal(fixture.store.get_corrected_record(0), before, "a Paint WorkingMask must remain transient")
	_expect_equal(fixture.history.get_undo_count(), 0, "a Paint WorkingMask must not enter history")
	_expect(fixture.statuses.has("Paint outline is waiting for Fill, Close Gaps, or Escape"), "the Paint outline should notify the edit state")

	_expect(fixture.plugin.set_active_tool(&"fill").is_empty(), "Fill should activate without cancelling the Paint WorkingMask")
	_expect_equal(_overlay(fixture), working, "switching a WorkingMask to Fill should preserve every mask byte")
	_expect(fixture.plugin.set_active_tool(&"close_gaps").is_empty(), "Close Gaps should activate without cancelling the Paint WorkingMask")
	_expect_equal(_overlay(fixture), working, "switching a WorkingMask to Close Gaps should preserve every mask byte")
	var expected_error := PackedStringArray(["Resolve the Paint working mask with Fill, Close Gaps, or Escape"])
	_expect_equal(fixture.plugin.set_active_tool(&"select"), expected_error, "every other tool switch should be refused while Paint has a WorkingMask")
	_expect_equal(_overlay(fixture), working, "a refused tool switch must not cancel the Paint WorkingMask")
	for action: Dictionary in [
		{"id": &"relabel_selected", "payload": {"class": "clip"}},
		{"id": &"set_tool_option", "payload": {"option_id": &"brush_radius", "value": 8.0}},
		{"id": &"undo", "payload": {}},
		{"id": &"fill", "payload": {}},
	]:
		_expect_equal(fixture.plugin.invoke(action.id, action.payload), expected_error, "%s invoke should be refused without treating tool IDs as actions" % action.id)
		_expect_equal(_overlay(fixture), working, "%s refusal must preserve the WorkingMask" % action.id)
	_expect_equal(fixture.store.get_corrected_record(0), before, "WorkingMask refusals must preserve Store")
	_expect_equal(fixture.history.get_undo_count(), 0, "WorkingMask refusals must preserve history")
	_expect(fixture.plugin.handle_key(_key(KEY_ESCAPE)), "Escape should cancel a Paint WorkingMask")
	_expect_equal(_overlay(fixture), {}, "Escape should clear the Paint WorkingMask overlay")


func _test_working_mask_blocks_real_history_shortcuts() -> void:
	for shortcut: Dictionary in [
		{"name": "Ctrl+Z", "event": _key(KEY_Z, false, true)},
		{"name": "Ctrl+Shift+Z", "event": _key(KEY_Z, true, true)},
	]:
		var fixture := _base_fixture()
		fixture.selected[0] = "box-1"
		if not _activate_tool(fixture, &"paint", "%s WorkingMask history guard" % shortcut.name):
			continue
		_expect(
			fixture.plugin.invoke(&"relabel_selected", {"class": "clip"}).is_empty(),
			"%s setup should execute the first real history command" % shortcut.name,
		)
		_expect(
			fixture.plugin.invoke(&"relabel_selected", {"class": "scissors"}).is_empty(),
			"%s setup should execute the second real history command" % shortcut.name,
		)
		_expect(fixture.history.undo(fixture.store), "%s setup should create a real redo entry" % shortcut.name)
		_expect_equal(fixture.history.get_undo_count(), 1, "%s setup should retain one undo entry" % shortcut.name)
		_expect_equal(fixture.history.get_redo_count(), 1, "%s setup should retain one redo entry" % shortcut.name)

		fixture.selected[0] = ""
		_expect(
			fixture.plugin.invoke(&"set_tool_option", {"option_id": &"brush_radius", "value": 2.0}).is_empty(),
			"%s setup should select the outline brush radius" % shortcut.name,
		)
		_gesture(fixture.plugin, fixture.viewport, [
			Vector2(55, 10), Vector2(80, 10), Vector2(80, 35),
			Vector2(55, 35), Vector2(55, 10),
		])
		var overlay_before: Dictionary = _overlay(fixture).duplicate(true)
		var session_before: Dictionary = _session_snapshot(fixture.plugin)
		var store_before: Dictionary = fixture.store.get_corrected_record(0)
		var undo_before: int = fixture.history.get_undo_count()
		var redo_before: int = fixture.history.get_redo_count()
		var status_count_before: int = fixture.statuses.size()
		_expect_equal(overlay_before.get("phase"), &"working_mask", "%s setup should create a real WorkingMask" % shortcut.name)

		_expect(fixture.plugin.handle_key(shortcut.event), "%s should be consumed while a WorkingMask exists" % shortcut.name)
		_expect_equal(
			fixture.statuses.size(),
			status_count_before + 1,
			"%s should report exactly one WorkingMask resolution message" % shortcut.name,
		)
		_expect_equal(
			fixture.statuses.back(),
			"Resolve the Paint working mask with Fill, Close Gaps, or Escape",
			"%s should report the established WorkingMask resolution message" % shortcut.name,
		)
		_expect_equal(fixture.store.get_corrected_record(0), store_before, "%s must not mutate Store behind a WorkingMask" % shortcut.name)
		_expect_equal(fixture.history.get_undo_count(), undo_before, "%s must not consume the undo stack behind a WorkingMask" % shortcut.name)
		_expect_equal(fixture.history.get_redo_count(), redo_before, "%s must not consume the redo stack behind a WorkingMask" % shortcut.name)
		_expect_equal(_session_snapshot(fixture.plugin), session_before, "%s must preserve the complete edit-session snapshot" % shortcut.name)
		_expect_equal(_overlay(fixture), overlay_before, "%s must preserve the complete WorkingMask overlay snapshot" % shortcut.name)


func _test_edit_state_is_observable_and_isolated() -> void:
	var fixture := _base_fixture()
	if not _activate_tool(fixture, &"paint", "edit-state callback"):
		return
	_expect(fixture.plugin.has_method("get_edit_state"), "the production Edit plugin should expose its diagnostic edit-state snapshot")
	if not fixture.plugin.has_method("get_edit_state"):
		return
	_expect(not fixture.edit_states.is_empty(), "activation should publish the initial edit state")
	_expect_equal(fixture.edit_states.back(), {
		"phase": &"idle",
		"navigation_blocked": false,
		"message": "",
	}, "activation should publish the exact idle navigation contract")

	var working := _outline_state(Rect2i(55, 10, 13, 13), 3, 9, [6, 7])
	_install_working_mask(fixture, working, "two-pixel contour")
	var snapshot: Dictionary = fixture.plugin.get_edit_state()
	_expect_equal(snapshot, {
		"phase": &"working_mask",
		"navigation_blocked": true,
		"message": "two-pixel contour",
	}, "WorkingMask should publish the exact navigation-blocking state")
	_expect_equal(fixture.edit_states.back(), snapshot, "the optional state callback should observe WorkingMask transitions")
	snapshot["phase"] = &"tampered"
	snapshot["message"] = "tampered"
	_expect_equal(fixture.plugin.get_edit_state(), {
		"phase": &"working_mask",
		"navigation_blocked": true,
		"message": "two-pixel contour",
	}, "get_edit_state should return an isolated snapshot")
	_expect(fixture.plugin.handle_key(_key(KEY_ESCAPE)), "Escape should resolve the observable WorkingMask")
	_expect_equal(fixture.edit_states.back(), {
		"phase": &"idle",
		"navigation_blocked": false,
		"message": "",
	}, "Escape should publish idle without adding history")
	_expect_equal(fixture.history.get_undo_count(), 0, "edit-state publication and Escape should not enter history")


func _test_fill_commits_a_working_mask_and_refuses_open_background() -> void:
	var no_mask := _base_fixture()
	if _activate_tool(no_mask, &"fill", "Fill without a WorkingMask"):
		var before: Dictionary = no_mask.store.get_corrected_record(0)
		_click(no_mask.plugin, no_mask.viewport, Vector2(20, 20))
		_expect_equal(no_mask.store.get_corrected_record(0), before, "Fill without a WorkingMask must preserve Store")
		_expect_equal(no_mask.class_requests, [], "Fill that creates no region must never request a class")

	var valid := _base_fixture()
	if not _activate_tool(valid, &"paint", "WorkingMask Fill"):
		return
	var two_pixel_gap := _outline_state(Rect2i(55, 10, 13, 13), 3, 9, [6, 7])
	_install_working_mask(valid, two_pixel_gap, "ready for Fill")
	_expect(valid.plugin.set_active_tool(&"fill").is_empty(), "Fill should take ownership of an existing WorkingMask")
	_click(valid.plugin, valid.viewport, Vector2(61, 16))
	_expect(_confirm_pending_polygon(valid).is_empty(), "Fill-created region should accept class assignment")
	var expected_polygon := PackedVector2Array([
		Vector2(58, 13), Vector2(65, 13), Vector2(65, 20), Vector2(58, 20),
	])
	var after: Dictionary = valid.store.get_corrected_record(0)
	_expect_equal(after.regions.size(), 3, "Fill should add exactly one region from the transient contour")
	var added: Dictionary = after.regions[2] if after.regions.size() == 3 else {}
	_expect_equal(_polygon_from_value(added.get("polygon", [])), expected_polygon, "Fill should commit the independently expected solid ring")
	_expect_equal(added.get("class"), "unknown", "Fill should use the taxonomy default class")
	_expect_equal(added.get("kind"), "region", "Fill should use the taxonomy default kind")
	_expect_equal(valid.history.get_undo_count(), 1, "one successful Fill should create one AddPolygon command")
	_expect_equal(_overlay(valid), {}, "successful Fill should clear the orange WorkingMask")
	_expect(valid.history.undo(valid.store), "the Fill command should undo")
	_expect_equal(valid.store.get_corrected_record(0), _record(), "Fill undo should restore the independent original record exactly")
	_expect_equal(valid.history.redo(valid.store), PackedStringArray(), "the Fill command should redo")
	var redone: Dictionary = valid.store.get_corrected_record(0)
	_expect_equal(redone.regions.size(), 3, "Fill redo should restore exactly one added region")
	var redone_added: Dictionary = redone.regions[2] if redone.regions.size() == 3 else {}
	_expect_equal(_polygon_from_value(redone_added.get("polygon", [])), expected_polygon, "Fill redo should restore the expected geometry")

	var refusal_cases := [
		{
			"name": "border-connected seed",
			"mask": _outline_state(Rect2i(55, 10, 13, 13), 3, 9, []),
			"seed": Vector2(56, 11),
		},
		{
			"name": "gap larger than two pixels",
			"mask": _outline_state(Rect2i(55, 10, 13, 13), 3, 9, [5, 6, 7]),
			"seed": Vector2(61, 16),
		},
	]
	for case: Dictionary in refusal_cases:
		var refused := _base_fixture()
		if not _activate_tool(refused, &"paint", "Fill %s refusal" % case.name):
			continue
		_install_working_mask(refused, case.mask, "ready for Fill")
		refused.plugin.set_active_tool(&"fill")
		_click(refused.plugin, refused.viewport, case.seed)
		var expected_message := "Contour is not closed enough; continue Paint or use Close Gaps"
		var overlay := _overlay(refused)
		_expect_equal(refused.store.get_corrected_record(0), _record(), "Fill %s refusal must preserve Store" % case.name)
		_expect_equal(refused.history.get_undo_count(), 0, "Fill %s refusal must preserve history" % case.name)
		_expect_equal(overlay.get("phase"), &"working_mask", "Fill %s refusal should remain navigation-blocking" % case.name)
		_expect_equal(overlay.get("fill_color"), WORKING_MASK_COLOR, "Fill %s refusal should keep the orange repair state" % case.name)
		_expect_equal(overlay.get("mask_preview", {}).get("roi"), case.mask.roi, "Fill %s refusal should preserve the bounded ROI" % case.name)
		_expect_equal(overlay.get("mask_preview", {}).get("mask"), case.mask.mask, "Fill %s refusal should preserve every source byte" % case.name)
		_expect_equal(overlay.get("message"), expected_message, "Fill %s refusal should explain the resolution path" % case.name)
		_expect_equal(refused.class_requests, [], "Fill %s refusal must not request a class" % case.name)


func _test_close_gaps_repairs_a_working_mask_before_fill() -> void:
	var fixture := _base_fixture()
	if not _activate_tool(fixture, &"paint", "WorkingMask Close Gaps"):
		return
	var open_outline := _outline_state(Rect2i(55, 10, 13, 13), 3, 9, [6, 7])
	var expected_closed := _outline_state(Rect2i(55, 10, 13, 13), 3, 9, [])
	_install_working_mask(fixture, open_outline, "ready for Close Gaps")
	_expect(fixture.plugin.set_active_tool(&"close_gaps").is_empty(), "Close Gaps should take ownership of the WorkingMask")
	_click(fixture.plugin, fixture.viewport, Vector2(61, 13))
	var repaired := _overlay(fixture)
	_expect_equal(repaired.get("phase"), &"working_mask", "WorkingMask Close Gaps should remain transient")
	_expect_equal(repaired.get("fill_color"), WORKING_MASK_COLOR, "successful WorkingMask repair should remain orange")
	_expect_equal(repaired.get("mask_preview", {}).get("roi"), expected_closed.roi, "Close Gaps should preserve the exact bounded ROI")
	_expect_equal(repaired.get("mask_preview", {}).get("mask"), expected_closed.mask, "Close Gaps should repair only the independently expected two bytes")
	_expect_equal(fixture.store.get_corrected_record(0), _record(), "WorkingMask Close Gaps must not mutate Store")
	_expect_equal(fixture.history.get_undo_count(), 0, "WorkingMask Close Gaps must create zero commands")

	fixture.plugin.set_active_tool(&"fill")
	_click(fixture.plugin, fixture.viewport, Vector2(61, 16))
	_expect(_confirm_pending_polygon(fixture).is_empty(), "Close Gaps then Fill should accept class assignment")
	var filled_record: Dictionary = fixture.store.get_corrected_record(0)
	_expect_equal(filled_record.regions.size(), 3, "Fill after Close Gaps should add one region")
	_expect_equal(fixture.history.get_undo_count(), 1, "Close Gaps then Fill should have exactly one history entry total")
	var filled_region: Dictionary = filled_record.regions[2] if filled_record.regions.size() == 3 else {}
	_expect_equal(_polygon_from_value(filled_region.get("polygon", [])), PackedVector2Array([
		Vector2(58, 13), Vector2(65, 13), Vector2(65, 20), Vector2(58, 20),
	]), "Close Gaps then Fill should commit the expected solid ring")


func _test_close_gaps_replaces_one_selected_region_with_round_trip_history() -> void:
	var before := _record()
	before.regions[1]["polygon"] = [
		[40, 40], [46, 40], [46, 42], [48, 42], [48, 40],
		[55, 40], [55, 55], [40, 55],
	]
	var fixture := _fixture(before, _flat_image())
	fixture.selected[0] = "poly-1"
	if not _activate_tool(fixture, &"close_gaps", "selected Close Gaps"):
		return
	_click(fixture.plugin, fixture.viewport, Vector2(47, 40))
	var expected := _record()
	expected.regions[1]["polygon"] = [[40.0, 40.0], [55.0, 40.0], [55.0, 55.0], [40.0, 55.0]]
	_expect_equal(fixture.store.get_corrected_record(0), expected, "selected Close Gaps should commit the independently expected replacement record")
	_expect_equal(fixture.history.get_undo_count(), 1, "selected Close Gaps should create exactly one ReplaceGeometry command")
	_expect_equal(fixture.class_requests, [], "selected Close Gaps must preserve metadata without requesting a class")
	_expect_equal(_overlay(fixture), {}, "selected Close Gaps should never leave an orange mask waiting for Fill")
	_expect(fixture.history.undo(fixture.store), "selected Close Gaps should undo")
	_expect_equal(fixture.store.get_corrected_record(0), before, "selected Close Gaps undo should restore the independent original record")
	_expect_equal(fixture.history.redo(fixture.store), PackedStringArray(), "selected Close Gaps should redo")
	_expect_equal(fixture.store.get_corrected_record(0), expected, "selected Close Gaps redo should restore the independent replacement record")


func _test_eraser_requires_an_explicit_selection() -> void:
	var fixture := _base_fixture()
	if not _activate_tool(fixture, &"eraser", "unselected Eraser"):
		return
	var before: Dictionary = fixture.store.get_corrected_record(0)
	_pointer(fixture.plugin, true, Vector2(15, 15), fixture.viewport)
	_expect(fixture.statuses.has("Select a region before using Eraser"), "Eraser without selection should explain the selection requirement")
	_expect_equal(_overlay(fixture).get("phase"), &"brush_cursor", "Eraser without selection should retain its idle brush cursor")
	_expect_equal(fixture.selected[0], "", "Eraser must not infer selection from its press location")
	_expect_equal(fixture.store.get_corrected_record(0), before, "unselected Eraser must preserve Store")
	_expect_equal(fixture.history.get_undo_count(), 0, "unselected Eraser must preserve history")


func _test_eraser_subtracts_and_refuses_v1_inexpressible_results() -> void:
	var partial := _base_fixture()
	partial.selected[0] = "box-1"
	if _activate_tool(partial, &"eraser", "partial Eraser"):
		partial.plugin.invoke(&"set_tool_option", {"option_id": &"brush_radius", "value": 3.0})
		var before_area := _absolute_area(_region_polygon(partial.store.get_corrected_record(0), "box-1"))
		_gesture(partial.plugin, partial.viewport, [Vector2(29, 7), Vector2(29, 17), Vector2(29, 28)])
		var polygon := _region_polygon(partial.store.get_corrected_record(0), "box-1")
		_expect(POLYGON_OPS.validate_simple_polygon(polygon), "partial Eraser should keep one simple V1 ring")
		_expect(_absolute_area(polygon) > 0.0 and _absolute_area(polygon) < before_area, "partial Eraser should remove only brush area")
		_expect_equal(partial.history.get_undo_count(), 1, "one successful Eraser gesture should create exactly one command")
		_expect_equal(partial.class_requests, [], "selected Eraser must preserve metadata without requesting a class")
		var idle_cursor := _overlay(partial)
		_expect_equal(idle_cursor.get("phase"), &"brush_cursor", "successful Eraser should immediately restore its idle brush cursor")
		_expect_equal(idle_cursor.get("cursor"), Vector2(29, 28), "restored Eraser cursor should stay at the release point")

	var refusal_cases := [
		{"name": "full erasure", "radius": 40.0, "points": [Vector2(20, 17)]},
		{"name": "hole", "radius": 3.0, "points": [Vector2(20, 17)]},
		{"name": "multiple components", "radius": 1.0, "points": [Vector2(20, 5), Vector2(20, 35)]},
	]
	for case: Dictionary in refusal_cases:
		var fixture := _base_fixture()
		fixture.selected[0] = "box-1"
		if not _activate_tool(fixture, &"eraser", "Eraser %s refusal" % case.name):
			continue
		fixture.plugin.invoke(&"set_tool_option", {"option_id": &"brush_radius", "value": case.radius})
		var before: Dictionary = fixture.store.get_corrected_record(0)
		_gesture(fixture.plugin, fixture.viewport, case.points)
		var invalid := _overlay(fixture)
		_expect_equal(fixture.store.get_corrected_record(0), before, "Eraser must refuse %s atomically" % case.name)
		_expect_equal(fixture.history.get_undo_count(), 0, "refused Eraser %s must not enter history" % case.name)
		_expect_equal(invalid.get("phase"), &"invalid", "refused Eraser %s should remain visibly invalid" % case.name)
		_expect_equal(invalid.get("fill_color"), INVALID_COLOR, "refused Eraser %s should stay red" % case.name)
		_expect(not invalid.get("mask_preview", {}).is_empty(), "refused Eraser %s should retain its raw bounded mask" % case.name)
		_expect_equal(fixture.class_requests, [], "refused Eraser %s must not request a class" % case.name)


func _test_selected_paint_disjoint_adds_a_new_region() -> void:
	var fixture := _base_fixture()
	fixture.selected[0] = "box-1"
	if not _activate_tool(fixture, &"paint", "disjoint selected Paint creates a new object"):
		return
	fixture.plugin.invoke(&"set_tool_option", {"option_id": &"brush_radius", "value": 2.0})
	var before: Dictionary = fixture.store.get_corrected_record(0)
	_gesture(fixture.plugin, fixture.viewport, [Vector2(68, 20), Vector2(76, 20)])
	_expect_equal(fixture.store.get_corrected_record(0), before, "disjoint selected Paint should await class assignment without changing the selected object")
	_expect_equal(_overlay(fixture).get("phase"), &"awaiting_class", "disjoint selected Paint should become a new-object candidate")
	_expect_equal(fixture.class_requests.size(), 1, "disjoint selected Paint should request a class for the new object")
	_expect(_confirm_pending_polygon(fixture, "separate paint", "region").is_empty(), "disjoint selected Paint should accept class assignment")
	var after: Dictionary = fixture.store.get_corrected_record(0)
	_expect_equal(after.regions.size(), before.regions.size() + 1, "disjoint selected Paint should add exactly one object")
	_expect_equal(_find_region(after, "box-1"), _find_region(before, "box-1"), "disjoint Paint must leave the formerly selected object byte-identical")


func _test_unselected_paint_overlap_repairs_one_existing_region() -> void:
	var fixture := _base_fixture()
	if not _activate_tool(fixture, &"paint", "unselected overlapping Paint inference"):
		return
	fixture.plugin.invoke(&"set_tool_option", {"option_id": &"brush_radius", "value": 3.0})
	var before: Dictionary = fixture.store.get_corrected_record(0)
	_gesture(fixture.plugin, fixture.viewport, [Vector2(27, 17), Vector2(36, 17)])
	var after: Dictionary = fixture.store.get_corrected_record(0)
	_expect_equal(after.regions.size(), before.regions.size(), "Paint overlapping exactly one object should repair rather than add")
	_expect(_absolute_area(_region_polygon(after, "box-1")) > _absolute_area(_region_polygon(before, "box-1")),
		"inferred overlapping Paint should union visible brush area into the existing object")
	_expect_equal(fixture.selected[0], "box-1", "a successfully inferred Paint target should become selected")
	_expect_equal(fixture.class_requests, [], "repairing an inferred existing object must preserve its metadata without a class prompt")
	_expect_equal(fixture.history.get_undo_count(), 1, "one inferred Paint repair should create one command")


func _test_paint_multi_overlap_requires_or_honors_selection() -> void:
	var record := _record()
	record.regions.append({"id": "box-2", "class": "clip", "kind": "instrument", "box": [20, 10, 20, 15], "track_id": null})
	var ambiguous := _fixture(record, _flat_image())
	if _activate_tool(ambiguous, &"paint", "ambiguous multi-overlap Paint"):
		ambiguous.plugin.invoke(&"set_tool_option", {"option_id": &"brush_radius", "value": 3.0})
		var before: Dictionary = ambiguous.store.get_corrected_record(0)
		_gesture(ambiguous.plugin, ambiguous.viewport, [Vector2(25, 17), Vector2(33, 17)])
		_expect_equal(ambiguous.store.get_corrected_record(0), before, "ambiguous Paint must preserve all overlapping objects")
		_expect_equal(_overlay(ambiguous).get("phase"), &"invalid", "ambiguous Paint should retain a visible refusal")
		_expect(String(_overlay(ambiguous).get("message", "")).contains("select"), "ambiguous Paint should explain how to choose a target")
		_expect_equal(ambiguous.history.get_undo_count(), 0, "ambiguous Paint must not create history")

	var preferred := _fixture(record, _flat_image())
	preferred.selected[0] = "box-1"
	if _activate_tool(preferred, &"paint", "selected multi-overlap Paint"):
		preferred.plugin.invoke(&"set_tool_option", {"option_id": &"brush_radius", "value": 3.0})
		var before: Dictionary = preferred.store.get_corrected_record(0)
		_gesture(preferred.plugin, preferred.viewport, [Vector2(25, 17), Vector2(33, 17)])
		var after: Dictionary = preferred.store.get_corrected_record(0)
		_expect(_absolute_area(_region_polygon(after, "box-1")) > _absolute_area(_region_polygon(before, "box-1")),
			"selected Paint target should win when the stroke overlaps multiple objects")
		_expect_equal(_find_region(after, "box-2"), _find_region(before, "box-2"), "non-selected overlapping objects must stay byte-identical")
		_expect_equal(preferred.history.get_undo_count(), 1, "selected multi-overlap Paint should create one repair command")


func _test_close_repairs_a_narrow_open_contour() -> void:
	var record := _record()
	record.regions[1].polygon = [
		[10, 10],
		[30, 10],
		[30, 30],
		[21, 30],
		[21, 14],
		[19, 14],
		[19, 30],
		[10, 30],
	]
	var fixture := _fixture(record, _flat_image())
	fixture.selected[0] = "poly-1"
	if not _activate_tool(fixture, &"close", "Close"):
		return
	var before_polygon := _region_polygon(fixture.store.get_corrected_record(0), "poly-1")
	_click(fixture.plugin, fixture.viewport, Vector2(15, 20))
	var after_polygon := _region_polygon(fixture.store.get_corrected_record(0), "poly-1")
	_expect(POLYGON_OPS.validate_simple_polygon(after_polygon), "Close should commit one V1-safe simple contour")
	_expect(after_polygon != before_polygon, "Close should repair the deliberately narrow two-pixel contour gap")
	_expect(_absolute_area(after_polygon) > _absolute_area(before_polygon), "closing the narrow gap should add the missing contour area")
	_expect_equal(fixture.history.get_undo_count(), 1, "one Close click should create exactly one command")


func _test_region_growing_previews_adjusts_and_commits_the_displayed_candidate() -> void:
	var image := _flat_image()
	for y in range(10, 20):
		for x in range(60, 70):
			image.set_pixel(x, y, Color(0.4, 0.4, 0.4))
		for x in range(70, 80):
			image.set_pixel(x, y, Color(0.495, 0.4, 0.4))
	var fixture := _fixture(_record(), image)
	if not _activate_tool(fixture, &"region_growing", "adjustable Region Growing"):
		return
	var before: Dictionary = fixture.store.get_corrected_record(0)
	_pointer(fixture.plugin, true, Vector2(65, 15), fixture.viewport)
	var initial := _overlay(fixture)
	_expect_equal(initial.get("phase"), &"candidate", "pointer-down should publish a valid green Region Growing preview")
	_expect_equal(initial.get("fill_color"), Color("#22c55e"), "a valid Region Growing candidate should use the shared green preview")
	_expect_overlay_contract(initial, "Region Growing pointer preview")
	_expect_equal(fixture.store.get_corrected_record(0), before, "pointer-down preview must not mutate Store")
	_expect_equal(fixture.history.get_undo_count(), 0, "pointer-down preview must create zero history")
	_expect_equal(
		POLYGON_OPS.polygon_bounds(initial.get("candidate_polygon", PackedVector2Array())),
		Rect2(60, 10, 10, 10),
		"the initial tolerance should keep only the seed-colour block",
	)
	var preview_count: int = fixture.viewport.overlays.size()
	_motion(fixture.plugin, Vector2(65.9, 15), fixture.viewport)
	_expect_equal(fixture.viewport.overlays.size(), preview_count, "sub-quantum pointer motion should not recompute or republish the candidate")
	var unrelated := _flat_image()
	fixture.viewport.current_image = unrelated
	_motion(fixture.plugin, Vector2(85, 15), fixture.viewport)
	var adjusted := _overlay(fixture)
	_expect_equal(adjusted.get("phase"), &"candidate", "quantized brightness adjustment should recompute a green candidate")
	_expect_equal(
		POLYGON_OPS.polygon_bounds(adjusted.get("candidate_polygon", PackedVector2Array())),
		Rect2(60, 10, 20, 10),
		"horizontal drag should bias the frozen press image and admit its connected fringe",
	)
	_expect_equal(fixture.store.get_corrected_record(0), before, "live adjustment must remain transient")
	_expect_equal(fixture.history.get_undo_count(), 0, "live adjustment must remain outside history")
	var displayed: PackedVector2Array = adjusted.get("candidate_polygon", PackedVector2Array()).duplicate()
	_pointer(fixture.plugin, false, Vector2(85, 15), fixture.viewport)
	_expect(_confirm_pending_polygon(fixture).is_empty(), "Region Growing should accept class assignment")
	var after: Dictionary = fixture.store.get_corrected_record(0)
	_expect_equal(after.regions.size(), before.regions.size() + 1, "release should add the seed-connected candidate as one region")
	var added: Dictionary = after.regions.back() if after.regions.size() > before.regions.size() else {}
	var polygon := _polygon_from_value(added.get("polygon", []))
	_expect_equal(polygon, displayed, "release must commit the already displayed frozen candidate without recomputing")
	_expect(POLYGON_OPS.validate_simple_polygon(polygon), "Region Growing should commit one V1-safe polygon")
	_expect_equal(fixture.history.get_undo_count(), 1, "one successful Region Growing gesture should create exactly one command")


func _test_region_growing_refuses_v1_inexpressible_topology_in_red() -> void:
	var image := _flat_image()
	for y in range(10, 17):
		for x in range(60, 67):
			if x == 60 or x == 66 or y == 10 or y == 16:
				image.set_pixel(x, y, Color.RED)
	var fixture := _fixture(_record(), image)
	if not _activate_tool(fixture, &"region_growing", "Region Growing hole refusal"):
		return
	var before: Dictionary = fixture.store.get_corrected_record(0)
	_pointer(fixture.plugin, true, Vector2(60, 10), fixture.viewport)
	var pressed := _overlay(fixture)
	_expect_equal(pressed.get("phase"), &"invalid", "a V1-inexpressible Region Growing preview should be red on pointer-down")
	_expect_equal(pressed.get("fill_color"), INVALID_COLOR, "an invalid Region Growing preview should use the shared red fill")
	_expect_overlay_contract(pressed, "invalid Region Growing pointer preview")
	_pointer(fixture.plugin, false, Vector2(60, 10), fixture.viewport)
	_expect_equal(_overlay(fixture).get("phase"), &"invalid", "invalid release should retain the red candidate for correction or cancellation")
	_expect_equal(fixture.store.get_corrected_record(0), before, "Region Growing must refuse a mask hole instead of silently dropping it")
	_expect_equal(fixture.history.get_undo_count(), 0, "a refused Region Growing result must not enter history")
	_expect(not fixture.statuses.is_empty(), "Region Growing should report why the V1-inexpressible mask was refused")


func _test_region_growing_expands_a_truncated_roi_before_commit() -> void:
	var image := Image.create(220, 80, false, Image.FORMAT_RGBA8)
	image.fill(Color.RED)
	var fixture := _fixture(_record(), image)
	if not _activate_tool(fixture, &"region_growing", "Region Growing dynamic ROI"):
		return
	var before: Dictionary = fixture.store.get_corrected_record(0)
	_pointer(fixture.plugin, true, Vector2(110, 40), fixture.viewport)
	var preview := _overlay(fixture)
	_expect_equal(preview.get("phase"), &"candidate", "a formerly clipped 129-pixel component should expand to a complete preview")
	_expect_equal(
		POLYGON_OPS.polygon_bounds(preview.get("candidate_polygon", PackedVector2Array())),
		Rect2(0, 0, 220, 80),
		"dynamic expansion should reach the complete image-edge component",
	)
	_expect_equal(fixture.store.get_corrected_record(0), before, "expanded preview must still be transient")
	_expect_equal(fixture.history.get_undo_count(), 0, "expanded preview must still create zero commands")
	_pointer(fixture.plugin, false, Vector2(110, 40), fixture.viewport)
	_expect(_confirm_pending_polygon(fixture).is_empty(), "expanded Region Growing should accept class assignment")
	_expect_equal(
		fixture.store.get_corrected_record(0).regions.size(),
		before.regions.size() + 1,
		"release should commit the fully expanded component exactly once",
	)
	_expect_equal(fixture.history.get_undo_count(), 1, "the expanded success should enter history once")


func _test_region_growing_cannot_commit_a_stale_frame_or_store_snapshot() -> void:
	var image := _flat_image()
	for y in range(10, 20):
		for x in range(60, 70):
			image.set_pixel(x, y, Color.RED)
	var intervened := _fixture(_record(), image)
	if _activate_tool(intervened, &"region_growing", "Region Growing intervening Store guard"):
		_pointer(intervened.plugin, true, Vector2(65, 15), intervened.viewport)
		var external: Dictionary = intervened.store.get_corrected_record(0)
		external.regions[0]["class"] = "clip"
		_expect(intervened.store.replace_corrected_record(0, external).is_empty(), "the independent intervening edit should be schema-valid")
		_pointer(intervened.plugin, false, Vector2(65, 15), intervened.viewport)
		_expect_equal(intervened.store.get_corrected_record(0), external, "release must not overwrite an intervening Store record")
		_expect_equal(intervened.history.get_undo_count(), 0, "a stale Store candidate must create zero commands")
		_expect_equal(_overlay(intervened).get("phase"), &"invalid", "a stale Store release should remain visibly red")

	var stale_frame := _fixture(_record(), image)
	if _activate_tool(stale_frame, &"region_growing", "Region Growing stale-frame guard"):
		var before: Dictionary = stale_frame.store.get_corrected_record(0)
		_pointer(stale_frame.plugin, true, Vector2(65, 15), stale_frame.viewport)
		stale_frame.frame[0] = 1
		_pointer(stale_frame.plugin, false, Vector2(65, 15), stale_frame.viewport)
		_expect_equal(stale_frame.store.get_corrected_record(0), before, "release on another frame must preserve the frozen frame record")
		_expect_equal(stale_frame.history.get_undo_count(), 0, "a stale-frame candidate must create zero commands")
		_expect_equal(_overlay(stale_frame).get("phase"), &"invalid", "a stale-frame release should remain visibly red")


func _test_region_growing_command_rejection_preserves_redo_and_frozen_preview() -> void:
	var image := _flat_image()
	for y in range(10, 20):
		for x in range(60, 70):
			image.set_pixel(x, y, Color.RED)
	var fixture := _fixture(_record(), image)
	var rejecting_store := RejectOnceStore.new(fixture.store)
	fixture.store = rejecting_store
	fixture.context["store"] = rejecting_store
	fixture.selected[0] = "box-1"
	if not _activate_tool(fixture, &"select", "Region Growing command rejection setup"):
		return
	_expect(fixture.plugin.handle_key(_key(KEY_RIGHT)), "a real move should establish one undo entry")
	_expect(fixture.history.undo(fixture.store), "command history should move the setup command into redo")
	_expect_equal(fixture.history.get_undo_count(), 0, "rejection setup should leave no undo entries")
	_expect_equal(fixture.history.get_redo_count(), 1, "rejection setup should retain one independent redo entry")
	var store_before: Dictionary = rejecting_store.get_corrected_record(0)
	_expect(fixture.plugin.set_active_tool(&"region_growing").is_empty(), "Region Growing should activate after redo setup")
	_pointer(fixture.plugin, true, Vector2(65, 15), fixture.viewport)
	var displayed: Dictionary = _overlay(fixture).duplicate(true)
	var frozen: Dictionary = _session_snapshot(fixture.plugin)
	_expect_equal(displayed.get("phase"), &"candidate", "command rejection setup should first display a valid candidate")
	rejecting_store.reject_next_replace = true
	_pointer(fixture.plugin, false, Vector2(65, 15), fixture.viewport)
	var confirmation_errors := _confirm_pending_polygon(fixture)
	var refused: Dictionary = _overlay(fixture)
	var retained: Dictionary = _session_snapshot(fixture.plugin)
	_expect_equal(confirmation_errors, PackedStringArray(["forced replacement rejection"]), "Region Growing confirmation should expose the concrete Store error")
	_expect_equal(refused.get("phase"), &"awaiting_class", "a rejected Add command should retain its recoverable AwaitingClass preview")
	_expect_equal(refused.get("candidate_polygon"), displayed.get("candidate_polygon"), "rejection must retain the exactly displayed candidate")
	_expect(fixture.statuses.has("forced replacement rejection"), "rejected Region Growing confirmation should report the concrete Store error")
	_expect_equal(retained.get("frame"), frozen.get("frame"), "rejection must retain the frozen frame")
	_expect_equal(retained.get("before"), frozen.get("before"), "rejection must retain the frozen before record")
	_expect_equal(rejecting_store.get_corrected_record(0), store_before, "rejected Add must preserve Store exactly")
	_expect_equal(fixture.history.get_undo_count(), 0, "rejected Add must not enter undo history")
	_expect_equal(fixture.history.get_redo_count(), 1, "rejected Add must not clear the pre-existing redo entry")


func _test_live_wire_hover_cache_uses_full_paths_and_image_identity() -> void:
	var fixture := _base_fixture()
	if not _activate_tool(fixture, &"live_wire", "Live Wire hover cache"):
		return
	var first_image: Image = fixture.viewport.current_image
	var first_bytes := first_image.get_data()
	_click(fixture.plugin, fixture.viewport, Vector2(10, 10))
	_expect_equal(
		fixture.plugin.get("_live_wire_anchors"),
		PackedVector2Array([Vector2(10, 10)]),
		"the first pointer click should place exactly one rounded pixel anchor",
	)
	_expect_equal(_private_int(fixture.plugin, &"_live_wire_cache_hits"), 0, "a new Live Wire transaction should start with zero cache hits")
	_expect_equal(_private_int(fixture.plugin, &"_live_wire_cache_misses"), 0, "a new Live Wire transaction should start with zero cache misses")

	var expected_to_thirteen := PackedVector2Array([
		Vector2(10, 10), Vector2(11, 10), Vector2(12, 10), Vector2(13, 10),
	])
	_hover(fixture.plugin, Vector2(13.2, 10.2), fixture.viewport)
	var first_hover := _overlay(fixture)
	_expect_equal(first_hover.get("phase"), &"drawing", "unbuttoned Live Wire motion should publish a cyan drawing preview")
	_expect_equal(first_hover.get("path"), expected_to_thirteen, "hover should publish the full unsampled last-anchor-to-cursor path")
	_expect_equal(first_hover.get("cursor"), Vector2(13, 10), "hover cursor should use the rounded clamped image pixel")
	_expect_equal(first_hover.get("fill_color"), PAINT_OVERLAY_COLOR, "Live Wire hover should use the established cyan drawing color")
	_expect_equal(_private_int(fixture.plugin, &"_live_wire_cache_hits"), 0, "the first rounded hover key should be a cache miss")
	_expect_equal(_private_int(fixture.plugin, &"_live_wire_cache_misses"), 1, "the first rounded hover key should run exactly one search")

	_hover(fixture.plugin, Vector2(13.4, 10.4), fixture.viewport)
	_expect_equal(_overlay(fixture).get("path"), expected_to_thirteen, "subpixel-equivalent hover should reuse the exact cached full path")
	_expect_equal(_private_int(fixture.plugin, &"_live_wire_cache_hits"), 1, "the same rounded cursor should be an exact cache hit")
	_expect_equal(_private_int(fixture.plugin, &"_live_wire_cache_misses"), 1, "a subpixel-equivalent cache hit must not rerun search")

	_hover(fixture.plugin, Vector2(14, 10), fixture.viewport)
	_expect_equal(_private_int(fixture.plugin, &"_live_wire_cache_misses"), 2, "a changed rounded cursor must miss the cache")
	var replacement := _flat_image()
	var replacement_bytes := replacement.get_data()
	fixture.viewport.current_image = replacement
	_hover(fixture.plugin, Vector2(14, 10), fixture.viewport)
	_expect_equal(_private_int(fixture.plugin, &"_live_wire_cache_misses"), 3, "a same-sized replacement Image identity must miss the cache")
	var anchors_before_press: PackedVector2Array = fixture.plugin.get("_live_wire_anchors").duplicate()
	_pointer(fixture.plugin, true, Vector2(14, 10), fixture.viewport)
	_expect_equal(_private_int(fixture.plugin, &"_live_wire_cache_hits"), 2, "clicking the cached rounded cursor should reuse its full hover segment")
	_expect_equal(fixture.plugin.get("_live_wire_anchors").size(), anchors_before_press.size() + 1, "pointer press should append one anchor")
	var anchors_after_press: PackedVector2Array = fixture.plugin.get("_live_wire_anchors").duplicate()
	_pointer(fixture.plugin, false, Vector2(14, 10), fixture.viewport)
	_expect_equal(fixture.plugin.get("_live_wire_anchors"), anchors_after_press, "ordinary pointer release must not append a duplicate anchor")
	_hover(fixture.plugin, Vector2(18, 10), fixture.viewport)
	_expect_equal(_private_int(fixture.plugin, &"_live_wire_cache_misses"), 4, "changing the last anchor must force the next hover segment to miss")
	_expect_equal(first_image.get_data(), first_bytes, "hover and cache lookup must not mutate the original source Image")
	_expect_equal(replacement.get_data(), replacement_bytes, "hover and cached click must not mutate a replacement source Image")
	_expect_equal(fixture.history.get_undo_count(), 0, "hover and anchor placement must remain outside command history")


func _test_live_wire_modal_backspace_delete_and_double_click_closure() -> void:
	var fixture := _base_fixture()
	if not _activate_tool(fixture, &"live_wire", "Live Wire modal pointer controls"):
		return
	var before: Dictionary = fixture.store.get_corrected_record(0)
	for anchor: Vector2 in [Vector2(10, 10), Vector2(20, 10), Vector2(20, 20)]:
		_hover(fixture.plugin, anchor, fixture.viewport)
		_click(fixture.plugin, fixture.viewport, anchor)
	var three_anchor_path: PackedVector2Array = fixture.plugin.get("_live_wire_points").duplicate()
	_hover(fixture.plugin, Vector2(10, 20), fixture.viewport)
	_click(fixture.plugin, fixture.viewport, Vector2(10, 20))
	_expect_equal(fixture.plugin.get("_live_wire_anchors").size(), 4, "the fourth pointer press should append one anchor")
	_expect(fixture.plugin.handle_key(_key(KEY_BACKSPACE)), "modal Backspace should be consumed by Live Wire")
	_expect_equal(fixture.plugin.get("_live_wire_anchors").size(), 3, "modal Backspace should remove exactly the last anchor")
	_expect_equal(fixture.plugin.get("_live_wire_points"), three_anchor_path, "Backspace should restore the exact fixed path that preceded the removed anchor")
	_expect_equal(_overlay(fixture).get("path"), three_anchor_path, "Backspace should republish the exact restored fixed path")
	_expect(fixture.plugin.handle_key(_key(KEY_DELETE)), "modal Delete should be consumed by Live Wire")
	_expect_equal(fixture.store.get_corrected_record(0), before, "modal Delete must never delete the selected or any other region")
	_expect_equal(fixture.history.get_undo_count(), 0, "modal Backspace/Delete should remain outside history")

	_hover(fixture.plugin, Vector2(10, 20), fixture.viewport)
	_pointer(fixture.plugin, true, Vector2(10, 20), fixture.viewport, true)
	_expect(_confirm_pending_polygon(fixture).is_empty(), "double-click Live Wire should accept class assignment")
	var after_press: Dictionary = fixture.store.get_corrected_record(0)
	var expected_polygon := PackedVector2Array([
		Vector2(10, 10), Vector2(20, 10), Vector2(20, 20), Vector2(10, 20),
	])
	_expect_equal(after_press.regions.size(), before.regions.size() + 1, "double-click press should close and add exactly one region")
	_expect_equal(_polygon_from_value(after_press.regions.back().get("polygon", [])), expected_polygon, "double-click should commit the independently expected rectangle")
	_expect_equal(fixture.history.get_undo_count(), 1, "double-click closure should create exactly one AddPolygon command")
	_pointer(fixture.plugin, false, Vector2(10, 20), fixture.viewport, true)
	_expect_equal(fixture.store.get_corrected_record(0), after_press, "double-click release must not append or commit a second time")
	_expect_equal(fixture.history.get_undo_count(), 1, "double-click release must not create duplicate history")


func _test_live_wire_commits_anchors_on_enter() -> void:
	var fixture := _base_fixture()
	if not _activate_tool(fixture, &"live_wire", "Live Wire"):
		return
	var before: Dictionary = fixture.store.get_corrected_record(0)
	for anchor: Vector2 in [Vector2(60, 10), Vector2(80, 10), Vector2(80, 30), Vector2(60, 30)]:
		_click(fixture.plugin, fixture.viewport, anchor)
	_expect_equal(fixture.history.get_undo_count(), 0, "Live Wire anchors should remain preview-only until explicit confirmation")
	var handled: bool = fixture.plugin.handle_key(_key(KEY_ENTER))
	_expect(_confirm_pending_polygon(fixture).is_empty(), "Live Wire Enter should accept class assignment")
	var after: Dictionary = fixture.store.get_corrected_record(0)
	_expect(handled, "Enter should confirm a multi-anchor Live Wire contour")
	_expect_equal(after.regions.size(), before.regions.size() + 1, "confirmed Live Wire anchors should add exactly one region")
	var added: Dictionary = after.regions.back() if after.regions.size() > before.regions.size() else {}
	var expected_polygon := PackedVector2Array([
		Vector2(60, 10), Vector2(80, 10), Vector2(80, 30), Vector2(60, 30),
	])
	_expect_equal(_polygon_from_value(added.get("polygon", [])), expected_polygon, "pointer Enter should commit the independently expected edge-following ring")
	_expect_equal(fixture.history.get_undo_count(), 1, "one confirmed Live Wire contour should create exactly one command")
	_expect(fixture.history.undo(fixture.store), "the one Live Wire Add command should undo")
	_expect_equal(fixture.store.get_corrected_record(0), before, "Live Wire undo should restore the exact independent before record")
	_expect_equal(fixture.history.redo(fixture.store), PackedStringArray(), "the one Live Wire Add command should redo")
	_expect_equal(fixture.store.get_corrected_record(0), after, "Live Wire redo should restore the exact committed record")


func _test_live_wire_refusals_retain_exact_state_for_correction() -> void:
	var bounds := _base_fixture()
	if _activate_tool(bounds, &"live_wire", "Live Wire direct bounds refusal"):
		var before: Dictionary = bounds.store.get_corrected_record(0)
		_click(bounds.plugin, bounds.viewport, Vector2(10, 10))
		var fixed_before: PackedVector2Array = bounds.plugin.get("_live_wire_points").duplicate()
		_pointer(bounds.plugin, true, Vector2(-1, 10), bounds.viewport)
		_pointer(bounds.plugin, false, Vector2(-1, 10), bounds.viewport)
		var refused := _overlay(bounds)
		var frozen := _session_snapshot(bounds.plugin)
		_expect_equal(refused.get("phase"), &"invalid", "a directly out-of-image pixel should remain visibly red")
		_expect_equal(refused.get("fill_color"), INVALID_COLOR, "direct pixel refusal should use the shared invalid red")
		_expect(not String(refused.get("message", "")).is_empty(), "direct pixel refusal should explain the image bounds")
		_expect_equal(bounds.plugin.get("_live_wire_anchors"), PackedVector2Array([Vector2(10, 10)]), "direct pixel refusal must preserve the exact anchors")
		_expect_equal(bounds.plugin.get("_live_wire_points"), fixed_before, "direct pixel refusal must preserve the exact fixed path")
		_expect_equal(frozen.get("before"), before, "direct pixel refusal must retain the exact frozen record")
		_expect_equal(bounds.store.get_corrected_record(0), before, "direct pixel refusal must not mutate Store")
		_expect_equal(bounds.history.get_undo_count(), 0, "direct pixel refusal must create zero history")
		_hover(bounds.plugin, Vector2(20, 10), bounds.viewport)
		_expect_equal(_overlay(bounds).get("phase"), &"drawing", "a valid hover should correct a retained bounds refusal")

	var crossing := _base_fixture()
	if _activate_tool(crossing, &"live_wire", "Live Wire self-intersection refusal"):
		var before: Dictionary = crossing.store.get_corrected_record(0)
		for anchor: Vector2 in [Vector2(10, 10), Vector2(20, 20), Vector2(10, 20), Vector2(20, 10)]:
			_click(crossing.plugin, crossing.viewport, anchor)
		var exact_anchors: PackedVector2Array = crossing.plugin.get("_live_wire_anchors").duplicate()
		var exact_fixed: PackedVector2Array = crossing.plugin.get("_live_wire_points").duplicate()
		_expect(crossing.plugin.handle_key(_key(KEY_ENTER)), "invalid pointer closure should still consume Enter")
		var refused := _overlay(crossing)
		var frozen := _session_snapshot(crossing.plugin)
		_expect_equal(refused.get("phase"), &"invalid", "a self-intersecting closure should remain visibly red")
		_expect_equal(refused.get("fill_color"), INVALID_COLOR, "self-intersection should publish a red candidate")
		_expect(not refused.get("candidate_polygon", PackedVector2Array()).is_empty(), "invalid closure should keep its attempted filled candidate visible")
		_expect_equal(crossing.plugin.get("_live_wire_anchors"), exact_anchors, "invalid closure must retain all exact anchors")
		_expect_equal(crossing.plugin.get("_live_wire_points"), exact_fixed, "invalid closure must retain the exact fixed path")
		_expect_equal(frozen.get("before"), before, "invalid closure must retain the exact frozen Store record")
		_expect_equal(crossing.store.get_corrected_record(0), before, "invalid closure must not mutate Store")
		_expect_equal(crossing.history.get_undo_count(), 0, "invalid closure must create zero history")
		_expect(crossing.plugin.handle_key(_key(KEY_BACKSPACE)), "Backspace should correct a retained invalid closure")
		_expect_equal(crossing.plugin.get("_live_wire_anchors").size(), 3, "correction should remove exactly the crossing anchor")
		_expect(crossing.plugin.handle_key(_key(KEY_ENTER)), "the corrected three-anchor contour should close")
		_expect(_confirm_pending_polygon(crossing).is_empty(), "corrected Live Wire should accept class assignment")
		_expect_equal(crossing.store.get_corrected_record(0).regions.size(), before.regions.size() + 1, "a corrected retained contour should remain committable")
		_expect_equal(crossing.history.get_undo_count(), 1, "only the corrected success should create one command")

	var oversized_image := Image.create(700, 500, false, Image.FORMAT_RGBA8)
	oversized_image.fill(Color.BLACK)
	var oversized := _fixture(_record(), oversized_image)
	if _activate_tool(oversized, &"live_wire", "Live Wire search-cap refusal"):
		var before: Dictionary = oversized.store.get_corrected_record(0)
		_click(oversized.plugin, oversized.viewport, Vector2(0, 0))
		_hover(oversized.plugin, Vector2(699, 499), oversized.viewport)
		var first_refusal := _overlay(oversized).duplicate(true)
		_expect_equal(first_refusal.get("phase"), &"invalid", "an oversized edge search should remain as a red retained preview")
		_expect(String(first_refusal.get("message", "")).contains("ROI"), "search-cap refusal should explain the bounded ROI")
		_expect_equal(_private_int(oversized.plugin, &"_live_wire_cache_misses"), 1, "the first oversized search refusal should be cached as one miss")
		_hover(oversized.plugin, Vector2(699.2, 499.2), oversized.viewport)
		_expect_equal(_overlay(oversized), first_refusal, "a subpixel-equivalent refusal should reuse the exact cached result")
		_expect_equal(_private_int(oversized.plugin, &"_live_wire_cache_hits"), 1, "a cached refusal should count as a hit instead of repeating the search")
		_expect_equal(_private_int(oversized.plugin, &"_live_wire_cache_misses"), 1, "a cached refusal must not increase search misses")
		_expect_equal(oversized.plugin.get("_live_wire_anchors"), PackedVector2Array([Vector2.ZERO]), "search-cap refusal must preserve the first anchor")
		_expect_equal(oversized.store.get_corrected_record(0), before, "search-cap refusal must preserve Store")
		_expect_equal(oversized.history.get_undo_count(), 0, "search-cap refusal must create zero history")

	var long_image := Image.create(2050, 1, false, Image.FORMAT_RGBA8)
	long_image.fill(Color.GRAY)
	var long_bytes := long_image.get_data()
	var too_long := _fixture(_record(), long_image)
	if _activate_tool(too_long, &"live_wire", "Live Wire point-cap refusal"):
		var before: Dictionary = too_long.store.get_corrected_record(0)
		_click(too_long.plugin, too_long.viewport, Vector2.ZERO)
		_hover(too_long.plugin, Vector2(2049, 0), too_long.viewport)
		var refused := _overlay(too_long)
		_expect_equal(refused.get("phase"), &"invalid", "a path above 2,048 points should remain visibly red")
		_expect(String(refused.get("message", "")).contains("2,048"), "point-cap refusal should explain the exact interaction limit")
		_expect_equal(too_long.plugin.get("_live_wire_anchors"), PackedVector2Array([Vector2.ZERO]), "point-cap refusal must preserve the exact anchor")
		_expect_equal(too_long.plugin.get("_live_wire_points"), PackedVector2Array([Vector2.ZERO]), "point-cap refusal must preserve the exact fixed path")
		_expect_equal(_session_snapshot(too_long.plugin).get("before"), before, "point-cap refusal must retain the frozen Store snapshot")
		_expect_equal(too_long.store.get_corrected_record(0), before, "point-cap refusal must not mutate Store")
		_expect_equal(too_long.history.get_undo_count(), 0, "point-cap refusal must create zero history")
		_expect_equal(long_image.get_data(), long_bytes, "point-cap search must not mutate source Image bytes")

	var degenerate := _base_fixture()
	if _activate_tool(degenerate, &"live_wire", "Live Wire degenerate closure"):
		var before: Dictionary = degenerate.store.get_corrected_record(0)
		for anchor: Vector2 in [Vector2(10, 10), Vector2(20, 10), Vector2(30, 10)]:
			_click(degenerate.plugin, degenerate.viewport, anchor)
		var anchors: PackedVector2Array = degenerate.plugin.get("_live_wire_anchors").duplicate()
		var fixed: PackedVector2Array = degenerate.plugin.get("_live_wire_points").duplicate()
		_expect(degenerate.plugin.handle_key(_key(KEY_ENTER)), "degenerate closure should consume Enter")
		_expect_equal(_overlay(degenerate).get("phase"), &"invalid", "a zero-area Live Wire contour should remain visibly red")
		_expect_equal(degenerate.plugin.get("_live_wire_anchors"), anchors, "degenerate refusal must retain exact anchors")
		_expect_equal(degenerate.plugin.get("_live_wire_points"), fixed, "degenerate refusal must retain the exact fixed path")
		_expect_equal(_session_snapshot(degenerate.plugin).get("before"), before, "degenerate refusal must retain the exact frozen record")
		_expect_equal(degenerate.store.get_corrected_record(0), before, "degenerate refusal must preserve Store")
		_expect_equal(degenerate.history.get_undo_count(), 0, "degenerate refusal must create zero history")


func _test_live_wire_command_rejection_preserves_redo_and_frozen_preview() -> void:
	var fixture := _base_fixture()
	var rejecting_store := RejectOnceStore.new(fixture.store)
	fixture.store = rejecting_store
	fixture.context["store"] = rejecting_store
	fixture.selected[0] = "box-1"
	if not _activate_tool(fixture, &"select", "Live Wire command rejection setup"):
		return
	_expect(fixture.plugin.handle_key(_key(KEY_RIGHT)), "a real move should establish one undo entry before Live Wire rejection")
	_expect(fixture.history.undo(fixture.store), "command history should move the setup command into redo")
	_expect_equal(fixture.history.get_undo_count(), 0, "Live Wire rejection setup should leave no undo entries")
	_expect_equal(fixture.history.get_redo_count(), 1, "Live Wire rejection setup should retain one independent redo entry")
	var before: Dictionary = rejecting_store.get_corrected_record(0)
	_expect(fixture.plugin.set_active_tool(&"live_wire").is_empty(), "Live Wire should activate after redo setup")
	for anchor: Vector2 in [Vector2(60, 10), Vector2(80, 10), Vector2(80, 30), Vector2(60, 30)]:
		_click(fixture.plugin, fixture.viewport, anchor)
	var exact_anchors: PackedVector2Array = fixture.plugin.get("_live_wire_anchors").duplicate()
	var exact_fixed: PackedVector2Array = fixture.plugin.get("_live_wire_points").duplicate()
	var frozen_before: Dictionary = _session_snapshot(fixture.plugin).get("before", {}).duplicate(true)
	rejecting_store.reject_next_replace = true
	_expect(fixture.plugin.handle_key(_key(KEY_ENTER)), "a rejected Live Wire confirmation should consume Enter")
	var confirmation_errors := _confirm_pending_polygon(fixture)
	var refused := _overlay(fixture)
	var retained := _session_snapshot(fixture.plugin)
	_expect_equal(confirmation_errors, PackedStringArray(["forced replacement rejection"]), "Live Wire confirmation should expose the concrete Store error")
	_expect_equal(refused.get("phase"), &"awaiting_class", "a rejected Live Wire Add should retain a recoverable AwaitingClass preview")
	_expect_equal(refused.get("candidate_polygon"), PackedVector2Array([
		Vector2(60, 10), Vector2(80, 10), Vector2(80, 30), Vector2(60, 30),
	]), "command rejection should retain the exact independently expected ring")
	_expect(fixture.statuses.has("forced replacement rejection"), "rejected Live Wire confirmation should report the concrete Store error")
	_expect_equal(fixture.plugin.get("_live_wire_anchors"), exact_anchors, "command rejection must retain every anchor")
	_expect_equal(fixture.plugin.get("_live_wire_points"), exact_fixed, "command rejection must retain the exact fixed path")
	_expect_equal(retained.get("before"), frozen_before, "command rejection must retain the exact frozen before record")
	_expect_equal(rejecting_store.get_corrected_record(0), before, "rejected Live Wire Add must preserve Store exactly")
	_expect_equal(fixture.history.get_undo_count(), 0, "rejected Live Wire Add must not enter undo history")
	_expect_equal(fixture.history.get_redo_count(), 1, "rejected Live Wire Add must not clear the pre-existing redo entry")
	_expect(_confirm_pending_polygon(fixture).is_empty(), "the retained Live Wire candidate should be retryable")
	_expect_equal(rejecting_store.get_corrected_record(0).regions.size(), before.regions.size() + 1, "retry after command rejection should add exactly one region")
	_expect_equal(fixture.history.get_undo_count(), 1, "only the successful retry should create one command")


func _test_live_wire_pending_state_cannot_overwrite_an_intervening_edit() -> void:
	var fixture := _base_fixture()
	fixture.selected[0] = "box-1"
	if not _activate_tool(fixture, &"live_wire", "Live Wire stale-snapshot safety"):
		return
	for anchor: Vector2 in [Vector2(60, 10), Vector2(80, 10), Vector2(80, 30)]:
		_click(fixture.plugin, fixture.viewport, anchor)
	var before_arrow: Dictionary = fixture.store.get_corrected_record(0)
	_expect(fixture.plugin.handle_key(_key(KEY_RIGHT)), "a key during pointer Live Wire should be consumed")
	_expect_equal(
		fixture.store.get_corrected_record(0),
		before_arrow,
		"pointer Live Wire must not let an unrelated arrow edit mutate Store behind its frozen preview",
	)
	var relabel_errors: PackedStringArray = fixture.plugin.invoke(
		&"relabel_selected",
		{"class": "clip"},
	)
	_expect(relabel_errors.is_empty(), "an Inspector-style edit should cancel Live Wire before committing")
	var after_relabel: Dictionary = fixture.store.get_corrected_record(0)
	_expect_equal(_find_region(after_relabel, "box-1").get("class"), "clip", "the intervening edit should commit")
	_expect_equal(after_relabel.regions.size(), 2, "cancelling Live Wire must not add a stale polygon")
	_expect(fixture.plugin.handle_key(_key(KEY_ENTER)), "Enter after cancellation should be handled safely")
	_expect_equal(
		fixture.store.get_corrected_record(0),
		after_relabel,
		"confirming after an external edit must never restore Live Wire's frozen frame snapshot",
	)
	_expect_equal(fixture.history.get_undo_count(), 1, "only the intervening relabel should enter history")


func _base_fixture() -> Dictionary:
	return _fixture(_record(), _flat_image())


func _expect_pending_polygon_transaction(
	fixture: Dictionary,
	before: Dictionary,
	tool_id: StringName,
	class_label: String,
	kind: String,
) -> void:
	var allocator_before: int = fixture.allocator_before
	_expect_equal(fixture.store.get_corrected_record(0), before, "%s geometry completion must not mutate Store" % tool_id)
	_expect_equal(fixture.store.get_dirty_frames(), PackedInt64Array(), "%s geometry completion must not mark a dirty frame" % tool_id)
	_expect_equal(fixture.history.get_undo_count(), 0, "%s geometry completion must not enter History" % tool_id)
	_expect_equal(fixture.history.get_redo_count(), 0, "%s geometry completion must not alter redo History" % tool_id)
	_expect_equal(fixture.selected[0], "", "%s geometry completion must preserve selection" % tool_id)
	_expect_equal(ADD_POLYGON_COMMAND._next_session_id, allocator_before, "%s geometry completion must not allocate a region ID" % tool_id)
	_expect_equal(fixture.class_requests.size(), 1, "%s geometry completion must request class assignment exactly once" % tool_id)
	var request: Dictionary = fixture.class_requests[0] if fixture.class_requests.size() == 1 else {}
	_expect_equal(request.get("frame"), 0, "%s class request must identify the frozen frame" % tool_id)
	_expect_equal(request.get("tool_id"), tool_id, "%s class request must identify its creating tool" % tool_id)
	_expect(not request.has("geometry") and not request.has("image_size"), "%s class request must not expose private geometry" % tool_id)
	var overlay := _overlay(fixture)
	_expect_equal(overlay.get("phase"), &"awaiting_class", "%s must retain an AwaitingClass overlay" % tool_id)
	_expect_overlay_contract(overlay, "%s pending polygon" % tool_id)
	var pending_ring: Variant = overlay.get("candidate_polygon")
	_expect(pending_ring is PackedVector2Array and pending_ring.size() >= 3, "%s pending overlay must retain its exact ring" % tool_id)
	var cancel_errors: PackedStringArray = fixture.plugin.invoke(&"cancel_pending_region", {
		"candidate_token": request.get("candidate_token"),
	})
	_expect_equal(cancel_errors, PackedStringArray(), "%s must accept cancellation of its actual completed geometry" % tool_id)
	_expect_equal(fixture.store.get_corrected_record(0), before, "%s cancellation must preserve the exact Store" % tool_id)
	_expect_equal(fixture.store.get_dirty_frames(), PackedInt64Array(), "%s cancellation must preserve clean dirty-frame state" % tool_id)
	_expect_equal([fixture.history.get_undo_count(), fixture.history.get_redo_count()], [0, 0], "%s cancellation must preserve History" % tool_id)
	_expect_equal(fixture.selected[0], "", "%s cancellation must preserve selection" % tool_id)
	_expect_equal(ADD_POLYGON_COMMAND._next_session_id, allocator_before, "%s cancellation must preserve the allocator" % tool_id)
	_expect_equal(_overlay(fixture), {}, "%s cancellation must clear only its pending overlay" % tool_id)
	fixture.plugin.call(
		"_await_class_for_polygon",
		0,
		before,
		pending_ring,
		Vector2(fixture.viewport.current_image.get_size()),
		tool_id,
	)
	_expect_equal(fixture.class_requests.size(), 2, "%s retry must emit exactly one fresh class request" % tool_id)
	request = fixture.class_requests[1] if fixture.class_requests.size() == 2 else {}
	var errors: PackedStringArray = fixture.plugin.invoke(&"confirm_pending_region", {
		"candidate_token": request.get("candidate_token"),
		"class": class_label,
		"kind": kind,
	})
	_expect_equal(errors, PackedStringArray(), "%s should accept one valid class/kind confirmation" % tool_id)
	var after: Dictionary = fixture.store.get_corrected_record(0)
	_expect_equal(after.regions.size(), before.regions.size() + 1, "%s confirmation must add exactly one polygon" % tool_id)
	var added: Dictionary = after.regions.back() if after.regions.size() == before.regions.size() + 1 else {}
	_expect_equal(added.get("class"), class_label.strip_edges(), "%s must commit the exact trimmed free class" % tool_id)
	_expect_equal(added.get("kind"), kind.strip_edges(), "%s must commit the exact trimmed free kind" % tool_id)
	_expect_equal(_polygon_from_value(added.get("polygon", [])), pending_ring, "%s must commit the exact displayed pending ring" % tool_id)
	_expect_equal(fixture.history.get_undo_count(), 1, "%s confirmation must create exactly one AddPolygon command" % tool_id)
	_expect(fixture.history.undo(fixture.store), "%s AddPolygon must undo" % tool_id)
	_expect_equal(fixture.store.get_corrected_record(0), before, "%s undo must restore the exact prior record" % tool_id)
	_expect_equal(fixture.history.redo(fixture.store), PackedStringArray(), "%s AddPolygon must redo" % tool_id)
	_expect_equal(fixture.store.get_corrected_record(0), after, "%s redo must restore the exact committed record" % tool_id)


func _confirm_pending_polygon(
	fixture: Dictionary,
	class_label := "unknown",
	kind := "region",
) -> PackedStringArray:
	var request: Dictionary = fixture.plugin.get("_session").pending_request()
	return fixture.plugin.invoke(&"confirm_pending_region", {
		"candidate_token": request.get("candidate_token"),
		"class": class_label,
		"kind": kind,
	})


func _expect_pending_polygon_cancel(fixture: Dictionary, before: Dictionary, tool_id: StringName) -> void:
	var allocator_before: int = fixture.allocator_before
	_expect_equal(fixture.store.get_corrected_record(0), before, "%s pending cancellation setup must preserve Store" % tool_id)
	_expect_equal(fixture.history.get_undo_count(), 0, "%s pending cancellation setup must preserve History" % tool_id)
	_expect_equal(fixture.class_requests.size(), 1, "%s completion must emit exactly one class request" % tool_id)
	var request: Dictionary = fixture.class_requests[0] if fixture.class_requests.size() == 1 else {}
	_expect_equal(_overlay(fixture).get("phase"), &"awaiting_class", "%s cancellation setup must retain AwaitingClass" % tool_id)
	var errors: PackedStringArray = fixture.plugin.invoke(&"cancel_pending_region", {
		"candidate_token": request.get("candidate_token"),
	})
	_expect_equal(errors, PackedStringArray(), "%s pending cancellation should be accepted" % tool_id)
	_expect_equal(fixture.store.get_corrected_record(0), before, "%s cancel must preserve the exact Store" % tool_id)
	_expect_equal(fixture.store.get_dirty_frames(), PackedInt64Array(), "%s cancel must preserve clean dirty-frame state" % tool_id)
	_expect_equal([fixture.history.get_undo_count(), fixture.history.get_redo_count()], [0, 0], "%s cancel must preserve History" % tool_id)
	_expect_equal(fixture.selected[0], "", "%s cancel must preserve selection" % tool_id)
	_expect_equal(ADD_POLYGON_COMMAND._next_session_id, allocator_before, "%s cancel must preserve the allocator" % tool_id)
	_expect_equal(_overlay(fixture), {}, "%s cancel must clear only its private overlay" % tool_id)


func _fixture(record: Dictionary, image: Image) -> Dictionary:
	var store = STORE_SCRIPT.new()
	var load_errors: PackedStringArray = store.load_model_records([record])
	var history = HISTORY_SCRIPT.new()
	var viewport := ViewportProbe.new(image)
	var frame := [0]
	var selected := [""]
	var statuses: Array[String] = []
	var edit_states: Array[Dictionary] = []
	var class_requests: Array[Dictionary] = []
	var image_getter := func(): return viewport.current_image
	var context := {
		"store": store,
		"history": history,
		"viewport": viewport,
		"current_frame": func(): return frame[0],
		"selected_region": func(): return selected[0],
		"set_selected_region": func(value: String): selected[0] = value,
		"status": func(message: String): statuses.append(message),
		"edit_state_changed": func(state: Dictionary): edit_states.append(state.duplicate(true)),
		"request_class_assignment": func(request: Dictionary): class_requests.append(request.duplicate(true)),
		"taxonomy": {"classes": [{"id": "unknown", "kind": "region"}]},
		"get_current_image": image_getter,
		"current_image_getter": image_getter,
		"current_image": image_getter,
	}
	return {
		"plugin": PLUGIN_SCRIPT.new(),
		"store": store,
		"history": history,
		"viewport": viewport,
		"frame": frame,
		"selected": selected,
		"statuses": statuses,
		"edit_states": edit_states,
		"class_requests": class_requests,
		"context": context,
		"load_errors": load_errors,
		"allocator_before": ADD_POLYGON_COMMAND._next_session_id,
	}


func _activate_tool(fixture: Dictionary, tool_id: StringName, behavior: String) -> bool:
	_expect(fixture.load_errors.is_empty(), "%s fixture should be schema-valid" % behavior)
	if not fixture.load_errors.is_empty():
		return false
	var activation_errors: PackedStringArray = fixture.plugin.activate(fixture.context)
	_expect(activation_errors.is_empty(), "%s should activate with the normal edit context" % behavior)
	if not activation_errors.is_empty():
		return false
	var tool_errors: PackedStringArray = fixture.plugin.set_active_tool(tool_id)
	_expect(tool_errors.is_empty(), "%s should be a supported implemented tool" % behavior)
	return tool_errors.is_empty()


func _pointer(plugin: Variant, pressed: bool, image_position: Vector2, viewport: ViewportProbe, double_click := false) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = pressed
	event.double_click = double_click
	event.position = viewport.transform.image_to_viewport(image_position)
	plugin.handle_pointer(event, image_position)


func _motion(plugin: Variant, image_position: Vector2, viewport: ViewportProbe) -> void:
	var event := InputEventMouseMotion.new()
	event.position = viewport.transform.image_to_viewport(image_position)
	event.button_mask = MOUSE_BUTTON_MASK_LEFT
	plugin.handle_pointer(event, image_position)


func _hover(plugin: Variant, image_position: Vector2, viewport: ViewportProbe) -> void:
	var event := InputEventMouseMotion.new()
	event.position = viewport.transform.image_to_viewport(image_position)
	event.button_mask = 0
	plugin.handle_pointer(event, image_position)


func _click(plugin: Variant, viewport: ViewportProbe, image_position: Vector2) -> void:
	_pointer(plugin, true, image_position, viewport)
	_pointer(plugin, false, image_position, viewport)


func _gesture(plugin: Variant, viewport: ViewportProbe, points: Array) -> void:
	if points.is_empty():
		return
	_pointer(plugin, true, points[0], viewport)
	for index in range(1, points.size()):
		_motion(plugin, points[index], viewport)
	_pointer(plugin, false, points.back(), viewport)


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
			{"id": "box-1", "class": "grasper", "kind": "instrument", "box": [10, 10, 20, 15], "conf": 0.9, "track_id": "T01"},
			{"id": "poly-1", "class": "gallbladder", "kind": "anatomy", "polygon": [[40, 40], [55, 40], [45, 55]], "conf": 0.8, "track_id": null},
		],
	}


func _enclosed_blank_record() -> Dictionary:
	return {
		"schema_version": 1,
		"source": "sample_v1",
		"frame": 0,
		"regions": [
			{"id": "top", "class": "guide", "kind": "region", "box": [20, 20, 40, 5], "track_id": null},
			{"id": "bottom", "class": "guide", "kind": "region", "box": [20, 55, 40, 5], "track_id": null},
			{"id": "left", "class": "guide", "kind": "region", "box": [20, 25, 5, 30], "track_id": null},
			{"id": "right", "class": "guide", "kind": "region", "box": [55, 25, 5, 30], "track_id": null},
		],
	}


func _flat_image() -> Image:
	var image := Image.create(100, 80, false, Image.FORMAT_RGBA8)
	image.fill(Color.BLACK)
	return image


func _find_region(record: Dictionary, region_id: String) -> Dictionary:
	for value: Variant in record.get("regions", []):
		if value is Dictionary and value.get("id") == region_id:
			return value
	return {}


func _region_polygon(record: Dictionary, region_id: String) -> PackedVector2Array:
	var region := _find_region(record, region_id)
	if region.has("polygon"):
		return _polygon_from_value(region.get("polygon", []))
	if region.has("box"):
		return POLYGON_OPS.box_to_polygon(region.get("box", []))
	return PackedVector2Array()


func _descriptor(descriptors: Array, tool_id: StringName) -> Dictionary:
	for value: Variant in descriptors:
		if value is Dictionary and StringName(value.get("id", &"")) == tool_id:
			return value
	return {}


func _overlay(fixture: Dictionary) -> Dictionary:
	var overlays: Array[Dictionary] = fixture.viewport.overlays
	return overlays.back() if not overlays.is_empty() else {}


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


func _latest_overlay_with_phase(fixture: Dictionary, phase: StringName) -> Dictionary:
	var overlays: Array[Dictionary] = fixture.viewport.overlays
	for index in range(overlays.size() - 1, -1, -1):
		if StringName(overlays[index].get("phase", &"")) == phase:
			return overlays[index]
	return {}


func _install_working_mask(fixture: Dictionary, state: Dictionary, message: String) -> void:
	var session: Variant = fixture.plugin.get("_session")
	session.begin(&"paint", 0, "", fixture.store.get_corrected_record(0))
	session.set_working_mask(state, message)
	fixture.plugin.call("_push_session_overlay")


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


func _double_outline_state() -> Dictionary:
	var roi := Rect2i(50, 10, 21, 31)
	var mask := PackedByteArray()
	mask.resize(roi.size.x * roi.size.y)
	# Narrow upper lobe and wider lower lobe share a solid waist boundary.
	for x in range(4, 17):
		mask[1 * roi.size.x + x] = 1
		mask[14 * roi.size.x + x] = 1
	for y in range(1, 15):
		mask[y * roi.size.x + 4] = 1
		mask[y * roi.size.x + 16] = 1
	for x in range(2, 19):
		mask[14 * roi.size.x + x] = 1
		mask[29 * roi.size.x + x] = 1
	for y in range(14, 30):
		mask[y * roi.size.x + 2] = 1
		mask[y * roi.size.x + 18] = 1
	return {"roi": roi, "mask": mask}


func _figure_eight_gesture() -> Array[Vector2]:
	return [
		Vector2(40, 25), Vector2(28, 10), Vector2(12, 10), Vector2(8, 18),
		Vector2(20, 28), Vector2(40, 25), Vector2(52, 10), Vector2(68, 10),
		Vector2(72, 18), Vector2(60, 28), Vector2(40, 25),
	]


func _mask_at(state: Dictionary, point: Vector2i) -> int:
	var roi: Rect2i = state.get("roi", Rect2i())
	var mask: PackedByteArray = state.get("mask", PackedByteArray())
	if not roi.has_point(point) or mask.size() != roi.size.x * roi.size.y:
		return 0
	var local := point - roi.position
	return mask[local.y * roi.size.x + local.x]


func _session_snapshot(plugin: Variant) -> Dictionary:
	var session: Variant = plugin.get("_session")
	return {
		"phase": session.phase,
		"tool_id": session.tool_id,
		"frame": session.frame,
		"region_id": session.region_id,
		"before": session.before.duplicate(true),
		"points": session.points.duplicate(),
		"working_mask": session.working_mask.duplicate(true),
		"candidate_polygon": session.candidate_polygon.duplicate(),
		"cursor": session.cursor,
		"brush_radius": session.brush_radius,
		"message": session.message,
		"fill_color": session.fill_color,
	}


func _expect_retained_subtract(
	fixture: Dictionary,
	drawn_points: Array,
	expected_before: Dictionary,
	expected_target: String,
	behavior: String,
) -> void:
	var expected_path := PackedVector2Array()
	for point: Variant in drawn_points:
		expected_path.append(point)
	var expected_candidate := expected_path.duplicate()
	if expected_candidate.size() > 1 and expected_candidate[0].is_equal_approx(expected_candidate[-1]):
		expected_candidate.remove_at(expected_candidate.size() - 1)
	var overlay := _overlay(fixture)
	var snapshot := _session_snapshot(fixture.plugin)
	_expect_equal(overlay.get("phase"), &"invalid", "%s should retain an Invalid overlay" % behavior)
	_expect_equal(overlay.get("path"), expected_path, "%s should retain the exact drawn contour" % behavior)
	_expect_equal(overlay.get("candidate_polygon"), expected_candidate, "%s should retain a filled contour candidate" % behavior)
	_expect_equal(overlay.get("fill_color"), INVALID_COLOR, "%s should retain a red fill" % behavior)
	_expect(not String(overlay.get("message", "")).is_empty(), "%s should retain an explanation" % behavior)
	_expect_equal(snapshot.get("tool_id"), &"subtract", "%s should remain owned by Subtract" % behavior)
	_expect_equal(snapshot.get("frame"), 0, "%s should retain the frozen frame" % behavior)
	_expect_equal(snapshot.get("region_id"), expected_target, "%s should retain the frozen target" % behavior)
	_expect_equal(snapshot.get("before"), expected_before, "%s should retain the exact frozen Store snapshot" % behavior)
	_expect_equal(fixture.plugin.get("_drag_kind"), "", "%s should wait for a fresh pointer correction instead of remaining pressed" % behavior)
	_expect_equal(fixture.plugin.get("_drag_frame"), 0, "%s should retain the pointer transaction frame" % behavior)
	_expect_equal(fixture.plugin.get("_drag_region_id"), expected_target, "%s should retain the pointer transaction target" % behavior)
	_expect_equal(fixture.plugin.get("_drag_before"), expected_before, "%s should retain the exact pointer transaction snapshot" % behavior)


func _polygon_from_value(value: Variant) -> PackedVector2Array:
	var result := PackedVector2Array()
	if not value is Array:
		return result
	for item: Variant in value:
		if item is Array and item.size() == 2:
			result.append(Vector2(float(item[0]), float(item[1])))
	return result


func _absolute_area(polygon: PackedVector2Array) -> float:
	if polygon.size() < 3:
		return 0.0
	var twice_area := 0.0
	for index in range(polygon.size()):
		twice_area += polygon[index].cross(polygon[(index + 1) % polygon.size()])
	return absf(twice_area) * 0.5


func _private_int(object: Object, property_name: StringName) -> int:
	for value: Dictionary in object.get_property_list():
		if StringName(value.get("name", &"")) == property_name:
			return int(object.get(property_name))
	return -1


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


func _expect_equal(actual: Variant, expected: Variant, message: String) -> void:
	_expect(actual == expected, "%s (expected %s, got %s)" % [message, str(expected), str(actual)])
