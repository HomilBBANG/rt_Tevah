extends Node
## Task Graph (Blueprint 스타일) 단위 테스트 — 기획 v2.0 §11 'Blueprint 스타일 Task Graph 검증'. 실행:
##   Godot_v4.7-stable_win64_console.exe --headless --path . res://tests/test_task_graph.tscn

const Runner = preload("res://core/ai/bt_runner.gd")
const Assets = preload("res://core/ai/ai_assets.gd")
const Graph = preload("res://core/ai/task_graph.gd")
const GraphRunner = preload("res://core/ai/task_graph_runner.gd")
const FakeAgent = preload("res://tests/test_bt.gd").FakeAgent

var _fail := 0
var _pass := 0


func _ready() -> void:
	var all := Assets.load_dir()
	var g: Dictionary = all.BTT_SearchLastPosition
	var bb: Dictionary = all.BB_Infected
	# ---------- 검사
	check(Graph.validate(g, all).is_empty(), "샘플 BTT_SearchLastPosition 오류 없음: %s" % [Graph.validate(g, all)])
	check(Assets.validate_all(all).is_empty(), "모든 샘플 자산 (BT_03_Stalker 의 TaskGraph 참조 포함) 오류 없음: %s" % [Assets.validate_all(all)])
	check(Graph.can_connect(g, bb, "get_loc", "value", "branch", "condition").contains("타입이 맞지 않음"), "Vector2 → Bool 연결 막음")
	check(Graph.can_connect(g, bb, "get_has", "value", "move", "exec_in").contains("타입이 맞지 않음"), "데이터 → 실행 핀 연결 막음")
	check(Graph.compatible("int", "float") and not Graph.compatible("float", "int"), "Int → Float 는 자동 변환, 반대는 안 됨")
	var bad := g.duplicate(true)
	bad.connections = bad.connections.filter(func(c): return not (c.from_node == "move" and c.from_pin == "on_fail"))
	check(_has(Graph.validate(bad, all), "'on_fail' 이 이어지지 않음"), "이동 실패 쪽에 Finish 가 없으면 오류")
	bad = g.duplicate(true)
	bad.connections.append({"from_node": "clear_ok", "from_pin": "exec_out", "to_node": "branch", "to_pin": "exec_in"})
	check(_has(Graph.validate(bad, all), "한 곳으로만"), "실행 출력은 한 곳으로만")
	bad = g.duplicate(true)
	bad.connections = bad.connections.filter(func(c): return c.from_node != "clear_ok")
	bad.connections.append({"from_node": "clear_ok", "from_pin": "exec_out", "to_node": "branch", "to_pin": "exec_in"})
	check(_has(Graph.validate(bad, all), "순환"), "실행 경로 순환 막음")
	bad = g.duplicate(true)
	bad.connections.append({"from_node": "get_has", "from_pin": "value", "to_node": "branch", "to_pin": "condition"})
	check(_has(Graph.validate(bad, all), "한 곳에서만"), "데이터 입력은 한 곳에서만")
	bad = g.duplicate(true)
	bad.nodes.append({"id": "evil", "type": "RunGDScript", "pos": [0, 0]})
	check(_has(Graph.validate(bad, all), "허용되지 않은 노드"), "허용 목록에 없는 노드 막음 (GDScript 실행 노드 없음)")
	bad = g.duplicate(true)
	bad.nodes[1].params.key = "Nope"
	check(_has(Graph.validate(bad, all), "없는 키"), "Blackboard 에 없는 키")

	# ---------- 실행: BT_03_Stalker (수색 = Task Graph)
	var ag := FakeAgent.new()
	ag.points = [Vector2(0, 0), Vector2(-3, 0)]   # 플레이어 반대쪽으로 순찰
	var r := Runner.new()
	r.assets = all
	r.setup(all.BT_03_Stalker, bb, ag)
	_ticks(r, 3, 0.1)
	check(r.task_node == "patrol", "처음엔 순찰")
	ag.player = Vector2(3, 0)
	_ticks(r, 3, 0.1)
	check(r.task_node == "move_to_target", "보이면 추격 (%s)" % r.task_node)
	ag.see = false
	ag.player = Vector2(-8, 0)
	ag.allow_battle = false
	_ticks(r, 2, 0.1)
	check(r.task_node == "search_last" and r.task is GraphRunner, "놓치면 수색 = Task Graph 실행 (%s)" % r.task_node)
	var gt: GraphRunner = r.task
	check(not gt.pending.is_empty() and gt.trace.slice(0, 2) == ["branch", "move"], "Receive Execute AI → Branch → Move To Location (비동기, 기다림 %s)" % [gt.trace])
	_ticks(r, 3, 0.1)
	check(gt.trace.count("move") == 1 and gt.trace.count("branch") == 1, "RUNNING 동안 다시 시작하지 않음 (Execute 한 번, Move 한 번)")
	var ok := false
	for i in 80:
		r.tick(0.1)
		if r.task_node == "patrol":
			ok = true
			break
	check(ok and gt.result == 0 and gt.trace.has("look") and gt.trace.has("finish_ok") and not r.bb.get_value("HasLastKnownLocation"),
		"도착 → Wait(SearchDuration) → Clear → Finish Execute(성공) → 순찰 (%s)" % [gt.trace])
	# 중단: 수색(그래프 이동) 중에 다시 보이면 Chase 가 선점 → Receive Abort AI → Stop Movement → Finish Abort
	ag.see = null
	ag.player = Vector2(-2.5, 0)
	_ticks(r, 3, 0.1)
	ag.see = false
	ag.player = Vector2(-12, 0)
	_ticks(r, 2, 0.1)
	check(r.task_node == "search_last", "다시 수색 시작")
	var gt2: GraphRunner = r.task
	var stops := ag.stops
	ag.see = true
	_ticks(r, 2, 0.1)
	check(r.task_node == "move_to_target" and gt2.aborted and gt2.abort_finished and gt2.trace.has("stop") and ag.stops > stops,
		"보이면 Chase 가 선점 → Receive Abort AI → Stop Movement → Finish Abort (%s)" % [gt2.trace])
	var bb_before: bool = r.bb.get_value("HasLastKnownLocation")
	var late := gt2.tick(100.0)
	check(late != 2 and r.bb.get_value("HasLastKnownLocation") == bb_before and r.task_node == "move_to_target", "중단된 그래프는 늦게 tick 해도 되살아나지 않음")
	# Branch false → Finish Execute(실패)
	var r3 := Runner.new()
	r3.assets = all
	r3.setup(_bt_with_graph("BTT_SearchLastPosition"), bb, FakeAgent.new())
	r3.tick(0.1)
	check(r3.last_result.get("g") == "FAILURE", "HasLastKnownLocation 없음 → Branch False → Finish Execute(실패)")
	# 오류 있는 그래프는 실행 안 함
	var broken := g.duplicate(true)
	broken.id = "BTT_Broken"
	broken.connections = broken.connections.filter(func(c): return c.from_node != "evt_execute")
	var all2 := all.duplicate()
	all2[broken.id] = broken
	var r4 := Runner.new()
	r4.assets = all2
	r4.setup(_bt_with_graph("BTT_Broken"), bb, FakeAgent.new())
	r4.tick(0.1)
	check(r4.last_result.get("g") == "FAILURE" and r4.log.any(func(e): return "그래프 오류로 실행 안 함" in e.reason), "오류 있는 그래프 → 실행 대신 FAILURE + 기록")
	# Request Battle: 한 번만
	var bg := {"schema_version": 2, "asset_type": "task_graph", "id": "BTT_Battle", "blackboard_id": "BB_Infected", "variables": [{"name": "Count", "type": "int", "default": 0}],
		"nodes": [{"id": "e", "type": "ReceiveExecuteAI"}, {"id": "rb", "type": "RequestBattle"}, {"id": "sv", "type": "SetVariable", "params": {"var": "Count", "value": 1}},
			{"id": "ok", "type": "FinishExecute", "params": {"success": true}}, {"id": "no", "type": "FinishExecute", "params": {"success": false}}],
		"connections": [{"from_node": "e", "from_pin": "exec_out", "to_node": "rb", "to_pin": "exec_in"},
			{"from_node": "rb", "from_pin": "on_success", "to_node": "sv", "to_pin": "exec_in"}, {"from_node": "sv", "from_pin": "exec_out", "to_node": "ok", "to_pin": "exec_in"},
			{"from_node": "rb", "from_pin": "on_fail", "to_node": "no", "to_pin": "exec_in"}]}
	check(Graph.validate(bg, all).is_empty(), "전투 요청 그래프 검사 통과: %s" % [Graph.validate(bg, all)])
	var all3 := all.duplicate()
	all3[bg.id] = bg
	var ba := FakeAgent.new()
	var r5 := Runner.new()
	r5.assets = all3
	r5.setup(_bt_with_graph("BTT_Battle"), bb, ba)
	_ticks(r5, 5, 0.1)
	check(ba.battles == 1 and r5.last_result.get("g") == "FAILURE", "Request Battle 은 전투가 끝날 때까지 한 번만 (%d)" % ba.battles)

	print("[test_task_graph] %d 통과, %d 실패" % [_pass, _fail])
	get_tree().quit(1 if _fail > 0 else 0)


func _bt_with_graph(gid: String) -> Dictionary:
	return {"asset_type": "behavior_tree", "id": "BT_G", "blackboard_id": "BB_Infected", "root_id": "root", "nodes": [
		{"id": "root", "kind": "Root", "children": ["seq"]}, {"id": "seq", "kind": "Sequence", "children": ["g"]},
		{"id": "g", "kind": "Task", "task_type": "TaskGraph", "params": {"graph_id": gid}}]}


func _ticks(r: Runner, n: int, dt: float) -> void:
	for i in n:
		r.tick(dt)


func _has(errs: Array, part: String) -> bool:
	return errs.any(func(e): return part in e.msg)


func check(ok: bool, label: String) -> void:
	if ok:
		_pass += 1
		print("ok   ", label)
	else:
		_fail += 1
		print("FAIL ", label)
