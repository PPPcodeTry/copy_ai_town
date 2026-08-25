# 室内前景墙遮挡。前景贴图由资源工具预生成，运行时只校验并加载；
# 人物脚点、可见性或深度没有变化时，不重复执行多边形命中计算。
class_name InteriorWallOcclusion
extends Node2D

const Z_STEP := 4
const DEFAULT_FOREGROUND_Z := 999
const MANIFEST := preload(
	"res://world/maps/town/interiors/InteriorOcclusionManifest.gd"
)

var _segments: Array[Dictionary] = []
var _subject_overlays: Dictionary = {}
var _subject_states: Dictionary = {}
var _debug_root: Node2D
var _manifest_validator: InteriorOcclusionManifest
var _pending_segments: Array[Dictionary] = []
var _pending_debug_root: Node2D
var _pending_world_origin := Vector2.ZERO
var _configuration_active := false


func configure(
	shell_value: Variant,
	geometry_value: Variant,
	geometry_path_value: Variant,
	occlusion_path_value: Variant,
	shell_path_value: Variant,
) -> bool:
	if not begin_configuration(
		shell_value,
		geometry_value,
		geometry_path_value,
		occlusion_path_value,
		shell_path_value,
	):
		return false
	while _configuration_active:
		var result := continue_configuration()
		if result.get("failed") == true:
			return false
	return true


func begin_configuration(
	shell_value: Variant,
	geometry_value: Variant,
	geometry_path_value: Variant,
	occlusion_path_value: Variant,
	shell_path_value: Variant,
) -> bool:
	if not shell_value is Sprite2D or not geometry_value is Dictionary:
		return false
	if (
		not geometry_path_value is String
		or not occlusion_path_value is String
		or not shell_path_value is String
	):
		return false
	var shell := shell_value as Sprite2D
	var geometry := geometry_value as Dictionary
	if shell.texture == null:
		return false
	_release_pending_configuration()
	_manifest_validator = MANIFEST.new() as InteriorOcclusionManifest
	var begun := _manifest_validator.begin_load_staged(
		geometry,
		geometry_path_value,
		occlusion_path_value,
		shell_path_value,
	)
	if begun.get("ok") != true:
		push_error(
			"Pre-generated interior occlusion is stale or invalid (%s): %s"
			% [begun.get("code", "UNKNOWN"), begun.get("error", "")],
		)
		_manifest_validator = null
		return false
	_pending_world_origin = _pair(geometry.get("world_origin_px"))
	_pending_debug_root = Node2D.new()
	_pending_debug_root.name = "WallOcclusionDebug"
	_pending_debug_root.visible = false
	_configuration_active = true
	return true


func continue_configuration() -> Dictionary:
	if not _configuration_active or not is_instance_valid(_manifest_validator):
		return {"ok": false, "complete": false, "failed": true}
	var step := _manifest_validator.validate_next_segment() as Dictionary
	if step.get("ok") != true:
		return _fail_pending_configuration(step)
	var segment_value: Variant = step.get("segment")
	if segment_value is Dictionary and not _append_render_segment(
		segment_value as Dictionary,
		_pending_world_origin,
		_pending_segments,
		_pending_debug_root,
	):
		return _fail_pending_configuration({
			"code": "TEXTURE_LOAD_FAILED",
			"error": "validated segment texture could not be loaded",
		})
	if step.get("complete") == true:
		var committed_segments := _pending_segments
		var committed_debug_root := _pending_debug_root
		_pending_segments = []
		_pending_debug_root = null
		_manifest_validator = null
		_configuration_active = false
		_commit_build(committed_segments, committed_debug_root)
		return {"ok": true, "complete": true, "failed": false}
	return {"ok": true, "complete": false, "failed": false}


func _fail_pending_configuration(error: Dictionary) -> Dictionary:
	push_error(
		"Pre-generated interior occlusion is stale or invalid (%s): %s"
		% [error.get("code", "UNKNOWN"), error.get("error", "")],
	)
	_release_pending_configuration()
	return {"ok": false, "complete": false, "failed": true}


