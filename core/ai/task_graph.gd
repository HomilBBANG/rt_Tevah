extends RefCounted
## Task Graph (BTT_ 자산) — BT 의 Task 하나의 속을 Blueprint 처럼 실행 핀 + 데이터 핀 노드로 짠 것. 몬스터 AI 기획 v2.0 §5.
## Unreal 의 BTTask_BlueprintBase Event Graph 를 연습하는 '테바 전용 소형 도구' — 실제 Blueprint 와 호환되는 자산은 아니다.
##
## 자산: {schema_version, asset_type:"task_graph", id, description, blackboard_id,
##        variables:[{name, type, default}],             # Task 지역 변수 (실행할 때마다 기본값으로)
##        nodes:[{id, type, params:{}, pos:[x,y]}],       # params: Blackboard 키·변수 이름·연결 안 한 입력 핀의 값 등
##        connections:[{from_node, from_pin, to_node, to_pin}]}
## 핀: 실행(exec, 흰색) — 출력 하나는 한 곳으로만, 입력은 여러 곳에서 / 데이터 — 입력 하나는 한 곳에서만, 출력은 여러 곳으로.
## 연결 안 한 데이터 입력은 노드 params 의 같은 이름 값(Blueprint 의 핀 기본값)을 쓴다.
## 허용된 노드만 (화이트리스트). GDScript 글을 실행하는 노드는 없다. 반복문·함수·매크로도 없다 (v1).

const Blackboard = preload("res://core/ai/blackboard.gd")

const TYPES := ["exec", "bool", "int", "float", "vector2", "entity_ref", "string"]
## 핀 색 (Unreal 과 비슷하게 — 색만이 아니라 핀 이름 옆에 타입도 적는다)
const TYPE_COLOR := {"exec": Color.WHITE, "bool": Color("b02020"), "int": Color("1fd2a6"), "float": Color("8ee34a"),
	"vector2": Color("f2c037"), "entity_ref": Color("4aa3ff"), "string": Color("ff4ad8"), "any": Color("aaaaaa")}

