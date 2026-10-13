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
	for f in ["test_field", "basecamp"]:
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
	check(ed.files.item_count == 2, "맵 2개 목록")
	ed.open_map("test_field")
	await _frames(2)
	var cv = ed.canvas
	check(ed.map.objects.size() == 9 and ed.map.tiles.size() == 13, "test_field: 물체 9, 13줄")
	check(ed.enemies.size() == 1 and ed.dialogue_starts.size() >= 3 and ed.loot_spots.size() >= 3, "목록: 적·대화·Loot")

	# 열고 저장 → 그대로
	ed.save()
	var saved: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(TEST_DIR + "test_field.json"))
	check(saved.tiles == original.tiles and saved.objects == original.objects and saved.start == original.start, "열고 저장 → 내용 그대로")

	# 칠하기: 벽 → 바닥
	ed.set_tool("wall")
	cv.apply_tool(Vector2i(5, 6))
	check(not cv.is_floor(Vector2i(5, 6)), "벽 칠하기")
	ed.set_tool("floor")
	cv.apply_tool(Vector2i(5, 6))
	check(cv.is_floor(Vector2i(5, 6)), "바닥 칠하기")
	ed.set_tool("wall")
	cv.apply_tool(Vector2i(10, 1))   # NPC 1 자리
	check(cv.is_floor(Vector2i(10, 1)), "물체가 있는 칸은 벽으로 안 바뀜")

	# 적 놓기 → 세부 → 순찰
	ed.set_tool("enemy")
	cv.apply_tool(Vector2i(4, 7))
	var e: Dictionary = cv.selected
	check(e.type == "enemy" and e.object_id == "test_field_enemy_1" and ed.map.objects.size() == 10, "적 놓기, ID 자동")
	ed.set_field(e, "ref", "enemy_test")
	ed.set_field(e, "patrol_dir", "right")
	ed.set_field(e, "patrol_len", 3)
	ed.set_tool("enemy")
	cv.apply_tool(Vector2i(4, 7))
	check(ed.map.objects.size() == 10, "같은 칸에 또 못 놓음")
	# 선택 도구로 옮기기 (끌기 대신 직접)
	ed.set_tool("select")
	cv.apply_tool(Vector2i(4, 7))
	check(cv.selected == e, "선택")
	# 지우개
	ed.set_tool("erase")
	cv.apply_tool(Vector2i(3, 10))   # 조사 지점 2 (d)
	check(ed.map.objects.size() == 9, "지우개로 물체 삭제")
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
	check(ed.map.objects.size() == 9 and ed.map.run_start == [20, 5], "다시 열면 그대로")

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
