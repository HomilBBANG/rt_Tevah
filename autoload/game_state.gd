extends Node
## 게임 상태: 스탯·인벤토리·에피소드 플래그(에피소드마다 초기화)와 월드 플래그(영구).
## 조건 해석기(core/expr.gd)의 컨텍스트 역할도 한다:
## item_count / get_stat / get_ability / has_flag / has_wflag / has_trait / is_severed / get_count.

signal stats_changed
signal body_changed
signal inventory_changed
signal equipment_changed
signal statuses_changed
signal traits_changed
signal flags_changed
signal survival_changed
signal clock_changed

const STATS := ["hp", "sanity", "time"]
const Combat = preload("res://core/combat/combat.gd")
const Expr = preload("res://core/expr.gd")

# --- 에피소드 상태 (에피소드 진행 파일에 저장)
var episode_id := ""
var node_id := ""
var stats := {}               # name -> int
var inventory: Array = []     # 칸 목록: [{ "id": String, "count": int }, ...]
var ep_flags := {}            # name -> true
var protagonist_id := ""      # 현재 주인공 char_id (대화 화면에서 주인공 대사 구분)
var traits: Array = []        # 주인공 기본 능력 (Player.traits 열)
## 가진 특성 [{trait_id, from}] — from: creation(캐릭터 생성) / event(사건·거래). 회차가 바뀌어도 남는다 (월드 저장),
## 회차 저장에도 들어가서 슬롯을 불러오면 그 저장의 특성으로 돌아간다 (기획 §5.4 안 B)
var owned_traits: Array = []
var character_created := false
var opening_pending := false     # 캐릭터 생성 직후: 필드가 열리면 오프닝 컷신(Config opening_dialogue)을 한 번 (저장 안 함)   # 캐릭터 생성을 마쳤나 (안 했으면 타이틀 '새 게임' = 생성 화면)
var abilities := {}           # 주사위 능력치 ability_id -> int (주인공 기본값 + 에피소드 중 성장)
var timed_out := false        # 시간 초과 노드로 이미 보냈는지 (중복 이동 방지)

# --- 탐험 회차 상태 (베이스캠프에서 회차 파일에 저장, 사망하면 사라짐 — 기획서 §11, §13)
var current_map := ""
var clock := 0.0              # 회차 시작부터 흐른 게임 시간 (분). 1일차 0:00 = 0
var survival := {}            # param_id -> float (0 ~ max, 높을수록 좋음)
var player_body := {}         # 전투 부위 상태 (부상·절단), 전투 사이에 이어짐
var statuses: Array = []      # 걸려 있는 상태이상 status_id (StatusEffects 시트). 효과 status:+id / status:-id
var equipment := {}           # 장비: slot_id(EquipSlots) -> item_id. 장착한 것은 인벤토리 칸을 차지하지 않는다
var field_state := {}         # map_id -> { "removed": [object_id], "done": [object_id] }
var talk_counts := {}         # 대화 시작 node_id -> 그 대화를 시작한 횟수 (회차 저장에 들어감)
var combat_enemy := ""        # 지금 싸우는 상대 enemy_id (전투 화면이 정함, 조건 combat:) — 저장 안 함
var pending_death := ""       # 효과 die:cause_id 로 정해진 사망 — 필드가 대화가 끝난 뒤 처리. 저장 안 함
var talk_now := 0             # 지금 대화를 전에 몇 번 했나 (조건 count:talk, 첫 대화 = 0)
var arrive_at := ""           # 다음 맵 로드 때 도착할 도착 지점(arrive 물체) id (저장 안 함)
var arrive_edge := {}         # 이어지는 맵(가장자리 seamless): {dir: 나간 쪽, along: 가장자리를 따라 위치(칸, 소수, offset 더함)} — 반대쪽 같은 자리로 (저장 안 함)
var arrive_from := ""         # 어디로 들어왔나: 문·통로·이용 object_id 또는 "맵:방향"(가장자리). 도착 P 의 from 과 맞추어 도착
var wake_at_run_start := false   # 다음 맵 로드 때 그 맵의 S(회차 시작 위치)에서 깨어남 (저장 안 함)

