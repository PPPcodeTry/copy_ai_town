extends "res://tests/agent/support/AgentPromptTestCase.gd"


func _initialize() -> void:
	var compiler_script := _load_prompt_compiler()
	if compiler_script != null:
		_test_overheard_conversation_keeps_both_participants(compiler_script)
		_test_photo_content_is_separate_one_time_request(compiler_script)
		_test_overheard_photo_is_not_sent_to_model(compiler_script)
		_test_clinic_photo_is_not_sent_to_model(compiler_script)
	_finish_prompt_test("AGENT_MULTIMODAL_PROMPT_PASS")


func _test_overheard_conversation_keeps_both_participants(compiler_script: Script) -> void:
	var wake := _wake_packet("overheard-1", "晴天")
	wake["events"] = [{
		"event_id": "overheard-event-1",
		"time": {"day": 1, "clock": "08:10", "period": "上午"},
		"type": "旁听",
		"conversation_id": "conversation-overheard",
		"speaker_resident_ids": [
			"resident-tang-xiao-man",
			"person-avatar-7",
		],
		"speakers": ["唐小满", "阿澈"],
		"turn": {
			"turn_id": 1,
			"speaker_resident_id": "resident-tang-xiao-man",
			"speaker": "唐小满",
			"say": "阿澈，你见过那只猫吗？",
			"narration": "",
			"photos": [],
		},
	}]
	var compiler: RefCounted = compiler_script.new(_initialization())
	var request: Dictionary = compiler.call("compile", wake, "")
	var messages := request.get("messages", []) as Array
	var user_text := String((messages[1] as Dictionary).get("content", ""))
	_expect(
		user_text.contains("resident-tang-xiao-man｜唐小满")
		and user_text.contains("person-avatar-7｜阿澈"),
		"decision prompt keeps both confirmed participants of an overheard conversation",
	)

func _test_photo_content_is_separate_one_time_request(compiler_script: Script) -> void:
	var resolver := FakePhotoContentResolver.new()
	var compiler: RefCounted = compiler_script.new(
		_initialization(),
		"res://prompts",
		resolver,
		"person-avatar-7",
	)
	var wake := _wake_packet("photo-input-1", "晴天")
	wake["snapshot"]["conversation"] = {
		"conversation_id": "conversation-photo",
		"with_resident_id": "person-avatar-7",
		"with": "阿澈",
		"turns": [{
			"turn_id": 0,
			"speaker_resident_id": "person-avatar-7",
			"speaker": "阿澈",
			"say": "之前也给你看过一张图。",
			"narration": "",
			"photos": [{"ref": "old-photo-1", "mime_type": "image/png"}],
		}],
	}
	wake["events"] = [{
		"event_id": "photo-turn-1",
		"time": {"day": 1, "clock": "08:10", "period": "上午"},
		"type": "搭话",
		"conversation_id": "conversation-photo",
		"turn": {
			"turn_id": 1,
			"speaker_resident_id": "person-avatar-7",
			"speaker": "阿澈",
			"say": "你见过这只猫吗？",
			"narration": "递来一张照片。",
			"photos": [{"ref": "chat-photo-37", "mime_type": "image/png"}],
		},
	}]
	var request: Dictionary = compiler.call("compile", wake, "")
	var messages := request.get("messages", []) as Array
	var content: Variant = (messages[1] as Dictionary).get("content")
	_expect_equal(typeof(content), TYPE_STRING, "normal decision receives text-only content")
	_expect(
		not String(content).contains("data:image/")
		and not String(content).contains("chat-photo-37"),
		"normal decision does not retain image data or photo refs",
	)
	var photo_inputs := compiler.call("photo_inputs_for_wake", wake) as Array
	_expect_equal(photo_inputs.size(), 1, "direct player chat exposes one transient photo input")
	_expect_equal(resolver.calls, [], "selecting a photo does not resolve it during normal compilation")
	var photo_request := compiler.call(
		"build_photo_description_request",
		photo_inputs,
	) as Dictionary
	_expect_equal(photo_request.get("request_kind"), "photo_description", "photo conversion has its own request kind")
	var photo_messages := photo_request.get("messages", []) as Array
	var photo_content: Variant = (photo_messages[1] as Dictionary).get("content")
	_expect_equal(typeof(photo_content), TYPE_ARRAY, "only the one-time description request is multimodal")
	if photo_content is Array:
		var parts := photo_content as Array
		_expect_equal(parts.size(), 2, "description request sends one text part and one image part")
		if parts.size() == 2:
			_expect(
				String(((parts[1] as Dictionary).get("image_url", {}) as Dictionary).get("url", ""))
				.begins_with("data:image/png;base64,"),
				"description request resolves photo bytes exactly once",
			)
	_expect_equal(
		resolver.calls,
		[{"ref": "chat-photo-37", "mime_type": "image/png"}],
		"prompt compiler resolves each referenced photo once for conversion",
	)
	var compiled_wake := request.get("wake_packet", {}) as Dictionary
	var compiled_snapshot := compiled_wake.get("snapshot", {}) as Dictionary
	var compiled_conversation := compiled_snapshot.get("conversation", {}) as Dictionary
	var compiled_history := compiled_conversation.get("turns", []) as Array
	_expect_equal(
		(compiled_history[0] as Dictionary).get("photos", []),
		[],
		"old conversation photos are removed from the decision model wake",
	)
	var compiled_event := (compiled_wake.get("events", []) as Array)[0] as Dictionary
	_expect_equal(
		(compiled_event.get("turn", {}) as Dictionary).get("photos", []),
		[],
		"current photo refs are removed from the normal decision wake",
	)
	var missing_resolver: RefCounted = compiler_script.new(
		_initialization(),
		"res://prompts",
		null,
		"person-avatar-7",
	)
	var missing_request := missing_resolver.call("compile", wake, "") as Dictionary
	_expect_equal(
		missing_request.get("request_kind"),
		"resident_decision",
		"normal decision does not fail just because no photo resolver is configured",
	)
	_expect_equal(
		missing_resolver.call("build_photo_description_request", photo_inputs).get("ok"),
		false,
		"photo conversion fails explicitly when no content resolver is connected",
	)


