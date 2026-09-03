class_name InspectorPanel
extends VBoxContainer


signal relabel_requested(region_id: String, class_label: String)
signal delete_requested(region_id: String)
signal fill_requested(region_id: String, filled: bool)
signal geometry_requested(region_id: String, box: Array)
signal track_id_requested(region_id: String, track_id: Variant)

@onready var _region_id: LineEdit = $Fields/RegionId
@onready var _class_taxonomy: OptionButton = $Fields/ClassTaxonomy
@onready var _class_free_text: LineEdit = $Fields/ClassFreeText
@onready var _kind: LineEdit = $Fields/Kind
@onready var _confidence: LineEdit = $Fields/Confidence
@onready var _track_id: LineEdit = $Fields/TrackId
@onready var _box_x: SpinBox = $Fields/BoxX
@onready var _box_y: SpinBox = $Fields/BoxY
@onready var _box_width: SpinBox = $Fields/BoxWidth
@onready var _box_height: SpinBox = $Fields/BoxHeight
@onready var _fill: CheckButton = $Fields/Fill
@onready var _delete: Button = $Fields/Delete
@onready var _status: Label = $Status

var _snapshot: Dictionary = {}
var _taxonomy: Dictionary = {}
var _syncing := false


func _ready() -> void:
	_class_taxonomy.item_selected.connect(_on_class_selected)
	_class_free_text.text_submitted.connect(_on_class_submitted)
	_track_id.text_submitted.connect(_on_track_submitted)
	_fill.toggled.connect(_on_fill_toggled)
	_delete.pressed.connect(_on_delete_pressed)
	for spin_box: SpinBox in [_box_x, _box_y, _box_width, _box_height]:
		spin_box.value_changed.connect(_on_geometry_changed)
	_sync_empty()


func set_taxonomy(taxonomy: Dictionary) -> void:
	_taxonomy = taxonomy.duplicate(true)
	_sync_taxonomy_options()


func populate(region: Dictionary, taxonomy: Variant = null) -> void:
	if taxonomy is Dictionary:
		_taxonomy = taxonomy.duplicate(true)
	_snapshot = region.duplicate(true)
	_syncing = true
	_sync_taxonomy_options()
	if _snapshot.is_empty():
		_sync_empty_fields()
		_syncing = false
		_sync_empty()
		return
	var validation_errors := PackedStringArray()
	var id_value: Variant = _snapshot.get("id")
	var class_value: Variant = _snapshot.get("class")
	var kind_value: Variant = _snapshot.get("kind")
	if typeof(id_value) != TYPE_STRING or String(id_value).is_empty():
		validation_errors.append("Region ID must be a non-empty string")
	if typeof(class_value) != TYPE_STRING or String(class_value).is_empty():
		validation_errors.append("Class must be a non-empty string")
	if typeof(kind_value) != TYPE_STRING or String(kind_value).is_empty():
		validation_errors.append("Kind must be a non-empty string")
	_region_id.text = id_value if typeof(id_value) == TYPE_STRING else ""
	_class_free_text.text = class_value if typeof(class_value) == TYPE_STRING else ""
	_kind.text = kind_value if typeof(kind_value) == TYPE_STRING else ""
	var confidence_value: Variant = _snapshot.get("conf")
	if _snapshot.has("conf") and not _is_number(confidence_value):
		validation_errors.append("Confidence must be a finite number")
	_confidence.text = "%.2f" % float(confidence_value) if _is_number(confidence_value) else ""
	var track_value: Variant = _snapshot.get("track_id")
	if _snapshot.has("track_id") and track_value != null and typeof(track_value) != TYPE_STRING:
		validation_errors.append("Track ID must be a string or null")
	_track_id.text = track_value if typeof(track_value) == TYPE_STRING else ""
	var fill_value: Variant = _snapshot.get("filled", false)
	if typeof(fill_value) != TYPE_BOOL:
		validation_errors.append("Filled must be a boolean")
		fill_value = false
	_fill.button_pressed = fill_value
	var box: Variant = _snapshot.get("box")
	var has_box := _snapshot.has("box")
	var has_polygon := _snapshot.has("polygon")
	var is_box := has_box and _valid_box(box)
	if has_box and not is_box:
		validation_errors.append("Box must contain four finite values with positive size")
	if has_polygon and not _snapshot.get("polygon") is Array:
		validation_errors.append("Polygon must be an array")
	if has_box == has_polygon:
		validation_errors.append("Region must contain exactly one geometry")
	if is_box:
		_box_x.value = float(box[0])
		_box_y.value = float(box[1])
		_box_width.value = float(box[2])
		_box_height.value = float(box[3])
	else:
		_box_x.value = 0.0
		_box_y.value = 0.0
		_box_width.value = 0.0
		_box_height.value = 0.0
	_select_current_class()
	_set_controls_enabled(typeof(id_value) == TYPE_STRING and not String(id_value).is_empty(), is_box)
	_status.text = "; ".join(validation_errors)
	_syncing = false


