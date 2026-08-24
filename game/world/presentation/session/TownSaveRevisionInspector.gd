extends RefCounted
## 校验一个已发布修订的 manifest、World、配置、日志和 Agent 完整对。


const COMPATIBILITY := preload(
	"res://world/presentation/session/TownSaveCompatibilityRegistry.gd"
)
const MANIFEST := preload(
	"res://world/presentation/session/TownSessionSaveManifest.gd"
)
const SUPPORT := preload(
	"res://world/presentation/session/TownSaveInspectionSupport.gd"
)
const AGENT_INSPECTOR := preload(
	"res://world/presentation/session/TownSaveAgentSnapshotInspector.gd"
)
const SESSION_CONFIG_INSPECTOR := preload(
	"res://world/presentation/session/TownSaveSessionConfigInspector.gd"
)
const PHOTO_INSPECTOR := preload(
	"res://world/presentation/session/TownSaveConversationPhotoInspector.gd"
)
const WORLD_CODEC := preload(
	"res://world/runtime/persistence/TownWorldSaveCodec.gd"
)


static func inspect(
	source: String,
	expected_slot_id: String,
	manifest_path: String,
	shared_versions: Dictionary,
	shared_issues: Array[Dictionary],
) -> Dictionary:
	var manifest_result := SUPPORT.read_json(manifest_path)
	if manifest_result.get("ok") != true:
		return SUPPORT.base_revision(
			SUPPORT.revision_from_manifest_file(manifest_path.get_file()),
			"",
			"damaged",
			"unknown",
			shared_issues + [SUPPORT.issue(
				"damaged_save",
				"session_manifest",
				SUPPORT.relative_path(source, manifest_path),
				String(manifest_result.get("reason", "manifest is unreadable")),
			)],
		)
	var manifest := manifest_result.get("value", {}) as Dictionary
	var file_revision := SUPPORT.revision_from_manifest_file(manifest_path.get_file())
	var save_revision := int(manifest.get("save_revision", -1))
	var session_id := String(manifest.get("session_id", ""))
	var issues: Array[Dictionary] = []
	for shared_issue in shared_issues:
		issues.append(shared_issue.duplicate(true))
	var hashes: Array[Dictionary] = []
	var early_versions := shared_versions.duplicate(true)
	if manifest.get("schema_version") is int:
		early_versions["manifest"] = int(manifest.get("schema_version"))
	else:
		issues.append(SUPPORT.issue(
			"damaged_save", "session_manifest",
			SUPPORT.relative_path(source, manifest_path),
			"manifest version field is missing or invalid",
		))
	var envelope_support := COMPATIBILITY.classify_versions(early_versions)
	if envelope_support.get("ok") != true:
		return _version_only_revision(
			source,
			manifest_path,
			manifest,
			file_revision,
			early_versions,
			envelope_support,
			issues,
		)
	var components := manifest.get("components", {}) as Dictionary
	var world_component := components.get("world", {}) as Dictionary
	var world_log_component := components.get("world_log", {}) as Dictionary
	for version_field in ["schema_version", "world_data_version"]:
		if world_component.get(version_field) is int:
			early_versions[
				"world" if version_field == "schema_version" else "worldData"
			] = int(world_component.get(version_field))
		else:
			issues.append(SUPPORT.issue(
				"damaged_save", "session_manifest",
				SUPPORT.relative_path(source, manifest_path),
				"World component version field is missing or invalid",
			))
	var agent_slot_version := _agent_slot_version(
		source, expected_slot_id,
	)
	if agent_slot_version >= 0:
		early_versions["agent"] = agent_slot_version
	if world_log_component.get("schema_version") is int:
		early_versions["worldLog"] = int(
			world_log_component.get("schema_version"),
		)
	if not session_id.is_empty() and save_revision >= 1:
		early_versions.merge(AGENT_INSPECTOR.inspect_versions(
			source, expected_slot_id, session_id, save_revision,
		), true)
	var version_support := COMPATIBILITY.classify_versions(early_versions)
	if version_support.get("ok") != true:
		return _version_only_revision(
			source,
			manifest_path,
			manifest,
			file_revision,
			early_versions,
			version_support,
			issues,
		)
	if String(manifest.get("slot_id", "")) != expected_slot_id:
		issues.append(SUPPORT.issue(
			"damaged_save", "session_manifest",
			SUPPORT.relative_path(source, manifest_path),
			"manifest slot does not match its directory",
		))
	if save_revision != file_revision:
		issues.append(SUPPORT.issue(
			"damaged_save", "session_manifest",
			SUPPORT.relative_path(source, manifest_path),
			"manifest revision does not match its file name",
		))
	var manifest_contract_valid: bool = MANIFEST.validate(manifest).get("ok") == true
	var world_result := _read_hashed_json_reference(
		source,
		String(world_component.get("snapshot_ref", "")),
		String(world_component.get("snapshot_sha256", "")),
		"world_snapshot",
		hashes,
		issues,
	)
	var config_result := _read_hashed_json_reference(
		source,
		String(manifest.get("session_config_ref", "")),
		String(manifest.get("session_config_sha256", "")),
		"session_config",
		hashes,
		issues,
	)
	var world_log_result := {"ok": true, "version": -1}
	if not world_log_component.is_empty():
		world_log_result = _inspect_world_log(
			source, world_log_component, world_component, hashes, issues,
		)
	var context_check := MANIFEST.validate_context({
		"slot_id": expected_slot_id,
		"session_id": session_id,
		"save_revision": save_revision,
	})
	var agent_result := {}
	if context_check.get("ok") == true and save_revision >= 1:
		agent_result = AGENT_INSPECTOR.inspect(
			source, expected_slot_id, session_id, save_revision,
			manifest.get("resident_ids", []), hashes, issues,
		)
	else:
		issues.append(SUPPORT.issue(
			"damaged_save", "session_manifest",
			SUPPORT.relative_path(source, manifest_path),
			"manifest context is unsafe or invalid",
		))
	var world := world_result.get("value", {}) as Dictionary
	var world_schema_version := int(world.get("schemaVersion", -1))
	var world_data_version := int(world.get("worldDataVersion", -1))
	if world_result.get("ok") == true and (
		not world.get("schemaVersion") is int
		or not world.get("worldDataVersion") is int
		or world_schema_version != int(world_component.get("schema_version", -2))
		or world_data_version != int(world_component.get("world_data_version", -2))
	):
		issues.append(SUPPORT.issue(
			"damaged_save", "world_snapshot",
			String(world_component.get("snapshot_ref", "")),
			"World file versions differ from the manifest",
		))
	if (
		world_result.get("ok") == true
		and world_schema_version
		in TownSaveSchemaRegistry.WORLD_SUPPORTED_SCHEMA_VERSIONS
	):
		var world_errors := WORLD_CODEC.validate_envelope(
			world,
			{
				"worldId": world.get("worldId"),
				"schemaVersion": world.get("worldDataSchemaVersion"),
				"dataVersion": world.get("worldDataVersion"),
			},
			{"worldId": world.get("worldId")},
		)
		var decoded := WORLD_CODEC.decode_checked(world.get("state"))
		if not world_errors.is_empty() or decoded.get("ok") != true:
			issues.append(SUPPORT.issue(
				"damaged_save", "world_snapshot",
				String(world_component.get("snapshot_ref", "")),
				"World snapshot contract is invalid",
			))
	var state := world.get("state", {}) as Dictionary
	var activity_runtime := state.get("activityRuntime", {}) as Dictionary
	var agent_versions := agent_result.get("versions", {}) as Dictionary
	var versions := {
		"world": world_schema_version,
		"manifest": int(manifest.get("schema_version", -1)),
		"profile": int(shared_versions.get("profile", -1)),
		"agent": int(agent_versions.get("agent", -1)),
		"residentPayload": int(agent_versions.get("residentPayload", -1)),
		"residentRuntime": int(agent_versions.get("residentRuntime", -1)),
		"residentMemory": int(agent_versions.get("residentMemory", -1)),
		"worldData": world_data_version,
	}
	if int(shared_versions.get("customResidentLibrary", -1)) >= 0:
		versions["customResidentLibrary"] = int(
			shared_versions.get("customResidentLibrary", -1),
		)
	for optional_version in ["provider", "playerSettings"]:
		if int(shared_versions.get(optional_version, -1)) >= 0:
			versions[optional_version] = int(shared_versions.get(optional_version))
	if int(world_log_result.get("version", -1)) >= 0:
		versions["worldLog"] = int(world_log_result.get("version", -1))
	var evidence := {
		"versions": versions.duplicate(true),
		"worldSectionCount": state.size(),
		"activitySourceFingerprint": String(activity_runtime.get("sourceFingerprint", "")),
		"residentPathLayout": "",
	}
	var compatibility := COMPATIBILITY.detect_release(evidence)
	var migration_path := {}
	if compatibility.get("ok") == true:
		if not manifest_contract_valid:
			issues.append(SUPPORT.issue(
				"damaged_save", "session_manifest",
				SUPPORT.relative_path(source, manifest_path),
				"manifest contract is invalid",
			))
		migration_path = COMPATIBILITY.migration_path(
			String(compatibility.get("migrationStartRelease", "")),
		)
		if migration_path.get("ok") != true:
			issues.append((migration_path.get("error", {}) as Dictionary).duplicate(true))
	else:
		issues.append((compatibility.get("error", {}) as Dictionary).duplicate(true))
	var manifest_ids := SUPPORT.sorted_unique_strings(manifest.get("resident_ids", []))
	var world_ids := _world_resident_ids(world)
	var config_contract := SESSION_CONFIG_INSPECTOR.validate(
		config_result.get("value", {}) as Dictionary,
		session_id,
		manifest_ids.get("values", []) as Array,
	)
	var world_set_matches: bool = (
		manifest_ids.get("ok") == true
		and world_ids.get("ok") == true
		and manifest_ids.get("values", []) == world_ids.get("values", [])
	)
	if not world_set_matches:
		issues.append(SUPPORT.issue(
			"damaged_save", "world_snapshot",
			String(world_component.get("snapshot_ref", "")),
			"World and Agent resident sets differ",
		))
	if (
		config_contract.get("ok") != true
	):
		issues.append(SUPPORT.issue(
			"damaged_save", "session_config",
			String(manifest.get("session_config_ref", "")),
			"session config resident bindings differ from the saved resident set",
		))
	var photo_references := PHOTO_INSPECTOR.collect_references(world)
	for ref_value: Variant in agent_result.get("photoReferences", []) as Array:
		var ref := String(ref_value)
		if not photo_references.has(ref):
			photo_references.append(ref)
	photo_references.sort()
	return {
		"saveRevision": save_revision,
		"sessionId": session_id,
		"savedAt": String(manifest.get("saved_at", "")),
		"status": _status(compatibility, migration_path, issues),
		"versions": versions,
		"evidence": evidence,
		"compatibility": compatibility,
		"migrationPath": migration_path,
		"hashes": hashes,
		"photoReferences": photo_references,
		"worldAgentPair": {
			"sameContext": bool(agent_result.get("sameContext", false)),
			"sameResidentSet": (
				bool(agent_result.get("sameResidentSet", false)) and world_set_matches
			),
			"manifestResidentIds": manifest_ids.get("values", []),
			"worldResidentIds": world_ids.get("values", []),
			"agentResidentIds": agent_result.get("residentIds", []),
		},
		"transactionState": String(manifest.get("state", "unknown")),
		"issues": issues,
	}


