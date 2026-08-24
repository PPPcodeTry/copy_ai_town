class_name TownSaveArchiveInspector
extends RefCounted
## 只读检查一个存档根目录。调用方只需认识 inspect(source) 与返回报告。


const MANIFEST := preload(
	"res://world/presentation/session/TownSessionSaveManifest.gd"
)
const SUPPORT := preload(
	"res://world/presentation/session/TownSaveInspectionSupport.gd"
)
const COMPATIBILITY := preload(
	"res://world/presentation/session/TownSaveCompatibilityRegistry.gd"
)
const REVISION_INSPECTOR := preload(
	"res://world/presentation/session/TownSaveRevisionInspector.gd"
)
const TRANSACTION_INSPECTOR := preload(
	"res://world/presentation/session/TownSaveTransactionInspector.gd"
)
const PHOTO_INSPECTOR := preload(
	"res://world/presentation/session/TownSaveConversationPhotoInspector.gd"
)
const LOCAL_SETTINGS_INSPECTOR := preload(
	"res://world/presentation/session/TownSaveLocalSettingsInspector.gd"
)
const AGENT_INSPECTOR := preload(
	"res://world/presentation/session/TownSaveAgentSnapshotInspector.gd"
)

const REPORT_SCHEMA := "town-save-inspection-report"
const REPORT_SCHEMA_VERSION := 1
const STATUS_PRIORITY := {
	"empty": 0,
	"healthy": 0,
	"read_only": 1,
	"unsupported": 2,
	"unrecognized": 3,
	"migration_blocked": 4,
	"incomplete": 5,
	"recoverable": 6,
	"damaged": 7,
}
const SUPPORT_STATUS_PRIORITY := {
	"current": 0,
	"supported": 1,
	"unsupported": 2,
	"read_only": 3,
	"invalid": 4,
}


static func inspect(source_value: Variant) -> Dictionary:
	var source_result := SUPPORT.normalize_source(source_value)
	if source_result.get("ok") != true:
		return _unreadable_report("", source_result.get("issue", {}) as Dictionary)
	var source := String(source_result.get("source", ""))
	var shared_issues: Array[Dictionary] = []
	var module_versions := {}
	var module_hashes: Array[Dictionary] = []
	var module_states: Array[Dictionary] = []
	var profile_version := _read_profile_version(
		source, shared_issues, module_hashes,
	)
	module_versions["profile"] = profile_version
	module_states.append(_shared_module_state(
		"startup_profile",
		"town_startup_profile.json",
		FileAccess.file_exists(source.path_join("town_startup_profile.json")),
		profile_version,
		profile_version >= 0,
	))
	var custom_library_version := _read_custom_library_version(
		source, shared_issues, module_hashes,
	)
	module_versions["customResidentLibrary"] = custom_library_version
	var custom_library_present := FileAccess.file_exists(
		source.path_join("town_custom_resident_library.json"),
	)
	module_states.append(_shared_module_state(
		"custom_resident_library",
		"town_custom_resident_library.json",
		custom_library_present,
		custom_library_version,
		custom_library_version >= 0 or not custom_library_present,
	))
	if int(module_versions.get("customResidentLibrary", -1)) < 0:
		module_versions.erase("customResidentLibrary")
	var local_settings := LOCAL_SETTINGS_INSPECTOR.inspect(source)
	module_versions.merge(local_settings.get("versions", {}) as Dictionary, true)
	module_hashes.append_array(local_settings.get("hashes", []) as Array)
	shared_issues.append_array(local_settings.get("issues", []) as Array)
	module_states.append_array(local_settings.get("modules", []) as Array)
	var slot_ids := _slot_ids(source)
	var slots: Array[Dictionary] = []
	var report_issues := shared_issues.duplicate(true)
	for slot_id in slot_ids:
		var slot := _inspect_slot(source, slot_id, module_versions, shared_issues)
		slots.append(slot)
		report_issues.append_array((slot.get("issues", []) as Array).duplicate(true))
	return {
		"ok": true,
		"schema": REPORT_SCHEMA,
		"schemaVersion": REPORT_SCHEMA_VERSION,
		"source": source,
		"readOnly": true,
		"status": _report_status(slots, module_versions, shared_issues),
		"supportStatus": _support_status(slots, module_versions),
		"profileVersion": int(module_versions.get("profile", -1)),
		"moduleVersions": module_versions,
		"moduleHashes": module_hashes,
		"moduleStates": module_states,
		"slots": slots,
		"issues": report_issues,
		"error": {},
	}


