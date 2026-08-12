class_name AgentContractConversation
extends RefCounted
## AgentContract 拆分模块(批次C之4,纯搬运+跨模块调用改类前缀)。


static func _validate_conversation(conversation: Dictionary, errors: Array[String]) -> void:
	AgentContract._require_non_empty_string(
		conversation,
		"conversation_id",
		"snapshot.conversation.conversation_id",
		errors,
	)
	AgentContractIdentity._validate_resident_id(
		conversation,
		"with_resident_id",
		"snapshot.conversation.with_resident_id",
		errors,
	)
	AgentContract._require_non_empty_string(conversation, "with", "snapshot.conversation.with", errors)
	var turns := AgentContract._require_array(conversation, "turns", "snapshot.conversation.turns", errors)
	for index in turns.size():
		_validate_turn(turns[index], "snapshot.conversation.turns[%d]" % index, errors)
		if typeof(turns[index]) == TYPE_DICTIONARY:
			var turn := turns[index] as Dictionary
			if typeof(turn.get("turn_id")) == TYPE_INT and int(turn["turn_id"]) != index + 1:
				errors.append(
					"snapshot.conversation.turns[%d].turn_id 必须从 1 开始递增" % index,
				)
	if conversation.has("medical_context"):
		var medical_value: Variant = conversation.get("medical_context")
		if medical_value != null:
			AgentContractMedical._validate_medical_dialogue_projection(
				medical_value,
				"snapshot.conversation.medical_context",
				"",
				errors,
			)
	if conversation.has("traveler_relationship"):
		_validate_traveler_relationship(
			conversation.get("traveler_relationship"),
			"snapshot.conversation.traveler_relationship",
			errors,
		)


static func _validate_traveler_relationship(
	value: Variant,
	path: String,
	errors: Array[String],
) -> void:
	if value is not Dictionary:
		errors.append("%s 必须是对象" % path)
		return
	var relationship := value as Dictionary
	AgentContractIdentity._validate_allowed_fields(
		relationship,
		[
			"affinity",
			"affinity_label",
			"familiarity_level",
			"familiarity_label",
			"conversation_count",
			"attack_count",
			"last_change",
		],
		path,
		errors,
	)
	var affinity: Variant = relationship.get("affinity")
	if typeof(affinity) != TYPE_INT or int(affinity) < 0 or int(affinity) > 100:
		errors.append("%s.affinity 必须是 0 到 100 的整数" % path)
	for field_name in ["affinity_label", "familiarity_label", "last_change"]:
		if typeof(relationship.get(field_name)) != TYPE_STRING:
			errors.append("%s.%s 必须是文本" % [path, field_name])
	var familiarity_level: Variant = relationship.get("familiarity_level")
	if (
		typeof(familiarity_level) != TYPE_INT
		or int(familiarity_level) < 0
		or int(familiarity_level) > 5
	):
		errors.append("%s.familiarity_level 必须是 0 到 5 的整数" % path)
	for field_name in ["conversation_count", "attack_count"]:
		var count: Variant = relationship.get(field_name)
		if typeof(count) != TYPE_INT or int(count) < 0:
			errors.append("%s.%s 必须是非负整数" % [path, field_name])


static func _validate_turn(value: Variant, path: String, errors: Array[String]) -> void:
	if typeof(value) != TYPE_DICTIONARY:
		errors.append("%s 必须是对象" % path)
		return
	var turn := value as Dictionary
	if not turn.has("turn_id"):
		errors.append("%s.turn_id 缺失" % path)
	elif typeof(turn["turn_id"]) != TYPE_INT or int(turn["turn_id"]) <= 0:
		errors.append("%s.turn_id 必须是正整数" % path)
	AgentContractIdentity._validate_resident_id(turn, "speaker_resident_id", "%s.speaker_resident_id" % path, errors)
	AgentContract._require_non_empty_string(turn, "speaker", "%s.speaker" % path, errors)
	AgentContractAction._validate_say_and_narration(turn, path, errors)
	AgentContractAction._validate_photos(turn, path, {}, errors, false)
