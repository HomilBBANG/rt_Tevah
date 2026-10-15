extends Node
## 컷신 스모크 (창 필요): 🎬 연출 카드 + 이벤트 칸. 테스트 전용 작은 맵과 대화를 DataLoader 에 넣어서 쓴다 (실제 데이터 안 건드림).
## 스크린샷 user://cutscene_smoke/.
##   Godot_v4.7-stable_win64_console.exe --path . res://tests/cutscene_smoke.tscn

const FieldScript = preload("res://scenes/field/field.gd")

var _fail := 0


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute("user://cutscene_smoke")
	DataLoader.config["text_speed_default"] = "instant"
	SaveManager.save_dir = "user://test_saves/"
	SaveManager.delete_all()
	SaveManager.begin_run()
	_inject()
	FieldScript.next_map_id = "tcut_map"
	var f: Node = load("res://scenes/field/field.tscn").instantiate()
	add_child(f)
	await _wait(0.3)
	var npc: Dictionary = f.npcs.filter(func(n): return n.data.object_id == "tcut_npc")[0]
	# ---- 인게임 컷신: 이벤트 칸을 밟으면 시작
	check(f.events.size() == 1, "이벤트 칸 1개 (화면에 안 보임)")
	check(f._try_event(Vector2i(2, 2)) and f._dialogue_ui != null and f.frozen, "이벤트 칸 → 대화(컷신) 시작, 플레이어 못 움직임")
	await _wait(0.15)
	check(f._dialogue_ui.directing and not f._dialogue_ui.get_node("%Bubble").visible, "연출 중: 대사 상자 숨김")
	await _wait(0.25)
	check(f._camera().top_level, "카메라가 플레이어를 떠나 지정 칸으로")
	await _snap("01_camera_moved")
	await _until(func(): return not f._dialogue_ui.directing, 6.0)
	var npc_tile := Vector2i(floori(npc.node.position.x / f.tile), floori(npc.node.position.y / f.tile))
	check(npc_tile == Vector2i(6, 2) and npc.pos == npc.node.position, "NPC 가 벽을 돌아 (6,2)까지 걸어옴: %s" % npc_tile)
	var p_tile := Vector2i(floori(f.player.position.x / f.tile), floori(f.player.position.y / f.tile))
	check(p_tile == Vector2i(3, 4), "플레이어도 (3,4)로 걸음: %s" % p_tile)
	check(GameState.node_id == "tcut_b" and f._dialogue_ui.get_node("%Bubble").visible, "연출이 끝나면 다음 카드의 대사")
	await _snap("02_after_walk")
	f._dialogue_ui.advance()
	await _wait(0.3)
	check(f._dialogue_ui == null and not f.frozen and not f._camera().top_level, "대화가 끝나면 조작 가능, 카메라는 다시 플레이어")
	check(not f._try_event(Vector2i(2, 2)) and GameState.field_has("tcut_map", "done", "tcut_event"), "한 번만: 다시 밟아도 안 나옴 (회차 상태에 기록)")
	# ---- 그림 컷신: 그림을 띄우고 그 위에 대사
	f._start_dialogue({"data": {"ref": "tcut_img"}})
	await _until(func(): return f._dialogue_ui and not f._dialogue_ui.directing and GameState.node_id == "tcut_img_line", 3.0)
	var ui: Control = f._dialogue_ui
	check(ui.cg.visible and ui.cg.texture != null and is_equal_approx(ui.cg.modulate.a, 1.0) and ui.get_node("%SituationBox").visible,
		"그림(art/cutscenes/test_cg.png)을 띄우고 그 위에 대사")
	await _snap("03_image")
	ui.advance()
	await _until(func(): return f._dialogue_ui == null, 3.0)
	check(f._dialogue_ui == null, "그림 내리고 대화 끝")
	f.queue_free()
	_cleanup()
	print("[cutscene_smoke] 실패 %d" % _fail)
	get_tree().quit(1 if _fail > 0 else 0)


## 테스트 맵 (12x7, x=7 에 벽이 있어 NPC 는 돌아가야 함) + 대화
func _inject() -> void:
	var tiles := ["############", "#......#...#", "#......#...#", "#..........#", "#..........#", "#..........#", "############"]
	var obj := func(id: String, type: String, x: int, y: int, ref := "") -> Dictionary:
		return {"object_id": id, "type": type, "ref": ref, "name": id, "text": "", "condition": "", "arrive": "", "from": [],
			"default": false, "once": type == "event", "map_id": "tcut_map", "x": x, "y": y, "patrol_dir": "", "patrol_len": 0, "schedule": []}
	DataLoader.maps["tcut_map"] = {"map_id": "tcut_map", "width": 12, "height": 7, "tiles": tiles, "start": [2, 4], "run_start": [2, 4],
		"objects": [obj.call("tcut_npc", "npc", 9, 2, "tcut_b"), obj.call("tcut_event", "event", 2, 2, "tcut_a")], "edges": {}}
	var node := func(id: String, kind: String, next: String, extra := {}) -> Dictionary:
		var n := {"node_id": id, "kind": kind, "speaker_id": "", "text": "", "next_node": next, "on_enter": "", "pages": [], "episode_id": ""}
		n.merge(extra, true)
		DataLoader.nodes[id] = n
		return n
	node.call("tcut_a", "direct", "tcut_b", {"steps": [
		{"do": "camera", "to": [8, 2], "time": 0.2},
		{"do": "walk", "who": "tcut_npc", "to": [6, 2], "speed": 12, "wait": false},
		{"do": "walk", "who": "player", "to": [3, 4], "speed": 12},
		{"do": "wait", "time": 0.6},
		{"do": "fade", "to": "black", "time": 0.1},
		{"do": "fade", "to": "clear", "time": 0.1}]})
	node.call("tcut_b", "", "EXIT", {"speaker_id": "char_npc", "text": "(테스트) 컷신 대사"})
	node.call("tcut_img", "direct", "tcut_img_line", {"steps": [{"do": "image", "file": "test_cg.png", "fade": 0.2}]})
	node.call("tcut_img_line", "", "tcut_img_off", {"text": "(테스트) 그림 위 대사"})
	node.call("tcut_img_off", "direct", "EXIT", {"steps": [{"do": "image_off", "fade": 0.1}]})


func _cleanup() -> void:
	DataLoader.maps.erase("tcut_map")
	for id in ["tcut_a", "tcut_b", "tcut_img", "tcut_img_line", "tcut_img_off"]:
		DataLoader.nodes.erase(id)
	SaveManager.delete_all()


func _until(cond: Callable, timeout: float) -> void:
	var t := 0.0
	while not cond.call() and t < timeout:
		await _wait(0.05)
		t += 0.05


func _wait(sec: float) -> void:
	await get_tree().create_timer(sec).timeout


func _snap(name: String) -> void:
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("user://cutscene_smoke/%s.png" % name)


func check(ok: bool, label: String) -> void:
	print(("ok   " if ok else "FAIL ") + label)
	if not ok:
		_fail += 1
