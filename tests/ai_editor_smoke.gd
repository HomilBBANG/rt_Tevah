extends Node
## 몬스터 AI 에디터 스모크 (창 필요): 에디터 화면을 게임 안에 띄워 BT 편집·Blackboard·검사·저장·Compile 확인.
## tools/ai 원본은 건드리지 않고 user://test_ai/ 복사본을 쓴다. 스크린샷 user://ai_editor_smoke/.
##   Godot_v4.7-stable_win64_console.exe --path . res://tests/ai_editor_smoke.tscn

const Editor = preload("res://addons/monster_ai/ai_editor.gd")
const TEST_DIR := "user://test_ai/"
const OUT := "user://test_ai_out.json"

var _fail := 0
var _shot := 0
var ed: Control


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(TEST_DIR)
	DirAccess.make_dir_recursive_absolute("user://ai_editor_smoke")
	for f in DirAccess.get_files_at(TEST_DIR):
		DirAccess.remove_absolute(TEST_DIR + f)
	for f in DirAccess.get_files_at("res://tools/ai/"):
		if f.ends_with(".json"):
			DirAccess.copy_absolute("res://tools/ai/" + f, TEST_DIR + f)
	if FileAccess.file_exists(OUT):
		DirAccess.remove_absolute(OUT)
	ed = Editor.new()
	ed.dir = TEST_DIR
	ed.out_path = OUT
	ed.set_anchors_preset(Control.PRESET_FULL_RECT)
	var bg := ColorRect.new()
	bg.color = Color(0.13, 0.14, 0.17)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	add_child(ed)
	await _frames(3)
	ed.open_asset("BT_Infected_Field")
	await _frames(2)

	# ---- 열기·배치
	check(ed.current == "BT_Infected_Field" and ed.canvas.rects.size() == 9, "BT 열기: 노드 9개 그림 (%s, %d)" % [ed.current, ed.canvas.rects.size()])
	var kids: Array = ed.node("ai_root").children
	var xs := kids.map(func(k): return ed.canvas.rects[k].position.x)
	check(xs == xs.duplicate().map(func(x): return x) and xs[0] < xs[1] and xs[1] < xs[2] and xs[2] < xs[3], "자식은 children 순서대로 왼쪽→오른쪽")
	check(ed.canvas.rects["root"].position.y < ed.canvas.rects["ai_root"].position.y and ed.canvas.rects["ai_root"].position.y < ed.canvas.rects["engage"].position.y, "Root 맨 위, 아래로 자식")
	check(ed.problems.get_item_text(0).begins_with("✓"), "샘플 검사 통과: %s" % ed.problems.get_item_text(0))
	ed._select("chase", true)
	await _frames(2)
	await _snap("bt_chase_selected")
	check(ed.details.get_children().any(func(c): return c is Label and "BTComposite_Sequence" in c.text), "Details 에 UE 대응 이름 (Sequence)")

	# ---- 노드 넣기·순서·되돌리기
	ed._select("ai_root", false)
	var w: String = ed.add_from_palette("task:Wait")
	check(w != "" and ed.node("ai_root").children.back() == w and ed.node(w).params.get("seconds") == 1.0, "팔레트: Task Wait 를 마지막 자식으로 (기본값 seconds=1)")
	ed.move_node(w, 0)
	check(ed.node("ai_root").children[0] == w and ed.canvas.rects[w].position.x < ed.canvas.rects["engage"].position.x, "순서 바꾸기: 0 번째 = 가장 왼쪽")
	ed.canvas.reorder_requested.emit(w, 4)
	check(ed.node("ai_root").children[4] == w, "카드 끌어 놓기(reorder_requested) → 4 번째")
	ed.undo()
	check(ed.node("ai_root").children[0] == w, "되돌리기 → 0 번째로")
	ed.undo()
	ed.undo()
	check(ed.node(w).is_empty() and ed.node("ai_root").children.size() == 4, "되돌리기 3번 → 넣기 전")
	ed.redo()
	check(not ed.node(w).is_empty(), "다시 → 다시 들어옴")
	# Decorator·Service
	ed._select(w, false)
	check(ed.add_decorator(w, "Blackboard") and ed.add_service(w, "UpdateTargetDistance"), "Decorator·Service 붙이기")
	var d: Dictionary = ed.node(w).decorators[0]
	d.key = "DistanceToTarget"
	d.operator = "<="
	d.value = 2.0
	d.observer_aborts = "Both"
	ed._changed()
	check(ed.problems.get_item_text(0).begins_with("✓"), "Blackboard Check (DistanceToTarget <= 2, Both) 검사 통과")
	d.operator = "<"
	d.key = "HasLineOfSight"
	ed._changed()
	check(ed.problems.get_item_text(0).contains("수(Int/Float) 키에만"), "bool 키에 < 는 오류: %s" % ed.problems.get_item_text(0))
	ed.delete_node(w)
	check(ed.node(w).is_empty() and not w in ed.node("ai_root").children, "지우기")
	# 복사·붙여넣기
	ed._select("chase", false)
	ed.copy_selected()
	ed._select("ai_root", false)
	var pasted: String = ed.paste()
	var pn: Dictionary = ed.node(pasted)
	check(pasted != "" and pasted != "chase" and pn.children.size() == 1 and pn.children[0] != "move_to_target"
		and ed.node(pn.children[0]).task_type == "MoveTo" and pn.decorators[0].key == "HasLineOfSight", "복사·붙여넣기: 새 ID 로 아래 노드까지")
	ed.delete_node(pasted)
	# 찾기
	ed.find_node("search")
	check(ed.selected in ["search", "search_last"], "노드 찾기 → %s" % ed.selected)

	# ---- Task 키 타입 검사
	ed.node("move_to_target").params.target_key = "SearchDuration"
	ed._changed()
	check(ed.problems.get_item_text(0).contains("키 타입이 맞지 않음"), "Task 키 타입 불일치 오류: %s" % ed.problems.get_item_text(0))
	ed.problems.item_clicked.emit(0, Vector2.ZERO, MOUSE_BUTTON_LEFT)
	check(ed.selected == "move_to_target", "오류를 누르면 그 노드로")
	ed.node("move_to_target").params.target_key = "TargetLocation"
	ed._changed()

	# ---- Blackboard 탭: 키 이름 바꾸기·지우기
	ed.tabs.current_tab = 1
	await _frames(2)
	await _snap("blackboard_tab")
	var los_refs: Array = ed.key_refs("BB_Infected", "HasLineOfSight").filter(func(r): return r.begins_with("BT_Infected_Field"))
	check(los_refs.size() == 2, "키를 쓰는 곳 (BT_Infected_Field 의 Engage·Chase Decorator): %s" % [los_refs])
	check(ed.key_refs("BB_Infected", "TargetLocation").has("BT_Infected_Field / move_to_target (Task target_key)"), "Task 의 키 (MoveTo target_key) 도 쓰는 곳")
	ed.rename_key("BB_Infected", "HasLineOfSight", "CanSee", false)
	check(ed.node("chase").decorators[0].key == "CanSee" and ed.assets.BB_Infected.keys.any(func(k): return k.name == "CanSee")
		and ed.dirty.has("BB_Infected") and ed.dirty.has("BT_Infected_Field"), "키 이름 바꾸기 → 쓰는 Decorator 도 함께, 둘 다 저장 표시")
	ed.delete_key("BB_Infected", "CanSee")
	check(ed.assets.BB_Infected.keys.any(func(k): return k.name == "CanSee") and "곳에서 씁니다" in ed.status.text, "쓰는 키는 못 지움")
	ed.add_key("BB_Infected")
	check(ed.assets.BB_Infected.keys.back().name == "NewKey1", "키 추가")
	ed.delete_key("BB_Infected", "NewKey1")
	check(not ed.assets.BB_Infected.keys.any(func(k): return k.name == "NewKey1"), "안 쓰는 키는 지움")
	ed.tabs.current_tab = 0

	# ---- 저장·다시 읽기
	check(ed.save() and ed.dirty.is_empty(), "저장")
	var saved: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(TEST_DIR + "BT_Infected_Field.json"))
	check(saved.nodes.filter(func(n): return n.id == "chase")[0].decorators[0].key == "CanSee", "저장한 파일에 바뀐 키")
	ed.reload_assets()
	check(ed.node("engage").decorators[0].key == "CanSee", "다시 읽어도 그대로")

	# ---- Compile
	ed._touch()
	ed.node("battle").task_type = "Nope"
	ed._changed()
	check(not ed.compile() and not FileAccess.file_exists(OUT), "오류가 있으면 Compile 실패, data 안 씀")
	ed.undo()
	check(ed.compile() and FileAccess.file_exists(OUT), "고치면 Compile → %s" % OUT)
	var out: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(OUT))
	check(out.assets.size() == ed.assets.size() and ed.assets.size() >= 4, "Compile 결과에 모든 자산 (%d)" % out.assets.size())

	# ---- Task Graph (Blueprint 스타일): BT 에서 두 번 누르면 열림
	ed.open_asset("BT_03_Stalker")
	await _frames(2)
	ed.canvas.node_activated.emit("search_last")
	await _frames(3)
	var gv: Control = ed.graph_view
	var gnodes: Array = gv.ge.get_children().filter(func(c): return c is GraphNode)
	check(ed.current == "BTT_SearchLastPosition" and ed.tabs.current_tab == 2 and gv.back_btn.visible and gnodes.size() == 15,
		"BT 의 TaskGraph Task 두 번 누르기 → Task Graph 탭 (노드 %d, 돌아가기 버튼)" % gnodes.size())
	check(gv.ge.get_connection_list().size() == 13, "연결 13개 그림 (%d)" % gv.ge.get_connection_list().size())
	var exec_slot: Color = gnodes.filter(func(n): return n.name == "branch")[0].get_slot_color_left(0)
	var bool_slot: Color = gnodes.filter(func(n): return n.name == "branch")[0].get_slot_color_left(1)
	check(exec_slot == Color.WHITE and bool_slot != Color.WHITE, "실행 핀은 흰색, Bool 데이터 핀은 다른 색")
	await _snap("task_graph")
	var n_conn: int = ed.cur().connections.size()
	check(gv.connect_pins("get_loc", "value", "branch", "condition") != "" and ed.cur().connections.size() == n_conn, "Vector2 → Bool 은 이어지지 않음")
	check(gv.connect_pins("branch", "false", "finish_fail", "exec_in") == ""
		and ed.cur().connections.filter(func(c): return c.from_node == "branch" and c.from_pin == "false").size() == 1, "실행 출력을 새로 이으면 바뀜 (한 곳으로만)")
	check(ed.problems.get_item_text(0).contains("finish_none") or ed.problems.get_item_text(0).begins_with("✓"), "검사 결과 갱신: %s" % ed.problems.get_item_text(0))
	ed.undo()
	check(ed.cur().connections.filter(func(c): return c.from_node == "branch" and c.from_pin == "false")[0].to_node == "finish_none", "되돌리기")
	var cmp: String = ed.add_from_palette("gnode:Compare")
	check(cmp != "" and gv.node(cmp).type == "Compare" and gv.node(cmp).params.op == "<", "팔레트로 Compare 노드 넣기")
	check(gv.connect_pins("get_dur", "value", cmp, "a") == "", "Float → Float 연결")
	var v: String = gv.add_var()
	ed.cur().variables.back().type = "int"
	var gvn: String = gv.add_node("GetVariable", Vector2.ZERO, {"var": v})
	check(gv.connect_pins(gvn, "value", cmp, "b") == "", "Int 변수 → Float 입력 (자동 변환)")
	gv.delete_nodes([cmp])
	check(gv.node(cmp).is_empty() and not ed.cur().connections.any(func(c): return c.to_node == cmp), "노드 지우면 그 선도 지움")
	gv.delete_nodes(["finish_none"])
	check(ed.problems.get_item_text(0).contains("'false' 이 이어지지 않음"), "Finish 를 지우면 오류 표시: %s" % ed.problems.get_item_text(0))
	ed.problems.item_clicked.emit(0, Vector2.ZERO, MOUSE_BUTTON_LEFT)
	check(gv.selected == "branch", "오류를 누르면 그 노드 (%s)" % gv.selected)
	ed.undo()
	ed.undo()
	ed.undo()
	ed.undo()
	check(not gv.node("finish_none").is_empty() and ed.problems.get_item_text(0).begins_with("✓"), "되돌리면 다시 통과")
	gv._select("move")
	await _frames(1)
	check(ed.details.get_children().any(func(c): return c is Label and "AI Move To" in c.text), "Details 에 UE 대응 (AI Move To)")
	# 키 이름을 바꾸면 그래프의 Get/Set 도
	ed.rename_key("BB_Infected", "LastKnownLocation", "LastSeenAt", false)
	check(gv.node("get_loc").params.key == "LastSeenAt" and ed.dirty.has("BTT_SearchLastPosition"), "Blackboard 키 이름 바꾸면 그래프 노드도")
	ed.go_back()
	check(ed.current == "BT_03_Stalker" and ed.selected == "search_last" and ed.tabs.current_tab == 0, "◀ 돌아가기 → 그 Task 카드")
	check(ed.new_graph("BTT_New", "BB_Infected") and ed.problems.get_item_text(0).begins_with("✓"), "새 Task Graph: 바로 검사 통과")

	# ---- Runtime Debugger: 게임이 보내는 상태(진짜 BT 실행기에서 만든 것)를 받으면
	var all := preload("res://core/ai/ai_assets.gd").load_dir()
	var ag = preload("res://tests/test_bt.gd").FakeAgent.new()
	ag.points = [Vector2(0, 0), Vector2(-3, 0)]   # 플레이어 반대쪽으로 순찰 → 보이면 추격 (아직 전투 거리 아님)
	var rr = preload("res://core/ai/bt_runner.gd").new()
	rr.setup(all.BT_Infected_Field, all.BB_Infected, ag)
	for i in 3:
		rr.tick(0.1)
	ag.player = Vector2(3, 0)
	for i in 3:
		rr.tick(0.1)
	var msg := {"map": "test_ai", "frozen": false, "monsters": [{"id": "ai_infected", "name": "감염자", "ref": "enemy_test", "tile": [1, 0], "grace": 0.0, "snap": rr.debug_snapshot()}]}
	ed.open_asset("BT_Infected_Field")
	ed.on_snapshot(JSON.parse_string(JSON.stringify(msg)))   # 다른 프로세스에서 오는 것처럼
	var dv: Control = ed.debug_view
	await _frames(2)
	check(dv.list.item_count == 1 and dv.selected_id == "ai_infected" and "실행 중" in dv.status.text, "Debugger: 몬스터 목록 (%d)" % dv.list.item_count)
	check(ed.canvas.debug.get("active", []).has("move_to_target") and ed.canvas.debug.results.get("patrol") == "ABORTED", "BT 그래프 카드에 실행 경로·결과 (추격 중, 순찰은 ABORTED)")
	var key_rows: Array = dv.keys.get_root().get_children().map(func(it): return [it.get_text(0), it.get_text(2)])
	check(key_rows.any(func(k): return k[0].begins_with("HasLineOfSight") and k[1] == "Service"), "Blackboard 값과 마지막으로 바꾼 곳 (Service)")
	var log_texts: Array = range(dv.logs.item_count).map(func(i): return dv.logs.get_item_text(i))
	check(log_texts.any(func(t): return "observer_abort" in t and "Lower Priority" in t), "기록에 Observer Aborts 중단과 이유")
	check(range(dv.decos.item_count).any(func(i): return "CanSeePlayer" in dv.decos.get_item_text(i)), "Decorator 마지막 판정")
	ed.tabs.current_tab = 3
	await _frames(2)
	await _snap("debugger")
	var ai := log_texts.find(log_texts.filter(func(t): return "observer_abort" in t)[0])
	dv.logs.item_clicked.emit(ai, Vector2.ZERO, MOUSE_BUTTON_LEFT)
	await _frames(2)
	check(ed.tabs.current_tab == 0 and ed.selected == "chase", "기록을 누르면 BT 탭의 그 노드로 (%s)" % ed.selected)
	await _snap("bt_debug_highlight")
	dv.follow.button_pressed = false
	check(ed.canvas.debug.is_empty(), "'BT 그래프에 표시' 끄면 표시 없음")
	ed.on_session_stopped()
	check("게임이 끝남" in dv.status.text, "게임이 끝나면 알림")

	# ---- Phase 6: Simple Parallel · Run Behavior · 전투 BT · 브레이크포인트·일시정지
	ed.open_asset("BT_Infected_Field")
	await _frames(1)
	ed._select("ai_root", false)
	var par: String = ed.add_from_palette("composite:SimpleParallel")
	check(par != "" and ed.node(par).kind == "SimpleParallel" and ed.node(par).finish_mode == "Immediate", "팔레트: Simple Parallel (Immediate)")
	var pm1: String = ed.add_node(par, "Task", "Wait")
	check(ed.problems.get_item_text(0).contains("자식은 둘"), "Simple Parallel 자식이 하나면 오류")
	var pb: String = ed.add_node(par, "Task", "RunBehavior")
	ed.node(pb).params.bt_id = "BT_02_HearAndSearch"
	ed._changed()
	check(ed.problems.get_item_text(0).begins_with("✓"), "주 Task + 배경(Run Behavior) → 통과: %s" % ed.problems.get_item_text(0))
	ed._select(pb, false)
	await _frames(1)
	var bt_opts: Array = []
	for ob in ed.details.find_children("*", "OptionButton", true, false):
		for i in ob.item_count:
			bt_opts.append(ob.get_item_text(i))
	check(bt_opts.has("BT_02_HearAndSearch") and bt_opts.has("BT_03_Stalker") and not bt_opts.has("BT_Battle_Test"), "Run Behavior: 같은 Blackboard·domain 의 BT 만 고르기")
	ed._select(par, true)
	await _frames(2)
	await _snap("simple_parallel")
	ed.toggle_breakpoint("chase")
	check(ed.canvas.breakpoints.has("chase") and ed.sent.back()[0] == "monster_ai:breakpoints" and ed.sent.back()[1][0].BT_Infected_Field == ["chase"],
		"브레이크포인트: 카드에 빨간 점 + 게임으로 보냄")
	dv.set_game_paused(true)
	check(ed.sent.back() == ["monster_ai:pause", [true]] and dv.pause_btn.text.contains("재개"), "일시정지 → 게임으로 pause 보냄")
	var pmsg: Dictionary = JSON.parse_string(JSON.stringify(msg))
	pmsg.paused = true
	pmsg.monsters[0].snap.bp_hit = "chase"
	ed.on_snapshot(pmsg)
	check("브레이크포인트: ai_infected @ chase" in dv.status.text, "브레이크포인트에 걸리면 알림: %s" % dv.status.text)
	ed.toggle_breakpoint("chase")
	check(not ed.canvas.breakpoints.has("chase"), "브레이크포인트 끄기")
	ed.open_asset("BT_Battle_Test")
	await _frames(1)
	var pal: Array = []
	var root_item: TreeItem = ed.palette.get_root()
	for g in root_item.get_children():
		for it in g.get_children():
			pal.append(it.get_text(0))
	check(pal.has("UseAttack") and pal.has("UseRandomAttack") and not pal.has("MoveTo") and not pal.has("Patrol"), "전투 BT 팔레트: 전투 Task 만 (%s)" % [pal])
	ed._select("use_quick", false)
	await _frames(1)
	var atk_opts: Array = []
	for ob in ed.details.find_children("*", "OptionButton", true, false):
		for i in ob.item_count:
			atk_opts.append(ob.get_item_text(i))
	check(atk_opts.any(func(t): return "atk_quick" in t), "UseAttack: 공격 고르기 목록 (NpcAttacks)")
	await _snap("battle_bt")

	# ---- 새 자산
	check(not ed.new_bt("Bad", "BB_Infected"), "BT_ 로 시작하지 않으면 거절")
	check(ed.new_bt("BT_Test", "BB_Infected") and ed.current == "BT_Test" and ed.node("selector_1").kind == "Selector", "새 BT: Root + Selector")
	check(ed.problems.get_item_text(0).contains("자식이 없음"), "빈 Selector 는 오류로 표시")
	var mv: String = ed.add_from_palette("task:MoveTo", "selector_1")
	check(ed.node("selector_1").children == [mv] and ed.problems.get_item_text(0).begins_with("✓"), "MoveTo 넣으면 통과")
	check(ed.new_bt("BT_Copy", "", "BT_Infected_Field") and ed.node("engage").kind == "Sequence", "템플릿 복사")
	check(ed.new_bb("BB_Test") and ed.tabs.current_tab == 1, "새 Blackboard → Blackboard 탭")
	ed.open_asset("BT_Infected_Field")
	await _frames(3)
	await _snap("bt_full")
	check(ed.has_unsaved(), "저장 안 한 새 자산 → has_unsaved (닫을 때 Godot 가 물음)")

	for f in DirAccess.get_files_at(TEST_DIR):
		DirAccess.remove_absolute(TEST_DIR + f)
	DirAccess.remove_absolute(OUT)
	print("[ai_editor_smoke] 스크린샷 %d장, 실패 %d → %s" % [_shot, _fail, ProjectSettings.globalize_path("user://ai_editor_smoke")])
	get_tree().quit(1 if _fail > 0 else 0)


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _snap(name: String) -> void:
	await RenderingServer.frame_post_draw
	_shot += 1
	get_viewport().get_texture().get_image().save_png("user://ai_editor_smoke/%02d_%s.png" % [_shot, name])


func check(ok: bool, label: String) -> void:
	if ok:
		print("ok   ", label)
	else:
		_fail += 1
		print("FAIL ", label)
