extends RefCounted
## BT 의 Task(task_type = TaskGraph) 하나를 Task Graph(BTT_) 로 실행 — Unreal 의 BTTask_BlueprintBase 처럼.
##   enter(): Event Receive Execute AI 에서 실행 시작 (Task 가 시작될 때 한 번).
##   비동기 노드(Move To Location·Wait)를 만나면 거기서 멈추고 RUNNING → tick 마다 이어서, 끝나면 그 출력 실행 핀으로.
##   기다리는 노드가 없고 Receive Tick AI 가 있으면 tick 마다 그 경로를 실행.
##   Finish Execute 에 닿으면 SUCCESS/FAILURE (한 번만 유효 — 그 뒤 실행은 무시).
##   abort(): Event Receive Abort AI 경로 (Stop Movement → Finish Abort). 그 뒤에는 무엇이 와도 되살아나지 않는다.
## 그래프에 오류가 있으면 실행하지 않고 FAILURE (에디터에서 오류를 보여 준다).

const Blackboard = preload("res://core/ai/blackboard.gd")
const Graph = preload("res://core/ai/task_graph.gd")
const SUCCESS := 0
const FAILURE := 1
const RUNNING := 2
const MAX_STEPS := 256
const MAX_EVAL_DEPTH := 64

var r: Object            # BT Runner (bb, agent, memory, _log)
var p: Dictionary        # BT 노드 params (graph_id)
var graph := {}
var bb_asset := {}
var nodes := {}
var exec_to := {}        # "node/pin" -> [node, pin]
var data_from := {}      # "node/pin" -> [node, pin]
var locals := {}
var result := -1         # Finish Execute 결과 (-1 = 아직)
var aborted := false
var abort_finished := false
var pending := {}        # 기다리는 비동기 노드 {node, kind, left, dest, run, acceptance}
var last_delta := 0.0
var trace: Array = []    # 실행한 노드 순서 (디버거)


func _init(runner: Object, params: Dictionary) -> void:
	r = runner
	p = params
	var all: Dictionary = r.assets if not r.assets.is_empty() else DataLoader.ai_assets
	graph = all.get(str(p.get("graph_id", "")), {})
	bb_asset = all.get(str(graph.get("blackboard_id", "")), {})
	nodes = Graph.index(graph)
	for c in graph.get("connections", []):
		var ft := Graph.pin_type(nodes.get(str(c.from_node), {}), str(c.from_pin), graph, bb_asset, true)
		if ft == "exec":
			exec_to["%s/%s" % [c.from_node, c.from_pin]] = [str(c.to_node), str(c.to_pin)]
		else:
			data_from["%s/%s" % [c.to_node, c.to_pin]] = [str(c.from_node), str(c.from_pin)]


func enter() -> int:
	if graph.is_empty():
		_log("없는 Task Graph '%s'" % p.get("graph_id", ""))
		return FAILURE
	var errs := Graph.validate(graph, {graph.blackboard_id: bb_asset, graph.id: graph}) if not bb_asset.is_empty() else [{"msg": "Blackboard 없음"}]
	if not errs.is_empty():
		_log("그래프 오류로 실행 안 함: " + str(errs[0].msg))
		return FAILURE
	locals.clear()
	for v in graph.get("variables", []):
		locals[str(v.name)] = Blackboard.coerce(str(v.type), v.get("default"))
	var start := _event("ReceiveExecuteAI")
	_run_from(start, "exec_out")
	return _status()


func tick(delta: float) -> int:
	if aborted or result >= 0:
		return result if result >= 0 else FAILURE
	last_delta = delta
	if not pending.is_empty():
		_tick_pending(delta)
	else:
		var t := _event("ReceiveTickAI")
		if t != "":
			_run_from(t, "exec_out")
		else:
			_log("기다리는 노드도 Tick 이벤트도 없이 Finish Execute 에 닿지 않음")
			result = FAILURE
	return _status()


func abort() -> void:
	if aborted:
		return
	aborted = true
	var was_pending := pending
	pending = {}
	var a := _event("ReceiveAbortAI")
	if a != "":
		_run_from(a, "exec_out", true)
	if not was_pending.is_empty() and was_pending.kind == "move":
		r.agent.ai_stop()   # Abort 경로가 없어도 이동은 멈춤 (안전)
	if a != "" and not abort_finished:
		_log("Receive Abort AI 경로가 Finish Abort 에 닿지 않음")


func _status() -> int:
	if result >= 0:
		return result
	return RUNNING


func _event(type: String) -> String:
	for id in nodes:
		if nodes[id].get("type") == type:
			return id
	return ""


