extends RefCounted


static func query(
	world,
	resident_id: String,
	resident_override: Dictionary = {},
	max_uncached_reachability_checks := -1,
	priority_activity_id := "",
) -> Dictionary:
	if not world._running:
		return world._command_failure("WORLD_NOT_RUNNING", ["世界尚未运行"])
	var normalized_id := resident_id.strip_edges()
	if normalized_id.is_empty() or not world._residents.has(normalized_id):
		return world._command_failure(
			"ACTIVITY_STATE_CHANGED",
			["activity query 必须使用稳定 residentId"],
		)
	var resident := world._residents[normalized_id] as Dictionary
	if not resident_override.is_empty():
		resident = resident_override.duplicate(true)
	var absolute_minute := int(world._environment.get_absolute_minute())
	var option_by_id: Dictionary = {}
	var result := {
		"ok": true,
		"errorCode": "",
		"options": [],
	}
	var query_occupation_ids: Array = world._work_occupation_ids_for_resident(
		normalized_id,
	)
	if query_occupation_ids.is_empty():
		query_occupation_ids.append("")
	for occupation_id: String in query_occupation_ids:
		var social_state := (
			resident.get("socialState", {}) as Dictionary
		).duplicate(true)
		if not occupation_id.is_empty():
			social_state["occupationId"] = occupation_id
		var occupation_result := world._activity_runtime.query_options(
			normalized_id,
			social_state,
			String(resident.get("currentPlace", "")),
			absolute_minute % 1440,
			world.get_weather(),
		) as Dictionary
		if occupation_result.get("ok") != true:
			result = occupation_result
			break
		for option_value: Variant in occupation_result.get(
			"options",
			[],
		) as Array:
			var option := option_value as Dictionary
			var activity_id := String(option.get("activityId", ""))
			if (
				not option_by_id.has(activity_id)
				or bool(option.get("available", false))
			):
				option_by_id[activity_id] = option.duplicate(true)
	if result.get("ok") == true:
		var activity_ids: Array[String] = []
		for activity_id_value: Variant in option_by_id:
			activity_ids.append(String(activity_id_value))
		activity_ids.sort()
		var merged_options: Array[Dictionary] = []
		for activity_id: String in activity_ids:
			merged_options.append(
				(
					option_by_id.get(activity_id, {}) as Dictionary
				).duplicate(true),
			)
		result["options"] = merged_options
	if result.get("ok") == true:
		# 先完成不需要寻路的资格判断。限额模式必须把真正有职业任务、
		# 需要休息等仍可执行的活动排在前面，不能让已经失效的工作占掉
		# 本帧唯一一次新路线检查。
		for option_value: Variant in result.get("options", []) as Array:
			var option := option_value as Dictionary
			world._apply_sleep_activity_availability(resident, option)
			world._apply_bulletin_activity_availability(normalized_id, option)
			world._apply_work_task_activity_availability(
				normalized_id,
				resident,
				option,
			)
			world._apply_occupation_service_activity_availability(
				normalized_id,
				option,
			)
			world._apply_clinic_visitor_activity_availability(
				normalized_id,
				option,
			)
			world._apply_clinic_practitioner_request_priority(
				normalized_id,
				option,
			)
		# 同一次查询里，不同活动选项的候选经常落在同一区域/落点，
		# 可达性寻路按目标去重，避免重复的整张路网 A*。
		var reachability_memo := {}
		var uncached_reachability_checks := 0
		world._ensure_activity_reachability_cache_minute()
		if max_uncached_reachability_checks >= 0:
			(result.get("options", []) as Array).sort_custom(
				func(left: Dictionary, right: Dictionary) -> bool:
					var left_priority := _agent_activity_route_priority(
						world,
						left,
						priority_activity_id,
					)
					var right_priority := _agent_activity_route_priority(
						world,
						right,
						priority_activity_id,
					)
					if left_priority != right_priority:
						return left_priority < right_priority
					return String(left.get("activityId", "")) < String(
						right.get("activityId", ""),
					)
			)
		for option_value: Variant in result.get("options", []) as Array:
			var option := option_value as Dictionary
			# Weather is part of the formal activity contract. A later
			# reachability check may further disable an available option, but
			# it must never reopen an option that weather already rejected.
			if not bool(option.get("available", false)):
				continue
			var candidates := world._activity_runtime.query_preflight_candidates(
				world._activity_social_state_for(
					normalized_id,
					String(option.get("activityId", "")),
				),
				String(resident.get("currentPlace", "")),
				String(option.get("activityId", "")),
			) as Array
			# 可达性探测在第一个可达候选处停止；按与居民的直线距离
			# 预排序，让最可能可达的候选先寻路，减少每个选项的 A* 次数。
			# 只影响探测顺序，不影响"任一可达即可用"的判定结果。
			var probe_origin := resident.get("position", Vector2.ZERO) as Vector2
			candidates.sort_custom(func(left: Dictionary, right: Dictionary) -> bool:
				var left_pos := left.get("memberPosition", []) as Array
				var right_pos := right.get("memberPosition", []) as Array
				var left_dist := (
					probe_origin.distance_squared_to(
						Vector2(float(left_pos[0]), float(left_pos[1])),
					)
					if left_pos.size() == 2
					else INF
				)
				var right_dist := (
					probe_origin.distance_squared_to(
						Vector2(float(right_pos[0]), float(right_pos[1])),
					)
					if right_pos.size() == 2
					else INF
				)
				return left_dist < right_dist
			)
			var has_unreserved := false
			var has_reachable := false
			var reachability_deferred := false
			for candidate_value: Variant in candidates:
				var candidate := candidate_value as Dictionary
				if not bool(candidate.get("memberAvailable", false)):
					continue
				has_unreserved = true
				var candidate_cache_key: String = world._activity_candidate_cache_key(
					resident,
					candidate,
				)
				var cached_reachability: bool = (
					world._activity_reachability_cache.has(candidate_cache_key)
				)
				if (
					not cached_reachability
					and max_uncached_reachability_checks >= 0
					and uncached_reachability_checks
					>= max_uncached_reachability_checks
				):
					reachability_deferred = true
					continue
				if not cached_reachability:
					uncached_reachability_checks += 1
				if world._activity_query_candidate_reachable(
					resident,
					candidate,
					String(option.get("label", "")),
					reachability_memo,
				):
					has_reachable = true
					break
			option["available"] = has_reachable
			option["disabledReason"] = (
				""
				if has_reachable
				else (
					"ACTIVITY_REACHABILITY_DEFERRED"
					if reachability_deferred
					else "ACTIVITY_TARGET_UNREACHABLE"
					if has_unreserved
					else "ACTIVITY_RESERVATION_CONFLICT"
				)
			)
	return world._decorate_command_result(result)


static func _agent_activity_route_priority(
	world,
	option: Dictionary,
	priority_activity_id: String,
) -> int:
	if (
		not priority_activity_id.is_empty()
		and String(option.get("activityId", "")) == priority_activity_id
	):
		return -1
	if not bool(option.get("available", false)):
		return 3
	if String(option.get("role", "")) == "worker":
		return 0
	if String(option.get("activityId", "")) == world.SLEEP_ACTIVITY_ID:
		return 1
	return 2
