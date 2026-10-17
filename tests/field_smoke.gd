extends Node
## 탐험 필드 스모크 테스트 (더미 맵 test_field 기준). 실제 물리·입력으로 진행하며 user://field_smoke/ 에 스크린샷.
## 화면이 필요하므로 --headless 없이:
##   Godot_v4.7-stable_win64_console.exe --path . res://tests/field_smoke.tscn

var _shot := 0
var _fail := 0
var f: Node


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute("user://field_smoke")
	seed(3)
	DataLoader.config["text_speed_default"] = "instant"   # 대사가 한 자씩 나오지 않게 (타이핑은 script_play_smoke)
	DataLoader.config["basecamp_map"] = "basecamp"   # 엑셀 Config 에서 베이스캠프를 바꿔도 테스트는 basecamp 맵으로
	SaveManager.save_dir = "user://test_saves/"
	SaveManager.delete_all()
	SaveManager.begin_run()
	var scene: PackedScene = load("res://scenes/field/field.tscn")
	preload("res://scenes/field/field.gd").next_map_id = "test_field"
	f = scene.instantiate()
	add_child(f)
	await _wait(0.3)
	check(f.enemies.size() == 2 and f.spots.size() == 5, "맵 로드: 적 2, 조사 4 + 출구 1")
	await _snap("start")

	# 이동: 오른쪽으로 0.5초 → 약 2칸 (4칸/초)
	var x0: float = f.player.position.x
	Input.action_press("move_right")
	await _wait(0.5)
	Input.action_release("move_right")
	check(f.player.position.x - x0 > f.tile * 1.5, "오른쪽 이동 (%.0f px)" % (f.player.position.x - x0))
	check(is_equal_approx(f.player.speed, 4 * f.tile) and is_equal_approx(f.player.run_speed, 6 * f.tile),
		"이동 속도 = Player 시트 걷기 4 · 달리기 6 (칸/초)")
	check(is_equal_approx(f.enemies[0].patrol_speed, 2 * f.tile) and is_equal_approx(f.enemies[0].chase_speed, 3.2 * f.tile),
		"적 속도 = Npcs 시트 걷기(순찰) 2 · 달리기(추격) 3.2")
	var x1: float = f.player.position.x
	Input.action_press("run")
	Input.action_press("move_left")
	await _wait(0.5)
	Input.action_release("move_left")
	Input.action_release("run")
	check(x1 - f.player.position.x > f.tile * 2.3, "Shift 달리기: 0.5초에 약 3칸 (%.0f px)" % (x1 - f.player.position.x))
	f.player.position.x = x1
	# 벽: 위쪽은 벽이라 못 올라감
	var y0: float = f.player.position.y
	Input.action_press("move_up")
	await _wait(0.4)
	Input.action_release("move_up")
	check(f.player.position.y >= f.tile * 1.2, "위쪽 벽에 막힘 (y=%.0f)" % f.player.position.y)

	# 조사: 조사 지점 1 (8,6) 옆으로 옮기고 E
	_teleport(7, 6)
	await _wait(0.15)
	check(f.get_node("%Prompt").visible, "조사 지점 근처 → 안내 표시")
	await _snap("near_spot")
	_press("interact")
	await _wait(0.1)
	check(f.get_node("%MessagePanel").visible and f.frozen, "조사 → 메시지, 이동 멈춤")
	check(GameState.item_count("knife") == 1, "조사 지점 1 → 칼 획득 (Loot spot_b, 100%)")
	await _snap("investigate")
	_press("interact")
	await _wait(0.1)
	check(not f.frozen, "메시지 닫기")

	# NPC 대화: NPC 1 (10,1) 옆에서 E → 대화 화면이 필드 위에 뜸
	check(f.npcs.size() == 2, "NPC 2명")
	_teleport(9, 1)
	await _wait(0.15)
	check("대화: NPC 1" in f.get_node("%Prompt").text, "NPC 근처 → 대화 안내")
	_press("interact")
	await _wait(0.3)
	var dlg: Node = f._dialogue_ui
	check(dlg != null and f.frozen, "대화 화면 열림, 필드 멈춤")
	await _snap("npc_dialogue")
	await _press_button(dlg, "[아이템] 칼 보여주기")
	await _snap("npc_protagonist_line")
	check(GameState.has_flag("showed_knife"), "아이템 선택지 → 플래그")
	dlg.advance()
	await _wait(0.2)
	check(f._dialogue_ui == null and not f.frozen, "EXIT → 필드로 복귀")
	# NPC 2 (10,9): NPC 1 대화에서 켠 플래그로 선택지가 열림
	_teleport(11, 9)
	await _wait(0.15)
	_press("interact")
	await _wait(0.3)
	dlg = f._dialogue_ui
	check(dlg != null and _find_button(dlg, "칼 이야기 (flag:showed_knife)") != null, "NPC 2: 플래그로 열린 선택지")
	await _snap("npc2_dialogue")
	await _press_button(dlg, "대화 끝내기")
	await _wait(0.2)
	check(f._dialogue_ui == null and not f.frozen, "대화 끝내기 → 복귀")
	# 대화 전투 선택지: 대화를 숨기고 전투 → 도주하면 대화 계속 (도주 노드)
	var body_before: Dictionary = GameState.player_body.duplicate(true)
	await _talk_and_fight()
	check(f._combat_ui != null and not f._dialogue_ui.visible and f.frozen, "대화 전투 선택지 → 전투, 대화 숨김")
	await _snap("dialogue_combat")
	await _end_combat("fled", func(_c): pass)
	check(f._dialogue_ui != null and f._dialogue_ui.visible and GameState.has_flag("fled_npc2"), "도주 → 대화로 돌아옴")
	await _snap("dialogue_after_flee")
	f._dialogue_ui.advance()
	await _wait(0.2)
	check(f._dialogue_ui == null and not f.frozen, "도주 노드 → EXIT → 필드")
	await _talk_and_fight()
	await _end_combat("win", func(_c): pass)
	check(f._dialogue_ui != null and GameState.has_flag("beat_npc2"), "승리 → 대화 계속 (승리 노드)")
	f._dialogue_ui.advance()
	await _wait(0.2)
	check(f._dialogue_ui == null and not f.frozen and f.enemies.size() == 2, "승리 후 필드, 맵의 적은 그대로")
	GameState.player_body = body_before

	# 닫힌 문은 시야를 가린다: 문 (2,2) 를 사이에 두고 적 (2,4) ↔ 플레이어 (2,1)
	var e0: Node = f.enemies[0]
	var e0_pos: Vector2 = e0.position
	var door: Dictionary = f.spots.filter(func(s): return s.kind == "exit")[0]
	e0.position = Vector2(2.5, 4.5) * f.tile
	_teleport(2, 1)
	await get_tree().physics_frame
	check(not e0._can_see(f.player.global_position), "닫힌 문 너머는 안 보임")
	f.toggle_door(door)
	await get_tree().physics_frame
	await get_tree().physics_frame
	check(door.open and e0._can_see(f.player.global_position), "문을 열면 보임")
	f.toggle_door(door)
	e0.position = e0_pos
	await get_tree().physics_frame

	# 추격: 적 1 (21,2) 시야 안, 벽 없는 곳으로
	var e1: Node = f.enemies[0]
	_teleport(floorf(e1.position.x / f.tile) - 3, 3)   # 같은 방, 3칸 옆 한 줄 아래
	await _wait(0.3)
	check(e1.state == "chase", "시야 안 → 추격 (%s)" % e1.state)
	await _snap("chase")

	# 전투 진입 → 도주
	await _wait_until(func(): return f._combat_ui != null, 4.0)
	check(f._combat_ui != null and f.frozen, "적과 닿음 → 전투")
	await _wait(0.3)
	await _snap("combat")
	await _end_combat("fled", func(c): c.player_parts.left_arm.hp = 7)
	check(f._combat_ui == null and not f.frozen and e1.grace > 0.0, "도주 → 필드 복귀, 적 유예")
	check(GameState.player_body.left_arm.hp == 7, "전투 피해가 필드에 이어짐")
	await _wait(0.1)
	await _snap("after_flee")

	# 승리 → 적 제거, 절단 상태 유지
	await _wait_until(func(): return e1.grace == 0.0, 5.0)
	_teleport_to(e1)
	await _wait_until(func(): return f._combat_ui != null, 2.0)
	check(f._combat_ui.combat.player_parts.left_arm.hp == 7, "다음 전투도 부상 상태로 시작")
	await _end_combat("win", func(c): c.player_parts.left_arm.broken = true; c.player_parts.left_arm.hp = 0)
	check(f.enemies.size() == 1 and GameState.player_body.left_arm.broken, "승리 → 적 제거, 왼팔 절단 유지")
	check("왼팔 절단" in f.get_node("%Body").text, "HUD 부상 표시: %s" % f.get_node("%Body").text)

	# 부활 아이템을 가진 채 사망 → 모두 유지한 채 베이스캠프에서 깨어남
	GameState.add_item("charm", 1)
	var items_before := GameState.inventory.size()
	_teleport_to(f.enemies[0])
	await _wait_until(func(): return f._combat_ui != null, 2.0)
	await _end_combat("lose", func(c): c.player_parts.head.hp = 0; c.player_parts.head.broken = true)
	await _wait(0.2)
	check(f.get_node("%DeathPanel").visible and f.get_node("%NewRunButton").text == "깨어난다", "부적으로 부활 → '깨어난다'")
	check("부활 텍스트 1" in f.get_node("%DeathMessage").text, "부활 문구 표시")
	check(f.get_node("%DeathMessage").text.begins_with("적 A (테스트)의 공격으로 인해 사망했습니다."),
		"사망 원인 문구 (전투): %s" % f.get_node("%DeathMessage").text)
	var clock_before := GameState.clock   # 사망 패널 동안 시간 멈춤
	await _snap("revive")
	f.get_node("%NewRunButton").pressed.emit()
	await _wait(0.2)
	check(f.map.map_id == "basecamp" and GameState.run_count == 1, "베이스캠프에서 깨어남, 회차 그대로")
	check(GameState.item_count("charm") == 0 and GameState.inventory.size() == items_before - 1, "부적만 소모, 소지품 유지")
	check(GameState.player_body.left_arm.broken and not GameState.player_body.head.broken, "잘린 왼팔 유지, 머리 회복")
	check(absf(GameState.clock - clock_before) < 1.0, "시간 유지 (깨어난 뒤 흐른 몇 초 제외)")
	var start: Array = f.map.start
	check(f.player.position.distance_to(Vector2((start[0] + 0.5) * f.tile, (start[1] + 0.5) * f.tile)) < 1.0, "베이스캠프 P 위치")

	# 부활 수단 없이 사망 → 게임 처음부터 (맵 한복판 S)
	f.load_map("test_field")
	await _wait(0.2)
	_teleport_to(f.enemies[0])
	await _wait_until(func(): return f._combat_ui != null, 2.0)
	await _end_combat("lose", func(_c): pass)
	await _wait(0.2)
	check(f.get_node("%DeathPanel").visible and f.get_node("%NewRunButton").text == "처음부터",
		"부활 수단 없음 → '처음부터'")
	await _snap("dead")
	f.get_node("%NewRunButton").pressed.emit()
	await _wait(0.2)
	var rs: Array = f.map.run_start
	check(GameState.run_count == 2 and f.map.map_id == "test_field" and not GameState.player_body.left_arm.broken
		and GameState.inventory.is_empty(), "처음부터 → 2회차, 소지품·몸 새로")
	check(f.player.position.distance_to(Vector2((rs[0] + 0.5) * f.tile, (rs[1] + 0.5) * f.tile)) < 1.0, "맵 한복판(S)에서 깨어남")

	# 사망 원인: 생존 수치 0 (Survival death_cause) / 효과 die:
	for c in [["hunger", "굶어 죽었습니다."], ["thirst", "탈수로 죽었습니다."]]:
		for p in DataLoader.survival:
			GameState.survival[p.param_id] = 50.0
		GameState.survival[c[0]] = 0.0
		await _wait(0.2)
		check(f.get_node("%DeathPanel").visible and f.get_node("%DeathMessage").text == c[1],
			"%s 0 → '%s' (%s)" % [c[0], c[1], f.get_node("%DeathMessage").text])
		f.get_node("%NewRunButton").pressed.emit()
		await _wait(0.2)
	check(GameState.get_survival("hunger") > 0.0 and GameState.death_cause_now() == "", "새 회차: 바로 다시 죽지 않음")
	GameState.survival["sleep"] = 0.0
	await _wait(0.2)
	check(not f.get_node("%DeathPanel").visible, "death_cause 가 빈 수치(수면)는 0 이어도 안 죽음")
	GameState.survival["sleep"] = 50.0
	await StoryRunner.run_effects("die:unknown")
	await _wait(0.2)
	check(f.get_node("%DeathPanel").visible and f.get_node("%DeathMessage").text == "알 수 없는 원인으로 인해 사망했습니다.",
		"효과 die: → 비어 있는 text 는 '(으)로 인해 사망했습니다.' (%s)" % f.get_node("%DeathMessage").text)
	f.get_node("%NewRunButton").pressed.emit()
	await _wait(0.2)

	# 대화 전투에서 지면 → 대화가 닫히고 사망 처리
	await _talk_and_fight()
	await _end_combat("lose", func(_c): pass)
	await _wait(0.2)
	check(f._dialogue_ui == null and f.get_node("%DeathPanel").visible and StoryRunner.ended and not StoryRunner.busy,
		"대화 전투 패배 → 대화 닫힘, 사망 패널")
	f.get_node("%NewRunButton").pressed.emit()
	await _wait(0.2)
	SaveManager.delete_all()
	print("[field_smoke] 스크린샷 %d장, 실패 %d → %s" % [_shot, _fail, ProjectSettings.globalize_path("user://field_smoke")])
	get_tree().quit(1 if _fail > 0 else 0)