# --- 월드 상태 (월드 파일에 저장, 회차가 바뀌어도 유지)
var world_flags := {}         # name -> true
var run_count := 0            # 지금까지 시작한 회차 수 (처음부터 다시 시작한 횟수)
var death_count := 0          # 지금까지 죽은 횟수 (부활 포함). 초월적 존재의 반복 부활 인식용 (§11)


func reset_for_episode(ep: Dictionary) -> void:
	# TODO(기획 확인): 인벤토리·스탯은 에피소드마다 새로 시작한다고 가정. 에피소드 간 인계가 필요하면 여기서 바꾼다.
	episode_id = ep.episode_id
	node_id = ""
	stats = {}
	for s in STATS:
		stats[s] = DataLoader.get_config_int(s + "_start", 100)
	inventory = []
	equipment = {}
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
	pending_death = ""
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
	equipment = {}
	equipment_changed.emit()
	statuses = []
	statuses_changed.emit()
	field_state = {}
	talk_counts = {}
	talk_now = 0
	wake_at_run_start = true
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


## 하루 중 몇 분째인지 (0 ~ 1439)
func minute_of_day() -> int:
	return int(clock) % 1440


func day() -> int:
	return int(clock / 1440.0) + 1


## "HH:MM"
func clock_text() -> String:
	var m := int(clock) % 1440
	return "%02d:%02d" % [m / 60, m % 60]


# ---------------------------------------------------------------- 부활 (§11)
## 사망 순간 적용할 부활 규칙: Revivals 에서 condition 이 참인 첫 행. 없으면 {} (게임 처음부터).
## 영구 능력치 강화는 없다 — 부활은 '그 회차를 이어 가는 것'.
## 지금 죽어야 하나 → 사망 원인 cause_id (아니면 ""). 효과 die: 가 먼저, 그다음 death_cause 가 있는 생존 수치가 0 인 것.
func death_cause_now() -> String:
	if pending_death != "":
		return pending_death
	for p in DataLoader.survival:
		if str(p.get("death_cause", "")) != "" and get_survival(p.param_id) <= 0.0:
			return p.death_cause
	return ""


func find_revival() -> Dictionary:
	for r in DataLoader.revivals:
		if Expr.evaluate(r.condition, self):
			return r
	return {}


## 부활하면 모두 유지한 채 베이스캠프에서 깨어난다.
## TODO(기획 확인): 그대로 두면 바로 다시 죽으므로 치명 부위(머리·몸통)만 최대 HP로 회복. 잘린 팔다리는 그대로 (§9: 거래로만 복구).
func restore_after_revival() -> void:
	for p in player_body.values():
		if p.vital:
			p.hp = p.max_hp
			p.broken = false
	# 0 인 생존 수치 그대로면 깨자마자 다시 죽는다 → Config revive_survival_floor 까지 (임시값, TODO 기획)
	var floor_v := float(DataLoader.config.get("revive_survival_floor", 10))
	for p in DataLoader.survival:
		if str(p.get("death_cause", "")) != "" and get_survival(p.param_id) < floor_v:
			survival[p.param_id] = minf(floor_v, float(p.max))
	survival_changed.emit()
	pending_death = ""
	current_map = DataLoader.get_config_str("basecamp_map", current_map)
	wake_at_run_start = false


## 맵 위 물체 상태 (처치한 적·조사한 곳). kind: "removed" / "done"
func field_has(map_id: String, kind: String, object_id: String) -> bool:
	return object_id in field_state.get(map_id, {}).get(kind, [])


func field_mark(map_id: String, kind: String, object_id: String) -> void:
	if not field_state.has(map_id):
		field_state[map_id] = {"removed": [], "done": []}
	if not field_state[map_id].has(kind):
		field_state[map_id][kind] = []
	if not object_id in field_state[map_id][kind]:
		field_state[map_id][kind].append(object_id)


func field_unmark(map_id: String, kind: String, object_id: String) -> void:
	if field_state.has(map_id) and field_state[map_id].has(kind):
		field_state[map_id][kind].erase(object_id)


