extends RefCounted

const SCHEMA_VERSION := 2
const RUNTIME_DIRECTORY := "wall_occlusion_runtime"
const MANIFEST_NAME := "wall_occlusion_runtime.json"
const MAX_CANVAS_PIXELS := 16777216


func generate(rooms_root: String, room_ids: Array[String]) -> Dictionary:
	if not _valid_resource_path(rooms_root) or room_ids.is_empty():
		return _failure("rooms root and room ids are required")
	var run_id := "%d_%d" % [Time.get_ticks_usec(), randi()]
	var staging_root := "user://interior_occlusion_staging/%s" % run_id
	if DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(staging_root),
	) != OK:
		return _failure("staging directory could not be created")
	var staged_rooms: Array[Dictionary] = []
	for room_id in room_ids:
		var staged := _stage_room(rooms_root, room_id, staging_root)
		if staged.get("ok") != true:
			_remove_staging_tree(staging_root)
			return staged
		staged_rooms.append(staged)
	var published := _publish(staged_rooms, run_id)
	_remove_staging_tree(staging_root)
	if published.get("ok") != true:
		return published
	return {
		"ok": true,
		"room_count": staged_rooms.size(),
		"segment_count": int(published.get("segment_count", 0)),
	}


func _stage_room(
	rooms_root: String,
	room_id: String,
	staging_root: String,
) -> Dictionary:
	if room_id.is_empty() or not room_id.is_valid_identifier():
		return _failure("invalid room id: %s" % room_id)
	var room_root := rooms_root.path_join(room_id)
	var geometry_path := room_root.path_join("room_geometry.json")
	var occlusion_path := room_root.path_join("wall_occlusion.json")
	var geometry := _read_json(geometry_path)
	var occlusion := _read_json(occlusion_path)
	if geometry.is_empty() or occlusion.is_empty():
		return _failure("%s geometry or occlusion JSON is missing" % room_id)
	if (
		String(geometry.get("room_id", "")) != room_id
		or String(occlusion.get("room_id", "")) != room_id
		or geometry.get("canvas_size_px") != occlusion.get("canvas_size_px")
		or String(geometry.get("source_revision", "")).strip_edges().is_empty()
		or String(occlusion.get("source_revision", "")).strip_edges().is_empty()
	):
		return _failure("%s geometry and occlusion metadata do not match" % room_id)
	var canvas := _canvas_size(geometry.get("canvas_size_px"))
	if canvas == Vector2i.ZERO or canvas.x * canvas.y > MAX_CANVAS_PIXELS:
		return _failure("%s canvas size is invalid" % room_id)
	var shell_relative_path := String(geometry.get("background_sprite", ""))
	var shell_path := room_root.path_join(shell_relative_path).simplify_path()
	var shell_image := Image.new()
	if (
		shell_relative_path.is_empty()
		or shell_image.load(ProjectSettings.globalize_path(shell_path)) != OK
	):
		return _failure("%s shell image could not be loaded" % room_id)
	shell_image.convert(Image.FORMAT_RGBA8)
	if shell_image.get_size() != canvas:
		return _failure("%s shell size does not match its geometry" % room_id)
	var segment_values: Variant = occlusion.get("segments")
	if segment_values is not Array or (segment_values as Array).is_empty():
		return _failure("%s has no occlusion segments" % room_id)
	var room_stage := staging_root.path_join(room_id)
	if DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(room_stage),
	) != OK:
		return _failure("%s staging directory could not be created" % room_id)
	var generated_segments: Array[Dictionary] = []
	var staged_assets: Array[Dictionary] = []
	var ids := {}
	for segment_value: Variant in segment_values as Array:
		if segment_value is not Dictionary:
			return _failure("%s contains an invalid segment" % room_id)
		var segment := segment_value as Dictionary
		var segment_id := String(segment.get("id", "")).strip_edges()
		if (
			segment_id.is_empty()
			or not segment_id.is_valid_identifier()
			or ids.has(segment_id)
		):
			return _failure("%s contains an invalid or duplicate segment" % room_id)
		ids[segment_id] = true
		var foreground := _polygon(
			segment.get("foreground_polygon_canvas_px"),
			canvas,
		)
		if not _valid_polygon(foreground):
			return _failure("%s segment %s polygon is invalid" % [room_id, segment_id])
		var cutouts: Array[PackedVector2Array] = []
		var cutout_values: Variant = segment.get(
			"foreground_cutout_polygons_canvas_px",
			[],
		)
		if cutout_values is not Array:
			return _failure("%s segment %s cutouts are invalid" % [room_id, segment_id])
		for cutout_value: Variant in cutout_values as Array:
			var cutout := _polygon(cutout_value, canvas)
			if not _valid_polygon(cutout):
				return _failure(
					"%s segment %s cutout is invalid" % [room_id, segment_id],
				)
			cutouts.append(cutout)
		var extracted := _extract_foreground(shell_image, foreground, cutouts)
		var image := extracted.get("image") as Image
		if image == null or image.is_empty():
			return _failure("%s segment %s could not be extracted" % [room_id, segment_id])
		var staged_texture_path := room_stage.path_join("%s.png" % segment_id)
		if image.save_png(
			ProjectSettings.globalize_path(staged_texture_path),
		) != OK:
			return _failure("%s segment %s could not be staged" % [room_id, segment_id])
		var texture_sha256 := FileAccess.get_sha256(staged_texture_path)
		if texture_sha256.length() != 64:
			return _failure("%s segment %s digest failed" % [room_id, segment_id])
		var final_texture_path := room_root.path_join(
			RUNTIME_DIRECTORY,
		).path_join("%s-%s.png" % [segment_id, texture_sha256.left(12)])
		staged_assets.append({
			"staged_path": staged_texture_path,
			"final_path": final_texture_path,
			"sha256": texture_sha256,
		})
		generated_segments.append({
			"id": segment_id,
			"foreground_texture_path": final_texture_path,
			"foreground_texture_sha256": texture_sha256,
			"foreground_canvas_origin_px": extracted.get("canvas_origin"),
			"foreground_texture_size_px": [image.get_width(), image.get_height()],
			"reveal_polygons_canvas_px": segment.get(
				"reveal_polygons_canvas_px",
				[],
			),
			"fade_distance_px": segment.get("fade_distance_px"),
			"minimum_alpha": segment.get("minimum_alpha"),
		})
	var manifest := {
		"schema_version": SCHEMA_VERSION,
		"source_occlusion_revision": String(occlusion.get("source_revision")),
		"source_occlusion_sha256": FileAccess.get_sha256(occlusion_path),
		"source_geometry_revision": String(geometry.get("source_revision")),
		"source_geometry_sha256": FileAccess.get_sha256(geometry_path),
		"source_shell_path": shell_path,
		"source_shell_sha256": FileAccess.get_sha256(shell_path),
		"room_id": room_id,
		"canvas_size_px": occlusion.get("canvas_size_px"),
		"segments": generated_segments,
	}
	var staged_manifest_path := room_stage.path_join(MANIFEST_NAME)
	if not _write_json(staged_manifest_path, manifest):
		return _failure("%s manifest could not be staged" % room_id)
	return {
		"ok": true,
		"room_id": room_id,
		"room_root": room_root,
		"staged_manifest_path": staged_manifest_path,
		"final_manifest_path": room_root.path_join(MANIFEST_NAME),
		"assets": staged_assets,
		"manifest": manifest,
	}


