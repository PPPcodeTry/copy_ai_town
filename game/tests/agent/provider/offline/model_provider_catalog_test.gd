extends "res://tests/agent/support/AgentTestCase.gd"


const CatalogScript := preload("res://agent/model/ModelProviderCatalog.gd")



func _initialize() -> void:
	var catalog: RefCounted = CatalogScript.new()
	var provider_ids: Array[String] = []
	for descriptor: Dictionary in catalog.call("list_providers"):
		provider_ids.append(String(descriptor.get("id", "")))
	_expect_equal(
		provider_ids,
		[
			"deepseek",
			"volcengine-ark",
			"aliyun-bailian",
			"kimi",
			"zhipu-glm",
			"xiaomi-mimo",
			"openai-compatible",
			"fake",
		],
		"catalog exposes the provider adapters in stable order",
	)

	_expect_equal(_model_ids(catalog, "deepseek"), ["deepseek-v4-flash", "deepseek-v4-pro"], "DeepSeek exposes V4 models")
	_expect_equal(
		_model_ids(catalog, "volcengine-ark"),
		[
			"doubao-seed-2-0-pro-260215",
			"doubao-seed-2-0-lite-260428",
			"doubao-seed-2-0-mini-260428",
			"doubao-seed-2-1-pro-260628",
			"doubao-seed-2-1-turbo-260628",
		],
		"Ark exposes Doubao Seed 2.0 and 2.1",
	)
	_expect_equal(
		_model_ids(catalog, "aliyun-bailian"),
		[
			"qwen3.5-plus",
			"qwen3.5-flash",
			"qwen3.5-397b-a17b",
			"qwen3.5-122b-a10b",
			"qwen3.5-35b-a3b",
			"qwen3.5-27b",
			"qwen3.6-max-preview",
			"qwen3.6-plus",
			"qwen3.6-flash",
			"qwen3.7-max",
			"qwen3.7-plus",
		],
		"Bailian exposes the documented Qwen 3.5 through 3.7 catalog",
	)
	_expect_equal(
		_model_ids(catalog, "kimi"),
		["kimi-k2.5", "kimi-k2.6", "kimi-k2.7-code-highspeed", "kimi-k3"],
		"Kimi keeps only the faster K2.7 variant alongside K2.5, K2.6, and K3",
	)
	_expect_equal(
		_model_ids(catalog, "zhipu-glm"),
		["glm-4.7", "glm-5", "glm-5.1", "glm-5.2", "glm-5v-turbo"],
		"GLM exposes 4.7 through current",
	)
	_expect_equal(
		_model_ids(catalog, "xiaomi-mimo"),
		["mimo-v2.5-pro", "mimo-v2.5"],
		"Xiaomi exposes the current MiMo V2.5 chat models",
	)
	_expect_equal(_model_ids(catalog, "openai-compatible"), ["custom"], "generic OpenAI compatibility has one custom model entry")
	_expect_equal(_model_ids(catalog, "fake"), ["fake"], "Fake is represented by the same two-level catalog")
	_expect_equal(catalog.call("default_model_id"), "deepseek-v4-flash", "DeepSeek remains the global default")
	_expect_equal(catalog.call("default_model_id", "volcengine-ark"), "doubao-seed-2-0-lite-260428", "Ark defaults to Seed 2.0 Lite")
	_expect_equal(catalog.call("default_model_id", "aliyun-bailian"), "qwen3.7-plus", "Bailian defaults to Qwen 3.7 Plus")
	_expect_equal(catalog.call("default_model_id", "kimi"), "kimi-k3", "Kimi defaults to K3")
	_expect_equal(catalog.call("default_model_id", "zhipu-glm"), "glm-5.2", "GLM defaults to 5.2")
	_expect_equal(catalog.call("default_model_id", "xiaomi-mimo"), "mimo-v2.5-pro", "Xiaomi defaults to MiMo V2.5 Pro")
	_expect_equal(
		catalog.call("model_descriptor", "deepseek", "deepseek-v4-flash").get("input_modalities"),
		["text"],
		"DeepSeek declares text input explicitly",
	)
	_expect_equal(
		catalog.call("model_descriptor", "aliyun-bailian", "qwen3.7-plus").get("input_modalities"),
		["text", "image"],
		"Qwen 3.7 Plus declares visual input explicitly",
	)
	_expect_equal(
		catalog.call("model_descriptor", "aliyun-bailian", "qwen3.7-max").get("input_modalities"),
		["text"],
		"unverified Qwen visual input fails closed",
	)
	_expect_equal(
		catalog.call("model_descriptor", "zhipu-glm", "glm-5v-turbo").get("input_modalities"),
		["text", "image"],
		"GLM-5V declares visual input explicitly",
	)
	_expect_equal(
		catalog.call("model_descriptor", "xiaomi-mimo", "mimo-v2.5-pro").get("input_modalities"),
		["text"],
		"MiMo V2.5 Pro declares text input",
	)
	_expect_equal(
		catalog.call("model_descriptor", "xiaomi-mimo", "mimo-v2.5").get("input_modalities"),
		["text", "image"],
		"MiMo V2.5 declares visual input",
	)
	_expect_equal(
		catalog.call("model_descriptor", "fake", "fake").get("input_modalities"),
		["text", "image"],
		"Fake supports offline visual-flow testing",
	)

	var k3_creation := catalog.call(
		"create_model",
		"kimi",
		"kimi-k3",
		null,
		{"api_key": "test-key"},
	) as Dictionary
	_expect_equal(k3_creation.get("ok"), true, "catalog creates K3 through the model seam")
	if k3_creation.get("ok") == true:
		_expect_equal(k3_creation.get("model_descriptor", {}).get("provider_id"), "kimi", "created K3 retains its route")
		_expect_equal(k3_creation.get("provider").call("get_provider_descriptor").get("model_id"), "kimi-k3", "K3 model id reaches the shared adapter")
		_expect_equal(
			k3_creation.get("provider").call("get_provider_descriptor").get("input_modalities"),
			["text", "image"],
			"selected model input modalities reach the adapter",
		)
	var fake_creation := catalog.call("create_model", "fake", "fake", null, {}) as Dictionary
	_expect_equal(fake_creation.get("ok"), true, "catalog creates Fake through the model seam")
	if fake_creation.get("ok") == true:
		_expect_equal(
			fake_creation.get("provider").call("get_provider_descriptor").get("input_modalities"),
			["text", "image"],
			"Fake receives the registered input modalities",
		)
	var visual_custom := catalog.call(
		"create_model",
		"openai-compatible",
		"custom",
		null,
		{"input_modalities": ["text", "image"]},
	) as Dictionary
	_expect_equal(visual_custom.get("ok"), true, "custom model accepts an explicit visual-input declaration")
	if visual_custom.get("ok") == true:
		_expect_equal(
			visual_custom.get("provider").call("get_provider_descriptor").get("input_modalities"),
			["text", "image"],
			"custom visual-input declaration reaches the adapter",
		)
	var suggestive_custom_name := catalog.call(
		"create_model",
		"openai-compatible",
		"custom",
		null,
		{"api_model": "vendor-vision-image-model"},
	) as Dictionary
	_expect_equal(suggestive_custom_name.get("ok"), true, "custom model accepts arbitrary wire model names")
	if suggestive_custom_name.get("ok") == true:
		_expect_equal(
			suggestive_custom_name.get("provider").call("get_provider_descriptor").get("input_modalities"),
			["text"],
			"custom remains text-only unless the user explicitly declares image input",
		)
	var invalid_custom_modalities := catalog.call(
		"create_model",
		"openai-compatible",
		"custom",
		null,
		{"input_modalities": ["image"]},
	) as Dictionary
	_expect_equal(
		invalid_custom_modalities.get("ok"),
		false,
		"custom model declarations must retain Agent text input",
	)
	var null_custom_modality := catalog.call(
		"create_model",
		"openai-compatible",
		"custom",
		null,
		{"input_modalities": [null]},
	) as Dictionary
	_expect_equal(
		null_custom_modality.get("ok"),
		false,
		"custom model rejects null input modality elements",
	)
	var numeric_custom_modality := catalog.call(
		"create_model",
		"openai-compatible",
		"custom",
		null,
		{"input_modalities": [1]},
	) as Dictionary
	_expect_equal(
		numeric_custom_modality.get("ok"),
		false,
		"custom model rejects numeric input modality elements",
	)
	var dictionary_custom_modality := catalog.call(
		"create_model",
		"openai-compatible",
		"custom",
		null,
		{"input_modalities": [{}]},
	) as Dictionary
	_expect_equal(
		dictionary_custom_modality.get("ok"),
		false,
		"custom model rejects dictionary input modality elements",
	)
	var protected_builtin := catalog.call(
		"create_model",
		"deepseek",
		"deepseek-v4-flash",
		null,
		{"input_modalities": ["text", "image"]},
	) as Dictionary
	_expect_equal(protected_builtin.get("ok"), true, "built-in model creation ignores capability expansion")
	if protected_builtin.get("ok") == true:
		_expect_equal(
			protected_builtin.get("provider").call("get_provider_descriptor").get("input_modalities"),
			["text"],
			"built-in model capabilities remain authoritative",
		)

	var legacy_kimi := catalog.call("create_provider", "kimi", null, {"api_key": "test-key"}) as Dictionary
	_expect_equal(legacy_kimi.get("ok"), true, "legacy provider creation remains available")
	if legacy_kimi.get("ok") == true:
		_expect_equal(legacy_kimi.get("provider").call("get_provider_descriptor").get("model_id"), "kimi-k3", "legacy Kimi creation resolves to K3")

	var mismatch := catalog.call("create_provider", "deepseek", null, {
		"api_key": "test-key",
		"model": "kimi-k3",
	}) as Dictionary
	_expect_equal(mismatch.get("ok"), false, "registered models cannot be sent to the wrong provider")
	_expect(_errors_contain(mismatch.get("errors", []), "未知模型"), "provider/model mismatch returns a useful error")
	var unsupported_kimi := catalog.call("create_provider", "kimi", null, {
		"api_key": "test-key",
		"model": "kimi-unknown",
	}) as Dictionary
	_expect_equal(unsupported_kimi.get("ok"), false, "unknown Kimi models cannot bypass the catalog")
	_expect(_errors_contain(unsupported_kimi.get("errors", []), "未知模型"), "unknown model returns a useful error")

	var unknown := catalog.call("create_model", "kimi", "missing-model", null, {}) as Dictionary
	_expect_equal(unknown.get("ok"), false, "unknown models are rejected")
	var shared_deepseek := catalog.call("register_model", {
		"id": "shared-model-id",
		"label": "DeepSeek Shared",
		"provider_id": "deepseek",
		"input_modalities": ["text"],
	}) as Dictionary
	var shared_kimi := catalog.call("register_model", {
		"id": "shared-model-id",
		"label": "Kimi Shared",
		"provider_id": "kimi",
		"input_modalities": ["text"],
	}) as Dictionary
	_expect_equal(shared_deepseek.get("ok"), true, "model ids are unique inside a Provider")
	_expect_equal(shared_kimi.get("ok"), true, "different Providers may reuse the same model id")
	_expect_equal(
		catalog.call("model_descriptor", "kimi", "shared-model-id").get("label"),
		"Kimi Shared",
		"provider/model identity resolves the correct descriptor",
	)
	var normalized_modalities := catalog.call("register_model", {
		"id": "normalized-modalities",
		"label": "Normalized Modalities",
		"provider_id": "deepseek",
		"input_modalities": [" text ", " image "],
	}) as Dictionary
	_expect_equal(normalized_modalities.get("ok"), true, "valid input modalities are normalized")
	_expect_equal(
		catalog.call("model_descriptor", "deepseek", "normalized-modalities").get("input_modalities"),
		["text", "image"],
		"catalog stores canonical input modality values",
	)
	var string_name_modalities := catalog.call("register_model", {
		"id": "string-name-modalities",
		"label": "StringName Modalities",
		"provider_id": "deepseek",
		"input_modalities": [&"text", &"image"],
	}) as Dictionary
	_expect_equal(string_name_modalities.get("ok"), true, "StringName input modalities are accepted")
	_expect_equal(
		catalog.call("model_descriptor", "deepseek", "string-name-modalities").get("input_modalities"),
		["text", "image"],
		"StringName input modalities are stored as canonical strings",
	)
	var missing_modalities := catalog.call("register_model", {
		"id": "missing-modalities",
		"label": "Missing Modalities",
		"provider_id": "deepseek",
	}) as Dictionary
	_expect_equal(missing_modalities.get("ok"), false, "model registration requires declared input modalities")
	var image_only := catalog.call("register_model", {
		"id": "image-only",
		"label": "Image Only",
		"provider_id": "deepseek",
		"input_modalities": ["image"],
	}) as Dictionary
	_expect_equal(image_only.get("ok"), false, "Agent models must support text input")
	var unknown_modality := catalog.call("register_model", {
		"id": "unknown-modality",
		"label": "Unknown Modality",
		"provider_id": "deepseek",
		"input_modalities": ["text", "audio"],
	}) as Dictionary
	_expect_equal(unknown_modality.get("ok"), false, "unknown input modalities are rejected")
	_finish_suite("MODEL_PROVIDER_CATALOG_PASS")


func _model_ids(catalog: RefCounted, provider_id: String) -> Array[String]:
	var result: Array[String] = []
	for descriptor: Dictionary in catalog.call("list_models", provider_id):
		result.append(String(descriptor.get("id", "")))
	return result
