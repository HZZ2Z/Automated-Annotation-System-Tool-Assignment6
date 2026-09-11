extends RefCounted

const VIEWPORT_SCENE = preload("res://client/ui/annotation_viewport.tscn")
const RENDERER_SCRIPT = preload("res://client/plugins/render/canvas_region_renderer/plugin.gd")


class HoverRenderer extends RefCounted:
	var hover_calls: Array[String] = []

	func set_state(_texture: Texture2D, _record: Dictionary, _transform: Variant, _selected_id: String, _opacity: float) -> void:
		pass

	func draw(_canvas: CanvasItem) -> void:
		pass

	func hit_test(_image_point: Vector2) -> Dictionary:
		return {}

	func set_hovered_region_id(region_id: String) -> void:
		hover_calls.append(region_id)


class RequiredOnlyRenderer extends RefCounted:
	func set_state(_texture: Texture2D, _record: Dictionary, _transform: Variant, _selected_id: String, _opacity: float) -> void:
		pass

	func draw(_canvas: CanvasItem) -> void:
		pass

	func hit_test(_image_point: Vector2) -> Dictionary:
		return {}


func run(support, tree: SceneTree) -> void:
	await _test_scene_and_dirty_redraws(support, tree)
	await _test_cpu_image_snapshot_identity_and_refresh(support, tree)
	await _test_same_texture_content_refresh(support, tree)
	await _test_same_texture_identity_dimension_reconfiguration(support, tree)
	await _test_set_record_uses_snapshots(support, tree)
	await _test_set_state_uses_snapshots(support, tree)
	await _test_clearing_image_state_invalidates_transform(support, tree)
	await _test_resize_preserves_user_view(support, tree)
	await _test_transformed_selection_and_pointer_signal(support, tree)
	await _test_edit_overlay_preserves_image_space_state(support, tree)
	await _test_edit_plugin_can_own_internal_selection(support, tree)
	await _test_letterbox_selection_and_clamped_drag(support, tree)
	await _test_reset_view_to_fit(support, tree)
	await _test_edit_pointer_boundary_and_order(support, tree)
	await _test_right_click_requests_selection_cancel(support, tree)
	await _test_wheel_and_pan_controls(support, tree)
	await _test_focus_out_preserves_non_space_pan_contract(support, tree)
	await _test_space_in_text_input_never_enables_pan(support, tree)
	await _test_hover_forwarding_is_optional(support, tree)


func _test_scene_and_dirty_redraws(support, tree: SceneTree) -> void:
	var viewport := VIEWPORT_SCENE.instantiate() as Control
	support.expect(viewport != null, "annotation viewport scene should instantiate as a Control")
	if viewport == null:
		return
	var initial_renderer: Variant = viewport.get("_renderer")
	support.expect(
		initial_renderer != null and initial_renderer.get_script().resource_path == "res://client/pipeline/null_renderer.gd",
		"AnnotationViewport should depend only on a neutral core fallback before renderer injection",
	)
	viewport.set_renderer(RENDERER_SCRIPT.new())
	viewport.set_anchors_preset(Control.PRESET_TOP_LEFT)
	viewport.size = Vector2(800, 600)
	var draws := [0]
	viewport.draw.connect(func(): draws[0] += 1)
	tree.root.add_child(viewport)
	await tree.process_frame
	draws[0] = 0

	var record := _record()
	viewport.call("set_record", record)
	await tree.process_frame
	support.expect_equal(draws[0], 1, "record change should queue one redraw")
	viewport.call("set_record", record)
	await tree.process_frame
	support.expect_equal(draws[0], 1, "setting the same record should not queue another redraw")

	viewport.call("set_selected_region_id", "box")
	await tree.process_frame
	support.expect_equal(draws[0], 2, "selection change should queue a redraw")
	viewport.call("set_selected_region_id", "box")
	await tree.process_frame
	support.expect_equal(draws[0], 2, "setting the same selection should not queue another redraw")

	viewport.call("set_overlay_opacity", 0.7)
	await tree.process_frame
	support.expect_equal(draws[0], 3, "opacity change should queue a redraw")
	viewport.call("set_overlay_opacity", 0.7)
	await tree.process_frame
	support.expect_equal(draws[0], 3, "setting the same opacity should not queue another redraw")

	var image := Image.create(200, 120, false, Image.FORMAT_RGBA8)
	image.fill(Color.DARK_SLATE_GRAY)
	var texture := ImageTexture.create_from_image(image)
	viewport.call("set_texture", texture)
	await tree.process_frame
	support.expect_equal(draws[0], 4, "texture change should queue a redraw")
	var current_image: Variant = viewport.call("get_current_image")
	support.expect(current_image is Image, "annotation viewport should expose the current image to image-aware edit tools")
	if current_image is Image:
		support.expect_equal(current_image.get_size(), Vector2i(200, 120), "current edit image should retain source dimensions")
		support.expect(current_image.get_pixel(0, 0).is_equal_approx(Color.DARK_SLATE_GRAY), "current edit image should retain source pixels")
		support.expect(is_same(current_image, viewport.call("get_current_image")), "repeated current-image reads should return one stable CPU snapshot identity")
	viewport.call("set_texture", texture)
	await tree.process_frame
	support.expect_equal(draws[0], 4, "setting the same texture should not queue another redraw")
	support.expect(not is_same(current_image, viewport.call("get_current_image")), "an explicit same-texture submission should conservatively refresh the cached CPU snapshot identity")
	viewport.call("notify_transform_changed")
	await tree.process_frame
	support.expect_equal(draws[0], 4, "an unchanged transform notification should not queue another redraw")
	var transform = viewport.call("get_image_transform")
	transform.pan_by(Vector2(1, 0))
	viewport.call("notify_transform_changed")
	await tree.process_frame
	support.expect_equal(draws[0], 5, "an actual transform change should queue a redraw")
	viewport.queue_free()
	await tree.process_frame