## 노드 정의. ins/outs: [[핀 이름, 타입], …] — 타입 "key" = 고른 Blackboard 키의 타입, "var" = 고른 변수의 타입
## params: 노드 고유 설정 [[이름, 종류, 기본값, 설명]] (종류: key/var/bool/number/op/who)
## async = 여러 tick 에 걸쳐 실행 (RUNNING), 끝나면 출력 실행 핀 중 하나로
const NODES := {
	"ReceiveExecuteAI": {"cat": "Event", "title": "Event Receive Execute AI", "ue": "Event Receive Execute AI (BTTask_BlueprintBase)",
		"desc": "Task 가 시작될 때 한 번. 여기서 실행이 시작된다.", "ins": [], "outs": [["exec_out", "exec"]]},
	"ReceiveTickAI": {"cat": "Event", "title": "Event Receive Tick AI", "ue": "Event Receive Tick AI",
		"desc": "Task 가 실행 중인 동안 매 tick (기다리는 비동기 노드가 없을 때). delta = 지난 tick 의 실제 초.",
		"ins": [], "outs": [["exec_out", "exec"], ["delta", "float"]]},
	"ReceiveAbortAI": {"cat": "Event", "title": "Event Receive Abort AI", "ue": "Event Receive Abort AI",
		"desc": "Task 가 강제로 중단될 때 (Observer Aborts·몬스터 제거 등). 이동을 멈추고 Finish Abort 로 끝낸다.",
		"ins": [], "outs": [["exec_out", "exec"]]},
	"Branch": {"cat": "Flow", "title": "Branch", "ue": "Branch (Flow Control)", "desc": "Condition 이 참이면 True, 거짓이면 False 로.",
		"ins": [["exec_in", "exec"], ["condition", "bool"]], "outs": [["true", "exec"], ["false", "exec"]]},
	"GetBlackboard": {"cat": "Data", "title": "Get Blackboard Value", "ue": "Get Blackboard Value as … (Bool/Float/Vector …)",
		"desc": "Blackboard 키 값 읽기 (데이터 노드 — 실행 핀 없음).", "ins": [], "outs": [["value", "key"]],
		"params": [["key", "key", "", "읽을 키"]]},
	"SetBlackboard": {"cat": "Data", "title": "Set Blackboard Value", "ue": "Set Blackboard Value as …",
		"desc": "Blackboard 키에 값 쓰기 → 그 키를 보는 Decorator 의 Observer Aborts 가 반응할 수 있다.",
		"ins": [["exec_in", "exec"], ["value", "key"]], "outs": [["exec_out", "exec"]], "params": [["key", "key", "", "쓸 키"]]},
	"ClearBlackboard": {"cat": "Data", "title": "Clear Blackboard Value", "ue": "Clear Blackboard Value",
		"desc": "키를 비움 (bool false, 위치 없음).", "ins": [["exec_in", "exec"]], "outs": [["exec_out", "exec"]],
		"params": [["key", "key", "", "비울 키"]]},
	"GetVariable": {"cat": "Data", "title": "Get Variable", "ue": "Get (변수)", "desc": "이 Task Graph 의 지역 변수 읽기.",
		"ins": [], "outs": [["value", "var"]], "params": [["var", "var", "", "변수"]]},
	"SetVariable": {"cat": "Data", "title": "Set Variable", "ue": "Set (변수)", "desc": "지역 변수에 값 쓰기 (실행할 때마다 기본값에서 시작).",
		"ins": [["exec_in", "exec"], ["value", "var"]], "outs": [["exec_out", "exec"]], "params": [["var", "var", "", "변수"]]},
	"Compare": {"cat": "Data", "title": "Compare (Float)", "ue": "Less / Greater / Equal (Float)", "desc": "두 수를 비교해 Bool.",
		"ins": [["a", "float"], ["b", "float"]], "outs": [["result", "bool"]], "params": [["op", "op", "<", "비교"]]},
	"AND": {"cat": "Data", "title": "AND", "ue": "AND Boolean", "desc": "둘 다 참이면 참.", "ins": [["a", "bool"], ["b", "bool"]], "outs": [["result", "bool"]]},
	"OR": {"cat": "Data", "title": "OR", "ue": "OR Boolean", "desc": "하나라도 참이면 참.", "ins": [["a", "bool"], ["b", "bool"]], "outs": [["result", "bool"]]},
	"NOT": {"cat": "Data", "title": "NOT", "ue": "NOT Boolean", "desc": "참·거짓을 뒤집음.", "ins": [["a", "bool"]], "outs": [["result", "bool"]]},
	"Distance": {"cat": "Data", "title": "Distance (Vector2)", "ue": "Distance (Vector) — 테바는 2D 칸 좌표",
		"desc": "두 위치 사이 거리 (칸).", "ins": [["a", "vector2"], ["b", "vector2"]], "outs": [["result", "float"]]},
	"GetActorPosition": {"cat": "Data", "title": "Get Actor Position", "ue": "Get Actor Location (테바는 칸 좌표 Vector2)",
		"desc": "몬스터 자신 또는 플레이어의 위치 (칸).", "ins": [], "outs": [["position", "vector2"]],
		"params": [["who", "who", "self", "누구"]]},
	"MoveToLocation": {"cat": "Action", "title": "Move To Location", "ue": "AI Move To (비동기 노드)", "async": true,
		"desc": "목적지로 이동 (벽을 돌아가는 길). 도착하면 On Success, 막히면 On Fail. 이동 중엔 Task 가 RUNNING.",
		"ins": [["exec_in", "exec"], ["destination", "vector2"]], "outs": [["on_success", "exec"], ["on_fail", "exec"]],
		"params": [["run", "bool", true, "달리기"], ["acceptance", "number", 0.4, "도착으로 보는 거리 (칸)"]]},
	"StopMovement": {"cat": "Action", "title": "Stop Movement", "ue": "Stop Movement", "desc": "이동을 멈춤.",
		"ins": [["exec_in", "exec"]], "outs": [["exec_out", "exec"]]},
	"Wait": {"cat": "Action", "title": "Wait (Delay)", "ue": "Delay (비동기)", "async": true,
		"desc": "Seconds 동안 기다린 뒤 Completed (실제 초 — 전투·대화·메뉴 중엔 멈춤).",
		"ins": [["exec_in", "exec"], ["seconds", "float"]], "outs": [["completed", "exec"]]},
	"RequestBattle": {"cat": "Action", "title": "Request Battle", "ue": "(테바 전용) 턴제 전투 시작",
		"desc": "플레이어와 턴제 전투 시작 요청. 시작하면 On Success, 못 하면(도주 직후 유예 등) On Fail. 전투가 끝날 때까지 다시 요청하지 않음.",
		"ins": [["exec_in", "exec"]], "outs": [["on_success", "exec"], ["on_fail", "exec"]]},
	"FinishExecute": {"cat": "Result", "title": "Finish Execute", "ue": "Finish Execute (Success)",
		"desc": "Task 를 끝냄 (Success 체크 = SUCCESS, 아니면 FAILURE). 한 번만 유효.",
		"ins": [["exec_in", "exec"]], "outs": [], "params": [["success", "bool", true, "성공"]]},
	"FinishAbort": {"cat": "Result", "title": "Finish Abort", "ue": "Finish Abort", "desc": "중단 정리가 끝났음을 알림.",
		"ins": [["exec_in", "exec"]], "outs": []},
}
const CATS := ["Event", "Flow", "Data", "Action", "Result"]
const OPS := ["<", "<=", ">", ">=", "==", "!="]
const EVENTS := ["ReceiveExecuteAI", "ReceiveTickAI", "ReceiveAbortAI"]