func _release_pending_configuration() -> void:
	if not _pending_segments.is_empty() or is_instance_valid(_pending_debug_root):
		_release_build(_pending_segments, _pending_debug_root)
	_pending_segments = []
	_pending_debug_root = null
	_manifest_validator = null
	_configuration_active = false


func set_debug_visible(value: Variant) -> void:
	if value is bool and is_instance_valid(_debug_root):
		_debug_root.visible = value


func is_debug_visible() -> bool:
	return is_instance_valid(_debug_root) and _debug_root.visible


func update_for_subject(subject_value: Variant) -> bool:
	return update_for_subjects([subject_value]) if subject_value is Node2D else false


func update_for_subjects(subject_values: Variant) -> bool:
	if not subject_values is Array:
		return false
	var subjects: Array[Node2D] = []
	for value: Variant in subject_values as Array:
		if not value is Node2D:
			return false
		var subject := value as Node2D
		if (
			is_instance_valid(subject)
			and subject.is_inside_tree()
			and subject.is_visible_in_tree()
		):
			subjects.append(subject)
	var next_states := _subject_states_for(subjects)
	if next_states == _subject_states:
		return false
	_subject_states = next_states
	_prune_subject_overlays(subjects)
	_hide_subject_overlays()
	var has_subject := not subjects.is_empty()
	var behind_z := DEFAULT_FOREGROUND_Z
	var has_subject_depth := false
	for subject in subjects:
		var subject_behind_z := _z_index_with_offset(subject.z_index, -Z_STEP)
		behind_z = subject_behind_z if not has_subject_depth else mini(
			behind_z,
			subject_behind_z,
		)
		has_subject_depth = true
	for segment in _segments:
		var foreground := segment.get("foreground") as CanvasItem
		if not is_instance_valid(foreground):
			continue
		if not has_subject:
			_reset_foreground(segment)
			continue
		# 完整墙面留在所有人物后方，只把触发脚点附近的小片提升到人物前方。
		foreground.z_index = behind_z
		foreground.modulate.a = 1.0
		for subject in subjects:
			var local_foot := to_local(subject.global_position)
			var active_polygon := _active_polygon_for(segment, local_foot)
			if active_polygon.is_empty():
				continue
			var overlay := _subject_overlay_for(segment, subject, local_foot)
			if not is_instance_valid(overlay):
				continue
			overlay.visible = true
			overlay.z_index = _z_index_with_offset(subject.z_index, Z_STEP)
			overlay.modulate = Color(
				1.0,
				1.0,
				1.0,
				_alpha_for_active_foot(local_foot, active_polygon, segment),
			)
	return true


func _build_render_nodes(
	validated_segments: Array[Dictionary],
	world_origin: Vector2,
) -> Dictionary:
	var new_segments: Array[Dictionary] = []
	var new_debug_root := Node2D.new()
	new_debug_root.name = "WallOcclusionDebug"
	new_debug_root.visible = false
	for segment_data in validated_segments:
		if not _append_render_segment(
			segment_data,
			world_origin,
			new_segments,
			new_debug_root,
		):
			_release_build(new_segments, new_debug_root)
			return {}
	return {"segments": new_segments, "debug_root": new_debug_root}


func _append_render_segment(
	segment_data: Dictionary,
	world_origin: Vector2,
	new_segments: Array[Dictionary],
	new_debug_root: Node2D,
) -> bool:
	var foreground := Sprite2D.new()
	foreground.name = String(segment_data.get("id"))
	foreground.centered = false
	foreground.position = (
		_pair(segment_data.get("foreground_canvas_origin_px"))
		- world_origin
	)
	foreground.texture = _load_texture(
		String(segment_data.get("foreground_texture_path")),
	)
	if foreground.texture == null:
		foreground.free()
		return false
	foreground.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	foreground.z_as_relative = false
	foreground.z_index = DEFAULT_FOREGROUND_Z
	var reveal_polygons: Array[PackedVector2Array] = []
	for polygon_value: Variant in (
		segment_data.get("reveal_polygons_canvas_px") as Array
	):
		var reveal_local := _offset_polygon(
			_polygon(polygon_value),
			-world_origin,
		)
		reveal_polygons.append(reveal_local)
		var debug_polygon := Polygon2D.new()
		debug_polygon.name = "Debug_%s_%02d" % [
			String(segment_data.get("id")),
			reveal_polygons.size(),
		]
		debug_polygon.polygon = reveal_local
		debug_polygon.color = Color(0.545, 0.361, 0.965, 0.34)
		debug_polygon.z_index = 1200
		new_debug_root.add_child(debug_polygon)
	new_segments.append({
		"id": String(segment_data.get("id")),
		"foreground": foreground,
		"reveal_polygons": reveal_polygons,
		"fade_distance_px": float(segment_data.get("fade_distance_px")),
		"minimum_alpha": float(segment_data.get("minimum_alpha")),
		"default_z_index": DEFAULT_FOREGROUND_Z,
	})
	return true


