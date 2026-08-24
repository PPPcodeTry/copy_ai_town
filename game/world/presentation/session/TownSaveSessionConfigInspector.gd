extends RefCounted
## 校验存档中的正式会话配置，不读取 Provider 凭据或当前设备状态。


const MANIFEST := preload(
	"res://world/presentation/session/TownSessionSaveManifest.gd"
)
const FIELDS: Array[String] = [
	"mode",
	"sessionId",
	"openingConfig",
	"residentIdentities",
	"residentBindings",
	"connectedResidents",
	"worldStartMode",
	"useLiveModel",
	"enablePlayerAvatar",
	"enableTestUi",
]


static func validate(
	value: Dictionary,
	session_id: String,
	expected_resident_ids: Array,
) -> Dictionary:
	if not _has_exact_fields(value, FIELDS):
		return {"ok": false}
	if (
		value.get("mode") not in ["new_game", "continue"]
		or value.get("sessionId") != session_id
		or not value.get("openingConfig") is Dictionary
		or (value.get("openingConfig", {}) as Dictionary).is_empty()
		or value.get("worldStartMode") not in ["formal", "development"]
	):
		return {"ok": false}
	for field_name in ["useLiveModel", "enablePlayerAvatar", "enableTestUi"]:
		if not value.get(field_name) is bool:
			return {"ok": false}
	var identities := MANIFEST.resident_ids(value.get("residentIdentities"))
	if (
		identities.get("ok") != true
		or identities.get("residentIds", []) != expected_resident_ids
		or not _connected_names_valid(value.get("connectedResidents"))
	):
		return {"ok": false}
	var binding_ids := _binding_resident_ids(value.get("residentBindings"))
	if binding_ids.get("ok") != true or binding_ids.get("values", []) != expected_resident_ids:
		return {"ok": false}
	return {"ok": true, "residentIds": binding_ids.get("values", [])}


static func _binding_resident_ids(value: Variant) -> Dictionary:
	if not value is Array:
		return {"ok": false, "values": []}
	var resident_ids: Array[String] = []
	for binding_value: Variant in value as Array:
		if not binding_value is Dictionary:
			return {"ok": false, "values": []}
		var binding := binding_value as Dictionary
		if not _has_exact_fields(binding, ["residentId", "llmBinding"]):
			return {"ok": false, "values": []}
		var resident_id_value: Variant = binding.get("residentId")
		var llm_value: Variant = binding.get("llmBinding")
		if (
			not resident_id_value is String
			or String(resident_id_value).is_empty()
			or String(resident_id_value) != String(resident_id_value).strip_edges()
			or resident_ids.has(String(resident_id_value))
			or not llm_value is Dictionary
		):
			return {"ok": false, "values": []}
		var llm := llm_value as Dictionary
		if (
			not _has_exact_fields(llm, ["mode", "providerId", "modelId"])
			or llm.get("mode") != "model"
			or not _non_empty_trimmed_string(llm.get("providerId"))
			or not _non_empty_trimmed_string(llm.get("modelId"))
		):
			return {"ok": false, "values": []}
		resident_ids.append(String(resident_id_value))
	resident_ids.sort()
	return {"ok": true, "values": resident_ids}


static func _connected_names_valid(value: Variant) -> bool:
	if not value is Array:
		return false
	var names: Array[String] = []
	for name_value: Variant in value as Array:
		if (
			not _non_empty_trimmed_string(name_value)
			or names.has(String(name_value))
		):
			return false
		names.append(String(name_value))
	return true


static func _non_empty_trimmed_string(value: Variant) -> bool:
	return value is String and not String(value).is_empty() and value == String(value).strip_edges()


static func _has_exact_fields(value: Dictionary, fields: Array) -> bool:
	if value.size() != fields.size():
		return false
	for field in fields:
		if not value.has(field):
			return false
	return true
