extends SceneTree

const TOWN_BASE := preload("res://world/maps/town/TownBase.gd")
const ROOM_SCENE := preload(
	"res://world/maps/town/interiors/InteriorRoom.tscn"
)
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


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	match OS.get_environment("AI_TOWN_INTERIOR_PERF_MODE"):
		"room_build":
			await _probe_direct_room_build()
		"entry_memory":
			await _probe_entry_and_memory()
		_:
			await _probe_startup_and_prewarm()
	_prepare_audio_shutdown()
	call_deferred("_quit_after_cleanup")


func _probe_startup_and_prewarm() -> void:
	var started_usec := Time.get_ticks_usec()
	var town := TOWN_BASE.new()
	root.add_child(town)
	var startup_usec := Time.get_ticks_usec() - started_usec
	var initial_rooms := (town.get("_interior_roots") as Dictionary).size()
	var longest_delayed_frame_usec := 0
	for _index in 60:
		var frame_started_usec := Time.get_ticks_usec()
		await process_frame
		longest_delayed_frame_usec = maxi(
			longest_delayed_frame_usec,
			Time.get_ticks_usec() - frame_started_usec,
		)
	var queue := town.get_node_or_null("InteriorRoomBuildQueue")
	var queue_profile := (
		queue.get_profile_snapshot() as Dictionary if queue != null else {}
	)
	print(
		"ISSUE141_PERF_STARTUP syncColdUsec=%d initialRooms=%d delayedRooms=%d delayedLongestFrameUsec=%d queueMaxFrameUsec=%d queueMaxStageUsec=%d staticMiB=%.1f peakStaticMiB=%.1f"
		% [
			startup_usec,
			initial_rooms,
			(town.get("_interior_roots") as Dictionary).size(),
			longest_delayed_frame_usec,
			int(queue_profile.get("max_frame_work_usec", 0)),
			int(queue_profile.get("max_stage_usec", 0)),
			_static_mib(),
			_peak_static_mib(),
		]
	)
	town.queue_free()
	await process_frame
	await process_frame


func _probe_direct_room_build() -> void:
	var total_usec := 0
	var max_room_usec := 0
	var built_rooms := 0
	for interior_id_value: Variant in TOWN_BASE.INTERIOR_DEFINITIONS.keys():
		var definition := (
			TOWN_BASE.INTERIOR_DEFINITIONS.get(interior_id_value) as Dictionary
		)
		var room := ROOM_SCENE.instantiate() as InteriorRoom
		var started_usec := Time.get_ticks_usec()
		room.configure(
			String(definition.get("shell_path", "")),
			definition.get("entry_point", Vector2.ZERO) as Vector2,
			definition.get("exit_point", Vector2.ZERO) as Vector2,
			String(definition.get("geometry_path", "")),
			String(definition.get("occlusion_path", "")),
			String(definition.get("furniture_manifest_path", "")),
			String(definition.get("layout_path", "")),
		)
		var elapsed_usec := Time.get_ticks_usec() - started_usec
		total_usec += elapsed_usec
		max_room_usec = maxi(max_room_usec, elapsed_usec)
		if room.has_wall_occlusion() and room.has_furniture_runtime():
			built_rooms += 1
		room.free()
	print(
		"ISSUE141_PERF_ROOM_BUILD rooms=%d totalUsec=%d maxRoomUsec=%d staticMiB=%.1f peakStaticMiB=%.1f"
		% [built_rooms, total_usec, max_room_usec, _static_mib(), _peak_static_mib()]
	)
	await process_frame


func _probe_entry_and_memory() -> void:
	var town := TOWN_BASE.new()
	root.add_child(town)
	for _index in 60:
		await process_frame
	var player := town.get_node("Player") as CharacterBody2D
	var first_entry_started_usec := Time.get_ticks_usec()
	await town.call("_enter_interior", player, "cafe")
	var first_entry_usec := Time.get_ticks_usec() - first_entry_started_usec
	if String(town.get("_active_interior_id")) == "cafe":
		await town.call("_exit_interior", player, "cafe")
	for interior_id_value: Variant in UNIQUE_INTERIOR_PORTALS.keys():
		var interior_id := String(interior_id_value)
		var portal_id := String(UNIQUE_INTERIOR_PORTALS.get(interior_id))
		town.set("_blocked_exterior_reentry_portal_id", "")
		await town.call("_enter_interior", player, portal_id)
		if String(town.get("_active_interior_id")) == interior_id:
			await town.call("_exit_interior", player, interior_id)
	for _index in 10:
		await process_frame
	var queue := town.get_node_or_null("InteriorRoomBuildQueue")
	var queue_profile := (
		queue.get_profile_snapshot() as Dictionary if queue != null else {}
	)
	var max_room_cpu_usec := 0
	var max_room_wall_usec := 0
	for profile_value: Variant in (
		queue_profile.get("rooms", {}) as Dictionary
	).values():
		var profile := profile_value as Dictionary
		max_room_cpu_usec = maxi(
			max_room_cpu_usec,
			int(profile.get("cpu_usec", 0)),
		)
		max_room_wall_usec = maxi(
			max_room_wall_usec,
			int(profile.get("wall_usec", 0)),
		)
	print(
		"ISSUE141_PERF_ENTRY firstCompleteEntryUsec=%d rooms=%d queueMaxRoomCpuUsec=%d queueMaxRoomWallUsec=%d staticMiB=%.1f peakStaticMiB=%.1f"
		% [
			first_entry_usec,
			(town.get("_interior_roots") as Dictionary).size(),
			max_room_cpu_usec,
			max_room_wall_usec,
			_static_mib(),
			_peak_static_mib(),
		]
	)
	town.queue_free()
	await process_frame
	await process_frame


func _static_mib() -> float:
	return float(Performance.get_monitor(Performance.MEMORY_STATIC)) / 1048576.0


func _peak_static_mib() -> float:
	return float(Performance.get_monitor(Performance.MEMORY_STATIC_MAX)) / 1048576.0


func _quit_after_cleanup() -> void:
	await process_frame
	await process_frame
	await create_timer(0.2).timeout
	quit(0)


func _prepare_audio_shutdown() -> void:
	var audio := root.get_node_or_null("TownAudioController")
	if audio != null and audio.has_method("prepare_shutdown"):
		audio.call("prepare_shutdown")
