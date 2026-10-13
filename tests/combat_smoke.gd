extends Node
## 전투 화면 스모크 테스트: 실제 타이밍으로 한 판 진행하며 user://combat_smoke/ 에 스크린샷.
## 화면이 필요하므로 --headless 없이:
##   Godot_v4.7-stable_win64_console.exe --path . res://tests/combat_smoke.tscn

var _shot := 0
var _fail := 0
var ui: Node


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute("user://combat_smoke")
	ui = load("res://scenes/combat.tscn").instantiate()
	add_child(ui)
	await _wait(0.2)
	await _snap("player_turn")

	# 공격 → 부위 선택 화면
	ui.get_node("%AttackButton").pressed.emit()
	await _wait(0.1)
	await _snap("choose_target")
	# 몸통 명중(69 < 90) → 적 턴: 일반 공격(가중치 굴림 0)
	ui.combat.forced_rolls.assign([69.0, 0.0])
	ui._on_target_chosen("torso")
	check(ui.combat.enemy_parts.torso.hp == 20, "몸통 명중 30 → 20")

	# 일반 공격: 전조 1.2초. 0.7초쯤 스크린샷, 타격 시점에 S → 완벽 회피
	await _wait(0.6 + 0.7)
	await _snap("telegraph_torso")
	await _wait(0.5)
	ui.press_dodge("S")
	await _wait(0.15)
	await _snap("dodge_result")
	check(ui.combat.player_parts.torso.hp == 50, "타이밍 맞춰 S → 피해 없음")
	await _wait_state("player")

	# 방어 → 적 턴: 기만 공격(가중치 굴림 99). 전조는 몸통 → 도중에 머리. 아무것도 안 눌러 피격(방어로 절반)
	ui.combat.forced_rolls.assign([99.0])
	ui._on_defend()
	await _wait(0.6 + 0.4)
	await _snap("feint_before_switch")
	await _wait(0.5)
	await _snap("feint_after_switch")
	await _wait(0.8)
	await _snap("feint_hit")
	check(ui.combat.player_parts.head.hp == 14, "기만 공격 피격, 방어 중이라 12 → 6 (머리 20 → 14)")
	await _wait_state("player")

	# 사망 화면: 머리 HP 를 1로 만든 뒤 피격
	ui.combat.player_parts.head.hp = 1
	ui.combat.forced_rolls.assign([99.0])
	ui._on_defend()
	await _wait_state("over", 5.0)
	await _snap("dead")
	check(ui.combat.outcome == "lose", "머리 파괴 → 사망")

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
