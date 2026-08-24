extends SceneTree


const INSPECTOR := preload(
	"res://world/presentation/session/TownSaveArchiveInspector.gd"
)

const BETA6_ROOT := "res://tests/fixtures/historical_saves/beta6"
const FILE_SYSTEM := preload("res://agent/AgentFileSystem.gd")

var _failures: Array[String] = []
var _checks := 0
var _test_roots: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_healthy_archive_is_inspected_without_writes()
	_test_shared_modules_and_photos_are_inspected()
	_test_beta1_to_beta6_release_evidence_is_supported()
	_test_activity_lifecycle_revisions_are_inspected()
	_test_long_path_archive_is_inspected()
	_test_optional_local_modules_are_recorded()
	_test_missing_custom_library_is_an_empty_library()
	_test_future_archive_is_read_only_not_damaged()
	_test_future_agent_store_is_read_only_not_damaged()
	_test_future_nested_module_versions_are_read_only()
	_test_unsupported_old_version_is_not_damage()
	_test_missing_version_is_damage()
	_test_unknown_supported_combination_is_not_damage()
	_test_world_version_evidence_comes_from_file()
	_test_world_and_agent_resident_sets_must_match()
	_test_component_contract_damage_is_localized()
	_test_world_log_segment_content_is_validated()
	_test_world_contract_damage_is_localized()
	_test_agent_slot_manifest_is_required()
	_test_agent_only_slot_is_enumerated()
	_test_missing_referenced_photo_is_reported()
	_test_shared_module_status_survives_without_slots()
	_test_orphaned_revision_directory_is_enumerated()
	_test_invalid_manifest_is_not_duplicated_as_orphan()
	_test_damaged_latest_revision_preserves_older_complete_evidence()
	_test_interrupted_transaction_is_reported_as_incomplete_revision()
	_test_invalid_transaction_record_is_preserved()
	_test_contextless_transaction_record_is_preserved()
	_test_completed_transaction_suppresses_early_damage()
	_test_allocation_without_manifest_is_preserved()
	_finish()


func _test_healthy_archive_is_inspected_without_writes() -> void:
	var before := _tree_fingerprint(BETA6_ROOT)
	var report := INSPECTOR.inspect(BETA6_ROOT)
	var after := _tree_fingerprint(BETA6_ROOT)

	_expect_equal(report.get("ok"), true, "beta6 存档完成只读检查")
	_expect_equal(report.get("readOnly"), true, "检查报告声明只读")
	_expect_equal(after, before, "检查前后源目录逐文件哈希不变")
	_expect_equal(report.get("status"), "healthy", "完整存档报告为健康")
	var slots := report.get("slots", []) as Array
	_expect_equal(slots.size(), 1, "检查器发现一个存档槽位")
	if slots.size() != 1:
		return
	var slot := slots[0] as Dictionary
	_expect_equal(slot.get("slotId"), "roundtrip-slot-beta6", "槽位身份来自存档内容")
	_expect_equal(slot.get("latestEvidenceRevision"), 1, "报告记录最新证据修订")
	_expect_equal(slot.get("latestCompleteRevision"), 1, "报告记录最新完整修订")
	var revisions := slot.get("revisions", []) as Array
	_expect_equal(revisions.size(), 1, "所有已发布修订均进入报告")
	if revisions.size() != 1:
		return
	var revision := revisions[0] as Dictionary
	_expect_equal(revision.get("status"), "complete", "World 与 Agent 完整对通过检查")
	_expect_equal(
		revision.get("versions"),
		{
			"world": 2,
			"manifest": 3,
			"profile": 2,
			"agent": 3,
			"residentPayload": 2,
			"residentRuntime": 6,
			"residentMemory": 6,
			"worldData": 4,
			"worldLog": 1,
			"customResidentLibrary": 1,
			"playerSettings": 1,
		},
		"报告提取迁移所需模块版本",
	)
	var compatibility := revision.get("compatibility", {}) as Dictionary
	_expect_equal(compatibility.get("ok"), true, "持久化证据可交给兼容注册表识别")
	_expect_equal(
		compatibility.get("releaseRange"),
		["beta3", "beta4", "beta5", "beta6"],
		"无发行元数据时保留可证明的版本范围",
	)
	var pair := revision.get("worldAgentPair", {}) as Dictionary
	_expect_equal(pair.get("sameContext"), true, "World 与 Agent 修订上下文一致")
	_expect_equal(pair.get("sameResidentSet"), true, "World 与 Agent 居民集合一致")
	_expect_equal((pair.get("manifestResidentIds", []) as Array).size(), 15, "报告保留 manifest 居民集合")
	_expect_equal(pair.get("worldResidentIds"), pair.get("manifestResidentIds"), "报告保留一致的 World 居民集合")
	_expect_equal(pair.get("agentResidentIds"), pair.get("manifestResidentIds"), "报告保留一致的 Agent 居民集合")
	_expect_equal(revision.get("transactionState"), "published", "报告记录发布事务状态")
	var hashes := revision.get("hashes", []) as Array
	_expect_equal(hashes.size(), 19, "修订报告保留配置、World、日志和 Agent 哈希证据")
	_expect_equal(
		_all_hashes_match(hashes),
		true,
		"所有已登记引用与文件哈希一致",
	)
	var session_assets := slot.get("sessionAssets", []) as Array
	_expect_equal(session_assets.size(), 1, "报告按会话聚合共享照片证据")
	_expect_equal(
		(((session_assets[0] as Dictionary).get("hashes", []) as Array).size()),
		1,
		"共享照片只计算一次内容哈希",
	)


func _test_shared_modules_and_photos_are_inspected() -> void:
	var healthy := INSPECTOR.inspect(BETA6_ROOT)
	_expect_equal(
		_has_module_state(
			healthy.get("moduleStates", []) as Array, "startup_profile", true,
		),
		true,
		"报告记录启动资料存在状态",
	)
	_expect_equal(
		(healthy.get("moduleVersions", {}) as Dictionary).get("customResidentLibrary"),
		1,
		"报告记录自定义居民库版本",
	)
	_expect_equal(
		_has_hash_module(healthy.get("moduleHashes", []) as Array, "custom_resident_library"),
		true,
		"报告记录自定义居民库文件哈希",
	)

	var future_root := _new_fixture_copy("future_library")
	_expect_equal(not future_root.is_empty(), true, "未来居民库测试副本可创建")
	var library_path := future_root.path_join("town_custom_resident_library.json")
	var library := _read_json(library_path)
	library["schemaVersion"] = 2
	_expect_equal(_write_json(library_path, library), OK, "测试副本可标记未来居民库版本")
	var future_report := INSPECTOR.inspect(future_root)
	_expect_equal(future_report.get("status"), "read_only", "未来居民库版本只读拒绝")
	_expect_equal(_first_revision(future_report).get("status"), "read_only", "未来居民库不误判坏档")

	var photo_root := _new_fixture_copy("photo")
	_expect_equal(not photo_root.is_empty(), true, "照片损坏测试副本可创建")
	var photo_directory := DirAccess.open(photo_root.path_join(
		"town_conversation_photos/roundtrip-slot-beta6/roundtrip-session-beta6",
	))
	var photo_path := photo_root.path_join(
		"town_conversation_photos/roundtrip-slot-beta6/roundtrip-session-beta6",
	).path_join(photo_directory.get_files()[0])
	_expect_equal(_write_text(photo_path, "corrupt-photo"), OK, "测试副本可损坏会话照片")
	var photo_report := INSPECTOR.inspect(photo_root)
	var photo_revision := _first_revision(photo_report)
	var photo_slot := (photo_report.get("slots", []) as Array)[0] as Dictionary
	_expect_equal(photo_revision.get("status"), "complete", "未被引用的坏照片不污染历史修订")
	_expect_equal(
		_has_module_issue(
			photo_slot.get("issues", []) as Array,
			"conversation_photos",
		),
		true,
		"照片损坏证据定位到会话照片",
	)


