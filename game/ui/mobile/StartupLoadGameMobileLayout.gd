class_name StartupLoadGameMobileLayout
extends RefCounted


const MINIMUM_TOUCH_TARGET := 48.0
const ACTION_GAP := 8.0
const ACTION_GROUP_HEIGHT := MINIMUM_TOUCH_TARGET * 2.0 + ACTION_GAP
const LANDSCAPE_ROW_HEIGHT := 108.0
const LANDSCAPE_ROW_GAP := 8.0
const PORTRAIT_CARD_HEIGHT := 216.0
const PORTRAIT_CARD_GAP := 10.0


static func slot_rects(
	canvas_size: Vector2,
	display_size: Vector2,
	row_index: int,
	row_count: int,
) -> Dictionary:
	if (
		canvas_size.x <= 0.0
		or canvas_size.y <= 0.0
		or display_size.x <= 0.0
		or display_size.y <= 0.0
		or row_index < 0
		or row_count <= 0
		or row_index >= row_count
	):
		return {}

	var display_rects: Dictionary = {}
	var margin := 16.0
	if display_size.x >= display_size.y:
		# Keep the slot copy and its three actions in one row. This is important
		# on narrow landscape screens: moving only the buttons lets them cover
		# the text column while still looking like a valid layout to the engine.
		var action_zone_width := clampf(display_size.x * 0.32, 280.0, 330.0)
		var action_left := floorf(display_size.x - margin - action_zone_width)
		var text_left := margin + 12.0
		var text_right := action_left - 16.0
		var text_width := maxf(120.0, text_right - text_left)
		var area_top := maxf(138.0, display_size.y * 0.26)
		var area_bottom := display_size.y - maxf(28.0, display_size.y * 0.10)
		var row_step := LANDSCAPE_ROW_HEIGHT + LANDSCAPE_ROW_GAP
		if row_count > 1:
			row_step = maxf(
				LANDSCAPE_ROW_HEIGHT,
				minf(
					LANDSCAPE_ROW_HEIGHT + LANDSCAPE_ROW_GAP,
					(area_bottom - area_top - LANDSCAPE_ROW_HEIGHT)
					/ float(row_count - 1),
				),
			)
		var top := roundf(area_top + float(row_index) * row_step)
		var primary_width := clampf(
			action_zone_width * 0.49,
			132.0,
			160.0,
		)
		var secondary_width := maxf(
			MINIMUM_TOUCH_TARGET,
			action_zone_width - primary_width - ACTION_GAP,
		)
		var secondary_left := action_left + primary_width + ACTION_GAP
		display_rects = {
			"accent": Rect2(0.0, top + 4.0, 8.0, LANDSCAPE_ROW_HEIGHT - 8.0),
			"title": Rect2(text_left, top, text_width, 30.0),
			"body": Rect2(text_left, top + 27.0, text_width, 25.0),
			"recovery": Rect2(text_left, top + 53.0, text_width, 25.0),
			"detail": Rect2(text_left, top + 79.0, text_width, 25.0),
			"primary": Rect2(
				action_left,
				top + 2.0,
				primary_width,
				ACTION_GROUP_HEIGHT,
			),
			"delete": Rect2(
				secondary_left,
				top + 2.0,
				secondary_width,
				MINIMUM_TOUCH_TARGET,
			),
			"edit": Rect2(
				secondary_left,
				top + 2.0 + MINIMUM_TOUCH_TARGET + ACTION_GAP,
				secondary_width,
				MINIMUM_TOUCH_TARGET,
			),
		}
	else:
		# Portrait has enough height for a compact card. Put the four text lines
		# above the action row so the model-edit action remains a full-sized,
		# independent target instead of being squeezed beside long copy.
		var content_left := margin
		var content_width := maxf(160.0, display_size.x - margin * 2.0)
		var area_top := maxf(270.0, display_size.y * 0.28)
		var top := roundf(area_top + float(row_index) * (
			PORTRAIT_CARD_HEIGHT + PORTRAIT_CARD_GAP
		))
		var primary_width := clampf(content_width * 0.44, 180.0, 220.0)
		var secondary_width := maxf(
			MINIMUM_TOUCH_TARGET,
			content_width - primary_width - ACTION_GAP,
		)
		var secondary_left := content_left + primary_width + ACTION_GAP
		display_rects = {
			"accent": Rect2(0.0, top + 4.0, 8.0, PORTRAIT_CARD_HEIGHT - 8.0),
			"title": Rect2(content_left + 10.0, top, content_width - 10.0, 30.0),
			"body": Rect2(content_left + 10.0, top + 29.0, content_width - 10.0, 25.0),
			"recovery": Rect2(content_left + 10.0, top + 55.0, content_width - 10.0, 25.0),
			"detail": Rect2(content_left + 10.0, top + 81.0, content_width - 10.0, 25.0),
			"primary": Rect2(
				content_left,
				top + 109.0,
				primary_width,
				ACTION_GROUP_HEIGHT,
			),
			"delete": Rect2(
				secondary_left,
				top + 109.0,
				secondary_width,
				MINIMUM_TOUCH_TARGET,
			),
			"edit": Rect2(
				secondary_left,
				top + 109.0 + MINIMUM_TOUCH_TARGET + ACTION_GAP,
				secondary_width,
				MINIMUM_TOUCH_TARGET,
			),
		}

	var to_canvas := canvas_size / display_size
	var result: Dictionary = {}
	for role: String in display_rects:
		var rect := display_rects[role] as Rect2
		result[role] = Rect2(
			rect.position * to_canvas,
			rect.size * to_canvas,
		)
	return result


static func action_rects(
	canvas_size: Vector2,
	display_size: Vector2,
	row_index: int,
	row_count: int,
) -> Dictionary:
	var layout := slot_rects(canvas_size, display_size, row_index, row_count)
	var result: Dictionary = {}
	for role: String in ["primary", "delete", "edit"]:
		if layout.has(role):
			result[role] = layout[role]
	return result
