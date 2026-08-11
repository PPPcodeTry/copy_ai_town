extends "res://tests/support/TownWorldTestCase.gd"


const AGENT_SOUL_PROFILE := preload("res://agent/soul/AgentSoulProfile.gd")
const AGENT_CONTRACT := preload("res://agent/AgentContract.gd")
const GAME_FLOW_HOST := preload(
	"res://world/presentation/game_flow/GameFlowHost.gd"
)
const RESIDENT_REPLACEMENT := preload(
	"res://world/runtime/lifecycle/TownResidentReplacementAdmission.gd"
)


class NeverCompletingProvider:
	extends RefCounted
	var callback := Callable()

	func request_json(_request: Dictionary, on_complete: Callable) -> void:
		callback = on_complete

	func complete(result: Dictionary) -> void:
		if callback.is_valid():
			callback.call(result.duplicate(true))


class ReplacementProviderService:
	extends RefCounted
	var provider: NeverCompletingProvider

	func _init(value: NeverCompletingProvider) -> void:
		provider = value

	func create_provider_for_resident(_binding: Dictionary) -> Dictionary:
		return {
			"ok": true,
			"errorCode": "",
			"retryable": false,
			"provider": provider,
		}


class GameFlowRecoveryHarness:
	extends "res://world/presentation/game_flow/GameFlowHost.gd"
	var presented_replacements: Array[Dictionary] = []
	var continued_quit_messages: Array[Array] = []

	func _present_generated_replacement(candidate: Dictionary) -> void:
		presented_replacements.append(candidate.duplicate(true))

	func _continue_quit_after_optional_messages(
		messages: Array,
		_execute_process_quit: bool,
	) -> Dictionary:
		continued_quit_messages.append(messages.duplicate(true))
		_quit_departure_pending = false
		_quit_departure_id = ""
		return {"ok": true, "errorCode": "", "retryable": false}


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var data := _build_data()
	var opening := _load_opening(data)
	var identities: Array[Dictionary] = []
	for resident_value: Variant in opening.get("residents", []) as Array:
		var resident := resident_value as Dictionary
		identities.append({
			"residentId": String(resident.get("residentId", "")),
			"residentName": String(
				(resident.get("attributes", {}) as Dictionary).get("name", "")
			),
		})
	var world := WORLD.new()
	var started := world.start(data, opening, identities) as Dictionary
	_expect(
		bool(started.get("ok", false)),
		"世界可以启动：%s" % JSON.stringify(started.get("errors", [])),
	)
	var deceased := identities[0]
	var deceased_name := String(deceased.get("residentName", ""))
	var death := world.confirm_resident_death(
		String(deceased.get("residentId", "")),
		"测试确认的死亡原因",
	) as Dictionary
	_expect(bool(death.get("ok", false)), "居民死亡可以确认")
	var death_event_id := String(
		(death.get("event", {}) as Dictionary).get("event_id", "")
	)
	_verify_async_recovery(opening, death.get("event", {}) as Dictionary)
	var record := ((opening.get("residents", []) as Array)[0] as Dictionary).duplicate(true)
	record["residentId"] = String(deceased.get("residentId", ""))
	var attributes := (record.get("attributes", {}) as Dictionary).duplicate(true)
	attributes["name"] = "补位测试居民"
	record["attributes"] = attributes
	var host := GAME_FLOW_HOST.new()
	host.set("_pending_replacement_candidate", {
		"record": record.duplicate(true),
		"identity": {
			"residentId": String(deceased.get("residentId", "")),
			"residentName": "补位测试居民",
		},
		"binding": {
			"residentId": String(deceased.get("residentId", "")),
			"residentName": "补位测试居民",
		},
	})
	var editor_attributes := attributes.duplicate(true)
	editor_attributes["selectionSummary"] = "UI 列表摘要"
	host.call("_merge_replacement_editor_source", {
		"attributes": editor_attributes,
		"occupation": {},
		"presentation": {},
	})
	var merged_record := (
		(host.get("_pending_replacement_candidate") as Dictionary)
		.get("record", {}) as Dictionary
	)
	_expect(
		not (merged_record.get("attributes", {}) as Dictionary).has(
			"selectionSummary",
		),
		"入镇编辑不会把 UI 专用摘要带入正式居民资料",
	)
	host.free()
	var invalid_record := record.duplicate(true)
	var invalid_attributes := (
		invalid_record.get("attributes", {}) as Dictionary
	).duplicate(true)
	invalid_attributes["selectionSummary"] = "UI 列表摘要"
	invalid_record["attributes"] = invalid_attributes
	var invalid_preview := RESIDENT_REPLACEMENT.preview_agent_initialization(
		world,
		invalid_record,
		String(deceased.get("residentId", "")),
	) as Dictionary
	_expect(bool(invalid_preview.get("ok", false)), "World 可以无副作用预览补位 Agent 资料")
	_expect(
		not AGENT_CONTRACT.validate_initialization(
			invalid_preview.get("initialization", {}),
		).is_empty(),
		"Agent 预检会拒绝泄漏的 UI 字段",
	)
	_expect_equal(RESIDENT_REPLACEMENT.living_resident_count(world), 14, "预检失败前 World 不会提前补位")
	var same_name_record := record.duplicate(true)
	var same_name_attributes := (
		same_name_record.get("attributes", {}) as Dictionary
	).duplicate(true)
	same_name_attributes["name"] = deceased_name
	same_name_record["attributes"] = same_name_attributes
	var same_name_validation := RESIDENT_REPLACEMENT.validate(
		world,
		same_name_record,
		String(deceased.get("residentId", "")),
	) as Dictionary
	_expect(
		bool(same_name_validation.get("ok", false)),
		"补位可以复用已经死亡居民的姓名",
	)
	var admitted := RESIDENT_REPLACEMENT.admit(
		world,
		record,
		String(deceased.get("residentId", "")),
	) as Dictionary
	_expect(bool(admitted.get("ok", false)), "补位居民可以进入运行中的世界")
	_expect_equal(RESIDENT_REPLACEMENT.living_resident_count(world), 15, "补位后恢复十五名在世居民")
	_expect_equal(world.get_resident_ids().size(), 15, "新居民接替原有住宅席位")
	_expect_equal(
		(world.get_resident_state(String(deceased.get("residentId", ""))) as Dictionary).get("name"),
		"补位测试居民",
		"同一住宅席位已换成新居民身份",
	)
	_expect_equal(world.get_public_death_events(), [], "完成补位后不再重复处理同一死亡事件")
	var historical_death_name := ""
	for event_value: Variant in world.get_public_event_log():
		if not event_value is Dictionary:
			continue
		var event := event_value as Dictionary
		if String(event.get("eventId", "")) == death_event_id:
			historical_death_name = String(event.get("residentName", ""))
			break
	_expect_equal(
		historical_death_name,
		deceased_name,
		"补位后的死亡历史仍保留死者姓名",
	)
	_expect(
		not world.get_agent_initialization_by_id(
			String(deceased.get("residentId", "")),
		).is_empty(),
		"新居民具备 Agent 初始化资料",
	)
	var save_result := world.create_save_snapshot() as Dictionary
	_expect(bool(save_result.get("ok", false)), "补位后的世界可以保存")
	var restored_opening := opening.duplicate(true)
	var restored_residents := (
		(restored_opening.get("residents", []) as Array).duplicate(true)
	)
	restored_residents[0] = record.duplicate(true)
	restored_opening["residents"] = restored_residents
	restored_opening["agentSoulProfiles"] = AGENT_SOUL_PROFILE.analyze_all(
		restored_residents,
	)
	var restored_identities := identities.duplicate(true)
	restored_identities[0] = {
		"residentId": String(deceased.get("residentId", "")),
		"residentName": "补位测试居民",
	}
	world.stop()
	var restored_world := WORLD.new()
	var restored := restored_world.restore_from_snapshot(
		data,
		restored_opening,
		(save_result.get("snapshot", {}) as Dictionary).duplicate(true),
		restored_identities,
	) as Dictionary
	_expect(
		bool(restored.get("ok", false)),
		"补位后的世界存档可以恢复：%s" % JSON.stringify(restored),
	)
	_expect_equal(RESIDENT_REPLACEMENT.living_resident_count(restored_world), 15, "读档后仍保持十五名在世居民")
	_expect_equal(
		(restored_world.get_resident_state(String(deceased.get("residentId", ""))) as Dictionary).get("name"),
		"补位测试居民",
		"读档后保留新居民身份",
	)
	restored_world.stop()
	_finish_suite("RESIDENT_REPLACEMENT_PASS")


