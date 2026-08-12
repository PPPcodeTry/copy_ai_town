class_name TownDiningServiceRuntime
extends RefCounted


const CONTENT_CATALOG := preload(
	"res://world/data/town/TownWorkContentCatalog.gd"
)
const MEAL_MENU_PATH := "res://world/data/town/source/meal_menus.json"
const BATCH_SIZE := 4
const DINING_CAPACITY := 4
const FALLBACK_MEAL_MENU := "家常饭菜"
static var _meal_menu_by_period: Dictionary = {}
static var _meal_menu_loaded := false


static func meal_menu_for_period(period: Dictionary) -> String:
	_load_meal_menu_data()
	return String(
		_meal_menu_by_period.get(
			String(period.get("id", "")),
			FALLBACK_MEAL_MENU,
		)
	)


static func _load_meal_menu_data() -> void:
	if _meal_menu_loaded:
		return
	_meal_menu_loaded = true
	_meal_menu_by_period = {}
	if not FileAccess.file_exists(MEAL_MENU_PATH):
		return
	var parsed: Variant = JSON.parse_string(
		FileAccess.get_file_as_string(MEAL_MENU_PATH),
	)
	if not parsed is Dictionary:
		return
	var menus := (parsed as Dictionary).get("menus", {}) as Dictionary
	for period_id_value: Variant in menus:
		var period_id := String(period_id_value).strip_edges()
		var menu := String(menus[period_id_value]).strip_edges()
		if not period_id.is_empty() and not menu.is_empty():
			_meal_menu_by_period[period_id] = menu


static func capacity_status(
	world,
	resident_id: String,
	absolute_minute: int,
) -> Dictionary:
	var period := world._meal_period_for_minute(absolute_minute) as Dictionary
	var period_ref: String = String(world._meal_period_source_ref(absolute_minute))
	var occupied := _meal_admission_count(world, period_ref)
	var admitted := _resident_has_meal_admission(
		world,
		resident_id,
		period_ref,
	)
	var state := "closed"
	var state_label := "当前不在供餐时段"
	if period.is_empty() or not world._meal_service_is_open(absolute_minute):
		state = "closed"
		state_label = "当前不在供餐时段"
	elif not world._meal_period_is_prepared(absolute_minute):
		state = "not_ready"
		state_label = "本餐次还没有备好"
	elif admitted:
		state = "admitted"
		state_label = "你已经占用一个用餐名额"
	elif occupied >= DINING_CAPACITY:
		state = "full"
		state_label = "当前已满，等有人离开后再来"
	else:
		state = "available"
		state_label = "现在可以进入"
	var retry_after := -1
	if state == "full":
		retry_after = _next_admission_retry_minute(
			world,
			period_ref,
			absolute_minute,
		)
	return {
		"capacity": DINING_CAPACITY,
		"occupied": occupied,
		"available": maxi(0, DINING_CAPACITY - occupied),
		"state": state,
		"stateLabel": state_label,
		"admitted": admitted,
		"mealPeriodRef": period_ref,
		"retryAfterMinute": retry_after,
		"maxWaitMinutes": 10,
		"serviceMode": "self_service",
		"serviceRule": "餐食由食堂提前统一备好，开餐后居民自行取餐，不需要等工作人员逐人递餐",
		"menu": meal_menu_for_period(period) if not period.is_empty() else "",
	}


static func collect_is_full(
	world,
	resident_id: String,
	absolute_minute: int,
) -> bool:
	if (
		not world._dining_collect_can_finish_in_current_period(absolute_minute)
		or not world._meal_period_is_prepared(absolute_minute)
	):
		return false
	var period_ref: String = String(world._meal_period_source_ref(absolute_minute))
	return _meal_admission_count(world, period_ref, resident_id) >= DINING_CAPACITY


