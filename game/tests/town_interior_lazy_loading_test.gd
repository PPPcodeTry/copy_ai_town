extends SceneTree

const TOWN_BASE := preload("res://world/maps/town/TownBase.gd")
const UNIQUE_INTERIOR_PORTALS := {
	"cafe": "cafe",
	"library": "library",
	"town_hall": "town_hall",
	"clinic": "clinic",
	"market": "market",
	"dining_hall": "dining_hall",
	"workshop": "workshop",
	"dock_warehouse": "dock_warehouse",
	"home_a": "home_01",
	"home_b": "home_02",
}
const MAX_BLOCKING_FRAME_USEC := 25000

var _failures: Array[String] = []
var _checks := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var startup_started := Time.get_ticks_msec()
	var town := TOWN_BASE.new()
	root.add_child(town)
	var startup_msec := Time.get_ticks_msec() - startup_started
	var roots := town.get("_interior_roots") as Dictionary
	var build_queue := town.get_node_or_null("InteriorRoomBuildQueue")
	_expect(
		build_queue != null,
		"Town owns a frame-budgeted interior preparation queue",
	)
	if build_queue != null:
		_expect_equal(
			build_queue.get_frame_budget_usec(),
			8000,
			"interior preparation has an explicit eight-millisecond frame budget",
		)
	_expect_equal(
		roots.size(),
		0,
		"cold Town startup leaves every interior definition uninstantiated",
	)
	_expect_equal(
		_count_exterior_portals(town),
		TOWN_BASE.EXTERIOR_INTERIOR_PORTALS.size(),
		"cold Town startup still creates every lightweight exterior portal",
	)
	var player := town.get_node_or_null("Player") as CharacterBody2D
	_expect(player != null, "cold Town startup still creates the player")
	if player == null:
		await _finish(town, {"startup_msec": startup_msec})
		return
	await process_frame
	await process_frame
	await process_frame
	var cold_static_mib := (
		float(Performance.get_monitor(Performance.MEMORY_STATIC)) / 1048576.0
	)
	var cold_peak_static_mib := (
		float(Performance.get_monitor(Performance.MEMORY_STATIC_MAX)) / 1048576.0
	)
	var cold_room_count := (town.get("_interior_roots") as Dictionary).size()
	var prewarm_longest_frame_usec := 0
	if build_queue != null:
		for _index in 30:
			var frame_started_usec := Time.get_ticks_usec()
			await process_frame
			prewarm_longest_frame_usec = maxi(
				prewarm_longest_frame_usec,
				Time.get_ticks_usec() - frame_started_usec,
			)
			if int(
				(build_queue.get_profile_snapshot() as Dictionary).get(
					"completed_room_count",
					0,
				)
			) >= 1:
				break
		_expect(
			int(
				(build_queue.get_profile_snapshot() as Dictionary).get(
					"completed_room_count",
					0,
				)
			) >= 1,
			"delayed prewarm completes its one nearest room in bounded frames",
		)
	var max_first_entry_msec := 0
	var first_entry_msec := 0
	var controller_checked := false
	for interior_id_value: Variant in UNIQUE_INTERIOR_PORTALS.keys():
		var interior_id := String(interior_id_value)
		var portal_id := String(UNIQUE_INTERIOR_PORTALS[interior_id])
		town.set("_blocked_exterior_reentry_portal_id", "")
		var first_entry_started := Time.get_ticks_msec()
		await town.call("_enter_interior", player, portal_id)
		var entry_msec := Time.get_ticks_msec() - first_entry_started
		if first_entry_msec == 0:
			first_entry_msec = entry_msec
		max_first_entry_msec = maxi(max_first_entry_msec, entry_msec)
		_expect_equal(
			String(town.get("_active_interior_id")),
			interior_id,
			"%s can be entered after lazy construction" % interior_id,
		)
		var room := (town.get("_interior_roots") as Dictionary).get(
			interior_id,
		) as InteriorRoom
		_expect(room != null, "%s is cached after first entry" % interior_id)
		if room == null:
			continue
		_expect(room.visible, "%s is visible while active" % interior_id)
		_expect(
			room.has_wall_occlusion(),
			"%s loads its pre-generated wall occlusion" % interior_id,
		)
		_expect(
			room.has_furniture_runtime(),
			"%s loads its furniture runtime" % interior_id,
		)
		_expect(
			not room.get_navigation_grid_data().is_empty(),
			"%s builds navigation data" % interior_id,
		)
		var wall := room.get_node_or_null("WallCollision") as StaticBody2D
		_expect(
			wall != null and wall.get_child_count() > 0,
			"%s builds wall collisions" % interior_id,
		)
		if not controller_checked:
			var controller := town.get_node_or_null("InteriorOcclusionController")
			_expect(controller != null, "Town owns an event-driven occlusion controller")
			if controller != null:
				controller.set_process(false)
				controller.mark_subject_dirty(
					town.get_node("Player/PlayerOcclusionFootPoint") as Node2D,
				)
				_expect(
					controller.process_pending(),
					"one dirty subject state refreshes active room occlusion",
				)
				var static_refreshes := 0
				for _static_frame in 120:
					if controller.process_pending():
						static_refreshes += 1
				_expect_equal(
					static_refreshes,
					0,
					"120 static frames perform no resident scan or occlusion refresh",
				)
				controller.set_process(true)
			controller_checked = true
		await town.call("_exit_interior", player, interior_id)
		_expect(not room.visible, "%s hides after exit" % interior_id)
		town.set("_blocked_exterior_reentry_portal_id", "")
		await town.call("_enter_interior", player, portal_id)
		_expect(
			(town.get("_interior_roots") as Dictionary).get(interior_id) == room,
			"%s re-entry reuses the cached room" % interior_id,
		)
		await town.call("_exit_interior", player, interior_id)
	_expect_equal(
		(town.get("_interior_roots") as Dictionary).size(),
		UNIQUE_INTERIOR_PORTALS.size(),
		"the regression exercises every unique interior definition",
	)
	await process_frame
	await process_frame
	var all_rooms_static_mib := (
		float(Performance.get_monitor(Performance.MEMORY_STATIC)) / 1048576.0
	)
	var all_rooms_peak_static_mib := (
		float(Performance.get_monitor(Performance.MEMORY_STATIC_MAX)) / 1048576.0
	)
	var build_profile := (
		build_queue.get_profile_snapshot() as Dictionary
		if build_queue != null
		else {}
	)
	var max_room_cpu_usec := 0
	var max_room_wall_usec := 0
	var slowest_stage := ""
	var slowest_stage_usec := 0
	for room_profile_value: Variant in (
		build_profile.get("rooms", {}) as Dictionary
	).values():
		var room_profile := room_profile_value as Dictionary
		max_room_cpu_usec = maxi(
			max_room_cpu_usec,
			int(room_profile.get("cpu_usec", 0)),
		)
		max_room_wall_usec = maxi(
			max_room_wall_usec,
			int(room_profile.get("wall_usec", 0)),
		)
		for stage_name_value: Variant in (
			room_profile.get("stages", {}) as Dictionary
		).keys():
			var stage_name := String(stage_name_value)
			var stage_usec := int(
				(room_profile.get("stages", {}) as Dictionary).get(stage_name, 0),
			)
			if stage_usec > slowest_stage_usec:
				slowest_stage_usec = stage_usec
				slowest_stage = stage_name
	_expect_equal(
		build_profile.get("completed_room_count"),
		UNIQUE_INTERIOR_PORTALS.size(),
		"the build queue completes every unique interior definition",
	)
	_expect(
		prewarm_longest_frame_usec <= MAX_BLOCKING_FRAME_USEC,
		"delayed prewarm keeps the longest observed frame under 25 ms",
	)
	_expect(
		int(build_profile.get("max_frame_work_usec", 0))
		<= MAX_BLOCKING_FRAME_USEC,
		"all room preparation work stays under the blocking-frame ceiling",
	)
	_expect(
		int(build_profile.get("max_stage_usec", 0)) <= MAX_BLOCKING_FRAME_USEC,
		"no individual preparation stage can hide a long synchronous pause",
	)
	await _finish(town, {
		"startup_msec": startup_msec,
		"first_entry_msec": first_entry_msec,
		"max_first_entry_msec": max_first_entry_msec,
		"cold_static_mib": cold_static_mib,
		"cold_peak_static_mib": cold_peak_static_mib,
		"cold_room_count": cold_room_count,
		"prewarm_longest_frame_usec": prewarm_longest_frame_usec,
		"build_max_frame_usec": int(build_profile.get("max_frame_work_usec", 0)),
		"build_max_stage_usec": int(build_profile.get("max_stage_usec", 0)),
		"max_room_cpu_usec": max_room_cpu_usec,
		"max_room_wall_usec": max_room_wall_usec,
		"slowest_stage": slowest_stage,
		"all_rooms_static_mib": all_rooms_static_mib,
		"all_rooms_peak_static_mib": all_rooms_peak_static_mib,
	})


