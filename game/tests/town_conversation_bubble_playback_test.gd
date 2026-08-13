extends SceneTree


const PLAYBACK := preload(
	"res://world/presentation/ui/TownConversationBubblePlayback.gd"
)
const SEGMENTER := preload(
	"res://ui/conversation_unified/ConversationSemanticSegmenter.gd"
)
const BUBBLE_FONT := preload(
	"res://assets/fonts/zheng_ge_dian_hei_16/ZhengGeDianHei-16.ttf"
)

var _failures: Array[String] = []
var _checks := 0


func _initialize() -> void:
	call_deferred("_run_all")


func _run_all() -> void:
	_test_sentence_playback_and_model_gap()
	_test_end_waits_for_last_bubble()
	_test_pause_resume_keeps_progress()
	_test_short_sentences_share_a_bubble()
	_test_long_speech_uses_balanced_natural_breaks()
	_test_display_width_and_closing_mark_edges()
	_test_chat_segments_rebalance_short_tails()
	_finish_suite("TOWN_CONVERSATION_BUBBLE_PLAYBACK_PASS")


func _test_sentence_playback_and_model_gap() -> void:
	var playback := PLAYBACK.new()
	var first_state := _conversation(
		"conversation-bubble-1",
		"active",
		[{
			"turn_id": 1,
			"speaker": "林岚",
			"speaker_resident_id": "resident-lin",
			"say": "先去看看花圃。",
		}],
	)
	playback.ingest(first_state, 1000)
	var visible := playback.visible_items(1000)
	_expect_equal(visible.size(), 1, "有已确认发言时生成一个气泡")
	_expect_equal(
		(visible[0] as Dictionary).get("bubbleText"),
		"先去看看花圃。",
		"气泡显示真实发言而不是旁观标签",
	)
	playback.advance(2199)
	_expect_equal(playback.visible_items(2199).size(), 1, "单句气泡停留满 1.2 秒")
	playback.advance(2200)
	_expect_equal(
		playback.visible_items(2200).size(),
		0,
		"模型还没给下一句时不显示连续省略号",
	)

	var reply_state := first_state.duplicate(true)
	(reply_state.get("turns", []) as Array).append({
		"turn_id": 2,
		"speaker": "唐小满",
		"speaker_resident_id": "resident-tang",
		"say": "好呀，我们一起去。",
	})
	playback.ingest(reply_state, 2300)
	visible = playback.visible_items(2300)
	_expect_equal(visible.size(), 1, "模型回复到达后恢复显示下一句")
	_expect_equal(
		(visible[0] as Dictionary).get("bubbleText"),
		"好呀，我们一起去。",
		"下一句只在真实回复到达后贴出",
	)


func _test_end_waits_for_last_bubble() -> void:
	var playback := PLAYBACK.new()
	var state := _conversation(
		"conversation-bubble-2",
		"active",
		[{
			"turn_id": 1,
			"speaker": "林岚",
			"speaker_resident_id": "resident-lin",
			"say": "这句播完，对话就结束。",
		}],
	)
	playback.ingest(state, 3000)
	var ended := state.duplicate(true)
	ended["status"] = "ended"
	playback.ingest(ended, 3500)
	_expect_equal(playback.visible_items(4199).size(), 1, "世界结束后最后一句仍然可见")
	_expect_equal(playback.visible_items(4200).size(), 0, "最后一句播完才清掉气泡")


func _test_pause_resume_keeps_progress() -> void:
	var playback := PLAYBACK.new()
	playback.ingest(
		_conversation(
			"conversation-bubble-3",
			"active",
			[{
				"turn_id": 1,
				"speaker": "林岚",
				"speaker_resident_id": "resident-lin",
				"say": "暂停后继续播放。",
			}],
		),
		5000,
	)
	playback.set_paused(true, 5500)
	playback.advance(8000)
	_expect_equal(playback.visible_items(8000).size(), 1, "暂停期间不推进气泡")
	playback.set_paused(false, 8000)
	_expect_equal(playback.visible_items(8699).size(), 1, "退出暂停后恢复剩余展示时间")
	_expect_equal(playback.visible_items(8700).size(), 0, "恢复后仍按 1.2 秒结束")


