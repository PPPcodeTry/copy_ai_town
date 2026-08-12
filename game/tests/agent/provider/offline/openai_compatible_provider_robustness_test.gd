extends "res://tests/agent/support/OpenAICompatibleProviderTestCase.gd"


const PROVIDER_PATH := "res://agent/model/GenericOpenAICompatibleModelProvider.gd"
const ENV_TEST_PATH := "user://openai_compatible_provider_robustness_test.env"


class SilentTransport:
	extends RefCounted

	var requests := 0
	var saved_callback := Callable()
	var cancelled_request_ids: Array[String] = []

	func request_json(
		_url: String,
		_headers: PackedStringArray,
		_body: Dictionary,
		on_complete: Callable,
	) -> int:
		requests += 1
		saved_callback = on_complete
		return OK

	func cancel_request(request_id: String) -> void:
		cancelled_request_ids.append(request_id)


class ImmediateTransport:
	extends RefCounted

	var response: Dictionary = {}
	var requests := 0

	func request_json(
		_url: String,
		_headers: PackedStringArray,
		_body: Dictionary,
		on_complete: Callable,
	) -> int:
		requests += 1
		on_complete.call(response.duplicate(true))
		return OK


func _initialize() -> void:
	_run()


func _run() -> void:
	await process_frame
	var provider_script := load(PROVIDER_PATH) as Script
	_expect(provider_script != null, "通用 OpenAI Compatible Provider 脚本可加载")
	if provider_script != null:
		await _test_transport_watchdog_completes_hung_request(provider_script)
		await _test_transport_watchdog_releases_after_completion(provider_script)
		_test_synchronous_transport_releases_request_state(provider_script)
		await _test_transport_cancellation_releases_active_request(provider_script)
		await _test_transport_cancel_all_releases_active_requests(provider_script)
		_test_env_file_cache(provider_script)
	_finish_suite("OPENAI_COMPATIBLE_PROVIDER_ROBUSTNESS_PASS")


func _test_transport_watchdog_completes_hung_request(provider_script: Script) -> void:
	var host := Node.new()
	root.add_child(host)
	var transport := SilentTransport.new()
	var provider: RefCounted = provider_script.new(host, transport, {
		"api_key": "watchdog-test-key",
		"endpoint": "https://compatible.example/v1/chat/completions",
		"api_model": "vendor-model",
		"timeout_seconds": 0.05,
	})
	var collector := ResultCollector.new()
	provider.call(
		"request_decision",
		{"messages": [{"role": "user", "content": "决定"}]},
		collector.collect,
	)
	_expect_equal(transport.requests, 1, "挂起的注入 transport 收到请求")
	_expect_equal(collector.values.size(), 0, "看门狗触发前不应有结果")
	await create_timer(0.3).timeout
	_expect_equal(collector.values.size(), 1, "看门狗把挂起请求收敛为恰好一次完成")
	if collector.values.size() == 1:
		_expect_equal(
			collector.values[0],
			{"ok": false, "errors": ["模型调用失败"]},
			"看门狗返回中性失败包",
		)
	var diagnostics := provider.call("get_diagnostics") as Array
	var timeout_entries := diagnostics.filter(
		func(entry: Variant) -> bool:
			return String((entry as Dictionary).get("error_type", "")) == "timeout"
	)
	_expect_equal(timeout_entries.size(), 1, "看门狗记录一条 timeout 诊断")
	if timeout_entries.size() == 1:
		_expect_equal(
			(timeout_entries[0] as Dictionary).get("retryable"),
			true,
			"transport 超时标记为可重试供网关消费",
		)
	if transport.saved_callback.is_valid():
		transport.saved_callback.call(_success_response("late-decision"))
	# 结算 lambda 捕获 provider、provider 又持有 transport，若不断开保存的
	# 回调会形成 RefCounted 引用环并在退出时报资源泄漏。
	transport.saved_callback = Callable()
	_expect_equal(
		collector.values.size(),
		1,
		"看门狗之后迟到的 transport 回复不会二次完成",
	)
	_expect_equal(
		(provider.call("get_diagnostics") as Array).size(),
		1,
		"迟到回复不追加诊断记录",
	)
	_expect_equal(
		(provider.call("get_results") as Array).size(),
		1,
		"迟到回复不追加结果记录",
	)
	_expect_equal(
		(provider.call("get_responses") as Array).size(),
		0,
		"迟到回复不写入响应历史",
	)
	var final_diagnostics := provider.call("get_diagnostics") as Array
	if final_diagnostics.size() == 1:
		var only_diagnostic := final_diagnostics[0] as Dictionary
		_expect_equal(
			only_diagnostic.get("error_type"),
			"timeout",
			"唯一诊断仍是超时",
		)
		_expect_equal(
			only_diagnostic.get("retryable"),
			true,
			"唯一诊断保持可重试供网关消费",
		)
	host.free()


