extends Node
## 몬스터 AI(BT) 필드 스모크 (창 필요): 맵 test_ai 의 감염자(BT_Infected_Field)가 실제 필드에서
## 순찰 → 발견하면 추격(순찰 중단) → 닿으면 턴제 전투(한 번만) → 도주 유예 동안 못 봄 → 수색 → 순찰로 돌아가는지.
## 같은 맵의 예전 AI 적(bt 없음)이 그대로 동작하는지도. 스크린샷 user://ai_field_smoke/.
##   Godot_v4.7-stable_win64_console.exe --path . res://tests/ai_field_smoke.tscn

var _shot := 0
var _fail := 0
var f: Node


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute("user://ai_field_smoke")
	SaveManager.save_dir = "user://test_saves/"
	SaveManager.delete_all()
	SaveManager.begin_run()
	preload("res://scenes/field/field.gd").next_map_id = "test_ai"
	var bt_asset: Dictionary = DataLoader.ai_assets.BT_Infected_Field
	check(bt_asset.get("battle_on_contact", false), "샘플 BT 는 '닿으면 바로 전투' 켬")
	bt_asset.battle_on_contact = false   # 먼저 끄고: 전투는 트리의 EnterTurnBattle 로만
	f = load("res://scenes/field/field.tscn").instantiate()
	add_child(f)
	await _wait(0.3)
	var inf: Node = _enemy("ai_infected")
	var old: Node = _enemy("ai_old")
	check(inf != null and inf.bt != null and old != null and old.bt == null, "BT 를 정한 적만 BT 로 (예전 AI 적은 그대로)")
	check(inf.bt.bb.get_value("VisionRange") == 4.0 and inf.bt.bb.last_source.VisionRange == "Editor Override", "맵의 bb_overrides → 시야 4칸 (개체별)")
	var y0: float = inf.position.y
	await _wait(1.0)
	check(inf.bt.task_node == "patrol" and inf.position.y > y0 + f.tile * 0.5, "멀면 순찰 (아래로 %.1f 칸)" % ((inf.position.y - y0) / f.tile))
	await _snap("patrol")
	var snap: Dictionary = f.ai_snapshot()
	check(snap.map == "test_ai" and snap.monsters.size() == 1 and snap.monsters[0].id == "ai_infected" and snap.monsters[0].snap.task == "patrol",
		"디버거로 보낼 상태: BT 몬스터만 (예전 AI 적은 빠짐)")
	var ev := InputEventKey.new()
	ev.keycode = KEY_F9
	ev.pressed = true
	Input.parse_input_event(ev)
	await _wait(0.1)
	check(f.ai_debug, "F9 → 몬스터 머리 위에 지금 Task 표시")
	await _snap("f9_debug")

	# 발견 → 추격
	var et: Vector2 = inf.ai_tile()
	_teleport(et.x - 3, et.y)
	await _wait(0.4)
	check(inf.bt.task_node in ["move_to_target", "battle"] and inf.bt.last_result.get("patrol") == "ABORTED",
		"3칸 앞에 보이면 Chase 가 Patrol 을 선점 (%s, patrol=%s)" % [inf.bt.task_node, inf.bt.last_result.get("patrol")])
	check(inf.state == "chase", "추격 표시(!)")
	await _snap("chase")
	# 닿으면 전투 (한 번만)
	var ok := await _wait_until(func(): return f._combat_ui != null, 5.0)
	check(ok and f._combat_enemy == inf and inf.bt.memory.get("battle_pending", false), "가까워지면 Engage → EnterTurnBattle → 턴제 전투")
	await _wait(0.5)
	check(f.frozen and inf.bt.log.filter(func(e): return e.node == "battle" and e.ev == "exit").size() == 1, "전투 중엔 필드가 멈추고 전투 요청은 한 번")
	await _snap("battle")
	# 도주 → 유예 동안 못 봄 → 마지막 위치 수색 → 순찰
	await _end_combat("fled")
	check(not f.frozen and inf.grace > 0.0 and not inf.bt.memory.has("battle_pending"), "도주 → 유예, 전투 잠금 풀림")
	_teleport(1, 1)
	await _wait(0.5)
	check(inf.bt.task_node == "search_last" and not inf.bt.bb.get_value("HasLineOfSight"), "유예 동안 못 봄 → 마지막 위치 수색 (%s)" % inf.bt.task_node)
	ok = await _wait_until(func(): return inf.bt.task_node == "patrol", 12.0)
	check(ok and not inf.bt.bb.get_value("HasLastKnownLocation"), "수색을 마치면 순찰로 돌아감")
	check(f._combat_ui == null, "멀리 있으면 다시 덤비지 않음")
	await _snap("back_to_patrol")
	old.grace = 999.0   # 비교용 예전 AI 적은 자기 차례까지 쉬게 (근처라 먼저 덤비지 않게)
	# 벽 뒤에서는 못 봄 (기둥 x6~8, y3~4)
	_teleport(7, 5)
	inf.position = f._tile_center(7, 2)
	await _wait(0.4)
	check(not inf.bt.bb.get_value("HasLineOfSight"), "기둥 너머(가까워도)는 안 보임")

	# '닿으면 바로 전투' 켬: 못 보는 상태(시야 0)여도 닿으면 전투
	bt_asset.battle_on_contact = true
	inf.bt.bb.set_value("VisionRange", 0.0, "Editor Override")
	await _wait_until(func(): return inf.grace == 0.0, 5.0)   # 도주 유예 동안은 닿아도 전투 안 함
	_teleport_to(inf)
	ok = await _wait_until(func(): return f._combat_ui != null, 2.0)
	check(ok and f._combat_enemy == inf and not inf.bt.memory.get("battle_pending", false), "켜면 닿는 순간 전투 (트리의 전투 Task 없이)")
	await _end_combat("fled")
	bt_asset.battle_on_contact = false
	await _wait_until(func(): return inf.grace == 0.0, 5.0)   # 도주 유예가 끝난 뒤에
	_teleport_to(inf)
	await _wait(0.5)
	check(f._combat_ui == null, "끄면 닿아도 전투 안 함 (못 보는 동안)")
	# 몬스터별 (맵 물체 touch_battle) 이 BT 설정보다 먼저
	inf.data.touch_battle = "on"   # BT 는 끔
	_teleport_to(inf)
	ok = await _wait_until(func(): return f._combat_ui != null, 2.0)
	check(ok and f._combat_enemy == inf, "몬스터별 '켬' → BT 가 꺼져 있어도 닿으면 전투")
	await _end_combat("fled")
	await _wait_until(func(): return inf.grace == 0.0, 5.0)
	bt_asset.battle_on_contact = true
	inf.data.touch_battle = "off"   # BT 는 켬
	_teleport_to(inf)
	await _wait(0.5)
	check(f._combat_ui == null, "몬스터별 '끔' → BT 가 켜져 있어도 닿아도 전투 안 함")
	inf.data.touch_battle = ""
	bt_asset.battle_on_contact = false
	_teleport(1, 1)

	# 예전 AI 적: 닿으면 바로 전투 (그대로)
	inf.position = f._tile_center(14, 6)
	inf.grace = 999.0
	old.grace = 0.0
	_teleport_to(old)
	ok = await _wait_until(func(): return f._combat_ui != null, 2.0)
	check(ok and f._combat_enemy == old, "예전 AI 적은 닿으면 바로 전투 (그대로)")
	await _end_combat("win")
	check(not old in f.enemies and inf in f.enemies, "이기면 그 적만 사라짐")

	# 맵 다시 불러오기 → BT 정리 (오류 없음)
	var r: RefCounted = inf.bt
	f.load_map("test_ai")
	await _wait(0.2)
	check(r.stack.is_empty() and r.task == null, "맵을 다시 불러오면 이전 몬스터의 BT 는 멈춤")
	check(_enemy("ai_infected") != null and _enemy("ai_infected").bt != r, "새 몬스터는 새 실행 상태")

	# Task Graph (BT_03_Stalker 의 수색 = BTT_SearchLastPosition) 도 실제 필드에서
	for o in DataLoader.maps.test_ai.objects:
		if o.object_id == "ai_infected":
			o.bt = "BT_03_Stalker"
	f.load_map("test_ai")
	await _wait(0.2)
	var st: Node = _enemy("ai_infected")
	_teleport(1, 6)
	st.bt.bb.set_value("LastKnownLocation", Vector2(9, 1), "Sensor")
	st.bt.bb.set_value("HasLastKnownLocation", true, "Sensor")
	await _wait_until(func(): return st.bt.task_node == "search_last", 8.0)   # 수색의 Decorator 는 Self 라 순찰 한 구간이 끝난 뒤에 바뀜
	check(st.bt.task_node == "search_last" and st.bt.task.get_script().resource_path.ends_with("task_graph_runner.gd"), "필드에서 수색 = Task Graph 실행 (%s)" % st.bt.task_node)
	var gtask: Object = st.bt.task
	ok = await _wait_until(func(): return st.bt.task_node == "patrol", 12.0)
	check(ok and gtask.result == 0 and st.ai_tile().distance_to(Vector2(9, 1)) < 3.0 and not st.bt.bb.get_value("HasLastKnownLocation"),
		"그래프: 마지막 위치까지 걸어가 둘러보고 Finish Execute → 순찰 (%s)" % [gtask.trace])
	for o in DataLoader.maps.test_ai.objects:
		if o.object_id == "ai_infected":
			o.bt = "BT_Infected_Field"

	# ---------- Phase 6: 소리 (BT_02_HearAndSearch — 달리기·문 소리를 들으면 확인하러 감)
	for o in DataLoader.maps.test_ai.objects:
		if o.object_id == "ai_infected":
			o.bt = "BT_02_HearAndSearch"
	f.load_map("test_ai")
	await _wait(0.2)
	var hs: Node = _enemy("ai_infected")
	hs.position = f._tile_center(12, 6)
	_teleport(1, 6)   # 멀리 (시야 밖)
	await _wait(0.3)
	check(not hs.bt.bb.get_value("HasLineOfSight"), "소리 테스트: 처음엔 못 봄")
	Input.action_press("run")
	Input.action_press("move_right")
	await _wait(0.4)
	Input.action_release("move_right")
	Input.action_release("run")
	await _wait(0.1)
	var heard: bool = hs.bt.bb.get_value("HasHeardNoise") or hs.bt.task_node == "move_noise"
	check(not heard, "달린 곳이 6칸 밖이면 못 들음")
	hs.position = f._tile_center(7, 1)   # 기둥(x6~8, y3~4) 위 — 가깝지만 안 보임
	_teleport(7, 6)
	Input.action_press("run")
	Input.action_press("move_left")
	await _wait(0.4)
	Input.action_release("move_left")
	Input.action_release("run")
	ok = await _wait_until(func(): return hs.bt.task_node == "move_noise", 2.0)
	var nl = hs.bt.bb.get_value("NoiseLocation")
	check(ok and nl != null and nl.distance_to(hs._to_tile(f.player.global_position)) < 3.0, "6칸 안에서 달리면 들음 → 순찰을 멈추고 소리 난 곳으로 (%s)" % hs.bt.task_node)
	_teleport(1, 1)
	ok = await _wait_until(func(): return hs.bt.task_node == "patrol" and hs.bt.last_result.get("listen") == "SUCCESS", 10.0)
	check(ok, "소리 난 곳을 둘러본 뒤 순찰로 (%s %s %s)" % [hs.bt.task_node, hs.bt.last_result, hs.bt.log.slice(-6).map(func(e): return "%s %s %s %s" % [e.ev, e.node, e.result, e.reason])])
	hs.bt.bb.set_value("HasHeardNoise", false)
	f.make_noise(hs.global_position - Vector2(f.tile * 3, 0), 5)
	ok = await _wait_until(func(): return hs.bt.task_node in ["move_noise", "listen"], 1.0)
	check(ok, "문 소리 등 make_noise 도 들음 → 확인하러 감 (%s)" % hs.bt.task_node)
	# 빛: 손전등을 들면 더 멀리서 봄 (시야 4칸 × 1.5)
	hs.bt.bb.set_value("HasHeardNoise", false)
	hs.position = f._tile_center(14, 6)
	hs.bt.set_paused(false)
	_teleport(9, 6)   # 5칸
	f.ai_paused = true   # 몬스터를 멈추고 감지만 비교
	var far: Dictionary = hs.ai_perceive(4.0)
	GameState.add_item("flashlight", 1)
	var fi := GameState.inventory.find_custom(func(sl): return sl.id == "flashlight")
	GameState.equip(fi)
	await _wait(0.1)
	var lit: Dictionary = hs.ai_perceive(4.0)
	check(not far.visible and lit.visible and is_equal_approx(f.sight_mult(), 1.5), "손전등을 들면 5칸 앞에서도 보임 (시야 4 × 1.5)")
	f.ai_paused = false

	# ---------- Phase 6: 맵 간 추적 — 쫓던 몬스터가 몇 초 뒤 같은 곳으로 따라 들어옴
	DataLoader.config["ai_follow_delay"] = 1.0
	_teleport(11, 6)
	ok = await _wait_until(func(): return hs.state == "chase", 2.0)
	check(ok, "추격 중")
	f.travel("basecamp")
	await _wait(0.2)
	check(GameState.field_has("test_ai", "gone", "ai_infected") and f.enemies.is_empty() and f._follow_queue.size() == 1, "다른 맵으로 가면 쫓던 몬스터는 원래 맵을 떠나 따라오는 중")
	ok = await _wait_until(func(): return not f.enemies.is_empty(), 3.0)
	var fol: Node = f.enemies[0] if ok else null
	check(ok and fol.data.object_id == "ai_infected" and fol.bt != null and Vector2i(fol.data.x, fol.data.y) == f._arrive_tile
		and GameState.followers("basecamp").size() == 1, "1초 뒤 들어온 곳으로 따라 들어옴 (BT 그대로)")
	if f._combat_ui != null:
		await _end_combat("fled")
	f.load_map("basecamp")
	await _wait(0.2)
	check(f.enemies.size() == 1, "따라온 몬스터는 그 맵에 남음 (다시 들어와도)")
	f.travel("test_ai")
	await _wait(0.2)
	check(_enemy("ai_infected") == null, "원래 맵에는 없음 (떠났으니)")
	GameState.field_state.erase("test_ai")
	GameState.field_state.erase("basecamp")
	# follow = off 면 안 따라옴
	for o in DataLoader.maps.test_ai.objects:
		if o.object_id == "ai_infected":
			o.follow = "off"
	f.load_map("test_ai")
	await _wait(0.2)
	var nf: Node = _enemy("ai_infected")
	nf.position = f._tile_center(12, 6)
	_teleport(10, 6)
	await _wait_until(func(): return nf.state == "chase", 2.0)
	f.travel("basecamp")
	await _wait(1.5)
	check(f.enemies.is_empty() and not GameState.field_has("test_ai", "gone", "ai_infected"), "맵 에디터 '따라오기 끔' 이면 안 따라옴")
	for o in DataLoader.maps.test_ai.objects:
		if o.object_id == "ai_infected":
			o.bt = "BT_Infected_Field"
			o.erase("follow")
	SaveManager.delete_all()
	print("[ai_field_smoke] 스크린샷 %d장, 실패 %d → %s" % [_shot, _fail, ProjectSettings.globalize_path("user://ai_field_smoke")])
	get_tree().quit(1 if _fail > 0 else 0)


