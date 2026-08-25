# 室内前景墙遮挡。前景贴图由资源工具预生成，运行时只校验并加载；
# 人物脚点、可见性或深度没有变化时，不重复执行多边形命中计算。
class_name InteriorWallOcclusion
extends Node2D

const Z_STEP := 4
const DEFAULT_FOREGROUND_Z := 999
const MAX_SEGMENTS := 256
const MAX_POLYGON_POINTS := 4096
const MAX_POLYGONS_PER_SEGMENT := 64
const MAX_TOTAL_POLYGON_POINTS := 32768
const MAX_CANVAS_COMPONENT := 65536.0
const MAX_CANVAS_PIXELS := 16777216
const MAX_JSON_BYTES := 8388608
const MAX_ID_LENGTH := 128
const MAX_REVISION_LENGTH := 256
const MANIFEST_KEYS := [
	"canvas_size_px",
	"room_id",
	"schema_version",
	"segments",
	"source_geometry_revision",
	"source_geometry_sha256",
	"source_occlusion_revision",
	"source_occlusion_sha256",
	"source_shell_path",
	"source_shell_sha256",
]
const SEGMENT_KEYS := [
	"fade_distance_px",
	"foreground_canvas_origin_px",
	"foreground_texture_path",
	"foreground_texture_size_px",
	"id",
	"minimum_alpha",
	"reveal_polygons_canvas_px",
]

var _segments: Array[Dictionary] = []
var _subject_overlays: Dictionary = {}
var _subject_states: Dictionary = {}
var _debug_root: Node2D


