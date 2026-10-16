extends RefCounted
## 몬스터 한 마리의 Behavior Tree 실행기 (Unreal 의 BehaviorTreeComponent 에 해당). 몬스터 기획 tevah_monster_bt_blueprint_style_spec_v2.0 §3, §7.
## BT 자산(정의)은 여러 몬스터가 같이 쓰고, 이 객체(실행 위치·Task·Service 타이머)와 Blackboard 값은 몬스터마다 따로.
##
## 실행 규칙 (Unreal 과 같게):
##   - Root → 자식 하나. Selector 는 왼쪽(children 앞쪽)부터 시도해 하나가 SUCCESS 면 SUCCESS, Sequence 는 하나가 FAILURE 면 FAILURE.
##   - 들어가기 전에 그 노드의 Decorator 를 모두(AND) 본다 — 하나라도 false 면 그 노드는 FAILURE.
##   - Task 가 RUNNING 이면 트리를 다시 뒤지지 않고 그 Task 만 이어서 돌린다 (다시 시작하지 않음).
##   - 트리가 끝나면(Root 결과) 다음 tick 에 처음부터 다시 (Unreal 처럼 반복).
##   - Observer Aborts: Blackboard 값이 바뀌면 그 키를 보는 Decorator 만 다시 판정 —
##       Self: 실행 중인 자기 분기의 조건이 false 가 되면 그 분기를 중단(FAILURE)하고 부모가 다음으로.
##       Lower Priority: 실행 중이 아닌 자기 분기의 조건이 true 가 되면, 오른쪽(낮은 우선순위)에서 실행 중인 분기를 중단하고 자기로.
##       Both: 둘 다. None: 중단 안 함 (다음에 그 노드에 들어갈 때만 판정).
##   - Service: 붙은 노드가 실행 경로(스택)에 있는 동안만 interval 초마다 실행 (random_deviation, run_on_activation).
##   - 중단된 Task 는 abort() 를 받고 정리(이동 멈춤). 결과는 디버그에 ABORTED 로 남기지만 BT 결과(SUCCESS/FAILURE/RUNNING)와는 따로.
## 시간: tick(delta) 의 delta = 실제 초. 필드가 멈춘 동안(전투·대화·메뉴)은 tick 이 오지 않으므로 Task 의 초도 멈춘다.

const Blackboard = preload("res://core/ai/blackboard.gd")
const Tasks = preload("res://core/ai/bt_tasks.gd")

enum { SUCCESS, FAILURE, RUNNING }
const RESULT_NAME := ["SUCCESS", "FAILURE", "RUNNING"]
const COMPOSITES := ["Selector", "Sequence"]
const ENTERING := -1
const MAX_STEPS := 512        # 한 번에 진행할 수 있는 단계 수 (무한 반복 보호)
const MAX_ABORT_ROUNDS := 16  # 한 tick 의 연쇄 중단 횟수 보호
const LOG_MAX := 200

signal debug_event(entry: Dictionary)

var asset := {}
var nodes := {}            # id -> 노드
var parent_of := {}        # id -> 부모 id
var bb: Blackboard
var agent: Object          # 몬스터 쪽 어댑터 (ai_tile, ai_move, ai_stop, ai_perceive, ai_request_battle …) — bt_tasks.gd 참고
var stack: Array = []      # 실행 경로 [{id, child_i}] (Root 부터 실행 중인 노드까지)
var task: Object = null    # RUNNING 중인 Task
var task_node := ""
var services: Array = []   # 실행 중인 Service [{node, def, left}]
var memory := {}           # Task 가 개체별로 기억할 것 (순찰 지점 번호, 전투 요청 중 …)
var last_result := {}      # node id -> "SUCCESS"/"FAILURE"/"RUNNING"/"ABORTED" (디버거)
var last_decorator := {}   # "node id/번호" -> bool (디버거)
var last_exit_time := {}   # node id -> 끝난 시각 (Cooldown)
var log: Array = []        # 디버그 기록 [{t, ev, node, result, reason}]
var time := 0.0
var error := ""            # 실행을 멈춘 오류 (자산 오류 등)
var _dirty := {}           # 바뀐 Blackboard 키 (다음 안전한 때에 Observer Aborts 처리)
var _observers := {}       # key -> [그 키를 보는 Decorator 가 붙은 node id]
var _order := {}           # node id -> 트리 순서 (왼쪽·위가 작음)