func _test_hover_forwarding_is_optional(support, tree: SceneTree) -> void:
	var viewport := VIEWPORT_SCENE.instantiate() as Control
	viewport.set_anchors_preset(Control.PRESET_TOP_LEFT)
	viewport.size = Vector2(800, 600)
	tree.root.add_child(viewport)
	await tree.process_frame
	var redraws := [0]
	viewport.draw.connect(func(): redraws[0] += 1)
	var hover_renderer := HoverRenderer.new()
	viewport.set_renderer(hover_renderer)
	await tree.process_frame
	hover_renderer.hover_calls.clear()
	redraws[0] = 0

	viewport.call("set_hovered_region_id", "box")
	await tree.process_frame
	support.expect_equal(viewport.call("get_hovered_region_id"), "box", "viewport should retain the current transient hover ID")
	support.expect_equal(hover_renderer.hover_calls, ["box"], "viewport should forward each changed hover ID to a supporting renderer")
	support.expect(redraws[0] > 0, "a changed hover ID should queue a viewport redraw")

	redraws[0] = 0
	viewport.call("set_hovered_region_id", "box")
	await tree.process_frame
	support.expect_equal(hover_renderer.hover_calls, ["box"], "reapplying the same hover ID should not call the renderer again")
	support.expect_equal(redraws[0], 0, "reapplying the same hover ID should not queue another redraw")

	viewport.call("set_renderer", hover_renderer)
	support.expect_equal(hover_renderer.hover_calls, ["box", "box"], "a newly set renderer should receive the current hover ID")

	redraws[0] = 0
	viewport.call("set_hovered_region_id", "")
	await tree.process_frame
	support.expect_equal(viewport.call("get_hovered_region_id"), "", "clearing hover should restore the empty hover ID")
	support.expect_equal(hover_renderer.hover_calls, ["box", "box", ""], "clearing hover should be forwarded once")
	support.expect(redraws[0] > 0, "clearing a hover ID should queue a viewport redraw")

	var required_only_renderer := RequiredOnlyRenderer.new()
	viewport.call("set_renderer", required_only_renderer)
	viewport.call("set_hovered_region_id", "without-optional-method")
	support.expect_equal(viewport.call("get_hovered_region_id"), "without-optional-method", "viewport should accept a required RenderStage v1 renderer without hover support")

	viewport.queue_free()
	await tree.process_frame


func _test_cpu_image_snapshot_identity_and_refresh(support, tree: SceneTree) -> void:
	var viewport := await _mounted_viewport(tree)
	var first_pixels := Image.create(32, 24, false, Image.FORMAT_RGBA8)
	first_pixels.fill(Color.RED)
	var texture := ImageTexture.create_from_image(first_pixels)
	viewport.call("set_texture", texture)
	var first_snapshot: Image = viewport.call("get_current_image")
	support.expect(first_snapshot != null, "set_texture should cache one CPU-readable image snapshot")
	support.expect_equal(viewport.get("_current_image_capture_count"), 1, "the initial texture submission should perform exactly one CPU image capture")
	support.expect(is_same(first_snapshot, viewport.call("get_current_image")), "get_current_image should never repeat Texture2D GPU readback between state updates")
	support.expect_equal(viewport.get("_current_image_capture_count"), 1, "repeated get_current_image calls should not perform another texture readback")
	support.expect(first_snapshot != first_pixels, "the viewport should expose a texture snapshot rather than the caller's mutable source Image")

	viewport.call("set_texture", texture)
	var refreshed_snapshot: Image = viewport.call("get_current_image")
	support.expect_equal(viewport.get("_current_image_capture_count"), 2, "an explicit same-texture submission should perform exactly one conservative recapture")
	support.expect(not is_same(refreshed_snapshot, first_snapshot), "same-identity texture submissions with unchanged dimensions should conservatively refresh the cached CPU snapshot")
	support.expect(is_same(refreshed_snapshot, viewport.call("get_current_image")), "a refreshed same-identity texture should remain stable across repeated reads")
	support.expect(refreshed_snapshot.get_pixel(0, 0).is_equal_approx(Color.RED), "same-identity refresh should preserve the submitted texture pixels")
	viewport.call("set_texture", texture)
	var second_refresh: Image = viewport.call("get_current_image")
	support.expect_equal(viewport.get("_current_image_capture_count"), 3, "each explicit same-texture submission should have one and only one readback")
	support.expect(not is_same(second_refresh, refreshed_snapshot), "each explicit same-texture submission should invalidate a possibly stale algorithm cache")
	support.expect(is_same(second_refresh, viewport.call("get_current_image")), "the conservative refresh should still perform no per-event readback")

	var replacement_pixels := Image.create(32, 24, false, Image.FORMAT_RGBA8)
	replacement_pixels.fill(Color.GREEN)
	var replacement_texture := ImageTexture.create_from_image(replacement_pixels)
	viewport.call("set_texture", replacement_texture)
	var replacement_snapshot: Image = viewport.call("get_current_image")
	support.expect_equal(viewport.get("_current_image_capture_count"), 4, "a replacement texture should perform exactly one CPU image capture")
	support.expect(not is_same(replacement_snapshot, refreshed_snapshot), "a same-size replacement texture should install a different CPU snapshot identity")
	support.expect(replacement_snapshot.get_pixel(0, 0).is_equal_approx(Color.GREEN), "a same-size replacement texture should expose its own pixels")

	viewport.call("set_state", replacement_texture, {}, "", 0.35)
	var state_snapshot: Image = viewport.call("get_current_image")
	support.expect_equal(viewport.get("_current_image_capture_count"), 5, "an explicit same-texture set_state should perform exactly one conservative recapture")
	support.expect(not is_same(state_snapshot, replacement_snapshot), "set_state should conservatively refresh a same-identity texture even when all other state is equal")
	support.expect(state_snapshot.get_pixel(0, 0).is_equal_approx(Color.GREEN), "set_state same-identity refresh should preserve the submitted texture pixels")
	support.expect(is_same(state_snapshot, viewport.call("get_current_image")), "set_state should also leave one stable CPU snapshot between updates")
	var state_pixels := Image.create(32, 24, false, Image.FORMAT_RGBA8)
	state_pixels.fill(Color.YELLOW)
	var state_texture := ImageTexture.create_from_image(state_pixels)
	viewport.call("set_state", state_texture, {}, "", 0.35)
	var replacement_state_snapshot: Image = viewport.call("get_current_image")
	support.expect_equal(viewport.get("_current_image_capture_count"), 6, "replacement-frame set_state should perform exactly one CPU image capture")
	support.expect(not is_same(replacement_state_snapshot, state_snapshot), "set_state should give a same-size replacement frame a different CPU identity")
	support.expect(replacement_state_snapshot.get_pixel(0, 0).is_equal_approx(Color.YELLOW), "set_state should cache the correct replacement-frame pixels")

	viewport.call("set_texture", null)
	support.expect(viewport.call("get_current_image") == null, "clearing the displayed texture should clear the cached CPU image")
	viewport.queue_free()
	await tree.process_frame


