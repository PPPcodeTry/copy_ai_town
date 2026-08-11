extends "res://tests/support/TownWorldTestCase.gd"


const SYNC := preload(
	"res://world/presentation/town_runtime/TownSpaceViewSync.gd"
)
const TOWN_RUNTIME_SCENE := preload(
	"res://world/presentation/town_runtime/TownRuntime.tscn"
)
const FOLLOW_OPENING := preload(
	"res://world/runtime/TownWorldOpeningConfig.gd"
)
const FOLLOW_WORLD_DATA_PATH := "res://world/data/town/town_world.json"


class FakeWorld:
	extends RefCounted

	func get_place_detail(place_name: String) -> Dictionary:
		if place_name == "诊所":
			return {"spaceId": "clinic_interior"}
		return {}


class FakePresentation:
	extends RefCounted
	var active_space_id := "town_outdoor"
	var observed_calls: Array[Dictionary] = []
	var clear_calls := 0
	var fail_observe := false

	func get_active_space_id() -> String:
		return active_space_id

	func set_observed_interior(place_name: String, origin: Vector2) -> Dictionary:
		observed_calls.append({"placeName": place_name, "origin": origin})
		if fail_observe:
			return {"ok": false, "code": "TEST_OBSERVE_FAILED"}
		active_space_id = "clinic_interior"
		return {"ok": true}

	func clear_observed_interior() -> Dictionary:
		clear_calls += 1
		active_space_id = "town_outdoor"
		return {"ok": true}


class FakeTown:
	extends RefCounted
	var _active_interior_id := ""
	var _active_exterior_portal_id := ""
	var _observed_place_name := ""
	var _interior_roots: Dictionary = {}
	var _world: FakeWorld = null

	func _is_inside_interior() -> bool:
		return not _active_interior_id.is_empty()

	func _place_name_for_portal_id(portal_id: String) -> String:
		if portal_id == "portal-clinic":
			return "诊所"
		return ""


func _initialize() -> void:
	call_deferred("_run_all")


func _run_all() -> void:
	_test_outdoor_consistent_no_change()
	_test_indoor_mismatch_switches_to_interior()
	_test_room_hidden_treated_as_outdoor()
	_test_indoor_uses_portal_mapping_over_observed_name()
	_test_unknown_place_skips()
	_test_outdoor_mismatch_clears()
	_test_failed_switch_is_not_reported_as_changed()
	await _test_production_follow_camera_contract()
	_finish_suite("TOWN_SPACE_VIEW_SYNC_PASS")


func _make_room(visible: bool) -> Node2D:
	var room := Node2D.new()
	room.visible = visible
	root.add_child(room)
	room.position = Vector2(640, 480)
	return room


func _test_outdoor_consistent_no_change() -> void:
	var town := FakeTown.new()
	town._world = FakeWorld.new()
	var presentation := FakePresentation.new()
	var result: Dictionary = SYNC.reconcile(town, presentation, "t")
	_expect_equal(result.get("changed"), false, "室外一致时不改动")
	_expect_equal(presentation.clear_calls, 0, "不触发clear")
	_expect_equal(presentation.observed_calls.size(), 0, "不触发observe")


func _test_indoor_mismatch_switches_to_interior() -> void:
	var town := FakeTown.new()
	town._world = FakeWorld.new()
	var room := _make_room(true)
	town._active_interior_id = "clinic"
	town._active_exterior_portal_id = "portal-clinic"
	town._interior_roots = {"clinic": room}
	var presentation := FakePresentation.new()
	var result: Dictionary = SYNC.reconcile(town, presentation, "portal_enter")
	_expect_equal(result.get("changed"), true, "失配时发生改动")
	_expect_equal(presentation.observed_calls.size(), 1, "调用一次室内观察")
	_expect_equal(
		presentation.observed_calls[0].get("placeName"),
		"诊所",
		"用portal映射出的地点名",
	)
	_expect_equal(
		presentation.observed_calls[0].get("origin"),
		Vector2(640, 480),
		"原点取房间位置",
	)
	room.queue_free()


func _test_room_hidden_treated_as_outdoor() -> void:
	var town := FakeTown.new()
	town._world = FakeWorld.new()
	var room := _make_room(false)
	town._active_interior_id = "clinic"
	town._active_exterior_portal_id = "portal-clinic"
	town._interior_roots = {"clinic": room}
	var presentation := FakePresentation.new()
	presentation.active_space_id = "clinic_interior"
	var result: Dictionary = SYNC.reconcile(town, presentation, "portal_exit")
	_expect_equal(result.get("changed"), true, "房间隐藏时改回室外")
	_expect_equal(presentation.clear_calls, 1, "清理一次室内观察")
	room.queue_free()


