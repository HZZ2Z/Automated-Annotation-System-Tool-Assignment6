extends RefCounted

const EDIT_OVERLAY := preload("res://client/ui/edit_overlay.gd")
const TRANSFORM := preload("res://client/services/viewport_transform.gd")


func run(support, tree: SceneTree) -> void:
	await _test_mouse_transparency_state_isolation_and_transform_redraw(support, tree)
	await _test_raw_mask_texture_cache_changes_only_with_mask(support, tree)
	await _test_model_prompt_draw_commands_and_candidate_layers(support, tree)


func _test_mouse_transparency_state_isolation_and_transform_redraw(support, tree: SceneTree) -> void:
	var overlay := EDIT_OVERLAY.new() as Control
	overlay.size = Vector2(320, 240)
	var transform = _configured_transform()
	var caller_state := _drawing_state()
	overlay.call("set_state", caller_state, transform)
	caller_state["path"][0] = Vector2(99, 99)
	tree.root.add_child(overlay)
	await tree.process_frame
	support.expect_equal(overlay.mouse_filter, Control.MOUSE_FILTER_IGNORE, "EditOverlay never intercepts viewport input")
	support.expect_equal(overlay.call("get_state_snapshot")["path"][0], Vector2(2, 3), "EditOverlay isolates caller-owned transient state")

	var redraw_count := [0]
	overlay.draw.connect(func(): redraw_count[0] += 1)
	transform.pan_by(Vector2(14, -6))
	overlay.call("set_transform", transform)
	await tree.process_frame
	support.expect(redraw_count[0] > 0, "set_transform refreshes child drawing after camera movement")
	support.expect_equal(overlay.call("get_state_snapshot")["path"], PackedVector2Array([Vector2(2, 3), Vector2(12, 9)]), "camera movement never rewrites image-space overlay points")
	overlay.queue_free()
	await tree.process_frame


func _test_raw_mask_texture_cache_changes_only_with_mask(support, tree: SceneTree) -> void:
	var overlay := EDIT_OVERLAY.new() as Control
	overlay.size = Vector2(320, 240)
	tree.root.add_child(overlay)
	var transform = _configured_transform()
	var state := _working_mask_state()
	overlay.call("set_state", state, transform)
	await tree.process_frame
	var first_builds: int = overlay.call("get_mask_texture_build_count")
	support.expect_equal(first_builds, 1, "first bounded raw mask builds one overlay texture")
	support.expect_equal(overlay.call("get_state_snapshot")["mask_preview"], state["mask_preview"], "EditOverlay preserves the raw ROI and mask snapshot")
	var mask_texture: ImageTexture = overlay.get("_mask_texture")
	var alpha_image := mask_texture.get_image() if mask_texture != null else null
	support.expect(alpha_image != null, "0/1 raw mask produces a cache image")
	if alpha_image != null:
		support.expect_equal(alpha_image.get_pixel(0, 0).a, 1.0, "nonzero mask byte 1 becomes fully opaque in the cache image")
		support.expect_equal(alpha_image.get_pixel(1, 0).a, 0.0, "zero mask byte remains transparent in the cache image")
		support.expect_equal(alpha_image.get_pixel(2, 0).a, 1.0, "first disconnected component remains visible")
		support.expect_equal(alpha_image.get_pixel(1, 1).a, 1.0, "second disconnected component remains visible without polygon conversion")
		support.expect_equal(alpha_image.get_pixel(0, 1).a, 0.0, "raw-mask hole remains transparent")

	state["cursor"] = Vector2(11, 12)
	overlay.call("set_state", state, transform)
	await tree.process_frame
	support.expect_equal(overlay.call("get_mask_texture_build_count"), first_builds, "cursor-only state updates reuse the bounded mask texture")

	state["mask_preview"] = {
		"roi": Rect2i(5, 7, 3, 2),
		"mask": PackedByteArray([255, 0, 0, 255, 0, 255]),
	}
	overlay.call("set_state", state, transform)
	await tree.process_frame
	support.expect_equal(overlay.call("get_mask_texture_build_count"), first_builds + 1, "a changed raw mask snapshot rebuilds the bounded texture exactly once")
	overlay.queue_free()
	await tree.process_frame


