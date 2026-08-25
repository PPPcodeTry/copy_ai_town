# 正式地图的通用室内壳。
# 具体底图、入口点和出口点由 TownBase.gd 的室内配置注入。
class_name InteriorRoom
extends Node2D

const FLOOR_PROFILES := preload("res://world/maps/town/interiors/InteriorFloorProfiles.gd")
const ROOM_GEOMETRY := preload("res://world/maps/town/interiors/InteriorRoomGeometry.gd")
const WALL_OCCLUSION_SCRIPT := preload("res://world/maps/town/interiors/InteriorWallOcclusion.gd")
const FURNITURE_RUNTIME_SCRIPT := preload(
	"res://world/maps/town/interiors/InteriorFurnitureRuntime.gd"
)
const GEOMETRY_LOAD_TASK := preload(
	"res://world/maps/town/interiors/InteriorGeometryLoadTask.gd"
)
const PREPARATION_WORK_ITEM_RESERVE_USEC := 500
const MAX_PREPARATION_WORK_ITEMS := 16
enum PreparationStage {
	IDLE,
	SHELL_REQUEST,
	SHELL_WAIT,
	GEOMETRY_REQUEST,
	GEOMETRY_WAIT,
	GEOMETRY_APPLY,
	COLLISION,
	NAVIGATION,
	NAVIGATION_LOOKUP,
	OCCLUSION_BEGIN,
	OCCLUSION_SEGMENT,
	FURNITURE_BEGIN,
	FURNITURE_INSTANCE,
	FURNITURE_NAVIGATION,
	FURNITURE_NAVIGATION_LOOKUP,
	COMPLETE,
	FAILED,
}

var _floor_profile_id := ""
var _geometry_path := ""
var _occlusion_path := ""
var _geometry_data: Dictionary = {}
var _navigation_grid_data: Dictionary = {}
var _base_navigation_grid_data: Dictionary = {}
var _walkable_cell_lookup := {}
var _geometry_debug_visible := false
var _wall_occlusion: InteriorWallOcclusion
var _furniture_manifest_path := ""
var _furniture_layout_path := ""
var _furniture_runtime: InteriorFurnitureRuntime
var _preparation_stage := PreparationStage.IDLE
var _preparation_config: Dictionary = {}
var _preparation_error := ""


func configure(
	shell_path: String,
	entry_point: Vector2,
	exit_point: Vector2,
	geometry_path: String = "",
	occlusion_path: String = "",
	furniture_manifest_path: String = "",
	furniture_layout_path: String = ""
) -> void:
	if not begin_preparation(
		shell_path,
		entry_point,
		exit_point,
		geometry_path,
		occlusion_path,
		furniture_manifest_path,
		furniture_layout_path,
	):
		return
	while not is_preparation_complete() and not has_preparation_failed():
		prepare_next_stage()


func begin_preparation(
	shell_path: String,
	entry_point: Vector2,
	exit_point: Vector2,
	geometry_path: String = "",
	occlusion_path: String = "",
	furniture_manifest_path: String = "",
	furniture_layout_path: String = "",
	threaded_shell_load: bool = false,
) -> bool:
	if _preparation_stage != PreparationStage.IDLE:
		return false
	_preparation_config = {
		"shell_path": shell_path,
		"entry_point": entry_point,
		"exit_point": exit_point,
		"geometry_path": geometry_path,
		"occlusion_path": occlusion_path,
		"furniture_manifest_path": furniture_manifest_path,
		"furniture_layout_path": furniture_layout_path,
		"threaded_shell_load": threaded_shell_load,
	}
	_preparation_error = ""
	_preparation_stage = PreparationStage.SHELL_REQUEST
	return true


