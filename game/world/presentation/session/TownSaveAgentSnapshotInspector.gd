extends RefCounted
## 校验一个 Agent 修订、居民载荷和居民集合，只通过返回值报告证据。


const SUPPORT := preload(
	"res://world/presentation/session/TownSaveInspectionSupport.gd"
)
const PHOTO_INSPECTOR := preload(
	"res://world/presentation/session/TownSaveConversationPhotoInspector.gd"
)
const COMPATIBILITY := preload(
	"res://world/presentation/session/TownSaveCompatibilityRegistry.gd"
)


static func inspect_versions(
	source: String,
	slot_id: String,
	session_id: String,
	save_revision: int,
) -> Dictionary:
	var root := source.path_join(
		"agent_saves/%s/sessions/%s/revisions/%d" % [
			slot_id, session_id, save_revision,
		],
	)
	var snapshot_result := SUPPORT.read_json(root.path_join("snapshot.json"))
	if snapshot_result.get("ok") != true:
		return {}
	var snapshot := snapshot_result.get("value", {}) as Dictionary
	var payload_version := -1
	var runtime_version := -1
	var memory_version := -1
	var residents_value: Variant = snapshot.get("residents")
	if not residents_value is Array:
		return {}
	for entry_value: Variant in residents_value as Array:
		if not entry_value is Dictionary:
			return {}
		var file_name := String((entry_value as Dictionary).get("file", ""))
		if not SUPPORT.safe_file_name(file_name):
			return {}
		var payload_path := root.path_join(file_name)
		var expected_sha := String((entry_value as Dictionary).get("sha256", ""))
		var file := FileAccess.open(payload_path, FileAccess.READ)
		if file == null:
			return {}
		var actual_length := file.get_length()
		file = null
		if (
			FileAccess.get_sha256(payload_path) != expected_sha
			or actual_length != int((entry_value as Dictionary).get("byte_length", -1))
		):
			return {}
		var loaded := SUPPORT.read_payload_envelope(payload_path)
		if loaded.get("ok") != true:
			return {}
		var envelope := loaded.get("envelope", {}) as Dictionary
		payload_version = SUPPORT.consistent_version(
			payload_version, int(envelope.get("format_version", -1)),
		)
		if payload_version > _current_version("residentPayload"):
			continue
		var resident_state := envelope.get("resident_state", {}) as Dictionary
		runtime_version = SUPPORT.consistent_version(
			runtime_version, int(resident_state.get("runtime_state_version", -1)),
		)
		if runtime_version > _current_version("residentRuntime"):
			continue
		var memory_state := resident_state.get("memory_system", {}) as Dictionary
		memory_version = SUPPORT.consistent_version(
			memory_version, int(memory_state.get("memory_state_version", -1)),
		)
	var versions := {}
	for pair in [
		["residentPayload", payload_version],
		["residentRuntime", runtime_version],
		["residentMemory", memory_version],
	]:
		var version := int(pair[1])
		if version >= 0:
			versions[String(pair[0])] = version
	return versions


static func _current_version(key: String) -> int:
	return int((COMPATIBILITY.VERSION_RULES.get(key, {}) as Dictionary).get(
		"current", 0,
	))


static func inspect_orphan(
	source: String,
	slot_id: String,
	session_id: String,
	save_revision: int,
	hashes: Array[Dictionary],
	issues: Array[Dictionary],
) -> Dictionary:
	var resident_set_path := source.path_join(
		"agent_saves/%s/sessions/%s/revisions/%d/resident_set.json" % [
			slot_id, session_id, save_revision,
		],
	)
	var loaded := SUPPORT.read_json(resident_set_path)
	var resident_ids: Variant = []
	if loaded.get("ok") == true:
		resident_ids = (loaded.get("value", {}) as Dictionary).get(
			"resident_ids", [],
		)
	var result := inspect(
		source, slot_id, session_id, save_revision,
		resident_ids, hashes, issues,
	)
	var versions := result.get("versions", {}) as Dictionary
	if int(versions.get("agent", -1)) < 0:
		var snapshot := SUPPORT.read_json(
			resident_set_path.get_base_dir().path_join("snapshot.json"),
		)
		var snapshot_value := snapshot.get("value", {}) as Dictionary
		if snapshot_value.get("format_version") is int:
			versions["agent"] = int(snapshot_value.get("format_version"))
	result["versions"] = versions
	return result


