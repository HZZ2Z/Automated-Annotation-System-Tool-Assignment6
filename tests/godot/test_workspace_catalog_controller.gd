extends RefCounted

const CONTROLLER_PATH := "res://client/workspace/workspace_catalog_controller.gd"
const TEMP_PREFIX := "/tmp/annotool-workspace-catalog-controller-"


class DiscoveryFactory extends RefCounted:
	var delay_steps := 0
	var ignore_cancel := false

	func _init(steps: int = 0, ignores_cancel: bool = false) -> void:
		delay_steps = steps
		ignore_cancel = ignores_cancel

	func discover_workspace_media(root: String, _preferred: String, token: Variant) -> Dictionary:
		for _index in range(delay_steps):
			if not ignore_cancel and token.is_cancelled():
				return {"claimed": false, "plugin_id": "probe", "media": [],
					"errors": PackedStringArray(["Workspace scan cancelled"])}
			OS.delay_msec(10)
		return {
			"claimed": true,
			"plugin_id": "probe_source",
			"media": [{
				"display_name": root.get_file(),
				"media_id": root.get_file().replace("-", "_"),
				"media_type": "image",
				"source_path": root.path_join("frame.png"),
				"relative_path": "frame.png",
				"source_plugin_id": "probe_source",
			}],
			"errors": PackedStringArray(),
		}

	func resolve_plugin_id(_locator: String, _preferred: String = "") -> String:
		return ""


func run(support, tree: SceneTree) -> void:
	var script := ResourceLoader.load(CONTROLLER_PATH, "Script") as Script
	support.expect(script != null,
		"WorkspaceCatalogController should own background discovery")
	if script == null:
		return
	var first_root := _root("first")
	var second_root := _root("second")
	var third_root := _root("third")
	var controller = script.new()
	tree.root.add_child(controller)

	var first_start: Dictionary = controller.start(first_root, DiscoveryFactory.new())
	support.expect(first_start.get("errors") is PackedStringArray
		and first_start.get("errors").is_empty(),
		"a valid catalog job should start immediately")
	var first: Dictionary = await controller.wait_for(int(first_start.get("generation", -1)))
	support.expect(bool(first.get("success", false)),
		"the first catalog candidate should complete")
	support.expect_equal(controller.get_catalog().get_root(), first_root,
		"a successful current generation should become the controller catalog")

	var slow_start: Dictionary = controller.start(second_root, DiscoveryFactory.new(30))
	var slow_generation := int(slow_start.get("generation", -1))
	var heartbeats := 0
	while heartbeats < 5:
		await tree.process_frame
		heartbeats += 1
	support.expect(controller.is_busy() and heartbeats == 5,
		"slow discovery should leave the SceneTree responsive")
	controller.cancel()
	var cancelled: Dictionary = await controller.wait_for(slow_generation)
	support.expect(bool(cancelled.get("cancelled", false))
		or "cancel" in " ".join(cancelled.get("errors", [])).to_lower(),
		"cooperative cancellation should be reported for its own generation")
	support.expect_equal(controller.get_catalog().get_root(), first_root,
		"cancelled discovery must preserve the previously published catalog")

	var stale_start: Dictionary = controller.start(second_root,
		DiscoveryFactory.new(20, true))
	await tree.process_frame
	var latest_start: Dictionary = controller.start(third_root, DiscoveryFactory.new())
	var latest: Dictionary = await controller.wait_for(int(latest_start.get("generation", -1)))
	support.expect(bool(latest.get("success", false)) and not bool(latest.get("stale", false)),
		"queued latest discovery should succeed after an uncooperative stale worker")
	support.expect_equal(controller.get_catalog().get_root(), third_root,
		"generation N must never replace the newer generation N+1")
	var stale: Dictionary = await controller.wait_for(int(stale_start.get("generation", -1)))
	support.expect(bool(stale.get("stale", false)),
		"the superseded completion should remain readable as stale evidence")

	await controller.cancel_and_drain()
	controller.queue_free()
	await tree.process_frame
	_remove_tree(first_root)
	_remove_tree(second_root)
	_remove_tree(third_root)


func _root(label: String) -> String:
	var path := "%s%s-%d-%d" % [
		TEMP_PREFIX, label, OS.get_process_id(), Time.get_ticks_usec()]
	DirAccess.make_dir_recursive_absolute(path)
	var image := Image.create(2, 2, false, Image.FORMAT_RGBA8)
	image.fill(Color.WHITE)
	image.save_png(path.path_join("frame.png"))
	return path


func _remove_tree(path: String) -> void:
	var directory := DirAccess.open(path)
	if directory == null:
		return
	for file_name: String in directory.get_files():
		DirAccess.remove_absolute(path.path_join(file_name))
	DirAccess.remove_absolute(path)