## 다른 맵에서 쫓아 들어온 몬스터 (맵 물체와 같은 모양의 사전, x·y = 들어온 칸). kind "gone" = 원래 맵을 떠난 몬스터
func followers(map_id: String) -> Array:
	return field_state.get(map_id, {}).get("followers", [])


func set_followers(map_id: String, list: Array) -> void:
	if not field_state.has(map_id):
		field_state[map_id] = {"removed": [], "done": []}
	field_state[map_id]["followers"] = list


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
## 인벤토리 칸 수 = Config inventory_slots + 장착한 장비(가방)의 bag_slots
func slot_count() -> int:
	var n := DataLoader.get_config_int("inventory_slots", 8)
	for id in equipment.values():
		n += int(DataLoader.items.get(id, {}).get("bag_slots", 0))
	return n


## 소지 개수 (장착한 것 포함 — has: 조건)
func item_count(item_id: String) -> int:
	var n := 0
	for slot in inventory:
		if slot.id == item_id:
			n += slot.count
	for id in equipment.values():
		if id == item_id:
			n += 1
	return n


# ---------------------------------------------------------------- 장비·무게
## 들고 있는 무게 (인벤토리 + 장착한 장비)
func carry_weight() -> float:
	var w := 0.0
	for slot in inventory:
		w += float(DataLoader.items.get(slot.id, {}).get("weight", 0.0)) * slot.count
	for id in equipment.values():
		w += float(DataLoader.items.get(id, {}).get("weight", 0.0))
	return w


func carry_max() -> float:
	return float(DataLoader.config.get("carry_max_weight", 30))


## 무게에 따른 이동 속도 배율: carry_heavy_weight 미만 1, 그 이상 carry_heavy_speed_mult, 최대 무게 이상 0 (못 움직임)
## TODO(기획): 기준 무게·배율은 임시 Config 값. 근력 등 능력치와의 관계 미정
func carry_speed_mult() -> float:
	var w := carry_weight()
	if w >= carry_max():
		return 0.0
	if w >= float(DataLoader.config.get("carry_heavy_weight", 20)):
		return float(DataLoader.config.get("carry_heavy_speed_mult", 0.5))
	return 1.0


## 장비 칸 정의 { slot_id, name, kind, col, row } (없으면 {})
func equip_slot_def(slot_id: String) -> Dictionary:
	for s in DataLoader.equip_slots:
		if s.slot_id == slot_id:
			return s
	return {}


## item 을 slot_id 칸에 넣을 수 있나: 손(kind=hand)은 아무 아이템이나, 그 밖에는 아이템 equip_slot 과 칸 kind 가 같아야
func can_equip_in(item_id: String, slot_id: String) -> bool:
	var slot := equip_slot_def(slot_id)
	if slot.is_empty() or not DataLoader.items.has(item_id):
		return false
	return slot.kind == "hand" or slot.kind == DataLoader.items[item_id].get("equip_slot", "")


## 칸을 정하지 않고 장착할 때(우클릭) 고를 칸: 맞는 빈 칸 → 맞는 칸(바꿔 끼기). 종류가 없으면 손.
func pick_equip_slot(item_id: String) -> String:
	var kind: String = DataLoader.items.get(item_id, {}).get("equip_slot", "")
	var want := kind if kind != "" else "hand"
	var fits: Array = DataLoader.equip_slots.filter(func(s): return s.kind == want)
	if fits.is_empty():
		return ""
	for s in fits:
		if not equipment.has(s.slot_id):
			return s.slot_id
	return fits[0].slot_id


## 인벤토리 index 칸의 아이템(1개)을 slot_id 칸에 장착 (비우면 pick_equip_slot). 손에 든 것은 소지품 칸을 차지하지 않는다.
## 그 칸에 이미 장비가 있으면 그것은 인벤토리로 돌아온다. 실패하면 이유(문자열), 성공하면 "".
func equip(index: int, slot_id := "") -> String:
	if index < 0 or index >= inventory.size():
		return "없는 칸"
	var id: String = inventory[index].id
	if slot_id == "":
		slot_id = pick_equip_slot(id)
	if not can_equip_in(id, slot_id):
		var slot := equip_slot_def(slot_id)
		return "%s 은(는) %s 칸에 넣을 수 없다." % [DataLoader.item_name(id), slot.get("name", "그")]
	var old: String = equipment.get(slot_id, "")
	if old != "" and not _can_hold_after(slot_id, id, 0):
		return "바꿔 낀 %s 을(를) 넣을 칸이 없다." % DataLoader.item_name(old)
	inventory[index].count -= 1
	if inventory[index].count <= 0:
		inventory.remove_at(index)
	equipment[slot_id] = id
	if old != "":
		inventory.insert(mini(index, inventory.size()), {"id": old, "count": 1})
	inventory_changed.emit()
	equipment_changed.emit()
	return ""


