extends Node
## 게임 상태: 스탯·인벤토리·에피소드 플래그(에피소드마다 초기화)와 월드 플래그(영구).
## 조건 해석기(core/expr.gd)의 컨텍스트 역할도 한다:
## item_count / get_stat / get_ability / has_flag / has_wflag / has_trait.

signal stats_changed
signal inventory_changed
signal flags_changed
signal survival_changed
signal clock_changed

const STATS := ["hp", "sanity", "time"]
const Combat = preload("res://core/combat/combat.gd")

# --- 에피소드 상태 (에피소드 진행 파일에 저장)
var episode_id := ""
var node_id := ""
var stats := {}               # name -> int
var inventory: Array = []     # 칸 목록: [{ "id": String, "count": int }, ...]
var ep_flags := {}            # name -> true
var protagonist_id := ""      # 현재 주인공 char_id (대화 화면에서 주인공 대사 구분)
var traits: Array = []        # 현재 주인공 능력
var abilities := {}           # 주사위 능력치 ability_id -> int (주인공 기본값 + 에피소드 중 성장)
var timed_out := false        # 시간 초과 노드로 이미 보냈는지 (중복 이동 방지)

# --- 탐험 회차 상태 (베이스캠프에서 회차 파일에 저장, 사망하면 사라짐 — 기획서 §11, §13)
var current_map := ""
var clock := 0.0              # 회차 시작부터 흐른 게임 시간 (분). 1일차 0:00 = 0
var survival := {}            # param_id -> float (0 ~ max, 높을수록 좋음)
var player_body := {}         # 전투 부위 상태 (부상·절단), 전투 사이에 이어짐
var field_state := {}         # map_id -> { "removed": [object_id], "done": [object_id] }

# --- 월드 상태 (월드 파일에 저장, 회차가 바뀌어도 유지)
var world_flags := {}         # name -> true
var run_count := 0            # 지금까지 시작한 회차 수 (초월적 존재의 부활 인식용, §11)


func reset_for_episode(ep: Dictionary) -> void:
	# TODO(기획 확인): 인벤토리·스탯은 에피소드마다 새로 시작한다고 가정. 에피소드 간 인계가 필요하면 여기서 바꾼다.
	episode_id = ep.episode_id
	node_id = ""
	stats = {}
	for s in STATS:
		stats[s] = DataLoader.get_config_int(s + "_start", 100)
	inventory = []
	ep_flags = {}
	timed_out = false
	# TODO(기획 확인): 능력치 성장은 에피소드 안에서만 유지. 영구 성장(로그라이크)은 다음 단계.
	_set_protagonist(ep.protagonist_id)
	stats_changed.emit()
	inventory_changed.emit()
	flags_changed.emit()


## 탐험 회차 시작 (에피소드 없이). 스탯·인벤토리·플래그를 처음 상태로.
## TODO(기획 §11): 회차 구조·베이스캠프 저장이 들어오면 여기서 회차 초기화를 맡는다.
func reset_run() -> void:
	episode_id = ""
	node_id = ""
	stats = {}
	for s in STATS:
		stats[s] = DataLoader.get_config_int(s + "_start", 100)
	inventory = []
	ep_flags = {}
	timed_out = false
	_set_protagonist(str(DataLoader.config.get("protagonist_id", "")))
	current_map = DataLoader.get_config_str("start_map", DataLoader.map_order[0] if not DataLoader.map_order.is_empty() else "")
	clock = DataLoader.get_config_int("start_hour", 8) * 60.0
	survival = {}
	for p in DataLoader.survival:
		survival[p.param_id] = float(p.start)
	player_body = Combat.fresh_player_parts()
	field_state = {}
	survival_changed.emit()
	clock_changed.emit()
	stats_changed.emit()
	inventory_changed.emit()
	flags_changed.emit()


func _set_protagonist(char_id: String) -> void:
	protagonist_id = char_id
	var protagonist: Dictionary = DataLoader.characters.get(char_id, {})
	traits = protagonist.get("traits", [])
	abilities = {}
	for id in protagonist.get("abilities", {}):
		abilities[id] = int(protagonist.abilities[id])