## 노드의 핀 [[이름, 타입], …] (key/var 타입은 고른 키·변수로 바꿔서)
static func pins(n: Dictionary, graph: Dictionary, bb: Dictionary, outs: bool) -> Array:
	var def: Dictionary = NODES.get(str(n.get("type", "")), {})
	var out := []
	for p in def.get("outs" if outs else "ins", []):
		out.append([p[0], resolve_type(p[1], n, graph, bb)])
	return out


static func resolve_type(t: String, n: Dictionary, graph: Dictionary, bb: Dictionary) -> String:
	match t:
		"key":
			var key := str(n.get("params", {}).get("key", ""))
			for k in bb.get("keys", []):
				if str(k.name) == key:
					return str(k.type)
			return "any"
		"var":
			var vn := str(n.get("params", {}).get("var", ""))
			for v in graph.get("variables", []):
				if str(v.name) == vn:
					return str(v.type)
			return "any"
	return t


static func pin_type(n: Dictionary, pin: String, graph: Dictionary, bb: Dictionary, outs: bool) -> String:
	for p in pins(n, graph, bb, outs):
		if p[0] == pin:
			return p[1]
	return ""


## from(출력) → to(입력) 타입 연결이 되나 (int → float 는 자동 변환)
static func compatible(from_t: String, to_t: String) -> bool:
	if from_t == "" or to_t == "" or from_t == "any" or to_t == "any":
		return false
	if from_t == "exec" or to_t == "exec":
		return from_t == to_t
	return from_t == to_t or (from_t == "int" and to_t == "float")


## 연결을 추가해도 되나 → "" 이면 됨, 아니면 이유
static func can_connect(graph: Dictionary, bb: Dictionary, from_node: String, from_pin: String, to_node: String, to_pin: String) -> String:
	var nodes := index(graph)
	if not nodes.has(from_node) or not nodes.has(to_node):
		return "없는 노드"
	if from_node == to_node:
		return "자기 자신에게는 연결할 수 없음"
	var ft := pin_type(nodes[from_node], from_pin, graph, bb, true)
	var tt := pin_type(nodes[to_node], to_pin, graph, bb, false)
	if ft == "" or tt == "":
		return "없는 핀"
	if not compatible(ft, tt):
		return "타입이 맞지 않음: %s → %s" % [ft, tt]
	return ""


static func index(graph: Dictionary) -> Dictionary:
	var out := {}
	for n in graph.get("nodes", []):
		out[str(n.id)] = n
	return out


