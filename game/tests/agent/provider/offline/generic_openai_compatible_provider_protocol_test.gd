extends "res://tests/agent/support/OpenAICompatibleProviderTestCase.gd"


const PROVIDER_PATH := "res://agent/model/GenericOpenAICompatibleModelProvider.gd"


func _initialize() -> void:
	var provider_script := load(PROVIDER_PATH) as Script
	_expect(provider_script != null, "通用 OpenAI Compatible Provider 脚本可加载")
	if provider_script != null:
		_test_generic_conservative_request(provider_script)
		_test_missing_messages_rejected(provider_script)
		_test_undeclared_image_input_rejected(provider_script)
		_test_declared_image_input_allowed(provider_script)
		_test_trace_record_limits_are_independent(provider_script)
	_finish_suite("GENERIC_OPENAI_COMPATIBLE_PROVIDER_PROTOCOL_PASS")


func _test_generic_conservative_request(provider_script: Script) -> void:
	var transport := FakeTransport.new()
	transport.response = _success_response("generic-decision")
	var provider: RefCounted = provider_script.new(null, transport, {
		"api_key": "temporary-compatible-key",
		"endpoint": "https://compatible.example/v1/chat/completions",
		"api_model": "vendor-model",
	})
	var collector := ResultCollector.new()
	provider.call("request_decision", {"messages": [{"role": "user", "content": "决定"}]}, collector.collect)

	_expect_equal(collector.values, [{"ok": true, "decision": _decision("generic-decision")}], "generic compatible provider returns a neutral decision")
	if transport.requests.size() == 1:
		var request := transport.requests[0]
		var body := request.get("body", {}) as Dictionary
		_expect_equal(request.get("url"), "https://compatible.example/v1/chat/completions", "generic provider uses the configured endpoint")
		_expect_equal(body.keys(), ["model", "messages", "stream"], "generic provider sends only conservative compatible fields")
		_expect_equal(body.get("model"), "vendor-model", "generic provider separates the catalog model from the wire model")
		_expect(not JSON.stringify(body).contains("temporary-compatible-key"), "generic key never enters the body")
	_expect(not JSON.stringify(provider.call("get_debug_snapshot")).contains("temporary-compatible-key"), "generic key never enters debug records")

func _test_missing_messages_rejected(provider_script: Script) -> void:
	var transport := FakeTransport.new()
	transport.response = _success_response("unexpected-decision")
	var provider: RefCounted = provider_script.new(null, transport, {
		"api_key": "temporary-compatible-key",
		"endpoint": "https://compatible.example/v1/chat/completions",
		"api_model": "vendor-model",
	})
	var collector := ResultCollector.new()
	provider.call("request_decision", {"request_kind": "resident_decision"}, collector.collect)

	_expect_equal(transport.requests.size(), 0, "requests without compiled messages never reach the transport")
	_expect_equal(collector.values, [{"ok": false, "errors": ["模型调用失败"]}], "missing messages return the neutral failure packet")
	var diagnostics := provider.call("get_diagnostics") as Array
	_expect_equal(diagnostics.size(), 1, "missing messages create one diagnostic")
	if diagnostics.size() == 1:
		_expect_equal(diagnostics[0].get("error_type"), "request_validation", "missing messages are classified as request validation")


func _test_undeclared_image_input_rejected(provider_script: Script) -> void:
	var transport := FakeTransport.new()
	transport.response = _success_response("unexpected-visual-decision")
	var provider: RefCounted = provider_script.new(null, transport, {
		"api_key": "temporary-compatible-key",
		"endpoint": "https://compatible.example/v1/chat/completions",
		"api_model": "vendor-model",
		"input_modalities": ["text"],
	})
	var collector := ResultCollector.new()
	provider.call("request_decision", {
		"messages": [{
			"role": "user",
			"content": [
				{"type": "text", "text": "看看这张图"},
				{"type": "image_url", "image_url": {"url": "data:image/png;base64,AA=="}},
			],
		}],
	}, collector.collect)

	_expect_equal(transport.requests.size(), 0, "image input never reaches a text-only model")
	_expect_equal(collector.values, [{"ok": false, "errors": ["模型调用失败"]}], "unsupported image input returns the neutral failure packet")
	var diagnostics := provider.call("get_diagnostics") as Array
	_expect_equal(diagnostics.size(), 1, "unsupported image input creates one diagnostic")
	if diagnostics.size() == 1:
		_expect_equal(diagnostics[0].get("error_type"), "request_validation", "unsupported image input is request validation")


func _test_declared_image_input_allowed(provider_script: Script) -> void:
	var transport := FakeTransport.new()
	transport.response = _success_response("visual-custom-decision")
	var provider: RefCounted = provider_script.new(null, transport, {
		"api_key": "temporary-compatible-key",
		"endpoint": "https://compatible.example/v1/chat/completions",
		"api_model": "visual-vendor-model",
		"input_modalities": ["text", "image"],
	})
	var collector := ResultCollector.new()
	var messages := [{
		"role": "user",
		"content": [
			{"type": "text", "text": "看看这张图"},
			{"type": "image_url", "image_url": {"url": "data:image/png;base64,AA=="}},
		],
	}]
	provider.call("request_decision", {"messages": messages}, collector.collect)

	_expect_equal(collector.values, [{"ok": true, "decision": _decision("visual-custom-decision")}], "declared custom visual input completes")
	_expect_equal(transport.requests.size(), 1, "declared custom visual input reaches the transport")
	if transport.requests.size() == 1:
		_expect_equal(
			transport.requests[0].get("body", {}).get("messages"),
			messages,
			"custom visual content passes through unchanged",
		)


func _test_trace_record_limits_are_independent(provider_script: Script) -> void:
	var transport := FakeTransport.new()
	transport.response = _success_response("retained-response")
	var provider: RefCounted = provider_script.new(null, transport, {
		"api_key": "temporary-compatible-key",
		"endpoint": "https://compatible.example/v1/chat/completions",
		"api_model": "vendor-model",
		"record_limit": 2,
	})
	var collector := ResultCollector.new()
	provider.call(
		"request_decision",
		{"messages": [{"role": "user", "content": "valid request"}]},
		collector.collect,
	)
	provider.call("request_decision", {"request_kind": "invalid-1"}, collector.collect)
	provider.call("request_decision", {"request_kind": "invalid-2"}, collector.collect)
	var snapshot := provider.call("get_debug_snapshot") as Dictionary
	_expect_equal((snapshot.get("model_requests", []) as Array).size(), 2, "model requests use their own record limit")
	_expect_equal((snapshot.get("requests", []) as Array).size(), 1, "provider requests retain sparse history independently")
	_expect_equal((snapshot.get("responses", []) as Array).size(), 1, "responses retain sparse history independently")
	_expect_equal((snapshot.get("diagnostics", []) as Array).size(), 2, "diagnostics use their own record limit")
	_expect_equal((snapshot.get("results", []) as Array).size(), 2, "results use their own record limit")
	_expect_equal(
		(snapshot.get("responses", []) as Array)[0].get("choices", [])[0].get("message", {}).get("content"),
		JSON.stringify(_decision("retained-response")),
		"sparse response history keeps the older completed response",
	)
