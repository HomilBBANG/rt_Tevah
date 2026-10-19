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
	check(not ScriptPages.is_plain(ScriptPages.normalize({"display": "system", "text": "a"}))
		and not ScriptPages.is_plain(ScriptPages.normalize({"display": "subtitle", "text": "a"})),
		"시스템·자막 1페이지는 pages 로 저장 (예전 형식이면 상황 묘사로 바뀌던 것)")
	var sub := ScriptPages.normalize({"display": "subtitle", "speaker_id": "char_cat", "text": "자막"})
	check(sub.display == "subtitle" and sub.speaker_id == "char_cat" and ScriptPages.problems(ScriptPages.normalize({"display": "subtitle", "text": "x"})).is_empty(),
		"자막: 화자 있어도 되고 없어도 됨")

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

	# 자막: 대화창 없이 화면 아래 글자만 (화자는 이름만 작게)
	DataLoader.nodes["tsp_sub"] = {"node_id": "tsp_sub", "speaker_id": "", "text": "", "next_node": "EXIT", "on_enter": "", "kind": "",
		"text_speed": "", "pages": [{"display": "subtitle", "text": "(테스트) 자막 한 줄", "speed": "instant"},
			{"display": "subtitle", "speaker_id": "char_cat", "text": "(테스트) 이름 있는 자막", "speed": "instant"}]}
	var ps: Control = DialogueScene.instantiate()
	ps.embedded = true
	add_child(ps)
	ps.set_process(false)
	await StoryRunner.start_dialogue("tsp_sub")
	await get_tree().process_frame
	check(ps.subtitle.visible and ps.subtitle.text == "(테스트) 자막 한 줄" and not ps.subtitle_name.visible
		and not ps.get_node("%SituationBox").visible and not ps.get_node("%Bubble").visible and not ps.get_node("%SystemBox").visible,
		"자막 페이지: 상자·말풍선 없이 글자만")
	ps.advance()
	check(ps.subtitle.text == "(테스트) 이름 있는 자막" and ps.subtitle_name.visible and ps.subtitle_name.text != "", "화자가 있으면 이름이 위에 작게")
	ps.queue_free()
	DataLoader.nodes.erase("tsp_sub")
	await get_tree().process_frame

	# 같은 사람이 이어서 말하면 같은 말풍선 (지난 대사 안 띄움), 다른 사람이 말하면 지난 대사가 회색으로
	DataLoader.nodes["tsp_same"] = {"node_id": "tsp_same", "speaker_id": "", "text": "", "next_node": "EXIT", "on_enter": "", "kind": "",
		"text_speed": "", "pages": [{"display": "bubble", "speaker_id": "char_cat", "text": "(테스트) 하나", "speed": "instant"},
			{"display": "bubble", "speaker_id": "char_cat", "text": "(테스트) 둘", "speed": "instant"},
			{"display": "bubble", "speaker_id": GameState.protagonist_id, "text": "(테스트) 셋", "speed": "instant"}]}
	var pb: Control = DialogueScene.instantiate()
	pb.embedded = true
	add_child(pb)
	pb.set_process(false)
	await StoryRunner.start_dialogue("tsp_same")
	await get_tree().process_frame
	pb.advance()
	check(pb.get_node("%Bubble").visible and pb.get_node("%Bubble").text_label().text == "(테스트) 둘" and not pb.get_node("%PrevBubble").visible,
		"같은 사람이 이어서: 같은 말풍선, 지난 대사 안 뜸")
	pb.advance()
	check(pb.get_node("%PrevBubble").visible, "다른 사람이 말하면 지난 대사(회색)가 뜸")
	pb.queue_free()
	DataLoader.nodes.erase("tsp_same")
	await get_tree().process_frame

	# 자유 위치 글자: 화면 % 자리, 정렬·크기·색 (빠진 칸은 기본값)
	var fr := ScriptPages.normalize({"display": "free", "text": "x", "x": 150, "align": "nope"})
	check(fr.display == "free" and fr.x == 100.0 and fr.y == 50.0 and fr.align == "center" and fr.size == 38 and fr.color == "#FFFFFF"
		and not ScriptPages.is_plain(fr), "자유 위치 글자: 범위 밖 x 는 100, 틀린 정렬·빠진 칸은 기본값")
	DataLoader.nodes["tsp_free"] = {"node_id": "tsp_free", "speaker_id": "", "text": "", "next_node": "EXIT", "on_enter": "", "kind": "",
		"text_speed": "", "pages": [{"display": "free", "text": "(테스트) 왼쪽 위", "speed": "instant", "x": 10, "y": 20, "align": "left", "size": 50, "color": "#FF0000"}]}
	var pf: Control = DialogueScene.instantiate()
	pf.embedded = true
	pf.size = Vector2(1920, 1080)
	add_child(pf)
	pf.set_process(false)
	await StoryRunner.start_dialogue("tsp_free")
	await get_tree().process_frame
	var ft: Label = pf.free_text
	check(ft.visible and ft.text == "(테스트) 왼쪽 위" and not pf.subtitle.visible and not pf.get_node("%SituationBox").visible
		and not pf.get_node("%Bubble").visible, "자유 위치 글자 페이지: 상자 없이 그 글자만")
	check(is_equal_approx(ft.anchor_left, 0.1) and is_equal_approx(ft.anchor_top, 0.2) and ft.grow_horizontal == Control.GROW_DIRECTION_END
		and ft.get_theme_font_size("font_size") == 50 and ft.get_theme_color("font_color").is_equal_approx(Color.RED),
		"자리 = 화면 10%·20%, 왼쪽 맞춤은 오른쪽으로 자람, 크기 50·빨강")
	# 연출 색 화면: 그림 칸 위·페이드 아래, 대사 상자 아래
	await pf._do_step({"do": "screen", "color": "#203040", "fade": 0.0})
	check(pf.screen.visible and pf.screen.color.is_equal_approx(Color("203040")) and pf.screen.get_index() > pf.cg.get_index()
		and pf.screen.get_index() < pf.fade.get_index() and pf.screen.get_index() < pf.free_text.get_index(), "색 화면: 그 색으로 화면을 덮음 (글자는 그 위)")
	await pf._do_step({"do": "screen_off", "fade": 0.0})
	check(not pf.screen.visible and pf.screen.color.a == 0.0, "색 화면 내리기")
	pf.queue_free()
	DataLoader.nodes.erase("tsp_free")
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
