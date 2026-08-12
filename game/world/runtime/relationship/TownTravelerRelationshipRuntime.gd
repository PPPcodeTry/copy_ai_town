class_name TownTravelerRelationshipRuntime
extends RefCounted


const SAVE_SCHEMA := "traveler-relationship"
const SCHEMA_VERSION := 1
const MAX_PROCESSED_CONVERSATIONS := 128
const MAX_PROCESSED_INTERACTIONS := 256
const MAX_AFFINITY_CHANGE_HISTORY := 32
const AGENT_AFFINITY_DELTA_MIN := -5
const AGENT_AFFINITY_DELTA_MAX := 5
const AVATAR_ATTACK_AFFINITY_DELTA := -10

const FAMILIARITY_LABELS := [
	"尚未交谈",
	"刚刚认识",
	"有些熟悉",
	"熟悉",
	"很熟悉",
	"老相识",
]
const FAMILIARITY_CONVERSATION_THRESHOLDS := [0, 1, 3, 6, 12, 24]


static func empty_snapshot() -> Dictionary:
	return {
		"schema": SAVE_SCHEMA,
		"schemaVersion": SCHEMA_VERSION,
		"items": {},
	}


static func normalize_snapshot(
	value: Variant,
	avatar_id: String,
	resident_ids: Array,
) -> Dictionary:
	var normalized := empty_snapshot()
	if not value is Dictionary:
		return normalized
	var source := value as Dictionary
	var source_items: Variant = source.get("items", source.get("relations", {}))
	if not source_items is Dictionary:
		return normalized
	var allowed_ids := {}
	for resident_value: Variant in resident_ids:
		var resident_id := String(resident_value).strip_edges()
		if not resident_id.is_empty():
			allowed_ids[resident_id] = true
	for resident_id_value: Variant in source_items:
		var resident_id := String(resident_id_value).strip_edges()
		if resident_id.is_empty() or not allowed_ids.has(resident_id):
			continue
		var item_value: Variant = (source_items as Dictionary).get(resident_id)
		if not item_value is Dictionary:
			continue
		var item := _normalized_item(
			item_value as Dictionary,
			avatar_id,
			resident_id,
		)
		normalized["items"][resident_id] = item
	return normalized


static func record_ended_conversation(
	snapshot: Dictionary,
	avatar_id: String,
	resident_id: String,
	conversation: Dictionary,
) -> bool:
	if (
		avatar_id.strip_edges().is_empty()
		or resident_id.strip_edges().is_empty()
		or String(conversation.get("status", "")) != "ended"
	):
		return false
	var participants_value: Variant = conversation.get("participants", [])
	if not participants_value is Array:
		return false
	var participants := participants_value as Array
	if not participants.has(avatar_id) or not participants.has(resident_id):
		return false
	var conversation_id := String(conversation.get("conversationId", "")).strip_edges()
	if conversation_id.is_empty():
		return false
	var items := snapshot.get("items", {}) as Dictionary
	var item := _normalized_item(
		items.get(resident_id, {}) as Dictionary,
		avatar_id,
		resident_id,
	)
	var processed := item.get("processedConversationIds", []) as Array
	if processed.has(conversation_id):
		return false
	var avatar_turn_count := 0
	var resident_turn_count := 0
	var confirmed_turn_count := 0
	for turn_value: Variant in conversation.get("turns", []) as Array:
		if typeof(turn_value) != TYPE_DICTIONARY:
			continue
		var speaker_id := String(
			(turn_value as Dictionary).get("speaker_resident_id", ""),
		)
		if speaker_id == avatar_id:
			avatar_turn_count += 1
		elif speaker_id == resident_id:
			resident_turn_count += 1
		else:
			continue
		confirmed_turn_count += 1
	if avatar_turn_count <= 0 or resident_turn_count <= 0:
		return false
	processed.append(conversation_id)
	while processed.size() > MAX_PROCESSED_CONVERSATIONS:
		processed.pop_front()
	item["processedConversationIds"] = processed
	item["conversationCount"] = int(item.get("conversationCount", 0)) + 1
	item["confirmedTurnCount"] = (
		int(item.get("confirmedTurnCount", 0)) + confirmed_turn_count
	)
	var ended_at_value: Variant = conversation.get("endedAt", {})
	item["lastInteractionAt"] = (
		ended_at_value.duplicate(true)
		if ended_at_value is Dictionary
		else {}
	)
	item["lastConversationId"] = conversation_id
	item["lastInteractionSource"] = "conversation_end"
	_update_labels(item)
	items[resident_id] = item
	snapshot["items"] = items
	return true


