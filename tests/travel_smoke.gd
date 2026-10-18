extends Node
## 맵 이동 스모크 테스트 (더미 맵 test_travel): 통로(밟으면) · 이용(사다리, E) · 가장자리(왼쪽·아래) · 효과 move: · 도착 지점.
## 화면이 필요하므로 --headless 없이:
##   Godot_v4.7-stable_win64_console.exe --path . res://tests/travel_smoke.tscn

const FieldScript = preload("res://scenes/field/field.gd")
## 테스트 전용 맵 복사본 — tools/maps 의 test_ 맵을 고쳐도 이 테스트는 안 깨진다
const FIX := "res://tests/fixtures/maps/"

var _fail := 0
var f: Node


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute("user://travel_smoke")
	_load_fixture_maps()
	SaveManager.save_dir = "user://test_saves/"
	SaveManager.delete_all()
	SaveManager.begin_run()
	GameState.wake_at_run_start = false
	FieldScript.next_map_id = "test_travel"
	f = load("res://scenes/field/field.tscn").instantiate()
	add_child(f)
	await _wait(0.3)
	check(f.map.map_id == "test_travel" and _at(4, 2), "test_travel 의 P(4,2)에서 시작")
	await _snap("test_travel")

	# 통로: 밟으면 베이스캠프 — 이어진 P 가 없으니 기본 P(★)
	var bc_p: Array = DataLoader.maps.basecamp.start
	await _walk_to(6, 2)
	check(f.map.map_id == "basecamp" and _at(bc_p[0], bc_p[1]), "통로 → 베이스캠프 기본 P 도착 (%s)" % _where())

	# 이용(사다리): 옆에서 E → test_field 의 P
	f.load_map("test_travel")
	await _wait(0.2)
	_teleport(2, 2)
	await _wait(0.2)
	check("이용: 사다리" in f.get_node("%Prompt").text, "사다리 근처 → '이용: 사다리' 안내 (%s)" % f.get_node("%Prompt").text)
	_press("interact")
	await _wait(0.2)
	check(f.map.map_id == "test_arrive" and _at(2, 2), "E → test_arrive '사다리 아래' P(2,2) — P 쪽 이어지는 곳 (%s)" % _where())

	# 가장자리: 왼쪽 끝(0,1) → test_field, 아래 끝(4,5) → 베이스캠프 정문
	f.load_map("test_travel")
	await _wait(0.2)
	await _walk_to(0, 1)
	check(f.map.map_id == "test_arrive" and _at(4, 2), "왼쪽 가장자리 → test_arrive '서쪽 길' P(4,2) (%s)" % _where())
	f.load_map("test_travel")
	await _wait(0.2)
	await _walk_to(4, 5)
	check(f.map.map_id == "basecamp" and _at(bc_p[0], bc_p[1]), "아래 가장자리 → 베이스캠프 기본 P (%s)" % _where())

	# 도착 지점에 서 있어도 바로 다시 이동하지 않는다 (통로 위 도착 → 한 번 벗어나야 작동)
	f.travel("test_travel", "tt_center")
	await _wait(0.2)
	check(f.map.map_id == "test_travel" and _at(4, 3), "travel(도착 지점 tt_center) → (4,3)")

	# 효과 move: (대화·아이템) — 대화 밖이면 바로
	await StoryRunner.run_effects("move:test_arrive@ta_from_ladder")
	await _wait(0.2)
	check(f.map.map_id == "test_arrive" and _at(2, 2), "효과 move:test_arrive@ta_from_ladder → 그 P (%s)" % _where())
	await StoryRunner.run_effects("move:test_travel")
	await _wait(0.2)
	check(f.map.map_id == "test_travel" and _at(4, 2), "효과 move:test_travel → P (%s)" % _where())
	await _snap("after_move")
	# 대화 중 move: 대화가 끝난 뒤 이동
	f._dialogue_ui = Control.new()
	f.add_child(f._dialogue_ui)
	f._on_travel_requested("basecamp", "")
	await _wait(0.1)
	check(f.map.map_id == "test_travel", "대화 중에는 바로 이동하지 않음")
	f._on_dialogue_finished()
	await _wait(0.1)
	check(f.map.map_id == "basecamp" and _at(bc_p[0], bc_p[1]), "대화가 끝나면 이동 (%s)" % _where())

	# 이어지는 맵 (가장자리 seamless): 아래로 나가면 저쪽 맵 위쪽 같은 자리(+어긋남)로, 도착 P 가 아니라
	var mk := func(id: String, tiles: Array, edges: Dictionary) -> Dictionary:
		return {"map_id": id, "width": String(tiles[0]).length(), "height": tiles.size(), "tiles": tiles, "start": [1, 1], "run_start": [1, 1],
			"edges": edges, "objects": [], "visual": {"layers": {}}}
	DataLoader.maps["seam_a"] = mk.call("seam_a", ["##########", "#........#", "#........#", "#........#", "#........#"],
		{"down": {"ref": "seam_b", "arrive": "", "seamless": true, "offset": 2}})
	DataLoader.maps["seam_b"] = mk.call("seam_b", ["##############", "#............#", "#............#", "#..##........#", "#............#", "##############"], {})
	f.travel("seam_a")
	await _wait(0.2)
	f.player.position = Vector2(3.4 * f.tile, 3.5 * f.tile)
	await get_tree().physics_frame
	Input.action_press("move_down")
	var tt := 0.0
	while f.map.map_id == "seam_a" and tt < 1.5:
		await get_tree().physics_frame
		tt += get_physics_process_delta_time()
	Input.action_release("move_down")
	check(f.map.map_id == "seam_b" and absf(f.player.position.x / f.tile - 5.4) < 0.05 and floori(f.player.position.y / f.tile) == 1,
		"이어지는 맵: 아래로 나가면 저쪽 맵 맨 위 바닥 줄, x 그대로 + 어긋남 2 (%s)" % _where())
	for i in 10:
		await get_tree().physics_frame
	check(f.map.map_id == "seam_b", "도착하자마자 되돌아가지 않음")
	# 같은 자리가 막혔으면 옆 칸: x 1.4 + 2 = 3.4 → (3,1) 은 바닥, (3,3) 벽은 상관없음. 맨 위 줄이 다 막힌 칸이면 옆으로
	DataLoader.maps["seam_b"].tiles[1] = "#..##........#"
	f.travel("seam_a")
	await _wait(0.2)
	f.player.position = Vector2(1.6 * f.tile, 4.5 * f.tile)
	GameState.arrive_edge = {"dir": "down", "along": 3.6}
	f.travel("seam_b")
	await _wait(0.1)
	check(f.map.map_id == "seam_b" and Vector2i(floori(f.player.position.x / f.tile), floori(f.player.position.y / f.tile)) in [Vector2i(3, 2), Vector2i(2, 1), Vector2i(5, 1)],
		"이어지는 자리가 벽이면 안쪽·옆 바닥으로 (%s)" % _where())
	DataLoader.maps.erase("seam_a")
	DataLoader.maps.erase("seam_b")

	SaveManager.delete_all()
	DataLoader.load_all()   # 진짜 데이터로 되돌림
	print("[travel_smoke] 실패 %d" % _fail)
	get_tree().quit(1 if _fail > 0 else 0)


