class_name GenericOpenAICompatibleModelProvider
extends "res://agent/model/OpenAICompatibleModelProvider.gd"


const DEFAULT_MODEL := "custom"
const MODEL_DESCRIPTORS := [
	{
		"id": DEFAULT_MODEL,
		"label": "自定义模型",
		"input_modalities": ["text"],
		"runtime_modalities_configurable": true,
	},
]


func _init(
	request_host: Node = null,
	transport: Object = null,
	config: Dictionary = {},
) -> void:
	super(request_host, transport, config)


func _provider_id() -> String:
	return "openai-compatible"


func _provider_label() -> String:
	return "OpenAI Compatible"


func _transport_label() -> String:
	return "通用 OpenAI-compatible API"


func _default_endpoint() -> String:
	return OS.get_environment("OPENAI_COMPATIBLE_ENDPOINT").strip_edges()


func _default_model() -> String:
	return DEFAULT_MODEL


func _build_request_body(model_request: Dictionary) -> Dictionary:
	var body := super._build_request_body(model_request)
	body["model"] = _api_model()
	body.erase("max_tokens")
	return body


func validate_configuration() -> Array[String]:
	var errors := super.validate_configuration()
	if String(_config.get("endpoint", _default_endpoint())).strip_edges().is_empty():
		errors.append("缺少 OpenAI-compatible endpoint")
	if _api_model().is_empty():
		errors.append("缺少 OpenAI-compatible api_model")
	return errors


func _api_model() -> String:
	return String(
		_config.get("api_model", OS.get_environment("OPENAI_COMPATIBLE_MODEL"))
	).strip_edges()


func _api_key_environment_names() -> Array[String]:
	return ["OPENAI_COMPATIBLE_API_KEY"]


func _missing_api_key_message(include_hint: bool) -> String:
	var message := "缺少 OPENAI_COMPATIBLE_API_KEY"
	if include_hint:
		message += "；可写入项目 .tmp/.env"
	return message