func _test_same_texture_content_refresh(support, tree: SceneTree) -> void:
	var viewport := await _mounted_viewport(tree)
	var first_pixels := Image.create(20, 16, false, Image.FORMAT_RGBA8)
	first_pixels.fill(Color.RED)
	var second_pixels := Image.create(20, 16, false, Image.FORMAT_RGBA8)
	second_pixels.fill(Color.BLUE)
	var third_pixels := Image.create(20, 16, false, Image.FORMAT_RGBA8)
	third_pixels.fill(Color.GREEN)
	var mutable_texture := AtlasTexture.new()
	mutable_texture.region = Rect2(0, 0, 20, 16)
	mutable_texture.atlas = ImageTexture.create_from_image(first_pixels)
	viewport.call("set_texture", mutable_texture)
	var first_snapshot: Image = viewport.call("get_current_image")
	support.expect(first_snapshot.get_pixel(0, 0).is_equal_approx(Color.RED), "same-identity content fixture should begin with the first pixels")

	mutable_texture.atlas = ImageTexture.create_from_image(second_pixels)
	viewport.call("set_texture", mutable_texture)
	var second_snapshot: Image = viewport.call("get_current_image")
	support.expect(not is_same(second_snapshot, first_snapshot), "set_texture should invalidate a same-identity Texture2D whose content source changed")
	support.expect(second_snapshot.get_pixel(0, 0).is_equal_approx(Color.BLUE), "set_texture should recapture changed content from the same Texture2D identity")
	support.expect(is_same(second_snapshot, viewport.call("get_current_image")), "same-identity changed content should remain one stable snapshot after set_texture")

	mutable_texture.atlas = ImageTexture.create_from_image(third_pixels)
	viewport.call("set_state", mutable_texture, {}, "", 0.35)
	var third_snapshot: Image = viewport.call("get_current_image")
	support.expect(not is_same(third_snapshot, second_snapshot), "set_state should invalidate a same-identity Texture2D whose content source changed")
	support.expect(third_snapshot.get_pixel(0, 0).is_equal_approx(Color.GREEN), "set_state should recapture changed content from the same Texture2D identity")
	support.expect(is_same(third_snapshot, viewport.call("get_current_image")), "same-identity changed content should remain one stable snapshot after set_state")
	viewport.queue_free()
	await tree.process_frame


func _test_same_texture_identity_dimension_reconfiguration(support, tree: SceneTree) -> void:
	var viewport := await _mounted_viewport(tree)
	var texture := ImageTexture.create_from_image(Image.create(200, 120, false, Image.FORMAT_RGBA8))
	viewport.call("set_texture", texture)
	viewport.call("set_edit_overlay", {
		"phase": &"drawing",
		"path": PackedVector2Array([Vector2(5, 6), Vector2(15, 16)]),
		"candidate_polygon": PackedVector2Array(),
		"mask_preview": {},
		"cursor": Vector2(15, 16),
		"brush_radius": 3.0,
		"message": "",
		"fill_color": Color.TRANSPARENT,
	})
	await tree.process_frame
	var overlay := viewport.get_node("EditOverlay") as Control
	var overlay_redraws := [0]
	var transform_changes := [0]
	overlay.draw.connect(func(): overlay_redraws[0] += 1)
	viewport.transform_changed.connect(func(): transform_changes[0] += 1)

	texture.set_image(Image.create(320, 180, false, Image.FORMAT_RGBA8))
	viewport.call("set_texture", texture)
	await tree.process_frame
	support.expect_equal(viewport.call("get_image_transform").image_size, Vector2(320, 180), "same ImageTexture identity with new dimensions reconfigures the viewport transform")
	support.expect_equal(viewport.call("get_edit_overlay_state")["path"], PackedVector2Array([Vector2(5, 6), Vector2(15, 16)]), "same-object texture reconfiguration preserves image-space overlay state")
	support.expect_equal(transform_changes[0], 1, "same-object dimension change publishes one transform update")
	support.expect(overlay_redraws[0] > 0, "same-object dimension change refreshes EditOverlay drawing")
	viewport.queue_free()
	await tree.process_frame