func _enemy(oid: String) -> Node:
	for e in f.enemies:
		if is_instance_valid(e) and e.data.object_id == oid:
			return e
	return null


func _end_combat(outcome: String) -> void:
	var ui: Node = f._combat_ui
	ui.combat.outcome = outcome
	ui._finish()
	await _wait(0.05)
	ui.get_node("%TitleButton").pressed.emit()
	await _wait(0.1)


func _teleport(tx: float, ty: float) -> void:
	f.player.position = Vector2((tx + 0.5) * f.tile, (ty + 0.5) * f.tile)


func _teleport_to(node: Node2D) -> void:
	f.player.position = node.position + Vector2(4, 0)


func _wait(sec: float) -> void:
	await get_tree().create_timer(sec).timeout


func _wait_until(cond: Callable, limit: float) -> bool:
	var t := 0.0
	while t < limit:
		if cond.call():
			return true
		await get_tree().create_timer(0.05).timeout
		t += 0.05
	return cond.call()


func _snap(name: String) -> void:
	await RenderingServer.frame_post_draw
	_shot += 1
	get_viewport().get_texture().get_image().save_png("user://ai_field_smoke/%02d_%s.png" % [_shot, name])


func check(ok: bool, label: String) -> void:
	if ok:
		print("ok   ", label)
	else:
		_fail += 1
		print("FAIL ", label)
