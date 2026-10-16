extends RefCounted
## BT 의 Task·Service 기본 목록 (Unreal 의 BTTask_* / BTService_* 에 해당). 허용된 것만 — 임의 코드를 실행하는 노드는 없다.
##
## 몬스터 쪽 어댑터(agent)가 갖출 함수 — 기존 이동·충돌·시야·전투 규칙을 다시 만들지 않고 이것으로 부른다:
##   ai_tile() -> Vector2                      지금 위치 (칸 좌표, 소수 가능)
##   ai_move(to: Vector2, run: bool, delta) -> String   한 tick 이동: "moving" / "arrived" / "blocked"
##   ai_stop()                                 멈춤
##   ai_patrol_points() -> Array               순찰 지점들 (칸 좌표)
##   ai_origin() -> Vector2                    처음 자리
##   ai_perceive(range_tiles: float) -> Dictionary   {visible, id, pos(칸), distance(칸)} — 시야(벽·닫힌 문 너머 안 보임)
##   ai_entity_tile(id: String) -> Variant     그 ID 의 위치 (칸, 없으면 null)
##   ai_noise() -> Dictionary                  들린 소리 {pos} 또는 {} (TODO: 소리 시스템 없음 — 지금은 늘 {})
##   ai_request_battle() -> bool               턴제 전투 시작 요청 (필드가 띄움). 못 하면 false (도주 직후 유예 등)
##
## 시간 값(seconds 등)은 모두 '실제 초' — 필드가 멈춘 동안(전투·대화·메뉴)은 흐르지 않는다.

const Blackboard = preload("res://core/ai/blackboard.gd")
const SUCCESS := 0
const FAILURE := 1
const RUNNING := 2

## 에디터 목록·도움말 (Unreal 대응 이름). params: [이름, 종류(number/bool/key:타입/key_any/value), 기본값, 설명]
const TASKS := {
	"Wait": {"ue": "BTTask_Wait", "desc": "정해진 시간 기다림 (실제 초)",
		"params": [["seconds", "number", 1.0, "기다릴 초"], ["seconds_key", "key:float", "", "초를 Blackboard 에서 (있으면 우선)"], ["random_deviation", "number", 0.0, "± 무작위"]]},
	"MoveTo": {"ue": "BTTask_MoveTo", "desc": "목표 위치로 이동. 목표가 움직이면 따라감 (도착 SUCCESS · 막힘 FAILURE · 이동 중 RUNNING)",
		"params": [["target_key", "key:vector2|entity_ref", "TargetLocation", "목표 (Blackboard 키)"], ["run", "bool", true, "달리기 (Npcs run_speed)"],
			["acceptance", "number", 0.4, "도착으로 보는 거리 (칸)"], ["timeout", "number", 0.0, "이 초가 지나면 FAILURE (0 = 없음)"]]},
	"Patrol": {"ue": "(테바 전용 — Unreal 에선 MoveTo + 순찰 지점 키)", "desc": "맵에 정한 순찰 경로의 다음 지점까지 걸어감 → SUCCESS",
		"params": []},
	"SearchLastPosition": {"ue": "(테바 전용 — Unreal 에선 MoveTo + Wait + Clear Value 를 Sequence 로)", "desc": "마지막 목격 위치로 가서 잠시 둘러본 뒤 그 키를 지움 → SUCCESS",
		"params": [["destination_key", "key:vector2", "LastKnownLocation", "갈 곳"], ["seconds_key", "key:float", "SearchDuration", "둘러보는 시간 (Blackboard)"],
			["seconds", "number", 2.0, "키가 없을 때 둘러보는 시간"], ["clear_key", "key:bool", "HasLastKnownLocation", "다 보면 지울 키"]]},
	"ReturnToOrigin": {"ue": "(테바 전용 — MoveTo 처음 자리)", "desc": "처음 놓인 자리로 걸어서 돌아감", "params": []},
	"EnterTurnBattle": {"ue": "(테바 전용 — 턴제 전투 시작)", "desc": "플레이어와 턴제 전투 시작. 전투가 끝날 때까지 다시 부르지 않음 (중복 방지)", "params": []},
	"SetBlackboardValue": {"ue": "BTTask_SetBlackboardValue (Blueprint 로 만드는 경우가 많음)", "desc": "키에 값 쓰기",
		"params": [["key", "key_any", "", "키"], ["value", "value", null, "값"]]},
	"ClearBlackboardValue": {"ue": "Clear Value (Blueprint)", "desc": "키를 비움 (bool false, 위치 없음)",
		"params": [["key", "key_any", "", "키"]]},
	"TaskGraph": {"ue": "BTTask_BlueprintBase (Blueprint 로 만든 Task)", "desc": "Task Graph(BTT_) 로 만든 Task 실행",
		"params": [["graph_id", "graph", "", "BTT_ 자산"]]},
}

