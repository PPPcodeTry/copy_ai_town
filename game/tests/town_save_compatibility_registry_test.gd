extends SceneTree

const REGISTRY := preload(
	"res://world/presentation/session/TownSaveCompatibilityRegistry.gd"
)

var _failures: Array[String] = []
var _checks := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_module_descriptors_cover_migration_scope()
	_test_release_detection_uses_contract_evidence()
	_test_release_detection_distinguishes_failure_types()
	_test_migration_path_is_ordered_and_explicit()
	_finish()


func _test_module_descriptors_cover_migration_scope() -> void:
	var modules := REGISTRY.module_descriptors()
	var policies := {}
	for module_value: Variant in modules:
		var module := module_value as Dictionary
		policies[String(module.get("id", ""))] = String(
			module.get("policy", "")
		)
	_expect_equal(
		policies,
		{
			"startup_profile": "required",
			"session_manifest": "required",
			"session_config": "required",
			"world_snapshot": "required",
			"world_log": "required",
			"agent_snapshot": "required",
			"resident_payload": "required",
			"resident_memory": "required",
			"conversation_photos": "required",
			"custom_resident_library": "required",
			"provider_config": "best_effort",
			"player_settings": "best_effort",
			"legacy_audio_settings": "best_effort",
			"provider_credentials": "excluded",
			"device_and_transaction_state": "excluded",
		},
		"兼容注册表覆盖已确认的迁移范围",
	)
	_expect_equal(
		REGISTRY.validate_registry(),
		[],
		"兼容注册表内部声明完整",
	)
	var world_snapshot := _module_by_id(modules, "world_snapshot")
	_expect_equal(
		world_snapshot.get("versions"),
		{
			"world": {"current": 2, "supported": [1, 2]},
			"worldData": {"current": 4, "supported": [4]},
		},
		"模块描述返回当前版本和支持范围",
	)
	_expect_equal(
		(_module_by_id(modules, "session_config")).get("versions"),
		{},
		"无独立版本的模块明确返回空版本表",
	)


func _test_release_detection_uses_contract_evidence() -> void:
	var beta1 := REGISTRY.detect_release(_release_evidence(
		26,
		"584ba4b89019f92378131a56bc380e0c2dec5e460d977d7050484996a9c57a9f",
		"raw",
	))
	_expect_equal(beta1.get("ok"), true, "beta1 版本组合可识别")
	_expect_equal(beta1.get("supportStatus"), "supported", "beta1 仍受支持")
	_expect_equal(beta1.get("release"), "beta1", "原始 ID 路径确定为 beta1")
	_expect_equal(beta1.get("releaseRange"), ["beta1"], "beta1 识别范围唯一")

	var beta2 := REGISTRY.detect_release(_release_evidence(
		26,
		"584ba4b89019f92378131a56bc380e0c2dec5e460d977d7050484996a9c57a9f",
		"hashed",
	))
	_expect_equal(beta2.get("release"), "beta2", "哈希路径确定为 beta2")
	var beta1_or_beta2 := REGISTRY.detect_release(_release_evidence(
		26,
		"584ba4b89019f92378131a56bc380e0c2dec5e460d977d7050484996a9c57a9f",
		"",
	))
	_expect_equal(
		beta1_or_beta2.get("releaseRange"),
		["beta1", "beta2"],
		"缺少路径证据时保留 beta1 至 beta2 范围",
	)

	var shared_contract := REGISTRY.detect_release(_release_evidence(
		27,
		"70dcd511461e5266174f3ddb5323d2adf4ecd5caf38cf25d7ba886ead3e3b818",
		"hashed",
	))
	_expect_equal(
		shared_contract.get("releaseRange"),
		["beta3", "beta4", "beta5", "beta6"],
		"磁盘字段相同的 beta3 至 beta6 返回版本范围",
	)
	_expect_equal(shared_contract.get("exact"), false, "共享契约不能猜测发行版")
	_expect_equal(
		shared_contract.get("migrationStartRelease"),
		"beta3",
		"共享契约从最早候选节点保守执行幂等迁移",
	)

	var beta5_evidence := _release_evidence(
		27,
		"70dcd511461e5266174f3ddb5323d2adf4ecd5caf38cf25d7ba886ead3e3b818",
		"hashed",
	)
	beta5_evidence["recordedRelease"] = "beta5"
	var recorded_beta5 := REGISTRY.detect_release(beta5_evidence)
	_expect_equal(recorded_beta5.get("release"), "beta5", "样本来源可缩小合法范围")
	_expect_equal(recorded_beta5.get("exact"), true, "来源记录产生精确结果")
	var beta6_evidence := beta5_evidence.duplicate(true)
	beta6_evidence["recordedRelease"] = "beta6"
	_expect_equal(
		REGISTRY.detect_release(beta6_evidence).get("supportStatus"),
		"current",
		"精确识别的 beta6 返回当前状态",
	)


