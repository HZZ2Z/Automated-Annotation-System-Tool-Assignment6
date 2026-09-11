extends RefCounted

func run(support) -> void:
	_test_sam_v3(support)
	_test_sam_playback_state(support)
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
	var records := {
		0: {"regions": [{"id":"poly", "polygon":[[0,0],[2,0],[2,2]]}]}, 1: {}, 2: {}
	}
	var edge := {"attempted": 2, "accepted": 1, "fallback": 1, "items": [
		{"frame_id": 1, "region_id": "poly", "accepted": true, "reason": "accepted", "raw_edge_score": 0.2, "refined_edge_score": 0.3},
		{"frame_id": 2, "region_id": "poly", "accepted": false, "reason": "edge gain below 0.01", "raw_edge_score": 0.2, "refined_edge_score": 0.2},
	]}
	var v2 := {"schema_version": 2, "type": "range_propagate", "mode": "merge", "keyframe": 0,
		"start_frame": 0, "end_frame": 2, "affected_frames": [1,2], "metric_id": "poly-sim-flow-edge-v1",
		"threshold": 0.02, "max_frames": 30, "keyframe_digest": "a".repeat(64),
		"created_at": "2026-09-07T01:02:03", "start_index": 0, "end_index": 2,
		"left_stop": "source boundary", "right_stop": "source boundary", "changed_count": 2,
		"covered_count": 3, "edge_refinement": edge}
	support.expect_equal(validator.validate_workflow_state({}, [v2], records), PackedStringArray(), "complete Poly v2 audit accepted")
	var sampled_records := {5850: records[0], 5875: records[1]}
	var sampled: Dictionary = v2.duplicate(true)
	sampled.merge({"keyframe": 5850, "start_frame": 5850, "end_frame": 5875,
		"affected_frames": [5875], "start_index": 0, "end_index": 1,
		"changed_count": 1, "covered_count": 2, "frame_step": 25}, true)
	sampled.edge_refinement = {"attempted": 1, "accepted": 1, "fallback": 0, "items": [
		{"frame_id": 5875, "region_id": "poly", "accepted": true, "reason": "accepted", "raw_edge_score": 0.2, "refined_edge_score": 0.3},
	]}
	support.expect_equal(validator.validate_workflow_state({}, [sampled], sampled_records), PackedStringArray(), "sampled Poly v2 audit accepts declared frame step")
	for invalid_step: Variant in [0, 1.5, 24]:
		var invalid_sampled: Dictionary = sampled.duplicate(true)
		invalid_sampled.frame_step = invalid_step
		support.expect(not validator.validate_workflow_state({}, [invalid_sampled], sampled_records).is_empty(), "reject invalid sampled frame_step %s" % str(invalid_step))
	var off_grid_records := {5850: records[0], 5860: records[1], 5900: records[2]}
	var off_grid: Dictionary = sampled.duplicate(true)
	off_grid.merge({"end_frame": 5900, "affected_frames": [5860, 5900], "end_index": 2,
		"changed_count": 2, "covered_count": 3}, true)
	off_grid.edge_refinement = {"attempted": 2, "accepted": 2, "fallback": 0, "items": [
		{"frame_id": 5860, "region_id": "poly", "accepted": true, "reason": "accepted", "raw_edge_score": 0.2, "refined_edge_score": 0.3},
		{"frame_id": 5900, "region_id": "poly", "accepted": true, "reason": "accepted", "raw_edge_score": 0.2, "refined_edge_score": 0.3},
	]}
	support.expect(not validator.validate_workflow_state({}, [off_grid], off_grid_records).is_empty(), "sampled audit rejects an off-grid middle frame")
	for mutation: String in ["extra", "nan", "duplicate", "counts", "reason", "frame"]:
		var invalid: Dictionary = v2.duplicate(true)
		if mutation == "extra": invalid["unexpected"] = true
		elif mutation == "nan": invalid.edge_refinement.items[0].raw_edge_score = NAN
		elif mutation == "duplicate": invalid.edge_refinement.items.append(invalid.edge_refinement.items[0].duplicate(true))
		elif mutation == "counts": invalid.edge_refinement.accepted = 2
		elif mutation == "reason": invalid.edge_refinement.items[0].reason = "x".repeat(161)
		else: invalid.edge_refinement.items[0].frame_id = 0
		support.expect(not validator.validate_workflow_state({}, [invalid], records).is_empty(), "reject v2 edge audit %s" % mutation)

