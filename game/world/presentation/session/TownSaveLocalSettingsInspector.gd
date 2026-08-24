extends RefCounted
## 只读记录可尽力迁移的本机配置；缺失不影响正式存档完整性。


const SUPPORT := preload(
	"res://world/presentation/session/TownSaveInspectionSupport.gd"
)


static func inspect(source: String) -> Dictionary:
	var versions := {}
	var hashes: Array[Dictionary] = []
	var issues: Array[Dictionary] = []
	var modules: Array[Dictionary] = []
	_inspect_provider(source, versions, hashes, issues, modules)
	_inspect_config_file(
		source,
		"player_settings",
		"playerSettings",
		"player_settings.cfg",
		"meta",
		"schema_version",
		versions,
		hashes,
		issues,
		modules,
	)
	_inspect_config_file(
		source,
		"legacy_audio_settings",
		"",
		"audio_settings.cfg",
		"audio",
		"",
		versions,
		hashes,
		issues,
		modules,
	)
	return {
		"versions": versions,
		"hashes": hashes,
		"issues": issues,
		"modules": modules,
	}


static func _inspect_provider(
	source: String,
	versions: Dictionary,
	hashes: Array[Dictionary],
	issues: Array[Dictionary],
	modules: Array[Dictionary],
) -> void:
	var relative_path := "provider_settings.json"
	var path := source.path_join(relative_path)
	if not FileAccess.file_exists(path):
		modules.append(_module("provider_config", relative_path, false, -1, true))
		return
	var loaded := SUPPORT.read_json(path)
	var version := -1
	var valid: bool = loaded.get("ok") == true
	if valid:
		var config := loaded.get("value", {}) as Dictionary
		var version_value: Variant = config.get("schemaVersion", 1)
		valid = version_value is int
		if valid:
			version = int(version_value)
	if valid:
		versions["provider"] = version
	else:
		issues.append(_invalid_issue(
			"provider_config", relative_path, "Provider config is unreadable or unversioned",
		))
	hashes.append(SUPPORT.observed_hash(source, "provider_config", path))
	modules.append(_module("provider_config", relative_path, true, version, valid))


static func _inspect_config_file(
	source: String,
	module_id: String,
	version_key: String,
	relative_path: String,
	required_section: String,
	version_field: String,
	versions: Dictionary,
	hashes: Array[Dictionary],
	issues: Array[Dictionary],
	modules: Array[Dictionary],
) -> void:
	var path := source.path_join(relative_path)
	if not FileAccess.file_exists(path):
		modules.append(_module(module_id, relative_path, false, -1, true))
		return
	var config := ConfigFile.new()
	var valid: bool = config.load(path) == OK and config.has_section(required_section)
	var version := 0 if version_field.is_empty() else -1
	if valid and not version_field.is_empty():
		var version_value: Variant = config.get_value(
			required_section, version_field, null,
		)
		valid = version_value is int
		if valid:
			version = int(version_value)
	if valid and not version_key.is_empty():
		versions[version_key] = version
	if not valid:
		issues.append(_invalid_issue(
			module_id, relative_path, "local settings file is unreadable or unversioned",
		))
	hashes.append(SUPPORT.observed_hash(source, module_id, path))
	modules.append(_module(module_id, relative_path, true, version, valid))


static func _module(
	module_id: String,
	path: String,
	present: bool,
	version: int,
	valid: bool,
) -> Dictionary:
	return {
		"module": module_id,
		"policy": "best_effort",
		"path": path,
		"present": present,
		"version": version,
		"valid": valid,
	}


static func _invalid_issue(
	module_id: String,
	path: String,
	reason: String,
) -> Dictionary:
	return SUPPORT.issue(
		"best_effort_module_invalid", module_id, path, reason,
	)