func prepare_next_stage(remaining_budget_usec: int = 8000) -> Dictionary:
	if is_preparation_complete() or has_preparation_failed():
		return _preparation_result("idle", 0)
	var started_usec := Time.get_ticks_usec()
	var stage_name := "unknown"
	var work_item_limit := clampi(
		remaining_budget_usec / PREPARATION_WORK_ITEM_RESERVE_USEC,
		1,
		MAX_PREPARATION_WORK_ITEMS,
	)
	var work_items := 1
	match _preparation_stage:
		PreparationStage.SHELL_REQUEST:
			stage_name = "shell_request"
			_prepare_shell_request()
		PreparationStage.SHELL_WAIT:
			stage_name = "shell_wait"
			_prepare_shell_wait()
			if _preparation_stage == PreparationStage.SHELL_WAIT:
				work_items = 0
		PreparationStage.GEOMETRY_REQUEST:
			stage_name = "geometry_request"
			_prepare_geometry_request()
		PreparationStage.GEOMETRY_WAIT:
			stage_name = "geometry_wait"
			_prepare_geometry_wait()
			if _preparation_stage == PreparationStage.GEOMETRY_WAIT:
				work_items = 0
		PreparationStage.GEOMETRY_APPLY:
			stage_name = "geometry_apply"
			_apply_geometry()
		PreparationStage.COLLISION:
			stage_name = "collision"
			work_items = _prepare_wall_collision(work_item_limit)
		PreparationStage.NAVIGATION:
			stage_name = "navigation"
			work_items = _prepare_navigation(work_item_limit)
		PreparationStage.NAVIGATION_LOOKUP:
			stage_name = "navigation_lookup"
			work_items = _continue_navigation_lookup(work_item_limit)
		PreparationStage.OCCLUSION_BEGIN:
			stage_name = "occlusion_begin"
			_prepare_occlusion_begin()
		PreparationStage.OCCLUSION_SEGMENT:
			stage_name = "occlusion_segment"
			_prepare_occlusion_segment()
		PreparationStage.FURNITURE_BEGIN:
			stage_name = "furniture_begin"
			_prepare_furniture_begin()
		PreparationStage.FURNITURE_INSTANCE:
			stage_name = "furniture_instance"
			_prepare_furniture_instance()
		PreparationStage.FURNITURE_NAVIGATION:
			stage_name = "furniture_navigation"
			work_items = _prepare_furniture_navigation(work_item_limit)
		PreparationStage.FURNITURE_NAVIGATION_LOOKUP:
			stage_name = "furniture_navigation_lookup"
			work_items = _continue_navigation_lookup(work_item_limit)
	var elapsed_usec := Time.get_ticks_usec() - started_usec
	return _preparation_result(
		stage_name,
		elapsed_usec,
		work_items,
		work_item_limit,
	)


func is_preparation_complete() -> bool:
	return _preparation_stage == PreparationStage.COMPLETE


func has_preparation_failed() -> bool:
	return _preparation_stage == PreparationStage.FAILED


func get_preparation_error() -> String:
	return _preparation_error


func _prepare_shell_request() -> void:
	var shell := get_node("RoomShell") as Sprite2D
	var shell_path := String(_preparation_config.get("shell_path"))
	if bool(_preparation_config.get("threaded_shell_load", false)):
		if (
			not ResourceLoader.exists(shell_path, "Texture2D")
			or ResourceLoader.load_threaded_request(
				shell_path,
				"Texture2D",
				true,
			) != OK
		):
			_fail_preparation("Interior shell could not be queued: %s" % shell_path)
			return
		_preparation_stage = PreparationStage.SHELL_WAIT
		return
	shell.texture = _load_texture(shell_path)
	if shell.texture == null:
		_fail_preparation("Interior shell is missing: %s" % shell_path)
		return
	_preparation_stage = PreparationStage.GEOMETRY_REQUEST


func _prepare_shell_wait() -> void:
	var shell_path := String(_preparation_config.get("shell_path"))
	var status := ResourceLoader.load_threaded_get_status(shell_path)
	if status == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
		return
	if status != ResourceLoader.THREAD_LOAD_LOADED:
		_fail_preparation("Interior shell threaded load failed: %s" % shell_path)
		return
	var shell := get_node("RoomShell") as Sprite2D
	shell.texture = ResourceLoader.load_threaded_get(shell_path) as Texture2D
	if shell.texture == null:
		_fail_preparation("Interior shell is missing: %s" % shell_path)
		return
	_preparation_stage = PreparationStage.GEOMETRY_REQUEST


func _prepare_geometry_request() -> void:
	_geometry_path = String(_preparation_config.get("geometry_path"))
	if (
		bool(_preparation_config.get("threaded_shell_load", false))
		and not _geometry_path.is_empty()
	):
		var task := GEOMETRY_LOAD_TASK.new() as InteriorGeometryLoadTask
		_preparation_config["geometry_task"] = task
		_preparation_config["geometry_task_id"] = WorkerThreadPool.add_task(
			task.run.bind(_geometry_path),
			false,
			"Load interior geometry",
		)
		_preparation_stage = PreparationStage.GEOMETRY_WAIT
		return
	_geometry_data = ROOM_GEOMETRY.load_geometry(_geometry_path)
	_preparation_stage = PreparationStage.GEOMETRY_APPLY

