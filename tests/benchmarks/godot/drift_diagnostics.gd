## 累积漂移机制的构造诊断；不代表真实手术数据精度。
extends SceneTree

const METRIC := preload("res://client/services/frame_similarity_service.gd")

class Source extends RefCounted:
	var frames: Array[Image] = []
	var entries: Array = []
	func get_frame_entry(index: int) -> Dictionary:
		return entries[index].duplicate(true)
	func load_texture(index: int) -> Texture2D:
		return ImageTexture.create_from_image(frames[index])

class Review extends RefCounted:
	func is_verified(_id: int) -> bool:
		return false

func _initialize() -> void:
	var results := {"kind": "constructed diagnostics, not surgical accuracy", "metric": METRIC.METRIC_ID, "threshold": 0.02, "cases": []}
	for mode: String in ["brightness_ramp", "slow_motion", "return_motion"]:
		var source := Source.new()
		var boxes: Array[Rect2i] = []
		var count := 29 if mode == "return_motion" else 40
		for i in range(count):
			var frame := Image.create(640, 360, false, Image.FORMAT_RGB8)
			var offset := mini(i, 28-i) * 2 if mode == "return_motion" else i
			var box := Rect2i(100 + offset, 100, 20, 20)
			boxes.append(box)
			if mode == "brightness_ramp":
				frame.fill(Color(float(i)/255, float(i)/255, float(i)/255))
			else:
				frame.fill(Color.BLACK)
				frame.fill_rect(box, Color.WHITE)
			source.frames.append(frame)
			source.entries.append({"frame": i, "frame_id": i, "time_s": float(i)/30})
		var scanner := METRIC.new()
		scanner.begin(source, Review.new(), source.entries, 0, 0.02)
		while scanner.running:
			scanner.step()
		var rows: Array = []
		for i in range(count):
			var gray := METRIC.grayscale(source.frames[i])
			var adjacent := METRIC.distance(gray, METRIC.grayscale(source.frames[maxi(0,i-1)]))
			var anchor := METRIC.distance(gray, METRIC.grayscale(source.frames[0]))
			var overlap := boxes[0].intersection(boxes[i]).get_area()
			var iou := float(overlap) / float(boxes[0].get_area() + boxes[i].get_area() - overlap)
			rows.append({"frame": i, "anchor": anchor, "adjacent": adjacent,
				"copied_box_iou": null if mode == "brightness_ramp" else iou})
		results.cases.append({"name": mode, "start": scanner.result.start_index, "end": scanner.result.end_index,
			"left_stop": scanner.result.left_stop, "right_stop": scanner.result.right_stop, "rows": rows})
	var file := FileAccess.open("res://tests/output/drift_diagnostics.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(results, "  ") + "\n")
	file.close()
	for result: Dictionary in results.cases:
		print(result.name, ": accepted ", result.start, "..", result.end, "; ", result.right_stop)
	quit()