func _release_evidence(
	world_section_count: int,
	activity_source_fingerprint: String,
	resident_path_layout: String,
) -> Dictionary:
	return {
		"versions": {
			"world": 2,
			"manifest": 3,
			"profile": 2,
			"agent": 3,
			"residentPayload": 2,
			"residentRuntime": 6,
			"residentMemory": 6,
			"provider": 2,
			"worldData": 4,
		},
		"worldSectionCount": world_section_count,
		"activitySourceFingerprint": activity_source_fingerprint,
		"residentPathLayout": resident_path_layout,
	}


func _module_by_id(modules: Array, module_id: String) -> Dictionary:
	for module_value: Variant in modules:
		var module := module_value as Dictionary
		if String(module.get("id", "")) == module_id:
			return module
	return {}


func _test_release_detection_distinguishes_failure_types() -> void:
	_expect_equal(
		REGISTRY.ERROR_TYPES.get("damaged_save"),
		"SAVE_ARCHIVE_DAMAGED",
		"文件损坏保留独立错误类型供导入器使用",
	)
	var missing := REGISTRY.detect_release({})
	_expect_equal(
		(missing.get("error", {}) as Dictionary).get("type"),
		"invalid_evidence",
		"缺少证据单独归类",
	)

	var future_evidence := _release_evidence(
		27,
		"70dcd511461e5266174f3ddb5323d2adf4ecd5caf38cf25d7ba886ead3e3b818",
		"hashed",
	)
	(future_evidence.get("versions") as Dictionary)["world"] = 3
	var future := REGISTRY.detect_release(future_evidence)
	_expect_equal(future.get("supportStatus"), "read_only", "未来版本只读识别")
	_expect_equal(future.get("readOnly"), true, "未来版本禁止改写")
	_expect_equal(
		(future.get("error", {}) as Dictionary).get("code"),
		"SAVE_VERSION_NEWER_THAN_SUPPORTED",
		"未来版本返回稳定错误码",
	)
	var future_module_evidence := _release_evidence(
		27,
		"70dcd511461e5266174f3ddb5323d2adf4ecd5caf38cf25d7ba886ead3e3b818",
		"hashed",
	)
	(future_module_evidence.get("versions") as Dictionary)["futureModule"] = 1
	var future_module := REGISTRY.detect_release(future_module_evidence)
	_expect_equal(
		future_module.get("supportStatus"),
		"read_only",
		"未知的未来模块版本同样只读拒绝",
	)
	_expect_equal(
		(future_module.get("error", {}) as Dictionary).get("modules"),
		["futureModule"],
		"未来模块错误指出未知版本键",
	)

	var old_evidence := _release_evidence(
		26,
		"584ba4b89019f92378131a56bc380e0c2dec5e460d977d7050484996a9c57a9f",
		"raw",
	)
	(old_evidence.get("versions") as Dictionary)["agent"] = 2
	var old := REGISTRY.detect_release(old_evidence)
	_expect_equal(old.get("supportStatus"), "unsupported", "过旧版本明确拒绝")
	_expect_equal(
		(old.get("error", {}) as Dictionary).get("code"),
		"SAVE_VERSION_NO_LONGER_SUPPORTED",
		"过旧版本返回稳定错误码",
	)

	var unknown_evidence := _release_evidence(27, "unknown-fingerprint", "hashed")
	var unknown := REGISTRY.detect_release(unknown_evidence)
	_expect_equal(
		(unknown.get("error", {}) as Dictionary).get("type"),
		"unknown_combination",
		"未知版本组合不冒充损坏或过旧",
	)

	var mixed_versions := _release_evidence(
		26,
		"584ba4b89019f92378131a56bc380e0c2dec5e460d977d7050484996a9c57a9f",
		"raw",
	)
	(mixed_versions.get("versions") as Dictionary)["world"] = 1
	_expect_equal(
		(
			REGISTRY.detect_release(mixed_versions).get("error", {}) as Dictionary
		).get("type"),
		"unknown_combination",
		"单模块可读但未发行的混合版本不冒充 beta1",
	)

	var no_provider := _release_evidence(
		27,
		"70dcd511461e5266174f3ddb5323d2adf4ecd5caf38cf25d7ba886ead3e3b818",
		"hashed",
	)
	(no_provider.get("versions") as Dictionary).erase("provider")
	_expect_equal(
		REGISTRY.detect_release(no_provider).get("ok"),
		true,
		"缺少尽力迁移的 Provider 配置不阻断正式存档识别",
	)


