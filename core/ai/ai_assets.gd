extends RefCounted
## 몬스터 AI 자산 읽기·검사·컴파일. 원본은 tools/ai/<id>.json 하나 = 자산 하나:
##   BB_*  Blackboard   {schema_version, asset_type:"blackboard", id, keys:[{name, type, default, instance_override?}]}
##   BT_*  Behavior Tree {schema_version, asset_type:"behavior_tree", id, domain, blackboard_id, battle_on_contact, root_id, nodes:[…], editor_layout:{id:[x,y]}}
##         battle_on_contact (테바 전용, 기본 true): 닿으면 바로 턴제 전투. false 면 EnterTurnBattle Task 로만.
##   BTT_* Task Graph   {schema_version, asset_type:"task_graph", id, nodes:[…], connections:[…]}  (Phase 4)
## 'Compile'(테바) = 코드 컴파일이 아니라 검사 + 게임이 읽는 data/ai.json 만들기.
## BT 노드: {id, kind: Root/Selector/Sequence/Task, name?, children:[id…] (순서 = 우선순위, 유일한 기준),
##           decorators:[{type: Blackboard/Cooldown, key, operator, value, inverse?, observer_aborts: None/Self/LowerPriority/Both, name?}],
##           services:[{type, interval, random_deviation, run_on_activation}], task_type, params:{}}

const Blackboard = preload("res://core/ai/blackboard.gd")
const Tasks = preload("res://core/ai/bt_tasks.gd")

const SRC_DIR := "res://tools/ai/"
const OUT_PATH := "res://data/ai.json"
const SCHEMA := 2
const KINDS := ["Root", "Selector", "Sequence", "Task"]
const ABORTS := ["None", "Self", "LowerPriority", "Both"]
const OPERATORS := ["is_set", "is_not_set", "==", "!=", "<", "<=", ">", ">="]
const DECORATORS := {
	"Blackboard": {"ue": "BTDecorator_Blackboard (Blackboard Based Condition)", "desc": "Blackboard 키 값을 비교. Observer Aborts 로 값이 바뀌면 바로 중단·전환"},
	"Cooldown": {"ue": "BTDecorator_Cooldown", "desc": "이 노드가 끝난 뒤 정한 초 동안은 다시 못 들어감"},
}


## 폴더의 모든 자산 → {id: 자산}
static func load_dir(dir := SRC_DIR) -> Dictionary:
	var out := {}
	var d := DirAccess.open(dir)
	if d == null:
		return out
	for f in d.get_files():
		if not f.ends_with(".json") or f.begins_with("_"):
			continue
		var v = JSON.parse_string(FileAccess.get_file_as_string(dir + f))
		if v is Dictionary and v.has("id"):
			out[str(v.id)] = v
	return out


static func kind_of(asset: Dictionary) -> String:
	return str(asset.get("asset_type", ""))


## 자산 하나 검사 → [{node, msg}] (node = 문제 노드 id, 없으면 "")
static func validate(asset: Dictionary, all: Dictionary) -> Array:
	match kind_of(asset):
		"blackboard": return validate_bb(asset)
		"behavior_tree": return validate_bt(asset, all)
		"task_graph":
			var tg = load("res://core/ai/task_graph.gd")
			return tg.validate(asset, all) if tg else []
	return [{"node": "", "msg": "asset_type 을 모름: '%s'" % asset.get("asset_type", "")}]


static func validate_bb(bb: Dictionary) -> Array:
	var errs := []
	var seen := {}
	for k in bb.get("keys", []):
		var name := str(k.get("name", ""))
		if name == "" or not RegEx.create_from_string("^[A-Za-z_][A-Za-z0-9_]*$").search(name):
			errs.append({"node": name, "msg": "키 이름은 영문·숫자·_ : '%s'" % name})
		if seen.has(name):
			errs.append({"node": name, "msg": "키 이름이 겹침: %s" % name})
		seen[name] = true
		if not str(k.get("type", "")) in Blackboard.TYPES:
			errs.append({"node": name, "msg": "타입은 %s: '%s'" % [", ".join(Blackboard.TYPES), k.get("type", "")]})
		elif k.get("type") == "entity_ref" and k.get("default") != null:
			errs.append({"node": name, "msg": "EntityRef 는 기본값을 둘 수 없음 (런타임 전용)"})
	return errs