func _test_beta1_to_beta6_release_evidence_is_supported() -> void:
	for beta in range(1, 7):
		var source := "res://tests/fixtures/historical_saves/beta%d" % beta
		var report := INSPECTOR.inspect(source)
		var slot := (report.get("slots", []) as Array)[0] as Dictionary
		var revision := (slot.get("revisions", []) as Array)[0] as Dictionary
		var compatibility := revision.get("compatibility", {}) as Dictionary
		var expected_range := (
			["beta1", "beta2"]
			if beta <= 2
			else ["beta3", "beta4", "beta5", "beta6"]
		)
		_expect_equal(report.get("status"), "healthy", "beta%d 不误判为坏档" % beta)
		_expect_equal(revision.get("status"), "complete", "beta%d 修订完整" % beta)
		_expect_equal(
			compatibility.get("releaseRange"),
			expected_range,
			"beta%d 使用存档字段可证明的发行范围" % beta,
		)
		_expect_equal(
			(revision.get("migrationPath", {}) as Dictionary).get("ok"),
			true,
			"beta%d 到 beta6 的迁移链完整" % beta,
		)


func _test_activity_lifecycle_revisions_are_inspected() -> void:
	var activity_report := INSPECTOR.inspect(
		"res://tests/fixtures/historical_saves/beta5-activity-lifecycle",
	)
	var activity_revisions := (
		((activity_report.get("slots", []) as Array)[0] as Dictionary)
		.get("revisions", []) as Array
	)
	_expect_equal(activity_report.get("status"), "healthy", "活动生命周期样本完整")
	_expect_equal(activity_revisions.size(), 3, "活动生命周期样本的三个修订均被枚举")
	_expect_equal(_all_revisions_complete(activity_revisions), true, "活动生命周期修订均完成校验")
	_expect_equal(
		((activity_revisions[0] as Dictionary).get("hashes", []) as Array).size(),
		20,
		"活动生命周期样本校验 world log 分段引用",
	)
	var assets := (
		((activity_report.get("slots", []) as Array)[0] as Dictionary)
		.get("sessionAssets", []) as Array
	)
	_expect_equal(assets.size(), 1, "同一会话的照片只扫描一次")


func _test_long_path_archive_is_inspected() -> void:
	var long_path_report := INSPECTOR.inspect(
		"res://tests/fixtures/historical_saves/beta5-long-path",
	)
	_expect_equal(long_path_report.get("status"), "healthy", "长路径样本完成只读检查")
	_expect_equal(_first_revision(long_path_report).get("status"), "complete", "长路径修订完整")


func _test_optional_local_modules_are_recorded() -> void:
	var test_root := _new_fixture_copy("local_modules")
	_expect_equal(not test_root.is_empty(), true, "本机配置测试副本可创建")
	_expect_equal(_write_json(test_root.path_join("provider_settings.json"), {
		"schemaVersion": 2,
		"selectedProviderId": "",
		"selectedModelByProvider": {},
		"providers": {},
	}), OK, "测试副本可写入 Provider 配置")
	_expect_equal(_write_text(test_root.path_join("player_settings.cfg"), (
		"[meta]\n\nschema_version=1\n\n[audio]\n\nmaster_percent=100\n"
	)), OK, "测试副本可写入玩家设置")
	_expect_equal(_write_text(test_root.path_join("audio_settings.cfg"), (
		"[audio]\n\nmaster_percent=100\n"
	)), OK, "测试副本可写入旧声音设置")
	var report := INSPECTOR.inspect(test_root)
	var versions := report.get("moduleVersions", {}) as Dictionary
	_expect_equal(versions.get("provider"), 2, "报告记录 Provider 版本")
	_expect_equal(versions.get("playerSettings"), 1, "报告记录玩家设置版本")
	_expect_equal(
		_has_hash_module(report.get("moduleHashes", []) as Array, "provider_config"),
		true,
		"报告记录 Provider 配置哈希",
	)
	_expect_equal(
		_has_module_state(report.get("moduleStates", []) as Array, "legacy_audio_settings", true),
		true,
		"报告记录无独立版本的旧声音设置",
	)


func _test_missing_custom_library_is_an_empty_library() -> void:
	var test_root := _new_fixture_copy("missing_custom_library")
	_expect_equal(not test_root.is_empty(), true, "空自定义居民库测试副本可创建")
	_expect_equal(
		DirAccess.remove_absolute(ProjectSettings.globalize_path(
			test_root.path_join("town_custom_resident_library.json"),
		)),
		OK,
		"测试副本可移除自定义居民库文件",
	)
	var report := INSPECTOR.inspect(test_root)
	_expect_equal(report.get("status"), "healthy", "缺少自定义居民库按空库处理")
	_expect_equal(
		(report.get("moduleVersions", {}) as Dictionary).has("customResidentLibrary"),
		false,
		"空库不伪造版本证据",
	)
	_expect_equal(
		_has_module_state(
			report.get("moduleStates", []) as Array,
			"custom_resident_library",
			false,
		),
		true,
		"报告明确记录自定义居民库不存在",
	)


func _test_future_archive_is_read_only_not_damaged() -> void:
	var test_root := _new_fixture_copy("future")
	_expect_equal(not test_root.is_empty(), true, "未来版本测试副本可创建")
	var manifest_path := _fixture_manifest_path(test_root)
	var manifest := _fixture_manifest(test_root)
	manifest["schema_version"] = 4
	manifest.erase("components")
	manifest.erase("session_config_ref")
	manifest.erase("resident_ids")
	_expect_equal(_write_json(manifest_path, manifest), OK, "测试副本可标记为未来 manifest 版本")
	var before := _tree_fingerprint(test_root)
	var report := INSPECTOR.inspect(test_root)
	var after := _tree_fingerprint(test_root)
	_expect_equal(report.get("ok"), true, "未来版本仍能形成检查报告")
	_expect_equal(report.get("status"), "read_only", "未来版本只读拒绝")
	_expect_equal(report.get("supportStatus"), "read_only", "报告保留未来版本支持状态")
	_expect_equal(after, before, "未来版本检查也不改写源目录")
	var revision := _first_revision(report)
	_expect_equal(revision.get("status"), "read_only", "未来修订不标记为损坏")
	_expect_equal(
		((revision.get("compatibility", {}) as Dictionary).get("error", {}) as Dictionary).get("code"),
		"SAVE_VERSION_NEWER_THAN_SUPPORTED",
		"未来版本使用稳定错误码",
	)
	_expect_equal(_has_issue_type(revision.get("issues", []) as Array, "damaged_save"), false, "未来版本不会产生坏档证据")