func _prepare_geometry_wait() -> void:
	var task_id := int(_preparation_config.get("geometry_task_id", -1))
	if task_id < 0:
		_fail_preparation("Interior room geometry task is missing")
		return
	if not WorkerThreadPool.is_task_completed(task_id):
		return
	WorkerThreadPool.wait_for_task_completion(task_id)
	var task := (
		_preparation_config.get("geometry_task") as InteriorGeometryLoadTask
	)
	_geometry_data = task.take_result()
	_preparation_config.erase("geometry_task_id")
	_preparation_config.erase("geometry_task")
	_preparation_stage = PreparationStage.GEOMETRY_APPLY


func _apply_geometry() -> void:
	var shell := get_node("RoomShell") as Sprite2D
	var shell_path := String(_preparation_config.get("shell_path"))
	var entry_point := _preparation_config.get("entry_point") as Vector2
	var exit_point := _preparation_config.get("exit_point") as Vector2
	shell.position = Vector2.ZERO
	if not _geometry_path.is_empty() and _geometry_data.is_empty():
		_fail_preparation("Interior room geometry is missing: %s" % _geometry_path)
		return
	if not _geometry_data.is_empty():
		var setup := ROOM_GEOMETRY.room_setup_from_loaded_geometry(
			_geometry_data,
		) as Dictionary
		shell.position = setup.get("shell_position") as Vector2
		entry_point = setup.get("entry_point") as Vector2
		exit_point = setup.get("exit_point") as Vector2
	(get_node("IndoorEntryPoint") as Marker2D).position = entry_point
	(get_node("IndoorExitPoint") as Marker2D).position = exit_point
	if not _geometry_data.is_empty():
		_floor_profile_id = str(_geometry_data.get("room_id", ""))
	else:
		_floor_profile_id = FLOOR_PROFILES.profile_id_from_shell_path(shell_path)
		if not FLOOR_PROFILES.has_profile(_floor_profile_id):
			_fail_preparation(
				"Interior floor profile is missing: %s" % _floor_profile_id,
			)
			return
	_preparation_config["entry_point"] = entry_point
	_preparation_config["exit_point"] = exit_point
	_preparation_stage = PreparationStage.COLLISION


func _prepare_navigation(max_work_items: int) -> int:
	var entry_point := _preparation_config.get("entry_point") as Vector2
	var exit_point := _preparation_config.get("exit_point") as Vector2
	if not _geometry_data.is_empty():
		if not _preparation_config.has("navigation_scan"):
			_preparation_config["navigation_scan"] = (
				ROOM_GEOMETRY.begin_navigation_grid_scan(
					_geometry_data,
					entry_point,
					exit_point,
				)
			)
		var result := ROOM_GEOMETRY.continue_navigation_grid_scan(
			_preparation_config.get("navigation_scan") as Dictionary,
			max_work_items,
		) as Dictionary
		if result.get("complete") != true:
			return int(result.get("processed", 0))
		_preparation_config.erase("navigation_scan")
		if result.get("failed") == true:
			_fail_preparation("Interior navigation grid could not be built")
			return int(result.get("processed", 0))
		_navigation_grid_data = result.get("data", {}) as Dictionary
	else:
		# 旧壳配置仅用于兼容工具；正式十间室内全部走已验证几何的游标扫描。
		_navigation_grid_data = FLOOR_PROFILES.build_navigation_grid_data(
			_floor_profile_id,
			entry_point,
			exit_point
		)
	_base_navigation_grid_data = _navigation_grid_data.duplicate(true)
	_preparation_stage = PreparationStage.OCCLUSION_BEGIN
	return 1


func _prepare_occlusion_begin() -> void:
	var shell := get_node("RoomShell") as Sprite2D
	var configured_path := String(_preparation_config.get("occlusion_path"))
	_occlusion_path = _resolve_occlusion_path(_geometry_path, configured_path)
	if not _occlusion_path.is_empty() and not _geometry_data.is_empty():
		_wall_occlusion = WALL_OCCLUSION_SCRIPT.new() as InteriorWallOcclusion
		add_child(_wall_occlusion)
		if not bool(_wall_occlusion.begin_configuration(
			shell,
			_geometry_data,
			_geometry_path,
			_occlusion_path,
			String(_preparation_config.get("shell_path")),
		)):
			_wall_occlusion.queue_free()
			_wall_occlusion = null
			_fail_preparation("Interior wall occlusion could not be loaded")
			return
		_preparation_stage = PreparationStage.OCCLUSION_SEGMENT
		return
	_preparation_stage = PreparationStage.FURNITURE_BEGIN