func _test_set_record_uses_snapshots(support, tree: SceneTree) -> void:
	var viewport := await _mounted_viewport(tree)
	var caller_record := _record()
	viewport.call("set_record", caller_record)
	await tree.process_frame
	var draws := [0]
	viewport.draw.connect(func(): draws[0] += 1)
	var selected_ids: Array[String] = []
	viewport.connect("region_selected", func(region_id: String): selected_ids.append(region_id))

	caller_record["regions"][0]["id"] = "moved"
	caller_record["regions"][0]["box"] = [100, 10, 40, 40]
	_click(viewport, Vector2(25, 25))
	_click(viewport, Vector2(115, 25))
	support.expect_equal(selected_ids, ["box", ""], "set_record should isolate viewport picking from later caller mutation while empty clicks clear selection")
	support.expect_equal(draws[0], 0, "caller mutation alone should not queue viewport redraw")

	selected_ids.clear()
	viewport.call("set_record", caller_record)
	await tree.process_frame
	support.expect_equal(draws[0], 1, "explicitly setting a modified caller snapshot should queue exactly one redraw")
	_click(viewport, Vector2(25, 25))
	_click(viewport, Vector2(115, 25))
	support.expect_equal(selected_ids, ["", "moved"], "explicitly setting a modified caller snapshot should update viewport picking")
	viewport.call("set_record", caller_record)
	await tree.process_frame
	support.expect_equal(draws[0], 1, "reapplying an equal record snapshot should not redraw")
	viewport.queue_free()
	await tree.process_frame


func _test_set_state_uses_snapshots(support, tree: SceneTree) -> void:
	var viewport := await _mounted_viewport(tree)
	var caller_record := _record()
	viewport.call("set_state", null, caller_record, "", 0.35)
	await tree.process_frame
	var draws := [0]
	viewport.draw.connect(func(): draws[0] += 1)
	var selected_ids: Array[String] = []
	viewport.connect("region_selected", func(region_id: String): selected_ids.append(region_id))

	caller_record["regions"][0]["id"] = "state-moved"
	caller_record["regions"][0]["box"] = [100, 10, 40, 40]
	_click(viewport, Vector2(25, 25))
	_click(viewport, Vector2(115, 25))
	support.expect_equal(selected_ids, ["box", ""], "set_state should isolate viewport picking from later caller mutation while empty clicks clear selection")
	viewport.call("set_state", null, caller_record, "", 0.35)
	await tree.process_frame
	support.expect_equal(draws[0], 1, "explicitly setting modified combined state should queue exactly one redraw")
	selected_ids.clear()
	_click(viewport, Vector2(25, 25))
	_click(viewport, Vector2(115, 25))
	support.expect_equal(selected_ids, ["", "state-moved"], "explicitly setting modified combined state should update viewport picking")
	viewport.call("set_state", null, caller_record, "", 0.35)
	await tree.process_frame
	support.expect_equal(draws[0], 1, "reapplying equal combined state should not redraw")
	viewport.queue_free()
	await tree.process_frame


func _test_clearing_image_state_invalidates_transform(support, tree: SceneTree) -> void:
	var viewport := VIEWPORT_SCENE.instantiate() as Control
	viewport.set_anchors_preset(Control.PRESET_TOP_LEFT)
	viewport.size = Vector2(800, 600)
	tree.root.add_child(viewport)
	viewport.call("set_record", _record())
	var transform = viewport.call("get_image_transform")
	support.expect(transform.is_configured(), "record image dimensions should configure the viewport transform")
	viewport.call("set_record", {})
	support.expect(not transform.is_configured(), "clearing the only image dimensions should invalidate stale coordinate mapping")
	support.expect_equal(transform.viewport_to_image(Vector2(50, 50)), Vector2.ZERO, "cleared viewport should use the transform safe sentinel")
	viewport.queue_free()
	await tree.process_frame


func _test_resize_preserves_user_view(support, tree: SceneTree) -> void:
	var viewport := await _mounted_viewport(tree)
	viewport.call("set_record", _record())
	var transform = viewport.call("get_image_transform")
	transform.zoom_at(transform.image_to_viewport(Vector2.ZERO), 1.8)
	transform.pan_by(Vector2(23, -11))
	viewport.call("notify_transform_changed")
	var preserved_image_center: Vector2 = transform.viewport_to_image(transform.viewport_rect.get_center())
	viewport.size = Vector2(900, 650)
	await tree.process_frame
	support.expect(absf(transform.user_zoom - 1.8) < 0.000001, "valid viewport resize should preserve user zoom")
	support.expect(transform.image_to_viewport(preserved_image_center).distance_to(transform.viewport_rect.get_center()) < 0.00001, "valid viewport resize should preserve the image point at the view center")
	support.expect_equal(transform.viewport_rect, Rect2(Vector2.ZERO, Vector2(900, 650)), "valid viewport resize should configure the new local rect")
	viewport.queue_free()
	await tree.process_frame