func _test_transport_watchdog_releases_after_completion(provider_script: Script) -> void:
	var host := Node.new()
	root.add_child(host)
	var transport := SilentTransport.new()
	var provider: RefCounted = provider_script.new(host, transport, {
		"api_key": "watchdog-release-key",
		"endpoint": "https://compatible.example/v1/chat/completions",
		"api_model": "vendor-model",
		"timeout_seconds": 10.0,
	})
	var collector := ResultCollector.new()
	provider.call(
		"request_decision",
		{"messages": [{"role": "user", "content": "及时返回"}]},
		collector.collect,
	)
	_expect_equal(host.get_child_count(), 1, "在途 transport 有一个可控的看门狗计时器")
	transport.saved_callback.call(_success_response("watchdog-release"))
	transport.saved_callback = Callable()
	await process_frame
	_expect_equal(collector.values.size(), 1, "及时返回只结算一次")
	_expect_equal(host.get_child_count(), 0, "请求完成后立即释放看门狗计时器")
	host.free()


func _test_synchronous_transport_releases_request_state(provider_script: Script) -> void:
	var host := Node.new()
	root.add_child(host)
	var transport := ImmediateTransport.new()
	transport.response = _success_response("sync-decision")
	var provider: RefCounted = provider_script.new(host, transport, {
		"api_key": "sync-transport-key",
		"endpoint": "https://compatible.example/v1/chat/completions",
		"api_model": "vendor-model",
		"timeout_seconds": 10.0,
	})
	var provider_weak: WeakRef = weakref(provider)
	var collector := ResultCollector.new()
	provider.call(
		"request_decision",
		{"messages": [{"role": "user", "content": "同步决定"}]},
		collector.collect,
	)
	_expect_equal(transport.requests, 1, "同步 transport 收到一次请求")
	_expect_equal(collector.values.size(), 1, "同步 transport 只结算一次")
	_expect_equal(host.get_child_count(), 0, "同步完成后不会创建残留 watchdog")
	_expect_equal(provider.call("cancel_all_requests"), 0, "同步完成的请求不会留在取消队列")
	host.free()
	provider = null
	transport = null
	collector = null
	await process_frame
	_expect(provider_weak.get_ref() == null, "同步完成后 Provider 引用可以释放")


func _test_transport_cancellation_releases_active_request(provider_script: Script) -> void:
	var host := Node.new()
	root.add_child(host)
	var transport := SilentTransport.new()
	var provider: RefCounted = provider_script.new(host, transport, {
		"api_key": "cancel-test-key",
		"endpoint": "https://compatible.example/v1/chat/completions",
		"api_model": "vendor-model",
		"timeout_seconds": 10.0,
	})
	var collector := ResultCollector.new()
	provider.call(
		"request_decision",
		{
			"_agent_request_id": "cancelled-request",
			"messages": [{"role": "user", "content": "决定"}],
		},
		collector.collect,
	)
	_expect_equal(
		provider.call("cancel_request", "cancelled-request"),
		true,
		"主动取消能找到仍在途的模型请求",
	)
	_expect_equal(
		transport.cancelled_request_ids,
		["cancelled-request"],
		"主动取消通知注入 transport 停止真实请求",
	)
	_expect_equal(
		collector.values.size(),
		1,
		"主动取消也把上游请求收敛为恰好一次完成",
	)
	if collector.values.size() == 1:
		_expect_equal(
			collector.values[0],
			{"ok": false, "errors": ["模型调用失败"]},
			"主动取消返回中性失败包供上层识别 stale",
		)
	if transport.saved_callback.is_valid():
		transport.saved_callback.call(_success_response("late-cancelled-decision"))
	transport.saved_callback = Callable()
	_expect_equal(
		collector.values.size(),
		1,
		"取消后的迟到 transport 回复不会二次完成",
	)
	host.free()