func _test_model_prompt_draw_commands_and_candidate_layers(support, tree: SceneTree) -> void:
	var overlay := EDIT_OVERLAY.new() as Control
	overlay.size = Vector2(320, 240)
	tree.root.add_child(overlay)
	var transform = _configured_transform()
	var mask := PackedByteArray()
	mask.resize(20)
	mask.fill(1)
	var caller_state := {
		"phase": &"candidate",
		"positive_points": PackedVector2Array([Vector2(10, 12)]),
		"negative_points": PackedVector2Array([Vector2(20, 22)]),
		"prompt_box": Rect2(8, 9, 30, 20),
		"candidate_polygon": PackedVector2Array([Vector2(9, 10), Vector2(39, 10), Vector2(35, 31), Vector2(10, 30)]),
		"mask_preview": {"roi": Rect2i(10, 12, 5, 4), "mask": mask},
		"message": "candidate",
		"fill_color": Color("#22c55e"),
	}
	overlay.set_state(caller_state, transform)
	caller_state.positive_points[0] = Vector2.ZERO
	caller_state.prompt_box = Rect2()
	caller_state.mask_preview.mask[0] = 0
	await tree.process_frame
	var commands: Array = overlay.get_prompt_draw_commands()
	support.expect_equal(commands.size(), 3, "positive, negative, and box prompts each produce one bounded draw command")
	support.expect_equal(commands[0].kind, &"prompt_point", "positive prompt uses the point command")
	support.expect(commands[0].positive and commands[0].glyph == "+" and commands[0].color == Color("#22c55e"), "positive prompt is a green plus")
	support.expect_equal(commands[0].center, transform.image_to_viewport(Vector2(10, 12)), "positive prompt transforms from image space only during draw")
	support.expect(not commands[1].positive and commands[1].glyph == "-" and commands[1].color == Color("#ef4444"), "negative prompt is a red minus")
	support.expect_equal(commands[2].kind, &"prompt_box", "Ctrl-drag prompt uses the box command")
	support.expect(commands[2].dashed and commands[2].color == Color("#22d3ee"), "prompt box is cyan and dashed")
	support.expect_equal(commands[2].rect.position, transform.image_to_viewport(Vector2(8, 9)), "prompt box origin transforms from image space")
	support.expect_equal(commands[2].rect.end, transform.image_to_viewport(Vector2(38, 29)), "prompt box end transforms from image space")
	var frozen: Dictionary = overlay.get_state_snapshot()
	support.expect_equal(frozen.positive_points[0], Vector2(10, 12), "overlay owns prompt point copies")
	support.expect_equal(frozen.prompt_box, Rect2(8, 9, 30, 20), "overlay owns the prompt box value")
	support.expect_equal(frozen.mask_preview.mask[0], 1, "candidate mask remains a defensive preview")
	support.expect_equal(frozen.candidate_polygon.size(), 4, "candidate polygon remains present beside prompt commands")
	commands[0].center = Vector2.ZERO
	support.expect_equal(overlay.get_prompt_draw_commands()[0].center, transform.image_to_viewport(Vector2(10, 12)), "draw-command inspection is defensive")
	overlay.queue_free()
	await tree.process_frame


func _configured_transform():
	var transform = TRANSFORM.new()
	transform.configure(Vector2(100, 80), Rect2(0, 0, 320, 240))
	return transform


func _drawing_state() -> Dictionary:
	return {
		"phase": &"drawing",
		"path": PackedVector2Array([Vector2(2, 3), Vector2(12, 9)]),
		"candidate_polygon": PackedVector2Array(),
		"mask_preview": {},
		"cursor": Vector2(12, 9),
		"brush_radius": 4.0,
		"message": "",
		"fill_color": Color.TRANSPARENT,
	}


func _working_mask_state() -> Dictionary:
	return {
		"phase": &"working_mask",
		"path": PackedVector2Array(),
		"candidate_polygon": PackedVector2Array(),
		"mask_preview": {
			"roi": Rect2i(5, 7, 3, 2),
			"mask": PackedByteArray([1, 0, 1, 0, 1, 0]),
		},
		"cursor": Vector2.ZERO,
		"brush_radius": 0.0,
		"message": "Repair before commit",
		"fill_color": Color.TRANSPARENT,
	}