func _prepare_occlusion_segment() -> void:
	var result := _wall_occlusion.continue_configuration() as Dictionary
	if result.get("failed") == true:
		_fail_preparation("Interior wall occlusion segment could not be loaded")
		return
	if result.get("complete") == true:
		_preparation_stage = PreparationStage.FURNITURE_BEGIN


func _prepare_furniture_begin() -> void:
	_furniture_manifest_path = String(
		_preparation_config.get("furniture_manifest_path"),
	)
	_furniture_layout_path = String(_preparation_config.get("furniture_layout_path"))
	if not _furniture_manifest_path.is_empty() and not _furniture_layout_path.is_empty():
		_furniture_runtime = FURNITURE_RUNTIME_SCRIPT.new() as InteriorFurnitureRuntime
		_furniture_runtime.name = "FurnitureRuntime"
		add_child(_furniture_runtime)
		_furniture_runtime.connect(
			"layout_changed",
			_on_furniture_layout_changed
		)
		if not bool(_furniture_runtime.begin_configuration(
			_furniture_manifest_path,
			_furniture_layout_path,
		)):
			var details := PackedStringArray()
			for error in _furniture_runtime.get_errors() as PackedStringArray:
				details.append(error)
			_fail_preparation(
				"Interior furniture layout could not be loaded: %s (%s)"
				% [_furniture_layout_path, "; ".join(details)],
			)
			return
		_preparation_stage = PreparationStage.FURNITURE_INSTANCE
		return
	_begin_navigation_lookup(
		PreparationStage.NAVIGATION_LOOKUP,
		PreparationStage.COMPLETE,
	)


func _prepare_furniture_instance() -> void:
	var result := _furniture_runtime.continue_configuration() as Dictionary
	if result.get("failed") == true:
		var details := _furniture_runtime.get_errors() as PackedStringArray
		_fail_preparation(
			"Interior furniture instance could not be loaded: %s"
			% "; ".join(details),
		)
		return
	if result.get("complete") == true:
		_furniture_runtime.begin_occupied_room_cell_scan()
		_preparation_config["furniture_navigation_phase"] = "occupancy"
		_preparation_stage = PreparationStage.FURNITURE_NAVIGATION


func _finish_preparation() -> void:
	queue_redraw()
	_preparation_config.clear()
	_preparation_stage = PreparationStage.COMPLETE


func _fail_preparation(message: String) -> void:
	_preparation_error = message
	_preparation_stage = PreparationStage.FAILED
	push_error(message)


func _preparation_result(
	stage_name: String,
	elapsed_usec: int,
	work_items: int = 0,
	work_item_limit: int = 0,
) -> Dictionary:
	return {
		"ok": not has_preparation_failed(),
		"complete": is_preparation_complete(),
		"failed": has_preparation_failed(),
		"stage": stage_name,
		"elapsed_usec": elapsed_usec,
		"work_items": work_items,
		"work_item_limit": work_item_limit,
		"waiting": (
			(
				stage_name == "shell_wait"
				and _preparation_stage == PreparationStage.SHELL_WAIT
			)
			or (
				stage_name == "geometry_wait"
				and _preparation_stage == PreparationStage.GEOMETRY_WAIT
			)
		),
		"error": _preparation_error,
	}


func get_floor_profile_id() -> String:
	return _floor_profile_id


func get_geometry_path() -> String:
	return _geometry_path


func get_occlusion_path() -> String:
	return _occlusion_path


func get_furniture_manifest_path() -> String:
	return _furniture_manifest_path


func get_furniture_layout_path() -> String:
	return _furniture_layout_path


func get_furniture_layout_snapshot() -> Dictionary:
	if not is_instance_valid(_furniture_runtime):
		return {}
	return _furniture_runtime.get_layout_snapshot() as Dictionary


func has_furniture_runtime() -> bool:
	return is_instance_valid(_furniture_runtime)


func get_furniture_instance_count() -> int:
	if not is_instance_valid(_furniture_runtime):
		return 0
	return int(_furniture_runtime.get_instance_count())


func get_furniture_collision_shape_count() -> int:
	if not is_instance_valid(_furniture_runtime):
		return 0
	return int(_furniture_runtime.get_collision_shape_count())


func get_furniture_errors() -> PackedStringArray:
	if not is_instance_valid(_furniture_runtime):
		return PackedStringArray()
	return _furniture_runtime.get_errors() as PackedStringArray