static func _agent_slot_version(
	source: String,
	slot_id: String,
) -> int:
	var loaded := SUPPORT.read_json(
		source.path_join("agent_saves/%s/slot.json" % slot_id),
	)
	if loaded.get("ok") != true:
		return -1
	var slot := loaded.get("value", {}) as Dictionary
	return (
		int(slot.get("format_version"))
		if slot.get("format_version") is int
		else -1
	)


static func _version_only_revision(
	source: String,
	manifest_path: String,
	manifest: Dictionary,
	file_revision: int,
	versions: Dictionary,
	compatibility: Dictionary,
	issues: Array[Dictionary],
) -> Dictionary:
	var revision_issues := issues.duplicate(true)
	revision_issues.append((compatibility.get("error", {}) as Dictionary).duplicate(true))
	var result := SUPPORT.base_revision(
		int(manifest.get("save_revision", file_revision)),
		String(manifest.get("session_id", "")),
		_status(compatibility, {}, revision_issues),
		String(manifest.get("state", "unknown")),
		revision_issues,
	)
	result["savedAt"] = String(manifest.get("saved_at", ""))
	result["versions"] = versions.duplicate(true)
	result["compatibility"] = compatibility.duplicate(true)
	result["hashes"] = [SUPPORT.observed_hash(
		source, "session_manifest", manifest_path,
	)]
	result["photoReferences"] = []
	return result


