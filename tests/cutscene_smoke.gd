extends Node
## 컷신 스모크 (창 필요): 🎬 연출 카드 + 이벤트 칸. 테스트 전용 작은 맵과 대화를 DataLoader 에 넣어서 쓴다 (실제 데이터 안 건드림).
## 스크린샷 user://cutscene_smoke/.
##   Godot_v4.7-stable_win64_console.exe --path . res://tests/cutscene_smoke.tscn

const Direction = preload("res://core/direction.gd")
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
	check(not f._try_event(Vector2i(4, 2)) and not f._try_event(Vector2i(2, 4)), "이벤트 영역(2×2) 밖은 안 밟힘")
	check(f._try_event(Vector2i(3, 3)) and f._dialogue_ui != null and f.frozen, "이벤트 영역 안 아무 칸 → 대화(컷신) 시작, 플레이어 못 움직임")
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
	# ---- 바라보는 방향: 맵의 face, 걸으면 가는 쪽, '바라보기'
	check(npc.node.facing == Vector2.UP, "NPC 는 마지막으로 걸은 쪽을 봄 (벽을 돌아 (6,3)→(6,2) = 위): %s" % npc.node.facing)
	# ---- 소리 + 바라보기 + 건너뛰기 (긴 컷신을 건너뛰면 바로 끝난 모습, 선택지에서 멈춤)
	f._start_dialogue({"data": {"ref": "tcut_long"}})
	await _wait(0.4)
	check(Sound.music_file == "test_loop.wav", "배경음 틀기 (audio/bgm/test_loop.wav)")
	check(f._dialogue_ui.skip_btn.visible, "컷신 중 '건너뛰기' 버튼")
	await _snap("04_skip_button")
	var t0 := Time.get_ticks_msec()
	f._dialogue_ui.skip()
	await _until(func(): return f._dialogue_ui and f._dialogue_ui.get_node("%Choices").get_child_count() > 0, 3.0)
	var took := Time.get_ticks_msec() - t0
	await _wait(0.1)   # 선택지가 뜬 다음 프레임에 건너뛰기가 멈춘다
	var nt := Vector2i(floori(npc.node.position.x / f.tile), floori(npc.node.position.y / f.tile))
	check(took < 1500 and nt == Vector2i(2, 5) and npc.node.facing == Vector2.UP and GameState.node_id == "tcut_long_q",
		"건너뛰기: %dms 만에 끝난 모습 (NPC (2,5)·위를 봄), 대사 넘기고 선택지에서 멈춤" % took)
	check(not f._dialogue_ui.skipping and Sound.music_file == "", "선택지에서 건너뛰기 멈춤, 배경음 끄기도 적용됨")
	await StoryRunner.choose("tcut_long_c")
	await _until(func(): return f._dialogue_ui == null, 2.0)
	# 카메라: 시작 위치(from)에서 바로 → 플레이어까지 천천히 → 도착하면 다시 따라감
	var cam: Camera2D = f._camera()
	var cam_done := [false]
	var go := func():
		await f._direct_step({"do": "camera", "who": "player", "from": [9, 0], "time": 0.6})
		cam_done[0] = true
	go.call()
	await get_tree().process_frame
	var start_at := cam.global_position
	check(cam.top_level and start_at.is_equal_approx(f._clamp_cam(f._tile_center(9, 0))) and not cam.position_smoothing_enabled,
		"카메라 시작 위치: from 칸에서 바로 (맵 끝 안으로), 연출 중엔 부드럽게 따라가기 끔")
	await _wait(0.3)
	check(not cam_done[0], "그다음 플레이어 쪽으로 '시간' 동안 움직이는 중 (작은 테스트 맵은 화면보다 작아 위치는 같음)")
	await _until(func(): return cam_done[0], 2.0)
	check(cam_done[0] and not cam.top_level and cam.position_smoothing_enabled, "플레이어에 닿으면 다시 따라감")
	# 위아래 띠: 플레이 중엔 없고, 대화·연출 중에만
	var lb: Control = f.get_node("HUD/Letterbox")
	check(not lb.is_open(), "플레이 중에는 위아래 띠 없음")
	# 확대: 도트 배율 한 단계씩 (5 → 7), 기다리지 않기
	var zdone := [false]
	var zgo := func():
		await f._direct_step({"do": "zoom", "scale": 7, "time": 0.4, "wait": true})
		zdone[0] = true
	zgo.call()
	await _wait(0.25)
	check(f.zoom_px() == 6, "확대 중간: ×6 (딱 떨어지는 배율만 거침) — %d" % f.zoom_px())
	await _until(func(): return zdone[0], 2.0)
	check(f.zoom_px() == 7 and is_equal_approx(f._camera().zoom.x, 7.0 / 5.0), "확대 끝: ×7")
	var cam_t0 := Time.get_ticks_msec()
	await f._direct_step({"do": "camera", "to": [3, 3], "time": 1.0, "wait": false})
	check(Time.get_ticks_msec() - cam_t0 < 100, "카메라 '기다리지 않음': 바로 다음 단계")
	# 계속 흔들기 → 멈춤
	f._direct_step({"do": "shake", "power": 1.0, "time": 0.0, "speed": 20})
	await _wait(0.3)
	var shaking: bool = f._camera().offset != Vector2.ZERO
	await f._direct_step({"do": "shake_off"})
	await _wait(0.1)
	check(shaking and f._camera().offset == Vector2.ZERO, "시간 0 = 계속 흔들림, '흔들기 멈춤'으로 멈춤")
	# 인물 따라가기: NPC 로 가서 그 NPC 가 걸으면 계속 따라감
	await f._direct_step({"do": "camera", "who": "tcut_npc", "time": 0.0, "follow": true})
	check(f._cam_target == npc.node, "카메라가 NPC 를 따라감")
	f._reset_camera_fx()
	f._camera_follow()
	check(f._cam_target == null and f.zoom_px() == 5, "대화가 끝나면 확대·따라가기 원래대로")
	# 덮인 화면으로 시작: 첫 연출이 검게 덮기면 처음부터 검게 (자동 시작 컷신 — 맵이 먼저 보이지 않게)
	DataLoader.nodes["tcut_cover"] = {"node_id": "tcut_cover", "kind": "direct", "speaker_id": "", "text": "", "next_node": "EXIT", "on_enter": "",
		"episode_id": "", "steps": [{"do": "fade", "to": "black", "time": 0.3}, {"do": "fade", "to": "clear", "time": 0.1}]}
	check(Direction.opening_cover("tcut_cover").get("layer", "") == "fade" and Direction.opening_cover("tcut_b").is_empty(), "덮인 화면 판단: 첫 단계가 검게 덮기")
	f._start_dialogue({"data": {"ref": "tcut_cover"}}, true)
	check(f._dialogue_ui.fade.color.a == 1.0, "자동 시작 컷신은 처음 프레임부터 검은 화면")
	check(lb.is_open() or lb.get_node("Top").anchor_bottom >= 0.0, "대화가 시작되면 띠가 밀려 들어옴")
	await _wait(0.4)
	check(lb.is_open() and not f._dialogue_ui.get_node("Letterbox").visible, "대화·연출 중 띠 (필드의 띠 하나만)")
	await _until(func(): return f._dialogue_ui == null, 3.0)
	DataLoader.nodes.erase("tcut_cover")
	await _wait(0.4)
	check(not lb.is_open(), "대화가 끝나면 띠가 빠짐")
	# 도착 칸이 이벤트 영역 안이면 들어오자마자 (문을 나서자마자 컷신)
	f.map.objects.filter(func(o): return o.type == "event")[0].once = false
	DataLoader.maps["tcut_map"].start = [3, 3]
	f.load_map("tcut_map")
	await _wait(0.2)
	check(f._dialogue_ui != null, "맵에 들어오자마자 도착 칸의 이벤트 시작")
	await _until(func(): return f._dialogue_ui == null or not f._dialogue_ui.directing, 6.0)
	for i in 20:
		if f._dialogue_ui == null:
			break
		f._dialogue_ui.advance()
		await _wait(0.2)
	DataLoader.maps["tcut_map"].start = [2, 4]
	f.queue_free()
	await _wait(0.1)
	# ---- 오프닝 컷신: 캐릭터 생성 직후 필드가 열리면 Config opening_dialogue 를 한 번
	var keep_open: Variant = DataLoader.config.get("opening_dialogue", "")
	DataLoader.config["opening_dialogue"] = "tcut_img"
	var keep_triggers: Dictionary = DataLoader.triggers
	DataLoader.triggers = {}   # 실제 데이터의 자동 시작(테스트 오프닝 등)은 빼고
	GameState.opening_pending = true
	FieldScript.next_map_id = "tcut_map"
	f = load("res://scenes/field/field.tscn").instantiate()
	add_child(f)
	await _wait(0.4)
	check(f._dialogue_ui != null and not GameState.opening_pending and GameState.node_id in ["tcut_img", "tcut_img_line"], "새 게임 → 필드가 열리자마자 오프닝 컷신")
	f._dialogue_ui.skip()
	await _until(func(): return f._dialogue_ui == null, 3.0)
	check(f._dialogue_ui == null and not f.frozen, "오프닝을 건너뛰면 바로 조작 가능")
	DataLoader.config["opening_dialogue"] = keep_open
	DataLoader.triggers = keep_triggers
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
		"objects": [obj.call("tcut_npc", "npc", 9, 2, "tcut_b"), obj.call("tcut_event", "event", 2, 2, "tcut_a").merged({"w": 2, "h": 2}, true)], "edges": {}}
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
	node.call("tcut_long", "direct", "tcut_long_1", {"steps": [
		{"do": "music", "file": "test_loop.wav", "fade": 0.2, "volume": 50},
		{"do": "sound", "file": "test_beep.wav", "volume": 80},
		{"do": "wait", "time": 5.0},
		{"do": "walk", "who": "tcut_npc", "to": [2, 5], "speed": 1.0},
		{"do": "face", "who": "tcut_npc", "dir": "up"},
		{"do": "image", "file": "test_cg.png", "fade": 3.0},
		{"do": "music_off", "fade": 2.0}]})
	node.call("tcut_long_1", "", "tcut_long_2", {"text": "(테스트) 건너뛰면 넘어가는 대사 1"})
	node.call("tcut_long_2", "", "tcut_long_q", {"text": "(테스트) 건너뛰면 넘어가는 대사 2"})
	node.call("tcut_long_q", "", "", {"text": "(테스트) 선택지에서는 멈춤"})
	DataLoader.choices_by_node["tcut_long_q"] = [{"choice_id": "tcut_long_c", "node_id": "tcut_long_q", "text": "(테스트) 끝", "condition": "",
		"show_mode": "", "cost": "", "effects": "", "next_node": "EXIT", "type": "normal", "check": "", "dc": 0, "mod": 0, "fail_effects": "", "fail_next": ""}]


func _cleanup() -> void:
	DataLoader.maps.erase("tcut_map")
	for id in ["tcut_a", "tcut_b", "tcut_img", "tcut_img_line", "tcut_img_off", "tcut_long", "tcut_long_1", "tcut_long_2", "tcut_long_q"]:
		DataLoader.nodes.erase(id)
	DataLoader.choices_by_node.erase("tcut_long_q")
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