static func _shared_module_state(
	module_id: String,
	path: String,
	present: bool,
	version: int,
	valid: bool,
) -> Dictionary:
	return {
		"module": module_id,
		"policy": "required",
		"path": path,
		"present": present,
		"version": version,
		"valid": valid,
	}


static func _inspect_slot(
	source: String,
	slot_id: String,
	shared_versions: Dictionary,
	shared_issues: Array[Dictionary],
) -> Dictionary:
	var manifest_root := source.path_join(
		"town_session_saves/slots/%s/manifests" % slot_id,
	)
	var revisions: Array[Dictionary] = []
	var directory := DirAccess.open(manifest_root)
	if directory != null:
		var manifest_files := directory.get_files()
		manifest_files.sort()
		for file_name in manifest_files:
			if file_name.ends_with(".json"):
				revisions.append(REVISION_INSPECTOR.inspect(
					source,
					slot_id,
					manifest_root.path_join(file_name),
					shared_versions,
					shared_issues,
				))
	for interrupted in TRANSACTION_INSPECTOR.inspect(source, slot_id):
		_merge_incomplete_revision(revisions, interrupted)
	for orphaned in _discover_orphaned_revisions(source, slot_id, revisions):
		_merge_incomplete_revision(revisions, orphaned)
	var session_assets := PHOTO_INSPECTOR.inspect(source, slot_id, revisions)
	_apply_session_asset_status(revisions, session_assets)
	revisions.sort_custom(func(left: Dictionary, right: Dictionary) -> bool:
		return int(left.get("saveRevision", -1)) > int(right.get("saveRevision", -1))
	)
	var latest_evidence := -1
	var latest_complete := -1
	var issues: Array[Dictionary] = []
	for revision in revisions:
		latest_evidence = maxi(latest_evidence, int(revision.get("saveRevision", -1)))
		if latest_complete < 0 and revision.get("status") == "complete":
			latest_complete = int(revision.get("saveRevision", -1))
		issues.append_array((revision.get("issues", []) as Array).duplicate(true))
	for session_asset in session_assets:
		issues.append_array((session_asset.get("issues", []) as Array).duplicate(true))
	var state := "empty"
	if not revisions.is_empty():
		state = String(revisions[0].get("status", "damaged"))
		if state == "complete":
			state = "healthy"
		elif state == "damaged" and latest_complete >= 0:
			state = "recoverable"
	return {
		"slotId": slot_id,
		"state": state,
		"latestEvidenceRevision": latest_evidence,
		"latestCompleteRevision": latest_complete,
		"revisions": revisions,
		"sessionAssets": session_assets,
		"issues": issues,
	}


static func _slot_ids(source: String) -> Array[String]:
	var found := {}
	for root in [
		source.path_join("town_session_saves/slots"),
		source.path_join("agent_saves"),
	]:
		var directory := DirAccess.open(root)
		if directory == null:
			continue
		for slot_id in directory.get_directories():
			if (
				root.ends_with("/agent_saves")
				and not FileAccess.file_exists(
					root.path_join(slot_id).path_join("slot.json"),
				)
				and not DirAccess.dir_exists_absolute(
					ProjectSettings.globalize_path(
						root.path_join(slot_id).path_join("sessions"),
					),
				)
			):
				continue
			if MANIFEST.validate_slot_id(slot_id).get("ok") == true:
				found[slot_id] = true
	var result: Array[String] = []
	for slot_id_value: Variant in found:
		result.append(String(slot_id_value))
	result.sort()
	return result