## 검사 → [{node, msg}]
static func validate(graph: Dictionary, all: Dictionary) -> Array:
	var errs := []
	var nodes := index(graph)
	var bb: Dictionary = all.get(str(graph.get("blackboard_id", "")), {})
	if bb.is_empty():
		errs.append({"node": "", "msg": "Blackboard 자산이 없음: '%s'" % graph.get("blackboard_id", "")})
	var counts := {}
	for id in nodes:
		var n: Dictionary = nodes[id]
		var t := str(n.get("type", ""))
		if not NODES.has(t):
			errs.append({"node": id, "msg": "허용되지 않은 노드 '%s'" % t})
			continue
		counts[t] = counts.get(t, 0) + 1
		for p in NODES[t].get("params", []):
			var v = n.get("params", {}).get(p[0], p[2])
			if p[1] == "key":
				if resolve_type("key", n, graph, bb) == "any":
					errs.append({"node": id, "msg": "Blackboard 에 없는 키 '%s'" % v})
			elif p[1] == "var":
				if resolve_type("var", n, graph, bb) == "any":
					errs.append({"node": id, "msg": "없는 변수 '%s'" % v})
	if counts.get("ReceiveExecuteAI", 0) != 1:
		errs.append({"node": "", "msg": "Event Receive Execute AI 가 정확히 하나 있어야 함 (지금 %d)" % counts.get("ReceiveExecuteAI", 0)})
	for ev in ["ReceiveTickAI", "ReceiveAbortAI"]:
		if counts.get(ev, 0) > 1:
			errs.append({"node": "", "msg": "%s 는 하나만" % ev})
	var seen_names := {}
	for v in graph.get("variables", []):
		if not str(v.get("type", "")) in TYPES or v.type == "exec":
			errs.append({"node": "", "msg": "변수 %s 의 타입 '%s'" % [v.get("name", "?"), v.get("type", "")]})
		if seen_names.has(v.get("name")):
			errs.append({"node": "", "msg": "변수 이름이 겹침: %s" % v.get("name")})
		seen_names[v.get("name")] = true
	# 연결
	var exec_out := {}   # "node/pin" -> to
	var data_in := {}    # "node/pin" -> from
	for c in graph.get("connections", []):
		var why := can_connect(graph, bb, str(c.from_node), str(c.from_pin), str(c.to_node), str(c.to_pin))
		if why != "":
			errs.append({"node": str(c.get("to_node", "")), "msg": "연결 %s.%s → %s.%s: %s" % [c.from_node, c.from_pin, c.to_node, c.to_pin, why]})
			continue
		var ft := pin_type(nodes[str(c.from_node)], str(c.from_pin), graph, bb, true)
		if ft == "exec":
			var k := "%s/%s" % [c.from_node, c.from_pin]
			if exec_out.has(k):
				errs.append({"node": str(c.from_node), "msg": "실행 출력 '%s' 은 한 곳으로만" % c.from_pin})
			exec_out[k] = [str(c.to_node), str(c.to_pin)]
		else:
			var k := "%s/%s" % [c.to_node, c.to_pin]
			if data_in.has(k):
				errs.append({"node": str(c.to_node), "msg": "데이터 입력 '%s' 은 한 곳에서만" % c.to_pin})
			data_in[k] = [str(c.from_node), str(c.from_pin)]
	# 실행 경로: Execute(·Tick) 에서 닿는 모든 실행 출력은 이어져야 하고 Finish Execute 로 끝나야 함. 순환 금지.
	for ev in nodes:
		var t := str(nodes[ev].get("type", ""))
		if not t in EVENTS:
			continue
		var want := "FinishAbort" if t == "ReceiveAbortAI" else "FinishExecute"
		var visiting := {}
		var finished := [false]
		_walk_exec(ev, nodes, graph, bb, exec_out, visiting, {}, errs, want, t, finished)
		if t == "ReceiveExecuteAI" and not finished[0]:
			errs.append({"node": ev, "msg": "Finish Execute 에 닿지 않음 (Task 가 끝나지 않는다)"})
	# 데이터 순환
	for id in nodes:
		if _data_cycle(id, data_in, {}, 0):
			errs.append({"node": id, "msg": "데이터 핀이 순환함"})
			break
	return errs


static func _walk_exec(id: String, nodes: Dictionary, graph: Dictionary, bb: Dictionary, exec_out: Dictionary,
		visiting: Dictionary, done: Dictionary, errs: Array, want: String, event: String, finished: Array) -> void:
	if visiting.has(id):
		errs.append({"node": id, "msg": "실행 경로가 순환함 (반복은 v1 에서 지원 안 함)"})
		return
	if done.has(id):
		return
	visiting[id] = true
	var n: Dictionary = nodes[id]
	var t := str(n.get("type", ""))
	if t == want:
		finished[0] = true
	elif t in ["FinishExecute", "FinishAbort"]:
		errs.append({"node": id, "msg": "%s 경로에는 %s 를 써야 함" % [event, want]})
	for p in pins(n, graph, bb, true):
		if p[1] != "exec":
			continue
		var k := "%s/%s" % [id, p[0]]
		if not exec_out.has(k):
			if event != "ReceiveTickAI":   # Tick 은 끝을 안 이어도 됨 (다음 tick 에 다시)
				errs.append({"node": id, "msg": "실행 출력 '%s' 이 이어지지 않음 (끝은 %s)" % [p[0], want]})
			continue
		_walk_exec(exec_out[k][0], nodes, graph, bb, exec_out, visiting, done, errs, want, event, finished)
	visiting.erase(id)
	done[id] = true


static func _data_cycle(id: String, data_in: Dictionary, path: Dictionary, depth: int) -> bool:
	if path.has(id) or depth > 64:
		return true
	path[id] = true
	for k in data_in:
		if k.begins_with(id + "/"):
			if _data_cycle(data_in[k][0], data_in, path, depth + 1):
				return true
	path.erase(id)
	return false