func set_furniture_layout_path(layout_path: String) -> bool:
	if layout_path.is_empty():
		return false
	if not is_instance_valid(_furniture_runtime):
		return false
	if layout_path == _furniture_layout_path:
		return true
	if not bool(_furniture_runtime.set_layout_path(layout_path)):
		return false
	_furniture_layout_path = layout_path
	return true


func apply_furniture_layout(layout: Dictionary) -> Dictionary:
	if not is_instance_valid(_furniture_runtime):
		return {
			"ok": false,
			"changed": false,
			"errors": PackedStringArray(["室内尚未加载家具运行时"]),
		}
	return _furniture_runtime.apply_layout(layout) as Dictionary


func upsert_furniture_instance(instance: Dictionary) -> Dictionary:
	if not is_instance_valid(_furniture_runtime):
		return {
			"ok": false,
			"changed": false,
			"errors": PackedStringArray(["室内尚未加载家具运行时"]),
		}
	return _furniture_runtime.upsert_instance(instance) as Dictionary


func remove_furniture_instance(instance_id: String) -> Dictionary:
	if not is_instance_valid(_furniture_runtime):
		return {
			"ok": false,
			"changed": false,
			"errors": PackedStringArray(["室内尚未加载家具运行时"]),
		}
	return _furniture_runtime.remove_instance(instance_id) as Dictionary


func create_world_layout_projection(base_projection: Dictionary) -> Dictionary:
	if not is_instance_valid(_furniture_runtime):
		return {
			"ok": false,
			"errors": PackedStringArray(["室内尚未加载家具运行时"]),
			"projection": {},
		}
	var navigation := (
		base_projection.get("navigation", {}) as Dictionary
	).duplicate(true)
	navigation["cellSize"] = int(_navigation_grid_data.get("cell_size", 0))
	navigation["walkableCells"] = (
		_navigation_grid_data.get("walkable_cells", []) as Array
	).duplicate(true)
	var identity := {
		"spaceId": str(base_projection.get("spaceId", "")),
		"placeName": str(base_projection.get("placeName", "")),
		"regionId": str(base_projection.get("regionId", "")),
		"roomId": str(base_projection.get("roomId", "")),
	}
	var prop_result := _furniture_runtime.create_agent_prop_projection(base_projection.get("props", []) as Array,
		identity,
		navigation.get("walkableCells", []) as Array,) as Dictionary
	if prop_result.get("ok") != true:
		return {
			"ok": false,
			"errors": prop_result.get("errors", PackedStringArray()),
			"projection": {},
		}
	return {
		"ok": true,
		"errors": PackedStringArray(),
		"projection": {
			"spaceId": identity["spaceId"],
			"placeName": identity["placeName"],
			"regionId": identity["regionId"],
			"roomId": identity["roomId"],
			"navigation": navigation,
			"props": (prop_result.get("props", []) as Array).duplicate(true),
		},
	}


func uses_room_geometry() -> bool:
	return not _geometry_data.is_empty()


func get_navigation_grid_data() -> Dictionary:
	return _navigation_grid_data.duplicate(true)


func local_position_to_navigation_cell(local_position: Vector2) -> Vector2i:
	if not _geometry_data.is_empty():
		return ROOM_GEOMETRY.local_position_to_cell(local_position)
	return FLOOR_PROFILES.local_position_to_cell(local_position)


func is_local_position_walkable(local_position: Vector2) -> bool:
	return is_navigation_cell_walkable(local_position_to_navigation_cell(local_position))


func is_navigation_cell_walkable(cell: Vector2i) -> bool:
	return _walkable_cell_lookup.has(cell)


func get_walkable_navigation_neighbors(cell: Vector2i) -> Array[Vector2i]:
	var neighbors: Array[Vector2i] = []
	for offset in FLOOR_PROFILES.CARDINAL_OFFSETS:
		var candidate: Vector2i = cell + offset
		if is_navigation_cell_walkable(candidate):
			neighbors.append(candidate)
	return neighbors


func set_geometry_debug_visible(value: bool) -> void:
	_geometry_debug_visible = value
	if is_instance_valid(_wall_occlusion):
		_wall_occlusion.set_debug_visible(value)
	if is_instance_valid(_furniture_runtime):
		_furniture_runtime.set_debug_visible(value)
	queue_redraw()


func is_geometry_debug_visible() -> bool:
	return _geometry_debug_visible


func has_wall_occlusion() -> bool:
	return is_instance_valid(_wall_occlusion)


