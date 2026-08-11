class_name GameBuildInfoOverlay
extends CanvasLayer


const BUILD_INFO := preload("res://ui/common/GameBuildInfo.gd")


var _label: Label


static func load_release_info() -> Dictionary:
	return BUILD_INFO.load_release_info()


func _ready() -> void:
	layer = 250
	_build_interface()
	apply_release_info(load_release_info())


func apply_release_info(release_info: Dictionary) -> void:
	var version := String(release_info.get("version", "")).strip_edges()
	var tag := String(release_info.get("tag", "")).strip_edges()
	var channel := String(release_info.get("channel", "")).strip_edges().to_lower()
	if version.is_empty() or tag != "v%s" % version or channel.is_empty():
		visible = false
		_label.text = ""
		return
	_label.text = _display_text(tag, channel)
	visible = true


func _build_interface() -> void:
	var root := Control.new()
	root.name = "GameBuildInfoRoot"
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	_label = Label.new()
	_label.name = "GameBuildInfoLabel"
	_label.anchor_left = 1.0
	_label.anchor_top = 1.0
	_label.anchor_right = 1.0
	_label.anchor_bottom = 1.0
	_label.offset_left = -720.0
	_label.offset_top = -54.0
	_label.offset_right = -24.0
	_label.offset_bottom = -18.0
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label.add_theme_font_size_override("font_size", 18)
	_label.add_theme_color_override(
		"font_color",
		Color(1.0, 1.0, 1.0, 0.92),
	)
	_label.add_theme_color_override(
		"font_outline_color",
		Color(0.0, 0.0, 0.0, 0.82),
	)
	_label.add_theme_constant_override("outline_size", 6)
	root.add_child(_label)


func _display_text(tag: String, channel: String) -> String:
	match channel:
		"alpha", "beta":
			return "当前为测试版本，不代表最终品质 · %s" % tag
		"rc":
			return "当前为候选版本，请以正式版为准 · %s" % tag
		_:
			return tag
