extends RefCounted


const RESIDENT_PRESENTATION_REFRESH_BUDGET_PER_ADVANCE := 3
const RESIDENT_PLACE_CHANGE_SIGNAL_BUDGET_PER_ADVANCE := 1
const PERCEPTION_MAX_DEFERRED_ADVANCES := 12


static func reset(world) -> void:
	world._deferred_resident_state_refreshes.clear()
	world._deferred_resident_state_refresh_keys.clear()
	world._deferred_resident_place_change_signals.clear()
	world._perception_refresh_deferred = false
	world._perception_deferred_advance_count = 0


static func defer_perception_refresh(world) -> void:
	if not world._perception_refresh_deferred:
		world._perception_deferred_advance_count = 0
	world._perception_refresh_deferred = true


static func queue_resident_state_refresh(world, resident_id: String) -> void:
	if world._deferred_resident_state_refresh_keys.has(resident_id):
		return
	world._deferred_resident_state_refresh_keys[resident_id] = true
	world._deferred_resident_state_refreshes.append(resident_id)


static func queue_resident_place_change_signal(
	world,
	resident_id: String,
	place_change: Dictionary,
) -> void:
	# 地点事件已经逐条写入公开日志；这里排的是表现通知。低帧率或 3 倍速下，
	# 同一居民再次跨区时合并到最新终点，队列长度因此最多等于居民数。
	for queued_value: Variant in world._deferred_resident_place_change_signals:
		var queued := queued_value as Dictionary
		if String(queued.get("residentId", "")) != resident_id:
			continue
		var queued_change := queued.get("change", {}) as Dictionary
		queued_change["to"] = place_change.get("to", queued_change.get("to", ""))
		queued_change["time"] = place_change.get(
			"time",
			queued_change.get("time", {}),
		)
		queued_change["worldRevision"] = place_change.get(
			"worldRevision",
			queued_change.get("worldRevision", world._world_revision),
		)
		return
	world._deferred_resident_place_change_signals.append({
		"residentId": resident_id,
		"change": place_change,
	})


static func process_deferred_work(world, advance_profile: Dictionary) -> Dictionary:
	var result := {
		"presentationProcessed": 0,
		"placeProcessed": 0,
		"perceptionProcessed": false,
	}
	if world._perception_refresh_deferred:
		world._perception_deferred_advance_count += 1
	if (
		world._perception_refresh_deferred
		and world._perception_deferred_advance_count
		>= PERCEPTION_MAX_DEFERRED_ADVANCES
	):
		_refresh_perception(world, advance_profile)
		result["perceptionProcessed"] = true
	elif not world._deferred_resident_place_change_signals.is_empty():
		var lap_usec := Time.get_ticks_usec() if world._advance_profile_enabled else 0
		result["placeProcessed"] = _drain_place_change_signals(world)
		world._advance_profile_lap(
			advance_profile,
			"deferredPlaceChangeSignalUsec",
			lap_usec,
		)
		if (
			world._deferred_resident_place_change_signals.is_empty()
			and world._deferred_resident_state_refreshes.is_empty()
		):
			defer_perception_refresh(world)
	elif not world._deferred_resident_state_refreshes.is_empty():
		var lap_usec := Time.get_ticks_usec() if world._advance_profile_enabled else 0
		result["presentationProcessed"] = _drain_state_refreshes(world)
		world._advance_profile_lap(
			advance_profile,
			"deferredPresentationRefreshUsec",
			lap_usec,
		)
		if world._deferred_resident_state_refreshes.is_empty():
			defer_perception_refresh(world)
	elif world._perception_refresh_deferred:
		_refresh_perception(world, advance_profile)
		result["perceptionProcessed"] = true
	return result


static func refresh_or_defer_perception(world) -> void:
	if (
		world._deferred_resident_place_change_signals.is_empty()
		and world._deferred_resident_state_refreshes.is_empty()
	):
		world.PERCEPTION_RUNTIME._refresh_perception(world, true)
	else:
		defer_perception_refresh(world)


static func _drain_state_refreshes(world) -> int:
	var resident_ids: Array[String] = []
	while (
		not world._deferred_resident_state_refreshes.is_empty()
		and resident_ids.size()
		< RESIDENT_PRESENTATION_REFRESH_BUDGET_PER_ADVANCE
	):
		var resident_id: String = world._deferred_resident_state_refreshes.pop_front()
		world._deferred_resident_state_refresh_keys.erase(resident_id)
		if not world._residents.has(resident_id):
			continue
		resident_ids.append(resident_id)
	if resident_ids.is_empty():
		return 0
	world._bump_world_revision(false)
	for resident_id: String in resident_ids:
		world._emit_resident_state_changed(resident_id)
	world._notify_world_revision()
	return resident_ids.size()


static func _drain_place_change_signals(world) -> int:
	var signals: Array[Dictionary] = []
	while (
		not world._deferred_resident_place_change_signals.is_empty()
		and signals.size()
		< RESIDENT_PLACE_CHANGE_SIGNAL_BUDGET_PER_ADVANCE
	):
		var deferred_signal := (
			world._deferred_resident_place_change_signals.pop_front()
			as Dictionary
		)
		if not world._residents.has(
			String(deferred_signal.get("residentId", "")),
		):
			continue
		signals.append(deferred_signal)
	if signals.is_empty():
		return 0
	world._bump_world_revision(false)
	for deferred_signal: Dictionary in signals:
		var resident_id := String(deferred_signal.get("residentId", ""))
		var place_change := deferred_signal.get("change", {}) as Dictionary
		place_change["state"] = world.get_resident_state(resident_id)
		place_change["worldRevision"] = world._world_revision
		world.resident_place_changed.emit(
			world._resident_display_name(resident_id),
			place_change,
		)
	world._notify_world_revision()
	return signals.size()


static func _refresh_perception(world, advance_profile: Dictionary) -> void:
	var lap_usec := Time.get_ticks_usec() if world._advance_profile_enabled else 0
	world._perception_refresh_deferred = false
	world._perception_deferred_advance_count = 0
	world._bump_world_revision(false)
	world.PERCEPTION_RUNTIME._refresh_perception(world, true)
	world._notify_world_revision()
	world._advance_profile_lap(
		advance_profile,
		"perceptionUsec",
		lap_usec,
	)