func _verify_async_recovery(
	opening: Dictionary,
	death_event: Dictionary,
) -> void:
	var provider := NeverCompletingProvider.new()
	var provider_service := ReplacementProviderService.new(provider)
	var host := GameFlowRecoveryHarness.new()
	var resident_id := String(death_event.get("deceased_resident_id", ""))
	var binding := {
		"residentId": resident_id,
		"residentName": "待补位居民",
	}
	host.set("_provider_service", provider_service)
	host.set("_active_session_config", {
		"openingConfig": opening.duplicate(true),
		"residentBindings": [binding.duplicate(true)],
	})
	host.call(
		"_begin_replacement_persona_generation",
		death_event.duplicate(true),
	)
	_expect_equal(
		host.get("_replacement_generation_pending"),
		true,
		"补位资料请求未回调时保持等待状态",
	)
	var generation_id := int(host.get("_active_replacement_generation_id"))
	host.call(
		"_on_replacement_persona_timeout",
		generation_id,
		death_event.duplicate(true),
		binding.duplicate(true),
	)
	_expect_equal(
		host.get("_replacement_generation_pending"),
		false,
		"补位资料请求超时后解除等待状态",
	)
	_expect_equal(
		host.presented_replacements.size(),
		1,
		"补位资料请求超时后生成一份本地默认候选人",
	)
	_expect(
		not host.presented_replacements[0].is_empty(),
		"补位资料超时使用的本地候选人资料完整",
	)
	provider.complete({"ok": true, "json": {"name": "迟到居民"}})
	_expect_equal(
		host.presented_replacements.size(),
		1,
		"补位资料超时后的迟到回调不会重复弹出候选人",
	)

	host.set("_quit_departure_pending", true)
	host.set("_quit_departure_id", "departure-timeout")
	host.set("_quit_execute_process", false)
	host.call(
		"_on_quit_departure_messages_timeout",
		"departure-timeout",
	)
	_expect_equal(
		host.continued_quit_messages.size(),
		1,
		"退出留言不回调时按超时继续退出流程",
	)
	_expect_equal(
		host.continued_quit_messages[0],
		[],
		"退出留言超时后不携带未确认留言",
	)
	host.call(
		"_on_quit_departure_messages_ready",
		{"ok": true, "messages": [{"text": "迟到留言"}]},
		"departure-timeout",
	)
	_expect_equal(
		host.continued_quit_messages.size(),
		1,
		"退出留言超时后的迟到回调不会重复执行退出",
	)

	host.set("_quit_departure_pending", true)
	host.set("_quit_departure_id", "departure-success")
	host.call(
		"_on_quit_departure_messages_ready",
		{"ok": true, "messages": [{"text": "按时留言"}]},
		"departure-success",
	)
	_expect_equal(
		host.continued_quit_messages.size(),
		2,
		"按时返回的退出留言正常继续退出流程",
	)
	host.call(
		"_on_quit_departure_messages_timeout",
		"departure-success",
	)
	_expect_equal(
		host.continued_quit_messages.size(),
		2,
		"退出已经继续后，旧超时不会再次结算",
	)
	host.free()
