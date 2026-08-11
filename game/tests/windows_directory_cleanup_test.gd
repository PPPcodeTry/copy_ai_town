extends SceneTree


const SESSION_STORE := preload(
	"res://world/presentation/session/TownSessionSaveStore.gd"
)
const PHOTO_STORE := preload(
	"res://world/integration/TownConversationPhotoStore.gd"
)
const ARCHIVE_SERVICE := preload(
	"res://world/integration/TownFormalSlotArchiveService.gd"
)
const AGENT_SAVE_STORE := preload("res://agent/lifecycle/AgentSaveStore.gd")
const AGENT_FILE_SYSTEM := preload("res://agent/AgentFileSystem.gd")
const RESIDENT_MEMORY_SYSTEM := preload(
	"res://agent/memory/ResidentMemorySystem.gd"
)
const RESIDENT_AVATAR_MEMORY_MODULE := preload(
	"res://agent/avatar_memory/ResidentAvatarMemoryModule.gd"
)
const WINDOWS_LEGACY_MAX_PATH := 260
const SIMULATED_WINDOWS_USER_ROOT := (
	"C:/Users/windows-user-with-long-profile-name/AppData/Roaming/"
	+ "Godot/app_userdata/我的ai小镇"
)

var _failures: Array[String] = []
var _checks := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var suffix := "%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	_test_session_store_cleanup(suffix)
	_test_long_restore_transaction_cleanup(suffix)
	_test_photo_store_cleanup(suffix)
	_test_archive_cleanup(suffix)
	_test_agent_store_long_staging(suffix)
	_test_resident_runtime_memory_path()
	_test_agent_filesystem_cleanup(suffix)
	var audio := root.get_node_or_null("TownAudioController")
	if audio != null and audio.has_method("prepare_shutdown"):
		audio.call("prepare_shutdown")
	for _index in 5:
		await process_frame
	await create_timer(0.3, true, false, true).timeout
	if _failures.is_empty():
		print("WINDOWS_DIRECTORY_CLEANUP_PASS checks=%d" % _checks)
		quit(0)
		return
	for failure: String in _failures:
		printerr("WINDOWS_DIRECTORY_CLEANUP_FAIL: %s" % failure)
	quit(1)


func _test_session_store_cleanup(suffix: String) -> void:
	var test_root := (
		"user://tests/town_session_saves/windows_cleanup_%s" % suffix
	)
	var store: RefCounted = SESSION_STORE.new()
	_expect_ok(
		store.call("configure_test_root", test_root) as Dictionary,
		"会话存档清理测试目录可配置",
	)
	_expect(
		_write_nested_fixture(test_root),
		"会话存档清理夹具可创建",
	)
	_expect_ok(
		store.call("cleanup_test_root") as Dictionary,
		"会话存档目录可递归删除",
	)
	_expect(
		not DirAccess.dir_exists_absolute(
			ProjectSettings.globalize_path(test_root),
		),
		"会话存档根目录已删除",
	)


