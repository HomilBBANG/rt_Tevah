extends Node
## 전투 로직 테스트 (더미 적 enemy_test 기준). 실행:
##   Godot_v4.7-stable_win64_console.exe --headless --path . res://tests/test_combat.tscn

const Combat = preload("res://core/combat/combat.gd")

var _fail := 0
var _pass := 0


func _ready() -> void:
	_test_dodge()
	_test_player_turn()
	_test_enemy_turn()
	_test_player_damage()
	print("\n[test_combat] %d 통과, %d 실패" % [_pass, _fail])
	get_tree().quit(1 if _fail > 0 else 0)


func _test_dodge() -> void:
	# Config: 완벽 ±0.08초, 일반 ±0.2초
	check(Combat.judge_dodge("S", "S", 0.0) == "perfect", "정확한 키·타이밍 → 완벽")
	check(Combat.judge_dodge("S", "S", -0.08) == "perfect", "완벽 경계 (-0.08)")
	check(Combat.judge_dodge("S", "S", 0.15) == "normal", "약간 늦음 → 일반")
	check(Combat.judge_dodge("S", "S", -0.2) == "normal", "일반 경계 (-0.2)")
	check(Combat.judge_dodge("S", "S", 0.25) == "fail", "너무 늦음 → 실패")
	check(Combat.judge_dodge("S", "S", -0.5) == "fail", "너무 이름 → 실패")
	check(Combat.judge_dodge("W", "S", 0.0) == "fail", "잘못된 방향 → 실패")
	check(Combat.judge_dodge("", "S", 0.0) == "fail", "안 누름 → 실패")


func _test_player_turn() -> void:
	var c := Combat.new()
	check(c.setup("enemy_test"), "적 준비")
	check(c.player_parts.size() == 6 and c.enemy_parts.size() == 4 and c.attacks.size() == 4, "부위·공격 로드")
	c.forced_rolls = [69.0]
	var r := c.player_attack("left_arm")
	check(r.hit and r.damage == 10 and c.enemy_parts.left_arm.hp == 5, "명중 (69 < 70%) → 왼팔 -10")
	c.forced_rolls = [70.0]
	check(not c.player_attack("left_arm").hit, "빗나감 (70 >= 70%)")
	c.forced_rolls = [0.0]
	r = c.player_attack("left_arm")
	check(r.broken and not r.killed and c.enemy_parts.left_arm.broken, "왼팔 파괴 (치명 부위 아님)")
	check(c.player_attack("left_arm").is_empty(), "파괴된 부위는 다시 못 노림")
	var ids := c.available_attacks().map(func(a): return a.attack_id)
	check(not "atk_quick" in ids and ids.size() == 3, "왼팔 파괴 → 왼팔 공격(속공) 봉인: %s" % [ids])
	c.forced_rolls = [0.0]
	r = c.player_attack("head")
	check(r.killed and c.outcome == "win", "머리(10) 한 번에 파괴 → 치명 부위 → 승리")

	var f := Combat.new()
	f.setup("enemy_test")
	f.forced_rolls = [49.0]
	check(f.player_flee() and f.outcome == "fled", "도주 성공 (49 < 50%)")
	f.setup("enemy_test")
	f.forced_rolls = [50.0]
	check(not f.player_flee() and f.outcome == "", "도주 실패")


func _test_enemy_turn() -> void:
	var c := Combat.new()
	c.setup("enemy_test")
	# 가중치 3:2:2:1 (합 8). 0 → 첫 공격, 99 → 마지막 공격
	c.forced_rolls = [0.0]
	check(c.choose_enemy_attack().attack_id == "atk_normal", "가중치 선택: 첫 구간")
	c.forced_rolls = [99.0]
	check(c.choose_enemy_attack().attack_id == "atk_feint", "가중치 선택: 마지막 구간")
	var feint: Dictionary = c.attacks.filter(func(a): return a.attack_id == "atk_feint")[0]
	var st: Dictionary = feint.strikes[0]
	check(st.telegraph == "torso" and st.target == "head" and c.dodge_key_for(st) == "W",
		"기만: 전조는 몸통, 실제는 머리 → W")
	var combo: Dictionary = c.attacks.filter(func(a): return a.attack_id == "atk_combo")[0]
	check(combo.strikes.size() == 2 and c.dodge_key_for(combo.strikes[1]) == "D", "연속: 2타, 두 번째는 오른다리 → D")
	for p in c.enemy_parts.values():
		if p.part_id != "head" and p.part_id != "torso":
			p.broken = true
	c.enemy_parts.head.broken = true
	check(c.choose_enemy_attack().is_empty(), "쓸 수 있는 부위가 없으면 공격 안 함")


func _test_player_damage() -> void:
	var c := Combat.new()
	c.setup("enemy_test")
	var normal: Dictionary = c.attacks[0]   # 몸통 10
	var r := c.apply_strike(normal, normal.strikes[0], "perfect")
	check(r.damage == 0 and c.player_parts.torso.hp == 50, "완벽 회피 → 피해 없음")
	r = c.apply_strike(normal, normal.strikes[0], "normal")
	check(r.damage == 0, "일반 회피 → 피해 없음")
	r = c.apply_strike(normal, normal.strikes[0], "fail")
	check(r.damage == 10 and c.player_parts.torso.hp == 40, "피격 → 몸통 -10")
	c.player_defend()
	r = c.apply_strike(normal, normal.strikes[0], "fail")
	check(r.damage == 5, "방어 중 피격 → 절반")
	c.end_enemy_turn()
	check(not c.defending, "적 턴 끝나면 방어 해제")

	var quick: Dictionary = c.attacks[1]    # 왼팔 8
	for i in 3:
		r = c.apply_strike(quick, quick.strikes[0], "fail")
	check(c.player_parts.left_arm.hp == 1 and c.can_attack(), "왼팔 25 → 1")
	r = c.apply_strike(quick, quick.strikes[0], "fail")
	check(r.severed and c.player_parts.left_arm.broken and c.outcome == "", "왼팔 절단 (치명 아님)")
	r = c.apply_strike(quick, quick.strikes[0], "fail")
	check(r.part == "torso", "잘린 팔을 노린 타격 → 몸통으로")
	c.player_parts.right_arm.broken = true
	check(not c.can_attack(), "양팔 절단 → 공격 불가")
	c.player_parts.left_leg.broken = true
	check(not c.can_flee(), "다리 절단 → 도주 불가")

	var combo: Dictionary = c.attacks[2]    # 머리 6
	for i in 4:
		r = c.apply_strike(combo, combo.strikes[0], "fail")
	check(r.dead and c.outcome == "lose", "머리 20 → 0 → 사망")


func check(ok: bool, label: String) -> void:
	if ok:
		_pass += 1
		print("ok   " + label)
	else:
		_fail += 1
		print("FAIL " + label)