const SERVICES := {
	"UpdatePerception": {"ue": "AIPerception + BTService (테바는 Service 가 감지 결과를 복사)",
		"desc": "시야로 플레이어를 찾아 HasLineOfSight·TargetActor·TargetLocation·DistanceToTarget, 보이면 LastKnownLocation·HasLastKnownLocation 도 씀. 시야 거리 = VisionRange 키 (없으면 5칸)"},
	"UpdateTargetDistance": {"ue": "BTService (Blueprint)", "desc": "TargetLocation 까지 거리를 DistanceToTarget 에"},
	"UpdateLastSeenPosition": {"ue": "BTService (Blueprint)", "desc": "보이는 동안 TargetLocation 을 LastKnownLocation 에 복사"},
	"UpdateNoise": {"ue": "AIPerception Hearing (테바 전용 단순형)", "desc": "들린 소리를 HasHeardNoise·NoiseLocation 에 (TODO: 소리 시스템이 아직 없어 늘 없음)"},
}


static func make(node: Dictionary, runner: Object) -> Object:
	var p: Dictionary = node.get("params", {})
	match str(node.get("task_type", "")):
		"Wait": return WaitTask.new(runner, p)
		"MoveTo": return MoveToTask.new(runner, p)
		"Patrol": return PatrolTask.new(runner, p)
		"SearchLastPosition": return SearchTask.new(runner, p)
		"ReturnToOrigin": return OriginTask.new(runner, p)
		"EnterTurnBattle": return BattleTask.new(runner, p)
		"SetBlackboardValue": return SetTask.new(runner, p)
		"ClearBlackboardValue": return ClearTask.new(runner, p)
		"TaskGraph":
			var tg = load("res://core/ai/task_graph_runner.gd")
			return tg.new(runner, p) if tg else null
	return null


# ---------------------------------------------------------------- Task 기본형
class BaseTask extends RefCounted:
	var r: Object        # BT Runner
	var p: Dictionary

	func _init(runner: Object, params: Dictionary) -> void:
		r = runner
		p = params

	func enter() -> int: return SUCCESS
	func tick(_delta: float) -> int: return SUCCESS
	func abort() -> void: pass

	func bbv(key: String) -> Variant:
		return r.bb.get_value(key) if key != "" else null

	func num(name: String, key_name := "") -> float:
		if key_name != "" and str(p.get(key_name, "")) != "" and r.bb.has_key(str(p[key_name])):
			return float(r.bb.get_value(str(p[key_name])))
		return float(p.get(name, 0.0))


class WaitTask extends BaseTask:
	var left := 0.0

	func enter() -> int:
		left = num("seconds", "seconds_key")
		var dev := float(p.get("random_deviation", 0.0))
		if dev > 0.0:
			left += randf_range(-dev, dev)
		return RUNNING if left > 0.0 else SUCCESS

	func tick(delta: float) -> int:
		left -= delta
		return SUCCESS if left <= 0.0 else RUNNING


## 이동 공통: 목표(칸)로 한 tick 씩. 도착 SUCCESS, 막힘 FAILURE
class MoveBase extends BaseTask:
	var elapsed := 0.0
	var run := false

	func dest() -> Variant: return null

	func step(delta: float) -> int:
		var to: Variant = dest()
		if to == null:
			r.agent.ai_stop()
			return FAILURE
		elapsed += delta
		var timeout := float(p.get("timeout", 0.0))
		if timeout > 0.0 and elapsed >= timeout:
			r.agent.ai_stop()
			return FAILURE
		if r.agent.ai_tile().distance_to(to) <= float(p.get("acceptance", 0.4)):
			r.agent.ai_stop()
			return SUCCESS
		match str(r.agent.ai_move(to, run, delta)):
			"arrived":
				r.agent.ai_stop()
				return SUCCESS
			"blocked":
				r.agent.ai_stop()
				return FAILURE
		return RUNNING

	func enter() -> int:
		return FAILURE if dest() == null else RUNNING

	func tick(delta: float) -> int:
		return step(delta)

	func abort() -> void:
		r.agent.ai_stop()


class MoveToTask extends MoveBase:
	func _init(runner: Object, params: Dictionary) -> void:
		super(runner, params)
		run = bool(p.get("run", true))

	func dest() -> Variant:
		var key := str(p.get("target_key", "TargetLocation"))
		var v: Variant = bbv(key)
		if r.bb.type_of(key) == "entity_ref":
			return r.agent.ai_entity_tile(str(v)) if v != null else null
		return v


