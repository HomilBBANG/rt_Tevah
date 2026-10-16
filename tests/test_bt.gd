extends Node
## 몬스터 AI Behavior Tree 단위 테스트 (기획 tevah_monster_bt_blueprint_style_spec_v2.0 §11 'BT 의미 검증'). 실행:
##   Godot_v4.7-stable_win64_console.exe --headless --path . res://tests/test_bt.tscn
## 맵 없이 가짜 몬스터(FakeAgent)로 Selector·Sequence·Decorator·Observer Aborts·Service·Task 중단을 확인한다.

const Runner = preload("res://core/ai/bt_runner.gd")
const Assets = preload("res://core/ai/ai_assets.gd")


class FakeAgent:
	var pos := Vector2.ZERO
	var speed := 4.0                 # 칸/초
	var player := Vector2(20, 0)
	var see: Variant = null          # null = 거리로, true/false = 강제
	var points := [Vector2(0, 0), Vector2(3, 0)]
	var origin := Vector2.ZERO
	var stops := 0
	var battles := 0
	var perceive_calls := 0
	var allow_battle := true

	func ai_tile() -> Vector2: return pos
	func ai_move(to: Vector2, run: bool, delta: float) -> String:
		var d := to - pos
		var step := speed * (1.5 if run else 1.0) * delta
		if d.length() <= step:
			pos = to
			return "arrived"
		pos += d.normalized() * step
		return "moving"
	func ai_stop() -> void: stops += 1
	func ai_patrol_points() -> Array: return points
	func ai_origin() -> Vector2: return origin
	func ai_perceive(rng: float) -> Dictionary:
		perceive_calls += 1
		var dist := pos.distance_to(player)
		var vis: bool = dist <= rng if see == null else see
		return {"visible": vis, "id": "player", "pos": player, "distance": dist}
	func ai_entity_tile(_id: String) -> Variant: return player
	func ai_noise() -> Dictionary: return {}
	func ai_request_battle() -> bool:
		if not allow_battle:
			return false
		battles += 1
		return true


var _fail := 0
var _pass := 0

const BB_TEST := {"asset_type": "blackboard", "id": "BB_Test", "keys": [
	{"name": "A", "type": "bool", "default": false}, {"name": "B", "type": "bool", "default": false},
	{"name": "Step", "type": "int", "default": 0}, {"name": "HasLineOfSight", "type": "bool", "default": false},
	{"name": "TargetLocation", "type": "vector2", "default": null}, {"name": "DistanceToTarget", "type": "float", "default": 9999.0},
	{"name": "VisionRange", "type": "float", "default": 5.0}]}


