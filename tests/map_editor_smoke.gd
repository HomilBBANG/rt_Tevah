extends Node
## 맵 에디터 스모크 테스트 (에디터 플러그인 화면을 게임 안에서 띄워 확인). user://test_maps/ 에 복사본으로 작업.
##   Godot_v4.7-stable_win64_console.exe --path . res://tests/map_editor_smoke.tscn

const Editor = preload("res://addons/map_editor/map_editor.gd")
const TEST_DIR := "user://test_maps/"

var _fail := 0
var ed: Node


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(TEST_DIR)
	for f in DirAccess.get_files_at(TEST_DIR):
		DirAccess.remove_absolute(TEST_DIR + f)
	for f in ["test_field", "basecamp", "test_travel", "test_arrive"]:
		var w := FileAccess.open(TEST_DIR + f + ".json", FileAccess.WRITE)
		w.store_string(FileAccess.get_file_as_string("res://tools/maps/%s.json" % f))
		w.close()
	var original: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(TEST_DIR + "test_field.json"))

	ed = Editor.new()
	ed.dir = TEST_DIR
	ed.set_anchors_preset(Control.PRESET_FULL_RECT)
	var bg := ColorRect.new()
	bg.color = Color(0.13, 0.14, 0.17)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	add_child(ed)
	await _frames(2)
	check(ed.files.item_count == 4, "맵 4개 목록")
	ed.open_map("test_field")
	await _frames(2)
	var cv = ed.canvas
	var legacy: bool = not original.objects.any(func(o): return o.type == "arrive")
	var n_tf: int = original.objects.size() + (1 if legacy else 0)
	check(ed.map.objects.size() == n_tf and ed.map.tiles.size() == original.tiles.size(), "test_field: 물체 %d, %d줄" % [n_tf, original.tiles.size()])
	check(not ed.canvas.default_p().is_empty() if legacy else true, "예전 형식 맵: 열면 P 자리가 ★ 기본 P 물체로")
	check(ed.enemies.size() == 1 and ed.dialogue_starts.size() >= 3 and ed.loot_spots.size() >= 3, "목록: 적·대화·Loot")

	# 열고 저장 → 그대로
	ed.save()
	var saved: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(TEST_DIR + "test_field.json"))
	var no_p := func(objs: Array) -> Array: return objs.filter(func(o): return o.type != "arrive")
	check(saved.tiles == original.tiles and no_p.call(saved.objects) == no_p.call(original.objects) and saved.start == original.start,
		"열고 저장 → 내용 그대로 (도착 P 외)")

	# 칠하기: 벽 → 바닥
	ed.set_tool("wall")
	cv.apply_tool(Vector2i(5, 6))
	check(not cv.is_floor(Vector2i(5, 6)), "벽 칠하기")
	ed.set_tool("floor")
	cv.apply_tool(Vector2i(5, 6))
	check(cv.is_floor(Vector2i(5, 6)), "바닥 칠하기")
	ed.set_tool("void")
	cv.apply_tool(Vector2i(5, 6))
	check(String(ed.map.tiles[6])[5] == " " and not cv.is_floor(Vector2i(5, 6)), "빈 공간 칠하기")
	ed.set_tool("floor")
	cv.apply_tool(Vector2i(5, 6))
	ed.set_tool("wall")
	cv.apply_tool(Vector2i(10, 1))   # NPC 1 자리
	check(cv.is_floor(Vector2i(10, 1)), "물체가 있는 칸은 벽으로 안 바뀜")

	# 적 놓기 → 세부 → 순찰
	ed.set_tool("enemy")
	cv.apply_tool(Vector2i(4, 7))
	var e: Dictionary = cv.selected
	check(e.type == "enemy" and e.object_id == "test_field_enemy_1" and ed.map.objects.size() == n_tf + 1, "적 놓기, ID 자동")
	ed.set_field(e, "ref", "enemy_test")
	ed.set_field(e, "patrol_dir", "right")
	ed.set_field(e, "patrol_len", 3)
	ed.set_tool("enemy")
	cv.apply_tool(Vector2i(4, 7))
	check(ed.map.objects.size() == n_tf + 1, "같은 칸에 또 못 놓음")
	# 선택 도구로 옮기기 (끌기 대신 직접)
	ed.set_tool("select")
	cv.apply_tool(Vector2i(4, 7))
	check(cv.selected == e, "선택")
	# 지우개
	ed.set_tool("erase")
	cv.apply_tool(Vector2i(3, 10))   # 조사 지점 2 (d)
	check(ed.map.objects.size() == n_tf, "지우개로 물체 삭제")
	# 회차 시작 위치 옮기기
	ed.set_tool("run_start")
	cv.apply_tool(Vector2i(20, 5))
	check(ed.map.run_start == [20, 5], "회차 시작 S 옮기기")
	await _frames(2)
	await _snap("test_field")

	ed.save()
	var after: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(TEST_DIR + "test_field.json"))
	var ne: Array = after.objects.filter(func(o): return o.object_id == "test_field_enemy_1")
	check(ne.size() == 1 and ne[0].patrol_dir == "right" and int(ne[0].patrol_len) == 3 and ne[0].ref == "enemy_test", "저장: 새 적의 순찰·종류")
	ed.open_map("basecamp")
	ed.open_map("test_field")
	check(ed.map.objects.size() == n_tf and ed.map.run_start == [20, 5], "다시 열면 그대로")

	# 맵 이동: 통로·이용·도착 지점·가장자리 (test_travel)
	ed.open_map("test_travel")
	await _frames(2)
	ed.canvas.select({})
	await _frames(2)
	var labels: Array = ed.inspector.find_children("*", "Label", true, false).map(func(l): return l.text)
	check("가장자리로 나가면" in labels and "왼쪽 →" in labels, "맵 설정에 가장자리 4방향")
	check(ed._arrive_options("test_arrive").any(func(a): return a[0] == "ta_from_ladder"), "도착 P 목록: test_arrive '사다리 아래'")
	await _snap("test_travel")
	var passage: Dictionary = ed.map.objects.filter(func(o): return o.type == "passage")[0]
	ed.canvas.select(passage)
	await _frames(2)
	await _snap("passage_selected")
	ed.save()
	var tt: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(TEST_DIR + "test_travel.json"))
	check(tt.edges.left.ref == "test_arrive" and tt.edges.down.ref == "basecamp", "저장: 가장자리 유지")
	# 도착 P 의 '이어지는 곳': test_arrive (★ 기본 P 없는 맵) '사다리 아래' ← test_travel 사다리
	ed.open_map("test_arrive")
	await _frames(2)
	check(ed.canvas.default_p().is_empty(), "베이스캠프가 아니면 기본 P 없어도 됨")
	var gate: Dictionary = ed.map.objects.filter(func(o): return o.object_id == "ta_from_ladder")[0]
	ed.canvas.select(gate)
	await _frames(2)
	var boxes: Array = ed.inspector.find_children("*", "CheckBox", true, false)
	var checked: Array = boxes.filter(func(b): return b.button_pressed).map(func(b): return b.text)
	# 체크박스: 기본 P 1 + 들어오는 곳 2 (test_travel 사다리, test_travel 왼쪽 가장자리)
	check(boxes.size() == 3 and checked.size() == 1 and "사다리" in checked[0], "도착 P: 이어지는 곳 목록, 사다리 체크 (%s)" % [checked])
	await _snap("arrive_p")
	var other: CheckBox = boxes.filter(func(b): return not b.button_pressed and not "기본 P" in b.text)[0]
	other.button_pressed = true
	check(gate.from.size() == 2, "체크하면 이어지는 곳 추가")
	other.button_pressed = false
	check(gate.from.size() == 1, "체크 풀면 빠짐")
	ed.save()
	var ta: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(TEST_DIR + "test_arrive.json"))
	check(ta.objects.filter(func(o): return o.object_id == "ta_from_ladder")[0].from == ["tt_ladder"], "저장: 이어지는 곳 유지")
	# 기본 P 켜고 끄기 (베이스캠프가 아니면 자유)
	ed.canvas.select(gate)
	await _frames(2)
	var dcb: CheckBox = ed.inspector.find_children("*", "CheckBox", true, false).filter(func(b): return "기본 P" in b.text)[0]
	dcb.button_pressed = true
	check(ed.canvas.default_p() == gate, "기본 P 켜기")
	await _frames(1)
	dcb = ed.inspector.find_children("*", "CheckBox", true, false).filter(func(b): return "기본 P" in b.text)[0]
	dcb.button_pressed = false
	check(ed.canvas.default_p().is_empty(), "기본 P 끄기 (베이스캠프 아님)")
	ed.undo()
	ed.undo()
	check(ed.canvas.default_p().is_empty() and ed.map.objects.size() == 3, "실행 취소")
	# 베이스캠프: 기본 P 필수 — 마지막 기본 P 는 못 지움
	ed.open_map("basecamp")
	await _frames(1)
	var bc_p: Dictionary = ed.canvas.default_p()
	ed.canvas.select(bc_p)
	ed.delete_selection()
	check(not bc_p.is_empty() and ed.canvas.default_p() == bc_p, "베이스캠프: 마지막 기본 P 는 못 지움")
	ed.new_map("t_p", 8, 6)
	var only_p: Dictionary = ed.map.objects[0]
	check(only_p.type == "arrive" and ed.canvas.default_p().is_empty(), "새 맵: P 하나 (기본 아님)")
	ed.canvas.select(only_p)
	ed.delete_selection()
	check(ed.map.objects.is_empty(), "베이스캠프가 아니면 P 지우기 가능")

	# ---------- 편집 기능: 실행 취소 · 사각형 · 영역 선택 · 복사/붙여넣기 · 묶음 편집 · 연결 · 목록 · 검색 · 필터
	ed.open_map("test_field")
	await _frames(2)
	cv = ed.canvas
	var before_tiles: Array = ed.map.tiles.duplicate()
	ed.set_tool("wall")
	cv.stroke_started.emit()
	cv.fill_rect(Rect2i(14, 5, 3, 2))   # 바닥 위 3x2 사각형 벽
	check(String(ed.map.tiles[5]).substr(14, 3) == "###" and String(ed.map.tiles[6]).substr(14, 3) == "###", "사각형 채우기 (벽 3x2)")
	ed.undo()
	check(ed.map.tiles == before_tiles, "실행 취소 → 원래대로")
	ed.redo()
	check(String(ed.map.tiles[5]).substr(14, 3) == "###", "다시 실행")
	ed.undo()
	# 영역 선택 → 복사 → 붙여넣기 (조사 지점 2개가 든 영역)
	var looks: Array = cv.objects_in(Rect2i(8, 5, 4, 2))
	cv.select_many(looks, Rect2i(8, 5, 4, 2))
	check(cv.selection.size() == 2, "영역 선택: 물체 2개")
	await _frames(1)
	var sel_labels: Array = ed.inspector.find_children("*", "Label", true, false).map(func(l): return l.text)
	check("2개 선택" in sel_labels, "여러 개 고르면 묶음 편집 칸")
	ed.copy_selection()
	var n0: int = ed.map.objects.size()
	ed.paste_at(Vector2i(20, 9))
	check(ed.map.objects.size() == n0 + 2 and cv.selection.size() == 2 and cv.selection[0].object_id != looks[0].object_id
		and int(cv.selection[0].x) == 20, "붙여넣기: 새 ID 로 2개, (20, 9) 부터")
	await _snap("pasted")
	ed.undo()
	check(ed.map.objects.size() == n0, "붙여넣기 실행 취소")
	# 묶음 편집: 적 2명 고르고 순찰 방향 한꺼번에
	var foes: Array = ed.map.objects.filter(func(o): return o.type == "enemy")
	cv.select_many(foes)
	await _frames(1)
	ed._multi_option(foes, "순찰 방향", [["", "-"], ["up", "위"]], "patrol_dir")
	ed.checkpoint("x")
	for o in foes:
		o.patrol_dir = "up"
	check(foes.all(func(o): return o.patrol_dir == "up"), "묶음 편집: 적 2명 순찰 방향")
	ed.undo()
	check(not foes.is_empty(), "묶음 편집 실행 취소")
	# 삭제 → 실행 취소
	var npc1: Dictionary = ed.map.objects.filter(func(o): return o.object_id == "fo_npc1")[0]
	cv.select(npc1)
	ed.delete_selection()
	check(not ed.map.objects.any(func(o): return o.object_id == "fo_npc1"), "선택 삭제")
	ed.undo()
	check(ed.map.objects.any(func(o): return o.object_id == "fo_npc1"), "삭제 실행 취소")
	# 연결 표시: 문 → 베이스캠프, 잘못된 연결은 경고
	var door: Dictionary = ed.map.objects.filter(func(o): return o.object_id == "fo_to_camp")[0]
	check(cv.link_labels.fo_to_camp[1] and "basecamp" in cv.link_labels.fo_to_camp[0], "문 연결 표시: %s" % cv.link_labels.fo_to_camp[0])
	ed.set_field(door, "ref", "no_such_map")
	check(not cv.link_labels.fo_to_camp[1], "없는 맵 → 경고 (%s)" % cv.link_labels.fo_to_camp[0])
	ed.undo()
	check(cv.link_labels.fo_to_camp[1], "실행 취소로 연결 복구")
	# 맵 목록 · 검색
	check(ed.map_list.item_count >= 3 and "→ basecamp" in ed.map_list.get_item_text(ed.map_ids.find("test_field")), "맵 목록에 이어지는 맵")
	ed.search.text = "고양이"
	ed._run_search()
	check(ed.results.item_count == 1 and ed.results.get_item_metadata(0) == ["basecamp", "fo_cat"], "검색: 고양이 → basecamp")
	ed.goto_object("basecamp", "fo_cat")
	check(ed.map.map_id == "basecamp" and cv.selected.object_id == "fo_cat", "검색 결과로 이동·선택")
	ed.search.text = ""
	ed._run_search()
	# 문 따라가기: test_travel 통로 → 베이스캠프 정문 P
	ed.open_map("test_travel")
	var pass_o: Dictionary = ed.map.objects.filter(func(o): return o.type == "passage")[0]
	ed.follow_link(pass_o)
	check(ed.map.map_id == "basecamp" and cv.selected.get("object_id", "") == "basecamp_p", "통로 더블클릭 → 베이스캠프 기본 P (★)")
	ed.open_map("test_travel")
	var ladder: Dictionary = ed.map.objects.filter(func(o): return o.type == "transit")[0]
	check("사다리 아래" in cv.link_labels[ladder.object_id][0], "사다리 연결 표시: %s" % cv.link_labels[ladder.object_id][0])
	ed.follow_link(ladder)
	check(ed.map.map_id == "test_arrive" and cv.selected.get("object_id", "") == "ta_from_ladder", "사다리 더블클릭 → test_arrive '사다리 아래' P")
	check(cv.link_labels.ta_from_ladder[0].begins_with("← ") and cv.link_labels.ta_from_ladder[1], "P 연결 표시: %s" % cv.link_labels.ta_from_ladder[0])
	# 기본 P 없는 맵에 이어지지 않은 입구 → 경고 (test_travel 왼쪽 가장자리의 이어짐을 잠시 뺌)
	var edge_p: Dictionary = ed.map.objects.filter(func(o): return o.object_id == "ta_from_edge")[0]
	ed.set_field(edge_p, "from", [])
	ed.open_map("test_travel")
	check(not cv.link_labels["edge:left"][1], "기본 P 없는 맵에 이어지지 않은 가장자리 → ⚠ (%s)" % cv.link_labels["edge:left"][0])
	ed.open_map("test_arrive")
	edge_p = ed.map.objects.filter(func(o): return o.object_id == "ta_from_edge")[0]
	ed.set_field(edge_p, "from", ["test_travel:left"])
	ed.save()
	ed.open_map("basecamp")
	# 표시 필터: NPC 끄면 안 보이고 못 고름
	ed.filter_boxes.npc.button_pressed = false
	check(cv.visible_object_at(Vector2i(9, 2)).is_empty() and not cv.object_at(Vector2i(9, 2)).is_empty(), "필터: NPC 숨김 → 고를 수 없음")
	await _snap("filtered")
	ed.filter_boxes.npc.button_pressed = true
	ed.open_map("test_field")

	# 새 맵 · 크기 바꾸기
	check(ed.new_map("t_new", 12, 8), "새 맵 만들기")
	check(ed.map.tiles.size() == 8 and String(ed.map.tiles[0]) == "############" and ed.map.start == [6, 4], "새 맵: 테두리 벽, P 가운데")
	ed.resize_map(16, 6)
	check(ed.map.tiles.size() == 6 and String(ed.map.tiles[0]).length() == 16, "크기 바꾸기")
	check(not ed.new_map("bad id!", 5, 5), "잘못된 ID 거부")
	await _snap("new_map")

	# 변환·검사 (실제 프로젝트 데이터 — 원본 tools/maps 는 안 건드림)
	check(ed.run_convert() and "변환 완료" in ed.log_view.text, "변환·검사 실행")

	for f in DirAccess.get_files_at(TEST_DIR):
		DirAccess.remove_absolute(TEST_DIR + f)
	print("[map_editor_smoke] 실패 %d" % _fail)
	get_tree().quit(1 if _fail > 0 else 0)


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _snap(name: String) -> void:
	await RenderingServer.frame_post_draw
	DirAccess.make_dir_recursive_absolute("user://map_editor_smoke")
	get_viewport().get_texture().get_image().save_png("user://map_editor_smoke/%s.png" % name)


func check(ok: bool, label: String) -> void:
	print(("ok   " if ok else "FAIL ") + label)
	if not ok:
		_fail += 1
