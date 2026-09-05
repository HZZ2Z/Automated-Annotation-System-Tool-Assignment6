class_name ClassAssignmentDialog
extends Window

signal assignment_confirmed(class_label: String, kind: String)
signal assignment_cancelled

@onready var _class_label: LineEdit = $Margin/Content/ClassLabel
@onready var _kind: LineEdit = $Margin/Content/Kind
@onready var _color_preview: ColorRect = $Margin/Content/ColorPreview
@onready var _suggestions_tree: Tree = $Margin/Content/Suggestions
@onready var _status: Label = $Margin/Content/Status
@onready var _cancel: Button = $Margin/Content/Actions/Cancel
@onready var _confirm: Button = $Margin/Content/Actions/Confirm

const CLASS_COLOR_RESOLVER := preload("res://client/domain/class_color_resolver.gd")

var _suggestions: Array[Dictionary] = []
var _resolver: Variant = null
var _active := false
var _cancel_emitted := false
var _syncing_fields := false


func _ready() -> void:
	_suggestions_tree.set_column_title(0, "Class")
	_suggestions_tree.set_column_title(1, "Kind")
	_suggestions_tree.column_titles_visible = true
	_suggestions_tree.hide_root = true
	_suggestions_tree.select_mode = Tree.SELECT_ROW
	_class_label.text_changed.connect(_on_field_changed)
	_kind.text_changed.connect(_on_field_changed)
	_class_label.text_submitted.connect(_on_field_submitted)
	_kind.text_submitted.connect(_on_field_submitted)
	_suggestions_tree.item_selected.connect(_on_suggestion_selected)
	_suggestions_tree.gui_input.connect(_on_suggestions_gui_input)
	for control: Control in [_class_label, _kind, _suggestions_tree, _cancel, _confirm]:
		control.gui_input.connect(_on_focused_control_gui_input)
	_cancel.pressed.connect(_cancel_assignment)
	_confirm.pressed.connect(_confirm_assignment)
	close_requested.connect(_cancel_assignment)
	_refresh_validation()


func present(initial_class: String, initial_kind: String, suggestions: Array, resolver: Variant) -> void:
	_resolver = resolver if resolver != null else CLASS_COLOR_RESOLVER.new()
	_suggestions = _copy_suggestions(suggestions)
	_active = true
	_cancel_emitted = false
	exclusive = true
	_status.text = ""
	_syncing_fields = true
	_class_label.text = initial_class.strip_edges()
	_kind.text = initial_kind.strip_edges()
	_syncing_fields = false
	_rebuild_suggestions()
	_refresh_validation()
	show()
	_class_label.grab_focus()
	_class_label.select_all()


func set_error(message: String) -> void:
	_status.text = message


func dismiss_silently() -> void:
	_active = false
	_cancel_emitted = true
	hide()
	exclusive = false


func is_assignment_open() -> bool:
	return _active


func _normalized_fields() -> Dictionary:
	return {
		"class": _class_label.text.strip_edges(),
		"kind": _kind.text.strip_edges(),
	}


func _refresh_validation() -> void:
	if not is_node_ready():
		return
	var values := _normalized_fields()
	_confirm.disabled = String(values["class"]).is_empty() or String(values["kind"]).is_empty()
	if _confirm.disabled:
		_status.text = "Class and kind are required."
	elif _status.text == "Class and kind are required.":
		_status.text = ""
	if _resolver != null and _resolver.has_method("color_for"):
		_color_preview.color = _resolver.color_for(String(values["class"]))
	else:
		_color_preview.color = CLASS_COLOR_RESOLVER.new().color_for(String(values["class"]))


func _copy_suggestions(values: Array) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var seen: Dictionary = {}
	for value: Variant in values:
		if not value is Dictionary:
			continue
		var class_label := String((value as Dictionary).get("class", "")).strip_edges()
		var kind := String((value as Dictionary).get("kind", "")).strip_edges()
		if class_label.is_empty():
			continue
		if not seen.has(class_label):
			seen[class_label] = {}
		var kinds: Dictionary = seen[class_label]
		if kinds.has(kind):
			continue
		kinds[kind] = true
		seen[class_label] = kinds
		result.append({"class": class_label, "kind": kind})
	return result


