extends Node
## 대화 에디터 스모크 테스트 (에디터 플러그인 화면을 게임 안에서 띄워 확인). user://test_dialogues/ 에 복사본으로 작업.
##   Godot_v4.7-stable_win64_console.exe --path . res://tests/dialogue_editor_smoke.tscn

const Editor = preload("res://addons/dialogue_editor/dialogue_editor.gd")
const Card = preload("res://addons/dialogue_editor/dialogue_card.gd")
const FuncCard = preload("res://addons/dialogue_editor/func_card.gd")
const ExprRows = preload("res://addons/expr_rows.gd")
const TEST_DIR := "user://test_dialogues/"

var _fail := 0
var ed: Node


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(TEST_DIR)
	for f in DirAccess.get_files_at(TEST_DIR):
		DirAccess.remove_absolute(TEST_DIR + f)
	for f in ["npc1", "cat", "npc2"]:
		var src := FileAccess.get_file_as_string("res://tools/dialogues/%s.json" % f)
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
	card.data.text = "새 대사"
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
	var se: Node = ExprRows.new().setup("effect", "status:+bleeding;status:-panic", lk)
	var sc: Node = ExprRows.new().setup("cond", "status:bleeding & !status:panic", lk)
	check(se._rows.size() == 2 and se._rows[0].kind == "status_add" and se._to_text() == "status:+bleeding;status:-panic"
		and sc._rows[1].kind == "not_status" and sc._to_text() == "status:bleeding & !status:panic"
		and lk.statuses.size() == 3, "상태이상 걸기·풀기·조건 줄 그대로")
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

	# 새 대화
	check(ed.new_dialogue("t_new"), "새 대화 만들기")
	check(FileAccess.file_exists(TEST_DIR + "t_new.json") and ed._cards().size() == 1, "새 대화 파일 + 첫 카드")
	check(not ed.new_dialogue("bad id!"), "잘못된 ID 거부")

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