static func record_resident_reply(
	snapshot: Dictionary,
	avatar_id: String,
	resident_id: String,
	conversation: Dictionary,
	turn: Dictionary,
	delta: int,
) -> bool:
	if (
		avatar_id.strip_edges().is_empty()
		or resident_id.strip_edges().is_empty()
		or not conversation.get("participants", []) is Array
		or not (conversation.get("participants", []) as Array).has(avatar_id)
		or not (conversation.get("participants", []) as Array).has(resident_id)
	):
		return false
	var conversation_id := String(conversation.get("conversationId", "")).strip_edges()
	var turn_id := int(turn.get("turn_id", 0))
	if conversation_id.is_empty() or turn_id <= 0:
		return false
	if String(turn.get("speaker_resident_id", "")) != resident_id:
		return false
	var items := snapshot.get("items", {}) as Dictionary
	var item := _normalized_item(
		items.get(resident_id, {}) as Dictionary,
		avatar_id,
		resident_id,
	)
	var interaction_id := "%s:reply:%d" % [conversation_id, turn_id]
	var processed := item.get("processedReplyIds", []) as Array
	if processed.has(interaction_id):
		return false
	processed.append(interaction_id)
	while processed.size() > MAX_PROCESSED_INTERACTIONS:
		processed.pop_front()
	item["processedReplyIds"] = processed
	var bounded_delta := clampi(
		delta,
		AGENT_AFFINITY_DELTA_MIN,
		AGENT_AFFINITY_DELTA_MAX,
	)
	item["affinity"] = clampi(
		int(item.get("affinity", 50)) + bounded_delta,
		0,
		100,
	)
	var updated_at_value: Variant = conversation.get("updatedAt", {})
	item["lastInteractionAt"] = (
		updated_at_value.duplicate(true)
		if updated_at_value is Dictionary
		else {}
	)
	item["lastConversationId"] = conversation_id
	item["lastInteractionSource"] = "resident_reply"
	_record_affinity_change(item, bounded_delta, "resident_reply", interaction_id)
	_update_labels(item)
	items[resident_id] = item
	snapshot["items"] = items
	return true


static func record_avatar_attack(
	snapshot: Dictionary,
	avatar_id: String,
	resident_id: String,
	attack_id: String,
	interaction_at: Dictionary,
) -> bool:
	if (
		avatar_id.strip_edges().is_empty()
		or resident_id.strip_edges().is_empty()
		or attack_id.strip_edges().is_empty()
	):
		return false
	var items := snapshot.get("items", {}) as Dictionary
	var item := _normalized_item(
		items.get(resident_id, {}) as Dictionary,
		avatar_id,
		resident_id,
	)
	var interaction_id := "%s:attack:%s" % [attack_id, resident_id]
	var processed := item.get("processedAttackIds", []) as Array
	if processed.has(interaction_id):
		return false
	processed.append(interaction_id)
	while processed.size() > MAX_PROCESSED_INTERACTIONS:
		processed.pop_front()
	item["processedAttackIds"] = processed
	item["attackCount"] = int(item.get("attackCount", 0)) + 1
	item["affinity"] = clampi(
		int(item.get("affinity", 50)) + AVATAR_ATTACK_AFFINITY_DELTA,
		0,
		100,
	)
	item["lastInteractionAt"] = interaction_at.duplicate(true)
	item["lastInteractionSource"] = "avatar_attack"
	_record_affinity_change(
		item,
		AVATAR_ATTACK_AFFINITY_DELTA,
		"avatar_attack",
		interaction_id,
	)
	_update_labels(item)
	items[resident_id] = item
	snapshot["items"] = items
	return true


