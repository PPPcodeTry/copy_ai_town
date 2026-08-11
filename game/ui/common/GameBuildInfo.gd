extends RefCounted


const BUILD_INFO_PATH := "res://build_info.json"


static func load_release_info(path: String = BUILD_INFO_PATH) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	return parse_json_text(file.get_as_text())


static func parse_json_text(text: String) -> Dictionary:
	var json := JSON.new()
	if json.parse(text) != OK:
		return {}
	var parsed: Variant = json.data
	if not parsed is Dictionary:
		return {}
	var info := parsed as Dictionary
	if int(info.get("schemaVersion", 0)) != 1:
		return {}
	var version := String(info.get("version", "")).strip_edges()
	var tag := String(info.get("tag", "")).strip_edges()
	var channel := String(info.get("channel", "")).strip_edges()
	if version.is_empty() or tag != "v%s" % version or channel.is_empty():
		return {}
	return {
		"version": version,
		"tag": tag,
		"channel": channel,
		"commit": String(info.get("commit", "")).strip_edges(),
		"buildDate": String(info.get("buildDate", "")).strip_edges(),
	}
