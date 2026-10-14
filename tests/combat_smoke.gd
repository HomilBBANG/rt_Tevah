extends Node
## 전투 화면 스모크 테스트: 실제 타이밍으로 한 판 진행하며 user://combat_smoke/ 에 스크린샷.
## 화면이 필요하므로 --headless 없이:
##   Godot_v4.7-stable_win64_console.exe --path . res://tests/combat_smoke.tscn

var _shot := 0
var _fail := 0
var ui: Node


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute("user://combat_smoke")
	GameState.inventory = []
	GameState.add_item("water", 1)
	ui = load("res://scenes/combat.tscn").instantiate()
	add_child(ui)
	await _wait(0.2)
	await _snap("player_turn")
	check(ui.get_node("%EnemyName").text == "적 A (테스트)", "왼쪽 위 적 이름")
	check(ui.get_node("%PlayerBody").figure, "내 상태: 사람 모양")
	check("나타났다" in ui.get_node("%Message").text, "처음에 '나타났다' 표시")

	# 공격 → 텍스트 창에 적 부위 선택지 (부위 4 + 취소)
	ui.get_node("%AttackButton").pressed.emit()
	await _wait(0.1)
	await _snap("choose_target")
	var opts: Array = ui.get_node("%Options").get_children()
	check(ui.get_node("%Options").visible and opts.size() == 5 and opts[1].text.begins_with("몸통  30/30"),
		"부위 선택지: %s" % [opts.map(func(b): return b.text)])
	check(ui.get_node("%AttackButton").disabled, "부위 고르는 중 행동 버튼 잠김")
	# 몸통 명중(69 < 90) → 적 턴: 일반 공격(가중치 굴림 0)
	ui.combat.forced_rolls.assign([69.0, 0.0])
	opts[1].pressed.emit()
	check(ui.combat.enemy_parts.torso.hp == 20, "몸통 명중 30 → 20")
	check(not "나타났다" in ui.get_node("%Message").text, "첫 행동 뒤에는 '나타났다' 안 보임")

	# 일반 공격: 전조 1.2초. 0.7초쯤 스크린샷, 타격 시점에 S → 완벽 회피
	await _wait(0.6 + 0.7)
	await _snap("telegraph_torso")
	await _wait(0.5)
	ui.press_dodge("S")
	await _wait(0.15)
	await _snap("dodge_result")
	check(ui.combat.player_parts.torso.hp == 50, "타이밍 맞춰 S → 피해 없음")
	await _wait_state("player")

	# 아이템 → 인벤토리 → 물 사용 (턴을 씀) → 적 턴: 빠른 공격(가중치 굴림 50) 왼팔 피격 8
	ui.get_node("%ItemButton").pressed.emit()
	await _wait(0.1)
	check(ui.get_node("%Inventory").visible, "아이템 → 인벤토리 열림")
	await _snap("inventory")
	ui.combat.forced_rolls.assign([50.0])
	ui._on_item_used(0)
	await _wait(0.1)
	check(GameState.item_count("water") == 0 and not ui.get_node("%Inventory").visible, "물 사용 → 소모, 인벤토리 닫힘")
	check("사용: 물(테스트)" in ui.get_node("%Message").text, "텍스트 창에 사용 메시지")
	await _wait_state("player", 4.0)
	check(ui.combat.player_parts.left_arm.hp == 17, "아이템 사용 후 적 턴 (왼팔 25 → 17)")

	# 도주 실패(주사위 81 > 50) → 적 턴: 기만 공격(가중치 굴림 99). 전조는 몸통 → 도중에 머리
	ui.combat.forced_rolls.assign([80.0, 99.0])
	ui.get_node("%FleeButton").pressed.emit()
	await _wait(0.3)
	await _snap("flee_rolling")
	await _wait(0.6)
	check("주사위 81 / 50 이하 → 도주 실패!" in ui.get_node("%Message").text, "도주 실패 메시지")
	await _wait(0.6 + 0.4)
	await _snap("feint_before_switch")
	await _wait(0.5)
	await _snap("feint_after_switch")
	await _wait(0.8)
	await _snap("feint_hit")
	check(ui.combat.player_parts.head.hp == 8, "기만 공격 피격, 머리 20 → 8")
	await _wait_state("player")

	# 사망 화면: 머리 HP 를 1로 만든 뒤 도주 실패 → 피격
	ui.combat.player_parts.head.hp = 1
	ui.combat.forced_rolls.assign([80.0, 99.0])
	ui.get_node("%FleeButton").pressed.emit()
	await _wait_state("over", 6.0)
	await _snap("dead")
	check(ui.combat.outcome == "lose" and ui.get_node("%EndButtons").visible, "머리 파괴 → 사망, 끝 버튼")

	# 도주 성공 (새 판)
	ui.queue_free()
	ui = load("res://scenes/combat.tscn").instantiate()
	add_child(ui)
	await _wait(0.2)
	ui.combat.forced_rolls.assign([10.0])
	ui.get_node("%FleeButton").pressed.emit()
	await _wait_state("over", 3.0)
	await _snap("fled")
	check(ui.combat.outcome == "fled", "주사위 11 ≤ 50 → 도주 성공")

	GameState.inventory = []
	print("[combat_smoke] 스크린샷 %d장, 실패 %d → %s" % [_shot, _fail, ProjectSettings.globalize_path("user://combat_smoke")])
	get_tree().quit(1 if _fail > 0 else 0)


func _wait(sec: float) -> void:
	await get_tree().create_timer(sec).timeout


func _wait_state(state: String, limit := 4.0) -> void:
	var t := 0.0
	while ui._state != state and t < limit:
		await _wait(0.05)
		t += 0.05


func _snap(name: String) -> void:
	await RenderingServer.frame_post_draw
	_shot += 1
	get_viewport().get_texture().get_image().save_png("user://combat_smoke/%02d_%s.png" % [_shot, name])


func check(ok: bool, label: String) -> void:
	print(("ok   " if ok else "FAIL ") + label)
	if not ok:
		_fail += 1
