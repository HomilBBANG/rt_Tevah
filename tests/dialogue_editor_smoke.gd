extends Node
## 대화 에디터 스모크 테스트 (에디터 플러그인 화면을 게임 안에서 띄워 확인). user://test_dialogues/ 에 복사본으로 작업.
##   Godot_v4.7-stable_win64_console.exe --path . res://tests/dialogue_editor_smoke.tscn

const Editor = preload("res://addons/dialogue_editor/dialogue_editor.gd")
const Card = preload("res://addons/dialogue_editor/dialogue_card.gd")
const FuncCard = preload("res://addons/dialogue_editor/func_card.gd")
const StartCard = preload("res://addons/dialogue_editor/start_card.gd")
const DirectCard = preload("res://addons/dialogue_editor/direct_card.gd")
const ExprRows = preload("res://addons/expr_rows.gd")
const TEST_DIR := "user://test_dialogues/"

var _fail := 0
var ed: Node


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(TEST_DIR)
	for f in DirAccess.get_files_at(TEST_DIR):
		DirAccess.remove_absolute(TEST_DIR + f)
	for f in ["npc1", "cat", "npc2"]:
		# 테스트 전용 복사본 (tools/dialogues 의 대화를 고쳐도 테스트가 안 깨지게)
		var src := FileAccess.get_file_as_string("res://tests/fixtures/dialogues/%s.json" % f)
		var w := FileAccess.open(TEST_DIR + f + ".json", FileAccess.WRITE)
		w.store_string(src)
		w.close()
	var original: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(TEST_DIR + "npc1.json"))

	ed = Editor.new()
	ed.dir = TEST_DIR
	ed.set_anchors_preset(Control.PRESET_FULL_RECT)
	var bg := ColorRect.new()
	bg.color = Color(0.13, 0.14, 0.17)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	add_child(ed)
	await _frames(2)
	check(ed.files.item_count == 3, "대화 파일 3개 목록")
	ed.open_dialogue("npc1")
	await _frames(3)
	var cards: Array = ed._cards()
	check(cards.size() == 3 and ed.graph.get_node_or_null("__EXIT__") != null, "NPC 1: 카드 3장 + 대화 끝(EXIT)")
	var conns: Array = ed.graph.get_connection_list()
	check(conns.size() == 7, "연결선 7개 (선택지 4 + 판정 실패 1 + 다음 2): %d" % conns.size())
	var dice_fail := conns.filter(func(c): return c.from_node == &"fd_npc1_a" and c.to_node == &"fd_npc1_fail")
	check(dice_fail.size() == 1, "판정 선택지의 실패 연결점 → fd_npc1_fail")
	ed._edit_choice(ed.graph.get_node("fd_npc1_a"), 2)
	await _frames(2)
	await _snap("npc1")

	# 저장해도 내용 그대로 (위치만 다를 수 있음)
	ed.save()
	var saved: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(TEST_DIR + "npc1.json"))
	check(_strip_pos(saved.nodes) == _strip_pos(original.nodes) and saved.choices == original.choices, "열고 저장 → 내용 그대로")

	# 카드 추가 → 선택지 추가 → EXIT 로 연결 → 판정으로 바꾸면 실패 연결점 생김
	var card: GraphNode = ed.add_card(Vector2(40, 600))
	card.data.pages[0].text = "새 대사"
	card.add_choice()
	await _frames(1)
	check(card.choices.size() == 1 and card.choices[0].choice_id == "npc1_c1", "선택지 추가, ID 자동 (npc1_c1)")
	ed._on_connect(card.name, 1, &"__EXIT__", 0)    # port 0 = 다음, 1 = 첫 선택지
	check(card.choices[0].next_node == "EXIT", "선택지 → EXIT 연결 = next_node EXIT")
	card.choices[0].type = "dice"
	card.rebuild()
	check(card.out_ports.size() == 3 and card.out_ports[2][0] == "fail", "판정으로 바꾸면 '판정 실패 →' 연결점")
	ed._on_connect(card.name, 2, &"fd_npc1_fail", 0)
	check(card.choices[0].fail_next == "fd_npc1_fail", "실패 연결 = fail_next")
	ed._on_connect(card.name, 0, &"fd_npc1_a", 0)
	check(card.data.next_node == "fd_npc1_a", "다음 → 연결 = next_node")
	ed._on_disconnect(card.name, 0, &"fd_npc1_a", 0)
	check(card.data.next_node == "", "연결 끊기 = next_node 비움")
	# 이름 바꾸기: 다른 카드의 연결도 따라감
	ed._rename_node(ed.graph.get_node("fd_npc1_fail"), "npc1_fail_renamed")
	check(card.choices[0].fail_next == "npc1_fail_renamed", "노드 이름 바꾸면 연결도 따라감")
	ed.save()
	var after: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(TEST_DIR + "npc1.json"))
	check(after.nodes.size() == 4 and after.choices.size() == 5, "저장: 노드 4, 선택지 5")
	ed.open_dialogue("cat")
	ed.open_dialogue("npc1")
	await _frames(2)
	check(ed._cards().size() == 4 and ed.graph.get_connection_list().size() == 9, "다시 열면 그대로 (연결 9)")
	await _snap("npc1_edited")

	# 조건·효과 고르기: 글자 ↔ 줄 목록
	var lk: Dictionary = ed.lookups
	check(not lk.items.is_empty() and "showed_knife" in lk.flags, "목록: 아이템 %d개, 플래그에 showed_knife" % lk.items.size())
	var er: Node = ExprRows.new().setup("cond", "has:knife & !flag:met", lk)
	check(er._rows.size() == 2 and er._rows[0].kind == "has" and er._rows[1].kind == "not_flag" and er.get_text() == "has:knife & !flag:met",
		"조건 → 줄 2개 (아이템 있음, 플래그 꺼짐)")
	er._rows.append(er._default_row("cut"))
	er._emit()
	check(er.get_text() == "has:knife & !flag:met & cut:any", "조건 줄 추가 → has:knife & !flag:met & cut:any (%s)" % er.get_text())
	er._join = "|"
	er._emit()
	check(er.get_text() == "has:knife | !flag:met | cut:any", "또는(|) 로 바꾸기")
	var ee: Node = ExprRows.new().setup("effect", "item:+food*2;surv:thirst+50;restore:left_arm;save", lk)
	check(ee._rows.size() == 4 and ee._to_text() == "item:+food*2;surv:thirst+50;restore:left_arm;save", "효과 4줄 그대로 (%s)" % ee._to_text())
	ee._rows[0].p.amount = 1
	ee._emit()
	check(ee.get_text().begins_with("item:+food;"), "수량 1 이면 *1 생략")
	check(ExprRows.new().setup("cond", "(has:a | has:b) & flag:x", lk)._raw, "괄호 식 → 직접 입력만")
	var se: Node = ExprRows.new().setup("effect", "status:+bleeding;status:-panic_disorder", lk)
	var sc: Node = ExprRows.new().setup("cond", "status:bleeding & !status:panic_disorder", lk)
	check(se._rows.size() == 2 and se._rows[0].kind == "status_add" and se._to_text() == "status:+bleeding;status:-panic_disorder"
		and sc._rows[1].kind == "not_status" and sc._to_text() == "status:bleeding & !status:panic_disorder"
		and lk.statuses.size() == 12 and "high_intellect" in lk.traits, "상태이상 걸기·풀기·조건 줄 그대로 (상태이상 12, 특성 목록)")
	se.free()
	sc.free()
	check(ExprRows.new().setup("effect", "goto:somewhere", lk)._raw, "goto 효과 → 직접 입력만")
	for x in [er, ee]:
		x.free()

	# 기능 카드: npc2 의 효과 카드·조건 분기 카드
	ed.open_dialogue("npc2")
	await _frames(2)
	var fx: GraphNode = ed.graph.get_node("fd_npc2_fx")
	var br: GraphNode = ed.graph.get_node("fd_npc2_br")
	check(fx is FuncCard and br is FuncCard and br.out_ports.size() == 2, "효과 카드·조건 분기 카드 (맞으면/아니면 2갈래)")
	var br_conns: Array = ed.graph.get_connection_list().filter(func(c): return c.from_node == &"fd_npc2_br")
	check(br_conns.size() == 2, "조건 분기 카드 연결선 2개")
	ed._edit_choice(ed.graph.get_node("fd_npc2_a"), 0)
	await _frames(2)
	await _snap("npc2_func_cards")
	var nb: GraphNode = ed.add_func_card("branch", Vector2(40, 900))
	ed._on_connect(nb.name, 0, &"__EXIT__", 0)
	ed._on_connect(nb.name, 1, &"fd_npc2_no", 0)
	check(nb.data.next_node == "EXIT" and nb.data.fail_next == "fd_npc2_no", "새 조건 분기: 맞으면 EXIT, 아니면 fd_npc2_no")
	nb.data.condition = "flag:fx_done"
	var ne: GraphNode = ed.add_func_card("effect", Vector2(40, 1100))
	ne.data.on_enter = "setflag:fx_done"
	ed._on_connect(ne.name, 0, StringName(nb.name), 0)
	var nb_name := String(nb.name)
	var ne_name := String(ne.name)
	ed.save()
	ed.open_dialogue("npc1")
	ed.open_dialogue("npc2")
	await _frames(2)
	var nb2: GraphNode = ed.graph.get_node(nb_name)
	var ne2: GraphNode = ed.graph.get_node(ne_name)
	check(nb2 is FuncCard and nb2.data.kind == "branch" and nb2.data.condition == "flag:fx_done" and nb2.data.fail_next == "fd_npc2_no"
		and ne2.data.kind == "effect" and ne2.data.next_node == nb_name, "저장 후 다시 열어도 기능 카드 그대로")

	# ---- 대본 블록: 여러 페이지 (기획 v1.0 1차)
	ed.open_dialogue("cat")
	await _frames(2)
	var cat: GraphNode = ed.graph.get_node("fd_cat_a")
	ed._select(cat)
	await _frames(1)
	var sp: Node = ed.script_panel
	check(sp.card == cat and sp.page_boxes.size() == 1 and cat.data.pages[0].display == "bubble", "카드 고르기 → 대본 칸에 1페이지 (말풍선)")
	sp.add_page(0)
	cat.data.pages[0].display = "narration"
	cat.data.pages[0].speaker_id = ""
	cat.data.pages[0].text = "고양이가 당신을 올려다본다.