static func collect_full_failure(
	world,
	resident_id: String,
	absolute_minute: int,
) -> Dictionary:
	if not collect_is_full(world, resident_id, absolute_minute):
		return {}
	return world._command_failure(
		"DINING_HALL_FULL",
		["公共食堂当前已占满4个用餐名额，等有人离开后才能取餐"],
		{"dining": capacity_status(world, resident_id, absolute_minute)},
		true,
	)


static func agent_meal_routine(
	world,
	resident: Dictionary,
	activity_id: String,
) -> Dictionary:
	var social_state := resident.get("socialState", {}) as Dictionary
	var place_id := String(resident.get("currentPlace", ""))
	var descriptor := world._activity_runtime.routine_descriptor(
		social_state,
		place_id,
		activity_id,
	) as Dictionary
	if String(descriptor.get("group", "")) != "meal":
		return {}
	var mapping := {
		"activityId": activity_id,
		"placeId": place_id,
	}
	if String(descriptor.get("phase", "")) != "collect":
		for candidate: Dictionary in world._activity_runtime.routine_candidates(
			social_state,
			place_id,
			"meal",
		) as Array[Dictionary]:
			if (
				bool(candidate.get("available", false))
				and String(candidate.get("phase", "")) == "collect"
			):
				mapping["activityId"] = String(candidate.get("activityId", ""))
				descriptor = candidate.duplicate(true)
				descriptor["group"] = "meal"
				break
	return {"mapping": mapping, "descriptor": descriptor}


static func activate_agent_meal_routine(
	world,
	resident_id: String,
	resident: Dictionary,
	decision_id: String,
	action: Dictionary,
	conversation_end_reason: String,
	allow_current_activity_interrupt: bool,
) -> Dictionary:
	var routine := agent_meal_routine(
		world,
		resident,
		String(action.get("activity_id", "")),
	)
	if routine.is_empty():
		return {}
	return world._activate_activity_routine(
		resident_id,
		resident,
		decision_id,
		action,
		conversation_end_reason,
		routine.get("mapping", {}) as Dictionary,
		routine.get("descriptor", {}) as Dictionary,
		allow_current_activity_interrupt,
	)


static func attach_capacity_status(
	world,
	place_snapshot: Dictionary,
	resident_id: String,
	place_id: String,
	absolute_minute: int,
) -> void:
	if place_id == CONTENT_CATALOG.PLACE_DINING_HALL:
		place_snapshot["dining"] = capacity_status(
			world,
			resident_id,
			absolute_minute,
		)


static func go_admission_failure(
	world,
	resident: Dictionary,
	target_place: String,
	absolute_minute: int,
) -> Dictionary:
	if target_place != CONTENT_CATALOG.PLACE_DINING_HALL:
		return {}
	var dining_status := capacity_status(
		world,
		String(resident.get("residentId", "")),
		absolute_minute,
	)
	if String(dining_status.get("state", "")) != "full":
		return {}
	return {
		"ok": false,
		"errorCode": "DINING_HALL_FULL",
		"retryable": true,
		"dining": dining_status,
		"errors": ["公共食堂当前已满，等有人离开后再来"],
	}


static func decorate_go_rejection(
	rejection: Dictionary,
	preparation: Dictionary,
) -> void:
	for detail_key: String in ["errorCode", "retryable", "dining"]:
		if preparation.has(detail_key):
			rejection[detail_key] = preparation.get(detail_key)
	if String(preparation.get("errorCode", "")) != "DINING_HALL_FULL":
		return
	# 满员是正常生活状态：行动没有执行，但 World 已消费决定，并把结果交给
	# 下一轮 Agent 生成符合人设的反应，不应计作网关错误。
	rejection["ok"] = true
	rejection["status"] = "handled"


static func activity_allowed_during_work(activity_id: String) -> bool:
	return activity_id in [
		"activity_home_sleep",
		"activity_dining_collect_meal",
	]