static func _apply_session_asset_status(
	revisions: Array[Dictionary],
	session_assets: Array[Dictionary],
) -> void:
	for session_asset in session_assets:
		if (session_asset.get("issues", []) as Array).is_empty():
			continue
		var session_id := String(session_asset.get("sessionId", ""))
		for revision_value: Variant in session_asset.get(
			"affectedRevisions", [],
		) as Array:
			var save_revision := int(revision_value)
			for revision in revisions:
				if (
					String(revision.get("sessionId", "")) == session_id
					and int(revision.get("saveRevision", -1)) == save_revision
					and revision.get("status") != "incomplete"
				):
					revision["status"] = "damaged"
					break


static func _read_profile_version(
	source: String,
	issues: Array[Dictionary],
	hashes: Array[Dictionary],
) -> int:
	var path := source.path_join("town_startup_profile.json")
	var loaded := SUPPORT.read_json(path)
	if loaded.get("ok") != true:
		issues.append(SUPPORT.issue(
			"damaged_save", "startup_profile", "town_startup_profile.json",
			String(loaded.get("reason", "startup profile is unreadable")),
		))
		return -1
	hashes.append(SUPPORT.observed_hash(source, "startup_profile", path))
	var profile := loaded.get("value", {}) as Dictionary
	var version_value: Variant = profile.get("schemaVersion")
	if (
		String(profile.get("schema", "")) != "town-startup-profile"
		or not version_value is int
	):
		issues.append(SUPPORT.issue(
			"damaged_save", "startup_profile", "town_startup_profile.json",
			"startup profile contract is invalid",
		))
		return -1
	return int(version_value)


static func _read_custom_library_version(
	source: String,
	issues: Array[Dictionary],
	hashes: Array[Dictionary],
) -> int:
	var path := source.path_join("town_custom_resident_library.json")
	if not FileAccess.file_exists(path):
		return -1
	var loaded := SUPPORT.read_json(path)
	if loaded.get("ok") != true:
		issues.append(SUPPORT.issue(
			"damaged_save", "custom_resident_library",
			"town_custom_resident_library.json",
			String(loaded.get("reason", "custom resident library is unreadable")),
		))
		return -1
	hashes.append(SUPPORT.observed_hash(source, "custom_resident_library", path))
	var library := loaded.get("value", {}) as Dictionary
	var version_value: Variant = library.get("schemaVersion")
	if (
		String(library.get("schema", "")) != "town-custom-resident-library"
		or not version_value is int
	):
		issues.append(SUPPORT.issue(
			"damaged_save", "custom_resident_library",
			"town_custom_resident_library.json",
			"custom resident library contract is invalid",
		))
		return -1
	var version := int(version_value)
	if version <= TownSaveSchemaRegistry.CUSTOM_RESIDENT_LIBRARY_SCHEMA_VERSION:
		var candidates_value: Variant = library.get("candidates")
		if (
			int(library.get("libraryRevision", 0)) < 1
			or not candidates_value is Array
			or not _custom_candidates_valid(candidates_value as Array)
		):
			issues.append(SUPPORT.issue(
				"damaged_save", "custom_resident_library",
				"town_custom_resident_library.json",
				"custom resident library contract is invalid",
			))
	return version


static func _custom_candidates_valid(candidates: Array) -> bool:
	var resident_ids: Array[String] = []
	for candidate_value: Variant in candidates:
		if not candidate_value is Dictionary:
			return false
		var candidate := candidate_value as Dictionary
		var resident_id := String(candidate.get("residentId", "")).strip_edges()
		if (
			resident_id.is_empty()
			or resident_ids.has(resident_id)
			or String(candidate.get("source", "custom")) != "custom"
		):
			return false
		resident_ids.append(resident_id)
	return true


static func _discover_orphaned_revisions(
	source: String,
	slot_id: String,
	existing: Array[Dictionary],
) -> Array[Dictionary]:
	var candidates := {}
	_collect_world_revision_directories(source, slot_id, candidates)
	_collect_agent_revision_directories(source, slot_id, candidates)
	var orphaned: Array[Dictionary] = []
	for candidate_value: Variant in candidates.values():
		var candidate := candidate_value as Dictionary
		var existing_index := _find_revision(existing, candidate)
		if existing_index >= 0:
			if not _needs_side_evidence(existing[existing_index]):
				continue
			var side_evidence := _inspect_orphaned_revision(source, slot_id, candidate)
			_merge_side_evidence(existing[existing_index], side_evidence)
			continue
		orphaned.append(_inspect_orphaned_revision(source, slot_id, candidate))
	return orphaned