func _test_future_agent_store_is_read_only_not_damaged() -> void:
	var test_root := _new_fixture_copy("future_agent")
	_expect_equal(not test_root.is_empty(), true, "未来 Agent 测试副本可创建")
	var slot_path := test_root.path_join("agent_saves/roundtrip-slot-beta6/slot.json")
	var slot_manifest := _read_json(slot_path)
	slot_manifest["format_version"] = 4
	_expect_equal(_write_json(slot_path, slot_manifest), OK, "测试副本可标记未来 Agent 槽位版本")
	var report := INSPECTOR.inspect(test_root)
	var revision := _first_revision(report)
	_expect_equal(report.get("status"), "read_only", "未来 Agent 版本只读拒绝")
	_expect_equal(revision.get("status"), "read_only", "未来 Agent 版本不标记为损坏")
	_expect_equal((revision.get("versions", {}) as Dictionary).get("agent"), 4, "报告使用 Agent 槽位版本证据")
	_expect_equal(_has_issue_type(revision.get("issues", []) as Array, "damaged_save"), false, "未来 Agent 版本不产生坏档证据")


func _test_future_nested_module_versions_are_read_only() -> void:
	var log_root := _new_fixture_copy("future_world_log")
	_expect_equal(not log_root.is_empty(), true, "未来 world log 测试副本可创建")
	var log_manifest := _fixture_manifest(log_root)
	var log_component := (
		(log_manifest.get("components", {}) as Dictionary).get("world_log", {}) as Dictionary
	)
	log_component["schema_version"] = 2
	log_component.erase("snapshot_ref")
	_expect_equal(_write_json(_fixture_manifest_path(log_root), log_manifest), OK, "测试副本可写入未来 world log 信封")
	var log_revision := _first_revision(INSPECTOR.inspect(log_root))
	_expect_equal(log_revision.get("status"), "read_only", "未来 world log 版本在解析布局前只读拒绝")
	_expect_equal(_has_issue_type(log_revision.get("issues", []) as Array, "damaged_save"), false, "未来 world log 布局不误判损坏")

	for version_key in ["residentPayload", "residentRuntime", "residentMemory"]:
		var test_root := _new_fixture_copy("future_%s" % version_key)
		_expect_equal(not test_root.is_empty(), true, "%s 未来版本测试副本可创建" % version_key)
		_expect_equal(
			_set_first_agent_nested_version(test_root, version_key),
			OK,
			"%s 可写入未来版本信封" % version_key,
		)
		var revision := _first_revision(INSPECTOR.inspect(test_root))
		_expect_equal(revision.get("status"), "read_only", "%s 未来版本只读拒绝" % version_key)
		_expect_equal(_has_issue_type(revision.get("issues", []) as Array, "damaged_save"), false, "%s 未来布局不误判损坏" % version_key)
	var tampered_root := _new_fixture_copy("tampered_future_payload")
	_expect_equal(not tampered_root.is_empty(), true, "伪造未来载荷测试副本可创建")
	_expect_equal(_tamper_first_agent_payload_version(tampered_root), OK, "测试副本可篡改未登记哈希的载荷版本")
	var tampered_revision := _first_revision(INSPECTOR.inspect(tampered_root))
	_expect_equal(tampered_revision.get("status"), "damaged", "未登记哈希的未来版本不能掩盖载荷损坏")
	_expect_equal(_has_module_issue(tampered_revision.get("issues", []) as Array, "resident_payload"), true, "伪造未来版本仍定位到载荷哈希")


func _test_unsupported_old_version_is_not_damage() -> void:
	var test_root := _new_fixture_copy("unsupported")
	_expect_equal(not test_root.is_empty(), true, "过旧版本测试副本可创建")
	var manifest := _fixture_manifest(test_root)
	manifest["schema_version"] = 0
	manifest.erase("components")
	manifest.erase("session_config_ref")
	manifest.erase("resident_ids")
	_expect_equal(_write_json(_fixture_manifest_path(test_root), manifest), OK, "测试副本可标记为过旧 manifest 版本")
	var report := INSPECTOR.inspect(test_root)
	var revision := _first_revision(report)
	_expect_equal(report.get("status"), "unsupported", "过旧版本与坏档分开报告")
	_expect_equal(report.get("supportStatus"), "unsupported", "报告保留停止支持状态")
	_expect_equal(revision.get("status"), "unsupported", "过旧修订不标记为损坏")
	_expect_equal(
		((revision.get("compatibility", {}) as Dictionary).get("error", {}) as Dictionary).get("code"),
		"SAVE_VERSION_NO_LONGER_SUPPORTED",
		"过旧版本使用稳定错误码",
	)
	_expect_equal(_has_issue_type(revision.get("issues", []) as Array, "damaged_save"), false, "过旧但完整的文件不产生坏档证据")


func _test_missing_version_is_damage() -> void:
	var test_root := _new_fixture_copy("missing_version")
	_expect_equal(not test_root.is_empty(), true, "缺失版本测试副本可创建")
	var manifest := _fixture_manifest(test_root)
	manifest.erase("schema_version")
	_expect_equal(_write_json(_fixture_manifest_path(test_root), manifest), OK, "测试副本可移除 manifest 版本")
	var revision := _first_revision(INSPECTOR.inspect(test_root))
	_expect_equal(revision.get("status"), "damaged", "缺失版本字段属于文件损坏")
	_expect_equal(_has_module_issue(revision.get("issues", []) as Array, "session_manifest"), true, "缺失版本证据定位到 manifest")


func _test_unknown_supported_combination_is_not_damage() -> void:
	var test_root := _new_fixture_copy("unknown")
	_expect_equal(not test_root.is_empty(), true, "未知组合测试副本可创建")
	var world_reference := (
		"slots/roundtrip-slot-beta6/sessions/roundtrip-session-beta6/"
		+ "revisions/00000000000000000001/world_snapshot.json"
	)
	var world_path := test_root.path_join("town_session_saves").path_join(world_reference)
	var world := _read_json(world_path)
	var state := world.get("state", {}) as Dictionary
	var activity_runtime := state.get("activityRuntime", {}) as Dictionary
	activity_runtime["sourceFingerprint"] = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	_expect_equal(_write_json(world_path, world), OK, "测试副本可形成未登记的活动指纹组合")
	var manifest := _fixture_manifest(test_root)
	var world_component := (manifest.get("components", {}) as Dictionary).get("world", {}) as Dictionary
	world_component["snapshot_sha256"] = FileAccess.get_sha256(world_path)
	_expect_equal(_write_json(_fixture_manifest_path(test_root), manifest), OK, "测试 manifest 可登记新 World 哈希")
	var report := INSPECTOR.inspect(test_root)
	var revision := _first_revision(report)
	_expect_equal(report.get("status"), "unrecognized", "未知组合与文件损坏分开报告")
	_expect_equal(revision.get("status"), "unrecognized", "未知组合修订不标记为损坏")
	_expect_equal(
		((revision.get("compatibility", {}) as Dictionary).get("error", {}) as Dictionary).get("code"),
		"SAVE_VERSION_COMBINATION_UNKNOWN",
		"未知组合使用稳定错误码",
	)
	_expect_equal(_has_issue_type(revision.get("issues", []) as Array, "damaged_save"), false, "未知但完整的组合不产生坏档证据")