func _test_transformed_selection_and_pointer_signal(support, tree: SceneTree) -> void:
	var viewport := VIEWPORT_SCENE.instantiate() as Control
	viewport.set_renderer(RENDERER_SCRIPT.new())
	viewport.set_anchors_preset(Control.PRESET_TOP_LEFT)
	viewport.size = Vector2(800, 600)
	tree.root.add_child(viewport)
	viewport.call("set_record", _record())
	var transform = viewport.call("get_image_transform")
	transform.zoom_at(Vector2(300, 240), 1.8)
	transform.pan_by(Vector2(37, -19))
	viewport.call("notify_transform_changed")
	var selected_ids: Array[String] = []
	var pointer_positions: Array[Vector2] = []
	viewport.connect("region_selected", func(region_id: String): selected_ids.append(region_id))
	viewport.connect("image_pointer_event", func(_event: InputEvent, image_position: Vector2): pointer_positions.append(image_position))
	var image_point := Vector2(25, 25)
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	click.position = transform.image_to_viewport(image_point)
	viewport.call("_gui_input", click)
	support.expect_equal(selected_ids, ["box"], "selection should use the same transformed coordinates as drawing")
	support.expect(pointer_positions.size() == 1 and pointer_positions[0].distance_to(image_point) < 0.00001, "pointer signal should expose image coordinates")
	viewport.queue_free()
	await tree.process_frame


func _test_edit_overlay_preserves_image_space_state(support, tree: SceneTree) -> void:
	var viewport := await _mounted_viewport(tree)
	viewport.call("set_record", _record())
	var state := {
		"phase": &"drawing",
		"path": PackedVector2Array([Vector2(4, 6), Vector2(20, 18)]),
		"candidate_polygon": PackedVector2Array(),
		"mask_preview": {},
		"cursor": Vector2(20, 18),
		"brush_radius": 5.0,
		"message": "",
		"fill_color": Color.TRANSPARENT,
	}
	viewport.call("set_edit_overlay", state)
	state["path"][0] = Vector2(99, 99)
	var expected_path := PackedVector2Array([Vector2(4, 6), Vector2(20, 18)])
	support.expect_equal(viewport.call("get_edit_overlay_state")["path"], expected_path, "viewport isolates caller-owned EditOverlay state")
	support.expect_equal(viewport.get("_record"), _record(), "transient overlays never enter the committed viewport record")

	var transform = viewport.call("get_image_transform")
	transform.zoom_at(Vector2(300, 240), 1.8)
	transform.pan_by(Vector2(23, -9))
	viewport.call("notify_transform_changed")
	support.expect_equal(viewport.call("get_edit_overlay_state")["path"], expected_path, "zoom and pan preserve image-space overlay points")
	support.expect_equal(viewport.call("get_edit_overlay_state")["phase"], &"drawing", "zoom and pan preserve the session phase")

	viewport.call("reset_view_to_fit")
	support.expect_equal(viewport.call("get_edit_overlay_state")["path"], expected_path, "Fit preserves image-space overlay points")
	viewport.size = Vector2(900, 650)
	await tree.process_frame
	support.expect_equal(viewport.call("get_edit_overlay_state")["path"], expected_path, "viewport resize preserves image-space overlay points")

	var image := Image.create(200, 120, false, Image.FORMAT_RGBA8)
	viewport.call("set_texture", ImageTexture.create_from_image(image))
	await tree.process_frame
	support.expect_equal(viewport.call("get_edit_overlay_state")["path"], expected_path, "texture-size reconfiguration preserves image-space overlay points")
	var overlay := viewport.get_node("EditOverlay") as Control
	support.expect_equal(overlay.mouse_filter, Control.MOUSE_FILTER_IGNORE, "mounted EditOverlay is mouse transparent")

	viewport.call("clear_edit_overlay")
	support.expect_equal(viewport.call("get_edit_overlay_state"), {}, "clear_edit_overlay removes transient drawing without touching committed content")
	support.expect_equal(viewport.get("_record"), _record(), "clearing EditOverlay leaves the committed record unchanged")
	viewport.queue_free()
	await tree.process_frame


func _test_edit_plugin_can_own_internal_selection(support, tree: SceneTree) -> void:
	var viewport := await _mounted_viewport(tree)
	viewport.call("set_record", _record())
	viewport.call("set_edit_selection_authoritative", true)
	var selections: Array[String] = []
	var pointers: Array[Vector2] = []
	viewport.region_selected.connect(func(region_id: String): selections.append(region_id))
	viewport.image_pointer_event.connect(func(_event: InputEvent, point: Vector2): pointers.append(point))
	_press_viewport(viewport, viewport.call("get_image_transform").image_to_viewport(Vector2(25, 25)))
	support.expect_equal(selections, [], "an active Edit plugin should own selection for clicks inside the image")
	support.expect_equal(pointers, [Vector2(25, 25)], "authoritative Edit selection should still receive the exact image pointer")
	_press_viewport(viewport, Vector2(25, 20))
	support.expect_equal(selections, [""], "letterbox clicks should still clear selection outside the Edit pipeline")
	viewport.queue_free()
	await tree.process_frame