## 장비를 벗어 인벤토리로. 가방을 벗어서 칸이 모자라면 못 벗는다. 실패하면 이유, 성공하면 "".
func unequip(slot_id: String) -> String:
	var id: String = equipment.get(slot_id, "")
	if id == "":
		return ""
	if not _can_hold_after(slot_id, "", 1):
		return "%s 을(를) 벗으면 소지품이 칸에 다 들어가지 않는다." % DataLoader.item_name(id)
	equipment.erase(slot_id)
	inventory.append({"id": id, "count": 1})
	inventory_changed.emit()
	equipment_changed.emit()
	return ""


## slot_id 칸 장비를 new_id 로 바꾸고(빈 문자열이면 벗음) 인벤토리에 extra 칸이 더 필요할 때 다 들어가는지
func _can_hold_after(slot_id: String, new_id: String, extra: int) -> bool:
	var old: String = equipment.get(slot_id, "")
	var bonus := int(DataLoader.items.get(new_id, {}).get("bag_slots", 0)) - int(DataLoader.items.get(old, {}).get("bag_slots", 0))
	return inventory.size() + extra <= slot_count() + bonus


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
	# 인벤토리에 모자라면 장착한 것에서 (예: 효과 item:-knife 인데 칼을 손에 들고 있을 때)
	for slot_id in equipment.keys():
		if left > 0 and equipment[slot_id] == item_id:
			equipment.erase(slot_id)
			left -= 1
			equipment_changed.emit()
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


## 조건 combat:any / combat:enemy_id
func in_combat(id: String) -> bool:
	return combat_enemy != "" and (id == "any" or id == combat_enemy)


func has_trait(name: String) -> bool:
	return name in traits or owned_traits.any(func(t): return t.trait_id == name)


func owned_trait_ids() -> Array:
	return owned_traits.map(func(t): return t.trait_id)


## 특성 얻기(on)·잃기. 같은 특성은 한 번만. 바뀌었으면 true
## 반대 특성(Traits.conflicts, 어느 쪽에 적혀 있든)을 가지고 있으면 그것은 사라지고 새 특성으로 바뀐다
func set_trait(id: String, on: bool, from := "event") -> bool:
	var have := id in owned_trait_ids()
	if on == have:
		return false
	if on:
		var mine: Array = DataLoader.traits.get(id, {}).get("conflicts", [])
		owned_traits = owned_traits.filter(func(t):
			return not (t.trait_id in mine or id in DataLoader.traits.get(t.trait_id, {}).get("conflicts", [])))
		owned_traits.append({"trait_id": id, "from": from})
	else:
		owned_traits = owned_traits.filter(func(t): return t.trait_id != id)
	traits_changed.emit()
	return true


## 캐릭터 생성 확정: 고른 특성으로 (예전 특성은 모두 버림)
func create_character(trait_ids: Array) -> void:
	owned_traits = trait_ids.map(func(id): return {"trait_id": id, "from": "creation"})
	character_created = true
	traits_changed.emit()


## 완전히 새 게임: 월드 기록(플래그·회차·사망 수)과 특성을 지운다. 저장 슬롯은 그대로
func reset_world() -> void:
	world_from_dict({})
	owned_traits = []
	character_created = false
	traits_changed.emit()


## 조건 status:id — 상태이상에 걸려 있나
func has_status(id: String) -> bool:
	return id in statuses


