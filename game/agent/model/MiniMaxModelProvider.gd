class_name MiniMaxModelProvider
extends "res://agent/model/OpenAICompatibleModelProvider.gd"


const DEFAULT_ENDPOINT := "https://api.minimaxi.com/v1/chat/completions"
const M3_MODEL := "MiniMax-M3"
const M2_7_MODEL := "MiniMax-M2.7"
const M2_7_HIGHSPEED_MODEL := "MiniMax-M2.7-highspeed"
const M2_5_MODEL := "MiniMax-M2.5"
const M2_5_HIGHSPEED_MODEL := "MiniMax-M2.5-highspeed"
const M2_1_MODEL := "MiniMax-M2.1"
const M2_1_HIGHSPEED_MODEL := "MiniMax-M2.1-highspeed"
const M2_MODEL := "MiniMax-M2"
const DEFAULT_MODEL := M2_7_MODEL
const MODEL_DESCRIPTORS := [
	{"id": M3_MODEL, "label": "MiniMax M3", "input_modalities": ["text", "image"]},
	{"id": M2_7_MODEL, "label": "MiniMax M2.7", "input_modalities": ["text"]},
	{
		"id": M2_7_HIGHSPEED_MODEL,
		"label": "MiniMax M2.7 Highspeed",
		"input_modalities": ["text"],
	},
	{"id": M2_5_MODEL, "label": "MiniMax M2.5", "input_modalities": ["text"]},
	{
		"id": M2_5_HIGHSPEED_MODEL,
		"label": "MiniMax M2.5 Highspeed",
		"input_modalities": ["text"],
	},
	{"id": M2_1_MODEL, "label": "MiniMax M2.1", "input_modalities": ["text"]},
	{
		"id": M2_1_HIGHSPEED_MODEL,
		"label": "MiniMax M2.1 Highspeed",
		"input_modalities": ["text"],
	},
	{"id": M2_MODEL, "label": "MiniMax M2", "input_modalities": ["text"]},
]
const MODEL_IDS := [
	M3_MODEL,
	M2_7_MODEL,
	M2_7_HIGHSPEED_MODEL,
	M2_5_MODEL,
	M2_5_HIGHSPEED_MODEL,
	M2_1_MODEL,
	M2_1_HIGHSPEED_MODEL,
	M2_MODEL,
]
const DEFAULT_MAX_COMPLETION_TOKENS := 2048
const M2_MAX_COMPLETION_TOKENS := 204800
const M3_MAX_COMPLETION_TOKENS := 524288


func _provider_id() -> String:
	return "minimax"


func _provider_label() -> String:
	return "MiniMax"


func _transport_label() -> String:
	return "MiniMax API"


func get_provider_descriptor() -> Dictionary:
	var descriptor := super.get_provider_descriptor()
	descriptor["default_endpoint"] = DEFAULT_ENDPOINT
	descriptor["auth_required"] = true
	return descriptor


func _default_endpoint() -> String:
	return DEFAULT_ENDPOINT


func _default_model() -> String:
	return DEFAULT_MODEL


func _default_max_tokens() -> int:
	return DEFAULT_MAX_COMPLETION_TOKENS


func _build_request_body(model_request: Dictionary) -> Dictionary:
	var body := super._build_request_body(model_request)
	var requested_tokens := int(body.get("max_tokens", DEFAULT_MAX_COMPLETION_TOKENS))
	var max_completion_tokens := (
		M3_MAX_COMPLETION_TOKENS
		if _selected_model_id() == M3_MODEL
		else M2_MAX_COMPLETION_TOKENS
	)
	body["max_completion_tokens"] = clampi(
		requested_tokens,
		1,
		max_completion_tokens,
	)
	body.erase("max_tokens")
	return body


func _provider_request_options() -> Dictionary:
	# MiniMax 的思考内容通过 reasoning_split 单独返回，避免污染居民
	# 需要解析的决定 JSON。居民每轮都要尽快恢复行动，因此 M3 固定关闭
	# thinking；M2.x 的思考由服务端控制，官方接口不支持关闭。
	var options := {"reasoning_split": true}
	if _selected_model_id() == M3_MODEL:
		options["thinking"] = {"type": "disabled"}
	return options


func validate_configuration() -> Array[String]:
	var errors := super.validate_configuration()
	var model_id := _selected_model_id()
	if model_id not in MODEL_IDS:
		errors.append("MiniMax Provider 不支持模型：%s" % model_id)
	return errors


func _selected_model_id() -> String:
	return String(_config.get("model", DEFAULT_MODEL))


func _api_key_environment_names() -> Array[String]:
	return ["MINIMAX_API_KEY"]


func _missing_api_key_message(include_hint: bool) -> String:
	var message := "缺少 MINIMAX_API_KEY"
	if include_hint:
		message += "；可写入项目 .tmp/.env"
	return message