## bt: BT_ 자산, bb_asset: BB_ 자산, overrides: 이 개체만의 Blackboard 시작값 (맵 에디터의 인스턴스 override)
func setup(bt: Dictionary, bb_asset: Dictionary, agent_obj: Object, overrides := {}) -> void:
	asset = bt
	agent = agent_obj
	nodes.clear()
	parent_of.clear()
	_observers.clear()
	for n in bt.get("nodes", []):
		nodes[str(n.id)] = n
	for id in nodes:
		for c in nodes[id].get("children", []):
			parent_of[str(c)] = id
		for d in nodes[id].get("decorators", []):
			var key := str(d.get("key", ""))
			if key != "" and d.get("type", "") == "Blackboard":
				if not _observers.has(key):
					_observers[key] = []
				if not id in _observers[key]:
					_observers[key].append(id)
	_order.clear()
	_number(str(bt.get("root_id", "")), [0])
	bb = Blackboard.new()
	bb.setup(bb_asset, overrides)
	bb.changed.connect(_on_bb_changed)
	if not nodes.has(str(bt.get("root_id", ""))):
		error = "Root 가 없음"


func _number(id: String, n: Array) -> void:
	if not nodes.has(id) or _order.has(id):
		return
	_order[id] = n[0]
	n[0] += 1
	for c in nodes[id].get("children", []):
		_number(str(c), n)


## 한 번 진행 (몬스터의 _physics_process 에서). delta = 실제 초.
func tick(delta: float) -> void:
	if error != "":
		return
	time += delta
	bb.clock = time
	if stack.is_empty():
		_log("tree", str(asset.get("root_id", "")), "", "트리 처음부터")
		_push(str(asset.get("root_id", "")))
		_run(ENTERING)
	_tick_services(delta)
	_process_aborts()
	if task != null:
		var r: int = task.tick(delta)
		if r != RUNNING and task != null:
			_finish_task(r)
	_process_aborts()


## 모두 멈춤 (맵 이동·사망·몬스터 제거·전투 진입). Task 는 abort, Service 는 정지.
func stop(reason := "정지") -> void:
	_abort_to(0, reason)
	_dirty.clear()


## 회차 재시작: 멈추고 Blackboard 를 기본값으로
func reset() -> void:
	stop("초기화")
	bb.reset()
	memory.clear()
	last_result.clear()
	last_decorator.clear()


## 전투가 끝나면 필드가 부른다 — EnterTurnBattle 의 중복 방지 잠금을 푼다
func notify_battle_end() -> void:
	memory.erase("battle_pending")


## 실행 경로의 node id (Root → 실행 중인 노드)
func active_path() -> Array:
	return stack.map(func(f): return f.id)


func is_active(id: String) -> bool:
	return _stack_index(id) >= 0


# ---------------------------------------------------------------- 실행
## 스택 맨 위 노드를 진행한다. result = ENTERING(막 들어옴) 또는 방금 끝난 자식의 결과.
func _run(result: int) -> void:
	var steps := 0
	while not stack.is_empty():
		steps += 1
		if steps > MAX_STEPS:
			_fail_hard("한 번에 %d 단계를 넘음 (무한 반복?)" % MAX_STEPS)
			return
		var f: Dictionary = stack.back()
		var n: Dictionary = nodes[f.id]
		var kids: Array = n.get("children", [])
		match str(n.kind):
			"Root":
				if result == ENTERING:
					result = _enter(str(kids[0])) if not kids.is_empty() else FAILURE
					continue
				_pop(result)
				return   # 트리 한 바퀴 끝 → 다음 tick 에 처음부터
			"Selector", "Sequence":
				if result != ENTERING:
					var stop_on := SUCCESS if n.kind == "Selector" else FAILURE
					if result == stop_on:
						result = _pop(result)
						continue
					f.child_i += 1
				if f.child_i >= kids.size():
					result = _pop(FAILURE if n.kind == "Selector" else SUCCESS)
					continue
				result = _enter(str(kids[f.child_i]))
			"Task":
				if result != ENTERING:
					result = _pop(result)
					continue
				var t: Object = Tasks.make(n, self)
				if t == null:
					_log("task", f.id, "FAILURE", "알 수 없는 Task '%s'" % n.get("task_type", ""))
					result = _pop(FAILURE)
					continue
				task = t
				task_node = f.id
				var r: int = t.enter()
				if r == RUNNING and task == t:
					last_result[f.id] = "RUNNING"
					_log("task", f.id, "RUNNING", "시작")
					return
				if task == t:
					task = null
					task_node = ""
				result = _pop(r)
			_:
				_fail_hard("알 수 없는 노드 종류 '%s' (%s)" % [n.kind, f.id])
				return


## 노드에 들어가기: Decorator 를 모두 통과하면 스택에 올리고 ENTERING, 아니면 FAILURE
func _enter(id: String) -> int:
	if not nodes.has(id):
		_log("enter", id, "FAILURE", "없는 노드")
		return FAILURE
	if stack.size() > 64:
		_fail_hard("트리가 너무 깊음")
		return FAILURE
	if not _decorators_pass(id, true):
		last_result[id] = "FAILURE"
		return FAILURE
	_push(id)
	return ENTERING