static func projection_for_resident(
	snapshot: Dictionary,
	avatar_id: String,
	avatar_name: String,
	resident_id: String,
	include_default := false,
) -> Dictionary:
	var item_value: Variant = (snapshot.get("items", {}) as Dictionary).get(resident_id)
	if not item_value is Dictionary and not include_default:
		return {}
	var item := _normalized_item(
		item_value as Dictionary if item_value is Dictionary else {},
		avatar_id,
		resident_id,
	)
	var conversation_count := int(item.get("conversationCount", 0))
	var turn_count := int(item.get("confirmedTurnCount", 0))
	var affinity := int(item.get("affinity", 50))
	var attack_count := int(item.get("attackCount", 0))
	var last_change := item.get("lastAffinityChange", {}) as Dictionary
	var last_change_label := _affinity_change_label(last_change)
	var interaction_summary := "已完成 %d 次对话，共 %d 个确认回合" % [
		conversation_count,
		turn_count,
	]
	if attack_count > 0:
		interaction_summary += "；化身命中 %d 次" % attack_count
	return {
		"residentId": avatar_id,
		"displayName": avatar_name,
		"identityLabel": "旅行者",
		"playerInvolved": true,
		"relatedToPlayer": true,
		"travelerRelation": true,
		"relationshipLabel": "对旅行者的好感",
		"summaryOnly": false,
		"depth": {
			"available": true,
			"level": int(item.get("familiarityLevel", 0)),
			"segmentCount": 5,
			"label": String(item.get("familiarityLabel", "尚未交谈")),
		},
		"familiarity": {
			"available": true,
			"level": int(item.get("familiarityLevel", 0)),
			"segmentCount": 5,
			"label": String(item.get("familiarityLabel", "尚未交谈")),
		},
		"affinity": {
			"available": true,
			"value": affinity,
			"segmentCount": 10,
			"segmentsFilled": int(round(float(affinity) / 10.0)),
			"label": String(item.get("affinityLabel", "普通")),
		},
		"tension": {"available": false},
		"conversationCount": conversation_count,
		"confirmedTurnCount": turn_count,
		"attackCount": attack_count,
		"lastAffinityChange": (
			item.get("lastAffinityChange", {}) as Dictionary
		).duplicate(true),
		"lastAffinityChangeLabel": last_change_label,
		"summary": "%s。当前好感度：%d（%s）。" % [
			interaction_summary,
			affinity,
			String(item.get("affinityLabel", "普通")),
		],
		"recentInteractionSummary": "%s；好感度 %d（%s）%s。" % [
			interaction_summary,
			affinity,
			String(item.get("affinityLabel", "普通")),
			"；最近变化：%s" % last_change_label
			if not last_change_label.is_empty()
			else "",
		],
		"lastInteractionAt": (
			item.get("lastInteractionAt", {}) as Dictionary
		).duplicate(true),
		"updatedLabel": "",
	}


static func agent_projection_for_resident(
	snapshot: Dictionary,
	avatar_id: String,
	resident_id: String,
) -> Dictionary:
	var projection := projection_for_resident(
		snapshot,
		avatar_id,
		"旅行者",
		resident_id,
		true,
	)
	var affinity := projection.get("affinity", {}) as Dictionary
	var familiarity := projection.get("familiarity", {}) as Dictionary
	return {
		"affinity": int(affinity.get("value", 50)),
		"affinity_label": String(affinity.get("label", "普通")),
		"familiarity_level": int(familiarity.get("level", 0)),
		"familiarity_label": String(familiarity.get("label", "尚未交谈")),
		"conversation_count": int(projection.get("conversationCount", 0)),
		"attack_count": int(projection.get("attackCount", 0)),
		"last_change": String(projection.get("lastAffinityChangeLabel", "")),
	}