func _test_short_sentences_share_a_bubble() -> void:
	var playback := PLAYBACK.new()
	playback.ingest(
		_conversation(
			"conversation-short-sentences",
			"active",
			[{
				"turn_id": 1,
				"speaker": "林岚",
				"speaker_resident_id": "resident-lin",
				"say": "好。走吧。去花圃看看。",
			}],
		),
		1000,
	)
	var snapshot := playback.debug_snapshot("conversation-short-sentences")
	var segments := snapshot.get("segments", []) as Array
	_expect_equal(segments.size(), 1, "连续短句合并到同一个头顶气泡")
	_expect_equal(
		(segments[0] as Dictionary).get("text"),
		"好。走吧。去花圃看看。",
		"短句合并后保留完整原文和标点",
	)


func _test_long_speech_uses_balanced_natural_breaks() -> void:
	var playback := PLAYBACK.new()
	var no_punctuation := "一二三四五六七八九十一二三四五六七八九"
	playback.ingest(
		_conversation(
			"conversation-balanced-long",
			"active",
			[{
				"turn_id": 1,
				"speaker": "林岚",
				"speaker_resident_id": "resident-lin",
				"say": no_punctuation,
			}],
		),
		1000,
	)
	var snapshot := playback.debug_snapshot("conversation-balanced-long")
	var segments := snapshot.get("segments", []) as Array
	_expect_equal(segments.size(), 2, "十九字无标点发言均衡拆成两个气泡")
	var first := String((segments[0] as Dictionary).get("text", ""))
	var second := String((segments[1] as Dictionary).get("text", ""))
	_expect(abs(first.length() - second.length()) <= 1, "无标点长句两段长度均衡")
	_expect(first.length() > 1 and second.length() > 1, "无标点长句不产生单字尾泡")
	_expect(_display_units(first) <= 18.0, "无标点长句第一页不超过气泡显示宽度")
	_expect(_display_units(second) <= 18.0, "无标点长句第二页不超过气泡显示宽度")
	_expect_equal(first + second, no_punctuation, "均衡拆分不丢失原文")

	var punctuation := "先检查花盆和工具，再看看天气变化，最后安排下午的工作。"
	playback = PLAYBACK.new()
	playback.ingest(
		_conversation(
			"conversation-natural-break",
			"active",
			[{
				"turn_id": 1,
				"speaker": "林岚",
				"speaker_resident_id": "resident-lin",
				"say": punctuation,
			}],
		),
		1000,
	)
	segments = (
		playback.debug_snapshot("conversation-natural-break")
		.get("segments", []) as Array
	)
	_expect(segments.size() >= 2, "超长有标点发言会拆成多个气泡")
	_expect(
		String((segments[0] as Dictionary).get("text", "")).ends_with("，"),
		"超长发言优先在自然标点处分段",
	)
	var restored := ""
	for segment: Dictionary in segments:
		restored += String(segment.get("text", ""))
	_expect_equal(restored, punctuation, "自然断句保留完整原文")
	var punctuation_near_tail := "一二三四五六七八九十一二三四五六，尾巴"
	playback = PLAYBACK.new()
	playback.ingest(
		_conversation(
			"conversation-punctuation-tail",
			"active",
			[{"turn_id": 1, "say": punctuation_near_tail}],
		),
		1000,
	)
	segments = (
		playback.debug_snapshot("conversation-punctuation-tail").get(
			"segments",
			[],
		) as Array
	)
	_expect(
		String((segments[-1] as Dictionary).get("text", "")).length() > 1,
		"靠近句尾的标点不会制造单字或过短尾泡",
	)