func _rebuild_suggestions() -> void:
	if not is_node_ready():
		return
	_suggestions_tree.clear()
	var root := _suggestions_tree.create_item()
	var filter := _class_label.text.strip_edges().to_lower()
	for suggestion: Dictionary in _suggestions:
		var class_label := String(suggestion.get("class", ""))
		if not filter.is_empty() and not class_label.to_lower().contains(filter):
			continue
		var item := _suggestions_tree.create_item(root)
		item.set_text(0, class_label)
		item.set_text(1, String(suggestion.get("kind", "")))
	_suggestions_tree.deselect_all()


func _on_field_changed(_value: String) -> void:
	if _syncing_fields:
		return
	_refresh_validation()
	_rebuild_suggestions()


func _on_field_submitted(_value: String) -> void:
	_confirm_assignment()


func _on_suggestion_selected() -> void:
	_apply_selected_suggestion()


func _apply_selected_suggestion() -> void:
	var item := _suggestions_tree.get_selected()
	if item == null:
		return
	_syncing_fields = true
	_class_label.text = item.get_text(0)
	_kind.text = item.get_text(1)
	_syncing_fields = false
	_class_label.caret_column = _class_label.text.length()
	_kind.caret_column = _kind.text.length()
	_refresh_validation()


func _on_suggestions_gui_input(event: InputEvent) -> void:
	if not _active:
		return
	if event is InputEventKey:
		var key_event := event as InputEventKey
		if not key_event.pressed:
			return
		if key_event.keycode == KEY_DOWN or key_event.keycode == KEY_UP:
			_move_selection(1 if key_event.keycode == KEY_DOWN else -1)
			_suggestions_tree.accept_event()
		elif key_event.keycode == KEY_ENTER or key_event.keycode == KEY_KP_ENTER:
			_apply_selected_suggestion()
			_confirm_assignment()
			_suggestions_tree.accept_event()
		return
	if event is InputEventMouseButton:
		var mouse_event := event as InputEventMouseButton
		if mouse_event.pressed and mouse_event.button_index == MOUSE_BUTTON_LEFT and mouse_event.double_click:
			var item := _suggestions_tree.get_item_at_position(mouse_event.position)
			if item != null:
				item.select(0)
				_apply_selected_suggestion()
				_confirm_assignment()
			_suggestions_tree.accept_event()


func _on_focused_control_gui_input(event: InputEvent) -> void:
	if not _active or not event is InputEventKey:
		return
	var key_event := event as InputEventKey
	if not key_event.pressed or key_event.echo or key_event.keycode != KEY_ESCAPE:
		return
	# Focused LineEdit/Tree controls consume Escape before Window's
	# `_unhandled_key_input`.  Route that real GUI event through the same
	# debounced cancellation boundary and stop it before any parent/global path.
	_cancel_assignment()
	get_viewport().set_input_as_handled()


func _move_selection(delta: int) -> void:
	var root := _suggestions_tree.get_root()
	if root == null:
		return
	var items: Array[TreeItem] = []
	var item := root.get_first_child()
	while item != null:
		items.append(item)
		item = item.get_next()
	if items.is_empty():
		return
	var current := _suggestions_tree.get_selected()
	var index := items.find(current)
	if index < 0:
		index = 0 if delta > 0 else items.size() - 1
	else:
		index = clampi(index + delta, 0, items.size() - 1)
	items[index].select(0)
	_apply_selected_suggestion()


func _confirm_assignment() -> void:
	if not _active:
		return
	var values := _normalized_fields()
	var class_label := String(values["class"])
	var kind := String(values["kind"])
	if class_label.is_empty() or kind.is_empty():
		_status.text = "Class and kind are required."
		return
	_active = false
	_cancel_emitted = true
	hide()
	exclusive = false
	assignment_confirmed.emit(class_label, kind)


func _cancel_assignment() -> void:
	if not _active or _cancel_emitted:
		return
	_cancel_emitted = true
	_active = false
	hide()
	exclusive = false
	assignment_cancelled.emit()


func _unhandled_key_input(event: InputEvent) -> void:
	if not _active or not event is InputEventKey:
		return
	var key_event := event as InputEventKey
	if not key_event.pressed:
		return
	if key_event.keycode == KEY_ESCAPE:
		_cancel_assignment()
		get_viewport().set_input_as_handled()
	elif key_event.keycode == KEY_ENTER or key_event.keycode == KEY_KP_ENTER:
		_confirm_assignment()
		get_viewport().set_input_as_handled()
