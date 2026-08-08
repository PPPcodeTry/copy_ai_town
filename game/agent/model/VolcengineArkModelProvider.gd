class_name VolcengineArkModelProvider
extends "res://agent/model/OpenAICompatibleModelProvider.gd"


const DEFAULT_ENDPOINT := "https://ark.cn-beijing.volces.com/api/v3/chat/completions"
const DEFAULT_MODEL := "doubao-seed-2-0-lite-260428"
const MODEL_DESCRIPTORS := [
	{"id": "doubao-seed-2-0-pro-260215", "label": "Doubao Seed 2.0 Pro", "input_modalities": ["text", "image"]},
	{"id": DEFAULT_MODEL, "label": "Doubao Seed 2.0 Lite", "input_modalities": ["text", "image"]},
	{"id": "doubao-seed-2-0-mini-260428", "label": "Doubao Seed 2.0 Mini", "input_modalities": ["text", "image"]},
	{"id": "doubao-seed-2-1-pro-260628", "label": "Doubao Seed 2.1 Pro", "input_modalities": ["text", "image"]},
	{"id": "doubao-seed-2-1-turbo-260628", "label": "Doubao Seed 2.1 Turbo", "input_modalities": ["text", "image"]},
]


func _init(
	request_host: Node = null,
	transport: Object = null,
	config: Dictionary = {},
) -> void:
	super(request_host, transport, config)


func _provider_id() -> String:
	return "volcengine-ark"


func _provider_label() -> String:
	return "火山方舟"


func _transport_label() -> String:
	return "方舟 OpenAI-compatible API"


func _default_endpoint() -> String:
	return DEFAULT_ENDPOINT


func _default_model() -> String:
	return DEFAULT_MODEL


func _provider_request_options() -> Dictionary:
	return {"thinking": {"type": "disabled"}}


func validate_configuration() -> Array[String]:
	var errors := super.validate_configuration()
	var model_id := String(_config.get("model", DEFAULT_MODEL))
	if not _supports_model(model_id):
		errors.append("方舟 Provider 不支持模型：%s" % model_id)
	return errors


func _supports_model(model_id: String) -> bool:
	for descriptor: Dictionary in MODEL_DESCRIPTORS:
		if descriptor.get("id") == model_id:
			return true
	return false


func _api_key_environment_names() -> Array[String]:
	return ["ARK_API_KEY"]


func _billing_error_identifiers() -> Array[String]:
	return [
		"AccountOverdueError",
		"OperationDenied.ServiceOverdue",
		"ServiceOverdue",
	]


func _missing_api_key_message(include_hint: bool) -> String:
	var message := "缺少 ARK_API_KEY"
	if include_hint:
		message += "；可写入项目 .tmp/.env"
	return message