# ---------------------------------------------------------------- 시간·생존 (기획서 §4, §5)
## 게임 시간을 흘리고 생존 파라미터를 줄인다.
## TODO(기획 §5): 파라미터가 낮거나 0일 때의 효과(전투·탐험 효율, 사망 여부)는 미정 — 지금은 표시만.
func advance_time(minutes: float) -> void:
	if minutes <= 0.0:
		return
	clock += minutes
	for p in DataLoader.survival:
		var v: float = survival.get(p.param_id, float(p.start))
		survival[p.param_id] = clampf(v - float(p.decay_per_hour) * minutes / 60.0, 0.0, float(p.max))
	clock_changed.emit()
	survival_changed.emit()


func get_survival(param_id: String) -> float:
	return float(survival.get(param_id, 0.0))


## op: "+", "-", "="
func change_survival(param_id: String, op: String, value: float) -> void:
	var p := survival_def(param_id)
	if p.is_empty():
		push_error("[GameState] 없는 생존 파라미터: %s" % param_id)
		return
	var v := get_survival(param_id)
	match op:
		"+": v += value
		"-": v -= value
		"=": v = value
	survival[param_id] = clampf(v, 0.0, float(p.max))
	survival_changed.emit()


func survival_def(param_id: String) -> Dictionary:
	for p in DataLoader.survival:
		if p.param_id == param_id:
			return p
	return {}


func day() -> int:
	return int(clock / 1440.0) + 1


## "HH:MM"
func clock_text() -> String:
	var m := int(clock) % 1440
	return "%02d:%02d" % [m / 60, m % 60]


## 맵 위 물체 상태 (처치한 적·조사한 곳). kind: "removed" / "done"
func field_has(map_id: String, kind: String, object_id: String) -> bool:
	return object_id in field_state.get(map_id, {}).get(kind, [])


func field_mark(map_id: String, kind: String, object_id: String) -> void:
	if not field_state.has(map_id):
		field_state[map_id] = {"removed": [], "done": []}
	if not object_id in field_state[map_id][kind]:
		field_state[map_id][kind].append(object_id)


# ---------------------------------------------------------------- 스탯
func get_stat(name: String) -> int:
	return int(stats.get(name, 0))


func stat_max(name: String) -> int:
	return DataLoader.get_config_int(name + "_max", 100)


## op: "+", "-", "="
func change_stat(name: String, op: String, value: int) -> void:
	if not name in STATS:
		push_error("[GameState] 알 수 없는 스탯: %s" % name)
		return
	var v := get_stat(name)
	match op:
		"+": v += value
		"-": v -= value
		"=": v = value
	stats[name] = clampi(v, 0, stat_max(name))
	stats_changed.emit()


# ---------------------------------------------------------------- 능력치
func get_ability(id: String) -> int:
	return int(abilities.get(id, 0))


## op: "+", "-", "="
func change_ability(id: String, op: String, value: int) -> void:
	var v := get_ability(id)
	match op:
		"+": v += value
		"-": v -= value
		"=": v = value
	abilities[id] = v
	stats_changed.emit()


# ---------------------------------------------------------------- 인벤토리
func slot_count() -> int:
	return DataLoader.get_config_int("inventory_slots", 8)


func item_count(item_id: String) -> int:
	var n := 0
	for slot in inventory:
		if slot.id == item_id:
			n += slot.count
	return n


## 가능한 만큼 넣고, 칸이 모자라 못 넣은 개수를 돌려준다.
func add_item(item_id: String, amount: int) -> int:
	var stack_max: int = max(1, DataLoader.items.get(item_id, {}).get("stack_max", 1))
	var left := amount
	for slot in inventory:
		if left <= 0:
			break
		if slot.id == item_id and slot.count < stack_max:
			var put: int = min(stack_max - slot.count, left)
			slot.count += put
			left -= put
	while left > 0 and inventory.size() < slot_count():
		var put: int = min(stack_max, left)
		inventory.append({"id": item_id, "count": put})
		left -= put
	if left != amount:
		inventory_changed.emit()
	return left