static func meal_period_ref_for_routine(
	world,
	group: String,
	absolute_minute: int,
) -> String:
	return world._meal_period_source_ref(absolute_minute) if group == "meal" else ""


static func cap_full_wait(
	world,
	resident: Dictionary,
	prepared: Dictionary,
) -> void:
	var resident_id := String(resident.get("residentId", ""))
	var now := int(prepared.get("startedAbsoluteMinute", 0))
	var capacity := capacity_status(world, resident_id, now)
	var is_dining_visitor := (
		String(resident.get("currentPlace", ""))
		== CONTENT_CATALOG.PLACE_DINING_HALL
		and not _resident_is_dining_worker(resident)
	)
	if capacity.get("state", "") == "full" or is_dining_visitor:
		prepared["completeAbsoluteMinute"] = mini(
			int(prepared.get("completeAbsoluteMinute", now)),
			now + 10,
		)


static func _meal_admission_count(
	world,
	period_ref: String,
	excluded_resident_id := "",
) -> int:
	if period_ref.is_empty():
		return 0
	var admitted: Dictionary = {}
	for resident_id_value: Variant in world._activity_routines:
		var resident_id := String(resident_id_value)
		if resident_id == excluded_resident_id:
			continue
		var routine := world._activity_routines[resident_id] as Dictionary
		if (
			String(routine.get("group", "")) == "meal"
			and String(routine.get("placeId", ""))
			== CONTENT_CATALOG.PLACE_DINING_HALL
			and String(routine.get("mealPeriodRef", "")) == period_ref
		):
			admitted[resident_id] = true
	for resident_id_value: Variant in world._residents:
		var resident_id := String(resident_id_value)
		if resident_id == excluded_resident_id:
			continue
		var resident := world._residents[resident_id] as Dictionary
		if _resident_is_dining_worker(resident):
			continue
		if (
			String(resident.get("currentPlace", ""))
			== CONTENT_CATALOG.PLACE_DINING_HALL
			or _resident_is_heading_to_dining_hall(resident)
		):
			admitted[resident_id] = true
	return admitted.size()


static func _resident_has_meal_admission(
	world,
	resident_id: String,
	period_ref: String,
) -> bool:
	if world._activity_routines.has(resident_id):
		var routine := world._activity_routines[resident_id] as Dictionary
		if (
			String(routine.get("group", "")) == "meal"
			and String(routine.get("placeId", ""))
			== CONTENT_CATALOG.PLACE_DINING_HALL
			and String(routine.get("mealPeriodRef", "")) == period_ref
		):
			return true
	var resident := world._residents.get(resident_id, {}) as Dictionary
	if resident.is_empty() or _resident_is_dining_worker(resident):
		return false
	return (
		String(resident.get("currentPlace", ""))
		== CONTENT_CATALOG.PLACE_DINING_HALL
		or _resident_is_heading_to_dining_hall(resident)
	)


static func _resident_is_heading_to_dining_hall(resident: Dictionary) -> bool:
	var action := resident.get("currentAction", {}) as Dictionary
	return (
		String(action.get("type", "")) == "去"
		and String(action.get("place", ""))
		== CONTENT_CATALOG.PLACE_DINING_HALL
	)


static func _resident_is_dining_worker(resident: Dictionary) -> bool:
	return String(
		(resident.get("socialState", {}) as Dictionary).get("workplace", ""),
	) == CONTENT_CATALOG.PLACE_DINING_HALL


static func settle_closed_meal_routine(
	world,
	resident_id: String,
	routine: Dictionary,
	status: String,
) -> void:
	if (
		status != "completed"
		or String(routine.get("group", "")) != "meal"
		or not (routine.get("visitedActivityIds", []) as Array).has(
			"activity_dining_eat_meal",
		)
	):
		return
	var period_ref := String(routine.get("mealPeriodRef", "")).strip_edges()
	if period_ref.is_empty():
		return
	world._occupation_services.mark_dining_order_completed_for_resident_meal_period(
		resident_id,
		period_ref,
	)


