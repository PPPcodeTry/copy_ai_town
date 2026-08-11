extends RefCounted


static func clear(world) -> void:
	world._activity_reachability_cache.clear()
	world._activity_prepared_action_cache.clear()
	world._activity_reachability_cache_minute = -1