## 뒤쪽 칸부터 빼고, 실제로 뺀 개수를 돌려준다.
func remove_item(item_id: String, amount: int) -> int:
	var left := amount
	for i in range(inventory.size() - 1, -1, -1):
		if left <= 0:
			break
		var slot = inventory[i]
		if slot.id != item_id:
			continue
		var take: int = min(slot.count, left)
		slot.count -= take
		left -= take
		if slot.count <= 0:
			inventory.remove_at(i)
	if left != amount:
		inventory_changed.emit()
	return amount - left


func remove_slot(index: int) -> Dictionary:
	if index < 0 or index >= inventory.size():
		return {}
	var slot: Dictionary = inventory[index]
	inventory.remove_at(index)
	inventory_changed.emit()
	return slot


# ---------------------------------------------------------------- 플래그·능력
func has_flag(name: String) -> bool:
	return ep_flags.has(name)


func set_flag(name: String, on: bool) -> void:
	if on:
		ep_flags[name] = true
	else:
		ep_flags.erase(name)
	flags_changed.emit()


func has_wflag(name: String) -> bool:
	return world_flags.has(name)


func set_wflag(name: String) -> void:
	world_flags[name] = true
	flags_changed.emit()


func has_trait(name: String) -> bool:
	return name in traits


# ---------------------------------------------------------------- 직렬화
func episode_to_dict() -> Dictionary:
	return {
		"episode_id": episode_id,
		"node_id": node_id,
		"stats": stats.duplicate(),
		"inventory": inventory.duplicate(true),
		"ep_flags": ep_flags.keys(),
		"abilities": abilities.duplicate(),
		"timed_out": timed_out,
	}


func episode_from_dict(d: Dictionary) -> void:
	var ep: Dictionary = DataLoader.episodes.get(d.get("episode_id", ""), {})
	reset_for_episode(ep)
	node_id = d.get("node_id", "")
	for s in STATS:
		stats[s] = int(d.get("stats", {}).get(s, stats[s]))
	inventory = []
	for slot in d.get("inventory", []):
		inventory.append({"id": str(slot.id), "count": int(slot.count)})
	ep_flags = {}
	for f in d.get("ep_flags", []):
		ep_flags[f] = true
	timed_out = d.get("timed_out", false)
	var saved_abilities: Dictionary = d.get("abilities", {})
	for id in saved_abilities:
		abilities[id] = int(saved_abilities[id])
	stats_changed.emit()
	inventory_changed.emit()
	flags_changed.emit()


func world_to_dict() -> Dictionary:
	return {"world_flags": world_flags.keys(), "run_count": run_count}


func world_from_dict(d: Dictionary) -> void:
	world_flags = {}
	for f in d.get("world_flags", []):
		world_flags[f] = true
	run_count = int(d.get("run_count", 0))
	flags_changed.emit()


## 탐험 회차 저장 내용 (베이스캠프에서 저장)
func run_to_dict() -> Dictionary:
	return {
		"current_map": current_map,
		"clock": clock,
		"survival": survival.duplicate(),
		"player_body": player_body.duplicate(true),
		"field_state": field_state.duplicate(true),
		"inventory": inventory.duplicate(true),
		"flags": ep_flags.keys(),
		"abilities": abilities.duplicate(),
	}


func run_from_dict(d: Dictionary) -> void:
	reset_run()
	current_map = d.get("current_map", current_map)
	clock = float(d.get("clock", clock))
	for k in d.get("survival", {}):
		survival[k] = float(d.survival[k])
	var body: Dictionary = d.get("player_body", {})
	for k in body:
		if player_body.has(k):
			player_body[k].hp = int(body[k].hp)
			player_body[k].broken = bool(body[k].broken)
	field_state = d.get("field_state", {}).duplicate(true)
	inventory = []
	for slot in d.get("inventory", []):
		inventory.append({"id": str(slot.id), "count": int(slot.count)})
	ep_flags = {}
	for f in d.get("flags", []):
		ep_flags[f] = true
	for k in d.get("abilities", {}):
		abilities[k] = int(d.abilities[k])
	survival_changed.emit()
	clock_changed.emit()
	inventory_changed.emit()
	flags_changed.emit()