func _test_long_restore_transaction_cleanup(suffix: String) -> void:
	var test_root := (
		"user://tests/town_session_saves/windows_long_path_%s" % suffix
	)
	var store: RefCounted = SESSION_STORE.new()
	_expect_ok(
		store.call("configure_test_root", test_root) as Dictionary,
		"Windows 长路径恢复测试目录可配置",
	)
	var slot_id := "windows-long-slot-%s" % "s".repeat(110)
	var session_id := "windows-long-session-%s" % "r".repeat(107)
	var reserved := store.call(
		"reserve_revision",
		slot_id,
		session_id,
	) as Dictionary
	_expect_ok(reserved, "超长身份仍可预留存档修订")
	var context := reserved.get("context", {}) as Dictionary
	var begun := store.call("begin_intent", context, "restore") as Dictionary
	_expect_ok(begun, "超长恢复日志仍可建立事务")
	var intent_id := String(begun.get("intentId", ""))
	var intent_root := String(store.call(
		"_intent_attempt_root",
		context,
		"restore",
		intent_id,
	))
	var legacy_owner_path := (
		"%s/.transition.claim.candidate-%s/owner.json"
		% [intent_root, "f".repeat(24)]
	)
	var short_claim_path := String(store.call(
		"_ephemeral_claim_path",
		"transition",
		intent_root,
	))
	var short_owner_path := (
		"%s.candidate-%s/owner.json"
		% [short_claim_path, "f".repeat(24)]
	)
	var legacy_windows_path := _simulated_windows_path(legacy_owner_path)
	var short_windows_path := _simulated_windows_path(short_owner_path)
	_expect(
		legacy_windows_path.length() >= WINDOWS_LEGACY_MAX_PATH,
		"测试夹具确实越过传统 Windows 260 字符边界",
	)
	_expect(
		short_windows_path.length() < WINDOWS_LEGACY_MAX_PATH,
		"集中式事务 owner.json 保持在传统 Windows 路径边界内",
	)
	_expect(
		legacy_windows_path.length() - short_windows_path.length() >= 100,
		"集中式事务目录为不同用户目录保留足够路径余量",
	)
	var legacy_slot_owner_path := (
		"user://town_session_saves/slot_leases/%s/transactions/"
		+ "%s.claim.candidate-%s/owner.json"
	) % [slot_id, "a".repeat(64), "f".repeat(24)]
	var slot_transaction_root := String(store.call(
		"_slot_transaction_root",
		slot_id,
	))
	var short_slot_owner_path := (
		"%s/%s.claim.candidate-%s/owner.json"
		% [slot_transaction_root, "a".repeat(24), "f".repeat(24)]
	).replace(test_root, "user://town_session_saves")
	_expect(
		_simulated_windows_path(legacy_slot_owner_path).length()
			>= WINDOWS_LEGACY_MAX_PATH,
		"旧式槽位事务 owner.json 会越过传统 Windows 路径边界",
	)
	_expect(
		_simulated_windows_path(short_slot_owner_path).length()
			< WINDOWS_LEGACY_MAX_PATH,
		"槽位事务 owner.json 使用摘要槽位和短令牌",
	)
	var slot_lease := store.call("begin_slot_transaction", slot_id) as Dictionary
	_expect_ok(slot_lease, "超长槽位身份可建立事务锁")
	_expect_ok(
		store.call(
			"end_slot_transaction",
			slot_lease.get("leaseToken"),
		) as Dictionary,
		"超长槽位事务锁可释放",
	)
	_expect(
		_directory_is_empty(slot_transaction_root),
		"槽位事务结束后不残留临时 owner.json",
	)
	_expect_ok(
		store.call(
			"write_intent_stage",
			context,
			"restore",
			intent_id,
			"restore_started",
			{},
		) as Dictionary,
		"超长恢复路径可写入开始记录",
	)
	_expect_ok(
		store.call(
			"write_intent_stage",
			context,
			"restore",
			intent_id,
			"transaction_failed",
			{
				"stage": "world_prepare",
				"errorCode": "WINDOWS_LONG_PATH_TEST",
				"errors": [],
			},
		) as Dictionary,
		"超长恢复路径可完成失败记录收尾",
	)
	var latest := store.call(
		"read_latest_intent",
		context,
		"restore",
		intent_id,
	) as Dictionary
	_expect(
		latest.get("ok") == true
		and latest.get("state") == "transaction_failed",
		"超长路径下写入的恢复事务可以重新读取",
	)
	_expect(
		_directory_is_empty("%s/_claims" % test_root),
		"恢复事务结束后不残留临时 owner.json",
	)
	_expect_ok(
		store.call("cleanup_test_root") as Dictionary,
		"包含超长恢复日志的测试目录可完整清理",
	)
	_expect(
		not DirAccess.dir_exists_absolute(
			ProjectSettings.globalize_path(test_root),
		),
		"超长恢复测试根目录已删除",
	)


func _test_photo_store_cleanup(suffix: String) -> void:
	var photo_root := (
		"user://tests/town_conversation_photos/windows_cleanup_%s" % suffix
	)
	var save_root := (
		"user://tests/town_session_saves/windows_photo_cleanup_%s" % suffix
	)
	var store: RefCounted = PHOTO_STORE.new()
	_expect_ok(
		store.call(
			"configure_test_roots",
			photo_root,
			save_root,
		) as Dictionary,
		"照片清理测试目录可配置",
	)
	var slot_id := "p".repeat(128)
	var session_id := "h".repeat(128)
	_expect_ok(
		store.call("configure_session", slot_id, session_id) as Dictionary,
		"照片会话可建立",
	)
	var session_root := "%s/%s/%s" % [photo_root, slot_id, session_id]
	var photo_ref := "chat-photo-sha256-%s" % "a".repeat(64)
	var destination := "%s/%s.bin" % [session_root, photo_ref]
	var legacy_temporary := "%s.tmp" % destination
	var short_temporary := String(store.call(
		"_temporary_photo_path",
		destination,
	))
	_expect(
		_simulated_windows_path(legacy_temporary).length()
			>= WINDOWS_LEGACY_MAX_PATH,
		"旧式照片临时文件会越过传统 Windows 路径边界",
	)
	_expect(
		_simulated_windows_path(short_temporary).length()
			< WINDOWS_LEGACY_MAX_PATH,
		"照片临时文件使用浅层固定长度路径",
	)
	_expect(
		_write_nested_fixture(session_root),
		"照片会话清理夹具可创建",
	)
	_expect_ok(
		store.call("discard_unpublished_session") as Dictionary,
		"未发布照片会话可递归删除",
	)
	_expect(
		not DirAccess.dir_exists_absolute(
			ProjectSettings.globalize_path(session_root),
		),
		"照片会话目录已删除",
	)
	var save_store := store.get("_save_store") as RefCounted
	_expect_ok(
		save_store.call("cleanup_test_root") as Dictionary,
		"照片测试使用的会话锁目录已清理",
	)
	_expect(
		store.call("_remove_tree", photo_root) == OK,
		"照片测试根目录可清理",
	)