func _test_letterbox_selection_and_clamped_drag(support, tree: SceneTree) -> void:
	var viewport := await _mounted_viewport(tree)
	viewport.call("set_record", _record())
	var transform = viewport.call("get_image_transform")
	var selected_ids: Array[String] = []
	var pointer_positions: Array[Vector2] = []
	viewport.region_selected.connect(func(region_id: String): selected_ids.append(region_id))
	viewport.image_pointer_event.connect(func(_event: InputEvent, image_position: Vector2): pointer_positions.append(image_position))

	_press_viewport(viewport, Vector2(25, 20))
	support.expect_equal(selected_ids, [""], "clicking vertical letterbox space should clear selection")
	support.expect_equal(pointer_positions, [], "letterbox clicks must not send invalid image coordinates to Edit")

	_press_viewport(viewport, transform.image_to_viewport(Vector2(180, 100)))
	support.expect_equal(selected_ids, ["", ""], "clicking empty image content should clear selection")
	support.expect(pointer_positions.size() == 1 and pointer_positions[0].distance_to(Vector2(180, 100)) < 0.00001, "empty image content should still send a valid edit pointer")

	_press_viewport(viewport, transform.image_to_viewport(Vector2(25, 25)))
	var outside_motion := InputEventMouseMotion.new()
	outside_motion.position = Vector2(1000, 1000)
	outside_motion.button_mask = MOUSE_BUTTON_MASK_LEFT
	viewport.call("_gui_input", outside_motion)
	var outside_release := InputEventMouseButton.new()
	outside_release.button_index = MOUSE_BUTTON_LEFT
	outside_release.pressed = false
	outside_release.position = Vector2(1000, 1000)
	viewport.call("_gui_input", outside_release)
	support.expect_equal(selected_ids.back(), "box", "a drag beginning inside a region should retain its normal selection event")
	support.expect(pointer_positions[-2].distance_to(Vector2(200, 120)) < 0.00001, "an active drag motion should clamp to the image boundary")
	support.expect(pointer_positions[-1].distance_to(Vector2(200, 120)) < 0.00001, "an active drag release should clamp to the image boundary")

	var pointer_count_before_outside_start := pointer_positions.size()
	_press_viewport(viewport, Vector2(10, 10))
	var inside_motion := InputEventMouseMotion.new()
	inside_motion.position = transform.image_to_viewport(Vector2(25, 25))
	inside_motion.button_mask = MOUSE_BUTTON_MASK_LEFT
	viewport.call("_gui_input", inside_motion)
	var inside_release := InputEventMouseButton.new()
	inside_release.button_index = MOUSE_BUTTON_LEFT
	inside_release.pressed = false
	inside_release.position = transform.image_to_viewport(Vector2(25, 25))
	viewport.call("_gui_input", inside_release)
	support.expect_equal(pointer_positions.size(), pointer_count_before_outside_start, "a drag beginning outside the image should never enter the Edit pipeline")
	viewport.queue_free()
	await tree.process_frame


func _test_reset_view_to_fit(support, tree: SceneTree) -> void:
	var viewport := await _mounted_viewport(tree)
	viewport.call("set_record", _record())
	var transform = viewport.call("get_image_transform")
	transform.zoom_at(Vector2(300, 240), 2.5)
	transform.pan_by(Vector2(35, -17))
	viewport.call("notify_transform_changed")
	var transform_signal_count := [0]
	viewport.transform_changed.connect(func(): transform_signal_count[0] += 1)
	support.expect(viewport.call("reset_view_to_fit"), "viewport Fit should report and apply a changed camera")
	support.expect_equal(transform.user_zoom, 1.0, "viewport Fit should reset zoom")
	support.expect_equal(transform.pan, Vector2.ZERO, "viewport Fit should reset pan")
	support.expect_equal(transform_signal_count[0], 1, "viewport Fit should publish one transform change")
	support.expect(not viewport.call("reset_view_to_fit"), "repeated viewport Fit should be a no-op")
	support.expect_equal(transform_signal_count[0], 1, "no-op viewport Fit should not publish another transform change")
	viewport.queue_free()
	await tree.process_frame


func _test_edit_pointer_boundary_and_order(support, tree: SceneTree) -> void:
	var viewport := await _mounted_viewport(tree)
	viewport.call("set_record", _record())
	var events: Array[String] = []
	var cancellation_count := [0]
	viewport.region_selected.connect(func(_id: String): events.append("selection"))
	viewport.image_pointer_event.connect(func(_event: InputEvent, _point: Vector2): events.append("pointer"))
	viewport.connect("edit_cancel_requested", func(): cancellation_count[0] += 1)
	_click(viewport, Vector2(25, 25))
	support.expect_equal(events, ["selection", "pointer"], "ordinary left press should publish selection before the edit pointer event")

	events.clear()
	var wheel := InputEventMouseButton.new()
	wheel.button_index = MOUSE_BUTTON_WHEEL_UP
	wheel.pressed = true
	wheel.position = Vector2(25, 25)
	viewport.call("_gui_input", wheel)
	var middle := InputEventMouseButton.new()
	middle.button_index = MOUSE_BUTTON_MIDDLE
	middle.pressed = true
	middle.position = Vector2(25, 25)
	viewport.call("_gui_input", middle)
	var pan_motion := InputEventMouseMotion.new()
	pan_motion.position = Vector2(30, 30)
	pan_motion.relative = Vector2(5, 5)
	pan_motion.button_mask = MOUSE_BUTTON_MASK_MIDDLE
	viewport.call("_gui_input", pan_motion)
	middle.pressed = false
	viewport.call("_gui_input", middle)
	support.expect(events.is_empty(), "wheel and middle-button pan events must not reach edit tools")
	viewport.notification(Node.NOTIFICATION_WM_WINDOW_FOCUS_OUT)
	support.expect_equal(cancellation_count[0], 0, "wheel, middle pan, and focus loss preserve transient edit sessions")
	viewport.queue_free()
	await tree.process_frame