func update_wall_occlusion_subjects(subjects: Array[Node2D]) -> bool:
	if not is_instance_valid(_wall_occlusion):
		return false
	return bool(_wall_occlusion.update_for_subjects(subjects))


func get_floor_local_bounds() -> Rect2:
	if not _geometry_data.is_empty():
		return ROOM_GEOMETRY.get_floor_local_bounds(_geometry_data)
	var navigation_size := _navigation_grid_data.get("size", [0, 0]) as Array
	var origin_cell := _navigation_grid_data.get("origin_cell", [0, 0]) as Array
	if navigation_size.size() < 2 or origin_cell.size() < 2:
		return Rect2()
	return Rect2(
		Vector2(float(origin_cell[0]), float(origin_cell[1])) * FLOOR_PROFILES.GRID_SIZE,
		Vector2(float(navigation_size[0]), float(navigation_size[1])) * FLOOR_PROFILES.GRID_SIZE
	)


func get_shell_local_bounds() -> Rect2:
	if not _geometry_data.is_empty():
		return ROOM_GEOMETRY.get_shell_local_bounds(_geometry_data)
	var shell := get_node("RoomShell") as Sprite2D
	if shell.texture == null:
		return Rect2()
	var size := shell.texture.get_size()
	return Rect2(shell.position - size * 0.5, size)


func _draw() -> void:
	if not _geometry_debug_visible:
		return
	var grid_size := (
		ROOM_GEOMETRY.GRID_SIZE
		if not _geometry_data.is_empty()
		else FLOOR_PROFILES.GRID_SIZE
	)
	for serialized_cell in _navigation_grid_data.get("walkable_cells", []) as Array:
		var cell := Vector2i(int(serialized_cell[0]), int(serialized_cell[1]))
		var rect := Rect2(Vector2(cell) * grid_size, Vector2.ONE * grid_size)
		draw_rect(rect, Color(0.20, 0.82, 0.46, 0.18), true)
		draw_rect(rect, Color(0.28, 0.95, 0.60, 0.48), false, 1.0)
	var blocker_rects: Array[Rect2] = (
		ROOM_GEOMETRY.get_boundary_collision_rects(_geometry_data)
		if not _geometry_data.is_empty()
		else FLOOR_PROFILES.get_boundary_collision_rects(_floor_profile_id)
	)
	for rect in blocker_rects:
		draw_rect(rect, Color(0.93, 0.18, 0.22, 0.25), true)
		draw_rect(rect, Color(1.0, 0.28, 0.32, 0.72), false, 2.0)
	draw_circle(
		(get_node("IndoorEntryPoint") as Marker2D).position,
		11.0,
		Color(0.10, 0.88, 1.0, 0.95)
	)
	draw_circle(
		(get_node("IndoorExitPoint") as Marker2D).position,
		9.0,
		Color(1.0, 0.34, 0.72, 0.95)
	)


func _prepare_wall_collision(max_work_items: int) -> int:
	var processed := 0
	if not _preparation_config.has("collision_rects"):
		if not _geometry_data.is_empty():
			if not _preparation_config.has("collision_scan"):
				_preparation_config["collision_scan"] = (
					ROOM_GEOMETRY.begin_boundary_collision_scan(_geometry_data)
				)
			var result := ROOM_GEOMETRY.continue_boundary_collision_scan(
				_preparation_config.get("collision_scan") as Dictionary,
				max_work_items,
			) as Dictionary
			processed += int(result.get("processed", 0))
			if result.get("complete") != true:
				return processed
			_preparation_config.erase("collision_scan")
			_preparation_config["collision_rects"] = result.get("rects", []) as Array
		else:
			# 旧壳配置仅用于兼容工具；正式室内使用上面的游标扫描。
			_preparation_config["collision_rects"] = (
				FLOOR_PROFILES.get_boundary_collision_rects(_floor_profile_id)
			)
		_preparation_config["collision_cursor"] = 0
	var collision_rects := _preparation_config.get("collision_rects", []) as Array
	var cursor := int(_preparation_config.get("collision_cursor", 0))
	var wall := get_node("WallCollision") as StaticBody2D
	while cursor < collision_rects.size() and processed < max_work_items:
		var rect := collision_rects[cursor] as Rect2
		var collision := CollisionShape2D.new()
		collision.name = "WallSection_%02d" % cursor
		collision.position = rect.get_center()
		var shape := RectangleShape2D.new()
		shape.size = rect.size
		collision.shape = shape
		wall.add_child(collision)
		cursor += 1
		processed += 1
	_preparation_config["collision_cursor"] = cursor
	if cursor >= collision_rects.size():
		_preparation_config.erase("collision_rects")
		_preparation_config.erase("collision_cursor")
		_preparation_stage = PreparationStage.NAVIGATION
	return processed


