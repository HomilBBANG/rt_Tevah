extends RefCounted
## 턴제 전투 로직 (기획서 §7–9). UI 없이 동작하고, 화면(scenes/combat.gd)이 호출해서 결과를 그린다.
##
## 흐름: 플레이어 턴(공격·아이템·도주, 방어는 지금 화면에 버튼 없음) → 적 턴(공격 1개 = 타격 1~N회, 타격마다 회피 판정) → 반복
## 회피 판정은 judge_dodge() — 누른 키·타이밍 오차(초)만 받아 결과를 낸다. 시간 측정은 화면 몫.
##
## TODO(기획 §18 미확정, 지금은 임시 규칙):
##  - 턴 순서: 플레이어 먼저, 그다음 적
##  - 양팔이 모두 잘리면 공격 불가, 다리 하나라도 잘리면 도주 불가
##  - 이미 잘린 부위를 노린 타격은 몸통으로 들어감
##  - 일반 회피의 추가 자원 소모(스태미나) 없음
##  - 부위 HP·명중률·피해량은 엑셀 데이터 값

const DODGE_PERFECT := "perfect"
const DODGE_NORMAL := "normal"
const DODGE_FAIL := "fail"

## 이름 → 상태. 부위: { part_id, name, hp, max_hp, vital, broken, (플레이어) key, (적) hit_chance }
var player_parts := {}
var player_order: Array = []
var enemy := {}
var enemy_parts := {}
var enemy_order: Array = []
var attacks: Array = []

var defending := false
var outcome := ""            # "" 진행 중 / "win" / "lose" / "fled"
var last_flee := {}          # 마지막 도주 굴림 { roll(1~100), chance(%), success }

## 테스트용: 비어 있지 않으면 0~100 난수 대신 앞에서부터 꺼내 쓴다 (명중·도주·공격 선택)
var forced_rolls: Array[float] = []


## player_state: 이전 전투에서 이어지는 플레이어 부위 상태 (비우면 새 몸). 복사해서 쓴다.
func setup(enemy_id: String, player_state := {}) -> bool:
	var data: Dictionary = DataLoader.enemies.get(enemy_id, {})
	if data.is_empty():
		push_error("[Combat] 없는 적: %s" % enemy_id)
		return false
	enemy = {"enemy_id": enemy_id, "name": data.name, "flee_chance": data.get("flee_chance"), "image": data.get("image", "")}
	player_parts = player_state.duplicate(true) if not player_state.is_empty() else fresh_player_parts()
	player_order.clear()
	for p in DataLoader.player_parts:
		player_order.append(p.part_id)
	enemy_parts.clear()
	enemy_order.clear()
	for p in data.parts:
		enemy_parts[p.part_id] = {"part_id": p.part_id, "name": p.name, "hp": int(p.hp), "max_hp": int(p.hp),
			"vital": p.vital, "broken": false, "hit_chance": float(p.hit_chance)}
		enemy_order.append(p.part_id)
	attacks = data.attacks
	defending = false
	outcome = ""
	return true


## 다친 곳 없는 플레이어 부위 상태
static func fresh_player_parts() -> Dictionary:
	var parts := {}
	for p in DataLoader.player_parts:
		parts[p.part_id] = {"part_id": p.part_id, "name": p.name, "key": p.key, "hp": int(p.hp),
			"max_hp": int(p.hp), "vital": p.vital, "broken": false}
	return parts


static func config_float(key: String, default: float) -> float:
	return float(DataLoader.config.get(key, default))


# ---------------------------------------------------------------- 플레이어 턴
func can_attack() -> bool:
	return not (_player_broken("left_arm") and _player_broken("right_arm"))


func can_flee() -> bool:
	return not (_player_broken("left_leg") or _player_broken("right_leg"))


## 부위 공격. { hit, part, damage, broken, killed }
func player_attack(part_id: String) -> Dictionary:
	defending = false
	var part: Dictionary = enemy_parts.get(part_id, {})
	if part.is_empty() or part.broken or not can_attack():
		return {}
	var res := {"hit": _roll() < part.hit_chance, "part": part_id, "damage": 0, "broken": false, "killed": false}
	if res.hit:
		res.damage = int(config_float("combat_player_damage", 10))
		part.hp = maxi(0, part.hp - res.damage)
		if part.hp == 0:
			part.broken = true
			res.broken = true
			if part.vital:
				res.killed = true
				outcome = "win"
	return res


