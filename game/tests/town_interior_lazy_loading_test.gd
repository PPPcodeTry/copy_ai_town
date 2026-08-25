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
		await _finish(town, startup_msec, 0, 0, 0.0, 0.0, 0)
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
	var max_first_entry_msec := 0
	var first_entry_msec := 0
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
	await _finish(
		town,
		startup_msec,
		first_entry_msec,
		max_first_entry_msec,
		cold_static_mib,
		cold_peak_static_mib,
		cold_room_count,
	)


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


func _finish(
	town: Node,
	startup_msec: int,
	first_entry_msec: int,
	max_first_entry_msec: int,
	cold_static_mib: float,
	cold_peak_static_mib: float,
	cold_room_count: int,
) -> void:
	if is_instance_valid(town):
		town.queue_free()
	await process_frame
	await process_frame
	_prepare_audio_shutdown()
	if _failures.is_empty():
		print(
			"TOWN_INTERIOR_LAZY_LOADING_PASS checks=%d startupMsec=%d firstEntryMsec=%d maxFirstEntryMsec=%d coldRooms=%d coldStaticMiB=%.1f coldPeakStaticMiB=%.1f"
			% [
				_checks,
				startup_msec,
				first_entry_msec,
				max_first_entry_msec,
				cold_room_count,
				cold_static_mib,
				cold_peak_static_mib,
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