func _publish(staged_rooms: Array[Dictionary], run_id: String) -> Dictionary:
	var segment_count := 0
	for room in staged_rooms:
		var runtime_root := String(room.get("room_root")).path_join(
			RUNTIME_DIRECTORY,
		)
		if DirAccess.make_dir_recursive_absolute(
			ProjectSettings.globalize_path(runtime_root),
		) != OK:
			return _failure("runtime output directory could not be created")
		for asset_value: Variant in room.get("assets", []) as Array:
			var asset := asset_value as Dictionary
			var final_path := String(asset.get("final_path"))
			var expected_hash := String(asset.get("sha256"))
			if FileAccess.file_exists(final_path):
				if FileAccess.get_sha256(final_path) != expected_hash:
					return _failure("content-addressed texture digest collision")
				continue
			var temp_path := "%s.%s.tmp" % [final_path, run_id]
			if not _copy_file(String(asset.get("staged_path")), temp_path):
				return _failure("generated texture could not be published")
			if FileAccess.get_sha256(temp_path) != expected_hash:
				_remove_file(temp_path)
				return _failure("published texture digest does not match")
			if not _rename_file(temp_path, final_path):
				_remove_file(temp_path)
				return _failure("generated texture could not be committed")
		segment_count += (room.get("assets", []) as Array).size()
	# Prepare every manifest beside its final location before switching any room.
	for room in staged_rooms:
		var temp_manifest := "%s.%s.tmp" % [
			String(room.get("final_manifest_path")),
			run_id,
		]
		room["temp_manifest_path"] = temp_manifest
		if not _copy_file(String(room.get("staged_manifest_path")), temp_manifest):
			_cleanup_manifest_temps(staged_rooms)
			return _failure("generated manifest could not be prepared")
	var switched: Array[Dictionary] = []
	for room in staged_rooms:
		var final_manifest := String(room.get("final_manifest_path"))
		var temp_manifest := String(room.get("temp_manifest_path"))
		var backup_manifest := "%s.%s.backup" % [final_manifest, run_id]
		var had_previous := FileAccess.file_exists(final_manifest)
		if had_previous and not _rename_file(final_manifest, backup_manifest):
			_rollback_manifests(switched)
			_cleanup_manifest_temps(staged_rooms)
			return _failure("previous manifest could not be backed up")
		var switch_state := {
			"final": final_manifest,
			"backup": backup_manifest,
			"had_previous": had_previous,
		}
		if not _rename_file(temp_manifest, final_manifest):
			if had_previous:
				_rename_file(backup_manifest, final_manifest)
			_rollback_manifests(switched)
			_cleanup_manifest_temps(staged_rooms)
			return _failure("generated manifest could not be committed")
		switched.append(switch_state)
	for state in switched:
		if bool(state.get("had_previous")):
			_remove_file(String(state.get("backup")))
	for room in staged_rooms:
		_remove_unreferenced_resources(room)
	return {"ok": true, "segment_count": segment_count}