func _test_right_click_requests_selection_cancel(support, tree: SceneTree) -> void:
	var viewport := await _mounted_viewport(tree)
	viewport.call("set_record", _record())
	var cancellation_count := [0]
	var selections: Array[String] = []
	var pointers: Array[Vector2] = []
	support.expect(viewport.has_signal("selection_cancel_requested"), "AnnotationViewport should expose a dedicated right-click cancellation signal")
	if viewport.has_signal("selection_cancel_requested"):
		viewport.connect("selection_cancel_requested", func(): cancellation_count[0] += 1)
	viewport.region_selected.connect(func(region_id: String): selections.append(region_id))
	viewport.image_pointer_event.connect(func(_event: InputEvent, point: Vector2): pointers.append(point))
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_RIGHT
	event.pressed = true
	event.position = viewport.call("get_image_transform").image_to_viewport(Vector2(25, 25))
	viewport.call("_gui_input", event)
	event.pressed = false
	viewport.call("_gui_input", event)
	support.expect_equal(cancellation_count[0], 1, "one right-button press should request cancellation exactly once")
	support.expect_equal(selections, [], "right click must not run ordinary hit-test selection")
	support.expect_equal(pointers, [], "right click must not enter a drawing tool's pointer stream")
	viewport.queue_free()
	await tree.process_frame


func _test_wheel_and_pan_controls(support, tree: SceneTree) -> void:
	var viewport := VIEWPORT_SCENE.instantiate() as Control
	viewport.set_anchors_preset(Control.PRESET_TOP_LEFT)
	viewport.size = Vector2(800, 600)
	tree.root.add_child(viewport)
	viewport.call("set_record", _record())
	var transform = viewport.call("get_image_transform")
	var transform_signal_count := [0]
	viewport.connect("transform_changed", func(): transform_signal_count[0] += 1)

	var cursor := Vector2(211, 177)
	var anchored_image_point: Vector2 = transform.viewport_to_image(cursor)
	var wheel := InputEventMouseButton.new()
	wheel.button_index = MOUSE_BUTTON_WHEEL_UP
	wheel.pressed = true
	wheel.position = cursor
	viewport.call("_gui_input", wheel)
	support.expect(transform.user_zoom > 1.0, "mouse wheel should zoom")
	support.expect(transform.image_to_viewport(anchored_image_point).distance_to(cursor) < 0.00001, "wheel zoom should stay anchored beneath the cursor")

	var middle_down := InputEventMouseButton.new()
	middle_down.button_index = MOUSE_BUTTON_MIDDLE
	middle_down.pressed = true
	middle_down.position = Vector2(100, 100)
	viewport.call("_gui_input", middle_down)
	var pan_before: Vector2 = transform.pan
	var middle_drag := InputEventMouseMotion.new()
	middle_drag.position = Vector2(112, 93)
	middle_drag.relative = Vector2(12, -7)
	viewport.call("_gui_input", middle_drag)
	support.expect_equal(transform.pan, pan_before + Vector2(12, -7), "middle-button drag should pan by local mouse delta")
	var middle_up := InputEventMouseButton.new()
	middle_up.button_index = MOUSE_BUTTON_MIDDLE
	middle_up.pressed = false
	viewport.call("_gui_input", middle_up)
	pan_before = transform.pan
	var motion_after_middle_release := InputEventMouseMotion.new()
	motion_after_middle_release.position = Vector2(117, 89)
	motion_after_middle_release.relative = Vector2(5, -4)
	viewport.call("_gui_input", motion_after_middle_release)
	support.expect_equal(transform.pan, pan_before, "releasing the middle button should end pan immediately")

	var space_down := InputEventKey.new()
	space_down.keycode = KEY_SPACE
	space_down.pressed = true
	viewport.call("_gui_input", space_down)
	var left_down := InputEventMouseButton.new()
	left_down.button_index = MOUSE_BUTTON_LEFT
	left_down.pressed = true
	left_down.position = Vector2(100, 100)
	viewport.call("_gui_input", left_down)
	pan_before = transform.pan
	var space_drag := InputEventMouseMotion.new()
	space_drag.position = Vector2(120, 105)
	space_drag.relative = Vector2(8, 5)
	viewport.call("_gui_input", space_drag)
	support.expect_equal(transform.pan, pan_before, "Space plus left drag must not pan the viewport")
	support.expect(transform_signal_count[0] >= 2, "zoom and middle-button pan should emit transform changes")
	viewport.queue_free()
	await tree.process_frame