## 복사본 맵을 변환기 결과와 같은 모양으로 DataLoader 에 넣는다 (start = 기본 P → 첫 P → start)
func _load_fixture_maps() -> void:
	for f in DirAccess.get_files_at(FIX):
		if not f.ends_with(".json"):
			continue
		var m: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(FIX + f))
		var objs := []
		var start = m.get("start")
		var first_p = null
		for o in m.objects:
			var c: Dictionary = o.duplicate(true)
			c.x = int(o.x)
			c.y = int(o.y)
			c.patrol_len = int(o.get("patrol_len", 0))
			c.schedule = _schedule(str(o.get("schedule", "")))
			c.from = o.get("from", [])
			c.default = o.get("default", false)
			for k in ["condition", "arrive", "ref", "name", "text", "patrol_dir"]:
				c[k] = str(o.get(k, ""))
			if c.type == "arrive":
				if c.default:
					start = [c.x, c.y]
				elif first_p == null:
					first_p = [c.x, c.y]
			objs.append(c)
		if not m.objects.any(func(o): return o.type == "arrive" and o.get("default", false)) and first_p != null:
			start = first_p
		start = [int(start[0]), int(start[1])]
		var w := 0
		for row in m.tiles:
			w = maxi(w, String(row).length())
		DataLoader.maps[m.map_id] = {"map_id": m.map_id, "width": w, "height": m.tiles.size(), "tiles": m.tiles,
			"start": start, "run_start": m.run_start if m.get("run_start") != null else start, "objects": objs,
			"edges": m.get("edges", {})}


## "06:00-12:00, 20:00-23:00" → [[360, 720], [1200, 1380]]
func _schedule(t: String) -> Array:
	var out := []
	for part in t.split(",", false):
		var ab := part.strip_edges().split("-")
		if ab.size() == 2:
			var a := ab[0].split(":")
			var b := ab[1].split(":")
			out.append([int(a[0]) * 60 + int(a[1]), int(b[0]) * 60 + int(b[1])])
	return out


## (x, y) 칸 바로 옆에 두고 그 칸으로 걸어 들어간다 (실제 이동·충돌로)
func _walk_to(x: int, y: int) -> void:
	var from := Vector2i(x, y)
	var key := ""
	for d in [[Vector2i(1, 0), "move_left"], [Vector2i(-1, 0), "move_right"], [Vector2i(0, -1), "move_down"], [Vector2i(0, 1), "move_up"]]:
		var t: Vector2i = from + d[0]
		if t.y >= 0 and t.y < f.map.tiles.size() and t.x >= 0 and t.x < String(f.map.tiles[t.y]).length() and f.map.tiles[t.y][t.x] == ".":
			_teleport(t.x, t.y)
			key = d[1]
			break
	await _wait(0.1)
	var start_map: String = f.map.map_id
	Input.action_press(key)
	# 맵이 바뀌면 바로 키를 뗀다 (도착한 뒤 더 걸어가지 않게)
	var t := 0.0
	while f.map.map_id == start_map and t < 0.8:
		await get_tree().physics_frame
		t += get_physics_process_delta_time()
	Input.action_release(key)
	await get_tree().physics_frame
	await get_tree().physics_frame


func _at(x: int, y: int) -> bool:
	return f.player.position.distance_to(Vector2((x + 0.5) * f.tile, (y + 0.5) * f.tile)) < 2.0


func _where() -> String:
	return "%s (%.1f, %.1f)" % [f.map.map_id, f.player.position.x / f.tile - 0.5, f.player.position.y / f.tile - 0.5]


func _teleport(tx: float, ty: float) -> void:
	f.player.position = Vector2((tx + 0.5) * f.tile, (ty + 0.5) * f.tile)


func _press(action: String) -> void:
	var ev := InputEventAction.new()
	ev.action = action
	ev.pressed = true
	Input.parse_input_event(ev)


func _wait(sec: float) -> void:
	await get_tree().create_timer(sec).timeout


func _snap(name: String) -> void:
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("user://travel_smoke/%s.png" % name)


func check(ok: bool, label: String) -> void:
	print(("ok   " if ok else "FAIL ") + label)
	if not ok:
		_fail += 1
