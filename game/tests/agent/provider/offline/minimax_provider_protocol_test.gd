extends "res://tests/agent/support/OpenAICompatibleProviderTestCase.gd"


const PROVIDER_PATH := "res://agent/model/MiniMaxModelProvider.gd"


func _initialize() -> void:
	var provider_script := load(PROVIDER_PATH) as Script
	_expect(provider_script != null, "MiniMax Provider script loads")
	if provider_script != null:
		_test_text_request(provider_script)
		_test_m3_request(provider_script)
		_test_unknown_model_rejected(provider_script)
	_finish_suite("MINIMAX_PROVIDER_PROTOCOL_PASS")


func _test_text_request(provider_script: Script) -> void:
	var transport := FakeTransport.new()
	transport.response = _success_response("minimax-decision")
	var provider: RefCounted = provider_script.new(null, transport, {
		"api_key": "temporary-minimax-key",
		"model": "MiniMax-M2.7",
	})
	var collector := ResultCollector.new()
	provider.call(
		"request_decision",
		{"messages": [{"role": "user", "content": "只返回决定 JSON"}]},
		collector.collect,
	)

	_expect_equal(
		collector.values,
		[{"ok": true, "decision": _decision("minimax-decision")}],
		"MiniMax returns a provider-neutral decision",
	)
	_expect_equal(transport.requests.size(), 1, "MiniMax sends one request")
	if transport.requests.size() == 1:
		var request := transport.requests[0]
		var body := request.get("body", {}) as Dictionary
		_expect_equal(
			request.get("url"),
			"https://api.minimaxi.com/v1/chat/completions",
			"MiniMax uses the official mainland endpoint",
		)
		_expect_equal(body.get("model"), "MiniMax-M2.7", "MiniMax sends the selected model")
		_expect_equal(body.get("reasoning_split"), true, "MiniMax separates reasoning from answer content")
		_expect_equal(body.get("max_completion_tokens"), 2048, "MiniMax uses its documented output token field")
		_expect(not body.has("max_tokens"), "MiniMax omits the legacy max_tokens field")
		_expect(not JSON.stringify(body).contains("temporary-minimax-key"), "MiniMax key never enters the body")

	var long_request_collector := ResultCollector.new()
	provider.call(
		"request_decision",
		{
			"messages": [{"role": "user", "content": "保留较长输出预算"}],
			"max_tokens": 8192,
		},
		long_request_collector.collect,
	)
	_expect_equal(
		long_request_collector.values,
		[{"ok": true, "decision": _decision("minimax-decision")}],
		"MiniMax keeps a caller-provided long output budget",
	)
	_expect_equal(transport.requests.size(), 2, "MiniMax accepts a second request")
	if transport.requests.size() == 2:
		var long_request := transport.requests[1]
		var long_body := long_request.get("body", {}) as Dictionary
		_expect_equal(
			long_body.get("max_completion_tokens"),
			8192,
			"MiniMax preserves the memory-sized output budget",
		)


func _test_m3_request(provider_script: Script) -> void:
	var transport := FakeTransport.new()
	transport.response = _success_response("minimax-m3-decision")
	var provider: RefCounted = provider_script.new(null, transport, {
		"api_key": "temporary-minimax-key",
		"model": "MiniMax-M3",
		"input_modalities": ["text", "image"],
		"thinking_type": "enabled",
	})
	var collector := ResultCollector.new()
	var image_messages := [{
		"role": "user",
		"content": [
			{"type": "text", "text": "根据图片只返回决定 JSON"},
			{
				"type": "image_url",
				"image_url": {"url": "https://example.invalid/town.png"},
			},
		],
	}]
	provider.call(
		"request_decision",
		{
			"messages": image_messages,
			"max_tokens": 600000,
		},
		collector.collect,
	)

	_expect_equal(
		collector.values,
		[{"ok": true, "decision": _decision("minimax-m3-decision")}],
		"MiniMax M3 returns a provider-neutral decision",
	)
	_expect_equal(transport.requests.size(), 1, "MiniMax M3 sends one request")
	if transport.requests.size() == 1:
		var request := transport.requests[0]
		var body := request.get("body", {}) as Dictionary
		_expect_equal(body.get("model"), "MiniMax-M3", "MiniMax M3 sends its exact model id")
		_expect_equal(
			body.get("thinking"),
			{"type": "disabled"},
			"MiniMax M3 disables thinking for fast structured decisions",
		)
		_expect_equal(body.get("reasoning_split"), true, "MiniMax M3 separates reasoning from answer content")
		_expect_equal(
			body.get("max_completion_tokens"),
			524288,
			"MiniMax M3 uses its documented output token ceiling",
		)
		_expect(not body.has("max_tokens"), "MiniMax M3 omits the legacy max_tokens field")
		_expect_equal(body.get("messages"), image_messages, "MiniMax M3 preserves image messages")
func _test_unknown_model_rejected(provider_script: Script) -> void:
	var provider: RefCounted = provider_script.new(null, null, {
		"api_key": "temporary-minimax-key",
		"model": "MiniMax-unknown",
	})
	_expect(
		_errors_contain(provider.call("validate_configuration"), "不支持模型"),
		"MiniMax rejects unknown models",
	)
