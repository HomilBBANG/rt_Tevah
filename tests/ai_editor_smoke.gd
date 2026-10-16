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
	check(ed.key_refs("BB_Infected", "HasLineOfSight").size() == 2, "키를 쓰는 곳 2개 (Engage·Chase Decorator): %s" % [ed.key_refs("BB_Infected", "HasLineOfSight")])
	check(ed.key_refs("BB_Infected", "TargetLocation").size() == 1, "Task 의 키 (MoveTo target_key) 도 쓰는 곳")
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
	check(out.assets.size() == 2, "Compile 결과에 자산 2개")

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