static func validate_bt(bt: Dictionary, all: Dictionary) -> Array:
	var errs := []
	var nodes := {}
	for n in bt.get("nodes", []):
		var id := str(n.get("id", ""))
		if nodes.has(id):
			errs.append({"node": id, "msg": "노드 ID 가 겹침"})
		nodes[id] = n
	var bb: Dictionary = all.get(str(bt.get("blackboard_id", "")), {})
	if bb.is_empty() or kind_of(bb) != "blackboard":
		errs.append({"node": str(bt.get("root_id", "")), "msg": "Root 의 Blackboard 자산이 없음: '%s'" % bt.get("blackboard_id", "")})
	var keys := {}
	for k in bb.get("keys", []):
		keys[str(k.name)] = str(k.get("type", ""))
	var root := str(bt.get("root_id", ""))
	if not nodes.has(root) or nodes[root].get("kind") != "Root":
		errs.append({"node": root, "msg": "root_id 가 Root 노드가 아님"})
	var parents := {}
	for id in nodes:
		var n: Dictionary = nodes[id]
		var kind := str(n.get("kind", ""))
		var kids: Array = n.get("children", [])
		if not kind in KINDS:
			errs.append({"node": id, "msg": "종류는 Root / Selector / Sequence / Task: '%s'" % kind})
		if kind == "Root" and id != root:
			errs.append({"node": id, "msg": "Root 는 하나만"})
		if kind == "Root":
			if kids.size() != 1:
				errs.append({"node": id, "msg": "Root 의 자식은 정확히 하나 (Selector 또는 Sequence)"})
			elif nodes.has(str(kids[0])) and not str(nodes[str(kids[0])].get("kind")) in ["Selector", "Sequence"]:
				errs.append({"node": id, "msg": "Root 의 자식은 Selector 또는 Sequence"})
		if kind in ["Selector", "Sequence"] and kids.is_empty():
			errs.append({"node": id, "msg": "%s 에 자식이 없음" % kind})
		if kind == "Task":
			if not kids.is_empty():
				errs.append({"node": id, "msg": "Task 는 자식을 가질 수 없음"})
			_check_task(n, keys, all, errs)
		for c in kids:
			c = str(c)
			if not nodes.has(c):
				errs.append({"node": id, "msg": "없는 자식 '%s'" % c})
			elif parents.has(c):
				errs.append({"node": c, "msg": "부모가 둘 (%s, %s)" % [parents[c], id]})
			else:
				parents[c] = id
		if kind == "Root" and not n.get("decorators", []).is_empty():
			errs.append({"node": id, "msg": "Root 에는 Decorator 를 붙일 수 없음"})
		for d in n.get("decorators", []):
			_check_decorator(id, d, keys, errs)
		for s in n.get("services", []):
			if not Tasks.SERVICES.has(str(s.get("type", ""))):
				errs.append({"node": id, "msg": "없는 Service '%s'" % s.get("type", "")})
			if float(s.get("interval", 0.5)) <= 0.0:
				errs.append({"node": id, "msg": "Service interval 은 0보다 커야 함"})
	# 고아·순환
	for id in nodes:
		if id != root and not parents.has(id):
			errs.append({"node": id, "msg": "트리에 이어지지 않은 노드 (부모 없음)"})
	if nodes.has(root):
		var seen := {}
		var todo := [root]
		while not todo.is_empty():
			var id: String = todo.pop_back()
			if seen.has(id):
				errs.append({"node": id, "msg": "순환 연결"})
				break
			seen[id] = true
			for c in nodes[id].get("children", []):
				if nodes.has(str(c)):
					todo.append(str(c))
	return errs