func _push(id: String, child_i := 0) -> void:
	stack.append({"id": id, "child_i": child_i})
	_log("enter", id, "", "")
	for s in nodes[id].get("services", []):
		var e := {"node": id, "def": s, "left": _interval(s)}
		services.append(e)
		if bool(s.get("run_on_activation", true)):
			_run_service(e)


## 맨 위 노드를 끝냄 → 결과를 그대로 돌려준다 (부모가 받음)
func _pop(result: int) -> int:
	var f: Dictionary = stack.pop_back()
	_stop_services(f.id)
	last_result[f.id] = RESULT_NAME[result]
	last_exit_time[f.id] = time
	_log("exit", f.id, RESULT_NAME[result], "")
	return result


func _finish_task(r: int) -> void:
	var id := task_node
	task = null
	task_node = ""
	_log("task", id, RESULT_NAME[r], "끝")
	if not stack.is_empty() and stack.back().id == id:
		_run(_pop(r))


## 스택을 i 번째 위치까지 줄인다 (그 위는 모두 중단). 실행 중인 Task 는 abort().
func _abort_to(i: int, reason: String) -> void:
	while stack.size() > i:
		var f: Dictionary = stack.pop_back()
		if f.id == task_node and task != null:
			var t := task
			task = null
			task_node = ""
			t.abort()
			_log("abort", f.id, "ABORTED", reason)
		_stop_services(f.id)
		last_result[f.id] = "ABORTED"
		last_exit_time[f.id] = time


func _fail_hard(msg: String) -> void:
	error = msg
	push_error("[BT %s] %s" % [asset.get("id", ""), msg])
	_log("error", stack.back().id if not stack.is_empty() else "", "FAILURE", msg)
	_abort_to(0, "오류")


# ---------------------------------------------------------------- Decorator
func _decorators_pass(id: String, record: bool) -> bool:
	var ok := true
	var ds: Array = nodes[id].get("decorators", [])
	for i in ds.size():
		var v := _decorator_value(id, ds[i])
		if record:
			last_decorator["%s/%d" % [id, i]] = v
		if not v:
			ok = false
			if record:
				_log("decorator", id, "FAILURE", "%s = false" % decorator_text(ds[i]))
	return ok


func _decorator_value(id: String, d: Dictionary) -> bool:
	var v := true
	match str(d.get("type", "")):
		"Blackboard":
			v = compare(bb.get_value(str(d.get("key", ""))), str(d.get("operator", "is_set")), d.get("value"))
		"Cooldown":
			v = not last_exit_time.has(id) or time - float(last_exit_time[id]) >= float(d.get("seconds", 1.0))
		_:
			v = false
	return not v if bool(d.get("inverse", false)) else v


## Blackboard Check 비교. 연산자: is_set / is_not_set / == / != / < / <= / > / >=
static func compare(a: Variant, op: String, b: Variant) -> bool:
	match op:
		"is_set": return Blackboard.is_set(a)
		"is_not_set": return not Blackboard.is_set(a)
	if a == null:
		return op == "!="
	if a is Vector2:
		b = Blackboard.coerce("vector2", b)
	elif a is bool:
		b = bool(b)
	elif a is float or a is int:
		b = float(b) if b != null else 0.0
		a = float(a)
	else:
		b = str(b)
	match op:
		"==", "equals": return a == b
		"!=", "not_equals": return a != b
		"<": return a < b
		"<=": return a <= b
		">": return a > b
		">=": return a >= b
	return false


static func decorator_text(d: Dictionary) -> String:
	var name := str(d.get("name", ""))
	if name != "":
		return name
	match str(d.get("type", "")):
		"Blackboard":
			var op := str(d.get("operator", "is_set"))
			var t := "%s %s" % [d.get("key", "?"), {"is_set": "있음", "is_not_set": "없음"}.get(op, op)]
			if not op in ["is_set", "is_not_set"]:
				t += " " + Blackboard.show(d.get("value"))
			return ("NOT " if d.get("inverse", false) else "") + t
		"Cooldown":
			return "Cooldown %s초" % d.get("seconds", 1.0)
	return str(d.get("type", "?"))


func _on_bb_changed(key: String, _old: Variant, _new: Variant, _source: String) -> void:
	if _observers.has(key):
		_dirty[key] = true