func _test_transport_cancel_all_releases_active_requests(provider_script: Script) -> void:
	var host := Node.new()
	root.add_child(host)
	var transport := SilentTransport.new()
	var provider: RefCounted = provider_script.new(host, transport, {
		"api_key": "cancel-all-test-key",
		"endpoint": "https://compatible.example/v1/chat/completions",
		"api_model": "vendor-model",
		"timeout_seconds": 10.0,
	})
	var first_collector := ResultCollector.new()
	var second_collector := ResultCollector.new()
	var untagged_collector := ResultCollector.new()
	provider.call(
		"request_decision",
		{
			"_agent_request_id": "session-close-a",
			"messages": [{"role": "user", "content": "决定一"}],
		},
		first_collector.collect,
	)
	provider.call(
		"request_decision",
		{
			"_agent_request_id": "session-close-b",
			"messages": [{"role": "user", "content": "决定二"}],
		},
		second_collector.collect,
	)
	provider.call(
		"request_decision",
		{
			"messages": [{"role": "user", "content": "没有上层编号的结构化请求"}],
		},
		untagged_collector.collect,
	)
	_expect_equal(
		provider.call("cancel_all_requests"),
		3,
		"关闭会话能一次取消该 Provider 的全部在途请求",
	)
	var cancelled_ids := transport.cancelled_request_ids.duplicate()
	cancelled_ids.sort()
	_expect_equal(
		cancelled_ids.size(),
		3,
		"全量取消会通知真实 transport 的每个请求",
	)
	_expect_equal(first_collector.values.size(), 1, "第一条关闭请求只结算一次")
	_expect_equal(second_collector.values.size(), 1, "第二条关闭请求只结算一次")
	_expect_equal(untagged_collector.values.size(), 1, "没有上层编号的请求也纳入会话级取消")
	if transport.saved_callback.is_valid():
		transport.saved_callback.call(_success_response("late-session-close"))
	transport.saved_callback = Callable()
	_expect_equal(first_collector.values.size(), 1, "关闭后的迟到回复不会二次完成第一条请求")
	_expect_equal(second_collector.values.size(), 1, "关闭后的迟到回复不会二次完成第二条请求")
	_expect_equal(untagged_collector.values.size(), 1, "关闭后的迟到回复不会二次完成无编号请求")
	host.free()


func _test_env_file_cache(provider_script: Script) -> void:
	var provider: RefCounted = provider_script.new(null, null, {})
	var env_file := FileAccess.open(ENV_TEST_PATH, FileAccess.WRITE)
	_expect(env_file != null, "能创建测试用 env 文件")
	if env_file == null:
		return
	env_file.store_string("# comment\nexport TEST_ROBUSTNESS_KEY=\"first-value\"\n")
	env_file.close()
	_expect_equal(
		provider.call("_read_env_value", ENV_TEST_PATH, "TEST_ROBUSTNESS_KEY"),
		"first-value",
		"首次读取解析 env 文件",
	)
	_expect_equal(
		provider.call("_read_env_value", ENV_TEST_PATH, "TEST_ROBUSTNESS_KEY"),
		"first-value",
		"二次读取命中缓存且值一致",
	)
	_expect_equal(
		provider.call("_read_env_value", ENV_TEST_PATH, "MISSING_KEY"),
		"",
		"缓存条目中不存在的键返回空串",
	)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(ENV_TEST_PATH))
	_expect_equal(
		provider.call("_read_env_value", ENV_TEST_PATH, "TEST_ROBUSTNESS_KEY"),
		"",
		"文件删除后不再返回缓存值",
	)
