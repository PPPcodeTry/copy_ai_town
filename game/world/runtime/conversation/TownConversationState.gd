class_name TownConversationState
extends RefCounted


var records: Dictionary = {}
var autonomous_idle_seconds: Dictionary = {}
var autonomous_timeout_tick_seconds := 0.0
var sequence := 0
var transient_photo_conversation_ids: Dictionary = {}
var traveler_relationship_state: TownTravelerRelationshipState


func _init(
	bound_traveler_relationship_state: TownTravelerRelationshipState = null,
) -> void:
	traveler_relationship_state = bound_traveler_relationship_state


func reset() -> void:
	records.clear()
	autonomous_idle_seconds.clear()
	autonomous_timeout_tick_seconds = 0.0
	sequence = 0
	transient_photo_conversation_ids.clear()


func restore(
	prepared_records: Dictionary,
	prepared_idle_seconds: Dictionary,
	prepared_sequence: int,
) -> void:
	records = prepared_records.duplicate(true)
	autonomous_idle_seconds = prepared_idle_seconds.duplicate(true)
	autonomous_timeout_tick_seconds = 0.0
	sequence = prepared_sequence
	transient_photo_conversation_ids.clear()


func mark_transient_photo_conversation(
	conversation_id: String,
	pending: bool,
) -> void:
	var normalized_id := conversation_id.strip_edges()
	if normalized_id.is_empty():
		return
	if pending:
		transient_photo_conversation_ids[normalized_id] = true
	else:
		transient_photo_conversation_ids.erase(normalized_id)


func clear_transient_photo_conversations() -> void:
	transient_photo_conversation_ids.clear()


func has_unmaterialized_photo_conversations() -> bool:
	for conversation_id_value: Variant in transient_photo_conversation_ids.keys():
		var conversation_id := String(conversation_id_value)
		var conversation_value: Variant = records.get(conversation_id)
		if not conversation_value is Dictionary:
			continue
		for turn_value: Variant in (conversation_value as Dictionary).get("turns", []) as Array:
			if not turn_value is Dictionary:
				continue
			var photos: Variant = (turn_value as Dictionary).get("photos", [])
			if photos is Array and not (photos as Array).is_empty():
				return true
	return false


func next_id() -> String:
	sequence += 1
	return "conversation-%d" % sequence