func _test_indoor_uses_portal_mapping_over_observed_name() -> void:
	var town := FakeTown.new()
	town._world = FakeWorld.new()
	var room := _make_room(true)
	town._active_interior_id = "clinic"
	town._active_exterior_portal_id = "portal-clinic"
	town._observed_place_name = "被UI写坏的名字"
	town._interior_roots = {"clinic": room}
	var desired: Dictionary = SYNC.desired_space(town)
	_expect_equal(
		desired.get("placeName"),
		"诊所",
		"portal映射优先于可能被改写的observed名",
	)
	room.queue_free()


func _test_unknown_place_skips() -> void:
	var town := FakeTown.new()
	town._world = FakeWorld.new()
	var room := _make_room(true)
	town._active_interior_id = "clinic"
	town._active_exterior_portal_id = "portal-unknown"
	town._interior_roots = {"clinic": room}
	var presentation := FakePresentation.new()
	var result: Dictionary = SYNC.reconcile(town, presentation, "periodic")
	_expect_equal(result.get("skipped"), true, "判定不出地点时跳过不动")
	_expect_equal(presentation.observed_calls.size(), 0, "不触发observe")
	room.queue_free()


func _test_outdoor_mismatch_clears() -> void:
	var town := FakeTown.new()
	town._world = FakeWorld.new()
	var presentation := FakePresentation.new()
	presentation.active_space_id = "clinic_interior"
	var result: Dictionary = SYNC.reconcile(town, presentation, "periodic")
	_expect_equal(result.get("changed"), true, "人在室外但表现层卡在室内时修正")
	_expect_equal(presentation.clear_calls, 1, "清理一次室内观察")


func _test_failed_switch_is_not_reported_as_changed() -> void:
	var town := FakeTown.new()
	town._world = FakeWorld.new()
	var room := _make_room(true)
	town._active_interior_id = "clinic"
	town._active_exterior_portal_id = "portal-clinic"
	town._interior_roots = {"clinic": room}
	var presentation := FakePresentation.new()
	presentation.fail_observe = true
	var result: Dictionary = SYNC.reconcile(
		town,
		presentation,
		"portal_enter",
	)
	_expect_equal(result.get("ok"), false, "切换失败保留失败结果")
	_expect_equal(result.get("changed"), false, "切换失败不能冒充已切换")
	_expect_equal(
		presentation.active_space_id,
		"town_outdoor",
		"切换失败时表现层仍留在原空间",
	)
	room.queue_free()