static func _next_admission_retry_minute(
	world,
	period_ref: String,
	absolute_minute: int,
) -> int:
	var retry_after := absolute_minute + 1
	for resident_id_value: Variant in world._activity_routines:
		var routine := world._activity_routines[String(resident_id_value)] as Dictionary
		if (
			String(routine.get("group", "")) != "meal"
			or String(routine.get("placeId", ""))
			!= CONTENT_CATALOG.PLACE_DINING_HALL
			or String(routine.get("mealPeriodRef", "")) != period_ref
		):
			continue
		var routine_end := int(routine.get("endAbsoluteMinute", -1))
		if routine_end >= absolute_minute:
			retry_after = mini(retry_after, routine_end)
	return retry_after


static func collect_disabled_reason(
	world,
	resident_id: String,
	absolute_minute: int,
) -> String:
	if not world._dining_collect_can_finish_in_current_period(absolute_minute):
		return "DINING_SERVICE_CLOSED"
	if not world._meal_period_is_prepared(absolute_minute):
		return "DINING_MEAL_NOT_READY"
	var period_ref: String = String(world._meal_period_source_ref(absolute_minute))
	if (
		world._occupation_services.has_dining_order_completed_for_resident_meal_period(
			resident_id,
			period_ref,
		)
		or not world._dining_order_for_resident_meal_period(
			resident_id,
			absolute_minute,
			["completed"],
		).is_empty()
	):
		return "DINING_MEAL_ALREADY_SERVED"
	return ""


static func publish_meal_menu_announcement(
	world,
	period: Dictionary,
	absolute_minute: int,
) -> void:
	var service_start := int(
		period.get("serviceStart", period.get("start", 0)),
	)
	var text := "第%d天%s菜单：%s。%02d:%02d开始公共供餐。" % [
		absolute_minute / 1440 + 1,
		String(period.get("label", "本餐次")),
		meal_menu_for_period(period),
		service_start / 60,
		posmod(service_start, 60),
	]
	for announcement: Dictionary in world.get_announcements():
		if String(announcement.get("text", "")) == text:
			return
	var publisher_id: String = String(
		"resident_su_tang_01"
		if world._residents.has("resident_su_tang_01")
		else world._first_resident_for_occupation(
			"occupation_dining_operator",
		)
	)
	if publisher_id.is_empty():
		world.publish_announcement(text)
	else:
		world.publish_resident_announcement(
			publisher_id,
			text,
			"",
			"town_bell",
		)


static func wait_deadline(world, absolute_minute: int) -> int:
	var period := world._meal_period_for_minute(absolute_minute) as Dictionary
	if period.is_empty():
		return absolute_minute + world._onsite_service_wait_minutes(
			"dining_order",
		)
	var day_start := absolute_minute - posmod(absolute_minute, 1440)
	var service_start := day_start + int(
		period.get("serviceStart", period.get("start", 0)),
	)
	var period_end := day_start + int(period.get("end", 0))
	return mini(
		maxi(absolute_minute, service_start)
		+ world._onsite_service_wait_minutes("dining_order"),
		period_end,
	)