func _test_archive_cleanup(suffix: String) -> void:
	var base := (
		"user://tests/town_session_saves/formal_slot_archive/"
		+ "windows_cleanup_%s" % suffix
	)
	var service: RefCounted = ARCHIVE_SERVICE.new()
	_expect_ok(
		service.call(
			"configure_test_roots",
			"%s/world/slots" % base,
			"%s/agent" % base,
			"%s/backups" % base,
			"%s/photos" % base,
		) as Dictionary,
		"正式存档备份清理目录可配置",
	)
	var long_slot_id := "b".repeat(128)
	var archive_target := (
		"%s/backups/%s/1234567890123456-r9007199254740991/"
		+ "archive_transaction.json"
	) % [base, long_slot_id]
	var legacy_staging := "%s.tmp-123456-%s" % [
		archive_target,
		"9".repeat(16),
	]
	var short_staging := String(service.call(
		"_temporary_json_path",
		archive_target,
	))
	_expect(
		_simulated_windows_path(legacy_staging).length()
			>= WINDOWS_LEGACY_MAX_PATH,
		"旧式归档临时文件会越过传统 Windows 路径边界",
	)
	_expect(
		_simulated_windows_path(short_staging).length()
			< WINDOWS_LEGACY_MAX_PATH,
		"归档临时文件使用浅层固定长度路径",
	)
	_expect(
		DirAccess.make_dir_recursive_absolute(
			ProjectSettings.globalize_path(archive_target.get_base_dir()),
		) in [OK, ERR_ALREADY_EXISTS],
		"超长归档目标目录可创建",
	)
	_expect(
		bool(service.call("_write_json_atomic", archive_target, {
			"state": "windows-long-path-test",
		})),
		"超长归档目标可通过浅层临时文件原子写入",
	)
	_expect(
		FileAccess.file_exists(archive_target),
		"超长归档目标写入后可重新发现",
	)
	_expect(
		_write_nested_fixture(base),
		"正式存档备份清理夹具可创建",
	)
	_expect(
		bool(service.call("_remove_tree", base)),
		"正式存档备份目录可递归删除",
	)
	_expect(
		not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(base)),
		"正式存档备份根目录已删除",
	)
	var empty_archive_root := "%s_empty" % base
	_expect(
		DirAccess.make_dir_recursive_absolute(
			ProjectSettings.globalize_path(empty_archive_root),
		) in [OK, ERR_ALREADY_EXISTS],
		"空备份目录夹具可创建",
	)
	service.call("_remove_empty_archive_root", empty_archive_root)
	_expect(
		not DirAccess.dir_exists_absolute(
			ProjectSettings.globalize_path(empty_archive_root),
		),
		"空备份目录释放遍历句柄后可删除",
	)