func _test_production_follow_camera_contract() -> void:
	var world_data_value: Variant = JSON.parse_string(
		FileAccess.get_file_as_string(FOLLOW_WORLD_DATA_PATH),
	)
	_expect(world_data_value is Dictionary, "正式 World 数据可读取")
	if not world_data_value is Dictionary:
		return
	var opening_result := FOLLOW_OPENING.load_config(
		OPENING_PATH,
		world_data_value as Dictionary,
	) as Dictionary
	_expect_equal(opening_result.get("ok"), true, "正式开局配置可读取")
	if opening_result.get("ok") != true:
		return
	var opening := opening_result.get("config", {}) as Dictionary
	var identities: Array[Dictionary] = []
	var connected_residents: Array[String] = []
	for resident_value: Variant in opening.get("residents", []) as Array:
		var resident := resident_value as Dictionary
		var attributes := resident.get("attributes", {}) as Dictionary
		identities.append({
			"residentId": String(resident.get("residentId", "")),
			"residentName": String(attributes.get("name", "")),
		})
		connected_residents.append(String(attributes.get("name", "")))
	var runtime := TOWN_RUNTIME_SCENE.instantiate() as Node
	var configured := runtime.call("configure_session", {
		"openingConfig": opening,
		"residentIdentities": identities,
		"connectedResidents": connected_residents,
		"worldStartMode": "development",
		"requireAgentGateway": false,
		"enableTestUi": false,
		"source": "space_follow_contract_test",
	}) as Dictionary
	_expect_equal(configured.get("ok"), true, "正式 TownRuntime 接受跟随测试配置")
	if configured.get("ok") != true:
		runtime.free()
		return
	root.add_child(runtime)
	for _frame in 5:
		await process_frame
	_expect_equal(
		(runtime.call("get_startup_result") as Dictionary).get("ok"),
		true,
		"正式 TownRuntime 启动完成",
	)
	_expect_equal(
		runtime.call("follow_resident", "林岚"),
		true,
		"正式跟随入口接受室外可见居民",
	)
	for _frame in 2:
		await process_frame
	var zoomed := runtime.call("zoom_observer_camera", -1) as Dictionary
	_expect_equal(zoomed.get("ok"), true, "跟随中允许调整镜头缩放")
	_expect_equal(
		(runtime.call("get_runtime_state") as Dictionary).get("followedResident"),
		"林岚",
		"缩放不会退出居民跟随",
	)
	Input.action_press("move_right")
	runtime.call("_update_observer_camera_input", 1.0 / 60.0)
	Input.action_release("move_right")
	_expect_equal(
		(runtime.call("get_runtime_state") as Dictionary).get("followedResident"),
		"",
		"主动平移镜头立即退出居民跟随",
	)
	runtime.call("reset_observer_camera")
	_expect_equal(
		runtime.call("follow_resident", "顾川"),
		true,
		"正式跟随入口接受室内居民",
	)
	await create_timer(0.75).timeout
	var indoor_state := runtime.call("get_runtime_state") as Dictionary
	_expect_equal(indoor_state.get("viewMode"), "interior", "室内跟随完成房屋切换")
	_expect_equal(indoor_state.get("followedResident"), "顾川", "进屋后继续跟随目标")
	var indoor_zoomed := runtime.call("zoom_observer_camera", -1) as Dictionary
	_expect_equal(indoor_zoomed.get("ok"), true, "室内跟随中允许调整缩放")
	_expect_equal(
		(runtime.call("get_runtime_state") as Dictionary).get("followedResident"),
		"顾川",
		"室内缩放不会退出跟随",
	)
	Input.action_press("move_right")
	runtime.call("_update_observer_camera_input", 1.0 / 60.0)
	Input.action_release("move_right")
	var indoor_pan_state := runtime.call("get_runtime_state") as Dictionary
	_expect_equal(indoor_pan_state.get("followedResident"), "", "室内平移退出居民跟随")
	_expect_equal(indoor_pan_state.get("viewMode"), "interior", "室内平移仍留在当前房屋")
	_expect_equal(
		(runtime.call(
			"get_resident_character_presentation_snapshot",
		) as Dictionary).get("activeSpaceId"),
		"indoor_clinic",
		"解除跟随后角色表现层仍保持当前室内空间",
	)
	runtime.call("reset_observer_camera")
	_expect_equal(
		(runtime.call("get_runtime_state") as Dictionary).get("viewMode"),
		"interior",
		"室内重置镜头不会返回室外",
	)
	var indoor_bounds := runtime.call("_observer_camera_bounds") as Rect2
	var indoor_camera_position := runtime.get("_observer_camera_position") as Vector2
	_expect(
		indoor_bounds.grow(0.01).has_point(indoor_camera_position),
		"室内自由镜头保持在当前房间边界内",
	)
	_expect_equal(
		await runtime.call("return_to_town_overview"),
		true,
		"明确返回操作可以离开室内",
	)
	_expect_equal(
		runtime.call("follow_resident", "顾川"),
		true,
		"返回室外后可再次发起室内跟随",
	)
	await process_frame
	_expect_equal(
		bool(runtime.get("_portal_transition_active")),
		true,
		"室内跟随开始正式房屋淡出",
	)
	runtime.call("cancel_resident_follow")
	await create_timer(0.75).timeout
	var cancelled_state := runtime.call("get_runtime_state") as Dictionary
	_expect_equal(cancelled_state.get("followedResident"), "", "取消后不恢复旧目标")
	_expect_equal(
		cancelled_state.get("viewMode"),
		"town",
		"过期室内跟随回退到原室外画面",
	)
	_expect_equal(
		(runtime.call(
			"get_resident_character_presentation_snapshot",
		) as Dictionary).get("activeSpaceId"),
		"town_outdoor",
		"过期切换同时恢复角色表现层空间",
	)
	_expect_equal(
		bool(runtime.get("_portal_transition_active")),
		false,
		"取消回退后不遗留房屋切换锁",
	)
	runtime.queue_free()
	for _frame in 3:
		await process_frame