static func complete_additional_orders(
	world,
	worker_resident_id: String,
	primary_request_id: String,
	absolute_minute: int,
) -> int:
	var primary := world._occupation_services.request(
		primary_request_id,
	) as Dictionary
	if (
		String(primary.get("kind", "")) != "dining_order"
		or String(primary.get("state", "")) != "completed"
	):
		return 0
	var meal_period_ref := _request_meal_period_ref(world, primary)
	var candidates: Array[Dictionary] = []
	for request_value: Variant in (
		world._occupation_services.snapshot() as Dictionary
	).get("requests", []) as Array:
		var request := request_value as Dictionary
		if (
			String(request.get("requestId", "")) == primary_request_id
			or String(request.get("kind", "")) != "dining_order"
			or String(request.get("state", "")) not in ["pending", "waiting"]
			or _request_meal_period_ref(world, request) != meal_period_ref
			or not world._dining_request_meal_is_ready(request)
		):
			continue
		var requester := world._residents.get(
			String(request.get("requesterResidentId", "")),
			{},
		) as Dictionary
		if String(requester.get("currentPlace", "")) != (
			CONTENT_CATALOG.PLACE_DINING_HALL
		):
			continue
		var task := world._work_tasks.task(
			String(request.get("taskId", "")),
		) as Dictionary
		if String(task.get("state", "")) == "in_progress":
			continue
		candidates.append(request.duplicate(true))
	candidates.sort_custom(func(left: Dictionary, right: Dictionary) -> bool:
		var left_minute := int(left.get("createdAtMinute", 0))
		var right_minute := int(right.get("createdAtMinute", 0))
		if left_minute != right_minute:
			return left_minute < right_minute
		return String(left.get("requestId", "")) < String(
			right.get("requestId", ""),
		)
	)
	var completed_count := 0
	for request: Dictionary in candidates:
		if completed_count >= BATCH_SIZE - 1:
			break
		var outcome := _handoff_outcome(request, "counter_batch")
		var task := world._work_tasks.task(
			String(request.get("taskId", "")),
		) as Dictionary
		if not _complete_batch_work_task(
			world,
			task,
			worker_resident_id,
			outcome,
		):
			continue
		if _complete_order_record(
			world,
			request,
			worker_resident_id,
			absolute_minute,
			"counter_batch",
			"同一批饭菜已经递到手里",
			true,
		):
			completed_count += 1
	return completed_count


static func complete_as_takeaway(
	world,
	request: Dictionary,
	absolute_minute: int,
	reason: String,
) -> bool:
	if String(request.get("state", "")) not in [
		"pending", "waiting", "in_progress",
	]:
		return false
	var task := world._work_tasks.task(
		String(request.get("taskId", "")),
	) as Dictionary
	if not task.is_empty() and String(task.get("state", "")) not in [
		"completed", "failed", "cancelled",
	]:
		var assigned_id := String(task.get("assignedResidentId", ""))
		if (
			not assigned_id.is_empty()
			and world._resident_is_actively_processing_work_task(
				assigned_id,
				String(task.get("taskId", "")),
			)
		):
			world._interrupt_action(assigned_id, "顾客已经领取打包餐")
		world._work_tasks.cancel_task(
			String(task.get("taskId", "")),
			"订单已由关餐打包兜底完成",
		)
	var requester_id := String(request.get("requesterResidentId", ""))
	if not _complete_order_record(
		world,
		request,
		requester_id,
		absolute_minute,
		"closing_takeaway",
		reason,
		false,
	):
		return false
	_send_home(world, requester_id, reason)
	return true


static func settle_period_close(world, absolute_minute: int) -> void:
	var ending_period := _meal_period_ending_at(world, absolute_minute)
	if ending_period.is_empty():
		return
	var period_ref: String = String(
		world._meal_period_source_ref(absolute_minute - 1),
	)
	for request_value: Variant in (
		world._occupation_services.snapshot() as Dictionary
	).get("requests", []) as Array:
		var request := request_value as Dictionary
		if (
			String(request.get("kind", "")) != "dining_order"
			or String(request.get("state", "")) not in [
				"pending", "waiting", "in_progress",
			]
			or _request_meal_period_ref(world, request) != period_ref
		):
			continue
		var requester_id := String(request.get("requesterResidentId", ""))
		var requester := world._residents.get(requester_id, {}) as Dictionary
		if String(requester.get("currentPlace", "")) == (
			CONTENT_CATALOG.PLACE_DINING_HALL
		):
			complete_as_takeaway(
				world,
				request,
				absolute_minute,
				"本餐次结束前已经领取打包餐",
			)
		else:
			world._cancel_occupation_service_request(
				request,
				"本餐次已经结束，居民也已离开食堂",
			)
	if String(ending_period.get("id", "")) != "dinner":
		return
	for resident_id: String in world._resident_order:
		var resident := world._residents.get(resident_id, {}) as Dictionary
		if String(resident.get("currentPlace", "")) != (
			CONTENT_CATALOG.PLACE_DINING_HALL
		):
			continue
		var completed_meal: bool = bool(
			world._occupation_services.has_dining_order_completed_for_resident_meal_period(
				resident_id,
				period_ref,
			)
		)
		if not completed_meal:
			world._apply_consumed_service_item(resident_id, "meal")
			world._occupation_services.mark_dining_order_completed_for_resident_meal_period(
				resident_id,
				period_ref,
			)
			completed_meal = true
		if completed_meal:
			_send_home(
				world,
				resident_id,
				"食堂结束供餐，已经吃好或领好打包餐，早点回家",
			)


