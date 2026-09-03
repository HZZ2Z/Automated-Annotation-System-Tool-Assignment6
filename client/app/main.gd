extends Control

const PLUGIN_REGISTRY_SCRIPT := preload("res://client/pipeline/plugin_registry.gd")

@onready var open_button: Button = $MainVBox/TopToolbar/Open
@onready var file_dialog: FileDialog = $OpenFileDialog
@onready var image_view: TextureRect = $MainVBox/Workspace/MainSplit/CenterPanel/AnnotationCanvas/ImageView
@onready var status_bar: Label = $MainVBox/StatusBar
var _plugin_registry = PLUGIN_REGISTRY_SCRIPT.new()


func _ready() -> void:
	open_button.pressed.connect(_on_open_pressed)
	file_dialog.file_selected.connect(_on_file_selected)
	var plugin_errors: PackedStringArray = _plugin_registry.discover("res://client/plugins")
	if not plugin_errors.is_empty():
		status_bar.text = "Plugin discovery: %d issue(s)" % plugin_errors.size()


func get_discovered_plugin(stage: String, plugin_id: String) -> RefCounted:
	return _plugin_registry.get_plugin(stage, plugin_id)


func _on_open_pressed() -> void:
	file_dialog.popup_centered_ratio(0.8)


func _on_file_selected(path: String) -> void:
	load_image_preview(path)


func load_image_preview(path: String) -> Error:
	var image := Image.new()
	var err := image.load(path)

	if err != OK:
		status_bar.text = "Cannot load image: %s" % path.get_file()
		return err

	image_view.texture = ImageTexture.create_from_image(image)
	status_bar.text = "Loaded: %s (%d x %d)" % [path.get_file(), image.get_width(), image.get_height()]
	return OK