func _test_world_version_evidence_comes_from_file() -> void:
	var test_root := _new_fixture_copy("world_version")
	_expect_equal(not test_root.is_empty(), true, "World 版本冲突测试副本可创建")
	var world_reference := (
		"slots/roundtrip-slot-beta6/sessions/roundtrip-session-beta6/"
		+ "revisions/00000000000000000001/world_snapshot.json"
	)
	var world_path := test_root.path_join("town_session_saves").path_join(world_reference)
	var world := _read_json(world_path)
	world["schemaVersion"] = 1
	_expect_equal(_write_json(world_path, world), OK, "测试副本可形成 World 版本冲突")
	var manifest := _fixture_manifest(test_root)
	var component := (manifest.get("components", {}) as Dictionary).get("world", {}) as Dictionary
	component["snapshot_sha256"] = FileAccess.get_sha256(world_path)
	_expect_equal(_write_json(_fixture_manifest_path(test_root), manifest), OK, "测试 manifest 可登记冲突 World 哈希")
	var revision := _first_revision(INSPECTOR.inspect(test_root))
	_expect_equal(revision.get("status"), "damaged", "World 文件与 manifest 版本冲突属于坏档")
	_expect_equal((revision.get("versions", {}) as Dictionary).get("world"), 1, "迁移证据使用 World 文件版本")
	_expect_equal(_has_module_issue(revision.get("issues", []) as Array, "world_snapshot"), true, "World 版本冲突证据定位到 World 快照")


func _test_world_and_agent_resident_sets_must_match() -> void:
	var test_root := _new_fixture_copy("residents")
	_expect_equal(not test_root.is_empty(), true, "居民集合测试副本可创建")
	var world_reference := (
		"slots/roundtrip-slot-beta6/sessions/roundtrip-session-beta6/"
		+ "revisions/00000000000000000001/world_snapshot.json"
	)
	var world_path := test_root.path_join("town_session_saves").path_join(world_reference)
	var world := _read_json(world_path)
	var residents := (
		(world.get("state", {}) as Dictionary).get("residents", []) as Array
	)
	residents.pop_back()
	_expect_equal(_write_json(world_path, world), OK, "测试副本可形成 World 居民缺失")
	var manifest_path := _fixture_manifest_path(test_root)
	var manifest := _fixture_manifest(test_root)
	var world_component := (
		(manifest.get("components", {}) as Dictionary).get("world", {}) as Dictionary
	)
	world_component["snapshot_sha256"] = FileAccess.get_sha256(world_path)
	_expect_equal(_write_json(manifest_path, manifest), OK, "测试 manifest 可登记变更后的 World 哈希")
	var report := INSPECTOR.inspect(test_root)
	var revision := _first_revision(report)

	_expect_equal(report.get("status"), "damaged", "World 与 Agent 居民不一致属于坏档")
	_expect_equal(revision.get("status"), "damaged", "居民集合不一致阻止完整修订")
	_expect_equal(
		(revision.get("worldAgentPair", {}) as Dictionary).get("sameResidentSet"),
		false,
		"报告明确 World 与 Agent 居民集合不一致",
	)
	_expect_equal(
		_has_module_issue(revision.get("issues", []) as Array, "world_snapshot"),
		true,
		"损坏证据定位到 World 快照",
	)


func _test_component_contract_damage_is_localized() -> void:
	var config_root := _new_fixture_copy("config")
	_expect_equal(not config_root.is_empty(), true, "配置损坏测试副本可创建")
	var config_reference := (
		"slots/roundtrip-slot-beta6/sessions/roundtrip-session-beta6/"
		+ "revisions/00000000000000000001/session_config.json"
	)
	var config_path := config_root.path_join("town_session_saves").path_join(config_reference)
	var damaged_config := _read_json(config_path)
	damaged_config["mode"] = "unknown"
	_expect_equal(_write_json(config_path, damaged_config), OK, "测试副本可写入非法 session config 模式")
	var config_manifest := _fixture_manifest(config_root)
	config_manifest["session_config_sha256"] = FileAccess.get_sha256(config_path)
	_expect_equal(_write_json(_fixture_manifest_path(config_root), config_manifest), OK, "测试 manifest 可登记空配置哈希")
	var config_revision := _first_revision(INSPECTOR.inspect(config_root))
	_expect_equal(config_revision.get("status"), "damaged", "非法 session config 不能通过完整性检查")
	_expect_equal(
		_has_module_issue(config_revision.get("issues", []) as Array, "session_config"),
		true,
		"配置损坏证据定位到 session config",
	)

	var log_root := _new_fixture_copy("world_log")
	_expect_equal(not log_root.is_empty(), true, "日志损坏测试副本可创建")
	var log_reference := (
		"slots/roundtrip-slot-beta6/sessions/roundtrip-session-beta6/"
		+ "revisions/00000000000000000001/world_log_snapshot.json"
	)
	var log_path := log_root.path_join("town_session_saves").path_join(log_reference)
	_expect_equal(_write_json(log_path, {}), OK, "测试副本可写入空 world log")
	var log_manifest := _fixture_manifest(log_root)
	var log_component := (
		(log_manifest.get("components", {}) as Dictionary).get("world_log", {}) as Dictionary
	)
	log_component["snapshot_sha256"] = FileAccess.get_sha256(log_path)
	_expect_equal(_write_json(_fixture_manifest_path(log_root), log_manifest), OK, "测试 manifest 可登记空日志哈希")
	var log_revision := _first_revision(INSPECTOR.inspect(log_root))
	_expect_equal(log_revision.get("status"), "damaged", "空 world log 不能通过完整性检查")
	_expect_equal(
		_has_module_issue(log_revision.get("issues", []) as Array, "world_log"),
		true,
		"日志损坏证据定位到 world log",
	)


func _test_world_log_segment_content_is_validated() -> void:
	var test_root := _new_fixture_copy_from(
		"world_log_segment",
		"res://tests/fixtures/historical_saves/beta5-activity-lifecycle",
	)
	_expect_equal(not test_root.is_empty(), true, "日志分段测试副本可创建")
	var manifest_path := test_root.path_join(
		"town_session_saves/slots/town-main/manifests/00000000000000000003.json",
	)
	var manifest := _read_json(manifest_path)
	var log_component := (
		(manifest.get("components", {}) as Dictionary).get("world_log", {}) as Dictionary
	)
	var snapshot_path := test_root.path_join("town_session_saves").path_join(
		String(log_component.get("snapshot_ref", "")),
	)
	var snapshot := _read_json(snapshot_path)
	var descriptor := (snapshot.get("segments", []) as Array)[0] as Dictionary
	var segment_path := test_root.path_join("town_session_saves").path_join(
		String(descriptor.get("segmentRef", "")),
	)
	var segment := _read_json(segment_path)
	segment["timelineId"] = "wrong-timeline"
	_expect_equal(_write_json(segment_path, segment), OK, "测试副本可写入错误日志时间线")
	descriptor["segmentSha256"] = FileAccess.get_sha256(segment_path)
	_expect_equal(_write_json(snapshot_path, snapshot), OK, "测试日志快照可登记新分段哈希")
	log_component["snapshot_sha256"] = FileAccess.get_sha256(snapshot_path)
	_expect_equal(_write_json(manifest_path, manifest), OK, "测试 manifest 可登记新日志快照哈希")
	var revision := _first_revision(INSPECTOR.inspect(test_root))
	_expect_equal(revision.get("status"), "damaged", "哈希一致的错误日志内容仍判为损坏")
	_expect_equal(
		_has_module_issue(revision.get("issues", []) as Array, "world_log"),
		true,
		"日志分段内容损坏证据定位到 world log",
	)
	_expect_equal(
		_all_hashes_match(revision.get("hashes", []) as Array),
		true,
		"日志内容校验独立于引用哈希校验",
	)