static func _needs_side_evidence(revision: Dictionary) -> bool:
	return (
		String(revision.get("sessionId", "")).is_empty()
		or (revision.get("versions", {}) as Dictionary).is_empty()
		or (revision.get("hashes", []) as Array).is_empty()
	)


static func _merge_side_evidence(
	revision: Dictionary,
	side_evidence: Dictionary,
) -> void:
	if String(revision.get("sessionId", "")).is_empty():
		revision["sessionId"] = String(side_evidence.get("sessionId", ""))
	var versions := revision.get("versions", {}) as Dictionary
	versions.merge(side_evidence.get("versions", {}) as Dictionary, false)
	revision["versions"] = versions
	var evidence := revision.get("evidence", {}) as Dictionary
	evidence.merge(side_evidence.get("evidence", {}) as Dictionary, false)
	revision["evidence"] = evidence
	var hashes := revision.get("hashes", []) as Array
	for hash_value: Variant in side_evidence.get("hashes", []) as Array:
		var hash := hash_value as Dictionary
		var duplicate := false
		for existing_hash_value: Variant in hashes:
			var existing_hash := existing_hash_value as Dictionary
			if (
				String(existing_hash.get("module", ""))
				== String(hash.get("module", ""))
				and String(existing_hash.get("path", ""))
				== String(hash.get("path", ""))
			):
				duplicate = true
				break
		if not duplicate:
			hashes.append(hash.duplicate(true))
	revision["hashes"] = hashes
	var side_pair := side_evidence.get("worldAgentPair", {}) as Dictionary
	var pair := revision.get("worldAgentPair", {}) as Dictionary
	for key in ["manifestResidentIds", "worldResidentIds", "agentResidentIds"]:
		if (pair.get(key, []) as Array).is_empty():
			pair[key] = (side_pair.get(key, []) as Array).duplicate()
	pair["sameContext"] = bool(pair.get("sameContext", false)) or bool(
		side_pair.get("sameContext", false),
	)
	pair["sameResidentSet"] = bool(pair.get("sameResidentSet", false)) or bool(
		side_pair.get("sameResidentSet", false),
	)
	revision["worldAgentPair"] = pair
	var photo_references := revision.get("photoReferences", []) as Array
	for ref_value: Variant in side_evidence.get("photoReferences", []) as Array:
		if not photo_references.has(ref_value):
			photo_references.append(ref_value)
	photo_references.sort()
	revision["photoReferences"] = photo_references
	(revision.get("issues", []) as Array).append_array(
		(side_evidence.get("issues", []) as Array).duplicate(true),
	)


static func _inspect_orphaned_revision(
	source: String,
	slot_id: String,
	candidate: Dictionary,
) -> Dictionary:
	var save_revision := int(candidate.get("saveRevision", -1))
	var session_id := String(candidate.get("sessionId", ""))
	var world_path := String(candidate.get("worldPath", ""))
	var agent_path := String(candidate.get("agentPath", ""))
	var evidence_path := world_path if not world_path.is_empty() else agent_path
	var issues: Array[Dictionary] = [SUPPORT.issue(
		"transaction_interrupted", "device_and_transaction_state",
		evidence_path,
		"revision directory exists without a published manifest",
	)]
	var hashes: Array[Dictionary] = []
	var versions := {}
	var world_ids: Array = []
	var agent_result := {}
	if not world_path.is_empty():
		var absolute_world_path := source.path_join(world_path)
		_observe_world_orphan(
			source, absolute_world_path, versions, hashes, world_ids, issues,
		)
	if not agent_path.is_empty():
		agent_result = AGENT_INSPECTOR.inspect_orphan(
			source, slot_id, session_id, save_revision, hashes, issues,
		)
		versions.merge(agent_result.get("versions", {}) as Dictionary, true)
		for file_name in ["snapshot.json", "resident_set.json"]:
			var path := source.path_join(agent_path).path_join(file_name)
			if FileAccess.file_exists(path):
				hashes.append(SUPPORT.observed_hash(
					source, "agent_snapshot", path,
				))
	var result := SUPPORT.base_revision(
		save_revision,
		session_id,
		"incomplete",
		"orphaned_revision",
		issues,
	)
	result["versions"] = versions
	result["hashes"] = hashes
	result["evidence"] = {
		"worldPresent": not world_path.is_empty(),
		"agentPresent": not agent_path.is_empty(),
	}
	result["worldAgentPair"] = {
		"sameContext": bool(agent_result.get("sameContext", false)),
		"sameResidentSet": (
			not world_ids.is_empty()
			and world_ids == agent_result.get("residentIds", [])
		),
		"manifestResidentIds": [],
		"worldResidentIds": world_ids,
		"agentResidentIds": agent_result.get("residentIds", []),
	}
	result["photoReferences"] = agent_result.get("photoReferences", [])
	return result


