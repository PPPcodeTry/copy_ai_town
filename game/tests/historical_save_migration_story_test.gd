extends SceneTree


const PROVIDER_SERVICE := preload(
	"res://world/integration/TownAgentProviderService.gd"
)
const GATEWAY := preload(
	"res://world/integration/TownWorldAgentGateway.gd"
)
const TOWN_RUNTIME_SCENE := preload(
	"res://world/presentation/town_runtime/TownRuntime.tscn"
)
const STORE := preload(
	"res://world/presentation/session/TownSessionSaveStore.gd"
)
const AGENT_STORE := preload(
	"res://agent/lifecycle/AgentSaveStore.gd"
)
const STARTUP_CATALOG := preload(
	"res://world/presentation/session/TownStartupSaveCatalog.gd"
)
const RUNTIME_GATE := preload(
	"res://world/presentation/session/TownSessionRuntimeGate.gd"
)
const COORDINATOR := preload(
	"res://world/presentation/session/TownSessionSaveCoordinator.gd"
)
const SCHEMA_REGISTRY := preload(
	"res://world/presentation/session/TownSaveSchemaRegistry.gd"
)

const SLOT_ID := "roundtrip-slot-beta2"
const EMPTY_SLOT_ID := "historical-empty-slot"
const SESSION_ID := "roundtrip-session-beta2"
const FIRST_REVISION := 1
const ACTIVITY_MIGRATION_ID := "2026-08-12-public-dining-day-routine"
const PLACE_SERVICE_OWNER_MIGRATION_ID := (
	"2026-08-24-place-service-owner-backfill"
)
const AGENT_SHOP_OWNER_MIGRATION_ID := (
	"2026-08-24-shop-owner-derived-from-occupation"
)