static func _check_decorator(id: String, d: Dictionary, keys: Dictionary, errs: Array) -> void:
	var t := str(d.get("type", ""))
	if not DECORATORS.has(t):
		errs.append({"node": id, "msg": "없는 Decorator '%s'" % t})
		return
	if not str(d.get("observer_aborts", "None")) in ABORTS + ["Lower Priority"]:
		errs.append({"node": id, "msg": "Observer Aborts 는 None / Self / LowerPriority / Both"})
	if t == "Blackboard":
		var key := str(d.get("key", ""))
		var op := str(d.get("operator", "is_set"))
		if not keys.has(key):
			errs.append({"node": id, "msg": "Decorator 의 키가 Blackboard 에 없음: '%s'" % key})
		elif not op in OPERATORS + ["equals", "not_equals"]:
			errs.append({"node": id, "msg": "연산자 '%s'" % op})
		elif op in ["<", "<=", ">", ">="] and not keys[key] in ["int", "float"]:
			errs.append({"node": id, "msg": "%s 는 수(Int/Float) 키에만: %s 은(는) %s" % [op, key, keys[key]]})
	elif t != "Cooldown" and str(d.get("observer_aborts", "None")) != "None":
		errs.append({"node": id, "msg": "%s 는 Observer Aborts 를 쓸 수 없음" % t})


static func _check_task(n: Dictionary, keys: Dictionary, all: Dictionary, errs: Array) -> void:
	var id := str(n.id)
	var tt := str(n.get("task_type", ""))
	if not Tasks.TASKS.has(tt):
		errs.append({"node": id, "msg": "없는 Task '%s'" % tt})
		return
	var p: Dictionary = n.get("params", {})
	for spec in Tasks.TASKS[tt].params:
		var kind: String = spec[1]
		var v: Variant = p.get(spec[0], spec[2])
		if kind.begins_with("key"):
			var key := str(v if v != null else "")
			if key == "":
				if kind == "key_any":
					errs.append({"node": id, "msg": "%s: 키를 고르세요" % spec[0]})
				continue
			if not keys.has(key):
				if not (spec[0] in ["seconds_key", "clear_key"] and p.get(spec[0], null) == null):
					errs.append({"node": id, "msg": "%s: Blackboard 에 없는 키 '%s'" % [spec[0], key]})
				continue
			if kind.begins_with("key:") and not keys[key] in kind.substr(4).split("|"):
				errs.append({"node": id, "msg": "%s: 키 타입이 맞지 않음 (%s 은(는) %s, 필요: %s)" % [spec[0], key, keys[key], kind.substr(4)]})
		elif kind == "graph":
			var g: Dictionary = all.get(str(v), {})
			if g.is_empty() or kind_of(g) != "task_graph":
				errs.append({"node": id, "msg": "없는 Task Graph '%s'" % v})
			elif keys.size() > 0 and not _same_bb(g, keys, all):
				errs.append({"node": id, "msg": "Task Graph '%s' 의 Blackboard(%s)가 이 트리의 것과 다름" % [v, g.get("blackboard_id", "")]})


## 그래프가 쓰는 Blackboard 의 키가 이 트리의 Blackboard 에 같은 타입으로 다 있나
static func _same_bb(g: Dictionary, keys: Dictionary, all: Dictionary) -> bool:
	for k in all.get(str(g.get("blackboard_id", "")), {}).get("keys", []):
		if keys.get(str(k.name), "") != str(k.type):
			return false
	return true


## 모든 자산 검사 → {자산 id: [오류]} (오류 없는 자산은 빠짐)
static func validate_all(all: Dictionary) -> Dictionary:
	var out := {}
	for id in all:
		var e := validate(all[id], all)
		if not e.is_empty():
			out[id] = e
	return out


## Compile: 검사해서 오류가 없으면 data/ai.json (게임이 읽는 묶음)을 쓴다 → 오류 목록 {id: [..]}
static func compile(all: Dictionary, out_path := OUT_PATH) -> Dictionary:
	var errs := validate_all(all)
	if not errs.is_empty():
		return errs
	var ids: Array = all.keys()
	ids.sort()
	var f := FileAccess.open(out_path, FileAccess.WRITE)
	if f == null:
		return {"(compile)": [{"node": "", "msg": "쓸 수 없음: " + out_path}]}
	f.store_string(JSON.stringify({"schema_version": SCHEMA, "assets": ids.map(func(i): return all[i])}, " ") + "\n")
	f.close()
	return {}