func _rollback_manifests(switched: Array[Dictionary]) -> void:
	for index in range(switched.size() - 1, -1, -1):
		var state := switched[index]
		var final_path := String(state.get("final"))
		_remove_file(final_path)
		if bool(state.get("had_previous")):
			_rename_file(String(state.get("backup")), final_path)


func _cleanup_manifest_temps(staged_rooms: Array[Dictionary]) -> void:
	for room in staged_rooms:
		_remove_file(String(room.get("temp_manifest_path", "")))


func _remove_unreferenced_resources(room: Dictionary) -> void:
	var referenced := {}
	for asset_value: Variant in room.get("assets", []) as Array:
		var asset := asset_value as Dictionary
		referenced[String(asset.get("final_path"))] = true
	var runtime_root := String(room.get("room_root")).path_join(RUNTIME_DIRECTORY)
	var directory := DirAccess.open(runtime_root)
	if directory == null:
		return
	directory.list_dir_begin()
	var file_name := directory.get_next()
	while not file_name.is_empty():
		if not directory.current_is_dir():
			var path := runtime_root.path_join(file_name)
			var png_path := path.trim_suffix(".import")
			if (
				(file_name.ends_with(".png") or file_name.ends_with(".png.import"))
				and not referenced.has(png_path)
			):
				_remove_file(path)
		file_name = directory.get_next()
	directory.list_dir_end()