func _test_overheard_photo_is_not_sent_to_model(compiler_script: Script) -> void:
	var resolver := FakePhotoContentResolver.new()
	var compiler: RefCounted = compiler_script.new(
		_initialization(),
		"res://prompts",
		resolver,
		"person-avatar-7",
	)
	var wake := _wake_packet("overheard-photo-1", "晴天")
	wake["events"] = [{
		"event_id": "overheard-photo-event-1",
		"time": {"day": 1, "clock": "08:10", "period": "上午"},
		"type": "旁听",
		"conversation_id": "conversation-overheard-photo",
		"speaker_resident_ids": ["resident-tang-xiao-man", "person-avatar-7"],
		"speakers": ["唐小满", "阿澈"],
		"turn": {
			"turn_id": 1,
			"speaker_resident_id": "person-avatar-7",
			"speaker": "阿澈",
			"say": "你看这张照片。",
			"narration": "",
			"photos": [{"ref": "overheard-photo-1", "mime_type": "image/png"}],
		},
	}]
	var request: Dictionary = compiler.call("compile", wake, "")
	var messages := request.get("messages", []) as Array
	_expect_equal(
		typeof((messages[1] as Dictionary).get("content")),
		TYPE_STRING,
		"overheard photos stay out of the decision model input",
	)
	_expect_equal(resolver.calls, [], "overheard photos are not resolved")
	var compiled_wake := request.get("wake_packet", {}) as Dictionary
	var event := (compiled_wake.get("events", []) as Array)[0] as Dictionary
	_expect_equal(
		(event.get("turn", {}) as Dictionary).get("photos", []),
		[],
		"overheard photo references are removed from the model wake",
	)


func _test_clinic_photo_is_not_sent_to_model(compiler_script: Script) -> void:
	var resolver := FakePhotoContentResolver.new()
	var compiler: RefCounted = compiler_script.new(
		_initialization(),
		"res://prompts",
		resolver,
		"person-avatar-7",
	)
	var wake := _wake_packet("clinic-photo-1", "晴天")
	wake["snapshot"]["conversation"] = {
		"conversation_id": "conversation-clinic-photo",
		"with_resident_id": "person-avatar-7",
		"with": "阿澈",
		"turns": [],
		"medical_context": {
			"request_id": "clinic-request-1",
			"role": "clinician",
			"status": "active",
			"reported_summary": "手腕疼痛",
		},
	}
	wake["events"] = [{
		"event_id": "clinic-photo-event-1",
		"time": {"day": 1, "clock": "08:10", "period": "上午"},
		"type": "对方答话",
		"conversation_id": "conversation-clinic-photo",
		"turn": {
			"turn_id": 1,
			"speaker_resident_id": "person-avatar-7",
			"speaker": "阿澈",
			"say": "我拍了伤口给你看。",
			"narration": "",
			"photos": [{"ref": "clinic-photo-1", "mime_type": "image/png"}],
		},
	}]
	var request: Dictionary = compiler.call("compile", wake, "")
	var messages := request.get("messages", []) as Array
	_expect_equal(
		typeof((messages[1] as Dictionary).get("content")),
		TYPE_STRING,
		"clinic conversation photos stay out of the decision model input",
	)
	_expect_equal(resolver.calls, [], "clinic photos are not resolved")