func configure(
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
	var geometry_path := _resource_path(geometry_path_value)
	var occlusion_path := _resource_path(occlusion_path_value)
	var shell_path := _resource_path(shell_path_value)
	if (
		shell.texture == null
		or geometry_path.is_empty()
		or occlusion_path.is_empty()
		or shell_path.is_empty()
	):
		return false
	var manifest_path := occlusion_path.get_base_dir().path_join(
		"wall_occlusion_runtime.json",
	)
	var manifest := _load_data(manifest_path)
	if manifest.is_empty():
		push_error(
			"Pre-generated interior occlusion is missing: %s" % manifest_path,
		)
		return false
	var authored_occlusion := _load_data(occlusion_path)
	if authored_occlusion.is_empty():
		push_error("Authored interior occlusion is missing: %s" % occlusion_path)
		return false
	var validated := _validate_manifest(
		manifest,
		geometry,
		authored_occlusion,
		geometry_path,
		occlusion_path,
		shell_path,
	)
	if validated.is_empty():
		push_error(
			"Pre-generated interior occlusion is stale or invalid: %s"
			% manifest_path,
		)
		return false
	var world_origin := _pair(geometry.get("world_origin_px"))
	var built := _build_render_nodes(
		validated.get("segments", []) as Array[Dictionary],
		world_origin,
	)
	var new_segments := built.get("segments", []) as Array[Dictionary]
	var new_debug_root := built.get("debug_root") as Node2D
	if new_segments.is_empty() or not is_instance_valid(new_debug_root):
		_release_build(new_segments, new_debug_root)
		return false
	_commit_build(new_segments, new_debug_root)
	return true


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
			_release_build(new_segments, new_debug_root)
			return {}
		foreground.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		foreground.z_as_relative = false
		foreground.z_index = DEFAULT_FOREGROUND_Z
		var reveal_polygons: Array[PackedVector2Array] = []
		for polygon_value: Variant in (
			segment_data.get("reveal_polygons_canvas_px") as Array
		):
			var reveal_local := _offset_polygon(
				_polygon(polygon_value, Vector2i(MAX_CANVAS_COMPONENT, MAX_CANVAS_COMPONENT)),
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
	return {"segments": new_segments, "debug_root": new_debug_root}


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


func _validate_manifest(
	data: Dictionary,
	geometry: Dictionary,
	authored_occlusion: Dictionary,
	geometry_path: String,
	occlusion_path: String,
	shell_path: String,
) -> Dictionary:
	if not _keys_equal(data, MANIFEST_KEYS) or not _exact_integer(
		data.get("schema_version"),
		1,
	):
		return {}
	var canvas_size := _canvas_size(geometry.get("canvas_size_px"))
	var room_id := _canonical_id(geometry.get("room_id"), MAX_ID_LENGTH)
	var geometry_revision := _canonical_text_limited(
		geometry.get("source_revision"),
		MAX_REVISION_LENGTH,
	)
	var occlusion_revision := _canonical_text_limited(
		authored_occlusion.get("source_revision"),
		MAX_REVISION_LENGTH,
	)
	if (
		canvas_size == Vector2i.ZERO
		or canvas_size.x * canvas_size.y > MAX_CANVAS_PIXELS
		or _canvas_size(data.get("canvas_size_px")) != canvas_size
		or _canonical_id(data.get("room_id"), MAX_ID_LENGTH) != room_id
		or _canonical_text_limited(
			data.get("source_geometry_revision"),
			MAX_REVISION_LENGTH,
		) != geometry_revision
		or occlusion_revision.is_empty()
		or _canonical_text_limited(
			data.get("source_occlusion_revision"),
			MAX_REVISION_LENGTH,
		) != occlusion_revision
		or _resource_path(data.get("source_shell_path")) != shell_path
		or not _finite_pair(geometry.get("world_origin_px"))
	):
		return {}
	if (
		not _source_matches(
			geometry_path,
			data.get("source_geometry_sha256"),
		)
		or not _source_matches(
			occlusion_path,
			data.get("source_occlusion_sha256"),
		)
		or not _source_matches(shell_path, data.get("source_shell_sha256"))
	):
		return {}
	var segment_values: Variant = data.get("segments")
	if (
		segment_values is not Array
		or (segment_values as Array).is_empty()
		or (segment_values as Array).size() > MAX_SEGMENTS
	):
		return {}
	var ids := {}
	var segments: Array[Dictionary] = []
	var polygon_points := 0
	for value: Variant in segment_values as Array:
		if value is not Dictionary:
			return {}
		var segment := value as Dictionary
		if not _keys_equal(segment, SEGMENT_KEYS):
			return {}
		var segment_id := _canonical_id(segment.get("id"), MAX_ID_LENGTH)
		var texture_path := _resource_path(
			segment.get("foreground_texture_path"),
		)
		var texture_size := _canvas_size(
			segment.get("foreground_texture_size_px"),
		)
		if (
			segment_id.is_empty()
			or ids.has(segment_id)
			or texture_path.is_empty()
			or texture_size == Vector2i.ZERO
			or not FileAccess.file_exists(texture_path)
			or not _finite_pair(segment.get("foreground_canvas_origin_px"))
			or not _texture_matches_size(texture_path, texture_size)
			or not _valid_fade(segment)
		):
			return {}
		var origin := _pair(segment.get("foreground_canvas_origin_px"))
		if (
			origin.x < 0.0
			or origin.y < 0.0
			or origin.x + texture_size.x > canvas_size.x
			or origin.y + texture_size.y > canvas_size.y
		):
			return {}
		ids[segment_id] = true
		var reveal_values: Variant = segment.get("reveal_polygons_canvas_px")
		if (
			reveal_values is not Array
			or (reveal_values as Array).is_empty()
			or (reveal_values as Array).size() > MAX_POLYGONS_PER_SEGMENT
		):
			return {}
		for polygon_value: Variant in reveal_values as Array:
			var polygon := _polygon(polygon_value, canvas_size)
			if not _valid_polygon(polygon):
				return {}
			polygon_points += polygon.size()
			if polygon_points > MAX_TOTAL_POLYGON_POINTS:
				return {}
		segments.append(segment.duplicate(true))
	return {"segments": segments}


func _valid_fade(segment: Dictionary) -> bool:
	return (
		_finite_number(segment.get("fade_distance_px"))
		and float(segment.get("fade_distance_px")) > 0.0
		and _finite_number(segment.get("minimum_alpha"))
		and float(segment.get("minimum_alpha")) >= 0.0
		and float(segment.get("minimum_alpha")) <= 1.0
	)


func _source_matches(path: String, expected_value: Variant) -> bool:
	var expected := _canonical_hash(expected_value)
	return (
		not expected.is_empty()
		and FileAccess.file_exists(path)
		and FileAccess.get_sha256(path) == expected
	)


func _texture_matches_size(path: String, expected_size: Vector2i) -> bool:
	var texture := _load_texture(path)
	return texture != null and Vector2i(texture.get_size()) == expected_size


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


func _load_data(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null or file.get_length() <= 0 or file.get_length() > MAX_JSON_BYTES:
		return {}
	var text := file.get_as_text()
	file.close()
	if text.to_utf8_buffer().size() > MAX_JSON_BYTES:
		return {}
	var parsed: Variant = JSON.parse_string(text)
	return parsed as Dictionary if parsed is Dictionary else {}


func _valid_polygon(polygon: PackedVector2Array) -> bool:
	if polygon.size() < 3 or polygon.size() > MAX_POLYGON_POINTS:
		return false
	var seen_points := {}
	for index in range(polygon.size()):
		var point := polygon[index]
		if seen_points.has(point) or point == polygon[(index + 1) % polygon.size()]:
			return false
		seen_points[point] = true
	return (
		absf(_signed_area(polygon)) > 0.0001
		and not Geometry2D.triangulate_polygon(polygon).is_empty()
	)


func _signed_area(polygon: PackedVector2Array) -> float:
	var area := 0.0
	for index in range(polygon.size()):
		var current := polygon[index]
		var next := polygon[(index + 1) % polygon.size()]
		area += current.x * next.y - next.x * current.y
	return area * 0.5


func _polygon(value: Variant, canvas_size: Vector2i) -> PackedVector2Array:
	var points := PackedVector2Array()
	if value is not Array or (value as Array).size() > MAX_POLYGON_POINTS:
		return points
	for point_value: Variant in value as Array:
		if not _finite_pair(point_value):
			return PackedVector2Array()
		var point := _pair(point_value)
		if (
			point.x < 0.0
			or point.y < 0.0
			or point.x > canvas_size.x
			or point.y > canvas_size.y
		):
			return PackedVector2Array()
		points.append(point)
	return points


func _canvas_size(value: Variant) -> Vector2i:
	if value is not Array or (value as Array).size() != 2:
		return Vector2i.ZERO
	var pair := value as Array
	if not _positive_integer(pair[0]) or not _positive_integer(pair[1]):
		return Vector2i.ZERO
	return Vector2i(int(pair[0]), int(pair[1]))


func _pair(value: Variant) -> Vector2:
	var pair := value as Array
	return Vector2(float(pair[0]), float(pair[1]))


func _finite_pair(value: Variant) -> bool:
	return (
		value is Array
		and (value as Array).size() == 2
		and _finite_number((value as Array)[0])
		and _finite_number((value as Array)[1])
	)


func _finite_number(value: Variant) -> bool:
	return (
		(typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT)
		and is_finite(float(value))
		and absf(float(value)) <= MAX_CANVAS_COMPONENT
	)


func _positive_integer(value: Variant) -> bool:
	return (
		_finite_number(value)
		and float(value) == floor(float(value))
		and float(value) > 0.0
	)


func _exact_integer(value: Variant, expected: int) -> bool:
	return (
		_finite_number(value)
		and float(value) == floor(float(value))
		and int(value) == expected
	)


func _canonical_text(value: Variant) -> String:
	if value is not String:
		return ""
	var text := value as String
	return text if not text.is_empty() and text == text.strip_edges() else ""


func _canonical_id(value: Variant, max_length: int) -> String:
	var text := _canonical_text(value)
	return (
		text
		if text.length() <= max_length and text.is_valid_identifier()
		else ""
	)


func _canonical_text_limited(value: Variant, max_length: int) -> String:
	var text := _canonical_text(value)
	return text if text.length() <= max_length else ""


func _canonical_hash(value: Variant) -> String:
	var text := _canonical_text(value)
	if text.length() != 64 or text.to_lower() != text:
		return ""
	for character in text:
		if not character in "0123456789abcdef":
			return ""
	return text


func _resource_path(value: Variant) -> String:
	var path := _canonical_text(value)
	if not path.begins_with("res://") and not path.begins_with("user://"):
		return ""
	return path if path.simplify_path() == path else ""


func _keys_equal(value: Dictionary, expected: Array) -> bool:
	var actual: Array = value.keys()
	actual.sort()
	var sorted_expected := expected.duplicate()
	sorted_expected.sort()
	return actual == sorted_expected


func _offset_polygon(
	polygon: PackedVector2Array,
	offset: Vector2,
) -> PackedVector2Array:
	var result := PackedVector2Array()
	for point in polygon:
		result.append(point + offset)
	return result