func _test_world_contract_damage_is_localized() -> void:
	var test_root := _new_fixture_copy("world_contract")
	_expect_equal(not test_root.is_empty(), true, "World 契约测试副本可创建")
	var world_reference := (
		"slots/roundtrip-slot-beta6/sessions/roundtrip-session-beta6/"
		+ "revisions/00000000000000000001/world_snapshot.json"
	)
	var world_path := test_root.path_join("town_session_saves").path_join(world_reference)
	var world := _read_json(world_path)
	(world.get("state", {}) as Dictionary)["environment"] = "broken"
	_expect_equal(_write_json(world_path, world), OK, "测试副本可写入非法 World 字段类型")
	var manifest := _fixture_manifest(test_root)
	var world_component := (
		(manifest.get("components", {}) as Dictionary).get("world", {}) as Dictionary
	)
	world_component["snapshot_sha256"] = FileAccess.get_sha256(world_path)
	_expect_equal(_write_json(_fixture_manifest_path(test_root), manifest), OK, "测试 manifest 可登记非法 World 哈希")
	var revision := _first_revision(INSPECTOR.inspect(test_root))
	_expect_equal(revision.get("status"), "damaged", "合法哈希不能掩盖 World 契约损坏")
	_expect_equal(
		_has_module_issue(revision.get("issues", []) as Array, "world_snapshot"),
		true,
		"World 契约损坏证据定位到 World 快照",
	)


func _test_agent_slot_manifest_is_required() -> void:
	var test_root := _new_fixture_copy("agent_slot")
	_expect_equal(not test_root.is_empty(), true, "Agent 槽位测试副本可创建")
	var slot_path := test_root.path_join("agent_saves/roundtrip-slot-beta6/slot.json")
	_expect_equal(
		DirAccess.remove_absolute(ProjectSettings.globalize_path(slot_path)),
		OK,
		"测试副本可移除 Agent slot manifest",
	)
	var revision := _first_revision(INSPECTOR.inspect(test_root))
	_expect_equal(revision.get("status"), "damaged", "缺少 Agent slot manifest 的修订不可加载")
	_expect_equal(
		_has_module_issue(revision.get("issues", []) as Array, "agent_snapshot"),
		true,
		"Agent 槽位损坏证据定位到 Agent",
	)


func _test_agent_only_slot_is_enumerated() -> void:
	var test_root := _new_fixture_copy("agent_only_slot")
	_expect_equal(not test_root.is_empty(), true, "Agent 独立槽位测试副本可创建")
	_expect_equal(
		FILE_SYSTEM.remove_tree(test_root.path_join(
			"town_session_saves/slots/roundtrip-slot-beta6",
		)),
		OK,
		"测试副本可移除对应 World 槽位",
	)
	_expect_equal(
		DirAccess.remove_absolute(ProjectSettings.globalize_path(
			test_root.path_join("agent_saves/roundtrip-slot-beta6/slot.json"),
		)),
		OK,
		"测试副本可同时移除 Agent slot manifest",
	)
	var report := INSPECTOR.inspect(test_root)
	var slots := report.get("slots", []) as Array
	_expect_equal(slots.size(), 1, "World 槽位缺失时仍枚举 Agent 槽位")
	var slot := slots[0] as Dictionary
	_expect_equal(slot.get("slotId"), "roundtrip-slot-beta6", "Agent 槽位身份进入报告")
	_expect_equal(
		(slot.get("revisions", []) as Array).size(),
		1,
		"Agent 修订作为孤立修订保留",
	)
	_expect_equal(slot.get("state"), "incomplete", "Agent 独立修订标记为未完成")
	var orphan := (slot.get("revisions", []) as Array)[0] as Dictionary
	_expect_equal((orphan.get("versions", {}) as Dictionary).get("agent"), 3, "孤立 Agent 侧仍记录格式版本")
	_expect_equal((orphan.get("hashes", []) as Array).is_empty(), false, "孤立 Agent 侧仍记录文件哈希")
	_expect_equal(
		((orphan.get("worldAgentPair", {}) as Dictionary).get("agentResidentIds", []) as Array).size(),
		15,
		"孤立 Agent 侧仍记录居民集合",
	)


func _test_missing_referenced_photo_is_reported() -> void:
	var test_root := _new_fixture_copy("missing_referenced_photo")
	_expect_equal(not test_root.is_empty(), true, "照片引用测试副本可创建")
	var ref := "chat-photo-sha256-05278b24b59eb927d34457d58e230cf34646240c06195e786bb403beb5a68291"
	_expect_equal(
		_inject_agent_photo_reference(test_root, ref),
		OK,
		"测试 Agent 居民载荷可登记照片引用",
	)
	var photo_path := test_root.path_join(
		"town_conversation_photos/roundtrip-slot-beta6/roundtrip-session-beta6/%s.bin" % ref,
	)
	_expect_equal(
		DirAccess.remove_absolute(ProjectSettings.globalize_path(photo_path)),
		OK,
		"测试副本可移除已引用照片",
	)
	var report := INSPECTOR.inspect(test_root)
	var revision := _first_revision(report)
	var slot := (report.get("slots", []) as Array)[0] as Dictionary
	_expect_equal(revision.get("status"), "damaged", "已引用照片缺失使对应修订损坏")
	_expect_equal(
		(revision.get("photoReferences", []) as Array).has(ref),
		true,
		"报告从居民载荷收集照片引用",
	)
	_expect_equal(
		_has_module_issue(slot.get("issues", []) as Array, "conversation_photos"),
		true,
		"照片缺失证据记录在共享会话资产中",
	)


