extends RefCounted


const SCENE_PATH := "res://client/ui/class_assignment_dialog.tscn"
const CLASS_COLOR_RESOLVER := preload("res://client/domain/class_color_resolver.gd")


func run(support: TestSupport, tree: SceneTree) -> void:
	var packed: PackedScene = ResourceLoader.load(SCENE_PATH)
	support.expect(packed != null, "class assignment dialog scene should load")
	if packed == null:
		return
	await _test_present_validation_and_confirm(packed, support, tree)
	await _test_filter_selection_and_deep_copy(packed, support, tree)
	await _test_keyboard_and_double_click(packed, support, tree)
	await _test_cancellation_is_debounced_and_silent_dismissal(packed, support, tree)


func _test_present_validation_and_confirm(packed: PackedScene, support: TestSupport, tree: SceneTree) -> void:
	var dialog := packed.instantiate()
	tree.root.add_child(dialog)
	await tree.process_frame
	var confirmations: Array = []
	var cancellations := [0]
	dialog.assignment_confirmed.connect(func(class_label: String, kind: String): confirmations.append([class_label, kind]))
	dialog.assignment_cancelled.connect(func(): cancellations[0] += 1)
	var resolver := CLASS_COLOR_RESOLVER.new({"classes": [{"id": "grasper", "color": "#ef4444"}]})
	dialog.present("  grasper  ", "  pathology_custom  ", _suggestions(), resolver)
	support.expect_equal(dialog.get_node("Margin/Content/ClassLabel").text, "grasper",
		"present must trim the initial class")
	support.expect_equal(dialog.get_node("Margin/Content/Kind").text, "pathology_custom",
		"kind must remain free-form after trimming")
	support.expect_equal((dialog.get_node("Margin/Content/ColorPreview") as ColorRect).color,
		resolver.color_for("grasper"), "color preview must use the supplied resolver")
	var class_edit := dialog.get_node("Margin/Content/ClassLabel") as LineEdit
	var kind_edit := dialog.get_node("Margin/Content/Kind") as LineEdit
	var confirm := dialog.get_node("Margin/Content/Actions/Confirm") as Button
	class_edit.text = "   "
	class_edit.text_changed.emit(class_edit.text)
	support.expect(confirm.disabled, "blank class must disable confirmation")
	class_edit.text = " new lesion "
	kind_edit.text = " pathology_custom "
	class_edit.text_changed.emit(class_edit.text)
	kind_edit.text_changed.emit(kind_edit.text)
	support.expect(not confirm.disabled, "two trimmed non-empty fields must enable confirmation")
	confirm.pressed.emit()
	support.expect_equal(confirmations, [["new lesion", "pathology_custom"]],
		"confirmation must emit one trimmed free-form pair")
	support.expect_equal(cancellations[0], 0, "confirmation must not emit cancellation")
	support.expect(not dialog.is_assignment_open(), "confirmation must deactivate the modal")
	dialog.present("  lesion  ", "  pathology  ", _suggestions(), resolver)
	dialog.set_error("candidate is stale")
	dialog.present("lesion", "pathology", _suggestions(), resolver)
	support.expect_equal(dialog.get_node("Margin/Content/Status").text, "",
		"present with valid fields must clear a stale error")
	dialog.set_error("candidate is stale")
	dialog.present("   ", "   ", _suggestions(), resolver)
	support.expect_equal(dialog.get_node("Margin/Content/Status").text, "Class and kind are required.",
		"present with blank fields must show only current validation")
	dialog.queue_free()
	await tree.process_frame


func _test_filter_selection_and_deep_copy(packed: PackedScene, support: TestSupport, tree: SceneTree) -> void:
	var dialog := packed.instantiate()
	tree.root.add_child(dialog)
	await tree.process_frame
	var suggestions := _suggestions()
	dialog.present("", "", suggestions, CLASS_COLOR_RESOLVER.new())
	suggestions[0]["class"] = "mutated outside dialog"
	var tree_control := dialog.get_node("Margin/Content/Suggestions") as Tree
	support.expect_equal(tree_control.get_root().get_child(0).get_text(0), "grasper",
		"present must deep-copy suggestions")
	var class_edit := dialog.get_node("Margin/Content/ClassLabel") as LineEdit
	class_edit.text = "SCISS"
	class_edit.text_changed.emit(class_edit.text)
	support.expect_equal(tree_control.get_root().get_child_count(), 1,
		"suggestion filtering must be case-insensitive")
	var item := tree_control.get_root().get_child(0)
	item.select(0)
	tree_control.item_selected.emit()
	support.expect_equal(class_edit.text, "scissors", "selecting a suggestion fills its class")
	support.expect_equal(dialog.get_node("Margin/Content/Kind").text, "instrument",
		"selecting a suggestion fills its last kind")
	dialog.present("", "", [
		{"class": "a|b", "kind": "c"},
		{"class": "a", "kind": "b|c"},
	], CLASS_COLOR_RESOLVER.new())
	support.expect_equal((dialog.get_node("Margin/Content/Suggestions") as Tree).get_root().get_child_count(), 2,
		"suggestion pairs that contain separators must not collide during de-duplication")
	dialog.queue_free()
	await tree.process_frame