static func _inspect_world_log(
	source: String,
	component: Dictionary,
	world_component: Dictionary,
	hashes: Array[Dictionary],
	issues: Array[Dictionary],
) -> Dictionary:
	var loaded := _read_hashed_json_reference(
		source,
		String(component.get("snapshot_ref", "")),
		String(component.get("snapshot_sha256", "")),
		"world_log",
		hashes,
		issues,
	)
	if loaded.get("ok") != true:
		return {"ok": false, "version": int(component.get("schema_version", -1))}
	var snapshot := loaded.get("value", {}) as Dictionary
	var valid: bool = (
		String(snapshot.get("schema", "")) == "town-world-log-snapshot"
		and int(snapshot.get("schemaVersion", -1)) == int(component.get("schema_version", -2))
		and int(snapshot.get("worldRevision", -1))
		== int(world_component.get("world_revision", -2))
		and String(snapshot.get("timelineId", ""))
		== String(component.get("timeline_id", ""))
		and int(snapshot.get("maxSequence", -1)) == int(component.get("max_sequence", -2))
		and int(snapshot.get("storageSchemaVersion", -1)) == 1
		and snapshot.get("readState") is Dictionary
		and snapshot.get("segments", []) is Array
	)
	if not valid:
		issues.append(SUPPORT.issue(
			"damaged_save", "world_log",
			String(component.get("snapshot_ref", "")),
			"world log snapshot contract is invalid",
		))
		return {"ok": false, "version": int(component.get("schema_version", -1))}
	var expected_sequence := 1
	for descriptor_value: Variant in snapshot.get("segments", []) as Array:
		if not descriptor_value is Dictionary:
			issues.append(SUPPORT.issue(
				"damaged_save", "world_log",
				String(component.get("snapshot_ref", "")),
				"world log segment descriptor is invalid",
			))
			continue
		var descriptor := descriptor_value as Dictionary
		var record_count := int(descriptor.get("recordCount", -1))
		var end_sequence := int(descriptor.get("endSequence", -1))
		if (
			int(descriptor.get("startSequence", -1)) != expected_sequence
			or record_count < 1
			or end_sequence != expected_sequence + record_count - 1
		):
			issues.append(SUPPORT.issue(
				"damaged_save", "world_log",
				String(component.get("snapshot_ref", "")),
				"world log segment sequence descriptor is invalid",
			))
			continue
		var segment_result := _read_hashed_json_reference(
			source,
			String(descriptor.get("segmentRef", "")),
			String(descriptor.get("segmentSha256", "")),
			"world_log",
			hashes,
			issues,
		)
		if segment_result.get("ok") != true:
			continue
		var segment := segment_result.get("value", {}) as Dictionary
		var records_value: Variant = segment.get("records")
		var segment_valid: bool = (
			String(segment.get("schema", "")) == "town-world-log-segment"
			and int(segment.get("schemaVersion", -1)) == 1
			and String(segment.get("timelineId", ""))
			== String(snapshot.get("timelineId", ""))
			and int(segment.get("startSequence", -1)) == expected_sequence
			and int(segment.get("endSequence", -1)) == end_sequence
			and records_value is Array
			and (records_value as Array).size() == record_count
		)
		if segment_valid:
			for record_value: Variant in records_value as Array:
				if (
					not record_value is Dictionary
					or int((record_value as Dictionary).get("sequence", -1))
					!= expected_sequence
				):
					segment_valid = false
					break
				expected_sequence += 1
		if not segment_valid:
			issues.append(SUPPORT.issue(
				"damaged_save", "world_log",
				String(descriptor.get("segmentRef", "")),
				"world log segment content is invalid",
			))
			expected_sequence = end_sequence + 1
	if int(snapshot.get("maxSequence", -1)) != expected_sequence - 1:
		issues.append(SUPPORT.issue(
			"damaged_save", "world_log",
			String(component.get("snapshot_ref", "")),
			"world log segment chain does not reach maxSequence",
		))
	return {"ok": true, "version": int(component.get("schema_version", -1))}