## 상태이상 걸기(on=true)·풀기. 이미 같은 상태면 아무 일 없음. 바뀌었으면 true.
## TODO(기획): 상태이상의 실제 효과(체력 감소·판정 보정 등)와 지속 시간 — 지금은 표시·조건용
func set_status(id: String, on: bool) -> bool:
	if on == has_status(id):
		return false
	if on:
		statuses.append(id)
	else:
		statuses.erase(id)
	statuses_changed.emit()
	return true


## 조건 count:run / count:death (월드 기록)
func get_count(name: String) -> int:
	match name:
		"run": return run_count
		"death": return death_count
		"talk": return talk_now
	return 0


## 대화 시작: 이 대화(시작 노드)를 전에 몇 번 했는지를 talk_now 로 두고 횟수를 1 올린다
func begin_talk(start_node: String) -> void:
	talk_now = int(talk_counts.get(start_node, 0))
	talk_counts[start_node] = talk_now + 1


# ---------------------------------------------------------------- 사지 절단·복구 (§9, §10)
## 조건 cut:part_id / cut:any — 잘린(파괴된 비치명) 팔다리
func is_severed(part_id: String) -> bool:
	for p in player_body.values():
		if p.broken and not p.vital and (part_id == "any" or p.part_id == part_id):
			return true
	return false


## 효과 restore:part_id / restore:all — 잘린 팔다리를 최대 HP로 되돌린다 (초월체 거래, §10).
## 복구한 부위 이름 목록을 돌려준다 (잘려 있지 않으면 아무 일 없음).
func restore_limb(part_id: String) -> Array:
	var restored := []
	for p in player_body.values():
		if p.broken and not p.vital and (part_id == "all" or p.part_id == part_id):
			p.hp = p.max_hp
			p.broken = false
			restored.append(p.name)
	if not restored.is_empty():
		body_changed.emit()
	return restored


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
	return {"world_flags": world_flags.keys(), "run_count": run_count, "death_count": death_count,
		"owned_traits": owned_traits.duplicate(true), "character_created": character_created}


func world_from_dict(d: Dictionary) -> void:
	world_flags = {}
	for f in d.get("world_flags", []):
		world_flags[f] = true
	run_count = int(d.get("run_count", 0))
	death_count = int(d.get("death_count", 0))
	owned_traits = _read_traits(d.get("owned_traits", []))
	character_created = bool(d.get("character_created", false))
	flags_changed.emit()
	traits_changed.emit()


static func _read_traits(arr: Variant) -> Array:
	var out := []
	if arr is Array:
		for t in arr:
			if t is Dictionary and str(t.get("trait_id", "")) != "":
				out.append({"trait_id": str(t.trait_id), "from": str(t.get("from", "event"))})
	return out


## 탐험 회차 저장 내용 (베이스캠프에서 저장)
func run_to_dict() -> Dictionary:
	return {
		"current_map": current_map,
		"clock": clock,
		"survival": survival.duplicate(),
		"player_body": player_body.duplicate(true),
		"field_state": field_state.duplicate(true),
		"talk_counts": talk_counts.duplicate(),
		"owned_traits": owned_traits.duplicate(true),
		"inventory": inventory.duplicate(true),
		"equipment": equipment.duplicate(),
		"statuses": statuses.duplicate(),
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
	# 기획 §5.4 안 B: 저장 슬롯의 특성으로 되돌린다 (예전 저장에 특성 기록이 없으면 지금 특성 그대로)
	if d.has("owned_traits"):
		owned_traits = _read_traits(d.owned_traits)
		traits_changed.emit()
	talk_counts = {}
	for k in d.get("talk_counts", {}):
		talk_counts[str(k)] = int(d.talk_counts[k])
	inventory = []
	for slot in d.get("inventory", []):
		inventory.append({"id": str(slot.id), "count": int(slot.count)})
	statuses = []
	for st in d.get("statuses", []):
		statuses.append(str(st))
	equipment = {}
	for k in d.get("equipment", {}):
		equipment[str(k)] = str(d.equipment[k])
	ep_flags = {}
	for f in d.get("flags", []):
		ep_flags[f] = true
	for k in d.get("abilities", {}):
		abilities[k] = int(d.abilities[k])
	survival_changed.emit()
	clock_changed.emit()
	inventory_changed.emit()
	equipment_changed.emit()
	flags_changed.emit()