static func _request_meal_period_ref(world, request: Dictionary) -> String:
	var period_ref := String(
		(request.get("context", {}) as Dictionary).get(
			"mealPeriodRef",
			"",
		),
	).strip_edges()
	if period_ref.is_empty():
		period_ref = world._meal_period_source_ref(
			int(request.get("createdAtMinute", -1)),
		)
	return period_ref


static func _handoff_outcome(
	request: Dictionary,
	service_mode: String,
) -> Dictionary:
	return {
		"kind": "meal_handoff",
		"customerResidentId": String(
			request.get("requesterResidentId", ""),
		),
		"itemId": "meal",
		"quantity": 1,
		"stockDecremented": false,
		"deliveryRequested": false,
		"deliveryLotId": "",
		"destinationPlaceId": "",
		"supplyMode": "base_always_available",
		"serviceMode": service_mode,
		"batchCapacity": BATCH_SIZE,
	}


static func _complete_batch_work_task(
	world,
	task_value: Dictionary,
	worker_resident_id: String,
	outcome: Dictionary,
) -> bool:
	var task := task_value.duplicate(true)
	if task.is_empty():
		return false
	var task_id := String(task.get("taskId", ""))
	var state := String(task.get("state", ""))
	var assigned_id := String(task.get("assignedResidentId", ""))
	if state == "in_progress":
		return false
	if state == "accepted" and assigned_id != worker_resident_id:
		var released := world._work_tasks.release_task(
			task_id,
			assigned_id,
			int(task.get("revision", 0)),
			"由同一批次的递餐负责人一并处理",
		) as Dictionary
		if released.get("ok") != true:
			return false
		task = released.get("task", {}) as Dictionary
		state = String(task.get("state", ""))
	if state in ["open", "waiting"]:
		var occupation_id: String = String(world._task_acceptance_occupation_id(
			worker_resident_id,
			task,
		))
		var accepted := world._work_tasks.accept_task(
			task_id,
			worker_resident_id,
			occupation_id,
			int(task.get("revision", 0)),
		) as Dictionary
		if accepted.get("ok") != true:
			return false
		task = accepted.get("task", {}) as Dictionary
		state = "accepted"
	if state == "accepted":
		var started := world._work_tasks.start_task(
			task_id,
			worker_resident_id,
			int(task.get("revision", 0)),
		) as Dictionary
		if started.get("ok") != true:
			return false
		task = started.get("task", {}) as Dictionary
	if String(task.get("state", "")) != "in_progress":
		return false
	var completed := world._work_tasks.complete_task(
		task_id,
		worker_resident_id,
		int(task.get("revision", 0)),
		String(task.get("requestedResultKind", "")),
		{
			"resultRef": "dining-batch:%s" % String(
				task.get("sourceRef", ""),
			),
			"facts": outcome.duplicate(true),
		},
	) as Dictionary
	return completed.get("ok") == true


