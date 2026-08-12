class_name TownTravelerRelationshipWorldBridge
extends RefCounted


const RUNTIME := preload("res://world/runtime/relationship/TownTravelerRelationshipRuntime.gd")


static func empty_snapshot() -> Dictionary:
	return RUNTIME.empty_snapshot()


static func restore_snapshot(world, prepared: Dictionary) -> Dictionary:
	return RUNTIME.normalize_snapshot(
		prepared.get("travelerRelations", {}),
		world._player_avatar_id(),
		world._resident_order,
	)


static func public_projection(
	world,
	resident_ref: String,
	include_default := false,
) -> Dictionary:
	var resident_id: String = world._resident_key(resident_ref)
	if resident_id.is_empty():
		return {}
	return RUNTIME.projection_for_resident(
		world._traveler_relations,
		world._player_avatar_id(),
		String(world._player_avatar.get("name", "旅行者")),
		resident_id,
		include_default,
	)


static func agent_projection(world, resident_ref: String) -> Dictionary:
	var resident_id: String = world._resident_key(resident_ref)
	if resident_id.is_empty():
		return {}
	return RUNTIME.agent_projection_for_resident(
		world._traveler_relations,
		world._player_avatar_id(),
		resident_id,
	)


static func agent_projection_for_conversation(
	world,
	participant_name: String,
	other_name: String,
) -> Dictionary:
	if (
		not world._residents.has(participant_name)
		or world._person_id_for_name(other_name) != world._player_avatar_id()
	):
		return {}
	return agent_projection(world, participant_name)


static func append_public_projection(
	world,
	items: Array[Dictionary],
	resident_id: String,
) -> void:
	var relation := public_projection(world, resident_id)
	if not relation.is_empty():
		items.append(relation)


static func record_conversation(world, conversation: Dictionary) -> void:
	var avatar_id: String = world._player_avatar_id()
	for participant_value: Variant in conversation.get("participants", []) as Array:
		var participant_id := String(participant_value)
		if participant_id == avatar_id or not world._residents.has(participant_id):
			continue
		if RUNTIME.record_ended_conversation(
			world._traveler_relations,
			avatar_id,
			participant_id,
			conversation,
		):
			world._bump_world_revision(false)


static func record_reply(
	world,
	conversation: Dictionary,
	resident_ref: String,
	action: Dictionary,
	turn: Dictionary,
) -> void:
	var resident_id: String = world._resident_key(resident_ref)
	if resident_id.is_empty() or not action.has("traveler_affinity_delta"):
		return
	var delta_value: Variant = action.get("traveler_affinity_delta")
	if typeof(delta_value) != TYPE_INT:
		return
	if RUNTIME.record_resident_reply(
		world._traveler_relations,
		world._player_avatar_id(),
		resident_id,
		conversation,
		turn,
		int(delta_value),
	):
		world._bump_world_revision(false)


static func record_attack(world, resident_ref: String, attack_id: String) -> void:
	var resident_id: String = world._resident_key(resident_ref)
	if resident_id.is_empty():
		return
	if RUNTIME.record_avatar_attack(
		world._traveler_relations,
		world._player_avatar_id(),
		resident_id,
		attack_id,
		world.get_time(),
	):
		world._bump_world_revision(false)


static func record_attack_result(world, result: Dictionary, intent: Dictionary) -> void:
	if result.get("ok") != true:
		return
	var attack_id := String(result.get("castId", intent.get("requestId", "")))
	for target_value: Variant in result.get("hitTargetIds", []) as Array:
		record_attack(world, String(target_value), attack_id)