func _begin_navigation_lookup(stage: PreparationStage, next_stage: PreparationStage) -> void:
	_walkable_cell_lookup = {}
	_preparation_config["navigation_lookup_cells"] = (
		_navigation_grid_data.get("walkable_cells", []) as Array
	)
	_preparation_config["navigation_lookup_cursor"] = 0
	_preparation_config["navigation_lookup_next_stage"] = next_stage
	_preparation_stage = stage


func _continue_navigation_lookup(max_work_items: int) -> int:
	var cells := _preparation_config.get("navigation_lookup_cells", []) as Array
	var cursor := int(_preparation_config.get("navigation_lookup_cursor", 0))
	var processed := 0
	while cursor < cells.size() and processed < max_work_items:
		var serialized_cell := cells[cursor] as Array
		if serialized_cell.size() >= 2:
			_walkable_cell_lookup[Vector2i(
				int(serialized_cell[0]),
				int(serialized_cell[1]),
			)] = true
		cursor += 1
		processed += 1
	_preparation_config["navigation_lookup_cursor"] = cursor
	if cursor >= cells.size():
		var next_stage := int(_preparation_config.get(
			"navigation_lookup_next_stage",
			PreparationStage.COMPLETE,
		)) as PreparationStage
		_preparation_config.erase("navigation_lookup_cells")
		_preparation_config.erase("navigation_lookup_cursor")
		_preparation_config.erase("navigation_lookup_next_stage")
		if next_stage == PreparationStage.COMPLETE:
			_finish_preparation()
		else:
			_preparation_stage = next_stage
	return processed


func _rebuild_navigation_lookup() -> void:
	_walkable_cell_lookup.clear()
	for serialized_cell in _navigation_grid_data.get("walkable_cells", []) as Array:
		if serialized_cell is Array and serialized_cell.size() >= 2:
			_walkable_cell_lookup[Vector2i(
				int(serialized_cell[0]),
				int(serialized_cell[1])
			)] = true


func _prepare_furniture_navigation(max_work_items: int) -> int:
	var phase := String(_preparation_config.get(
		"furniture_navigation_phase",
		"occupancy",
	))
	if phase == "occupancy":
		var occupancy_result := (
			_furniture_runtime.continue_occupied_room_cell_scan(max_work_items)
			as Dictionary
		)
		var processed := int(occupancy_result.get("processed", 0))
		if occupancy_result.get("complete") != true:
			return processed
		_preparation_config["furniture_blocked_cells"] = (
			_furniture_runtime.get_scanned_occupied_room_cells()
		)
		_preparation_config["furniture_blocked_lookup"] = (
			_furniture_runtime.get_scanned_occupied_room_cell_lookup()
		)
		_preparation_config["furniture_filtered_walkable"] = []
		_preparation_config["furniture_walkable_cursor"] = 0
		_preparation_config["furniture_navigation_phase"] = "walkable"
		return processed
	if phase == "walkable":
		var source_walkable := (
			_navigation_grid_data.get("walkable_cells", []) as Array
		)
		var cursor := int(_preparation_config.get("furniture_walkable_cursor", 0))
		var filtered := _preparation_config.get(
			"furniture_filtered_walkable",
			[],
		) as Array
		var blocked := _preparation_config.get(
			"furniture_blocked_lookup",
			{},
		) as Dictionary
		var processed := 0
		while cursor < source_walkable.size() and processed < max_work_items:
			var serialized_cell := source_walkable[cursor] as Array
			var cell := Vector2i(int(serialized_cell[0]), int(serialized_cell[1]))
			if not blocked.has(cell):
				filtered.append(serialized_cell)
			cursor += 1
			processed += 1
		_preparation_config["furniture_walkable_cursor"] = cursor
		if cursor >= source_walkable.size():
			_preparation_config["furniture_wall_lookup"] = {}
			_preparation_config["furniture_wall_cursor"] = 0
			_preparation_config["furniture_navigation_phase"] = "walls"
		return processed
	if phase == "walls":
		var wall_cells := _navigation_grid_data.get("wall_cells", []) as Array
		var cursor := int(_preparation_config.get("furniture_wall_cursor", 0))
		var wall_lookup := _preparation_config.get(
			"furniture_wall_lookup",
			{},
		) as Dictionary
		var processed := 0
		while cursor < wall_cells.size() and processed < max_work_items:
			var serialized_cell := wall_cells[cursor] as Array
			wall_lookup[Vector2i(
				int(serialized_cell[0]),
				int(serialized_cell[1]),
			)] = true
			cursor += 1
			processed += 1
		_preparation_config["furniture_wall_cursor"] = cursor
		if cursor >= wall_cells.size():
			_preparation_config["furniture_blocked_cursor"] = 0
			_preparation_config["furniture_navigation_phase"] = "blocked"
		return processed
	var blocked_cells := _preparation_config.get(
		"furniture_blocked_cells",
		[],
	) as Array
	var cursor := int(_preparation_config.get("furniture_blocked_cursor", 0))
	var wall_cells := _navigation_grid_data.get("wall_cells", []) as Array
	var wall_lookup := _preparation_config.get("furniture_wall_lookup", {}) as Dictionary
	var processed := 0
	while cursor < blocked_cells.size() and processed < max_work_items:
		var cell := blocked_cells[cursor] as Vector2i
		if not wall_lookup.has(cell):
			wall_lookup[cell] = true
			wall_cells.append([cell.x, cell.y])
		cursor += 1
		processed += 1
	_preparation_config["furniture_blocked_cursor"] = cursor
	if cursor >= blocked_cells.size():
		_navigation_grid_data["walkable_cells"] = _preparation_config.get(
			"furniture_filtered_walkable",
			[],
		) as Array
		for key in [
			"furniture_navigation_phase",
			"furniture_blocked_cells",
			"furniture_blocked_lookup",
			"furniture_filtered_walkable",
			"furniture_walkable_cursor",
			"furniture_wall_lookup",
			"furniture_wall_cursor",
			"furniture_blocked_cursor",
		]:
			_preparation_config.erase(key)
		_begin_navigation_lookup(
			PreparationStage.FURNITURE_NAVIGATION_LOOKUP,
			PreparationStage.COMPLETE,
		)
	return processed


