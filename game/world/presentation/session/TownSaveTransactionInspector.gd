extends RefCounted
## 从事务日志发现没有正常结束的保存或恢复修订。


const JOURNAL := preload(
	"res://world/presentation/session/TownSaveJournalStates.gd"
)
const SUPPORT := preload(
	"res://world/presentation/session/TownSaveInspectionSupport.gd"
)
const MANIFEST := preload(
	"res://world/presentation/session/TownSessionSaveManifest.gd"
)


static func inspect(source: String, slot_id: String) -> Array[Dictionary]:
	var intent_root := source.path_join(
		"town_session_saves/slots/%s/intents" % slot_id,
	)
	var paths: Array[String] = []
	_collect_json_paths(intent_root, paths)
	paths.sort()
	var latest_by_intent := {}
	var invalid_by_intent := {}
	for path in paths:
		var loaded := SUPPORT.read_json(path)
		if loaded.get("ok") != true:
			var invalid := _invalid_revision_from_path(source, intent_root, path, slot_id)
			if not invalid.is_empty():
				_append_invalid(invalid_by_intent, intent_root, path, invalid)
			continue
		var record := loaded.get("value", {}) as Dictionary
		if String(record.get("schema", "")) != "town-session-save-intent":
			if path.get_file() != "000_allocation.json":
				var invalid := _invalid_revision_from_path(source, intent_root, path, slot_id)
				if not invalid.is_empty():
					_append_invalid(invalid_by_intent, intent_root, path, invalid)
			continue
		var context_value: Variant = record.get("context")
		if not context_value is Dictionary:
			var invalid := _invalid_revision_from_path(source, intent_root, path, slot_id)
			if not invalid.is_empty():
				_append_invalid(invalid_by_intent, intent_root, path, invalid)
			continue
		var context := context_value as Dictionary
		var kind := String(record.get("kind", ""))
		var session_id := String(context.get("session_id", ""))
		var save_revision := int(context.get("save_revision", -1))
		var state := String(record.get("state", ""))
		var order := int(record.get("order", -1))
		if (
			String(context.get("slot_id", "")) != slot_id
			or session_id.is_empty()
			or save_revision < 1
			or not kind in ["save", "restore"]
			or int(JOURNAL.STAGE_ORDER.get(state, -2)) != order
			or (kind == "save" and state not in JOURNAL.SAVE_STAGES)
			or (kind == "restore" and state not in JOURNAL.RESTORE_STAGES)
		):
			var invalid := _invalid_revision_from_path(source, intent_root, path, slot_id)
			if not invalid.is_empty():
				_append_invalid(invalid_by_intent, intent_root, path, invalid)
			continue
		var key := "%s\u001f%s\u001f%d\u001f%s" % [
			kind,
			session_id,
			save_revision,
			String(record.get("intent_id", "")),
		]
		var previous := latest_by_intent.get(key, {}) as Dictionary
		if previous.is_empty() or order > int(previous.get("order", -1)):
			latest_by_intent[key] = {
				"kind": kind,
				"sessionId": session_id,
				"saveRevision": save_revision,
				"state": state,
				"order": order,
				"path": SUPPORT.relative_path(source, path),
			}
	var intent_keys := {}
	for key_value: Variant in latest_by_intent:
		intent_keys[key_value] = true
	for key_value: Variant in invalid_by_intent:
		intent_keys[key_value] = true
	var revisions: Array[Dictionary] = []
	for key_value: Variant in intent_keys:
		var key := String(key_value)
		var latest := latest_by_intent.get(key, {}) as Dictionary
		var state := String(latest.get("state", "unknown"))
		var kind := String(latest.get("kind", ""))
		if (
			(kind == "save" and state == "manifest_published")
			or (kind == "restore" and state == "restore_completed")
		):
			continue
		for invalid_value: Variant in invalid_by_intent.get(key, []) as Array:
			revisions.append((invalid_value as Dictionary).duplicate(true))
		if latest.is_empty():
			continue
		var issue_value := SUPPORT.issue(
			"transaction_interrupted",
			"device_and_transaction_state",
			String(latest.get("path", "")),
			"save or restore transaction did not reach its completed state",
		)
		revisions.append(_incomplete_revision(
			int(latest.get("saveRevision", -1)),
			String(latest.get("sessionId", "")),
			state,
			[issue_value],
		))
	revisions.append_array(_allocation_revisions(source, slot_id, revisions))
	return revisions


