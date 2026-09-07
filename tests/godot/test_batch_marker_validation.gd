extends RefCounted

func run(support) -> void:
	var validator = load("res://client/domain/annotation_store.gd")
	var frames := {0: {}, 1: {}, 2: {}}
	var legacy := {"schema_version": 1, "type": "range_propagate", "mode": "overwrite", "keyframe": 0, "start_frame": 1, "end_frame": 2, "affected_frames": [1, 2]}
	support.expect_equal(validator.validate_workflow_state({}, [legacy], frames), PackedStringArray(), "legacy marker remains readable")
	var full := legacy.duplicate(true)
	full.merge({"start_frame": 0, "metric_id": "gray_mad", "threshold": 0.02, "max_frames": 30, "keyframe_digest": "a".repeat(64), "created_at": "2026-09-07T01:02:03", "start_index": 0, "end_index": 2, "changed_count": 2, "covered_count": 3, "left_stop": "boundary", "right_stop": "boundary"}, true)
	support.expect_equal(validator.validate_workflow_state({}, [full], frames), PackedStringArray(), "complete UI audit accepted")
	for pair: Array in [["metric_id", ""], ["threshold", NAN], ["threshold", 0], ["threshold", 2], ["max_frames", 0], ["max_frames", 1.5], ["keyframe_digest", "bad"], ["created_at", "yesterday"], ["start_frame", 2], ["affected_frames", [0, 1]], ["end_frame", 1], ["changed_count", 9], ["covered_count", 9]]:
		var invalid := full.duplicate(true)
		invalid[pair[0]] = pair[1]
		support.expect(not validator.validate_workflow_state({}, [invalid], frames).is_empty(), "reject invalid audit %s=%s" % [pair[0], str(pair[1])])
	for field: String in ["threshold", "max_frames", "keyframe_digest", "created_at", "start_index", "end_index", "left_stop", "right_stop", "changed_count", "covered_count"]:
		var invalid := full.duplicate(true)
		invalid.erase(field)
		support.expect(not validator.validate_workflow_state({}, [invalid], frames).is_empty(), "metric marker requires %s" % field)