static func inspect(
	source: String,
	slot_id: String,
	session_id: String,
	save_revision: int,
	manifest_resident_ids_value: Variant,
	hashes: Array[Dictionary],
	issues: Array[Dictionary],
) -> Dictionary:
	var slot_root := source.path_join("agent_saves/%s" % slot_id)
	var root := source.path_join(
		"agent_saves/%s/sessions/%s/revisions/%d" % [
			slot_id,
			session_id,
			save_revision,
		],
	)
	var slot_result := SUPPORT.read_json(slot_root.path_join("slot.json"))
	var slot_manifest := slot_result.get("value", {}) as Dictionary
	var slot_structure_valid: bool = (
		slot_result.get("ok") == true
		and slot_manifest.get("format_version") is int
		and String(slot_manifest.get("slot_id", "")) == slot_id
	)
	if not slot_structure_valid:
		issues.append(SUPPORT.issue(
			"damaged_save",
			"agent_snapshot",
			SUPPORT.relative_path(source, slot_root.path_join("slot.json")),
			"Agent slot manifest is missing or invalid",
		))
	var slot_version := int(slot_manifest.get("format_version", -1))
	if (
		slot_structure_valid
		and slot_version != TownSaveSchemaRegistry.AGENT_SAVE_FORMAT_VERSION
	):
		return {
			"versions": {
				"agent": slot_version,
				"residentPayload": -1,
				"residentRuntime": -1,
				"residentMemory": -1,
			},
			"sameContext": true,
			"sameResidentSet": false,
			"residentIds": [],
		}
	var snapshot_result := SUPPORT.read_json(root.path_join("snapshot.json"))
	var resident_set_result := SUPPORT.read_json(root.path_join("resident_set.json"))
	if snapshot_result.get("ok") != true or resident_set_result.get("ok") != true:
		issues.append(SUPPORT.issue(
			"damaged_save",
			"agent_snapshot",
			SUPPORT.relative_path(source, root),
			"Agent snapshot or resident set is unreadable",
		))
		return {"versions": {}, "sameContext": false, "sameResidentSet": false}
	var snapshot := snapshot_result.get("value", {}) as Dictionary
	var resident_set := resident_set_result.get("value", {}) as Dictionary
	if (
		not snapshot.get("format_version") is int
		or int(snapshot.get("format_version", -1)) != slot_version
	):
		issues.append(SUPPORT.issue(
			"damaged_save",
			"agent_snapshot",
			SUPPORT.relative_path(source, root.path_join("snapshot.json")),
			"Agent snapshot version differs from its slot manifest",
		))
	var same_context: bool = slot_structure_valid and (
		String(snapshot.get("slot_id", "")) == slot_id
		and String(snapshot.get("session_id", "")) == session_id
		and int(snapshot.get("save_revision", -1)) == save_revision
	)
	if not same_context:
		issues.append(SUPPORT.issue(
			"damaged_save",
			"agent_snapshot",
			SUPPORT.relative_path(source, root.path_join("snapshot.json")),
			"World and Agent revision contexts differ",
		))

	var resident_entries_value: Variant = snapshot.get("residents")
	var resident_set_ids := SUPPORT.sorted_unique_strings(
		resident_set.get("resident_ids"),
	)
	var manifest_ids := SUPPORT.sorted_unique_strings(manifest_resident_ids_value)
	var snapshot_ids: Array[String] = []
	var payload_version := -1
	var runtime_version := -1
	var memory_version := -1
	var photo_references := {}
	if resident_entries_value is Array:
		for entry_value: Variant in resident_entries_value as Array:
			if not entry_value is Dictionary:
				continue
			var entry := entry_value as Dictionary
			var resident_id := String(entry.get("resident_id", ""))
			var resident_name := String(entry.get("resident_name", ""))
			var file_name := String(entry.get("file", ""))
			snapshot_ids.append(resident_id)
			if not SUPPORT.safe_file_name(file_name):
				issues.append(SUPPORT.issue(
					"damaged_save",
					"resident_payload",
					SUPPORT.relative_path(source, root),
					"resident payload file name is unsafe",
				))
				continue
			var payload_path := root.path_join(file_name)
			var actual_sha := FileAccess.get_sha256(payload_path)
			var expected_sha := String(entry.get("sha256", ""))
			hashes.append(SUPPORT.hash_evidence(
				source,
				"resident_payload",
				payload_path,
				expected_sha,
				actual_sha,
			))
			if actual_sha != expected_sha:
				issues.append(SUPPORT.issue(
					"damaged_save",
					"resident_payload",
					SUPPORT.relative_path(source, payload_path),
					"resident payload hash is invalid",
				))
				continue
			var payload_result := SUPPORT.read_payload_envelope(payload_path)
			if (
				payload_result.get("ok") != true
				or int(payload_result.get("byteLength", -1))
				!= int(entry.get("byte_length", -2))
			):
				issues.append(SUPPORT.issue(
					"damaged_save",
					"resident_payload",
					SUPPORT.relative_path(source, payload_path),
					"resident payload length or envelope is invalid",
				))
				continue
			var envelope := payload_result.get("envelope", {}) as Dictionary
			for ref in PHOTO_INSPECTOR.collect_references(envelope):
				photo_references[ref] = true
			if (
				String(envelope.get("resident_id", "")) != resident_id
				or String(envelope.get("resident_name", "")) != resident_name
			):
				issues.append(SUPPORT.issue(
					"damaged_save",
					"resident_payload",
					SUPPORT.relative_path(source, payload_path),
					"resident payload identity differs from Agent snapshot",
				))
			var resident_state := envelope.get("resident_state", {}) as Dictionary
			var memory_state := resident_state.get("memory_system", {}) as Dictionary
			payload_version = SUPPORT.consistent_version(
				payload_version,
				int(envelope.get("format_version", -1)),
			)
			runtime_version = SUPPORT.consistent_version(
				runtime_version,
				int(resident_state.get("runtime_state_version", -1)),
			)
			memory_version = SUPPORT.consistent_version(
				memory_version,
				int(memory_state.get("memory_state_version", -1)),
			)
	else:
		issues.append(SUPPORT.issue(
			"damaged_save",
			"agent_snapshot",
			SUPPORT.relative_path(source, root.path_join("snapshot.json")),
			"Agent resident entries are invalid",
		))
	if SUPPORT.INCONSISTENT_VERSION in [
		payload_version,
		runtime_version,
		memory_version,
	]:
		issues.append(SUPPORT.issue(
			"damaged_save",
			"resident_payload",
			SUPPORT.relative_path(source, root),
			"resident payload versions differ within one revision",
		))

	snapshot_ids.sort()
	var expected_resident_set_sha := String(snapshot.get("resident_set_sha256", ""))
	var actual_resident_set_sha := JSON.stringify(
		resident_set_ids.get("values", []),
	).sha256_text()
	hashes.append(SUPPORT.hash_evidence(
		source,
		"resident_set",
		root.path_join("resident_set.json"),
		expected_resident_set_sha,
		actual_resident_set_sha,
	))
	var same_resident_set: bool = (
		manifest_ids.get("ok") == true
		and resident_set_ids.get("ok") == true
		and snapshot_ids == manifest_ids.get("values", [])
		and snapshot_ids == resident_set_ids.get("values", [])
		and int(snapshot.get("resident_count", -1)) == snapshot_ids.size()
		and expected_resident_set_sha == actual_resident_set_sha
		and String(resident_set.get("resident_set_sha256", ""))
		== actual_resident_set_sha
	)
	if not same_resident_set:
		issues.append(SUPPORT.issue(
			"damaged_save",
			"agent_snapshot",
			SUPPORT.relative_path(source, root),
			"World and Agent resident sets differ",
		))
	return {
		"versions": {
			"agent": slot_version,
			"residentPayload": payload_version,
			"residentRuntime": runtime_version,
			"residentMemory": memory_version,
		},
		"sameContext": same_context,
		"sameResidentSet": same_resident_set,
		"residentIds": snapshot_ids,
		"photoReferences": _sorted_keys(photo_references),
	}


static func _sorted_keys(values: Dictionary) -> Array[String]:
	var result: Array[String] = []
	for value: Variant in values:
		result.append(String(value))
	result.sort()
	return result