잠시 침묵이 흐른다.{w=0.5}"
	sp.add_page(2)
	var sys_page: Dictionary = cat.data.pages[2]
	sys_page.display = "system"
	sys_page.text = "저장할 수 있을 것 같다."
	sys_page.speed = "instant"
	sys_page.advance = "auto"
	sys_page.auto_wait = 1.0
	cat.data.pages[1].speed = "slow"
	sp.edit(cat)
	cat.rebuild()
	await _frames(2)
	check(sp.page_boxes.size() == 3 and cat.data.pages.map(func(p): return p.page_id).size() == 3
		and cat.data.pages[0].page_id != cat.data.pages[1].page_id, "페이지 3개 (묘사 → 말풍선 → 시스템), page_id 겹치지 않음")
	await _snap("script_pages")
	ed.save()
	var cs: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(TEST_DIR + "cat.json"))
	var cn: Dictionary = cs.nodes[0]
	check(cn.pages.size() == 3 and cn.pages[0].display == "narration" and cn.pages[1].speaker_id == "char_cat" and cn.pages[1].speed == "slow"
		and cn.pages[2].advance == "auto" and not cn.pages[0].has("speaker_id") and cn.text == "고양이가 당신을 올려다본다.

잠시 침묵이 흐른다.",
		"저장: pages 3개 + 예전 칸(text)은 첫 페이지 글 (대기 표시 뺌)")
	ed.open_dialogue("npc1")
	ed.open_dialogue("cat")
	await _frames(2)
	cat = ed.graph.get_node("fd_cat_a")
	check(cat.data.pages.size() == 3 and cat.data.pages[2].auto_wait == 1.0 and "{w=0.5}" in cat.data.pages[0].text, "다시 열어도 페이지 그대로")
	# 페이지 순서 바꾸기·지우기
	ed._select(cat)
	sp.move_page(2, 0)
	check(cat.data.pages[0].display == "system", "페이지 옮기기 (3 → 1)")
	sp.remove_page(0)
	check(cat.data.pages.size() == 2 and cat.data.pages[0].display == "narration", "페이지 지우기")

	# ---- 실행 취소 / 다시 실행
	var n_before: int = ed._cards().size()
	ed.add_card(Vector2(0, 900))
	check(ed._cards().size() == n_before + 1, "카드 추가")
	ed.undo()
	await _frames(1)
	check(ed._cards().size() == n_before, "실행 취소 → 카드가 사라짐")
	ed.redo()
	await _frames(1)
	check(ed._cards().size() == n_before + 1, "다시 실행 → 카드가 돌아옴")
	ed.undo()
	ed.undo()   # 페이지 지우기 되돌림
	await _frames(1)
	check(ed.graph.get_node("fd_cat_a").data.pages.size() == 3, "실행 취소로 지운 페이지도 돌아옴")

	# ---- 복사·붙여넣기 (새 ID, 선택지 ID 도 새로)
	cat = ed.graph.get_node("fd_cat_a")
	for c in ed.graph.get_children():
		if c is GraphNode:
			c.selected = c == cat
	ed.copy_selected()
	var made: Array = ed.paste()
	var all_cids := []
	for c in ed._cards():
		for ch in c.choices:
			all_cids.append(ch.choice_id)
	var uniq := {}
	for x in all_cids:
		uniq[x] = true
	check(made.size() == 1 and made[0].data.node_id != "fd_cat_a" and made[0].choices.size() == cat.choices.size()
		and uniq.size() == all_cids.size() and made[0].data.pages.size() == 3, "붙여넣기: 새 노드 ID·선택지 ID 안 겹침, 페이지도 복사")
	check(ed.dirty and ed._save_btn.text == "저장 ●", "저장 안 한 변경 표시 (저장 ●)")
	# 다른 대화를 화면에서 고르면 묻는다
	ed._request_open("npc2")
	await _frames(1)
	var asked := ed.get_children().filter(func(c): return c is ConfirmationDialog and c.visible)
	check(asked.size() == 1 and ed.dialogue.dialogue_id == "cat", "저장 안 하고 다른 대화 열기 → 확인 창 (아직 cat)")
	for d in asked:
		d.get_cancel_button().pressed.emit()
	ed.undo()   # 붙여넣기 취소
	ed.save()

	# ---- 찾기 (모든 대화)
	ed.search.text = "올려다본다"
	ed._run_search()
	check(ed.results.item_count >= 1 and ed.results.get_item_metadata(0) == ["cat", "fd_cat_a", 1], "찾기: 대사 글 → cat · fd_cat_a · 2쪽 (%s)" % [ed.results.get_item_metadata(0) if ed.results.item_count > 0 else "없음"])
	ed.search.text = "showed_knife"
	ed._run_search()
	check(ed.results.item_count >= 1 and ed.results.get_item_metadata(0)[0] in ["npc1", "npc2"], "찾기: 플래그 이름")
	ed.search.text = ""
	ed._run_search()
	# ---- 검사 결과 줄 → 그 자리로
	ed.log_view.text = "오류 1개 — JSON을 쓰지 않았습니다.
  [대화 cat.json (fd_cat_a) 페이지 2] 말풍선 페이지에 화자(speaker_id)가 없음
