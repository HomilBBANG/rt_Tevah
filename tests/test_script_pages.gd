extends Node
## 대본 페이지 (core/script_pages.gd) + 대화 화면의 글자 출력 테스트. 실행:
##   Godot_v4.7-stable_win64_console.exe --headless --path . res://tests/test_script_pages.tscn
## 확인: 예전 노드 = 페이지 1개, {w=} 대기 자리, 속도, 문제 찾기, 그리고 실제 대화 화면에서
##   출력 중 입력 1번 = 전체 표시 / 다음 입력 = 다음 페이지, 대기, 자동 넘김, 즉시, 시작 페이지.

const ScriptPages = preload("res://core/script_pages.gd")
const DialogueScene = preload("res://scenes/main_play.tscn")

var _fail := 0


func _ready() -> void:
	# ---- 도우미
	var legacy := ScriptPages.pages_of({"speaker_id": "char_cat", "text": "야옹"})
	check(legacy.size() == 1 and legacy[0].display == "bubble" and legacy[0].text == "야옹" and ScriptPages.is_plain(legacy[0]),
		"예전 노드(화자 있음) → 말풍선 페이지 1개, 기본값만")
	var narr := ScriptPages.pages_of({"speaker_id": "", "text": "방이 조용하다"})
	check(narr[0].display == "narration" and ScriptPages.is_plain(narr[0]), "예전 노드(화자 없음) → 상황 묘사 1개")
	var parsed := ScriptPages.parse_text("가나{w=0.5}다\n\n라{w=1}")
	check(parsed.text == "가나다\n\n라" and parsed.pauses == [[2, 0.5], [6, 1.0]], "{w=} 빼고 대기 자리 [2, 0.5] [6, 1.0]: %s" % [parsed.pauses])
	var cfg := {"text_speed_default": "slow", "text_speed_fast": 80}
	check(ScriptPages.cps("", cfg) == 15.0 and ScriptPages.cps("fast", cfg) == 80.0 and ScriptPages.cps("instant", cfg) == 0.0
		and ScriptPages.cps("12", cfg) == 12.0 and ScriptPages.cps("", cfg, "fast") == 80.0, "속도: 기본·Config·즉시·숫자·대화 파일 기본")
	var bad := ScriptPages.normalize({"display": "bubble", "text": "{x}", "speed": "zzz"})
	var probs := ScriptPages.problems(bad)
	check(probs.size() == 3, "문제: 화자 없는 말풍선·알 수 없는 {}·이상한 속도 (%s)" % [probs])
	check(not ScriptPages.is_plain(ScriptPages.normalize({"text": "a{w=1}"})), "대기가 있으면 예전 형식으로 못 씀")

	# ---- 실제 대화 화면
	DataLoader.nodes["tsp_a"] = {"node_id": "tsp_a", "speaker_id": "", "text": "", "next_node": "", "on_enter": "", "kind": "",
		"text_speed": "", "pages": [
			{"display": "narration", "text": "첫 번째 페이지 글"},
			{"display": "bubble", "speaker_id": "char_cat", "text": "야옹{w=0.5}야옹", "speed": "10"},
			{"display": "system", "text": "자동", "speed": "instant", "advance": "auto", "auto_wait": 0.2},
			{"display": "narration", "text": "끝", "speed": "instant"}]}
	DataLoader.choices_by_node["tsp_a"] = [{"choice_id": "tsp_c1", "node_id": "tsp_a", "text": "닫기", "condition": "", "show_mode": "",
		"cost": "", "effects": "", "next_node": "EXIT", "type": "normal", "check": "", "dc": 0, "mod": 0, "fail_effects": "", "fail_next": ""}]
	var play: Control = DialogueScene.instantiate()
	play.embedded = true
	add_child(play)
	play.set_process(false)   # 시간은 테스트가 _process 로 직접 흘린다
	await StoryRunner.start_dialogue("tsp_a")
	await get_tree().process_frame
	check(play._page_i == 0 and play._type_label == play.get_node("%SituationText") and play._type_label.visible_characters == 0,
		"1쪽 상황 묘사: 글자가 0자부터 나오기 시작")
	play._process(0.1)
	var shown: int = play.get_node("%SituationText").visible_characters
	check(shown > 0 and shown < 9, "0.1초 뒤 몇 글자만 (%d)" % shown)
	play.advance()
	check(play._page_i == 0 and play._type_label == null and play.get_node("%SituationText").visible_characters == -1,
		"출력 중 입력 1번 → 이 페이지 전체 표시")
	play.advance()
	check(play._page_i == 1 and play.get_node("%Bubble").visible, "다음 입력 → 2쪽 말풍선")
	play._process(1.0)   # 10자/초 → '야옹' 2자 뒤 대기 지점에서 멈춤
	var bl: Label = play.get_node("%Bubble").text_label()
	check(bl.visible_characters == 2 and play._type_wait > 0.0, "{w=0.5} 자리(2자)에서 멈춤")
	play._process(0.3)
	check(bl.visible_characters == 2, "대기 중엔 그대로")
	play._process(0.3)
	play._process(0.15)
	check(bl.visible_characters > 2, "대기가 끝나면 이어서 (%d)" % bl.visible_characters)
	play._process(5.0)
	check(play._type_label == null and play.get_node("%Choices").get_child_count() == 0, "2쪽 다 나옴, 선택지 아직 없음")
	play.advance()
	check(play._page_i == 2 and play._type_label == null and play._auto_left > 0.0, "3쪽 시스템(즉시) → 자동 넘김 대기")
	play._process(0.25)
	check(play._page_i == 3 and play.get_node("%Choices").get_child_count() == 1, "0.2초 뒤 자동으로 4쪽, 마지막 쪽에 선택지")
	play.queue_free()
	await get_tree().process_frame

	# 시작 페이지 (에디터 미리보기)
	var play2: Control = DialogueScene.instantiate()
	play2.embedded = true
	play2.start_page = 2
	add_child(play2)
	play2.set_process(false)
	await StoryRunner.start_dialogue("tsp_a")
	await get_tree().process_frame
	check(play2._page_i == 2, "start_page 2 → 3쪽부터")
	play2.queue_free()
	DataLoader.nodes.erase("tsp_a")
	DataLoader.choices_by_node.erase("tsp_a")

	print("[test_script_pages] 실패 %d" % _fail)
	get_tree().quit(1 if _fail > 0 else 0)


func check(ok: bool, label: String) -> void:
	print(("ok   " if ok else "FAIL ") + label)
	if not ok:
		_fail += 1
