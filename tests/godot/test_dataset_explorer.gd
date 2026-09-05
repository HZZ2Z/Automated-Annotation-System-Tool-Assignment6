extends RefCounted

const SCENE := preload("res://client/ui/dataset_explorer.tscn")


func run(support, tree: SceneTree) -> void:
	var explorer = SCENE.instantiate()
	tree.root.add_child(explorer)
	await tree.process_frame

	support.expect(_find_item(explorer, "No dataset open") != null,
		"DatasetExplorer should expose an explicit empty state")

	var requested: Array[int] = []
	var rejected: Array[String] = []
	explorer.frame_requested.connect(func(index: int) -> void: requested.append(index))
	explorer.view_model_rejected.connect(func(message: String) -> void: rejected.append(message))
	var model := {
		"display_name": "sample_case",
		"source_path": "/tmp/sample_case",
		"frames": [
			{"index": 0, "label": "frames/frame_000000.png",
				"path": "/tmp/sample_case/frames/frame_000000.png"},
			{"index": 1, "label": "frames/frame_000001.png",
				"path": "/tmp/sample_case/frames/frame_000001.png"},
		],
		"artifacts": [
			{"label": "manifest.json", "path": "/tmp/sample_case/manifest.json"},
		],
	}
	explorer.populate(model)

	support.expect(_find_item(explorer, "sample_case") != null,
		"DatasetExplorer should show the active dataset")
	support.expect(_find_item(explorer, "Frames (2)") != null,
		"DatasetExplorer should show the accepted frame count")
	support.expect(_find_item(explorer, "frames/frame_000000.png") != null,
		"DatasetExplorer should show the first manifest path")
	support.expect(_find_item(explorer, "manifest.json") != null,
		"DatasetExplorer should show real metadata artifacts")

	support.expect(explorer.select_frame(1), "a valid frame should be selectable")
	support.expect_equal(requested, [], "programmatic selection must not emit navigation")
	support.expect_equal(_selected_frame(explorer), 1,
		"programmatic selection should update the highlight")
	support.expect(not explorer.select_frame(7), "an unknown frame should be refused")
	support.expect_equal(_selected_frame(explorer), 1,
		"a refused selection should preserve the highlight")

	var first_item := _find_item(explorer, "frames/frame_000000.png")
	(first_item as TreeItem).select(0)
	await tree.process_frame
	support.expect_equal(requested, [0], "a user frame selection should emit exactly once")

	explorer.populate({"display_name": "broken"})
	support.expect_equal(rejected.size(), 1, "an invalid model should emit one rejection")
	support.expect(rejected[0].length() <= 180,
		"view-model rejection should remain bounded")
	support.expect(_find_item(explorer, "sample_case") != null,
		"an invalid model should preserve the previous tree")

	var long_frames: Array[Dictionary] = []
	for index in range(10000):
		long_frames.append({
			"index": index,
			"label": "frames/frame_%06d.png" % index,
			"path": "/tmp/long/frames/frame_%06d.png" % index,
		})
	explorer.populate({
		"display_name": "long_case",
		"source_path": "/tmp/long",
		"frames": long_frames,
		"artifacts": [{"label": "manifest.json", "path": "/tmp/long/manifest.json"}],
	})
	support.expect(_find_item(explorer, "Frames (10000)") != null,
		"long sources should retain an exact frame-count summary")
	support.expect(_tree_item_count(explorer) <= 8,
		"a 10000-frame source must not create one TreeItem per frame")
	support.expect(explorer.select_frame(9999),
		"summary mode should accept an exact valid frame index")
	support.expect(_find_item(explorer, "Current: frames/frame_009999.png") != null,
		"summary mode should expose the exact current frame")
	support.expect_equal(_selected_frame(explorer), 9999,
		"summary-mode selection metadata should match the current frame")
	var bounded_count := _tree_item_count(explorer)
	support.expect(not explorer.select_frame(10000),
		"summary mode should reject an out-of-range frame")
	support.expect_equal(_tree_item_count(explorer), bounded_count,
		"summary navigation should keep materialization bounded")

	var requested_media: Array[String] = []
	explorer.media_requested.connect(
		func(media_id: String) -> void: requested_media.append(media_id))
	explorer.populate_workspace({
		"kind": "workspace",
		"display_name": "case_root",
		"root_path": "/tmp/case_root",
		"media": [
			{
				"display_name": "still.png",
				"media_id": "still",
				"media_type": "image",
				"source_path": "/tmp/case_root/patient/still.png",
				"relative_path": "patient/still.png",
			},
			{
				"display_name": "VID68",
				"media_id": "VID68",
				"media_type": "image_sequence",
				"source_path": "/tmp/case_root/videos/VID68",
				"relative_path": "videos/VID68",
			},
		],
	})
	support.expect(_find_item(explorer, "case_root") != null,
		"workspace root should be shown")
	support.expect(_find_item(explorer, "patient") != null
		and _find_item(explorer, "videos") != null,
		"real nested directories should be shown")
	support.expect(_find_item(explorer, "VID68") != null,
		"image sequence should be one selectable media leaf")
	support.expect(_find_item(explorer, "Frames (2)") == null,
		"workspace tree must not materialize video frames")
	support.expect(explorer.select_media("VID68"),
		"programmatic media selection should update the highlight")
	support.expect_equal(requested_media, [],
		"programmatic media selection must not request opening")
	var still_item := _find_item(explorer, "still.png")
	(still_item as TreeItem).select(0)
	await tree.process_frame
	support.expect_equal(requested_media, ["still"],
		"user media selection should emit exactly one stable media ID")
	var workspace_before: Dictionary = explorer.get("_view_model").duplicate(true)
	explorer.populate_workspace({"kind": "workspace", "display_name": "broken"})
	support.expect_equal(explorer.get("_view_model"), workspace_before,
		"invalid workspace view should preserve the previous tree")

	explorer.clear()
	support.expect(_find_item(explorer, "No dataset open") != null,
		"clear should restore the explicit empty state")
	explorer.queue_free()
	await tree.process_frame


func _find_item(explorer: Node, text: String) -> TreeItem:
	var tree := explorer.get_node("Tree") as Tree
	var root := tree.get_root()
	return _find_in_branch(root, text) if root != null else null


func _find_in_branch(item: TreeItem, text: String) -> TreeItem:
	if item.get_text(0) == text:
		return item
	var child := item.get_first_child()
	while child != null:
		var match := _find_in_branch(child, text)
		if match != null:
			return match
		child = child.get_next()
	return null


func _selected_frame(explorer: Node) -> int:
	var tree := explorer.get_node("Tree") as Tree
	var item := tree.get_selected()
	if item == null:
		return -1
	var value: Variant = item.get_metadata(0)
	return int(value) if typeof(value) == TYPE_INT else -1


func _tree_item_count(explorer: Node) -> int:
	var tree := explorer.get_node("Tree") as Tree
	var root := tree.get_root()
	return _branch_count(root) if root != null else 0


func _branch_count(item: TreeItem) -> int:
	var count := 1
	var child := item.get_first_child()
	while child != null:
		count += _branch_count(child)
		child = child.get_next()
	return count