static func _complete_order_record(
	world,
	request: Dictionary,
	worker_resident_id: String,
	absolute_minute: int,
	service_mode: String,
	reason: String,
	resume_meal_routine: bool,
) -> bool:
	var request_id := String(request.get("requestId", ""))
	var requester_id := String(request.get("requesterResidentId", ""))
	var completed := world._occupation_services.complete_request(
		request_id,
		worker_resident_id,
		absolute_minute,
		_handoff_outcome(request, service_mode),
	) as Dictionary
	if completed.get("ok") != true:
		return false
	world._apply_consumed_service_item(requester_id, "meal")
	var meal_period_ref := _request_meal_period_ref(world, request)
	if not meal_period_ref.is_empty():
		world._occupation_services.mark_dining_order_completed_for_resident_meal_period(
			requester_id,
			meal_period_ref,
		)
	world.record_place_service_request(
		String(request.get("placeId", CONTENT_CATALOG.PLACE_DINING_HALL)),
		request_id,
		false,
	)
	world._finish_customer_service_wait(
		requester_id,
		request_id,
		reason,
		resume_meal_routine,
	)
	return true


static func _send_home(world, resident_id: String, reason: String) -> bool:
	var resident := world._residents.get(resident_id, {}) as Dictionary
	if (
		resident.is_empty()
		or String(resident.get("currentPlace", ""))
		!= CONTENT_CATALOG.PLACE_DINING_HALL
	):
		return false
	var home_place: String = String(world._home_place_for_resident(resident_id))
	if home_place.is_empty():
		world._schedule_decision(resident_id, true)
		return false
	var current_action := resident.get("currentAction", {}) as Dictionary
	if (
		String(current_action.get("type", "")) == "去"
		and String(current_action.get("place", "")) == home_place
	):
		return true
	if not current_action.is_empty():
		world._interrupt_action(resident_id, reason, true)
		resident = world._residents.get(resident_id, {}) as Dictionary
	if world._activity_routines.has(resident_id):
		world._close_activity_routine(resident_id, "completed", reason)
	if bool(resident.get("decisionPending", false)):
		world._restore_inflight_facts(resident)
		resident["decisionPending"] = false
		resident["validDecisionId"] = ""
		resident["pendingWake"] = {}
		resident["wakeDispatchQueued"] = false
	# advance() 可能一次推进多个分钟，但关餐结算仍按当前 tick 逐分钟执行。
	# 路线必须从本次结算分钟开始计时；直接读取环境时钟会拿到这次
	# advance 的最终分钟，让已经领餐的居民在食堂原地停留到未来时刻。
	var settlement_minute := int(world._authoritative_absolute_minute())
	var prepared := world._prepare_go_action(
		resident,
		{
			"action_id": "dining-close-home:%s:%d" % [
				resident_id,
				settlement_minute,
			],
			"type": "去",
			"place": home_place,
			"line": reason,
		},
	) as Dictionary
	if prepared.get("ok") != true:
		world._schedule_decision(resident_id, true)
		return false
	var action := (
		prepared.get("action", {}) as Dictionary
	).duplicate(true)
	action["startedAbsoluteMinute"] = settlement_minute
	resident["currentAction"] = action
	(resident.get("usedActionIds", {}) as Dictionary)[
		String(action.get("action_id", ""))
	] = true
	resident["doing"] = "食堂结束供餐，正在回家"
	world._bump_world_revision(false)
	world._emit_resident_state_changed(resident_id)
	return true


static func _meal_period_ending_at(world, absolute_minute: int) -> Dictionary:
	if absolute_minute <= 0:
		return {}
	var previous_minute := absolute_minute - 1
	var period := world._meal_period_for_minute(previous_minute) as Dictionary
	if period.is_empty():
		return {}
	var day_start := previous_minute - posmod(previous_minute, 1440)
	var period_end := day_start + int(period.get("end", 0))
	return period if absolute_minute == period_end else {}
