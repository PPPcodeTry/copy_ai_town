class_name InteriorRoomBuildQueue
extends Node

signal room_prepared(interior_id: String, room: InteriorRoom, profile: Dictionary)
signal room_failed(interior_id: String, error: String, profile: Dictionary)

const FRAME_BUDGET_USEC := 8000
const ROOM_SCENE := preload(
	"res://world/maps/town/interiors/InteriorRoom.tscn"
)

var _order: Array[String] = []
var _jobs: Dictionary = {}
var _room_profiles: Dictionary = {}
var _max_frame_work_usec := 0
var _max_stage_usec := 0
var _completed_room_count := 0
var _failed_room_count := 0


func _ready() -> void:
	set_process(false)


func _exit_tree() -> void:
	for job_value: Variant in _jobs.values():
		var room := (job_value as Dictionary).get("room") as InteriorRoom
		if is_instance_valid(room) and room.get_parent() == null:
			room.free()
	_jobs.clear()
	_order.clear()


func request(
	interior_id: String,
	definition: Dictionary,
	priority: bool = false,
) -> bool:
	if interior_id.is_empty() or definition.is_empty() or _jobs.has(interior_id):
		return false
	var room := ROOM_SCENE.instantiate() as InteriorRoom
	if room == null:
		return false
	if not room.begin_preparation(
		String(definition.get("shell_path", "")),
		definition.get("entry_point", Vector2.ZERO) as Vector2,
		definition.get("exit_point", Vector2.ZERO) as Vector2,
		String(definition.get("geometry_path", "")),
		String(definition.get("occlusion_path", "")),
		String(definition.get("furniture_manifest_path", "")),
		String(definition.get("layout_path", "")),
		true,
	):
		room.free()
		return false
	_jobs[interior_id] = {
		"room": room,
		"requested_usec": Time.get_ticks_usec(),
		"cpu_usec": 0,
		"max_stage_usec": 0,
		"stage_count": 0,
		"stages": {},
	}
	if priority:
		_order.push_front(interior_id)
	else:
		_order.append(interior_id)
	set_process(true)
	return true


func is_pending(interior_id: String) -> bool:
	return _jobs.has(interior_id)


func get_frame_budget_usec() -> int:
	return FRAME_BUDGET_USEC


func get_profile_snapshot() -> Dictionary:
	return {
		"frame_budget_usec": FRAME_BUDGET_USEC,
		"max_frame_work_usec": _max_frame_work_usec,
		"max_stage_usec": _max_stage_usec,
		"completed_room_count": _completed_room_count,
		"failed_room_count": _failed_room_count,
		"rooms": _room_profiles.duplicate(true),
	}


func _process(_delta: float) -> void:
	if _order.is_empty():
		set_process(false)
		return
	var frame_started_usec := Time.get_ticks_usec()
	while not _order.is_empty():
		var interior_id := _order[0]
		var job := _jobs.get(interior_id, {}) as Dictionary
		var room := job.get("room") as InteriorRoom
		if not is_instance_valid(room):
			_finish_failed(interior_id, "interior room disappeared")
		else:
			var result := room.prepare_next_stage() as Dictionary
			var stage_usec := int(result.get("elapsed_usec", 0))
			job["cpu_usec"] = int(job.get("cpu_usec", 0)) + stage_usec
			job["max_stage_usec"] = maxi(
				int(job.get("max_stage_usec", 0)),
				stage_usec,
			)
			job["stage_count"] = int(job.get("stage_count", 0)) + 1
			var stages := job.get("stages", {}) as Dictionary
			var stage_name := String(result.get("stage", "unknown"))
			stages[stage_name] = maxi(
				int(stages.get(stage_name, 0)),
				stage_usec,
			)
			_max_stage_usec = maxi(_max_stage_usec, stage_usec)
			if result.get("failed") == true:
				_finish_failed(interior_id, String(result.get("error", "unknown")))
			elif result.get("complete") == true:
				_finish_prepared(interior_id, room)
			if result.get("waiting") == true:
				break
		var frame_work_usec := Time.get_ticks_usec() - frame_started_usec
		if frame_work_usec >= FRAME_BUDGET_USEC:
			break
	var total_frame_work_usec := Time.get_ticks_usec() - frame_started_usec
	_max_frame_work_usec = maxi(_max_frame_work_usec, total_frame_work_usec)
	if _order.is_empty():
		set_process(false)


func _finish_prepared(interior_id: String, room: InteriorRoom) -> void:
	var profile := _final_profile(interior_id)
	_remove_job(interior_id)
	_completed_room_count += 1
	_room_profiles[interior_id] = profile
	room_prepared.emit(interior_id, room, profile)


func _finish_failed(interior_id: String, error: String) -> void:
	var job := _jobs.get(interior_id, {}) as Dictionary
	var room := job.get("room") as InteriorRoom
	var profile := _final_profile(interior_id)
	_remove_job(interior_id)
	_failed_room_count += 1
	_room_profiles[interior_id] = profile
	if is_instance_valid(room):
		room.free()
	room_failed.emit(interior_id, error, profile)


func _final_profile(interior_id: String) -> Dictionary:
	var job := _jobs.get(interior_id, {}) as Dictionary
	return {
		"cpu_usec": int(job.get("cpu_usec", 0)),
		"wall_usec": Time.get_ticks_usec() - int(job.get("requested_usec", 0)),
		"max_stage_usec": int(job.get("max_stage_usec", 0)),
		"stage_count": int(job.get("stage_count", 0)),
		"stages": (job.get("stages", {}) as Dictionary).duplicate(),
	}


func _remove_job(interior_id: String) -> void:
	_jobs.erase(interior_id)
	_order.erase(interior_id)
