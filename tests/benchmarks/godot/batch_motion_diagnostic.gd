## 构造小目标位移反例；这是算法局限诊断，不是手术视频精度评测。
extends SceneTree

const METRIC := preload("res://client/services/frame_similarity_service.gd")

func _initialize() -> void:
	var images: Array[Image] = []
	var boxes := [Rect2i(100, 100, 20, 20), Rect2i(132, 100, 20, 20)]
	for box: Rect2i in boxes:
		var frame := Image.create(640, 360, false, Image.FORMAT_RGB8)
		frame.fill(Color.BLACK)
		frame.fill_rect(box, Color.WHITE)
		images.append(frame)
	var distance := METRIC.distance(METRIC.grayscale(images[0]), METRIC.grayscale(images[1]))
	var overlap: int = boxes[0].intersection(boxes[1]).get_area()
	var iou := float(overlap) / float(boxes[0].get_area() + boxes[1].get_area() - overlap)
	var result := {"diagnostic": "constructed small-object motion; not surgical accuracy",
		"metric_id": "godot-rgb64-bilinear-mad-v1", "image_size": [640, 360],
		"object_size": [20, 20], "movement_px": 32, "fixed_copy_box_iou": iou,
		"mad": distance, "threshold": 0.02, "accepted_as_similar": distance < 0.02}
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://tests/output"))
	var file := FileAccess.open("res://tests/output/part3_motion_diagnostic.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(result, "  ") + "\n")
	file.close()
	print(JSON.stringify(result))
	quit()