static func _normalized_item(
	value: Dictionary,
	avatar_id: String,
	resident_id: String,
) -> Dictionary:
	var last_interaction_at_value: Variant = value.get("lastInteractionAt", {})
	var last_affinity_change_value: Variant = value.get("lastAffinityChange", {})
	var processed_reply_ids_value: Variant = value.get("processedReplyIds", [])
	var processed_attack_ids_value: Variant = value.get("processedAttackIds", [])
	var affinity_change_history_value: Variant = value.get("affinityChangeHistory", [])
	var processed_conversation_ids_value: Variant = value.get(
		"processedConversationIds",
		[],
	)
	var item := {
		"travelerId": avatar_id,
		"residentId": resident_id,
		"conversationCount": maxi(0, int(value.get("conversationCount", 0))),
		"confirmedTurnCount": maxi(0, int(value.get("confirmedTurnCount", 0))),
		"affinity": clampi(int(value.get("affinity", 50)), 0, 100),
		"lastInteractionAt": (
			last_interaction_at_value.duplicate(true)
			if last_interaction_at_value is Dictionary
			else {}
		),
		"lastConversationId": String(value.get("lastConversationId", "")),
		"lastInteractionSource": String(value.get("lastInteractionSource", "")),
		"lastAffinityDelta": int(value.get("lastAffinityDelta", 0)),
		"lastAffinityChange": (
			last_affinity_change_value.duplicate(true)
			if last_affinity_change_value is Dictionary
			else {}
		),
		"attackCount": maxi(0, int(value.get("attackCount", 0))),
		"processedReplyIds": (
			processed_reply_ids_value.duplicate()
			if processed_reply_ids_value is Array
			else []
		),
		"processedAttackIds": (
			processed_attack_ids_value.duplicate()
			if processed_attack_ids_value is Array
			else []
		),
		"affinityChangeHistory": (
			affinity_change_history_value.duplicate(true)
			if affinity_change_history_value is Array
			else []
		),
		"processedConversationIds": (
			processed_conversation_ids_value.duplicate()
			if processed_conversation_ids_value is Array
			else []
		),
	}
	var processed := item["processedConversationIds"] as Array
	while processed.size() > MAX_PROCESSED_CONVERSATIONS:
		processed.pop_front()
	for key: String in ["processedReplyIds", "processedAttackIds"]:
		var interaction_ids := item[key] as Array
		while interaction_ids.size() > MAX_PROCESSED_INTERACTIONS:
			interaction_ids.pop_front()
	var change_history := item["affinityChangeHistory"] as Array
	while change_history.size() > MAX_AFFINITY_CHANGE_HISTORY:
		change_history.pop_front()
	_update_labels(item)
	return item


static func _record_affinity_change(
	item: Dictionary,
	delta: int,
	source: String,
	interaction_id: String,
) -> void:
	var change := {
		"delta": delta,
		"source": source,
		"interactionId": interaction_id,
	}
	var history := item.get("affinityChangeHistory", []) as Array
	history.append(change)
	while history.size() > MAX_AFFINITY_CHANGE_HISTORY:
		history.pop_front()
	item["affinityChangeHistory"] = history
	item["lastAffinityDelta"] = delta
	item["lastAffinityChange"] = change.duplicate(true)


static func _affinity_change_label(change: Dictionary) -> String:
	var delta := int(change.get("delta", 0))
	if delta == 0:
		return ""
	var source := String(change.get("source", ""))
	var source_label := (
		"居民回应"
		if source == "resident_reply"
		else "化身攻击"
		if source == "avatar_attack"
		else "互动"
	)
	return "%s%+d" % [source_label, delta]


static func _update_labels(item: Dictionary) -> void:
	var conversation_count := int(item.get("conversationCount", 0))
	var familiarity_level := 0
	for level in range(FAMILIARITY_CONVERSATION_THRESHOLDS.size()):
		if conversation_count < FAMILIARITY_CONVERSATION_THRESHOLDS[level]:
			break
		familiarity_level = level
	item["familiarityLevel"] = familiarity_level
	item["familiarityLabel"] = FAMILIARITY_LABELS[familiarity_level]
	var affinity := clampi(int(item.get("affinity", 50)), 0, 100)
	item["affinity"] = affinity
	item["affinityLabel"] = (
		"明显疏远"
		if affinity < 35
		else "有些冷淡"
		if affinity < 45
		else "普通"
		if affinity < 53
		else "开始在意"
		if affinity < 63
		else "关系不错"
		if affinity < 80
		else "信任"
		if affinity < 90
		else "很亲近"
	)