경고 1개 (변환은 됨):
  경고 [대화 npc2.json (fd_npc2_b)] 대사가 비어 있음"
	var counts: Array = ed._fill_problems()
	check(counts == [1, 1] and ed.problems.get_item_metadata(0) == ["cat", "fd_cat_a", 1] and ed.problems.get_item_metadata(1) == ["npc2", "fd_npc2_b", -1],
		"검사 결과: 오류 1·경고 1, 누르면 갈 곳 (cat 2쪽 / npc2)")
	ed.goto("npc2", "fd_npc2_b")
	await _frames(2)
	check(ed.dialogue.dialogue_id == "npc2" and ed._selected_card != null and ed._selected_card.name == &"fd_npc2_b", "검사 결과로 이동 → npc2 의 카드를 고름")
	await _snap("npc2_goto")

	# 새 대화
	check(ed.new_dialogue("t_new"), "새 대화 만들기")
	check(FileAccess.file_exists(TEST_DIR + "t_new.json") and ed._cards().size() == 2, "새 대화 파일 + 대화 시작 카드 + 첫 카드")
	check(not ed.new_dialogue("bad id!"), "잘못된 ID 거부")

	# ---- NPC 단위 대화 + 대화 시작 카드
	check(ed.new_dialogue("t_cat", "", "char_cat"), "NPC(고양이) 대화 만들기")
	var st: GraphNode = ed.graph.get_node("t_cat_start")
	var first: GraphNode = ed.graph.get_node(st.data.next_node)
	check(st is StartCard and first.data.pages[0].display == "bubble" and first.data.pages[0].speaker_id == "char_cat"
		and ed.dialogue.npc_id == "char_cat", "시작 카드 → 고양이 말풍선 첫 카드, 파일에 npc_id")
	check(ed.graph.get_connection_list().any(func(c): return c.from_node == &"t_cat_start" and c.to_node == first.name), "시작 카드 '그 외' 연결선")
	# 길 추가: 대화 횟수 == 0 → 새 카드, 그 외 → 반복 대사 카드
	st.data.routes.append({"condition": "count:talk==0", "next_node": ""})
	st.rebuild()
	check(st.out_ports.size() == 2 and st.out_ports[0][0] == "route", "길 1개 + 그 외 = 연결점 2개")
	var again: GraphNode = ed.add_card(Vector2(560, 400))
	ed._on_connect(st.name, 0, first.name, 0)
	ed._on_connect(st.name, 1, again.name, 0)
	check(st.data.routes[0].next_node == first.data.node_id and st.data.next_node == again.data.node_id, "길 1 → 첫 카드, 그 외 → 반복 카드")
	var n_cards: int = ed._cards().size()
	ed._add_kind("start", Vector2.ZERO)
	check(ed._cards().size() == n_cards + 1 and ed.graph.get_node_or_null("t_cat_start2") != null, "시작 카드는 여러 개 가능 (두 번째 t_cat_start2)")
	ed.undo()
	ed.save()
	var tf: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(TEST_DIR + "t_cat.json"))
	var sn: Dictionary = tf.nodes.filter(func(n): return n.node_id == "t_cat_start")[0]
	check(tf.npc_id == "char_cat" and sn.kind == "start" and sn.routes == [{"condition": "count:talk==0", "next_node": first.data.node_id}],
		"저장: npc_id, 시작 카드 kind=start, routes")
	ed.open_dialogue("cat")
	ed.open_dialogue("t_cat")
	await _frames(2)
	st = ed.graph.get_node("t_cat_start")
	check(st is StartCard and st.data.routes.size() == 1 and ed.graph.get_connection_list().filter(func(c): return c.from_node == &"t_cat_start").size() == 2,
		"다시 열어도 시작 카드·길 그대로 (연결선 2)")
	ed._select(st)
	await _frames(2)
	await _snap("start_card")
	check(ed.file_list.get_item_text(ed.files.selected).contains("고양이"), "대화 목록에 NPC 이름")

	# ---- NPC 없는 대화 (오프닝·이벤트 컷신) + '게임 오프닝으로 쓰기'
	check(ed.new_dialogue("t_open", "", ""), "NPC 없는 대화 만들기")
	var ost: GraphNode = ed.graph.get_node("t_open_start")
	var ofirst: GraphNode = ed.graph.get_node(ost.data.next_node)
	check(not ed.dialogue.has("npc_id") and ofirst.data.pages[0].display == "narration", "NPC 없음 → 첫 카드는 상황 묘사")
	# 시작 카드의 '🎬 자동 시작' 토글 → 시점 고르기 (방 진입은 맵도)
	var tog: CheckButton = ost.find_children("*", "CheckButton", true, false)[0]
	tog.button_pressed = true
	await _frames(1)
	ost = ed.graph.get_node("t_open_start")
	check(ost.data.trigger.when == "new_game" and ost.title.begins_with("🎬"), "자동 시작 켜기 → 기본 '새 게임 시작 후'")
	var when_opt: OptionButton = ost.find_children("*", "OptionButton", true, false)[0]
	when_opt.select(4)
	when_opt.item_selected.emit(4)
	await _frames(1)
	ost = ed.graph.get_node("t_open_start")
	check(ost.data.trigger.when == "map_enter" and ost.find_children("*", "OptionButton", true, false).size() == 2, "'방 진입 후' → 맵 고르기가 나옴")
	ost.data.trigger.map = "basecamp"
	# 시작 카드 여러 개 (자동 시작 + 말 걸 때)
	ed._add_kind("start", Vector2(40, 400))
	check(ed._cards().filter(func(c): return c is StartCard).size() == 2, "시작 카드를 하나 더 (여러 개 가능)")
	ed.save()
	var of: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(TEST_DIR + "t_open.json"))
	var trig_nodes: Array = of.nodes.filter(func(n): return n.has("trigger"))
	check(trig_nodes.size() == 1 and trig_nodes[0].trigger.when == "map_enter" and trig_nodes[0].trigger.map == "basecamp"
		and of.nodes.filter(func(n): return n.get("kind", "") == "start").size() == 2, "저장: 자동 시작(방 진입·basecamp) + 시작 카드 2개")
	check(ed.file_list.get_item_text(ed.files.selected).contains("🎬 자동 시작"), "대화 목록에 🎬 자동 시작 표시")
	await _snap("opening_check")
	ed.open_dialogue("t_cat")
	await _frames(2)

	# ---- 🎬 연출 카드: 단계 추가 → 저장 → 다시 열기
	var dc: GraphNode = ed.add_func_card("direct", Vector2(40, 700))
	dc.data.steps.append({"do": "image", "file": "test_cg.png", "fade": 0.5})
	dc.data.steps.append({"do": "walk", "who": "player", "to": [3, 4], "speed": 3.0, "wait": true})
	dc.rebuild()
	ed._on_connect(dc.name, 0, &"__EXIT__", 0)
	var dc_name := String(dc.name)
	ed._select(dc)
	await _frames(2)
	ed.center_on(dc)
	await _frames(2)
	await _snap("direct_card")
	ed.save()
	ed.open_dialogue("cat")
	ed.open_dialogue("t_cat")
	await _frames(2)
	var dc2: GraphNode = ed.graph.get_node(dc_name)
	check(dc2 is DirectCard and dc2.data.steps.size() == 2 and dc2.data.steps[0].file == "test_cg.png" and Vector2i(dc2.data.steps[1].to[0], dc2.data.steps[1].to[1]) == Vector2i(3, 4)
		and dc2.data.next_node == "EXIT", "연출 카드: 그림·걷기 단계, 저장 후 다시 열어도 그대로 (%s → %s)" % [dc2.data.steps if dc2 is DirectCard else dc2, dc2.data.get("next_node", "") if dc2 else ""])

	# 변환·검사 (실제 프로젝트 데이터 — 원본 tools/dialogues 는 안 건드림)
	var conv_ok: bool = ed.run_convert()
	check(conv_ok and "변환 완료" in ed.log_view.text, "변환·검사 실행")

	for f in DirAccess.get_files_at(TEST_DIR):
		DirAccess.remove_absolute(TEST_DIR + f)
	print("[dialogue_editor_smoke] 실패 %d" % _fail)
	get_tree().quit(1 if _fail > 0 else 0)


func _strip_pos(nodes: Array) -> Array:
	return nodes.map(func(n):
		var d: Dictionary = n.duplicate()
		d.erase("pos")
		return d)


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _snap(name: String) -> void:
	await RenderingServer.frame_post_draw
	DirAccess.make_dir_recursive_absolute("user://dialogue_editor_smoke")
	get_viewport().get_texture().get_image().save_png("user://dialogue_editor_smoke/%s.png" % name)


func check(ok: bool, label: String) -> void:
	print(("ok   " if ok else "FAIL ") + label)
	if not ok:
		_fail += 1