func _sam_marker() -> Dictionary:
	return {"schema_version": 3, "type": "range_propagate", "mode": "merge", "provider_id": "sam_video",
		"metric_id": "sam-video-v1", "keyframe": 11825, "keyframe_playback_index": 0,
		"keyframe_digest": "a".repeat(64), "region_id": "r", "direction": "forward",
		"requested_count": 2, "generated_count": 2, "start_frame": 11825, "end_frame": 11875,
		"affected_frames": [11850,11875], "target_playback_indices": [1,2],
		"stop_frame": null, "stop_reason": "", "checkpoint_sha256": "b".repeat(64), "device": "cpu",
		"model_version": "1.1.0", "elapsed_ms": 20, "risk_summary": [{"frame_id":11850,"kinds":["sparse_input"]}],
		"created_at": "2026-09-11T01:02:03"}

func _test_sam_v3(s) -> void:
	var validator = load("res://client/domain/annotation_store.gd")
	var frames := {11825: {}, 11850: {}, 11875: {}, 11900: {}}
	var entries := [{"frame":0,"frame_id":11825},{"frame":1,"frame_id":11850},{"frame":2,"frame_id":11875},{"frame":3,"frame_id":11900}]
	var complete := _sam_marker()
	s.expect_equal(validator.validate_workflow_state({}, [complete], frames, entries), PackedStringArray(), "complete SAM v3 audit accepted")
	var truncated := complete.duplicate(true)
	truncated.merge({"requested_count":3,"stop_frame":11900,"stop_reason":"model_topology"}, true)
	s.expect_equal(validator.validate_workflow_state({}, [truncated], frames, entries), PackedStringArray(), "truncated SAM accepted prefix is valid")
	var boundary := complete.duplicate(true)
	boundary.merge({"requested_count":3,"stop_reason":"source_end"}, true)
	s.expect_equal(validator.validate_workflow_state({}, [boundary], {11825:{},11850:{},11875:{}}, entries.slice(0,3)), PackedStringArray(), "Source boundary has no nonexistent stop frame")
	for field in complete:
		var missing := complete.duplicate(true)
		missing.erase(field)
		s.expect(not validator.validate_workflow_state({}, [missing], frames, entries).is_empty(), "SAM requires " + field)
	for pair in [["unexpected",true],["provider_id","polygon_flow"],["metric_id","other"],["direction","backward"],
		["mode","overwrite"],["requested_count",0],["requested_count",31],["generated_count",1],["generated_count",0],
		["keyframe",11850],["keyframe_playback_index",1],["start_frame",11850],["end_frame",11900],
		["affected_frames",[11875,11850]],["affected_frames",[11825,11875]],["affected_frames",[11850,11900]],
		["target_playback_indices",[2,1]],["target_playback_indices",[1,3]],["target_playback_indices",[1]],
		["stop_frame",11850],["stop_frame",11900],["stop_reason","model_topology"],
		["region_id","x".repeat(129)],["region_id","/tmp/token"],["region_id","r\nsecret"],
		["elapsed_ms",NAN],["elapsed_ms",INF],["elapsed_ms",-1],["elapsed_ms",0.1],["elapsed_ms",9007199254740992.0],
		["device","auto"],["device","cuda:0"],["checkpoint_sha256","bad"],["checkpoint_sha256","b".repeat(64)+"\n"],["model_version",""] ,
		["model_version","1.1.0\n"],["created_at","2026-09-11T01:02:03\n"],
		["model_version","/home/wang/model"],["model_version","x".repeat(65)],["created_at","yesterday"],
		["risk_summary",[{"frame_id":11850,"kinds":["score"]}]],
		["risk_summary",[{"frame_id":11825,"kinds":["sparse_input"]}]],
		["risk_summary",[{"frame_id":11850,"kinds":["sparse_input"],"score":0.9}]],
		["risk_summary",[{"frame_id":11850,"kinds":["sparse_input","sparse_input"]}]],
		["risk_summary",[{"frame_id":11850,"kinds":[]}]]]:
		var invalid := complete.duplicate(true)
		invalid[pair[0]] = pair[1]
		s.expect(not validator.validate_workflow_state({}, [invalid], frames, entries).is_empty(), "SAM rejects invalid %s=%s" % [pair[0],str(pair[1])])
	for pair in [["stop_frame",11875],["stop_frame",null],["stop_frame",12000],["stop_reason",""] ,
		["stop_reason","/tmp/mask.png"],["stop_reason","x".repeat(161)]]:
		var invalid := truncated.duplicate(true)
		invalid[pair[0]] = pair[1]
		s.expect(not validator.validate_workflow_state({}, [invalid], frames, entries).is_empty(), "SAM truncated stop rejects " + str(pair))
	var too_many := complete.duplicate(true)
	too_many.risk_summary = []
	for index in range(31): too_many.risk_summary.append({"frame_id":11850,"kinds":["sparse_input"]})
	s.expect(not validator.validate_workflow_state({}, [too_many], frames, entries).is_empty(), "SAM rejects more than 30 risk items")
	for invalid_entries in [null, [], {}, entries.slice(0,3),
		[{"frame":0,"frame_id":11825},{"frame":1,"frame_id":11850},{"frame":2,"frame_id":11850},{"frame":3,"frame_id":11900}],
		[{"frame":0,"frame_id":11825},{"frame":1,"frame_id":11850},{"frame":3,"frame_id":11875},{"frame":2,"frame_id":11900}],
		[{"frame":0,"frame_id":11825},{"frame":1,"frame_id":11850},{"frame":2,"frame_id":11875},{"frame":3,"frame_id":99999}]]:
		s.expect(not validator.validate_workflow_state({},[complete],frames,invalid_entries).is_empty(),"SAM rejects missing or untrustworthy playback mapping")

