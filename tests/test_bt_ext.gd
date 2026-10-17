extends Node
## 몬스터 AI Phase 6 단위 테스트 (헤드리스): Simple Parallel · Run Behavior(Subtree) · domain 검사 · 전투 BT · 브레이크포인트.
##   Godot_v4.7-stable_win64_console.exe --headless --path . res://tests/test_bt_ext.tscn

const Runner = preload("res://core/ai/bt_runner.gd")
const Assets = preload("res://core/ai/ai_assets.gd")
const Combat = preload("res://core/combat/combat.gd")
const FakeAgent = preload("res://tests/test_bt.gd").FakeAgent

var _fail := 0
var _pass := 0

const BB := {"asset_type": "blackboard", "id": "BB_T", "keys": [
	{"name": "A", "type": "bool", "default": false}, {"name": "Step", "type": "int", "default": 0},
	{"name": "HasLineOfSight", "type": "bool", "default": false}, {"name": "TargetLocation", "type": "vector2", "default": null}]}


func _ready() -> void:
	var all := Assets.load_dir()
	all["BB_T"] = BB
	# ---------- Simple Parallel (Immediate): 주 Task 가 끝나면 배경 분기를 바로 중단
	var par := _bt("BT_P", [
		{"id": "root", "kind": "Root", "children": ["par"]},
		{"id": "par", "kind": "SimpleParallel", "finish_mode": "Immediate", "children": ["main", "bg"]},
		{"id": "main", "kind": "Task", "task_type": "Wait", "params": {"seconds": 1.0}},
		{"id": "bg", "kind": "Task", "task_type": "Wait", "params": {"seconds": 0.25}}])
	all["BT_P"] = par
	check(Assets.validate_bt(par, all).is_empty(), "Simple Parallel 검사 통과: %s" % [Assets.validate_bt(par, all)])
	var r := _runner(par, all)
	r.tick(0.05)
	var sub = r.parallel_subs.get("par")
	check(sub != null and r.task_node == "main" and r.debug_snapshot().active.has("bg"), "주 Task(Wait 1초) + 배경 분기가 함께 실행 (디버거 경로에 둘 다)")
	for i in 19:
		r.tick(0.05)
	check(sub.passes >= 3, "배경 분기는 주 Task 가 도는 동안 반복 (%d 바퀴)" % sub.passes)
	r.tick(0.05)
	check(r.last_result.get("par") == "SUCCESS" and sub.stack.is_empty() and r.parallel_subs.get("par") != sub,
		"주 Task 끝 → 배경 중단, 결과 = 주 Task (Immediate) — 트리는 다음 바퀴에 새로 시작")
	# Delayed: 배경 한 바퀴가 끝날 때까지 기다림
	par.nodes[1].finish_mode = "Delayed"
	par.nodes[2].params.seconds = 0.3
	par.nodes[3].params.seconds = 1.0
	r = _runner(par, all)
	for i in 8:
		r.tick(0.05)
	check(r.task_node == "" and r.active_path().has("par") and r.parallel_subs.has("par"), "Delayed: 주 Task 가 끝나도 배경이 도는 동안 기다림")
	for i in 16:
		r.tick(0.05)
	check(r.log.any(func(e): return e.ev == "parallel" and "배경 분기도 끝남" in e.reason) and r.last_result.get("par") == "SUCCESS", "Delayed: 배경 한 바퀴가 끝나면 함께 끝남")
	var bad := par.duplicate(true)
	bad.nodes[1].children = ["bg", "main"]
	bad.nodes[3].kind = "Selector"
	bad.nodes[3].erase("task_type")
	bad.nodes[3].children = ["main"]
	check(_has(Assets.validate_bt(bad, all), "첫 자식(주)은 Task"), "Simple Parallel 첫 자식이 Task 가 아니면 오류")

	# ---------- Run Behavior (Subtree): 같은 Blackboard 로 다른 트리
	var child := _bt("BT_Child", [{"id": "root", "kind": "Root", "children": ["seq"]}, {"id": "seq", "kind": "Sequence", "children": ["s"]},
		{"id": "s", "kind": "Task", "task_type": "SetBlackboardValue", "params": {"key": "Step", "value": 7}}])
	var parent := _bt("BT_Parent", [{"id": "root", "kind": "Root", "children": ["seq"]}, {"id": "seq", "kind": "Sequence", "children": ["run", "w"]},
		{"id": "run", "kind": "Task", "task_type": "RunBehavior", "params": {"bt_id": "BT_Child"}},
		{"id": "w", "kind": "Task", "task_type": "Wait", "params": {"seconds": 5}}])
	all["BT_Child"] = child
	all["BT_Parent"] = parent
	check(Assets.validate_bt(parent, all).is_empty(), "Run Behavior 검사 통과: %s" % [Assets.validate_bt(parent, all)])
	r = _runner(parent, all)
	r.tick(0.1)
	check(r.bb.get_value("Step") == 7 and r.last_result.get("run") == "SUCCESS" and r.task_node == "w", "Run Behavior: 다른 트리를 같은 Blackboard 로 실행 → 그 결과로 다음")
	child.nodes.append({"id": "back", "kind": "Task", "task_type": "RunBehavior", "params": {"bt_id": "BT_Parent"}})
	child.nodes[1].children.append("back")
	check(_has(Assets.validate_bt(parent, all), "순환"), "Run Behavior 순환 (부모 → 자식 → 부모) 오류")
	child.nodes.pop_back()
	child.nodes[1].children.pop_back()
	child.blackboard_id = "BB_Infected"
	check(_has(Assets.validate_bt(parent, all), "같은 Blackboard"), "다른 Blackboard 의 트리는 Run Behavior 불가")
	child.blackboard_id = "BB_T"

	# ---------- domain: 필드 Task 는 전투 BT 에, 전투 Task 는 필드 BT 에 못 씀
	var b := _bt("BT_B", [{"id": "root", "kind": "Root", "children": ["sel"]}, {"id": "sel", "kind": "Selector", "children": ["mv"],
		"services": [{"type": "UpdatePerception", "interval": 0.2}]},
		{"id": "mv", "kind": "Task", "task_type": "MoveTo", "params": {"target_key": "TargetLocation"}}])
	b.domain = "battle"
	var msgs := Assets.validate_bt(b, all)
	check(_has(msgs, "field BT 용 Task") and _has(msgs, "Service 를 쓸 수 없음"), "전투 BT 에 MoveTo·Service 오류")
	var f := _bt("BT_F", [{"id": "root", "kind": "Root", "children": ["sel"]}, {"id": "sel", "kind": "Selector", "children": ["ua"]},
		{"id": "ua", "kind": "Task", "task_type": "UseAttack", "params": {"attack_id": "atk_quick"}}])
	check(_has(Assets.validate_bt(f, all), "battle BT 용 Task"), "필드 BT 에 UseAttack 오류")
	check(Assets.validate_bt(all.BT_Battle_Test, all).is_empty(), "샘플 전투 BT 검사 통과: %s" % [Assets.validate_bt(all.BT_Battle_Test, all)])

	# ---------- 전투 BT: 적 공격 고르기
	DataLoader.ai_assets = all
	DataLoader.enemies.enemy_test.battle_bt = "BT_Battle_Test"
	var c := Combat.new()
	c.setup("enemy_test")
	check(c.battle_bt != null, "Npcs battle_bt → 전투에서 BT 사용")
	check(c.choose_enemy_attack().attack_id == "atk_feint", "첫 차례 (Turn == 1) → 기만 공격")
	var ids := {}
	for i in 30:
		ids[c.choose_enemy_attack().attack_id] = true
	check(ids.size() >= 3, "그 외 차례 → 가중치로 여러 공격 (%s)" % [ids.keys()])
	c.enemy_parts.right_arm.broken = true
	check(c.choose_enemy_attack().attack_id == "atk_quick", "내 오른팔이 잘리면 → 왼팔 속공")
	c.player_parts.left_leg.broken = true
	check(c.choose_enemy_attack().attack_id == "atk_quick", "플레이어 다리 잘림 → 연속 공격(오른팔)을 고르지만 오른팔이 잘려 못 씀 → 다음 줄 (절단에 따른 행동 불가)")
	c.enemy_parts.right_arm.broken = false
	check(c.choose_enemy_attack().attack_id == "atk_combo", "오른팔이 있으면 다리 잃은 플레이어에게 연속 공격")
	check(c.battle_bt.bb.get_value("Turn") == c.enemy_turns and c.battle_bt.bb.last_source.Player_left_leg_Broken == "Sensor", "Blackboard 에 전투 상태 (Turn·부위 잘림, 출처 Sensor)")
	DataLoader.enemies.enemy_test.battle_bt = ""
	var c2 := Combat.new()
	c2.setup("enemy_test")
	check(c2.battle_bt == null and not c2.choose_enemy_attack().is_empty(), "battle_bt 가 없으면 예전처럼 가중치")

	# ---------- 브레이크포인트·일시정지·한 단계
	var ag := FakeAgent.new()
	ag.points = [Vector2(0, 0), Vector2(-3, 0)]
	r = Runner.new()
	r.assets = all
	r.setup(all.BT_Infected_Field, all.BB_Infected, ag)
	r.breakpoints["chase"] = true
	r.tick(0.1)
	ag.player = Vector2(3, 0)
	for i in 3:
		r.tick(0.1)
	check(r.is_paused() and r.bp_hit == "chase", "브레이크포인트: Chase 에 들어가면 멈춤")
	var pos := ag.pos
	for i in 5:
		r.tick(0.1)
	check(ag.pos == pos, "멈춘 동안은 진행 안 함")
	r.step(0.1)
	check(ag.pos != pos and r.is_paused(), "한 단계: 한 번 진행하고 다시 멈춤")
	r.breakpoints.clear()
	r.set_paused(false)
	r.tick(0.1)
	check(not r.is_paused() and r.bp_hit == "", "재개")

	print("[test_bt_ext] %d 통과, %d 실패" % [_pass, _fail])
	get_tree().quit(1 if _fail > 0 else 0)


func _bt(id: String, nodes: Array) -> Dictionary:
	return {"asset_type": "behavior_tree", "id": id, "blackboard_id": "BB_T", "root_id": "root", "nodes": nodes}


func _runner(bt: Dictionary, all: Dictionary) -> Runner:
	var r := Runner.new()
	r.assets = all
	r.setup(bt, BB, FakeAgent.new())
	return r


func _has(errs: Array, part: String) -> bool:
	return errs.any(func(e): return part in e.msg)


func check(ok: bool, label: String) -> void:
	if ok:
		_pass += 1
		print("ok   ", label)
	else:
		_fail += 1
		print("FAIL ", label)
