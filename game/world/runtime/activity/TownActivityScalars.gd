extends RefCounted


# 活动执行/身体需求/工单匹配等纯标量函数族(O 域迁移第八件)。

static func safe_activity_execution(execution: Dictionary) -> Dictionary:
	var label := String(
		execution.get(
			"label",
			execution.get("activityLabel", ""),
		)
	)
	var result_text := "已开始"
	match String(execution.get("status", "")):
		"completed":
			result_text = "已完成"
		"interrupted":
			result_text = "已中断"
		"failed":
			result_text = "未能完成"
	return {
		"activityId": String(execution.get("activityId", "")),
		"label": label,
		"placeId": String(execution.get("placeId", "")),
		"role": String(execution.get("role", "")),
		"result": result_text,
	}

static func activity_progress_doing(
	execution: Dictionary,
	performing_minutes: int,
) -> String:
	var label := String(
		execution.get(
			"activityLabel",
			execution.get("label", "当前活动"),
		)
	).strip_edges()
	if label.is_empty():
		label = "当前活动"
	if label.begins_with("在") and label.length() > 1:
		label = label.substr(1)
	if label.length() > 10:
		label = label.substr(0, 10)
	if String(execution.get("role", "")) != "worker":
		return "正在%s" % label
	match posmod(floori(float(performing_minutes) / 5.0), 3):
		0:
			return "正在%s" % label
		1:
			return "%s进行中" % label
		_:
			return "继续%s" % label

static func empty_activity_state() -> Dictionary:
	return {
		"energy": 50,
		"satiety": 50,
		"stress": 50,
		"socialNeed": 50,
		"solitudeNeed": 50,
	}

static func need_value_for_body_level(level: String) -> int:
	if level.begins_with("很"):
		return 20
	if level.begins_with("有点"):
		return 35
	return 50

static func sync_body_from_activity_needs(
	resident: Dictionary,
	activity_state: Dictionary,
) -> void:
	var body := resident.get("body", {}) as Dictionary
	var satiety := int(activity_state.get("satiety", 50))
	var energy := int(activity_state.get("energy", 50))
	body["饿"] = (
		"很饿"
		if satiety <= 20
		else ("有点饿" if satiety <= 35 else "不饿")
	)
	body["累"] = (
		"很累"
		if energy <= 20
		else ("有点累" if energy <= 35 else "不累")
	)

static func meal_period_for_minute(absolute_minute: int) -> Dictionary:
	var minute_of_day := posmod(absolute_minute, 1440)
	for period: Dictionary in [
		{
			"id": "breakfast", "label": "早餐",
			"start": 300, "serviceStart": 360, "end": 600,
		},
		{
			"id": "lunch", "label": "午餐",
			"start": 600, "serviceStart": 660, "end": 840,
		},
		{
			"id": "dinner", "label": "晚餐",
			"start": 960, "serviceStart": 1020, "end": 1200,
		},
	]:
		if minute_of_day >= int(period.get("start", 0)) and minute_of_day < int(
			period.get("end", 0),
		):
			return period.duplicate(true)
	return {}

static func activity_candidate_physical_targets(
	candidates: Array,
) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var seen: Dictionary = {}
	for value: Variant in candidates:
		var candidate := value as Dictionary
		var kind := String(candidate.get("targetType", ""))
		var ref := ""
		if kind == "region":
			ref = String(candidate.get("targetRegionId", ""))
		elif kind == "prop":
			ref = String(candidate.get("targetPropName", ""))
		else:
			continue
		var key := "%s:%s" % [kind, ref]
		if ref.is_empty() or seen.has(key):
			continue
		seen[key] = true
		result.append({"kind": kind, "ref": ref})
	return result

static func matching_work_tasks_for_targets(
	tasks: Array,
	physical_targets: Array[Dictionary],
) -> Array:
	if physical_targets.is_empty():
		return tasks.duplicate()
	var result: Array = []
	for value: Variant in tasks:
		var task := value as Dictionary
		var declared_region_targets: Array[Dictionary] = []
		for target_value: Variant in task.get("targets", []) as Array:
			var target := target_value as Dictionary
			if String(target.get("kind", "")) in [
				"region",
				"audience_area",
			]:
				declared_region_targets.append(target)
		if declared_region_targets.is_empty():
			result.append(task)
			continue
		var matches := false
		for declared: Dictionary in declared_region_targets:
			for actual: Dictionary in physical_targets:
				if (
					String(actual.get("kind", "")) == "region"
					and String(declared.get("ref", ""))
					== String(actual.get("ref", ""))
				):
					matches = true
					break
			if matches:
				break
		if matches:
			result.append(task)
	return result

static func onsite_service_wait_minutes(kind: String) -> int:
	# 诊所看诊包含自由问诊、检查和必要的配药；餐饮要等真实备餐。
	# 普通柜台服务窗口对这些真实链条太短。
	match kind:
		"dining_order":
			return 30
		"clinic", "cafe_order":
			return 120
	return 30

static func target_refs_match(
	expected: Dictionary,
	actual: Dictionary,
) -> bool:
	for key_value: Variant in expected:
		var key := String(key_value)
		if not actual.has(key) or actual.get(key) != expected.get(key):
			return false
	return true

static func duplicate_optional_dictionary(value: Variant) -> Variant:
	return (value as Dictionary).duplicate(true) if typeof(value) == TYPE_DICTIONARY else null

static func append_unique_story_ids(
	target: Array[String],
	values: Array,
) -> void:
	for value: Variant in values:
		var normalized := String(value).strip_edges()
		if not normalized.is_empty() and not target.has(normalized):
			target.append(normalized)
