class_name InteriorOcclusionController
extends Node

var _active_room: InteriorRoom
var _player_subject: Node2D
var _resident_subjects: Array[Node2D] = []
var _resident_presentation: Node
var _dirty := false


func _ready() -> void:
	set_process(true)


func _process(_delta: float) -> void:
	process_pending()


func bind_player(subject: Node2D) -> void:
	_player_subject = subject
	_dirty = true


func bind_resident_presentation(presentation: Node) -> bool:
	_disconnect_resident_presentation()
	if (
		not is_instance_valid(presentation)
		or not presentation.has_signal("occlusion_subjects_changed")
		or not presentation.has_signal("occlusion_subject_state_changed")
		or not presentation.has_method("get_active_occlusion_subjects")
	):
		return false
	_resident_presentation = presentation
	presentation.connect(
		"occlusion_subjects_changed",
		_on_resident_subjects_changed,
	)
	presentation.connect(
		"occlusion_subject_state_changed",
		mark_subject_dirty,
	)
	_on_resident_subjects_changed(
		presentation.get_active_occlusion_subjects() as Array[Node2D],
	)
	return true


func set_active_room(room: InteriorRoom) -> void:
	if _active_room == room:
		return
	_active_room = room
	_dirty = true


func mark_subject_dirty(subject: Node2D) -> void:
	if subject == _player_subject or _resident_subjects.has(subject):
		_dirty = true


func process_pending() -> bool:
	if not _dirty:
		return false
	_dirty = false
	if not is_instance_valid(_active_room) or not _active_room.visible:
		return false
	var subjects: Array[Node2D] = []
	if is_instance_valid(_player_subject):
		subjects.append(_player_subject)
	for subject in _resident_subjects:
		if is_instance_valid(subject):
			subjects.append(subject)
	_active_room.update_wall_occlusion_subjects(subjects)
	return true


func has_pending_refresh() -> bool:
	return _dirty


func _on_resident_subjects_changed(subjects: Array[Node2D]) -> void:
	_resident_subjects = []
	_resident_subjects.assign(subjects)
	_dirty = true


func _disconnect_resident_presentation() -> void:
	if not is_instance_valid(_resident_presentation):
		_resident_presentation = null
		_resident_subjects.clear()
		return
	for signal_name: StringName in [
		&"occlusion_subjects_changed",
		&"occlusion_subject_state_changed",
	]:
		var callable: Callable = (
			_on_resident_subjects_changed
			if signal_name == &"occlusion_subjects_changed"
			else mark_subject_dirty
		)
		if _resident_presentation.is_connected(signal_name, callable):
			_resident_presentation.disconnect(signal_name, callable)
	_resident_presentation = null
	_resident_subjects.clear()