# ---------------------------------------------------------------- 실행 핀
## node 의 출력 실행 핀 pin 에서 이어서 실행 (비동기 노드나 끝을 만날 때까지)
func _run_from(node: String, pin: String, aborting := false) -> void:
	var steps := 0
	while true:
		steps += 1
		if steps > MAX_STEPS:
			_log("한 번에 %d 노드를 넘음 (멈춤)" % MAX_STEPS)
			result = FAILURE
			return
		var to: Array = exec_to.get("%s/%s" % [node, pin], [])
		if to.is_empty():
			return
		node = to[0]
		var n: Dictionary = nodes[node]
		trace.append(node)
		if trace.size() > 200:
			trace.pop_front()
		var prm: Dictionary = n.get("params", {})
		match str(n.type):
			"Branch":
				pin = "true" if bool(_in(node, "condition")) else "false"
			"SetBlackboard":
				r.bb.set_value(str(prm.get("key", "")), _in(node, "value"), "Task")
				pin = "exec_out"
			"ClearBlackboard":
				r.bb.clear_value(str(prm.get("key", "")), "Task")
				pin = "exec_out"
			"SetVariable":
				var vn := str(prm.get("var", ""))
				locals[vn] = Blackboard.coerce(Graph.resolve_type("var", n, graph, bb_asset), _in(node, "value"))
				pin = "exec_out"
			"StopMovement":
				r.agent.ai_stop()
				pin = "exec_out"
			"RequestBattle":
				var ok: bool = not r.memory.get("battle_pending", false) and r.agent.ai_request_battle()
				if ok:
					r.memory["battle_pending"] = true
				pin = "on_success" if ok else "on_fail"
			"MoveToLocation":
				if aborting:
					return
				var dest: Variant = _in(node, "destination")
				if dest == null:
					pin = "on_fail"
					continue
				pending = {"node": node, "kind": "move", "dest": dest, "run": bool(prm.get("run", true)),
					"acceptance": float(prm.get("acceptance", 0.4))}
				return
			"Wait":
				if aborting:
					return
				pending = {"node": node, "kind": "wait", "left": float(_in(node, "seconds"))}
				if pending.left <= 0.0:
					pending = {}
					pin = "completed"
					continue
				return
			"FinishExecute":
				if aborting:
					_log("Abort 경로의 Finish Execute 는 무시")
				elif result < 0:
					result = SUCCESS if bool(prm.get("success", true)) else FAILURE
				return
			"FinishAbort":
				abort_finished = true
				return
			_:
				_log("실행할 수 없는 노드 '%s'" % n.type)
				return


func _tick_pending(delta: float) -> void:
	var node: String = pending.node
	match str(pending.kind):
		"wait":
			pending.left -= delta
			if pending.left <= 0.0:
				pending = {}
				_run_from(node, "completed")
		"move":
			var dest: Vector2 = pending.dest
			if r.agent.ai_tile().distance_to(dest) <= float(pending.acceptance):
				r.agent.ai_stop()
				pending = {}
				_run_from(node, "on_success")
				return
			match str(r.agent.ai_move(dest, bool(pending.run), delta)):
				"arrived":
					r.agent.ai_stop()
					pending = {}
					_run_from(node, "on_success")
				"blocked":
					r.agent.ai_stop()
					pending = {}
					_run_from(node, "on_fail")


# ---------------------------------------------------------------- 데이터 핀
## 입력 데이터 핀 값: 이어져 있으면 그 출력을 계산, 아니면 노드 params 의 같은 이름 값(핀 기본값)
func _in(node: String, pin: String, depth := 0) -> Variant:
	var t := Graph.pin_type(nodes[node], pin, graph, bb_asset, false)
	var src: Array = data_from.get("%s/%s" % [node, pin], [])
	var v: Variant
	if src.is_empty():
		v = nodes[node].get("params", {}).get(pin)
	else:
		v = _out(src[0], src[1], depth + 1)
	return Blackboard.coerce(t, v) if t in ["bool", "int", "float", "vector2", "entity_ref", "string"] else v


func _out(node: String, pin: String, depth: int) -> Variant:
	if depth > MAX_EVAL_DEPTH:
		_log("데이터 계산이 너무 깊음")
		return null
	var n: Dictionary = nodes[node]
	var prm: Dictionary = n.get("params", {})
	match str(n.type):
		"GetBlackboard": return r.bb.get_value(str(prm.get("key", "")))
		"GetVariable": return locals.get(str(prm.get("var", "")))
		"ReceiveTickAI": return last_delta
		"Compare":
			var a := float(_in(node, "a", depth))
			var b := float(_in(node, "b", depth))
			match str(prm.get("op", "<")):
				"<": return a < b
				"<=": return a <= b
				">": return a > b
				">=": return a >= b
				"==": return is_equal_approx(a, b)
				"!=": return not is_equal_approx(a, b)
			return false
		"AND": return bool(_in(node, "a", depth)) and bool(_in(node, "b", depth))
		"OR": return bool(_in(node, "a", depth)) or bool(_in(node, "b", depth))
		"NOT": return not bool(_in(node, "a", depth))
		"Distance":
			var a: Variant = _in(node, "a", depth)
			var b: Variant = _in(node, "b", depth)
			return a.distance_to(b) if a is Vector2 and b is Vector2 else 9999.0
		"GetActorPosition":
			return r.agent.ai_tile() if str(prm.get("who", "self")) == "self" else r.agent.ai_entity_tile("player")
	return null


func _log(msg: String) -> void:
	if r.has_method("_log"):
		r._log("graph", r.task_node if "task_node" in r else "", "", "[%s] %s" % [graph.get("id", "?"), msg])