static func _observe_world_orphan(
	source: String,
	revision_path: String,
	versions: Dictionary,
	hashes: Array[Dictionary],
	resident_ids: Array,
	issues: Array[Dictionary],
) -> void:
	for descriptor in [
		["world_snapshot.json", "world_snapshot"],
		["session_config.json", "session_config"],
		["world_log_snapshot.json", "world_log"],
	]:
		var path := revision_path.path_join(String(descriptor[0]))
		if FileAccess.file_exists(path):
			hashes.append(SUPPORT.observed_hash(
				source, String(descriptor[1]), path,
			))
	var world_path := revision_path.path_join("world_snapshot.json")
	var loaded := SUPPORT.read_json(world_path)
	if loaded.get("ok") != true:
		issues.append(SUPPORT.issue(
			"damaged_save", "world_snapshot",
			SUPPORT.relative_path(source, world_path),
			"orphaned World snapshot is unreadable",
		))
		return
	var world := loaded.get("value", {}) as Dictionary
	if world.get("schemaVersion") is int:
		versions["world"] = int(world.get("schemaVersion"))
	if world.get("worldDataVersion") is int:
		versions["worldData"] = int(world.get("worldDataVersion"))
	var state := world.get("state", {}) as Dictionary
	var residents_value: Variant = state.get("residents")
	if not residents_value is Array:
		return
	for resident_value: Variant in residents_value as Array:
		if resident_value is Dictionary:
			var resident_id := String((resident_value as Dictionary).get("residentId", ""))
			if not resident_id.is_empty() and not resident_ids.has(resident_id):
				resident_ids.append(resident_id)
	resident_ids.sort()


static func _collect_world_revision_directories(
	source: String,
	slot_id: String,
	result: Dictionary,
) -> void:
	var sessions_root := source.path_join(
		"town_session_saves/slots/%s/sessions" % slot_id,
	)
	var sessions := DirAccess.open(sessions_root)
	if sessions == null:
		return
	for session_id in sessions.get_directories():
		_collect_revision_directories(
			source, slot_id, session_id,
			sessions_root.path_join(session_id).path_join("revisions"),
			true, result,
		)


static func _collect_agent_revision_directories(
	source: String,
	slot_id: String,
	result: Dictionary,
) -> void:
	var sessions_root := source.path_join("agent_saves/%s/sessions" % slot_id)
	var sessions := DirAccess.open(sessions_root)
	if sessions == null:
		return
	for session_id in sessions.get_directories():
		_collect_revision_directories(
			source, slot_id, session_id,
			sessions_root.path_join(session_id).path_join("revisions"),
			false, result,
		)


static func _collect_revision_directories(
	source: String,
	slot_id: String,
	session_id: String,
	revisions_root: String,
	allow_padded: bool,
	result: Dictionary,
) -> void:
	var directory := DirAccess.open(revisions_root)
	if directory == null:
		return
	for revision_text in directory.get_directories():
		if not revision_text.is_valid_int():
			continue
		var revision := int(revision_text)
		if revision < 1 or (not allow_padded and str(revision) != revision_text):
			continue
		if MANIFEST.validate_context({
			"slot_id": slot_id,
			"session_id": session_id,
			"save_revision": revision,
		}).get("ok") != true:
			continue
		var key := "%s\u001f%d" % [session_id, revision]
		var candidate := result.get(key, {
			"sessionId": session_id,
			"saveRevision": revision,
		}) as Dictionary
		candidate["worldPath" if allow_padded else "agentPath"] = (
			SUPPORT.relative_path(
				source, revisions_root.path_join(revision_text),
			)
		)
		result[key] = candidate