func player_defend() -> void:
	defending = true


## 이 적에게서 도주할 확률 (%): Enemies.flee_chance, 비어 있으면 Config combat_flee_chance
func flee_chance() -> float:
	var c = enemy.get("flee_chance")
	return float(c) if c != null else config_float("combat_flee_chance", 50)


## 도주: 주사위 1~100 이 성공률 이하면 성공. 굴린 값은 last_flee = { roll, chance, success }
func player_flee() -> bool:
	defending = false
	last_flee = {}
	if not can_flee():
		return false
	var chance := flee_chance()
	var roll := clampi(int(_roll()) + 1, 1, 100)
	last_flee = {"roll": roll, "chance": chance, "success": roll <= chance}
	if last_flee.success:
		outcome = "fled"
	return last_flee.success


## 아이템 사용으로 턴을 씀 (효과는 화면이 StoryRunner 로 적용)
## TODO(기획 §7.1): 아이템 사용이 턴을 쓰는지 — 지금은 Config combat_item_uses_turn (기본 1 = 씀)
func player_use_item() -> void:
	defending = false


static func item_uses_turn() -> bool:
	return config_float("combat_item_uses_turn", 1) != 0


# ---------------------------------------------------------------- 적 턴
## 쓰는 부위가 파괴되지 않은 공격들
func available_attacks() -> Array:
	return attacks.filter(func(a): return a.part == "" or not enemy_parts.get(a.part, {}).get("broken", false))


## 가중치로 공격 하나 고르기. 쓸 수 있는 공격이 없으면 {}.
func choose_enemy_attack() -> Dictionary:
	var pool := available_attacks()
	if pool.is_empty():
		return {}
	var total := 0
	for a in pool:
		total += maxi(1, int(a.weight))
	var pick := _roll() / 100.0 * total
	for a in pool:
		pick -= maxi(1, int(a.weight))
		if pick < 0:
			return a
	return pool.back()


## 회피 판정. offset = 누른 시각 - 타격 시각 (초, 음수면 일찍 누름). 안 눌렀으면 pressed_key = "".
static func judge_dodge(pressed_key: String, expected_key: String, offset: float) -> String:
	if pressed_key == "" or pressed_key != expected_key:
		return DODGE_FAIL
	if absf(offset) <= config_float("combat_perfect_window", 0.08):
		return DODGE_PERFECT
	if absf(offset) <= config_float("combat_normal_window", 0.2):
		return DODGE_NORMAL
	return DODGE_FAIL


## 이 타격을 피하려면 눌러야 하는 키
func dodge_key_for(strike: Dictionary) -> String:
	return player_parts.get(_hit_part(strike.target), {}).get("key", "")


## 타격 결과 적용. { judgement, part, damage, broken, severed, dead }
func apply_strike(attack: Dictionary, strike: Dictionary, judgement: String) -> Dictionary:
	var part_id := _hit_part(strike.target)
	var res := {"judgement": judgement, "part": part_id, "damage": 0, "broken": false, "severed": false, "dead": false}
	if judgement != DODGE_FAIL:
		return res
	var dmg := int(attack.damage)
	if defending:
		dmg = int(round(dmg * config_float("combat_defend_mult", 0.5)))
	var part: Dictionary = player_parts[part_id]
	res.damage = dmg
	part.hp = maxi(0, part.hp - dmg)
	if part.hp == 0 and not part.broken:
		part.broken = true
		res.broken = true
		res.severed = not part.vital
		if part.vital:
			res.dead = true
			outcome = "lose"
	return res


func end_enemy_turn() -> void:
	defending = false


# ---------------------------------------------------------------- 내부
## 이미 잘린 부위를 노리면 몸통으로 (TODO 임시 규칙)
func _hit_part(target: String) -> String:
	if player_parts.get(target, {}).get("broken", false) and player_parts.has("torso"):
		return "torso"
	return target


func _player_broken(part_id: String) -> bool:
	return player_parts.get(part_id, {}).get("broken", false)


func _roll() -> float:
	if not forced_rolls.is_empty():
		return forced_rolls.pop_front()
	return randf() * 100.0
