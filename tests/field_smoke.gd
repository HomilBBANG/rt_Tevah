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
	f = load("res://scenes/field/field.tscn").instantiate()
	add_child(f)
	await _wait(0.3)
	check(f.enemies.size() == 2 and f.spots.size() == 3, "맵 로드: 적 2, 조사 지점 3")
	await _snap("start")

	# 이동: 오른쪽으로 0.5초 → 약 2칸 (4칸/초)
	var x0: float = f.player.position.x
	Input.action_press("move_right")
	await _wait(0.5)
	Input.action_release("move_right")
	check(f.player.position.x - x0 > f.tile * 1.5, "오른쪽 이동 (%.0f px)" % (f.player.position.x - x0))
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
	check(f.player_body.left_arm.hp == 7, "전투 피해가 필드에 이어짐")
	await _wait(0.1)
	await _snap("after_flee")

	# 승리 → 적 제거, 절단 상태 유지
	await _wait_until(func(): return e1.grace == 0.0, 5.0)
	_teleport_to(e1)
	await _wait_until(func(): return f._combat_ui != null, 2.0)
	check(f._combat_ui.combat.player_parts.left_arm.hp == 7, "다음 전투도 부상 상태로 시작")
	await _end_combat("win", func(c): c.player_parts.left_arm.broken = true; c.player_parts.left_arm.hp = 0)
	check(f.enemies.size() == 1 and f.player_body.left_arm.broken, "승리 → 적 제거, 왼팔 절단 유지")
	check("왼팔 절단" in f.get_node("%Body").text, "HUD 부상 표시: %s" % f.get_node("%Body").text)

	# 사망 → 처음부터 패널
	_teleport_to(f.enemies[0])
	await _wait_until(func(): return f._combat_ui != null, 2.0)
	await _end_combat("lose", func(_c): pass)
	check(f.get_node("%DeathPanel").visible, "사망 → 처음부터 패널")
	await _snap("dead")

	print("[field_smoke] 스크린샷 %d장, 실패 %d → %s" % [_shot, _fail, ProjectSettings.globalize_path("user://field_smoke")])
	get_tree().quit(1 if _fail > 0 else 0)


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