func _commit_build(
	new_segments: Array[Dictionary],
	new_debug_root: Node2D,
) -> void:
	_clear_render_nodes()
	for segment in new_segments:
		add_child(segment.get("foreground") as Sprite2D)
	add_child(new_debug_root)
	_segments = new_segments
	_debug_root = new_debug_root
	_subject_states.clear()
	name = "WallOcclusion"
	set_process(false)


func _clear_render_nodes() -> void:
	_subject_overlays.clear()
	for child in get_children():
		remove_child(child)
		child.free()
	_segments.clear()
	_subject_states.clear()
	_debug_root = null


func _release_build(
	segments: Array[Dictionary],
	debug_root: Node2D,
) -> void:
	for segment in segments:
		var foreground := segment.get("foreground") as Node
		if is_instance_valid(foreground):
			foreground.free()
	if is_instance_valid(debug_root):
		debug_root.free()


func _subject_states_for(subjects: Array[Node2D]) -> Dictionary:
	var states := {}
	for subject in subjects:
		states[subject.get_instance_id()] = {
			"global_position": subject.global_position,
			"z_index": subject.z_index,
		}
	return states


func _subject_overlay_for(
	segment: Dictionary,
	subject: Node2D,
	local_foot: Vector2,
) -> Sprite2D:
	var foreground := segment.get("foreground") as Sprite2D
	if not is_instance_valid(foreground) or foreground.texture == null:
		return null
	var segment_id := String(segment.get("id", "segment"))
	var key := "%s:%d" % [segment_id, subject.get_instance_id()]
	var overlay := _subject_overlays.get(key) as Sprite2D
	if not is_instance_valid(overlay):
		overlay = Sprite2D.new()
		overlay.name = "%sSubjectOverlay_%d" % [
			segment_id,
			subject.get_instance_id(),
		]
		overlay.centered = false
		overlay.texture_filter = foreground.texture_filter
		overlay.z_as_relative = false
		overlay.set_meta("subject_overlay", true)
		add_child(overlay)
		_subject_overlays[key] = overlay
	var source_rect := Rect2(Vector2.ZERO, foreground.texture.get_size())
	var slice := _subject_slice_rect(
		source_rect,
		local_foot - foreground.position,
	)
	if not slice.has_area():
		overlay.visible = false
		return overlay
	var atlas: AtlasTexture = (
		overlay.get_meta("atlas_texture") as AtlasTexture
		if overlay.has_meta("atlas_texture")
		else null
	)
	if not is_instance_valid(atlas):
		atlas = AtlasTexture.new()
		overlay.set_meta("atlas_texture", atlas)
	atlas.atlas = foreground.texture
	atlas.region = slice
	overlay.texture = atlas
	overlay.position = foreground.position + slice.position
	return overlay


func _subject_slice_rect(source_rect: Rect2, source_foot: Vector2) -> Rect2:
	if not source_rect.has_area():
		return Rect2()
	const HALF_EXTENT := 96.0
	var slice := source_rect
	if source_rect.size.x >= source_rect.size.y:
		var center_x := clampf(
			source_foot.x,
			source_rect.position.x,
			source_rect.end.x,
		)
		slice.position.x = center_x - HALF_EXTENT
		slice.size.x = HALF_EXTENT * 2.0
	else:
		var center_y := clampf(
			source_foot.y,
			source_rect.position.y,
			source_rect.end.y,
		)
		slice.position.y = center_y - HALF_EXTENT
		slice.size.y = HALF_EXTENT * 2.0
	return _intersection_rect(source_rect, slice)


