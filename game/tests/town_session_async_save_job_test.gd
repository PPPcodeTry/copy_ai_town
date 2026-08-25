extends SceneTree


const ASYNC_SAVE_JOB := preload(
	"res://world/presentation/session/TownSessionAsyncSaveJob.gd"
)
const SAVE_CONTEXT := preload(
	"res://world/presentation/session/TownSaveContext.gd"
)
const SHA256 := "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

var _failures: Array[String] = []
var _checks := 0


class SlowStore:
	extends RefCounted
	var delay_msec := 250
	var published_manifest: Dictionary = {}
	var fail_world_write := false

	func begin_slot_transaction(slot_id: Variant) -> Dictionary:
		return {
			"ok": true,
			"slotId": slot_id,
			"leaseToken": "async-test-lease",
		}

	func end_slot_transaction(_lease_token: Variant) -> Dictionary:
		return {"ok": true}

	func reserve_revision(slot_id: Variant, session_id: Variant) -> Dictionary:
		return {
			"ok": true,
			"context": {
				"slot_id": slot_id,
				"session_id": session_id,
				"save_revision": 11,
			},
		}

	func write_world_candidate(
		context: Dictionary,
		_snapshot: Dictionary,
		_session_config: Dictionary,
		_world_log_snapshot: Dictionary = {},
	) -> Dictionary:
		OS.delay_msec(delay_msec)
		if fail_world_write:
			return {
				"ok": false,
				"errorCode": "SESSION_SAVE_STORE_WRITE_FAILED",
				"retryable": true,
			}
		var revision_root := SAVE_CONTEXT.revision_directory(context)
		return {
			"ok": true,
			"snapshotRef": "%s/world_snapshot.json" % revision_root,
			"snapshotSha256": SHA256,
			"sessionConfigRef": "%s/session_config.json" % revision_root,
			"sessionConfigSha256": SHA256,
			"worldLogSnapshotRef": "%s/world_log_snapshot.json" % revision_root,
			"worldLogSnapshotSha256": SHA256,
		}

	func begin_intent(_context: Variant, _kind: Variant) -> Dictionary:
		return {"ok": true, "intentId": "save"}

	func write_intent_stage(
		_context: Variant,
		_kind: Variant,
		_intent_id: Variant,
		_stage: Variant,
		_payload: Variant = {},
	) -> Dictionary:
		return {"ok": true}

	func publish_manifest(manifest: Variant) -> Dictionary:
		published_manifest = (manifest as Dictionary).duplicate(true)
		return {"ok": true, "manifest": published_manifest.duplicate(true)}

	func list_published(_slot_id: Variant) -> Dictionary:
		return {"ok": true, "manifests": [], "invalid": []}

	func read_reference(_reference: Variant, _sha256: Variant = "") -> Dictionary:
		return {"ok": true, "value": {}}

	func list_incomplete(_slot_id: Variant) -> Dictionary:
		return {"ok": true, "records": []}


class AgentStore:
	extends RefCounted
	var calls := 0

	func save_snapshot(_context: Variant, _resident_payloads: Variant) -> Dictionary:
		calls += 1
		return {"ok": true}


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var store := SlowStore.new()
	var agent_store := AgentStore.new()
	var job: RefCounted = ASYNC_SAVE_JOB.new()
	var started_usec := Time.get_ticks_usec()
	var started := job.call(
		"start",
		store,
		_world_capture(),
		_agent_capture(),
		agent_store,
		_save_request(),
	) as Dictionary
	var start_msec := float(Time.get_ticks_usec() - started_usec) / 1000.0
	_expect_equal(started.get("pending"), true, "后台保存任务被接收")
	_expect_true(start_msec < 50.0, "启动后台任务不等待 250ms 慢写入")
	var first_poll := job.call("poll") as Dictionary
	_expect_equal(first_poll.get("pending"), true, "慢写入期间任务保持 pending")
	var completed := job.call("finish") as Dictionary
	var total_msec := float(Time.get_ticks_usec() - started_usec) / 1000.0
	_expect_equal(completed.get("ok"), true, "后台任务发布完整存档")
	_expect_true(total_msec >= 250.0, "保存总耗时仍包含慢写入")
	var timing := completed.get("timing", {}) as Dictionary
	_expect_true(float(timing.get("workerMsec", 0.0)) >= 250.0, "后台事务记录慢写入耗时")
	_expect_true(float(timing.get("totalMsec", 0.0)) >= 250.0, "任务记录端到端保存耗时")
	_expect_equal(
		(completed.get("context", {}) as Dictionary).get("save_revision"),
		11,
		"后台任务发布下一修订",
	)
	_expect_equal(agent_store.calls, 1, "Agent 与 World 在同一后台任务中各写一次")
	_expect_equal(
		store.published_manifest.get("save_revision"),
		11,
		"manifest 最后发布后台修订",
	)

	var failed_store := SlowStore.new()
	failed_store.delay_msec = 25
	failed_store.fail_world_write = true
	failed_store.published_manifest = {"save_revision": 10}
	var failed_agent_store := AgentStore.new()
	var failed_job: RefCounted = ASYNC_SAVE_JOB.new()
	var failed_started := failed_job.call(
		"start",
		failed_store,
		_world_capture(),
		_agent_capture(),
		failed_agent_store,
		_save_request(),
	) as Dictionary
	_expect_equal(failed_started.get("pending"), true, "失败注入任务仍由后台接收")
	var failed := failed_job.call("finish") as Dictionary
	_expect_equal(failed.get("ok"), false, "World 写入失败不会报告保存成功")
	_expect_equal(failed_agent_store.calls, 0, "World 候选失败后不提交 Agent 修订")
	_expect_equal(
		failed_store.published_manifest.get("save_revision"),
		10,
		"写入失败后上一份 manifest 保持不变",
	)
	_finish()