func _extract_foreground(
	image: Image,
	polygon: PackedVector2Array,
	cutouts: Array[PackedVector2Array],
) -> Dictionary:
	var bounds := Rect2(polygon[0], Vector2.ZERO)
	for point in polygon:
		bounds = bounds.expand(point)
	var min_x := maxi(0, floori(bounds.position.x))
	var min_y := maxi(0, floori(bounds.position.y))
	var max_x := mini(image.get_width(), ceili(bounds.end.x))
	var max_y := mini(image.get_height(), ceili(bounds.end.y))
	if max_x <= min_x or max_y <= min_y:
		return {}
	var result := Image.create(
		max_x - min_x,
		max_y - min_y,
		false,
		Image.FORMAT_RGBA8,
	)
	result.fill(Color.TRANSPARENT)
	for y in range(min_y, max_y):
		for x in range(min_x, max_x):
			var pixel_center := Vector2(x + 0.5, y + 0.5)
			if not Geometry2D.is_point_in_polygon(pixel_center, polygon):
				continue
			var cut_out := false
			for cutout in cutouts:
				if Geometry2D.is_point_in_polygon(pixel_center, cutout):
					cut_out = true
					break
			if not cut_out:
				result.set_pixel(x - min_x, y - min_y, image.get_pixel(x, y))
	return {
		"image": result,
		"canvas_origin": [min_x, min_y],
	}


func _polygon(value: Variant, canvas: Vector2i) -> PackedVector2Array:
	var result := PackedVector2Array()
	if value is not Array or (value as Array).size() > 4096:
		return result
	for point_value: Variant in value as Array:
		if point_value is not Array or (point_value as Array).size() != 2:
			return PackedVector2Array()
		var pair := point_value as Array
		if not _finite_number(pair[0]) or not _finite_number(pair[1]):
			return PackedVector2Array()
		var point := Vector2(float(pair[0]), float(pair[1]))
		if point.x < 0.0 or point.y < 0.0 or point.x > canvas.x or point.y > canvas.y:
			return PackedVector2Array()
		result.append(point)
	return result


func _valid_polygon(polygon: PackedVector2Array) -> bool:
	if polygon.size() < 3:
		return false
	var seen := {}
	for index in polygon.size():
		if seen.has(polygon[index]) or polygon[index] == polygon[(index + 1) % polygon.size()]:
			return false
		seen[polygon[index]] = true
	return not Geometry2D.triangulate_polygon(polygon).is_empty()


func _canvas_size(value: Variant) -> Vector2i:
	if value is not Array or (value as Array).size() != 2:
		return Vector2i.ZERO
	var pair := value as Array
	if not _positive_integer(pair[0]) or not _positive_integer(pair[1]):
		return Vector2i.ZERO
	return Vector2i(int(pair[0]), int(pair[1]))


func _positive_integer(value: Variant) -> bool:
	return _finite_number(value) and float(value) == floorf(float(value)) and float(value) > 0.0


func _finite_number(value: Variant) -> bool:
	return (
		(typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT)
		and is_finite(float(value))
	)


func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed as Dictionary if parsed is Dictionary else {}


func _write_json(path: String, value: Dictionary) -> bool:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(JSON.stringify(value, "  ") + "\n")
	file.close()
	return true


func _copy_file(source: String, destination: String) -> bool:
	return DirAccess.copy_absolute(
		ProjectSettings.globalize_path(source),
		ProjectSettings.globalize_path(destination),
	) == OK


func _rename_file(source: String, destination: String) -> bool:
	return DirAccess.rename_absolute(
		ProjectSettings.globalize_path(source),
		ProjectSettings.globalize_path(destination),
	) == OK


func _remove_file(path: String) -> void:
	if not path.is_empty() and FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _remove_staging_tree(path: String) -> void:
	if not path.begins_with("user://interior_occlusion_staging/"):
		return
	var absolute := ProjectSettings.globalize_path(path)
	_remove_directory_contents(absolute)
	DirAccess.remove_absolute(absolute)


func _remove_directory_contents(absolute_path: String) -> void:
	var directory := DirAccess.open(absolute_path)
	if directory == null:
		return
	directory.list_dir_begin()
	var entry := directory.get_next()
	while not entry.is_empty():
		var child := absolute_path.path_join(entry)
		if directory.current_is_dir():
			_remove_directory_contents(child)
			DirAccess.remove_absolute(child)
		else:
			DirAccess.remove_absolute(child)
		entry = directory.get_next()
	directory.list_dir_end()


func _valid_resource_path(path: String) -> bool:
	return (
		(path.begins_with("res://") or path.begins_with("user://"))
		and path == path.simplify_path()
	)


func _failure(message: String) -> Dictionary:
	return {"ok": false, "error": message}
