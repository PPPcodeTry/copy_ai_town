class_name TownSaveSchemaRegistry
extends RefCounted
## 存档链路版本常量与已发布迁移规则的唯一事实源(批次E之3)。各文件原常量改为引用本表,
## 数值逐字保留。目标:回答"v1 存档今天还能不能开"时只查一处。
## agent 层的 PERSISTENT_STATE/MEMORY_STATE 版本归 agent 域(tim),不入本表。

const WORLD_SCHEMA_VERSION := 2
const WORLD_SUPPORTED_SCHEMA_VERSIONS := [1, 2]
const MANIFEST_SCHEMA_VERSION := 3
const MANIFEST_LEGACY_SCHEMA_VERSION := 1
const MANIFEST_PREVIOUS_SCHEMA_VERSION := 2
const PROFILE_SCHEMA_VERSION := 2
const PROFILE_LEGACY_SCHEMA_VERSION := 1
const AGENT_SAVE_FORMAT_VERSION := 3
const NEW_GAME_DRAFT_SCHEMA_VERSION := 1
const CUSTOM_RESIDENT_LIBRARY_SCHEMA_VERSION := 1

# 活动运行时的 sourceFingerprint 只描述编译数据整体版本，不能替代逐字段迁移。
# 每次发布会改变已保存引用含义的活动/位置/道具/锚点时，必须在下方登记一条
# 从旧 sourceFingerprint 到下一版本的、可重复执行的字段迁移。旧规则一旦随版本
# 发布就不能删除，否则跳过多个版本的存档会失去升级路径。
const ACTIVITY_SAVE_MIGRATION_VERSION := 1
const ACTIVITY_SOURCE_FINGERPRINT_BEFORE_PUBLIC_DINING_SLOT_REWORK := (
	"bf870f16f18fde30f8512bdd6c1fbbaa62989f38970af10d1630d4ab87947dff"
)
const ACTIVITY_SOURCE_FINGERPRINT_AFTER_PUBLIC_DINING_SLOT_REWORK := (
	"584ba4b89019f92378131a56bc380e0c2dec5e460d977d7050484996a9c57a9f"
)
const ACTIVITY_SAVE_MIGRATIONS := [
	{
		"id": "2026-08-10-public-dining-prepare-dough-target",
		"fromSourceFingerprint": (
			ACTIVITY_SOURCE_FINGERPRINT_BEFORE_PUBLIC_DINING_SLOT_REWORK
		),
		"toSourceFingerprint": (
			ACTIVITY_SOURCE_FINGERPRINT_AFTER_PUBLIC_DINING_SLOT_REWORK
		),
		"executionRewrites": [
			{
				"activityId": "activity_baker_prepare_dough",
				"slotId": "slot_baker_prepare_dough_01",
				"targetType": "prop",
				"targetActionVerb": "准备面团",
				"field": "targetPropName",
				"from": "公共食堂备餐柜",
				"to": "公共食堂面团操作台",
			},
		],
		"placeServiceStateRewrites": [
			{
				"placeId": "公共食堂",
				"field": "service_capacity",
				"from": 2,
				"to": 4,
			},
		],
	},
]


static func migrate_activity_runtime_state(
	value: Dictionary,
	current_source_fingerprint: String,
) -> Dictionary:
	var state := value.duplicate(true)
	var source := String(state.get("sourceFingerprint", ""))
	var applied: Array[String] = []
	var visited := {}
	while (
		not source.is_empty()
		and source != current_source_fingerprint
		and not visited.has(source)
	):
		visited[source] = true
		var migration := _activity_migration_from(source)
		if migration.is_empty():
			break
		var rewrite_count := _apply_activity_migration(state, migration)
		var migration_id := String(migration.get("id", ""))
		if rewrite_count > 0 and not migration_id.is_empty():
			applied.append(migration_id)
		var next_source := String(migration.get("toSourceFingerprint", ""))
		if next_source.is_empty() or next_source == source:
			break
		source = next_source
		state["sourceFingerprint"] = source
	return {
		"ok": true,
		"state": state,
		"applied": applied,
		"migrationVersion": ACTIVITY_SAVE_MIGRATION_VERSION,
	}


static func migrate_world_state(
	value: Dictionary,
	current_activity_source_fingerprint: String,
) -> Dictionary:
	var state := value.duplicate(true)
	var activity_state_value: Variant = state.get("activityRuntime", {})
	var source := (
		String((activity_state_value as Dictionary).get("sourceFingerprint", ""))
		if activity_state_value is Dictionary
		else ""
	)
	var applied: Array[String] = []
	var visited := {}
	while (
		not source.is_empty()
		and source != current_activity_source_fingerprint
		and not visited.has(source)
	):
		visited[source] = true
		var migration := _activity_migration_from(source)
		if migration.is_empty():
			break
		var rewrite_count := _apply_place_service_state_migration(
			state,
			migration,
		)
		var migration_id := String(migration.get("id", ""))
		if rewrite_count > 0 and not migration_id.is_empty():
			applied.append(migration_id)
		var next_source := String(migration.get("toSourceFingerprint", ""))
		if next_source.is_empty() or next_source == source:
			break
		source = next_source
	return {
		"ok": true,
		"state": state,
		"applied": applied,
		"migrationVersion": ACTIVITY_SAVE_MIGRATION_VERSION,
	}


static func _activity_migration_from(source_fingerprint: String) -> Dictionary:
	for value: Variant in ACTIVITY_SAVE_MIGRATIONS:
		var migration := value as Dictionary
		if String(migration.get("fromSourceFingerprint", "")) == source_fingerprint:
			return migration
	return {}


static func _apply_activity_migration(
	state: Dictionary,
	migration: Dictionary,
) -> int:
	var rewrite_count := 0
	for execution_value: Variant in state.get("executions", []) as Array:
		if not execution_value is Dictionary:
			continue
		var execution := execution_value as Dictionary
		for rewrite_value: Variant in migration.get("executionRewrites", []) as Array:
			if not rewrite_value is Dictionary:
				continue
			var rewrite := rewrite_value as Dictionary
			var matches := true
			for match_field in [
				"activityId",
				"slotId",
				"targetType",
				"targetActionVerb",
			]:
				if String(execution.get(match_field, "")) != String(
					rewrite.get(match_field, "")
				):
					matches = false
					break
			if not matches:
				continue
			var field := String(rewrite.get("field", ""))
			if (
				field.is_empty()
				or String(execution.get(field, ""))
				!= String(rewrite.get("from", ""))
			):
				continue
			execution[field] = rewrite.get("to", "")
			rewrite_count += 1
	return rewrite_count


static func _apply_place_service_state_migration(
	state: Dictionary,
	migration: Dictionary,
) -> int:
	var states_value: Variant = state.get("placeServiceStates", {})
	if not states_value is Dictionary:
		return 0
	var states := states_value as Dictionary
	var rewrite_count := 0
	for rewrite_value: Variant in migration.get(
		"placeServiceStateRewrites",
		[],
	) as Array:
		if not rewrite_value is Dictionary:
			continue
		var rewrite := rewrite_value as Dictionary
		var place_id := String(rewrite.get("placeId", ""))
		var place_state_value: Variant = states.get(place_id, {})
		if not place_state_value is Dictionary:
			continue
		var place_state := place_state_value as Dictionary
		var field := String(rewrite.get("field", ""))
		if (
			field.is_empty()
			or not place_state.has(field)
			or place_state.get(field) != rewrite.get("from")
		):
			continue
		place_state[field] = rewrite.get("to")
		rewrite_count += 1
	return rewrite_count
