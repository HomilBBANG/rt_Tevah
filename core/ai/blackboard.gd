extends RefCounted
## 몬스터 한 마리의 Blackboard 값 (Unreal 의 Blackboard Component 에 해당).
## 키 정의(BB_ 자산)는 여러 몬스터가 같이 쓰고, 값은 이 객체 하나 = 몬스터 하나만의 것.
## 값이 바뀌면 changed(key, old, new, source) — BT Runner 가 그 키를 보는 Decorator 만 다시 판정한다 (Observer Aborts).
##
## 키 타입: bool / int / float / string / vector2 (칸 좌표, Godot 2D — Unreal 의 3D Vector 와 다름) / entity_ref (런타임 ID 글자, 예: "player")
## source: "Sensor" / "Service" / "Task" / "Editor Override" / "Init" — 디버거에 '누가 바꿨나' 로 보임.

signal changed(key: String, old_value: Variant, new_value: Variant, source: String)

const TYPES := ["bool", "int", "float", "string", "vector2", "entity_ref"]
const HISTORY_MAX := 64

var asset_id := ""
var defs := {}            # key -> {type, default}
var values := {}
var last_source := {}     # key -> 마지막으로 바꾼 곳
var history: Array = []   # [{t, key, old, new, source}] (최근 HISTORY_MAX 개)
var clock := 0.0          # 기록용 시각 (Runner 가 올림)


func setup(asset: Dictionary, overrides := {}) -> void:
	asset_id = str(asset.get("id", ""))
	defs.clear()
	for k in asset.get("keys", []):
		defs[str(k.name)] = {"type": str(k.get("type", "bool")), "default": k.get("default")}
	reset()
	for key in overrides:
		if defs.has(key):
			set_value(key, overrides[key], "Editor Override")


## 모두 기본값으로 (회차 재시작 등)
func reset() -> void:
	values.clear()
	last_source.clear()
	history.clear()
	for key in defs:
		values[key] = from_json(defs[key].type, defs[key].default)
		last_source[key] = "Init"


func has_key(key: String) -> bool:
	return defs.has(key)


func type_of(key: String) -> String:
	return defs.get(key, {}).get("type", "")


func get_value(key: String) -> Variant:
	return values.get(key)


## 값 쓰기. 타입에 맞게 바꿔 넣고, 정말 바뀌었을 때만 changed. 없는 키는 무시(false).
func set_value(key: String, value: Variant, source := "Task") -> bool:
	if not defs.has(key):
		push_warning("[Blackboard %s] 없는 키 '%s'" % [asset_id, key])
		return false
	var v: Variant = coerce(defs[key].type, value)
	var old: Variant = values.get(key)
	if typeof(old) == typeof(v) and old == v:
		return true
	values[key] = v
	last_source[key] = source
	history.append({"t": clock, "key": key, "old": old, "new": v, "source": source})
	if history.size() > HISTORY_MAX:
		history.pop_front()
	changed.emit(key, old, v, source)
	return true


## 키를 '비어 있음' 으로 (Unreal 의 Clear Value): bool false, 수 0, 글자 "", vector2·entity_ref 는 null
func clear_value(key: String, source := "Task") -> bool:
	if not defs.has(key):
		return false
	var t: String = defs[key].type
	return set_value(key, null if t in ["vector2", "entity_ref"] else coerce(t, null), source)


## 값이 '있음' 인가 (Decorator Is Set): bool true, 수 != 0, 글자·ID 비어 있지 않음, vector2 는 null 이 아님
static func is_set(v: Variant) -> bool:
	match typeof(v):
		TYPE_NIL: return false
		TYPE_BOOL: return v
		TYPE_INT, TYPE_FLOAT: return v != 0
		TYPE_STRING: return v != ""
	return true


static func coerce(type: String, v: Variant) -> Variant:
	match type:
		"bool": return bool(v) if v != null else false
		"int": return int(v) if v != null else 0
		"float": return float(v) if v != null else 0.0
		"string": return str(v) if v != null else ""
		"vector2":
			if v is Vector2: return v
			if v is Vector2i: return Vector2(v)
			if v is Array and v.size() >= 2: return Vector2(float(v[0]), float(v[1]))
			return null
		"entity_ref": return str(v) if v != null and str(v) != "" else null
	return v


static func from_json(type: String, v: Variant) -> Variant:
	return coerce(type, v)


## 저장·표시용 (Vector2 → [x, y])
static func to_json(v: Variant) -> Variant:
	if v is Vector2:
		return [v.x, v.y]
	return v


static func show(v: Variant) -> String:
	if v == null:
		return "(없음)"
	if v is Vector2:
		return "(%s, %s)" % [_num(v.x), _num(v.y)]
	if v is float:
		return _num(v)
	return str(v)


static func _num(f: float) -> String:
	return str(int(f)) if is_equal_approx(f, roundf(f)) else "%.1f" % f