func _test_shared_module_status_survives_without_slots() -> void:
	var future_root := _new_fixture_copy("no_slots_future")
	_expect_equal(not future_root.is_empty(), true, "无槽位未来模块测试副本可创建")
	_expect_equal(FILE_SYSTEM.remove_tree(future_root.path_join("town_session_saves/slots")), OK, "测试副本可移除 World 槽位根")
	_expect_equal(FILE_SYSTEM.remove_tree(future_root.path_join("agent_saves")), OK, "测试副本可移除 Agent 槽位根")
	var library_path := future_root.path_join("town_custom_resident_library.json")
	var library := _read_json(library_path)
	library["schemaVersion"] = 2
	_expect_equal(_write_json(library_path, library), OK, "无槽位副本可标记未来居民库")
	var future_report := INSPECTOR.inspect(future_root)
	_expect_equal(future_report.get("status"), "read_only", "无槽位时未来模块仍进入总状态")
	_expect_equal(future_report.get("supportStatus"), "read_only", "无槽位时保留未来支持状态")

	var damaged_root := _new_fixture_copy("no_slots_damaged")
	_expect_equal(not damaged_root.is_empty(), true, "无槽位损坏模块测试副本可创建")
	_expect_equal(FILE_SYSTEM.remove_tree(damaged_root.path_join("town_session_saves/slots")), OK, "损坏测试可移除 World 槽位根")
	_expect_equal(FILE_SYSTEM.remove_tree(damaged_root.path_join("agent_saves")), OK, "损坏测试可移除 Agent 槽位根")
	_expect_equal(_write_text(damaged_root.path_join("town_startup_profile.json"), "{broken"), OK, "无槽位副本可损坏启动资料")
	_expect_equal(INSPECTOR.inspect(damaged_root).get("status"), "damaged", "无槽位时 profile 损坏仍进入总状态")

	var orphan_root := _new_fixture_copy("orphan_with_damaged_profile")
	_expect_equal(not orphan_root.is_empty(), true, "孤立槽位共享损坏测试副本可创建")
	_expect_equal(
		DirAccess.remove_absolute(ProjectSettings.globalize_path(_fixture_manifest_path(orphan_root))),
		OK,
		"测试副本可形成孤立修订",
	)
	_expect_equal(_write_text(orphan_root.path_join("town_startup_profile.json"), "{broken"), OK, "孤立槽位副本可损坏启动资料")
	_expect_equal(INSPECTOR.inspect(orphan_root).get("status"), "damaged", "孤立槽位不能遮蔽共享模块损坏")


func _test_orphaned_revision_directory_is_enumerated() -> void:
	var test_root := _new_fixture_copy("orphan")
	_expect_equal(not test_root.is_empty(), true, "孤立修订测试副本可创建")
	var orphan_root := test_root.path_join(
		"town_session_saves/slots/roundtrip-slot-beta6/sessions/"
		+ "roundtrip-session-beta6/revisions/00000000000000000002",
	)
	_expect_equal(
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(orphan_root)),
		OK,
		"测试副本可创建无 manifest 的修订目录",
	)
	var report := INSPECTOR.inspect(test_root)
	var slot := (report.get("slots", []) as Array)[0] as Dictionary
	var revisions := slot.get("revisions", []) as Array
	_expect_equal(report.get("status"), "incomplete", "孤立修订与坏档分开报告")
	_expect_equal(slot.get("latestEvidenceRevision"), 2, "孤立目录计入最新证据修订")
	_expect_equal(revisions.size(), 2, "manifest 缺失时仍枚举修订目录")
	_expect_equal((revisions[0] as Dictionary).get("status"), "incomplete", "孤立修订标记为未完成")
	_expect_equal((revisions[0] as Dictionary).get("transactionState"), "orphaned_revision", "报告保留孤立修订状态")


func _test_invalid_manifest_is_not_duplicated_as_orphan() -> void:
	var test_root := _new_fixture_copy("invalid_manifest")
	_expect_equal(not test_root.is_empty(), true, "manifest 去重测试副本可创建")
	_expect_equal(
		_write_text(_fixture_manifest_path(test_root), "{not-json"),
		OK,
		"测试副本可损坏唯一 manifest",
	)
	var intent_root := test_root.path_join(
		"town_session_saves/slots/roundtrip-slot-beta6/intents/save/"
		+ "roundtrip-session-beta6/00000000000000000001/broken",
	)
	_expect_equal(
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(intent_root)),
		OK,
		"损坏 manifest 可同时存在事务证据",
	)
	_expect_equal(_write_text(intent_root.path_join("020_broken.json"), "{not-json"), OK, "同修订可写入损坏事务")
	var report := INSPECTOR.inspect(test_root)
	var revisions := (
		((report.get("slots", []) as Array)[0] as Dictionary)
		.get("revisions", []) as Array
	)
	_expect_equal(revisions.size(), 1, "损坏 manifest 与同修订目录只保留一份证据")
	_expect_equal((revisions[0] as Dictionary).get("status"), "damaged", "损坏 manifest 保持坏档状态")
	var damaged := revisions[0] as Dictionary
	_expect_equal((damaged.get("versions", {}) as Dictionary).get("world"), 2, "损坏 manifest 不遮蔽 World 版本证据")
	_expect_equal((damaged.get("versions", {}) as Dictionary).get("agent"), 3, "损坏 manifest 不遮蔽 Agent 版本证据")
	_expect_equal((damaged.get("hashes", []) as Array).is_empty(), false, "损坏 manifest 仍保留旁侧文件哈希")
	_expect_equal(
		((damaged.get("worldAgentPair", {}) as Dictionary).get("agentResidentIds", []) as Array).size(),
		15,
		"损坏 manifest 仍保留 Agent 居民集合",
	)


func _test_damaged_latest_revision_preserves_older_complete_evidence() -> void:
	var test_root := _new_fixture_copy("recovery")
	_expect_equal(not test_root.is_empty(), true, "损坏修订测试副本可创建")
	var damaged_manifest_path := test_root.path_join(
		"town_session_saves/slots/roundtrip-slot-beta6/manifests/00000000000000000002.json",
	)
	_expect_equal(
		_write_text(damaged_manifest_path, "{not-json"),
		OK,
		"测试副本可加入损坏的最新 manifest",
	)
	var before := _tree_fingerprint(test_root)
	var report := INSPECTOR.inspect(test_root)
	var after := _tree_fingerprint(test_root)
	var slot := (report.get("slots", []) as Array)[0] as Dictionary
	var revisions := slot.get("revisions", []) as Array

	_expect_equal(report.get("status"), "recoverable", "存在旧完整修订时报告为可恢复")
	_expect_equal(slot.get("state"), "recoverable", "槽位保留明确的可恢复状态")
	_expect_equal(slot.get("latestEvidenceRevision"), 2, "最新损坏修订仍计入证据")
	_expect_equal(slot.get("latestCompleteRevision"), 1, "较旧完整修订作为恢复候选")
	_expect_equal(revisions.size(), 2, "检查器不会只检查最新 manifest")
	_expect_equal((revisions[0] as Dictionary).get("status"), "damaged", "最新修订标记为损坏")
	_expect_equal((revisions[0] as Dictionary).get("saveRevision"), 2, "损坏修订号来自文件名")
	_expect_equal((revisions[1] as Dictionary).get("status"), "complete", "旧完整修订仍完成全量校验")
	_expect_equal(after, before, "恢复候选检查不改写损坏源目录")


