extends SceneTree

const WALL_OCCLUSION := preload(
	"res://world/maps/town/interiors/InteriorWallOcclusion.gd"
)
const WALL_Z_STEP := 4
const ROOMS := [
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
const ROOM_BASE := "res://world/maps/town/interiors/redesign_v2/rooms"

var _failures: Array[String] = []
var _checks := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_formal_generated_assets()
	for room_id in ["cafe", "clinic", "home_template_b"]:
		_test_multi_subject_state_refresh(room_id)
	await process_frame
	await process_frame
	_finish()


func _test_formal_generated_assets() -> void:
	var configured_rooms := 0
	for room_id in ROOMS:
		var base := "%s/%s" % [ROOM_BASE, room_id]
		var geometry_path := base.path_join("room_geometry.json")
		var occlusion_path := base.path_join("wall_occlusion.json")
		var manifest_path := base.path_join("wall_occlusion_runtime.json")
		var geometry := _read_json(geometry_path)
		var authored := _read_json(occlusion_path)
		var manifest := _read_json(manifest_path)
		_expect(not geometry.is_empty(), "%s has room geometry" % room_id)
		_expect(not authored.is_empty(), "%s has authored occlusion" % room_id)
		_expect(not manifest.is_empty(), "%s has generated occlusion" % room_id)
		if geometry.is_empty() or authored.is_empty() or manifest.is_empty():
			continue
		_expect_equal(
			manifest.get("schema_version"),
			2,
			"%s uses the digest-bearing generated manifest schema" % room_id,
		)
		_expect_equal(
			manifest.get("room_id"),
			geometry.get("room_id"),
			"%s generated occlusion keeps the room identity" % room_id,
		)
		_expect_equal(
			manifest.get("canvas_size_px"),
			geometry.get("canvas_size_px"),
			"%s generated occlusion keeps the room canvas" % room_id,
		)
		_expect_equal(
			manifest.get("source_geometry_revision"),
			geometry.get("source_revision"),
			"%s generated occlusion keeps the geometry revision" % room_id,
		)
		_expect_equal(
			manifest.get("source_occlusion_revision"),
			authored.get("source_revision"),
			"%s generated occlusion keeps the authored revision" % room_id,
		)
		_expect_equal(
			manifest.get("source_geometry_sha256"),
			FileAccess.get_sha256(geometry_path),
			"%s generated occlusion matches the geometry digest" % room_id,
		)
		_expect_equal(
			manifest.get("source_occlusion_sha256"),
			FileAccess.get_sha256(occlusion_path),
			"%s generated occlusion matches the authored digest" % room_id,
		)
		var shell_path := String(manifest.get("source_shell_path", ""))
		_expect_equal(
			manifest.get("source_shell_sha256"),
			FileAccess.get_sha256(shell_path),
			"%s generated occlusion matches the shell digest" % room_id,
		)
		var generated_segments := manifest.get("segments", []) as Array
		var authored_segments := authored.get("segments", []) as Array
		_expect_equal(
			generated_segments.size(),
			authored_segments.size(),
			"%s pre-generates every authored segment" % room_id,
		)
		for segment_value: Variant in generated_segments:
			var segment := segment_value as Dictionary
			var texture_path := String(
				segment.get("foreground_texture_path", ""),
			)
			_expect(
				FileAccess.file_exists(texture_path),
				"%s generated segment %s has a texture"
				% [room_id, segment.get("id")],
			)
			_expect_equal(
				segment.get("foreground_texture_sha256"),
				FileAccess.get_sha256(texture_path),
				"%s generated segment %s keeps the texture digest"
				% [room_id, segment.get("id")],
			)
		var shell := Sprite2D.new()
		shell.texture = ResourceLoader.load(shell_path, "Texture2D") as Texture2D
		_expect(shell.texture != null, "%s shell texture loads" % room_id)
		if shell.texture == null:
			shell.free()
			continue
		var source_texture := shell.texture
		root.add_child(shell)
		var occlusion := WALL_OCCLUSION.new()
		root.add_child(occlusion)
		_expect(
			bool(occlusion.configure(
				shell,
				geometry,
				geometry_path,
				occlusion_path,
				shell_path,
			)),
			"%s loads pre-generated wall occlusion" % room_id,
		)
		_expect(
			shell.texture == source_texture,
			"%s runtime does not duplicate or rewrite the full shell image" % room_id,
		)
		_expect(
			not occlusion.is_processing(),
			"%s wall occlusion does not run its own scene-tree scan" % room_id,
		)
		_expect_equal(
			occlusion.get_child_count(),
			generated_segments.size() + 1,
			"%s creates one sprite per generated segment and one debug root"
			% room_id,
		)
		for segment_value: Variant in generated_segments:
			var segment := segment_value as Dictionary
			_expect(
				occlusion.get_node_or_null(String(segment.get("id"))) != null,
				"%s exposes generated segment %s" % [room_id, segment.get("id")],
			)
		var first_segment := generated_segments[0] as Dictionary
		var first_reveal := (
			first_segment.get("reveal_polygons_canvas_px") as Array
		)[0] as Array
		var subject := Node2D.new()
		subject.z_index = 100
		subject.position = _inside_polygon_point(first_reveal) - _pair(
			geometry.get("world_origin_px"),
		)
		root.add_child(subject)
		_expect(
			bool(occlusion.update_for_subject(subject)),
			"%s refreshes when a subject moves behind its foreground wall" % room_id,
		)
		var foreground := occlusion.get_node_or_null(
			String(first_segment.get("id")),
		) as Sprite2D
		_expect_equal(
			foreground.z_index if foreground != null else -1,
			100 - WALL_Z_STEP,
			"%s keeps the full wall behind the subject" % room_id,
		)
		var active_overlays := _visible_subject_overlays(occlusion)
		_expect(
			not active_overlays.is_empty()
			and active_overlays[0].z_index == 100 + WALL_Z_STEP,
			"%s raises the local wall slice in front of the subject" % room_id,
		)
		subject.position = Vector2(-100000.0, -100000.0)
		_expect(
			bool(occlusion.update_for_subject(subject)),
			"%s refreshes when the subject leaves the reveal area" % room_id,
		)
		_expect_equal(
			_visible_subject_overlays(occlusion).size(),
			0,
			"%s removes the front wall slice outside the reveal area" % room_id,
		)
		subject.free()
		occlusion.update_for_subjects([])
		occlusion.free()
		shell.free()
		configured_rooms += 1
	_expect_equal(
		configured_rooms,
		ROOMS.size(),
		"every formal room loads its generated wall assets",
	)


func _test_multi_subject_state_refresh(room_id: String) -> void:
	var base := ROOM_BASE.path_join(room_id)
	var geometry_path := base.path_join("room_geometry.json")
	var occlusion_path := base.path_join("wall_occlusion.json")
	var manifest := _read_json(base.path_join("wall_occlusion_runtime.json"))
	var geometry := _read_json(geometry_path)
	var shell_path := String(manifest.get("source_shell_path", ""))
	var shell := Sprite2D.new()
	shell.texture = ResourceLoader.load(shell_path, "Texture2D") as Texture2D
	root.add_child(shell)
	var occlusion := WALL_OCCLUSION.new()
	root.add_child(occlusion)
	_expect(
		bool(occlusion.configure(
			shell,
			geometry,
			geometry_path,
			occlusion_path,
			shell_path,
		)),
		"%s multi-subject regression loads the wall" % room_id,
	)
	var first_segment := (manifest.get("segments") as Array)[0] as Dictionary
	var first_reveal := (
		first_segment.get("reveal_polygons_canvas_px") as Array
	)[0] as Array
	var foot := _inside_polygon_point(first_reveal) - _pair(
		geometry.get("world_origin_px"),
	)
	var first_subject := Node2D.new()
	first_subject.z_index = 10
	first_subject.position = foot
	root.add_child(first_subject)
	var second_subject := Node2D.new()
	second_subject.z_index = 20
	second_subject.position = foot + Vector2.ONE
	root.add_child(second_subject)
	_expect(
		bool(occlusion.update_for_subjects([first_subject, second_subject])),
		"%s first two-person state refreshes wall occlusion" % room_id,
	)
	var foreground := occlusion.get_node_or_null(
		String(first_segment.get("id")),
	) as Sprite2D
	_expect_equal(
		foreground.z_index if foreground != null else -1,
		10 - WALL_Z_STEP,
		"the shared wall stays behind both subjects",
	)
	_expect(
		_visible_subject_overlays(occlusion).size() >= 2,
		"two people in one room receive independent foreground slices",
	)
	var stable_overlay_count := _visible_subject_overlays(occlusion).size()
	_expect(
		not bool(occlusion.update_for_subjects([first_subject, second_subject])),
		"an unchanged two-person state skips refresh",
	)
	_expect_equal(
		_visible_subject_overlays(occlusion).size(),
		stable_overlay_count,
		"an unchanged frame preserves the existing foreground slices",
	)
	second_subject.position += Vector2.ONE
	_expect(
		bool(occlusion.update_for_subjects([first_subject, second_subject])),
		"moving one subject refreshes wall occlusion once",
	)
	first_subject.visible = false
	_expect(
		bool(occlusion.update_for_subjects([first_subject, second_subject])),
		"hiding one subject refreshes wall occlusion once",
	)
	stable_overlay_count = _visible_subject_overlays(occlusion).size()
	_expect(
		not bool(occlusion.update_for_subjects([first_subject, second_subject])),
		"a stable one-person state also skips refresh",
	)
	_expect_equal(
		_visible_subject_overlays(occlusion).size(),
		stable_overlay_count,
		"stable visibility preserves the existing foreground slice",
	)
	first_subject.free()
	second_subject.free()
	_expect(
		bool(occlusion.update_for_subjects([])),
		"removing every subject refreshes the wall once",
	)
	_expect_equal(
		_visible_subject_overlays(occlusion).size(),
		0,
		"removing every subject hides cached foreground slices",
	)
	occlusion.free()
	shell.free()


func _polygon_average(value: Array) -> Vector2:
	var total := Vector2.ZERO
	for point_value: Variant in value:
		total += _pair(point_value)
	return total / float(value.size())


func _inside_polygon_point(value: Array) -> Vector2:
	var polygon := PackedVector2Array()
	for point_value: Variant in value:
		polygon.append(_pair(point_value))
	var indices := Geometry2D.triangulate_polygon(polygon)
	if indices.size() >= 3:
		return (
			polygon[indices[0]]
			+ polygon[indices[1]]
			+ polygon[indices[2]]
		) / 3.0
	return _polygon_average(value)


func _pair(value: Variant) -> Vector2:
	var pair := value as Array
	return Vector2(float(pair[0]), float(pair[1]))


func _visible_subject_overlays(occlusion: Node2D) -> Array[Sprite2D]:
	var result: Array[Sprite2D] = []
	for child in occlusion.get_children():
		if child is Sprite2D and child.has_meta("subject_overlay") and child.visible:
			result.append(child as Sprite2D)
	return result


func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed as Dictionary if parsed is Dictionary else {}


func _expect(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures.append(message)


func _expect_equal(actual: Variant, expected: Variant, message: String) -> void:
	_expect(
		actual == expected,
		"%s: expected %s, got %s" % [message, expected, actual],
	)


func _finish() -> void:
	_prepare_audio_shutdown()
	if _failures.is_empty():
		print(
			"TOWN_INTERIOR_WALL_OCCLUSION_PASS checks=%d rooms=%d"
			% [_checks, ROOMS.size()]
		)
		call_deferred("_quit_after_cleanup", 0)
		return
	for failure in _failures:
		printerr("TOWN_INTERIOR_WALL_OCCLUSION_FAIL: %s" % failure)
	call_deferred("_quit_after_cleanup", 1)


func _quit_after_cleanup(exit_code: int) -> void:
	await process_frame
	await process_frame
	await create_timer(0.2).timeout
	quit(exit_code)


func _prepare_audio_shutdown() -> void:
	var audio := root.get_node_or_null("TownAudioController")
	if audio != null and audio.has_method("prepare_shutdown"):
		audio.call("prepare_shutdown")