func _test_sam_playback_state(s) -> void:
	var store = load("res://client/domain/annotation_store.gd").new()
	var records := []
	for frame in [90,12,77,5]: records.append({"schema_version":1,"source":"test","frame":frame,"regions":[]})
	s.expect_equal(store.load_model_records(records),PackedStringArray(),"nonmonotonic marker fixture loads")
	var marker := _sam_marker()
	marker.merge({"keyframe":90,"requested_count":3,"generated_count":3,"start_frame":90,"end_frame":5,
		"affected_frames":[12,77,5],"target_playback_indices":[1,2,3],"risk_summary":[]},true)
	var sorted_forgery := marker.duplicate(true)
	sorted_forgery.merge({"keyframe":5,"start_frame":5,"end_frame":90,"affected_frames":[12,77,90]},true)
	s.expect(not store.load_workflow_state({},[sorted_forgery]).is_empty(),"SAM refuses a v3 marker without trusted session entries")
	var context := {"session_id":"playback-validation","media_id":"clip","media_type":"video","source_relative_path":"clip.mp4","source":"test",
		"source_sha256":null,"round_id":"initial","model_revision":"fixture","taxonomy_version":"v1","baseline_kind":"model",
		"frame_entries":[{"frame":0,"frame_id":90},{"frame":1,"frame_id":12},{"frame":2,"frame_id":77},{"frame":3,"frame_id":5}]}
	s.expect_equal(store.configure_session(context),PackedStringArray(),"nonmonotonic Source context validates")
	s.expect_equal(store.load_workflow_state({},[marker]),PackedStringArray(),"v3 accepts actual nonmonotonic playback order")
	var before: Dictionary = store.freeze_snapshot()
	s.expect(not store.load_workflow_state({},[sorted_forgery]).is_empty(),"v3 refuses numerically sorted order against actual playback")
	s.expect_equal(store.freeze_snapshot(),before,"wrong playback validation does not mutate Store")