var _failures: Array[String] = []
var _checks := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	DisplayServer.window_set_size(Vector2i(1920, 1080))
	root.size = Vector2i(1920, 1080)
	var store: RefCounted = STORE.new()
	var catalog: RefCounted = STARTUP_CATALOG.new()
	_expect_ok(
		catalog.call("configure", store, "user://town_startup_profile.json", AGENT_STORE.new()) as Dictionary,
		"启动存档目录可配置",
	)
	var startup := catalog.call("get_catalog", [
		{"slotId": SLOT_ID, "displayName": "历史存档"},
		{"slotId": EMPTY_SLOT_ID, "displayName": "空槽位"},
	]) as Dictionary
	_expect_ok(startup, "beta2 存档可由正式启动目录发现")
	_expect_equal(startup.get("continueAvailable"), true, "beta2 存档可继续")
	var slot := startup.get("continueSlot", {}) as Dictionary
	_expect_equal(slot.get("state"), "healthy", "旧格式不会被误判为坏档")
	_expect_equal(slot.get("agentIntegrity"), "agent_snapshot_verified", "World 与 Agent 完整对通过检查")
	var session_config := (slot.get("sessionConfig", {}) as Dictionary).duplicate(true)
	var identities := (session_config.get("residentIdentities", []) as Array).duplicate(true)
	_expect_equal(identities.size(), 15, "历史样本保留全部居民")

	var provider_host := Node.new()
	provider_host.name = "HistoricalSaveProviderHost"
	root.add_child(provider_host)
	var provider_service: RefCounted = PROVIDER_SERVICE.new()
	_expect_ok(provider_service.call("configure", {
		"capabilityMode": "development",
		"source": "placeholder",
		"allowFake": true,
		"providerConfigs": {},
	}, provider_host) as Dictionary, "离线模型服务可用于历史存档恢复")

	var first := await _restore_revision(
		store,
		provider_service,
		provider_host,
		session_config,
		identities,
		FIRST_REVISION,
	)
	var first_restore := first.get("restore", {}) as Dictionary
	_expect_ok(first_restore, "beta2 存档可恢复到 beta6 运行时")
	var first_migration := (
		(first_restore.get("commitReceipt", {}) as Dictionary)
		.get("migrationReceipt", {}) as Dictionary
	)
	_expect(
		(first_migration.get("applied", []) as Array).has(
			ACTIVITY_MIGRATION_ID,
		),
		"首次恢复明确报告 beta2 活动迁移",
	)
	_expect(
		(first_migration.get("applied", []) as Array).has(
			PLACE_SERVICE_OWNER_MIGRATION_ID,
		),
		"首次恢复明确报告地点服务协调者迁移",
	)
	_expect(
		(first_migration.get("applied", []) as Array).has(
			AGENT_SHOP_OWNER_MIGRATION_ID,
		),
		"首次恢复明确报告 Agent 铺面负责人迁移",
	)
	_expect_equal(
		(
			(first_migration.get("moduleReceipts", {}) as Dictionary)
			.get("resident_payload", {}) as Dictionary
		).get("applied"),
		[AGENT_SHOP_OWNER_MIGRATION_ID],
		"Agent 迁移回执保持独立模块和版本",
	)
	var first_world: RefCounted = first.get("world")
	var before_time := first_world.call("get_time") as Dictionary
	_expect_ok(first_world.call("advance", 1.0) as Dictionary, "升级后的世界可继续推进")
	_expect(first_world.call("get_time") != before_time, "升级后产生可观察的时间变化")
	var second_revision := await _save_restored(first, session_config, identities)
	_expect_equal(second_revision, 2, "升级结果保存为新的成对修订")
	await _release_runtime(first)
	var reopened_catalog := catalog.call("get_catalog", [
		{"slotId": SLOT_ID, "displayName": "历史存档"},
		{"slotId": EMPTY_SLOT_ID, "displayName": "空槽位"},
	]) as Dictionary
	_expect_ok(reopened_catalog, "运行时释放后启动目录可重新读取升级结果")
	var reopened_slot := reopened_catalog.get("continueSlot", {}) as Dictionary
	_expect_equal(reopened_slot.get("state"), "healthy", "升级后启动目录保持健康")
	_expect_equal(
		(reopened_slot.get("summary", {}) as Dictionary).get("saveRevision"),
		second_revision,
		"启动目录选择升级后的最新修订",
	)

	var saved_snapshot := _read_world_snapshot(store, SLOT_ID, SESSION_ID, second_revision)
	_expect_equal(
		(saved_snapshot.get("state", {}) as Dictionary).size(),
		27,
		"升级后存档只保留 beta6 的 27 个 World 分区",
	)
	var saved_state := saved_snapshot.get("state", {}) as Dictionary
	_expect_equal(
		(saved_state.get("activityRuntime", {}) as Dictionary).get("sourceFingerprint"),
		SCHEMA_REGISTRY.ACTIVITY_SOURCE_FINGERPRINT_AFTER_PUBLIC_DINING_DAY_REWORK,
		"升级后写入当前活动指纹",
	)
	_expect_equal(
		(saved_state.get("travelerRelations", {}) as Dictionary).get("schemaVersion"),
		1,
		"缺失的旅行者关系按当前格式重建",
	)

	var reopened := await _restore_revision(
		store,
		provider_service,
		provider_host,
		session_config,
		identities,
		second_revision,
	)
	var reopened_restore := reopened.get("restore", {}) as Dictionary
	_expect_ok(reopened_restore, "升级后存档重建运行时仍可恢复")
	var second_migration := (
		(reopened_restore.get("commitReceipt", {}) as Dictionary)
		.get("migrationReceipt", {}) as Dictionary
	)
	_expect_equal(second_migration.get("applied"), [], "第二次恢复不再重复迁移")
	var third_revision := await _save_restored(reopened, session_config, identities)
	_expect_equal(third_revision, 3, "重开后的存档可再次成对保存")
	var resaved_state := (
		_read_world_snapshot(store, SLOT_ID, SESSION_ID, third_revision)
		.get("state", {}) as Dictionary
	)
	_expect_equal(
		resaved_state.get("activityRuntime"),
		saved_state.get("activityRuntime"),
		"第二次保存不再改变活动迁移结果",
	)
	_expect_equal(
		resaved_state.get("travelerRelations"),
		saved_state.get("travelerRelations"),
		"第二次保存不再改变重建的旅行者关系",
	)
	_expect_agent_snapshots_equal(second_revision, third_revision)
	await _release_runtime(reopened)
	provider_host.queue_free()
	_finish()


func _restore_revision(
	store: RefCounted,
	provider_service: RefCounted,
	provider_host: Node,
	session_config: Dictionary,
	identities: Array,
	revision: int,
) -> Dictionary:
	var gateway: Node = GATEWAY.new()
	var gateway_config := session_config.duplicate(true)
	gateway_config.merge({
		"slotId": SLOT_ID,
		"saveRevision": revision,
		"restorePending": true,
		"capabilityMode": "formal",
		"formalReady": true,
	}, true)
	_expect_ok(
		gateway.call("configure_session", gateway_config, provider_service, provider_host) as Dictionary,
		"历史存档 Agent 网关可配置",
	)
	var runtime: Node = TOWN_RUNTIME_SCENE.instantiate()
	_expect_ok(runtime.call("configure_agent_gateway", gateway) as Dictionary, "恢复网关可注入小镇")
	var runtime_config := gateway_config.duplicate(true)
	runtime_config.merge({
		"mode": "continue",
		"connectedResidents": _resident_names(identities),
		"source": "runtime",
		"providerFormalReady": true,
		"internalPlaytest": false,
		"internalLivePlaytest": false,
		"requireAgentGateway": true,
		"avatarInitialMode": "observer",
	}, true)
	_expect_ok(runtime.call("configure_session", runtime_config) as Dictionary, "继续游戏运行时可配置")
	root.add_child(runtime)
	await _wait_frames(5)
	_expect_ok(runtime.call("get_startup_result") as Dictionary, "继续游戏场景完成挂载")
	var world: RefCounted = runtime.call("get_world_runtime")
	var gate: RefCounted = RUNTIME_GATE.new()
	_expect_ok(gate.call("configure", runtime) as Dictionary, "恢复事务锁可配置")
	var coordinator: RefCounted = COORDINATOR.new()
	_expect_ok(coordinator.call(
		"configure",
		store,
		world,
		gateway.call("get_agent_save_participant"),
		gate,
	) as Dictionary, "成对存档协调器可配置")
	var restored := coordinator.call(
		"restore_revision",
		SLOT_ID,
		SESSION_ID,
		revision,
		_read_json("res://world/data/town/town_world.json"),
		identities,
		gateway,
	) as Dictionary
	if restored.get("ok") == true:
		_expect_ok(
			runtime.call("complete_restored_session", restored.get("context", {})) as Dictionary,
			"恢复结果可提交给小镇运行时",
		)
	return {
		"runtime": runtime,
		"gateway": gateway,
		"world": world,
		"coordinator": coordinator,
		"restore": restored,
	}