static func _append_invalid(
	invalid_by_intent: Dictionary,
	intent_root: String,
	path: String,
	invalid: Dictionary,
) -> void:
	var key := _intent_key_from_path(intent_root, path)
	if key.is_empty():
		return
	var entries := invalid_by_intent.get(key, []) as Array
	entries.append(invalid)
	invalid_by_intent[key] = entries


static func _intent_key_from_path(intent_root: String, path: String) -> String:
	var relative := path.trim_prefix("%s/" % intent_root.trim_suffix("/"))
	var parts := relative.split("/", false)
	if (
		parts.size() < 5
		or parts[0] not in ["save", "restore"]
		or not String(parts[2]).is_valid_int()
	):
		return ""
	return "%s\u001f%s\u001f%d\u001f%s" % [
		String(parts[0]),
		String(parts[1]),
		int(parts[2]),
		String(parts[3]),
	]


static func _allocation_revisions(
	source: String,
	slot_id: String,
	existing: Array[Dictionary],
) -> Array[Dictionary]:
	var root := source.path_join(
		"town_session_saves/slots/%s/allocations" % slot_id,
	)
	var directory := DirAccess.open(root)
	if directory == null:
		return []
	var result: Array[Dictionary] = []
	var files := directory.get_files()
	files.sort()
	for file_name in files:
		if not file_name.ends_with(".json"):
			continue
		var save_revision := SUPPORT.revision_from_manifest_file(file_name)
		if save_revision < 1:
			continue
		var already_reported := false
		for revision in existing:
			if int(revision.get("saveRevision", -1)) == save_revision:
				already_reported = true
				break
		if already_reported:
			continue
		var manifest_path := source.path_join(
			"town_session_saves/slots/%s/manifests/%020d.json" % [
				slot_id, save_revision,
			],
		)
		if FileAccess.file_exists(manifest_path):
			continue
		var path := root.path_join(file_name)
		var loaded := SUPPORT.read_json(path)
		var allocation := loaded.get("value", {}) as Dictionary
		var context := allocation.get("context", {}) as Dictionary
		var valid: bool = (
			loaded.get("ok") == true
			and String(allocation.get("schema", ""))
			== "town-session-save-allocation"
			and int(allocation.get("schema_version", -1)) == 1
			and String(context.get("slot_id", "")) == slot_id
			and int(context.get("save_revision", -1)) == save_revision
			and not String(context.get("session_id", "")).is_empty()
		)
		var session_id := String(context.get("session_id", ""))
		result.append(_incomplete_revision(
			save_revision,
			session_id,
			"revision_allocated" if valid else "allocation_invalid",
			[SUPPORT.issue(
				"transaction_interrupted" if valid else "damaged_save",
				"device_and_transaction_state",
				SUPPORT.relative_path(source, path),
				(
					"save revision was allocated but never published"
					if valid
					else "save revision allocation record is unreadable or invalid"
				),
			)],
		))
	return result


static func _invalid_revision_from_path(
	source: String,
	intent_root: String,
	path: String,
	slot_id: String,
) -> Dictionary:
	var relative := path.trim_prefix("%s/" % intent_root.trim_suffix("/"))
	var parts := relative.split("/", false)
	if parts.size() < 5 or parts[0] not in ["save", "restore"]:
		return {}
	var session_id := String(parts[1])
	var revision_text := String(parts[2])
	if not revision_text.is_valid_int():
		return {}
	var save_revision := int(revision_text)
	if MANIFEST.validate_context({
		"slot_id": slot_id,
		"session_id": session_id,
		"save_revision": save_revision,
	}).get("ok") != true:
		return {}
	return _incomplete_revision(
		save_revision,
		session_id,
		"journal_invalid",
		[SUPPORT.issue(
			"damaged_save",
			"device_and_transaction_state",
			SUPPORT.relative_path(source, path),
			"transaction journal record is unreadable or invalid",
		)],
	)


static func _collect_json_paths(path: String, result: Array[String]) -> void:
	var directory := DirAccess.open(path)
	if directory == null:
		return
	for file_name in directory.get_files():
		if file_name.ends_with(".json"):
			result.append(path.path_join(file_name))
	for directory_name in directory.get_directories():
		_collect_json_paths(path.path_join(directory_name), result)


static func _incomplete_revision(
	save_revision: int,
	session_id: String,
	transaction_state: String,
	issues: Array,
) -> Dictionary:
	return SUPPORT.base_revision(
		save_revision,
		session_id,
		"incomplete",
		transaction_state,
		issues,
	)