func _apply_furniture_navigation_blockers() -> void:
	if not is_instance_valid(_furniture_runtime):
		return
	var blocked_lookup := {}
	for cell in _furniture_runtime.get_occupied_room_cells() as Array[Vector2i]:
		blocked_lookup[cell] = true
	var filtered_walkable: Array = []
	for serialized_cell in _navigation_grid_data.get("walkable_cells", []) as Array:
		var cell := Vector2i(int(serialized_cell[0]), int(serialized_cell[1]))
		if not blocked_lookup.has(cell):
			filtered_walkable.append(serialized_cell)
	var wall_cells: Array = (_navigation_grid_data.get("wall_cells", []) as Array).duplicate(true)
	var wall_lookup := {}
	for serialized_cell in wall_cells:
		wall_lookup["%d,%d" % [int(serialized_cell[0]), int(serialized_cell[1])]] = true
	for cell in blocked_lookup.keys():
		var typed_cell := cell as Vector2i
		var key := "%d,%d" % [typed_cell.x, typed_cell.y]
		if not wall_lookup.has(key):
			wall_cells.append([typed_cell.x, typed_cell.y])
	_navigation_grid_data["walkable_cells"] = filtered_walkable
	_navigation_grid_data["wall_cells"] = wall_cells
	_rebuild_navigation_lookup()


func _on_furniture_layout_changed(snapshot: Dictionary) -> void:
	_navigation_grid_data = _base_navigation_grid_data.duplicate(true)
	_apply_furniture_navigation_blockers()
	# 局部灯光、炉火和蒸汽必须读取家具资产中精确登记的效果锚点。
	# 在效果锚点合同落地前，不允许用家具根节点加猜测偏移生成视觉效果。
	@warning_ignore("unused_parameter")
	var _unused_snapshot := snapshot
	queue_redraw()


func _load_texture(path: String) -> Texture2D:
	if ResourceLoader.exists(path, "Texture2D"):
		var imported := ResourceLoader.load(path, "Texture2D") as Texture2D
		if imported != null:
			return imported
	if not FileAccess.file_exists(path):
		return null
	var image := Image.new()
	if image.load(ProjectSettings.globalize_path(path)) != OK:
		return null
	return ImageTexture.create_from_image(image)


func _resolve_occlusion_path(geometry_path: String, configured_path: String) -> String:
	if not configured_path.is_empty():
		return configured_path
	if geometry_path.is_empty():
		return ""
	var sibling_path := geometry_path.get_base_dir().path_join("wall_occlusion.json")
	return sibling_path if FileAccess.file_exists(sibling_path) else ""