func _save_restored(restored: Dictionary, session_config: Dictionary, identities: Array) -> int:
	var next_config := session_config.duplicate(true)
	next_config["mode"] = "continue"
	var saved := (restored.get("coordinator") as RefCounted).call("save", {
		"slotId": SLOT_ID,
		"sessionId": SESSION_ID,
		"residentIdentities": identities.duplicate(true),
		"sessionConfig": next_config,
		"residentMessages": [],
	}) as Dictionary
	_expect_ok(saved, "升级后的 World 与 Agent 可成对保存")
	return int((saved.get("context", {}) as Dictionary).get("save_revision", -1))


func _read_world_snapshot(store: RefCounted, slot_id: String, session_id: String, revision: int) -> Dictionary:
	var discovered := store.call("list_published", slot_id) as Dictionary
	for value: Variant in discovered.get("manifests", []) as Array:
		var manifest := value as Dictionary
		if (
			String(manifest.get("session_id", "")) == session_id
			and int(manifest.get("save_revision", 0)) == revision
		):
			var world := (manifest.get("components", {}) as Dictionary).get("world", {}) as Dictionary
			var loaded := store.call(
				"read_reference",
				String(world.get("snapshot_ref", "")),
				String(world.get("snapshot_sha256", "")),
			) as Dictionary
			_expect_ok(loaded, "升级后的 World 快照可按哈希重读")
			return (loaded.get("value", {}) as Dictionary).duplicate(true)
	_expect(false, "找不到升级后发布的 World 快照")
	return {}


func _expect_agent_snapshots_equal(first_revision: int, second_revision: int) -> void:
	var agent_store: RefCounted = AGENT_STORE.new()
	var first := agent_store.call("load_snapshot", {
		"slot_id": SLOT_ID,
		"session_id": SESSION_ID,
		"save_revision": first_revision,
	}) as Dictionary
	var second := agent_store.call("load_snapshot", {
		"slot_id": SLOT_ID,
		"session_id": SESSION_ID,
		"save_revision": second_revision,
	}) as Dictionary
	_expect_ok(first, "首次升级后的 Agent 快照可重读")
	_expect_ok(second, "第二次保存后的 Agent 快照可重读")
	var first_payloads := first.get("resident_payloads", {}) as Dictionary
	var second_payloads := second.get("resident_payloads", {}) as Dictionary
	var first_ids := first_payloads.keys()
	var second_ids := second_payloads.keys()
	first_ids.sort()
	second_ids.sort()
	_expect_equal(second_ids, first_ids, "第二次保存保持同一居民集合")
	for resident_id: Variant in first_ids:
		_expect_equal(
			second_payloads.get(resident_id),
			first_payloads.get(resident_id),
			"第二次保存不改变居民 %s 的 Agent 载荷" % resident_id,
		)


func _release_runtime(value: Dictionary) -> void:
	var runtime: Node = value.get("runtime")
	if is_instance_valid(runtime):
		runtime.queue_free()
	await _wait_frames(4)


func _resident_names(identities: Array) -> Array[String]:
	var names: Array[String] = []
	for value: Variant in identities:
		names.append(String((value as Dictionary).get("residentName", "")))
	return names


func _read_json(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	return parsed as Dictionary if parsed is Dictionary else {}


func _wait_frames(count: int) -> void:
	for _index in count:
		await process_frame


func _expect_ok(result: Dictionary, message: String) -> void:
	_expect(bool(result.get("ok", false)), "%s（%s）" % [message, result.get("errorCode", "")])


func _expect_equal(actual: Variant, expected: Variant, message: String) -> void:
	_expect(actual == expected, "%s；实际=%s，预期=%s" % [message, actual, expected])


func _expect(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures.append(message)


func _finish() -> void:
	for _index in 5:
		await process_frame
	if _failures.is_empty():
		print("HISTORICAL_SAVE_MIGRATION_STORY_PASS checks=%d" % _checks)
		quit(0)
		return
	for failure: String in _failures:
		printerr("HISTORICAL_SAVE_MIGRATION_STORY_FAIL: %s" % failure)
	quit(1)
