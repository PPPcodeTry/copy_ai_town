extends "res://tests/agent/support/OpenAICompatibleProviderTestCase.gd"


const PROVIDER_PATH := "res://agent/model/VolcengineArkModelProvider.gd"


func _initialize() -> void:
	var provider_script := load(PROVIDER_PATH) as Script
	_expect(provider_script != null, "火山方舟 Provider 脚本可加载")
	if provider_script != null:
		_test_ark_request(provider_script)
		_test_ark_overdue_error(provider_script)
	_finish_suite("VOLCENGINE_ARK_PROVIDER_PROTOCOL_PASS")


func _test_ark_request(provider_script: Script) -> void:
	var transport := FakeTransport.new()
	transport.response = _success_response("ark-decision")
	var provider: RefCounted = provider_script.new(null, transport, {
		"api_key": "temporary-ark-key",
		"model": "doubao-seed-2-1-turbo-260628",
		"input_modalities": ["text", "image"],
	})
	var collector := ResultCollector.new()
	var messages := [{
		"role": "user",
		"content": [
			{"type": "image_url", "image_url": {"url": "https://example.invalid/image.png"}},
			{"type": "text", "text": "只返回决定 JSON"},
		],
	}]
	provider.call("request_decision", {"messages": messages}, collector.collect)

	_expect_equal(collector.values, [{"ok": true, "decision": _decision("ark-decision")}], "Ark returns a neutral decision")
	_expect_equal(transport.requests.size(), 1, "Ark sends one request")
	if transport.requests.size() == 1:
		var request := transport.requests[0]
		var body := request.get("body", {}) as Dictionary
		_expect_equal(request.get("url"), "https://ark.cn-beijing.volces.com/api/v3/chat/completions", "Ark uses the Beijing compatible endpoint")
		_expect_equal(body.get("model"), "doubao-seed-2-1-turbo-260628", "Ark sends the selected model")
		_expect_equal(body.get("messages"), messages, "Ark visual content passes through unchanged")
		_expect_equal(body.get("thinking"), {"type": "disabled"}, "Ark uses conservative non-thinking mode")
		_expect(not body.has("response_format"), "Ark avoids an unverified structured-output field")

func _test_ark_overdue_error(provider_script: Script) -> void:
	var transport := FakeTransport.new()
	transport.response = _http_response(403, {
		"code": "AccountOverdueError",
		"message": "Account overdue",
	})
	var provider: RefCounted = provider_script.new(null, transport, {"api_key": "temporary-ark-key"})
	var collector := ResultCollector.new()
	provider.call("request_decision", {"messages": [{"role": "user", "content": "决定 JSON"}]}, collector.collect)
	var diagnostics := provider.call("get_diagnostics") as Array
	_expect_equal(diagnostics.size(), 1, "Ark provider errors create one diagnostic")
	if diagnostics.size() == 1:
		_expect_equal(diagnostics[0].get("error_type"), "billing", "Ark overdue errors are classified as billing")
		_expect_equal(diagnostics[0].get("retryable"), false, "Ark overdue errors are not retried")
		_expect_equal(diagnostics[0].get("provider_error_message"), "Account overdue", "Ark top-level error message is retained")