func _ready() -> void:
	var all := Assets.load_dir()
	# ---------- 자산 검사
	check(all.has("BB_Infected") and all.has("BT_Infected_Field"), "샘플 자산 읽기 (tools/ai)")
	check(Assets.validate_all(all).is_empty(), "샘플 자산 오류 없음: %s" % [Assets.validate_all(all)])
	var bad := _bt([
		{"id": "root", "kind": "Root", "children": ["sel"]},
		{"id": "sel", "kind": "Selector", "children": ["t1", "t2"],
			"decorators": [{"type": "Blackboard", "key": "Nope", "operator": "is_set"}]},
		{"id": "t1", "kind": "Task", "task_type": "MoveTo", "params": {"target_key": "Step"}, "children": ["t2"]},
		{"id": "t2", "kind": "Task", "task_type": "Fly"},
		{"id": "lost", "kind": "Task", "task_type": "Wait"}])
	var msgs := Assets.validate_bt(bad, {"BB_Test": BB_TEST}).map(func(e): return e.msg)
	check(_has(msgs, "Blackboard 에 없음: 'Nope'") and _has(msgs, "키 타입이 맞지 않음") and _has(msgs, "Task 는 자식을")
		and _has(msgs, "없는 Task 'Fly'") and _has(msgs, "부모가 둘") and _has(msgs, "부모 없음"), "검사: 없는 키·타입 불일치·Task 자식·없는 Task·부모 둘·고아 (%s)" % [msgs])

	# ---------- Selector 왼쪽 우선 / Sequence 하나 실패하면 전체 실패
	var tree := _bt([
		{"id": "root", "kind": "Root", "children": ["sel"]},
		{"id": "sel", "kind": "Selector", "children": ["left", "right"]},
		{"id": "left", "kind": "Sequence", "children": ["set1"], "decorators": [{"type": "Blackboard", "key": "A", "operator": "is_set"}]},
		{"id": "set1", "kind": "Task", "task_type": "SetBlackboardValue", "params": {"key": "Step", "value": 1}},
		{"id": "right", "kind": "Sequence", "children": ["set5", "gate", "set6"]},
		{"id": "set5", "kind": "Task", "task_type": "SetBlackboardValue", "params": {"key": "Step", "value": 5}},
		{"id": "gate", "kind": "Task", "task_type": "Wait", "params": {"seconds": 0}, "decorators": [{"type": "Blackboard", "key": "B", "operator": "is_set"}]},
		{"id": "set6", "kind": "Task", "task_type": "SetBlackboardValue", "params": {"key": "Step", "value": 6}}])
	var r := _runner(tree, FakeAgent.new())
	r.tick(0.1)
	check(r.bb.get_value("Step") == 5 and r.last_result.get("gate") == "FAILURE" and r.last_result.get("right") == "FAILURE",
		"Decorator false → 그 노드 실패, Sequence 는 거기서 멈춤 (Step=%s)" % r.bb.get_value("Step"))
	check(r.last_result.get("left") == "FAILURE" and r.last_result.get("set1", "") == "", "Decorator false 인 분기는 실행 안 됨")
	r.bb.set_value("A", true)
	r.tick(0.1)
	check(r.bb.get_value("Step") == 1 and r.last_result.get("set5") == "SUCCESS", "A 가 true → 왼쪽(높은 우선순위)이 먼저")
	r.bb.set_value("A", false)
	r.bb.set_value("B", true)
	r.tick(0.1)
	check(r.bb.get_value("Step") == 6, "B 도 true → Sequence 끝까지")
	check(Array(tree.nodes[1].children) == ["left", "right"], "children 순서 = 실행 순서 (편집 표시와 무관)")

	# ---------- Observer Aborts 4가지
	for pol in ["None", "Self", "LowerPriority", "Both"]:
		var t := _bt([
			{"id": "root", "kind": "Root", "children": ["sel"]},
			{"id": "sel", "kind": "Selector", "children": ["hi", "lo"]},
			{"id": "hi", "kind": "Sequence", "children": ["wait_hi"], "decorators": [{"type": "Blackboard", "key": "A", "operator": "is_set", "observer_aborts": pol}]},
			{"id": "wait_hi", "kind": "Task", "task_type": "Wait", "params": {"seconds": 10}},
			{"id": "lo", "kind": "Task", "task_type": "Wait", "params": {"seconds": 10}}])
		var ag := FakeAgent.new()
		var rr := _runner(t, ag)
		rr.tick(0.1)
		check(rr.task_node == "lo", "[%s] 처음엔 낮은 우선순위 Wait" % pol)
		rr.bb.set_value("A", true)
		rr.tick(0.1)
		var preempt: bool = pol in ["LowerPriority", "Both"]
		check((rr.task_node == "wait_hi") == preempt, "[%s] A=true → 낮은 우선순위 중단 %s (지금 %s)" % [pol, "함" if preempt else "안 함", rr.task_node])
		if preempt:
			check(rr.last_result.get("lo") == "ABORTED" and rr.log.any(func(e): return e.ev == "observer_abort" and e.node == "hi"), "[%s] 중단 기록 (ABORTED, observer_abort)" % pol)
		# 높은 쪽이 실행 중일 때 A=false
		var rr2 := _runner(t, FakeAgent.new())
		rr2.bb.set_value("A", true)
		rr2.tick(0.1)
		check(rr2.task_node == "wait_hi", "[%s] A=true 로 시작 → 높은 우선순위 Wait" % pol)
		rr2.bb.set_value("A", false)
		rr2.tick(0.1)
		var self_abort: bool = pol in ["Self", "Both"]
		check((rr2.task_node == "lo") == self_abort, "[%s] A=false → 자기 분기 중단 %s (지금 %s)" % [pol, "함" if self_abort else "안 함", rr2.task_node])

	# ---------- 감염자 샘플: 순찰 → 발견하면 추격(순찰 중단) → 닿으면 전투(한 번만) → 놓치면 수색 → 순찰
	var ag := FakeAgent.new()
	var inf := _runner(all.BT_Infected_Field, ag, all.BB_Infected)
	_ticks(inf, 5, 0.1)
	check(inf.task_node == "patrol" and inf.last_result.get("patrol") == "RUNNING", "플레이어가 멀면 Patrol RUNNING (%s)" % inf.task_node)
	var stops_before := ag.stops
	ag.player = Vector2(4, 0)
	_ticks(inf, 3, 0.1)
	check(inf.task_node == "move_to_target" and inf.last_result.get("patrol") == "ABORTED" and ag.stops > stops_before,
		"발견 → Chase 가 Patrol 을 선점, Patrol 은 ABORTED 로 정리(멈춤) (%s)" % inf.task_node)
	check(inf.bb.get_value("HasLastKnownLocation") and inf.bb.last_source.get("HasLineOfSight") == "Service", "Service 가 Blackboard 갱신 (출처 Service)")
	_ticks(inf, 30, 0.1)
	check(ag.battles == 1, "가까워지면 Engage → 전투 요청 (%d 번)" % ag.battles)
	_ticks(inf, 20, 0.1)
	check(ag.battles == 1, "전투가 끝나기 전에는 다시 요청 안 함 (%d 번)" % ag.battles)
	inf.notify_battle_end()
	ag.see = false
	ag.player = Vector2(-6, 0)
	_ticks(inf, 2, 0.1)
	check(inf.task_node == "search_last" and not inf.bb.get_value("HasLineOfSight"), "놓치면 Chase/Engage 중단 → 마지막 위치 수색 (%s)" % inf.task_node)
	_ticks(inf, 60, 0.1)
	check(not inf.bb.get_value("HasLastKnownLocation") and inf.task_node == "patrol", "수색을 마치면 키를 지우고 Patrol 로 복귀 (%s)" % inf.task_node)

	# ---------- 디버거 스냅숏 (게임 → 에디터로 보내는 것)
	var snap := inf.debug_snapshot(200)
	check(snap.bt == "BT_Infected_Field" and snap.active.back() == snap.task and snap.task == "patrol"
		and snap.keys.any(func(k): return k[0] == "HasLastKnownLocation" and k[2] == "Task")
		and not snap.log.is_empty() and snap.results.get("search_last") == "SUCCESS",
		"디버그 스냅숏: 실행 경로·Task·Blackboard 값과 출처·Observer Aborts 기록·결과 (%s %s %s %s)" % [snap.active, snap.task, snap.results, snap.keys.filter(func(k): return k[0] == "HasLastKnownLocation")])
	check(JSON.parse_string(JSON.stringify(snap)) is Dictionary, "스냅숏은 글자·수만 (다른 프로세스로 보낼 수 있음)")

	# ---------- Service: 활성 분기에서만, 주기대로
	var st := _bt([
		{"id": "root", "kind": "Root", "children": ["sel"]},
		{"id": "sel", "kind": "Selector", "children": ["hi", "lo"]},
		{"id": "hi", "kind": "Sequence", "children": ["w"], "decorators": [{"type": "Blackboard", "key": "A", "operator": "is_set", "observer_aborts": "Self"}],
			"services": [{"type": "UpdatePerception", "interval": 0.5, "run_on_activation": false}]},
		{"id": "w", "kind": "Task", "task_type": "Wait", "params": {"seconds": 100}},
		{"id": "lo", "kind": "Task", "task_type": "Wait", "params": {"seconds": 100}}])
	var sa := FakeAgent.new()
	var sr := _runner(st, sa)
	sr.bb.set_value("A", true)
	_ticks(sr, 21, 0.1)   # 2.1초 → 0.5초마다 4번
	check(sa.perceive_calls == 4, "Service 는 interval 0.5초 → 2.1초에 4번 (%d)" % sa.perceive_calls)
	sr.bb.set_value("A", false)
	_ticks(sr, 20, 0.1)
	check(sa.perceive_calls == 4 and sr.task_node == "lo", "분기가 비활성이면 Service 도 멈춤 (%d)" % sa.perceive_calls)

	# ---------- 같은 자산 2마리: Blackboard·실행 상태 따로
	var a1 := FakeAgent.new()
	var a2 := FakeAgent.new()
	a1.points = [Vector2(0, 0), Vector2(-3, 0)]   # 플레이어 반대쪽으로 순찰
	a2.points = [Vector2(0, 0), Vector2(-3, 0)]
	a2.player = Vector2(3, 0)
	var r1 := _runner(all.BT_Infected_Field, a1, all.BB_Infected)
	var r2 := _runner(all.BT_Infected_Field, a2, all.BB_Infected, {"VisionRange": 2.0})
	_ticks(r1, 2, 0.1)
	_ticks(r2, 2, 0.1)
	check(r1.task_node == "patrol" and r2.task_node == "patrol" and r1.bb != r2.bb, "두 마리: 둘 다 순찰, Blackboard 객체가 다름")
	a1.player = Vector2(3, 0)
	_ticks(r1, 2, 0.1)
	_ticks(r2, 2, 0.1)
	check(r1.task_node == "move_to_target" and r2.task_node == "patrol", "같은 거리라도 시야 거리 override(2칸)인 쪽은 못 봄 (%s / %s)" % [r1.task_node, r2.task_node])
	check(r2.bb.get_value("VisionRange") == 2.0 and r1.bb.get_value("VisionRange") == 5.0 and r2.bb.last_source.VisionRange == "Editor Override", "VisionRange 개체별 (출처 Editor Override)")

	# ---------- 중단된 Task 의 늦은 완료는 무시
	var lr := _runner(st, FakeAgent.new())
	lr.tick(0.1)
	var old_task: Object = lr.task
	lr.stop("테스트")
	check(lr.task == null and lr.stack.is_empty() and lr.services.is_empty(), "stop: Task·Service·경로 모두 정리")
	old_task.tick(200.0)   # 늦게 끝나도
	check(lr.task == null and lr.stack.is_empty(), "중단된 Task 가 늦게 끝나도 트리를 되살리지 않음")
	lr.tick(0.1)
	check(lr.task_node == "lo", "다시 tick 하면 처음부터")

	# ---------- 무한 반복 보호: 즉시 끝나는 Task 만 있는 트리도 한 tick 에 한 바퀴만
	var fast := _bt([{"id": "root", "kind": "Root", "children": ["seq"]}, {"id": "seq", "kind": "Sequence", "children": ["s"]},
		{"id": "s", "kind": "Task", "task_type": "SetBlackboardValue", "params": {"key": "Step", "value": 9}}])
	var fr := _runner(fast, FakeAgent.new())
	_ticks(fr, 3, 0.1)
	check(fr.error == "" and fr.bb.get_value("Step") == 9 and fr.stack.is_empty(), "즉시 끝나는 트리: tick 마다 한 바퀴, 오류 없음")

	print("[test_bt] %d 통과, %d 실패" % [_pass, _fail])
	get_tree().quit(1 if _fail > 0 else 0)


func _bt(nodes: Array) -> Dictionary:
	return {"asset_type": "behavior_tree", "id": "BT_Test", "blackboard_id": "BB_Test", "root_id": "root", "nodes": nodes}


func _runner(bt: Dictionary, agent: Object, bb := BB_TEST, overrides := {}) -> Runner:
	var r := Runner.new()
	r.setup(bt, bb, agent, overrides)
	return r


func _ticks(r: Runner, n: int, dt: float) -> void:
	for i in n:
		r.tick(dt)


func _has(list: Array, part: String) -> bool:
	return list.any(func(m): return part in m)


func check(ok: bool, label: String) -> void:
	if ok:
		_pass += 1
		print("ok   ", label)
	else:
		_fail += 1
		print("FAIL ", label)