func _intersection_rect(first: Rect2, second: Rect2) -> Rect2:
	var left := maxf(first.position.x, second.position.x)
	var top := maxf(first.position.y, second.position.y)
	var right := minf(first.end.x, second.end.x)
	var bottom := minf(first.end.y, second.end.y)
	return (
		Rect2(left, top, right - left, bottom - top)
		if right > left and bottom > top
		else Rect2()
	)


func _hide_subject_overlays() -> void:
	for overlay_value: Variant in _subject_overlays.values():
		var overlay := overlay_value as Sprite2D
		if is_instance_valid(overlay):
			overlay.visible = false


func _prune_subject_overlays(subjects: Array[Node2D]) -> void:
	var active_subject_ids := {}
	for subject in subjects:
		active_subject_ids[subject.get_instance_id()] = true
	for key_value: Variant in _subject_overlays.keys():
		var key := String(key_value)
		var separator := key.rfind(":")
		var overlay := _subject_overlays.get(key_value) as Sprite2D
		var subject_id := int(key.substr(separator + 1)) if separator >= 0 else -1
		if (
			separator < 0
			or not active_subject_ids.has(subject_id)
			or not is_instance_valid(overlay)
		):
			if is_instance_valid(overlay):
				overlay.free()
			_subject_overlays.erase(key_value)


func _active_polygon_for(
	segment: Dictionary,
	local_foot: Vector2,
) -> PackedVector2Array:
	for reveal_polygon in segment.get("reveal_polygons") as Array[PackedVector2Array]:
		if Geometry2D.is_point_in_polygon(local_foot, reveal_polygon):
			return reveal_polygon
	return PackedVector2Array()


func _alpha_for_active_foot(
	local_foot: Vector2,
	active_polygon: PackedVector2Array,
	segment: Dictionary,
) -> float:
	var boundary_distance := _distance_to_polygon_boundary(
		local_foot,
		active_polygon,
	)
	var fade_distance := maxf(float(segment.get("fade_distance_px")), 1.0)
	return lerpf(
		1.0,
		float(segment.get("minimum_alpha")),
		smoothstep(0.0, fade_distance, boundary_distance),
	)


func _distance_to_polygon_boundary(
	point: Vector2,
	polygon: PackedVector2Array,
) -> float:
	if polygon.size() < 2:
		return 0.0
	var nearest := INF
	for index in range(polygon.size()):
		var closest := Geometry2D.get_closest_point_to_segment(
			point,
			polygon[index],
			polygon[(index + 1) % polygon.size()],
		)
		nearest = minf(nearest, point.distance_to(closest))
	return nearest


func _reset_foreground(segment: Dictionary) -> void:
	var foreground := segment.get("foreground") as CanvasItem
	if is_instance_valid(foreground):
		foreground.z_index = int(
			segment.get("default_z_index", DEFAULT_FOREGROUND_Z),
		)
		foreground.modulate.a = 1.0


func _z_index_with_offset(z_index: int, offset: int) -> int:
	return clampi(
		z_index + offset,
		RenderingServer.CANVAS_ITEM_Z_MIN,
		RenderingServer.CANVAS_ITEM_Z_MAX,
	)


func _load_texture(path: String) -> Texture2D:
	if ResourceLoader.exists(path, "Texture2D"):
		var imported := ResourceLoader.load(path, "Texture2D") as Texture2D
		if imported != null:
			return imported
	if not FileAccess.file_exists(path):
		return null
	var image := Image.new()
	if image.load(ProjectSettings.globalize_path(path)) != OK:
		return null
	return ImageTexture.create_from_image(image)


func _pair(value: Variant) -> Vector2:
	var pair := value as Array
	return Vector2(float(pair[0]), float(pair[1]))


func _polygon(value: Variant) -> PackedVector2Array:
	var result := PackedVector2Array()
	for point_value: Variant in value as Array:
		var pair := point_value as Array
		result.append(Vector2(float(pair[0]), float(pair[1])))
	return result


func _offset_polygon(
	polygon: PackedVector2Array,
	offset: Vector2,
) -> PackedVector2Array:
	var result := PackedVector2Array()
	for point in polygon:
		result.append(point + offset)
	return result
