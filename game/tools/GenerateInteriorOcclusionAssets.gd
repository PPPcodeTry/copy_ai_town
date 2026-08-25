extends SceneTree

const ROOMS_ROOT := "res://world/maps/town/interiors/redesign_v2/rooms"
const ROOM_IDS := [
	"cafe",
	"clinic",
	"dining_hall",
	"dock_warehouse",
	"home_template_a",
	"home_template_b",
	"library",
	"market_shop",
	"town_hall",
	"workshop",
]


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var failures: Array[String] = []
	for room_id in ROOM_IDS:
		var error := _generate_room(room_id)
		if not error.is_empty():
			failures.append(error)
	if failures.is_empty():
		print("INTERIOR_OCCLUSION_ASSETS_GENERATED: %d rooms" % ROOM_IDS.size())
		_prepare_audio_shutdown()
		call_deferred("_quit_after_cleanup", 0)
		return
	for failure in failures:
		printerr("INTERIOR_OCCLUSION_ASSET_ERROR: %s" % failure)
	_prepare_audio_shutdown()
	call_deferred("_quit_after_cleanup", 1)


func _quit_after_cleanup(exit_code: int) -> void:
	await process_frame
	await process_frame
	quit(exit_code)


func _prepare_audio_shutdown() -> void:
	var audio := root.get_node_or_null("TownAudioController")
	if audio != null and audio.has_method("prepare_shutdown"):
		audio.call("prepare_shutdown")


func _generate_room(room_id: String) -> String:
	var room_root := "%s/%s" % [ROOMS_ROOT, room_id]
	var geometry_path := room_root.path_join("room_geometry.json")
	var occlusion_path := room_root.path_join("wall_occlusion.json")
	var geometry := _read_json(geometry_path)
	var occlusion := _read_json(occlusion_path)
	if geometry.is_empty() or occlusion.is_empty():
		return "%s geometry or occlusion JSON is missing" % room_id
	if (
		String(geometry.get("room_id", "")) != String(occlusion.get("room_id", ""))
		or geometry.get("canvas_size_px") != occlusion.get("canvas_size_px")
	):
		return "%s geometry and occlusion metadata do not match" % room_id
	var shell_relative_path := String(geometry.get("background_sprite", ""))
	var shell_path := room_root.path_join(shell_relative_path).simplify_path()
	var shell_image := Image.new()
	if shell_relative_path.is_empty() or shell_image.load(
		ProjectSettings.globalize_path(shell_path),
	) != OK:
		return "%s shell image could not be loaded" % room_id
	shell_image.convert(Image.FORMAT_RGBA8)
	var canvas := geometry.get("canvas_size_px", []) as Array
	if (
		canvas.size() != 2
		or shell_image.get_size() != Vector2i(int(canvas[0]), int(canvas[1]))
	):
		return "%s shell size does not match its geometry" % room_id
	var output_root := room_root.path_join("wall_occlusion_runtime")
	var absolute_output_root := ProjectSettings.globalize_path(output_root)
	if DirAccess.make_dir_recursive_absolute(absolute_output_root) != OK:
		return "%s output directory could not be created" % room_id
	var generated_segments: Array[Dictionary] = []
	for segment_value: Variant in occlusion.get("segments", []) as Array:
		if segment_value is not Dictionary:
			return "%s contains an invalid segment" % room_id
		var segment := segment_value as Dictionary
		var segment_id := String(segment.get("id", "")).strip_edges()
		var foreground := _polygon(
			segment.get("foreground_polygon_canvas_px", []),
		)
		if segment_id.is_empty() or foreground.size() < 3:
			return "%s contains an incomplete segment" % room_id
		var cutouts: Array[PackedVector2Array] = []
		for cutout_value: Variant in segment.get(
			"foreground_cutout_polygons_canvas_px",
			[],
		) as Array:
			cutouts.append(_polygon(cutout_value))
		var extracted := _extract_foreground(shell_image, foreground, cutouts)
		var image := extracted.get("image") as Image
		if image == null or image.is_empty():
			return "%s segment %s could not be extracted" % [room_id, segment_id]
		var texture_path := output_root.path_join("%s.png" % segment_id)
		if image.save_png(ProjectSettings.globalize_path(texture_path)) != OK:
			return "%s segment %s could not be saved" % [room_id, segment_id]
		generated_segments.append({
			"id": segment_id,
			"foreground_texture_path": texture_path,
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
		"schema_version": 1,
		"source_occlusion_revision": String(occlusion.get("source_revision", "")),
		"source_occlusion_sha256": FileAccess.get_sha256(occlusion_path),
		"source_geometry_revision": String(geometry.get("source_revision", "")),
		"source_geometry_sha256": FileAccess.get_sha256(geometry_path),
		"source_shell_path": shell_path,
		"source_shell_sha256": FileAccess.get_sha256(shell_path),
		"room_id": String(occlusion.get("room_id", "")),
		"canvas_size_px": occlusion.get("canvas_size_px"),
		"segments": generated_segments,
	}
	var manifest_path := room_root.path_join("wall_occlusion_runtime.json")
	var file := FileAccess.open(manifest_path, FileAccess.WRITE)
	if file == null:
		return "%s runtime manifest could not be opened" % room_id
	file.store_string(JSON.stringify(manifest, "  ") + "\n")
	file.close()
	return ""


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


func _polygon(value: Variant) -> PackedVector2Array:
	var result := PackedVector2Array()
	if value is not Array:
		return result
	for point_value: Variant in value as Array:
		if point_value is not Array or (point_value as Array).size() != 2:
			return PackedVector2Array()
		var point := point_value as Array
		result.append(Vector2(float(point[0]), float(point[1])))
	return result


func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed as Dictionary if parsed is Dictionary else {}