func _test_agent_store_long_staging(suffix: String) -> void:
	var test_root := "user://agent_save_tests/windows_long_path_%s" % suffix
	var store: RefCounted = AGENT_SAVE_STORE.new()
	_expect_ok(
		store.call("configure_test_root", test_root) as Dictionary,
		"Agent 超长路径测试目录可配置",
	)
	var context := {
		"slot_id": "a".repeat(128),
		"session_id": "g".repeat(128),
		"save_revision": 1,
	}
	var final_root := String(store.call("_snapshot_root", context))
	var legacy_staging := "%s.tmp-%s" % [
		final_root,
		"9".repeat(16),
	]
	var short_staging := String(store.call(
		"_new_staging_root",
		"snapshot",
		final_root,
	))
	_expect(
		_simulated_windows_path(legacy_staging).length()
			>= WINDOWS_LEGACY_MAX_PATH,
		"旧式 Agent 快照临时目录会越过传统 Windows 路径边界",
	)
	_expect(
		_simulated_windows_path(short_staging).length()
			< WINDOWS_LEGACY_MAX_PATH,
		"Agent 快照临时目录使用浅层固定长度路径",
	)
	_expect_ok(
		store.call("create_new_game", context, {}) as Dictionary,
		"超长 Agent 身份可完成新游戏快照写入",
	)
	_expect_ok(
		store.call("load_snapshot", context) as Dictionary,
		"超长 Agent 快照提交后可以重新读取",
	)
	_expect_ok(
		store.call("cleanup_test_root") as Dictionary,
		"超长 Agent 快照测试目录可递归清理",
	)
	_expect(
		not DirAccess.dir_exists_absolute(
			ProjectSettings.globalize_path(test_root),
		),
		"超长 Agent 快照测试根目录已删除",
	)


func _test_resident_runtime_memory_path() -> void:
	var resident_id := "resident-%s" % "m".repeat(120)
	var memory_root := (
		"user://agent_runtime_memory/123456_1_restore_%s"
		% "a".repeat(32)
	)
	var legacy_path := "%s/%s/avatar_memory/avatar_evidence.json.tmp" % [
		memory_root,
		resident_id,
	]
	var primary_segment := String(
		RESIDENT_MEMORY_SYSTEM._resident_storage_segment(resident_id),
	)
	var avatar_segment := String(
		RESIDENT_AVATAR_MEMORY_MODULE._resident_storage_segment(resident_id),
	)
	var short_path := "%s/%s/avatar_memory/avatar_evidence.json.tmp" % [
		memory_root,
		primary_segment,
	]
	_expect(
		_simulated_windows_path(legacy_path).length()
			>= WINDOWS_LEGACY_MAX_PATH,
		"旧式居民运行时记忆路径会越过传统 Windows 路径边界",
	)
	_expect(
		_simulated_windows_path(short_path).length()
			< WINDOWS_LEGACY_MAX_PATH,
		"超长居民身份使用固定长度运行时存储目录",
	)
	_expect(
		primary_segment == avatar_segment,
		"居民记忆与化身记忆使用同一条存储目录映射",
	)


func _test_agent_filesystem_cleanup(suffix: String) -> void:
	var root_path := "user://tests/agent_save/windows_cleanup_%s" % suffix
	_expect(
		_write_nested_fixture(root_path),
		"居民存档清理夹具可创建",
	)
	_expect(
		AGENT_FILE_SYSTEM.remove_tree(root_path) == OK,
		"居民存档目录可递归删除",
	)
	_expect(
		not DirAccess.dir_exists_absolute(
			ProjectSettings.globalize_path(root_path),
		),
		"居民存档根目录已删除",
	)
	var empty_path := "%s_empty" % root_path
	_expect(
		DirAccess.make_dir_recursive_absolute(
			ProjectSettings.globalize_path(empty_path),
		) in [OK, ERR_ALREADY_EXISTS],
		"居民空目录夹具可创建",
	)
	AGENT_FILE_SYSTEM.remove_empty_directory(empty_path)
	_expect(
		not DirAccess.dir_exists_absolute(
			ProjectSettings.globalize_path(empty_path),
		),
		"居民空目录释放遍历句柄后可删除",
	)


func _write_nested_fixture(root_path: String) -> bool:
	var nested_path := "%s/nested/child" % root_path
	var error := DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(nested_path),
	)
	if error not in [OK, ERR_ALREADY_EXISTS]:
		return false
	var file := FileAccess.open("%s/payload.txt" % nested_path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string("windows-directory-cleanup")
	file.flush()
	var write_error := file.get_error()
	file = null
	return write_error == OK


func _directory_is_empty(path: String) -> bool:
	var directory := DirAccess.open(ProjectSettings.globalize_path(path))
	if directory == null:
		return true
	var empty := (
		directory.get_files().is_empty()
		and directory.get_directories().is_empty()
	)
	directory = null
	return empty


func _simulated_windows_path(path: String) -> String:
	return "%s/%s" % [
		SIMULATED_WINDOWS_USER_ROOT,
		path.trim_prefix("user://"),
	]


func _expect_ok(result: Dictionary, message: String) -> void:
	_expect(
		bool(result.get("ok", false)),
		"%s（%s）" % [message, result.get("errorCode", "")],
	)


func _expect(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures.append(message)