func _test_migration_path_is_ordered_and_explicit() -> void:
	var full_path := REGISTRY.migration_path("beta1")
	_expect_equal(full_path.get("ok"), true, "beta1 到当前版存在迁移链")
	var edge_ids: Array[String] = []
	for edge_value: Variant in full_path.get("edges", []) as Array:
		edge_ids.append(String((edge_value as Dictionary).get("id", "")))
	_expect_equal(
		edge_ids,
		[
			"beta1-to-beta2",
			"beta2-to-beta3",
			"beta3-to-beta4",
			"beta4-to-beta5",
			"beta5-to-beta6",
		],
		"跳版本升级逐段执行",
	)
	var edges := full_path.get("edges", []) as Array
	_expect_equal(
		((edges[0] as Dictionary).get("modules", []) as Array).has("resident_memory"),
		true,
		"beta1 到 beta2 登记居民记忆路径迁移",
	)
	_expect_equal(
		((edges[1] as Dictionary).get("migrationIds", []) as Array).has(
			"2026-08-12-public-dining-day-routine"
		),
		true,
		"beta2 到 beta3 登记活动指纹迁移",
	)
	for edge_value: Variant in edges.slice(2):
		_expect_equal(
			(edge_value as Dictionary).get("kind"),
			"no_change",
			"无字段变化的发行边仍有明确声明",
		)

	var current := REGISTRY.migration_path("beta6")
	_expect_equal(current.get("edges"), [], "当前版本不产生迁移步骤")
	var missing := REGISTRY.migration_path("beta0")
	_expect_equal(
		(missing.get("error", {}) as Dictionary).get("code"),
		"SAVE_MIGRATION_PATH_MISSING",
		"迁移链缺失有独立错误码",
	)


func _expect_equal(actual: Variant, expected: Variant, message: String) -> void:
	_checks += 1
	if actual != expected:
		_failures.append("%s: expected=%s actual=%s" % [
			message,
			str(expected),
			str(actual),
		])


func _finish() -> void:
	_prepare_project_shutdown()
	if _failures.is_empty():
		print("TOWN_SAVE_COMPATIBILITY_REGISTRY_PASS checks=%d" % _checks)
		call_deferred("_quit_after_shutdown", 0)
		return
	for failure in _failures:
		printerr("TOWN_SAVE_COMPATIBILITY_REGISTRY_FAIL: %s" % failure)
	call_deferred("_quit_after_shutdown", 1)


func _prepare_project_shutdown() -> void:
	var audio_controller := get_root().get_node_or_null("TownAudioController")
	if audio_controller != null and audio_controller.has_method("prepare_shutdown"):
		audio_controller.call("prepare_shutdown")


func _quit_after_shutdown(exit_code: int) -> void:
	await process_frame
	_prepare_project_shutdown()
	await create_timer(0.5).timeout
	quit(exit_code)
