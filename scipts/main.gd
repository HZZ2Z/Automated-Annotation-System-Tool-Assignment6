extends Control

@onready var open_button: Button = $MainVBox/TopToolbar/Open
@onready var file_dialog: FileDialog = $OpenFileDialog
@onready var image_view: TextureRect = $MainVBox/Workspace/MainSplit/CenterPanel/AnnotationCanvas/ImageView


func _ready() -> void:
	open_button.pressed.connect(_on_open_pressed)
	file_dialog.file_selected.connect(_on_file_selected)


func _on_open_pressed() -> void:
	file_dialog.popup_centered_ratio(0.8)


func _on_file_selected(path: String) -> void:
	var image := Image.new()
	var err := image.load(path)

	if err != OK:
		print("Failed to load image: ", path)
		return

	image_view.texture = ImageTexture.create_from_image(image)

	print("Loaded: ", path)
	print("Size: ", image.get_width(), " x ", image.get_height())