func _test_keyboard_and_double_click(packed: PackedScene, support: TestSupport, tree: SceneTree) -> void:
	var dialog := packed.instantiate()
	tree.root.add_child(dialog)
	await tree.process_frame
	var confirmations: Array = []
	dialog.assignment_confirmed.connect(func(class_label: String, kind: String): confirmations.append([class_label, kind]))
	dialog.present("", "", _suggestions(), CLASS_COLOR_RESOLVER.new())
	var tree_control := dialog.get_node("Margin/Content/Suggestions") as Tree
	tree_control.grab_focus()
	var root := tree_control.get_root()
	var first := root.get_child(0)
	first.select(0)
	tree_control.item_selected.emit()
	var down := InputEventKey.new()
	down.keycode = KEY_DOWN
	down.pressed = true
	tree_control.gui_input.emit(down)
	support.expect_equal(tree_control.get_selected().get_text(0), "scissors",
		"Down should move to the next suggestion")
	var up := InputEventKey.new()
	up.keycode = KEY_UP
	up.pressed = true
	tree_control.gui_input.emit(up)
	support.expect_equal(tree_control.get_selected().get_text(0), "grasper",
		"Up should move to the previous suggestion")
	var enter := InputEventKey.new()
	enter.keycode = KEY_ENTER
	enter.pressed = true
	tree_control.gui_input.emit(enter)
	support.expect_equal(confirmations, [["grasper", "instrument"]],
		"Enter should confirm a valid selected suggestion")
	dialog.queue_free()
	await tree.process_frame

	var double_dialog := packed.instantiate()
	tree.root.add_child(double_dialog)
	await tree.process_frame
	var double_confirmations: Array = []
	double_dialog.assignment_confirmed.connect(func(class_label: String, kind: String): double_confirmations.append([class_label, kind]))
	double_dialog.present("", "", _suggestions(), CLASS_COLOR_RESOLVER.new())
	var double_tree := double_dialog.get_node("Margin/Content/Suggestions") as Tree
	var double_item := double_tree.get_root().get_child(1)
	double_item.select(0)
	double_tree.item_selected.emit()
	var double_click := InputEventMouseButton.new()
	double_click.button_index = MOUSE_BUTTON_LEFT
	double_click.double_click = true
	double_click.pressed = true
	double_click.position = double_tree.get_item_area_rect(double_item).get_center()
	double_tree.gui_input.emit(double_click)
	support.expect_equal(double_confirmations, [["scissors", "instrument"]],
		"double-click should fill and confirm the selected suggestion")
	double_dialog.queue_free()
	await tree.process_frame


func _test_cancellation_is_debounced_and_silent_dismissal(packed: PackedScene, support: TestSupport, tree: SceneTree) -> void:
	var dialog := packed.instantiate()
	tree.root.add_child(dialog)
	await tree.process_frame
	var cancellations := [0]
	dialog.assignment_cancelled.connect(func(): cancellations[0] += 1)
	dialog.present("x", "kind", _suggestions(), CLASS_COLOR_RESOLVER.new())
	(dialog.get_node("Margin/Content/Actions/Cancel") as Button).pressed.emit()
	dialog.close_requested.emit()
	support.expect_equal(cancellations[0], 1,
		"Cancel followed by close_requested must emit exactly one cancellation")
	support.expect(not dialog.is_assignment_open(), "cancel must close the assignment")
	dialog.present("x", "kind", _suggestions(), CLASS_COLOR_RESOLVER.new())
	dialog.close_requested.emit()
	support.expect_equal(cancellations[0], 2, "window close must route through the cancellation guard")
	dialog.present("x", "kind", _suggestions(), CLASS_COLOR_RESOLVER.new())
	var class_edit := dialog.get_node("Margin/Content/ClassLabel") as LineEdit
	class_edit.grab_focus()
	await tree.process_frame
	await _push_key(dialog, KEY_ESCAPE, tree)
	support.expect_equal(cancellations[0], 3,
		"focused Class LineEdit Escape must route through the same cancellation guard exactly once")
	support.expect(not dialog.is_assignment_open(),
		"focused Class LineEdit Escape must close the assignment")
	dialog.present("x", "kind", _suggestions(), CLASS_COLOR_RESOLVER.new())
	var kind_edit := dialog.get_node("Margin/Content/Kind") as LineEdit
	kind_edit.grab_focus()
	await tree.process_frame
	await _push_key(dialog, KEY_ESCAPE, tree)
	support.expect_equal(cancellations[0], 4,
		"focused Kind LineEdit Escape must cancel exactly once")
	dialog.present("x", "kind", _suggestions(), CLASS_COLOR_RESOLVER.new())
	var suggestions := dialog.get_node("Margin/Content/Suggestions") as Tree
	suggestions.grab_focus()
	await tree.process_frame
	await _push_key(dialog, KEY_ESCAPE, tree)
	support.expect_equal(cancellations[0], 5,
		"focused Suggestions Escape must cancel exactly once")
	dialog.present("x", "kind", _suggestions(), CLASS_COLOR_RESOLVER.new())
	dialog.dismiss_silently()
	support.expect_equal(cancellations[0], 5, "silent dismissal must not emit cancellation")
	support.expect(not dialog.is_assignment_open(), "silent dismissal must close the assignment")
	dialog.set_error("candidate is stale")
	support.expect_equal(dialog.get_node("Margin/Content/Status").text, "candidate is stale",
		"set_error must update visible status")
	dialog.queue_free()
	await tree.process_frame


func _push_key(viewport: Viewport, keycode: Key, tree: SceneTree) -> void:
	var event := InputEventKey.new()
	event.keycode = keycode
	event.physical_keycode = keycode
	event.pressed = true
	viewport.push_input(event, true)
	await tree.process_frame
	var released := event.duplicate() as InputEventKey
	released.pressed = false
	viewport.push_input(released, true)
	await tree.process_frame


func _suggestions() -> Array:
	return [
		{"class": "grasper", "kind": "instrument"},
		{"class": "scissors", "kind": "instrument"},
		{"class": "lesion", "kind": "pathology"},
	]