func _test_interrupted_transaction_is_reported_as_incomplete_revision() -> void:
	var test_root := _new_fixture_copy("interrupted")
	_expect_equal(not test_root.is_empty(), true, "事务中断测试副本可创建")
	var intent_root := test_root.path_join(
		"town_session_saves/slots/roundtrip-slot-beta6/intents/save/roundtrip-session-beta6/00000000000000000002/save",
	)
	_expect_equal(
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(intent_root)),
		OK,
		"测试副本可创建未完成事务目录",
	)
	var context := {
		"slot_id": "roundtrip-slot-beta6",
		"session_id": "roundtrip-session-beta6",
		"save_revision": 2,
	}
	_expect_equal(_write_json(intent_root.path_join("020_agent_commit_started.json"), {
		"schema": "town-session-save-intent",
		"schema_version": 1,
		"kind": "save",
		"intent_id": "save",
		"state": "agent_commit_started",
		"order": 20,
		"context": context,
		"payload": {},
	}), OK, "测试副本可写入事务中断证据")
	_expect_equal(_write_json(test_root.path_join(
		"town_session_saves/slots/roundtrip-slot-beta6/allocations/00000000000000000002.json",
	), {
		"schema": "town-session-save-allocation",
		"schema_version": 1,
		"context": context,
	}), OK, "同一中断事务可保留修订分配证据")
	var before := _tree_fingerprint(test_root)
	var report := INSPECTOR.inspect(test_root)
	var after := _tree_fingerprint(test_root)
	var slot := (report.get("slots", []) as Array)[0] as Dictionary
	var revisions := slot.get("revisions", []) as Array
	var interrupted := revisions[0] as Dictionary

	_expect_equal(report.get("status"), "incomplete", "事务中断与文件损坏分开报告")
	_expect_equal(slot.get("latestEvidenceRevision"), 2, "未发布事务也计入最新证据修订")
	_expect_equal(slot.get("latestCompleteRevision"), 1, "未完成事务不会遮蔽旧完整修订")
	_expect_equal(interrupted.get("saveRevision"), 2, "报告枚举未发布事务修订")
	_expect_equal(interrupted.get("status"), "incomplete", "未发布事务修订标为未完成")
	_expect_equal(interrupted.get("transactionState"), "agent_commit_started", "报告保留最后事务阶段")
	_expect_equal(
		(((interrupted.get("issues", []) as Array)[0] as Dictionary).get("code")),
		"SAVE_TRANSACTION_INTERRUPTED",
		"事务中断使用稳定错误码",
	)
	_expect_equal(after, before, "事务检查不改写源目录")


func _test_invalid_transaction_record_is_preserved() -> void:
	var test_root := _new_fixture_copy("invalid_transaction")
	_expect_equal(not test_root.is_empty(), true, "损坏事务测试副本可创建")
	var intent_root := test_root.path_join(
		"town_session_saves/slots/roundtrip-slot-beta6/intents/save/"
		+ "roundtrip-session-beta6/00000000000000000002/save",
	)
	_expect_equal(
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(intent_root)),
		OK,
		"测试副本可创建损坏事务目录",
	)
	_expect_equal(
		_write_text(intent_root.path_join("020_agent_commit_started.json"), "{not-json"),
		OK,
		"测试副本可写入损坏事务记录",
	)
	var report := INSPECTOR.inspect(test_root)
	var revision := _first_revision(report)
	_expect_equal(report.get("status"), "incomplete", "损坏事务日志不会被静默忽略")
	_expect_equal(revision.get("saveRevision"), 2, "损坏事务记录仍保留修订身份")
	_expect_equal(revision.get("transactionState"), "journal_invalid", "报告标记损坏事务日志")
	_expect_equal(
		_has_module_issue(revision.get("issues", []) as Array, "device_and_transaction_state"),
		true,
		"事务损坏证据定位到事务状态",
	)


func _test_contextless_transaction_record_is_preserved() -> void:
	var test_root := _new_fixture_copy("contextless_transaction")
	_expect_equal(not test_root.is_empty(), true, "无 context 事务测试副本可创建")
	var intent_root := test_root.path_join(
		"town_session_saves/slots/roundtrip-slot-beta6/intents/save/"
		+ "roundtrip-session-beta6/00000000000000000002/save",
	)
	_expect_equal(
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(intent_root)),
		OK,
		"测试副本可创建无 context 事务目录",
	)
	_expect_equal(_write_json(intent_root.path_join("020_agent_commit_started.json"), {
		"schema": "town-session-save-intent",
		"schema_version": 1,
		"kind": "save",
		"intent_id": "save",
		"state": "agent_commit_started",
		"order": 20,
		"payload": {},
	}), OK, "测试副本可写入缺少 context 的事务记录")
	var report := INSPECTOR.inspect(test_root)
	var revision := _first_revision(report)
	_expect_equal(report.get("status"), "incomplete", "缺少 context 的事务记录不会丢失")
	_expect_equal(revision.get("saveRevision"), 2, "事务目录保留缺失 context 的修订身份")
	_expect_equal(revision.get("transactionState"), "journal_invalid", "缺少 context 的事务记录标记无效")


func _test_completed_transaction_suppresses_early_damage() -> void:
	var test_root := _new_fixture_copy("completed_transaction")
	_expect_equal(not test_root.is_empty(), true, "已完成事务测试副本可创建")
	var early_path := test_root.path_join(
		"town_session_saves/slots/roundtrip-slot-beta6/intents/save/"
		+ "roundtrip-session-beta6/00000000000000000001/save/001_save_started.json",
	)
	_expect_equal(_write_text(early_path, "{broken"), OK, "测试副本可损坏已完成事务的早期记录")
	var report := INSPECTOR.inspect(test_root)
	var slot := (report.get("slots", []) as Array)[0] as Dictionary
	_expect_equal(report.get("status"), "healthy", "最终阶段已完成时不误报早期事务损坏")
	_expect_equal((slot.get("revisions", []) as Array).size(), 1, "完成事务不生成额外未完成修订")
	_expect_equal(_has_module_issue(slot.get("issues", []) as Array, "device_and_transaction_state"), false, "完成事务消解同 intent 的早期记录")


func _test_allocation_without_manifest_is_preserved() -> void:
	var test_root := _new_fixture_copy("allocation_only")
	_expect_equal(not test_root.is_empty(), true, "修订分配测试副本可创建")
	var allocation_path := test_root.path_join(
		"town_session_saves/slots/roundtrip-slot-beta6/allocations/00000000000000000002.json",
	)
	_expect_equal(_write_json(allocation_path, {
		"schema": "town-session-save-allocation",
		"schema_version": 1,
		"context": {
			"slot_id": "roundtrip-slot-beta6",
			"session_id": "roundtrip-session-beta6",
			"save_revision": 2,
		},
	}), OK, "测试副本可写入未发布修订分配")
	var report := INSPECTOR.inspect(test_root)
	var revisions := (
		((report.get("slots", []) as Array)[0] as Dictionary).get("revisions", []) as Array
	)
	_expect_equal(report.get("status"), "incomplete", "分配后立即中断会进入总状态")
	_expect_equal(revisions.size(), 2, "未发布分配作为独立修订证据")
	_expect_equal((revisions[0] as Dictionary).get("saveRevision"), 2, "分配文件名保留修订号")
	_expect_equal((revisions[0] as Dictionary).get("transactionState"), "revision_allocated", "分配中断保留事务阶段")


func _all_hashes_match(hashes: Array) -> bool:
	for hash_value: Variant in hashes:
		if (
			not hash_value is Dictionary
			or String((hash_value as Dictionary).get("status", "")) != "match"
		):
			return false
	return true


func _all_revisions_complete(revisions: Array) -> bool:
	for revision_value: Variant in revisions:
		if (
			not revision_value is Dictionary
			or String((revision_value as Dictionary).get("status", "")) != "complete"
		):
			return false
	return true


func _has_issue_type(issues: Array, type: String) -> bool:
	for issue_value: Variant in issues:
		if (
			issue_value is Dictionary
			and String((issue_value as Dictionary).get("type", "")) == type
		):
			return true
	return false