static func _merge_incomplete_revision(
	revisions: Array[Dictionary],
	incomplete: Dictionary,
) -> void:
	var index := _find_revision(revisions, incomplete)
	if index < 0:
		revisions.append(incomplete)
		return
	var revision := revisions[index]
	if revision.get("status") != "damaged":
		revision["status"] = "incomplete"
	revision["transactionState"] = incomplete.get("transactionState", "unknown")
	(revision.get("issues", []) as Array).append_array(
		(incomplete.get("issues", []) as Array).duplicate(true),
	)


static func _find_revision(
	revisions: Array[Dictionary],
	candidate: Dictionary,
) -> int:
	for index in revisions.size():
		if (
			int(revisions[index].get("saveRevision", -1))
			== int(candidate.get("saveRevision", -2))
		):
			return index
	return -1


static func _support_status(
	slots: Array[Dictionary],
	module_versions: Dictionary,
) -> String:
	var selected := "invalid"
	var found := false
	for slot in slots:
		for revision_value: Variant in slot.get("revisions", []) as Array:
			var compatibility := (
				(revision_value as Dictionary).get("compatibility", {}) as Dictionary
			)
			if compatibility.is_empty():
				continue
			var candidate := String(compatibility.get("supportStatus", "invalid"))
			if (
				not found
				or int(SUPPORT_STATUS_PRIORITY.get(candidate, 4))
				> int(SUPPORT_STATUS_PRIORITY.get(selected, 4))
			):
				selected = candidate
			found = true
	var shared_support := COMPATIBILITY.classify_versions(module_versions)
	if shared_support.get("ok") != true:
		var candidate := String(shared_support.get("supportStatus", "invalid"))
		if (
			not found
			or int(SUPPORT_STATUS_PRIORITY.get(candidate, 4))
			> int(SUPPORT_STATUS_PRIORITY.get(selected, 4))
		):
			selected = candidate
		found = true
	return selected if found else "invalid"


static func _report_status(
	slots: Array[Dictionary],
	module_versions: Dictionary,
	shared_issues: Array[Dictionary],
) -> String:
	var selected := "empty" if slots.is_empty() else "healthy"
	for slot in slots:
		var candidate := String(slot.get("state", "damaged"))
		if int(STATUS_PRIORITY.get(candidate, 7)) > int(STATUS_PRIORITY.get(selected, 0)):
			selected = candidate
	var shared_candidate := "healthy"
	if SUPPORT.has_issue_type(shared_issues, "damaged_save"):
		shared_candidate = "damaged"
	else:
		var shared_support := COMPATIBILITY.classify_versions(module_versions)
		if shared_support.get("ok") != true:
			var support_status := String(shared_support.get("supportStatus", "invalid"))
			if support_status == COMPATIBILITY.STATUS_READ_ONLY:
				shared_candidate = "read_only"
			elif support_status == COMPATIBILITY.STATUS_UNSUPPORTED:
				shared_candidate = "unsupported"
			else:
				shared_candidate = "unrecognized"
	if (
		int(STATUS_PRIORITY.get(shared_candidate, 7))
		> int(STATUS_PRIORITY.get(selected, 0))
	):
		selected = shared_candidate
	return selected


static func _unreadable_report(source: String, issue_value: Dictionary) -> Dictionary:
	return {
		"ok": false,
		"schema": REPORT_SCHEMA,
		"schemaVersion": REPORT_SCHEMA_VERSION,
		"source": source,
		"readOnly": true,
		"status": "unreadable",
		"supportStatus": "invalid",
		"profileVersion": -1,
		"moduleVersions": {},
		"moduleHashes": [],
		"moduleStates": [],
		"slots": [],
		"issues": [issue_value.duplicate(true)],
		"error": issue_value.duplicate(true),
	}
