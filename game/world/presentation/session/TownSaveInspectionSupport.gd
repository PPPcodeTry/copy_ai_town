extends RefCounted
## 存档只读检查模块共用的文件读取、路径和报告值函数。


const COMPATIBILITY := preload(
	"res://world/presentation/session/TownSaveCompatibilityRegistry.gd"
)
const INCONSISTENT_VERSION := -2


static func read_payload_envelope(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {"ok": false}
	var byte_length := file.get_length()
	var bytes := file.get_buffer(byte_length)
	var read_error := file.get_error()
	file = null
	if read_error != OK or bytes.size() != byte_length:
		return {"ok": false}
	var decoded: Variant = bytes_to_var(bytes)
	if not decoded is Dictionary:
		return {"ok": false}
	return {
		"ok": true,
		"byteLength": byte_length,
		"envelope": (decoded as Dictionary).duplicate(true),
	}


static func read_json(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {"ok": false, "reason": "file is missing or unreadable"}
	var text := file.get_as_text()
	var read_error := file.get_error()
	file = null
	if read_error != OK:
		return {"ok": false, "reason": "file read failed"}
	var parser := JSON.new()
	if parser.parse(text) != OK:
		return {"ok": false, "reason": "file is not valid JSON"}
	var parsed: Variant = parser.data
	if not parsed is Dictionary:
		return {"ok": false, "reason": "file is not a JSON object"}
	return {
		"ok": true,
		"value": (_normalize_numbers(parsed) as Dictionary).duplicate(true),
	}


static func sorted_unique_strings(value: Variant) -> Dictionary:
	if not value is Array:
		return {"ok": false, "values": []}
	var result: Array[String] = []
	for item: Variant in value as Array:
		if not item is String or String(item).is_empty() or result.has(String(item)):
			return {"ok": false, "values": []}
		result.append(String(item))
	result.sort()
	return {"ok": true, "values": result}


static func consistent_version(current: int, candidate: int) -> int:
	if current == INCONSISTENT_VERSION:
		return INCONSISTENT_VERSION
	if current < 0:
		return candidate
	return current if current == candidate else INCONSISTENT_VERSION


static func has_issue_type(issues: Array[Dictionary], type: String) -> bool:
	for issue in issues:
		if String(issue.get("type", "")) == type:
			return true
	return false


static func normalize_source(value: Variant) -> Dictionary:
	if not value is String:
		return {"ok": false, "issue": issue(
			"invalid_evidence",
			"archive",
			"",
			"save archive source must be a path",
		)}
	var source := (value as String).strip_edges().trim_suffix("/")
	if source.is_empty() or not DirAccess.dir_exists_absolute(
		ProjectSettings.globalize_path(source),
	):
		return {"ok": false, "issue": issue(
			"invalid_evidence",
			"archive",
			source,
			"save archive source does not exist",
		)}
	return {"ok": true, "source": source}


static func safe_relative_reference(reference: String) -> bool:
	if (
		reference.is_empty()
		or reference != reference.strip_edges()
		or reference.begins_with("/")
		or reference.ends_with("/")
		or reference.contains("\\")
		or reference.contains("//")
	):
		return false
	for segment in reference.split("/", false):
		if segment in ["", ".", ".."]:
			return false
	return true


static func safe_file_name(file_name: String) -> bool:
	return (
		not file_name.is_empty()
		and file_name == file_name.get_file()
		and file_name not in [".", ".."]
		and not file_name.contains("\\")
	)


static func hash_evidence(
	source: String,
	module_id: String,
	path: String,
	expected: String,
	actual: String,
) -> Dictionary:
	return {
		"module": module_id,
		"path": relative_path(source, path),
		"expected": expected,
		"actual": actual,
		"status": "match" if not expected.is_empty() and expected == actual else "mismatch",
	}


static func observed_hash(
	source: String,
	module_id: String,
	path: String,
) -> Dictionary:
	return {
		"module": module_id,
		"path": relative_path(source, path),
		"expected": "",
		"actual": FileAccess.get_sha256(path),
		"status": "observed",
	}


static func issue(
	type: String,
	module_id: String,
	path: String,
	reason: String,
) -> Dictionary:
	return {
		"type": type,
		"code": String(COMPATIBILITY.ERROR_TYPES.get(type, "")),
		"module": module_id,
		"path": path,
		"reason": reason,
	}


static func revision_from_manifest_file(file_name: String) -> int:
	var text := file_name.trim_suffix(".json")
	return int(text) if file_name.ends_with(".json") and text.is_valid_int() else -1


static func base_revision(
	save_revision: int,
	session_id: String,
	status: String,
	transaction_state: String,
	issues: Array,
) -> Dictionary:
	return {
		"saveRevision": save_revision,
		"sessionId": session_id,
		"savedAt": "",
		"status": status,
		"versions": {},
		"evidence": {},
		"compatibility": {},
		"migrationPath": {},
		"hashes": [],
		"photoReferences": [],
		"worldAgentPair": {
			"sameContext": false,
			"sameResidentSet": false,
			"manifestResidentIds": [],
			"worldResidentIds": [],
			"agentResidentIds": [],
		},
		"transactionState": transaction_state,
		"issues": issues.duplicate(true),
	}


static func relative_path(source: String, path: String) -> String:
	return path.trim_prefix("%s/" % source.trim_suffix("/"))


static func _normalize_numbers(value: Variant) -> Variant:
	if typeof(value) == TYPE_FLOAT:
		var number := float(value)
		if not is_nan(number) and not is_inf(number) and number == floorf(number):
			return int(number)
	if value is Array:
		var array: Array = []
		for item: Variant in value as Array:
			array.append(_normalize_numbers(item))
		return array
	if value is Dictionary:
		var dictionary := {}
		for key: Variant in value as Dictionary:
			dictionary[key] = _normalize_numbers((value as Dictionary)[key])
		return dictionary
	return value