func _has_module_issue(issues: Array, module_id: String) -> bool:
	for issue_value: Variant in issues:
		if (
			issue_value is Dictionary
			and String((issue_value as Dictionary).get("module", "")) == module_id
		):
			return true
	return false


func _has_hash_module(hashes: Array, module_id: String) -> bool:
	for hash_value: Variant in hashes:
		if (
			hash_value is Dictionary
			and String((hash_value as Dictionary).get("module", "")) == module_id
		):
			return true
	return false


func _has_module_state(
	modules: Array,
	module_id: String,
	present: bool,
) -> bool:
	for module_value: Variant in modules:
		if (
			module_value is Dictionary
			and String((module_value as Dictionary).get("module", "")) == module_id
			and bool((module_value as Dictionary).get("present", false)) == present
		):
			return true
	return false


func _inject_agent_photo_reference(test_root: String, ref: String) -> Error:
	return _rewrite_agent_payloads(test_root, 1, true, func(envelope: Dictionary) -> void:
		envelope["inspection_photo_reference"] = {
			"ref": ref,
			"mime_type": "image/png",
		}
	)


func _set_first_agent_nested_version(
	test_root: String,
	version_key: String,
) -> Error:
	return _rewrite_agent_payloads(test_root, 0, true, func(envelope: Dictionary) -> void:
		if version_key == "residentPayload":
			envelope["format_version"] = 3
			envelope.erase("resident_state")
			return
		var resident_state := envelope.get("resident_state", {}) as Dictionary
		if version_key == "residentRuntime":
			resident_state["runtime_state_version"] = 7
			resident_state.erase("memory_system")
			return
		var memory_state := resident_state.get("memory_system", {}) as Dictionary
		memory_state["memory_state_version"] = 7
	)


func _tamper_first_agent_payload_version(test_root: String) -> Error:
	return _rewrite_agent_payloads(test_root, 1, false, func(envelope: Dictionary) -> void:
		envelope["format_version"] = 3
		envelope.erase("resident_state")
	)


func _rewrite_agent_payloads(
	test_root: String,
	max_count: int,
	update_snapshot: bool,
	mutate: Callable,
) -> Error:
	var revision_root := test_root.path_join(
		"agent_saves/roundtrip-slot-beta6/sessions/roundtrip-session-beta6/revisions/1",
	)
	var snapshot_path := revision_root.path_join("snapshot.json")
	var snapshot := _read_json(snapshot_path)
	var residents := snapshot.get("residents", []) as Array
	if residents.is_empty():
		return ERR_FILE_CORRUPT
	for index in residents.size():
		if max_count > 0 and index >= max_count:
			break
		var entry := residents[index] as Dictionary
		var payload_path := revision_root.path_join(String(entry.get("file", "")))
		var payload_file := FileAccess.open(payload_path, FileAccess.READ)
		if payload_file == null:
			return FileAccess.get_open_error()
		var payload := payload_file.get_buffer(payload_file.get_length())
		payload_file = null
		var decoded: Variant = bytes_to_var(payload)
		if not decoded is Dictionary:
			return ERR_FILE_CORRUPT
		var envelope := decoded as Dictionary
		mutate.call(envelope)
		var encoded := var_to_bytes(envelope)
		var write_error := _write_bytes(payload_path, encoded)
		if write_error != OK:
			return write_error
		if update_snapshot:
			entry["byte_length"] = encoded.size()
			entry["sha256"] = FileAccess.get_sha256(payload_path)
			residents[index] = entry
	if not update_snapshot:
		return OK
	snapshot["residents"] = residents
	return _write_json(snapshot_path, snapshot)


func _write_bytes(path: String, value: PackedByteArray) -> Error:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_buffer(value)
	file.flush()
	var error := file.get_error()
	file = null
	return error


func _copy_tree(source: String, destination: String) -> Error:
	var create_error := DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(destination),
	)
	if create_error != OK:
		return create_error
	var directory := DirAccess.open(source)
	if directory == null:
		return ERR_FILE_NOT_FOUND
	for file_name in directory.get_files():
		var copy_error := DirAccess.copy_absolute(
			ProjectSettings.globalize_path(source.path_join(file_name)),
			ProjectSettings.globalize_path(destination.path_join(file_name)),
		)
		if copy_error != OK:
			return copy_error
	for directory_name in directory.get_directories():
		var child_error := _copy_tree(
			source.path_join(directory_name),
			destination.path_join(directory_name),
		)
		if child_error != OK:
			return child_error
	return OK


func _read_json(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file = null
	return parsed as Dictionary if parsed is Dictionary else {}


func _write_json(path: String, value: Dictionary) -> Error:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string(JSON.stringify(value, "\t"))
	file.flush()
	var error := file.get_error()
	file = null
	return error


func _write_text(path: String, value: String) -> Error:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string(value)
	file.flush()
	var error := file.get_error()
	file = null
	return error


func _new_fixture_copy(label: String) -> String:
	return _new_fixture_copy_from(label, BETA6_ROOT)


func _new_fixture_copy_from(label: String, source: String) -> String:
	var test_root := "user://tests/town_save_archive_inspector/%s_%d_%d" % [
		label,
		OS.get_process_id(),
		Time.get_ticks_usec(),
	]
	_test_roots.append(test_root)
	return test_root if _copy_tree(source, test_root) == OK else ""


func _fixture_manifest_path(test_root: String) -> String:
	return test_root.path_join(
		"town_session_saves/slots/roundtrip-slot-beta6/manifests/00000000000000000001.json",
	)


func _fixture_manifest(test_root: String) -> Dictionary:
	return _read_json(_fixture_manifest_path(test_root))


func _first_revision(report: Dictionary) -> Dictionary:
	return (
		((report.get("slots", []) as Array)[0] as Dictionary)
		.get("revisions", []) as Array
	)[0] as Dictionary


func _tree_fingerprint(path: String) -> String:
	var entries: Array[String] = []
	_collect_tree_hashes(path, path, entries)
	entries.sort()
	return "\n".join(entries).sha256_text()


func _collect_tree_hashes(root_path: String, path: String, entries: Array[String]) -> void:
	var directory := DirAccess.open(path)
	if directory == null:
		return
	var files := directory.get_files()
	files.sort()
	for file_name in files:
		var file_path := path.path_join(file_name)
		entries.append("%s\u001f%s" % [
			file_path.trim_prefix("%s/" % root_path),
			FileAccess.get_sha256(file_path),
		])
	var directories := directory.get_directories()
	directories.sort()
	for directory_name in directories:
		_collect_tree_hashes(root_path, path.path_join(directory_name), entries)


func _expect_equal(actual: Variant, expected: Variant, message: String) -> void:
	_checks += 1
	if actual == expected:
		return
	_failures.append("%s：expected=%s actual=%s" % [message, str(expected), str(actual)])


func _finish() -> void:
	for test_root in _test_roots:
		FILE_SYSTEM.remove_tree(test_root)
	_prepare_project_shutdown()
	if _failures.is_empty():
		print("TOWN_SAVE_ARCHIVE_INSPECTOR_PASS checks=%d" % _checks)
		call_deferred("_quit_after_shutdown", 0)
		return
	for failure in _failures:
		printerr("TOWN_SAVE_ARCHIVE_INSPECTOR_FAIL: %s" % failure)
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