## Observer Aborts: 바뀐 키를 보는 Decorator 만 다시 판정 (매 프레임 트리 전체를 다시 뒤지지 않는다)
func _process_aborts() -> void:
	var rounds := 0
	while not _dirty.is_empty() and error == "":
		rounds += 1
		if rounds > MAX_ABORT_ROUNDS:
			_log("error", "", "", "연쇄 중단이 %d 번을 넘음 — 이번 tick 은 멈춤" % MAX_ABORT_ROUNDS)
			_dirty.clear()
			return
		var ids := {}
		for key in _dirty:
			for id in _observers.get(key, []):
				ids[id] = true
		_dirty.clear()
		var sorted: Array = ids.keys()
		sorted.sort_custom(func(a, b): return _order.get(a, 0) < _order.get(b, 0))
		for id in sorted:
			if _check_abort(id):
				break   # 실행 경로가 바뀜 — 남은 것은 다음 바퀴에 (그사이 바뀐 키는 _dirty 에 다시 들어온다)


func _check_abort(id: String) -> bool:
	var ok := _decorators_pass(id, true)
	var policy := _abort_policy(id)
	var at := _stack_index(id)
	if at >= 0:
		if not ok and policy in ["Self", "Both"]:
			_log("observer_abort", id, "ABORTED", "Self — 조건이 false 가 됨")
			_abort_to(at, "Observer Aborts: Self (%s)" % id)
			last_result[id] = "FAILURE"
			if not stack.is_empty():
				_run(FAILURE)
			return true
		return false
	if not ok or not policy in ["LowerPriority", "Both"]:
		return false
	# 실행 중이 아닌 높은 우선순위 분기의 조건이 true → 실행 경로와 갈라지는 조상 Composite 에서 그쪽으로
	var child := id
	var anc: String = parent_of.get(id, "")
	while anc != "" and _stack_index(anc) < 0:
		child = anc
		anc = parent_of.get(anc, "")
	if anc == "":
		return false
	var ai := _stack_index(anc)
	if not str(nodes[anc].kind) in COMPOSITES:
		return false
	var my_i: int = nodes[anc].children.find(child)
	if my_i < 0 or my_i >= int(stack[ai].child_i) or ai == stack.size() - 1:
		return false   # 오른쪽(낮은 우선순위)이거나 지금 실행 중인 바로 그 분기
	_log("observer_abort", id, "ABORTED", "Lower Priority — 조건이 true 가 되어 낮은 우선순위 분기를 중단")
	_abort_to(ai + 1, "Observer Aborts: Lower Priority (%s)" % id)
	stack[ai].child_i = my_i
	_run(_enter(child))
	return true


## 노드의 Decorator 중 가장 넓은 중단 정책 (여러 개면 합침)
func _abort_policy(id: String) -> String:
	var self_ := false
	var lower := false
	for d in nodes[id].get("decorators", []):
		match str(d.get("observer_aborts", "None")):
			"Self": self_ = true
			"LowerPriority", "Lower Priority": lower = true
			"Both": self_ = true; lower = true
	if self_ and lower:
		return "Both"
	return "Self" if self_ else ("LowerPriority" if lower else "None")


func _stack_index(id: String) -> int:
	for i in stack.size():
		if stack[i].id == id:
			return i
	return -1


# ---------------------------------------------------------------- Service
func _interval(s: Dictionary) -> float:
	var base := maxf(0.01, float(s.get("interval", 0.5)))
	var dev := float(s.get("random_deviation", 0.0))
	return maxf(0.01, base + (randf_range(-dev, dev) if dev > 0.0 else 0.0))


func _tick_services(delta: float) -> void:
	for e in services.duplicate():
		if not e in services:
			continue
		e.left -= delta
		if e.left <= 0.0001:   # 소수 오차 (0.5 - 0.1×5 ≠ 0)
			e.left = maxf(e.left + _interval(e.def), 0.0001)   # 남은 시간을 이어서 → 주기가 밀리지 않음
			_run_service(e)


func _run_service(e: Dictionary) -> void:
	e["runs"] = int(e.get("runs", 0)) + 1
	if not Tasks.run_service(e.def, self):
		_log("service", e.node, "", "알 수 없는 Service '%s'" % e.def.get("type", ""))


func _stop_services(id: String) -> void:
	services = services.filter(func(e): return e.node != id)


# ---------------------------------------------------------------- 디버그
func _log(ev: String, node: String, result: String, reason: String) -> void:
	var e := {"t": snappedf(time, 0.01), "ev": ev, "node": node, "result": result, "reason": reason}
	log.append(e)
	if log.size() > LOG_MAX:
		log.pop_front()
	debug_event.emit(e)


func node_name(id: String) -> String:
	var n: Dictionary = nodes.get(id, {})
	var nm := str(n.get("name", ""))
	return nm if nm != "" else "%s (%s)" % [n.get("task_type", n.get("kind", "?")), id]