func _world_capture() -> Dictionary:
	return {
		"candidate": {
			"token": "captured-world",
			"sourceGeneration": 3,
			"worldRevision": 42,
			"identitySnapshot": {
				"status": "confirmed",
				"residents": [{
					"residentId": "resident_a",
					"residentName": "阿青",
				}],
			},
			"residentIds": ["resident_a"],
		},
		"snapshot": {
			"schema": "town-world-save",
			"schemaVersion": 2,
			"worldDataVersion": 1,
			"savedAt": {"day": 2},
		},
		"worldLogSnapshot": {
			"schema": "town-world-log-snapshot",
			"schemaVersion": 1,
			"timelineId": "timeline-async-test",
			"maxSequence": 0,
			"worldRevision": 42,
		},
	}


func _agent_capture() -> Dictionary:
	return {
		"context": {
			"slot_id": "slot-async-test",
			"session_id": "session-async-test",
			"save_revision": 10,
		},
		"residentIds": ["resident_a"],
		"residentPayloads": {
			"resident_a": {
				"resident_name": "阿青",
				"payload": PackedByteArray([1, 2, 3]),
			},
		},
	}


func _save_request() -> Dictionary:
	var identities := [{
		"residentId": "resident_a",
		"residentName": "阿青",
	}]
	return {
		"slotId": "slot-async-test",
		"sessionId": "session-async-test",
		"residentIdentities": identities.duplicate(true),
		"sessionConfig": {
			"mode": "new_game",
			"sessionId": "session-async-test",
			"openingConfig": {"worldId": "town-main"},
			"residentIdentities": identities.duplicate(true),
			"residentBindings": [{
				"residentId": "resident_a",
				"llmBinding": {
					"mode": "model",
					"providerId": "fake",
					"modelId": "fake",
				},
			}],
			"connectedResidents": ["阿青"],
			"worldStartMode": "formal",
			"useLiveModel": false,
			"enablePlayerAvatar": false,
			"enableTestUi": false,
		},
		"savedAt": "2026-08-25T19:00:00",
		"residentMessages": [],
	}


func _expect_true(value: bool, label: String) -> void:
	_checks += 1
	if value:
		return
	_failures.append(label)
	push_error(label)


func _expect_equal(actual: Variant, expected: Variant, label: String) -> void:
	_checks += 1
	if actual == expected:
		return
	_failures.append("%s (actual=%s expected=%s)" % [label, actual, expected])
	push_error(_failures.back())


func _finish() -> void:
	var exit_code := 0 if _failures.is_empty() else 1
	if _failures.is_empty():
		print("TOWN_SESSION_ASYNC_SAVE_JOB_PASS checks=%d" % _checks)
	else:
		printerr("TOWN_SESSION_ASYNC_SAVE_JOB_FAIL: %s" % "; ".join(_failures))
	var audio_controller := root.get_node_or_null("TownAudioController")
	if audio_controller != null and audio_controller.has_method("prepare_shutdown"):
		audio_controller.call("prepare_shutdown")
	for _index in 5:
		await process_frame
	await create_timer(0.3, true, false, true).timeout
	quit(exit_code)