class PatrolTask extends MoveBase:
	var target: Variant = null

	func enter() -> int:
		var pts: Array = r.agent.ai_patrol_points()
		if pts.size() < 2:
			return SUCCESS   # 순찰 경로 없음 → 제자리
		var i: int = int(r.memory.get("patrol_i", 1)) % pts.size()
		target = pts[i]
		return RUNNING

	func dest() -> Variant:
		return target

	func tick(delta: float) -> int:
		var res := step(delta)
		if res == SUCCESS:
			var pts: Array = r.agent.ai_patrol_points()
			r.memory["patrol_i"] = (int(r.memory.get("patrol_i", 1)) + 1) % maxi(1, pts.size())
		return res


class OriginTask extends MoveBase:
	func dest() -> Variant:
		return r.agent.ai_origin()


## 마지막 위치로 가서 둘러보고(기다림) 키를 지움
class SearchTask extends MoveBase:
	var looking := -1.0

	func dest() -> Variant:
		return bbv(str(p.get("destination_key", "LastKnownLocation")))

	func enter() -> int:
		var clear_key := str(p.get("clear_key", "HasLastKnownLocation"))
		if clear_key != "" and r.bb.has_key(clear_key) and not Blackboard.is_set(r.bb.get_value(clear_key)):
			return FAILURE
		return super.enter()

	func tick(delta: float) -> int:
		if looking < 0.0:
			var res := step(delta)
			if res == RUNNING:
				return RUNNING
			if res == FAILURE:
				_clear()
				return FAILURE
			looking = num("seconds", "seconds_key") if r.bb.has_key(str(p.get("seconds_key", ""))) else float(p.get("seconds", 2.0))
		looking -= delta
		if looking > 0.0:
			return RUNNING
		_clear()
		return SUCCESS

	func _clear() -> void:
		var k := str(p.get("clear_key", "HasLastKnownLocation"))
		if k != "" and r.bb.has_key(k):
			r.bb.clear_value(k, "Task")


class BattleTask extends BaseTask:
	func enter() -> int:
		if r.memory.get("battle_pending", false):
			return FAILURE   # 전투가 끝나기 전에는 다시 부르지 않음
		if not r.agent.ai_request_battle():
			return FAILURE
		r.memory["battle_pending"] = true
		return SUCCESS


class SetTask extends BaseTask:
	func enter() -> int:
		return SUCCESS if r.bb.set_value(str(p.get("key", "")), p.get("value"), "Task") else FAILURE


class ClearTask extends BaseTask:
	func enter() -> int:
		return SUCCESS if r.bb.clear_value(str(p.get("key", "")), "Task") else FAILURE


# ---------------------------------------------------------------- Service
## Service 한 번 실행. 모르는 종류면 false.
static func run_service(def: Dictionary, r: Object) -> bool:
	var bb: Blackboard = r.bb
	match str(def.get("type", "")):
		"UpdatePerception":
			var rng := float(bb.get_value("VisionRange")) if bb.has_key("VisionRange") else 5.0
			var seen: Dictionary = r.agent.ai_perceive(rng)
			var vis := bool(seen.get("visible", false))
			_put(bb, "HasLineOfSight", vis)
			if vis:
				_put(bb, "TargetActor", seen.get("id", "player"))
				_put(bb, "TargetLocation", seen.get("pos"))
				_put(bb, "LastKnownLocation", seen.get("pos"))
				_put(bb, "HasLastKnownLocation", true)
				_put(bb, "DistanceToTarget", seen.get("distance", 0.0))
			else:
				_put(bb, "DistanceToTarget", 9999.0)
		"UpdateTargetDistance":
			var t: Variant = bb.get_value("TargetLocation") if bb.has_key("TargetLocation") else null
			_put(bb, "DistanceToTarget", r.agent.ai_tile().distance_to(t) if t != null else 9999.0)
		"UpdateLastSeenPosition":
			if bb.has_key("HasLineOfSight") and bb.get_value("HasLineOfSight") and bb.get_value("TargetLocation") != null:
				_put(bb, "LastKnownLocation", bb.get_value("TargetLocation"))
				_put(bb, "HasLastKnownLocation", true)
		"UpdateNoise":
			var n: Dictionary = r.agent.ai_noise()
			if not n.is_empty():
				_put(bb, "HasHeardNoise", true)
				_put(bb, "NoiseLocation", n.get("pos"))
		_:
			return false
	return true


static func _put(bb: Blackboard, key: String, v: Variant) -> void:
	if bb.has_key(key):
		bb.set_value(key, v, "Service")
