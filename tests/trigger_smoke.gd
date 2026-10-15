extends Node
## 자동 시작 컷신 스모크 (창 필요): 로고 → 타이틀 이전 → 타이틀 → 타이틀 이후 → (캐릭터 생성) → 새 게임 시작 후 → 방 진입 후.
## 테스트 전용 노드·트리거를 DataLoader 에 넣어서 쓴다. 장면이 바뀌어도 이 노드는 남도록 current_scene 에서 뺀다.
##   Godot_v4.7-stable_win64_console.exe --path . res://tests/trigger_smoke.tscn

const FieldScript = preload("res://scenes/field/field.gd")
const Triggers = preload("res://core/cutscene_triggers.gd")

var _fail := 0


func _ready() -> void:
	DataLoader.config["text_speed_default"] = "instant"
	SaveManager.save_dir = "user://test_saves/"
	SaveManager.delete_all()
	DirAccess.remove_absolute(Triggers._cfg_path())
	_inject()
	await get_tree().process_frame
	_detach()
	# ---- 켜기: 로고(한 번만) → 타이틀 이전 → 타이틀
	get_tree().change_scene_to_file("res://scenes/boot.tscn")
	await _until(func(): return _scene_name() == "CutscenePlayer", 2.0)
	check(_scene_name() == "CutscenePlayer" and GameState.node_id == "trg_logo", "켜면 로고 컷신부터 (%s)" % GameState.node_id)
	await _advance_until(func(): return GameState.node_id == "trg_before")
	check(GameState.node_id == "trg_before", "로고 다음 타이틀 이전 컷신")
	await _snap("01_before_title")
	await _advance_until(func(): return _scene_name() == "Title")
	check(_scene_name() == "Title", "컷신이 끝나면 타이틀")
	_detach()
	# 다시 켜기: 로고는 '처음 켤 때만' → 건너뜀, 타이틀 이전은 매번
	get_tree().change_scene_to_file("res://scenes/boot.tscn")
	await _until(func(): return _scene_name() == "CutscenePlayer", 2.0)
	check(GameState.node_id == "trg_before", "다시 켜면 로고(한 번만)는 건너뛰고 타이틀 이전부터")
	await _advance_until(func(): return _scene_name() == "Title")
	_detach()
	# ---- 타이틀 이후: 새 게임 → 컷신 → 캐릭터 생성
	await _wait(0.2)
	get_tree().current_scene.get_node("%NewRunButton").pressed.emit()
	await _until(func(): return _scene_name() == "CutscenePlayer", 2.0)
	check(GameState.node_id == "trg_after", "타이틀에서 새 게임 → 타이틀 이후 컷신")
	await _advance_until(func(): return _scene_name() == "CharacterCreation")
	check(_scene_name() == "CharacterCreation", "그다음 캐릭터 생성")
	_detach()
	# ---- 새 게임 시작 후 → 방 진입 후 (테스트 맵)
	GameState.create_character([])
	GameState.opening_pending = true
	SaveManager.begin_run()
	FieldScript.next_map_id = "trg_map"
	get_tree().change_scene_to_file("res://scenes/field/field.tscn")
	await _until(func(): return _scene_name() == "Field" and get_tree().current_scene._dialogue_ui != null, 3.0)
	var f: Node = get_tree().current_scene
	_detach()
	check(GameState.node_id == "trg_new", "필드가 열리면 '새 게임 시작 후'가 먼저 (%s)" % GameState.node_id)
	f._dialogue_ui.advance()
	await _until(func(): return f._dialogue_ui != null and GameState.node_id == "trg_room", 2.0)
	check(GameState.node_id == "trg_room" and f.frozen, "그다음 '방 진입 후' (이 맵)")
	f._dialogue_ui.advance()
	await _until(func(): return f._dialogue_ui == null, 2.0)
	check(f._dialogue_ui == null and not f.frozen, "다 끝나면 조작 가능")
	f.load_map("trg_map")   # 같은 회차에 다시 들어옴 → 한 번만이라 안 나옴
	await _wait(0.3)
	check(f._dialogue_ui == null, "방 진입(그 회차에 한 번만)은 다시 안 나옴")
	f.queue_free()
	_cleanup()
	print("[trigger_smoke] 실패 %d" % _fail)
	get_tree().quit(1 if _fail > 0 else 0)


func _inject() -> void:
	var line := func(id: String, text: String) -> void:
		DataLoader.nodes[id] = {"node_id": id, "kind": "", "speaker_id": "", "text": text, "next_node": "EXIT", "on_enter": "",
			"pages": [{"display": "subtitle", "text": text}], "episode_id": ""}
	for id in ["trg_logo", "trg_before", "trg_after", "trg_new", "trg_room"]:
		line.call(id, "(테스트) " + id)
	DataLoader.triggers = {
		"logo": [{"node_id": "trg_logo", "map": "", "once": true}],
		"before_title": [{"node_id": "trg_before", "map": "", "once": false}],
		"after_title": [{"node_id": "trg_after", "map": "", "once": false}],
		"new_game": [{"node_id": "trg_new", "map": "", "once": true}],
		"map_enter": [{"node_id": "trg_room", "map": "trg_map", "once": true}],
	}
	DataLoader.maps["trg_map"] = {"map_id": "trg_map", "width": 6, "height": 5, "tiles": ["######", "#....#", "#....#", "#....#", "######"],
		"start": [2, 2], "run_start": [2, 2], "objects": [], "edges": {}, "visual": {"layers": {}}, "environment": {"profile": "outdoor"}}


func _cleanup() -> void:
	DataLoader.load_all()
	SaveManager.delete_all()
	DirAccess.remove_absolute(Triggers._cfg_path())


## 이 테스트 노드가 장면 전환에 지워지지 않게: current_scene 을 다른 것으로
func _detach() -> void:
	if get_tree().current_scene == self:
		var dummy := Node.new()
		get_tree().root.add_child(dummy)
		get_tree().current_scene = dummy


func _scene_name() -> String:
	var cs := get_tree().current_scene
	return String(cs.name) if cs else ""


func _advance_until(cond: Callable) -> void:
	for i in 40:
		if cond.call():
			return
		var cs := get_tree().current_scene
		if cs and cs.get("ui") and is_instance_valid(cs.ui):
			cs.ui.advance()
		await _wait(0.1)


func _until(cond: Callable, timeout: float) -> void:
	var t := 0.0
	while not cond.call() and t < timeout:
		await _wait(0.05)
		t += 0.05


func _wait(sec: float) -> void:
	await get_tree().create_timer(sec).timeout


func _snap(name: String) -> void:
	await RenderingServer.frame_post_draw
	DirAccess.make_dir_recursive_absolute("user://trigger_smoke")
	get_viewport().get_texture().get_image().save_png("user://trigger_smoke/%s.png" % name)


func check(ok: bool, label: String) -> void:
	print(("ok   " if ok else "FAIL ") + label)
	if not ok:
		_fail += 1