func _test_focus_out_preserves_non_space_pan_contract(support, tree: SceneTree) -> void:
	var viewport := await _mounted_viewport(tree)
	viewport.call("set_record", _record())
	await tree.process_frame
	var transform = viewport.call("get_image_transform")
	var transform_signal_count := [0]
	var redraw_count := [0]
	viewport.connect("transform_changed", func(): transform_signal_count[0] += 1)
	viewport.draw.connect(func(): redraw_count[0] += 1)

	var space_down := InputEventKey.new()
	space_down.keycode = KEY_SPACE
	space_down.pressed = true
	Input.parse_input_event(space_down)
	await tree.process_frame
	var left_down := InputEventMouseButton.new()
	left_down.button_index = MOUSE_BUTTON_LEFT
	left_down.pressed = true
	left_down.position = Vector2(100, 100)
	viewport.call("_gui_input", left_down)

	viewport.notification(Node.NOTIFICATION_WM_WINDOW_FOCUS_OUT)
	var pan_before: Vector2 = transform.pan
	viewport.call("_gui_input", left_down)
	var ordinary_drag := InputEventMouseMotion.new()
	ordinary_drag.position = Vector2(109, 104)
	ordinary_drag.relative = Vector2(9, 4)
	ordinary_drag.button_mask = MOUSE_BUTTON_MASK_LEFT
	viewport.call("_gui_input", ordinary_drag)
	support.expect_equal(transform.pan, pan_before, "Space must never turn an ordinary left drag into pan, including after focus changes")
	support.expect_equal(transform_signal_count[0], 0, "focus loss without a transform change should not emit transform_changed")
	await tree.process_frame
	support.expect_equal(redraw_count[0], 0, "focus loss without a transform change should not queue redraw")

	var left_up := InputEventMouseButton.new()
	left_up.button_index = MOUSE_BUTTON_LEFT
	left_up.pressed = false
	viewport.call("_gui_input", left_up)
	var space_up := InputEventKey.new()
	space_up.keycode = KEY_SPACE
	space_up.pressed = false
	Input.parse_input_event(space_up)
	await tree.process_frame
	viewport.queue_free()
	await tree.process_frame


func _test_space_in_text_input_never_enables_pan(support, tree: SceneTree) -> void:
	var viewport := await _mounted_viewport(tree)
	viewport.call("set_record", _record())
	var line_edit := LineEdit.new()
	line_edit.position = Vector2(900, 20)
	line_edit.size = Vector2(200, 40)
	tree.root.add_child(line_edit)
	line_edit.grab_focus()
	await tree.process_frame
	support.expect(line_edit.has_focus(), "text input should own keyboard focus before the Space event")

	var space_down := InputEventKey.new()
	space_down.keycode = KEY_SPACE
	space_down.unicode = 32
	space_down.pressed = true
	Input.parse_input_event(space_down)
	await tree.process_frame
	support.expect_equal(line_edit.text, " ", "pre-GUI Space tracking must not prevent the focused LineEdit from consuming the event")
	support.expect(line_edit.has_focus(), "focused LineEdit should retain focus after consuming Space")

	var transform = viewport.call("get_image_transform")
	var pan_before: Vector2 = transform.pan
	var left_down := InputEventMouseButton.new()
	left_down.button_index = MOUSE_BUTTON_LEFT
	left_down.pressed = true
	left_down.position = Vector2(100, 100)
	left_down.global_position = left_down.position
	viewport.call("_gui_input", left_down)
	var drag := InputEventMouseMotion.new()
	drag.position = Vector2(114, 91)
	drag.global_position = drag.position
	drag.relative = Vector2(14, -9)
	drag.button_mask = MOUSE_BUTTON_MASK_LEFT
	viewport.call("_gui_input", drag)
	support.expect_equal(transform.pan, pan_before, "Space typed in a LineEdit must never enable left-button pan")

	var left_up := InputEventMouseButton.new()
	left_up.button_index = MOUSE_BUTTON_LEFT
	left_up.pressed = false
	left_up.position = drag.position
	left_up.global_position = drag.position
	viewport.call("_gui_input", left_up)
	var space_up := InputEventKey.new()
	space_up.keycode = KEY_SPACE
	space_up.unicode = 32
	space_up.pressed = false
	Input.parse_input_event(space_up)
	await tree.process_frame
	pan_before = transform.pan
	viewport.call("_gui_input", left_down)
	viewport.call("_gui_input", drag)
	support.expect_equal(transform.pan, pan_before, "ordinary left drag must remain non-panning after Space release")
	viewport.call("_gui_input", left_up)
	line_edit.release_focus()
	line_edit.queue_free()
	viewport.queue_free()
	await tree.process_frame


func _record() -> Dictionary:
	return {
		"schema_version": 1,
		"dataset_id": "viewport-test",
		"source": "model_output_v1",
		"frame": 0,
		"image_size": [200, 120],
		"regions": [{
			"id": "box",
			"class": "grasper",
			"kind": "instrument",
			"box": [10, 10, 40, 40],
		}],
	}


func _mounted_viewport(tree: SceneTree) -> Control:
	var viewport := VIEWPORT_SCENE.instantiate() as Control
	viewport.set_renderer(RENDERER_SCRIPT.new())
	viewport.set_anchors_preset(Control.PRESET_TOP_LEFT)
	viewport.size = Vector2(800, 600)
	tree.root.add_child(viewport)
	await tree.process_frame
	return viewport


func _click(viewport: Control, image_position: Vector2) -> void:
	var transform = viewport.call("get_image_transform")
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	click.position = transform.image_to_viewport(image_position)
	viewport.call("_gui_input", click)


func _press_viewport(viewport: Control, viewport_position: Vector2) -> void:
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	click.position = viewport_position
	viewport.call("_gui_input", click)