func get_region_snapshot() -> Dictionary:
	return _snapshot.duplicate(true)


func set_status(message: String) -> void:
	_status.text = message


func _sync_taxonomy_options() -> void:
	if not is_node_ready():
		return
	var was_syncing := _syncing
	_syncing = true
	_class_taxonomy.clear()
	var classes: Variant = _taxonomy.get("classes", [])
	if classes is Array:
		for value: Variant in classes:
			if value is Dictionary:
				var class_id: Variant = value.get("id")
				if typeof(class_id) == TYPE_STRING and not String(class_id).is_empty():
					_class_taxonomy.add_item(class_id)
	_select_current_class()
	_syncing = was_syncing


func _select_current_class() -> void:
	if _class_taxonomy == null:
		return
	var current := str(_snapshot.get("class", ""))
	_class_taxonomy.select(-1)
	for index in range(_class_taxonomy.item_count):
		if _class_taxonomy.get_item_text(index) == current:
			_class_taxonomy.select(index)
			return


func _sync_empty() -> void:
	if not is_node_ready():
		return
	_syncing = true
	_sync_empty_fields()
	_set_controls_enabled(false, false)
	_status.text = "Select a region to inspect"
	_syncing = false


func _sync_empty_fields() -> void:
	_region_id.text = ""
	_class_free_text.text = ""
	_kind.text = ""
	_confidence.text = ""
	_track_id.text = ""
	_fill.button_pressed = false
	for spin_box: SpinBox in [_box_x, _box_y, _box_width, _box_height]:
		spin_box.value = 0.0


func _set_controls_enabled(has_region: bool, is_box: bool) -> void:
	_class_taxonomy.disabled = not has_region
	_class_free_text.editable = has_region
	_track_id.editable = has_region
	_fill.disabled = not has_region
	_delete.disabled = not has_region
	for spin_box: SpinBox in [_box_x, _box_y, _box_width, _box_height]:
		spin_box.editable = has_region and is_box


func _on_class_selected(index: int) -> void:
	if _syncing or _snapshot.is_empty() or index < 0 or index >= _class_taxonomy.item_count:
		return
	var class_label := _class_taxonomy.get_item_text(index)
	_class_free_text.text = class_label
	_status.text = ""
	relabel_requested.emit(str(_snapshot.get("id", "")), class_label)


func _on_class_submitted(class_label: String) -> void:
	if _syncing or _snapshot.is_empty():
		return
	if class_label.is_empty():
		_status.text = "Class must be a non-empty string"
		return
	_status.text = ""
	relabel_requested.emit(str(_snapshot.get("id", "")), class_label)


func _on_track_submitted(value: String) -> void:
	if _syncing or _snapshot.is_empty():
		return
	_status.text = ""
	track_id_requested.emit(str(_snapshot.get("id", "")), null if value.is_empty() else value)


func _on_fill_toggled(filled: bool) -> void:
	if _syncing or _snapshot.is_empty():
		return
	_status.text = ""
	fill_requested.emit(str(_snapshot.get("id", "")), filled)


func _on_geometry_changed(_value: float) -> void:
	if _syncing or _snapshot.is_empty() or not _box_width.editable:
		return
	var box := [_box_x.value, _box_y.value, _box_width.value, _box_height.value]
	if box[2] <= 0.0 or box[3] <= 0.0:
		_status.text = "Box width and height must be positive"
		return
	_status.text = ""
	geometry_requested.emit(str(_snapshot.get("id", "")), box.duplicate(true))


func _on_delete_pressed() -> void:
	if _syncing or _snapshot.is_empty():
		return
	_status.text = ""
	delete_requested.emit(str(_snapshot.get("id", "")))


func _is_number(value: Variant) -> bool:
	return (typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT) and is_finite(float(value))


func _valid_box(value: Variant) -> bool:
	if not value is Array or value.size() != 4:
		return false
	for coordinate: Variant in value:
		if not _is_number(coordinate):
			return false
	return float(value[0]) >= 0.0 and float(value[1]) >= 0.0 and float(value[2]) > 0.0 and float(value[3]) > 0.0