## NPC 2 (10,9) 에게 말을 걸어 전투 선택지를 고른다
func _talk_and_fight() -> void:
	_teleport(11, 9)
	await _wait(0.15)
	_press("interact")
	await _wait(0.3)
	await _press_button(f._dialogue_ui, "[전투] 싸운다 (테스트)   (적 A (테스트))")
	await _wait(0.1)


func _end_combat(outcome: String, tweak: Callable) -> void:
	var ui: Node = f._combat_ui
	tweak.call(ui.combat)
	ui.combat.outcome = outcome
	ui._finish()
	await _wait(0.05)
	ui.get_node("%TitleButton").pressed.emit()   # 필드에서는 "계속"
	await _wait(0.1)


func _find_button(root: Node, text: String) -> Button:
	for c in root.find_children("*", "Button", true, false):
		if c.text == text and c.is_visible_in_tree():
			return c
	return null


func _press_button(root: Node, text: String) -> void:
	var b := _find_button(root, text)
	if b == null:
		check(false, "버튼 없음: " + text)
	else:
		b.pressed.emit()
	await _wait(0.2)


func _teleport(tx: float, ty: float) -> void:
	f.player.position = Vector2((tx + 0.5) * f.tile, (ty + 0.5) * f.tile)


func _teleport_to(node: Node2D) -> void:
	f.player.position = node.position + Vector2(4, 0)


func _press(action: String) -> void:
	var ev := InputEventAction.new()
	ev.action = action
	ev.pressed = true
	Input.parse_input_event(ev)


func _wait(sec: float) -> void:
	await get_tree().create_timer(sec).timeout


func _wait_until(cond: Callable, limit: float) -> void:
	var t := 0.0
	while not cond.call() and t < limit:
		await _wait(0.05)
		t += 0.05


func _snap(name: String) -> void:
	await RenderingServer.frame_post_draw
	_shot += 1
	get_viewport().get_texture().get_image().save_png("user://field_smoke/%02d_%s.png" % [_shot, name])


func check(ok: bool, label: String) -> void:
	print(("ok   " if ok else "FAIL ") + label)
	if not ok:
		_fail += 1