func _test_display_width_and_closing_mark_edges() -> void:
	var playback := PLAYBACK.new()
	var ascii_boundary := "abcdefghijklmnopqrstuvwxyz1234567890"
	playback.ingest(
		_conversation(
			"conversation-ascii-width",
			"active",
			[{"turn_id": 1, "say": ascii_boundary}],
		),
		1000,
	)
	_expect_equal(
		(playback.debug_snapshot("conversation-ascii-width").get(
			"segments",
			[],
		) as Array).size(),
		1,
		"三十六个拉丁字符按十八个汉字宽度放在一个气泡",
	)
	var wide_ascii := "WWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWW"
	playback = PLAYBACK.new()
	playback.ingest(
		_conversation(
			"conversation-wide-ascii-width",
			"active",
			[{"turn_id": 1, "say": wide_ascii}],
		),
		1000,
	)
	var wide_ascii_segments := (
		playback.debug_snapshot("conversation-wide-ascii-width").get(
			"segments",
			[],
		) as Array
	)
	_expect_equal(wide_ascii_segments.size(), 1, "等宽像素字体中的英文按实际宽度完整显示")
	var restored_wide_ascii := ""
	for segment: Dictionary in wide_ascii_segments:
		var segment_text := String(segment.get("text", ""))
		restored_wide_ascii += segment_text
		_expect(_display_units(segment_text) <= 18.0, "英文气泡不会文字出框")
	_expect_equal(restored_wide_ascii, wide_ascii, "宽字母气泡拆分保留完整原文")
	var mixed_boundary := "abcdefghijklmnopqrstuvwx中文测试额外"
	playback = PLAYBACK.new()
	playback.ingest(
		_conversation(
			"conversation-mixed-width",
			"active",
			[{"turn_id": 1, "say": mixed_boundary}],
		),
		1000,
	)
	_expect_equal(
		(playback.debug_snapshot("conversation-mixed-width").get(
			"segments",
			[],
		) as Array).size(),
		1,
		"中英混排按显示宽度而不是字符数切分",
	)

	var quoted := "今天先检查花盆，再整理工具，确认完毕！”然后我们一起出发去花园。"
	playback = PLAYBACK.new()
	playback.ingest(
		_conversation(
			"conversation-closing-mark",
			"active",
			[{"turn_id": 1, "say": quoted}],
		),
		1000,
	)
	var quoted_segments := (
		playback.debug_snapshot("conversation-closing-mark").get(
			"segments",
			[],
		) as Array
	)
	_expect(quoted_segments.size() >= 2, "带引号的长发言会按容量拆分")
	var found_closed_sentence := false
	var restored := ""
	for segment: Dictionary in quoted_segments:
		var text := String(segment.get("text", ""))
		found_closed_sentence = found_closed_sentence or text.ends_with("！”")
		restored += text
	_expect(found_closed_sentence, "句末引号与感叹号保留在同一个气泡")
	_expect_equal(restored, quoted, "带引号长发言分页保留完整原文")


func _test_chat_segments_rebalance_short_tails() -> void:
	var oversized := "一二三四五六七八九十".repeat(10)
	var pieces: Array[String] = SEGMENTER.segment(oversized, 72, 96)
	_expect_equal(pieces.size(), 2, "聊天页超长无标点消息均衡分成两个气泡")
	_expect(abs(pieces[0].length() - pieces[1].length()) <= 1, "聊天页长消息不产生九十六加四的短尾")
	_expect(pieces[0].length() >= 18 and pieces[1].length() >= 18, "聊天页不产生单字或过短尾泡")
	_expect_equal("".join(pieces), oversized, "聊天页分段保留完整原文")

	var manual_break := "这段文字本来足够长，需要和下一行一起重新均衡分配，避免换行后只剩下" + "一"
	manual_break = manual_break.insert(manual_break.length() - 1, "\n")
	pieces = SEGMENTER.segment(manual_break, 24, 32)
	for piece: String in pieces:
		_expect(piece.length() > 1, "聊天页短换行片段会与相邻内容重新分配")
	_expect_equal("".join(pieces), manual_break.replace("\n", ""), "短换行重分配不丢失原文")


func _conversation(
	conversation_id: String,
	status: String,
	turns: Array,
) -> Dictionary:
	return {
		"conversationId": conversation_id,
		"participants": ["resident-lin", "resident-tang"],
		"status": status,
		"turns": turns,
	}


func _expect(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures.append(message)


func _expect_equal(actual: Variant, expected: Variant, message: String) -> void:
	_checks += 1
	if actual != expected:
		_failures.append(
			"%s: expected %s, got %s" % [message, str(expected), str(actual)]
		)


func _finish_suite(pass_label: String) -> void:
	var exit_code := 0 if _failures.is_empty() else 1
	if _failures.is_empty():
		print("%s checks=%d" % [pass_label, _checks])
	else:
		for failure: String in _failures:
			printerr("%s_FAIL: %s" % [pass_label, failure])
	for _index: int in 5:
		await process_frame
	var audio_controller := root.get_node_or_null("TownAudioController")
	if audio_controller != null and audio_controller.has_method("prepare_shutdown"):
		audio_controller.call("prepare_shutdown")
	await create_timer(0.3, true, false, true).timeout
	quit(exit_code)


func _display_units(value: String) -> float:
	var units := 0.0
	for index: int in value.length():
		units += maxf(
			0.5,
			BUBBLE_FONT.get_string_size(
				value.substr(index, 1),
				HORIZONTAL_ALIGNMENT_LEFT,
				-1.0,
				20,
			).x / 20.0,
		)
	return units