func _count_exterior_portals(town: Node) -> int:
	var count := 0
	for portal_spec in TOWN_BASE.EXTERIOR_INTERIOR_PORTALS:
		if town.get_node_or_null(String(portal_spec.get("node_name", ""))) != null:
			count += 1
	return count


func _expect(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures.append(message)


func _expect_equal(actual: Variant, expected: Variant, message: String) -> void:
	_expect(
		actual == expected,
		"%s: expected %s, got %s" % [message, expected, actual],
	)


func _finish(town: Node, metrics: Dictionary) -> void:
	if is_instance_valid(town):
		town.queue_free()
	await process_frame
	await process_frame
	_prepare_audio_shutdown()
	if _failures.is_empty():
		print(
			"TOWN_INTERIOR_LAZY_LOADING_PASS checks=%d startupMsec=%d prewarmMaxFrameUsec=%d buildMaxFrameUsec=%d buildMaxStageUsec=%d slowestStage=%s maxRoomCpuUsec=%d maxRoomWallUsec=%d firstEntryMsec=%d maxFirstEntryMsec=%d coldRooms=%d coldStaticMiB=%.1f coldPeakStaticMiB=%.1f allRoomsStaticMiB=%.1f allRoomsPeakStaticMiB=%.1f"
			% [
				_checks,
				int(metrics.get("startup_msec", 0)),
				int(metrics.get("prewarm_longest_frame_usec", 0)),
				int(metrics.get("build_max_frame_usec", 0)),
				int(metrics.get("build_max_stage_usec", 0)),
				String(metrics.get("slowest_stage", "")),
				int(metrics.get("max_room_cpu_usec", 0)),
				int(metrics.get("max_room_wall_usec", 0)),
				int(metrics.get("first_entry_msec", 0)),
				int(metrics.get("max_first_entry_msec", 0)),
				int(metrics.get("cold_room_count", 0)),
				float(metrics.get("cold_static_mib", 0.0)),
				float(metrics.get("cold_peak_static_mib", 0.0)),
				float(metrics.get("all_rooms_static_mib", 0.0)),
				float(metrics.get("all_rooms_peak_static_mib", 0.0)),
			]
		)
		call_deferred("_quit_after_cleanup", 0)
		return
	for failure in _failures:
		printerr("TOWN_INTERIOR_LAZY_LOADING_FAIL: %s" % failure)
	call_deferred("_quit_after_cleanup", 1)


func _quit_after_cleanup(exit_code: int) -> void:
	await process_frame
	await process_frame
	await create_timer(0.2).timeout
	quit(exit_code)


func _prepare_audio_shutdown() -> void:
	var audio := root.get_node_or_null("TownAudioController")
	if audio != null and audio.has_method("prepare_shutdown"):
		audio.call("prepare_shutdown")