static func _read_hashed_json_reference(
	source: String,
	reference: String,
	expected_sha256: String,
	module_id: String,
	hashes: Array[Dictionary],
	issues: Array[Dictionary],
) -> Dictionary:
	var root := source.path_join("town_session_saves")
	var path := root.path_join(reference)
	if not SUPPORT.safe_relative_reference(reference):
		issues.append(SUPPORT.issue(
			"damaged_save", module_id, reference,
			"save reference leaves the archive root",
		))
		return {"ok": false}
	var actual_sha := FileAccess.get_sha256(path)
	hashes.append(SUPPORT.hash_evidence(
		source, module_id, path, expected_sha256, actual_sha,
	))
	if actual_sha.is_empty() or actual_sha != expected_sha256:
		issues.append(SUPPORT.issue(
			"damaged_save", module_id,
			SUPPORT.relative_path(source, path),
			"referenced file is missing or its hash differs",
		))
		return {"ok": false}
	var loaded := SUPPORT.read_json(path)
	if loaded.get("ok") != true:
		issues.append(SUPPORT.issue(
			"damaged_save", module_id,
			SUPPORT.relative_path(source, path),
			String(loaded.get("reason", "referenced JSON is invalid")),
		))
	return loaded


static func _world_resident_ids(world: Dictionary) -> Dictionary:
	var state_value: Variant = world.get("state")
	if not state_value is Dictionary:
		return {"ok": false, "values": []}
	var residents_value: Variant = (state_value as Dictionary).get("residents")
	if not residents_value is Array:
		return {"ok": false, "values": []}
	var resident_ids: Array[String] = []
	for resident_value: Variant in residents_value as Array:
		if not resident_value is Dictionary:
			return {"ok": false, "values": []}
		var resident_id_value: Variant = (resident_value as Dictionary).get("residentId")
		if not resident_id_value is String:
			return {"ok": false, "values": []}
		resident_ids.append(resident_id_value as String)
	return SUPPORT.sorted_unique_strings(resident_ids)


static func _status(
	compatibility: Dictionary,
	migration_path: Dictionary,
	issues: Array[Dictionary],
) -> String:
	if SUPPORT.has_issue_type(issues, "damaged_save"):
		return "damaged"
	if compatibility.get("ok") == true:
		return "complete" if migration_path.get("ok") == true else "migration_blocked"
	var support_status := String(compatibility.get("supportStatus", "invalid"))
	if support_status == COMPATIBILITY.STATUS_READ_ONLY:
		return "read_only"
	if support_status == COMPATIBILITY.STATUS_UNSUPPORTED:
		return "unsupported"
	return "unrecognized"
