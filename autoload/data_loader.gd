extends Node
## res://data/*.json (tools/xlsx_to_json.py 결과물)을 읽어 ID로 조회한다.

const DATA_DIR := "res://data/"

var episodes := {}         # episode_id -> Dictionary
var episode_order: Array[String] = []
var nodes := {}            # node_id -> Dictionary
var choices_by_node := {}  # node_id -> Array[Dictionary] (엑셀 행 순서)
var items := {}            # item_id -> Dictionary
var loot_by_spot := {}     # spot_id -> Array[Dictionary]
var characters := {}       # char_id -> Dictionary
var endings := {}          # ending_id -> Dictionary
var abilities := {}        # ability_id -> Dictionary
var player_parts: Array = []  # 전투: 플레이어 부위 (엑셀 행 순서)
var equip_slots: Array = []   # 장비창 칸 [{ slot_id, name }] (player.xlsx EquipSlots, 행 순서)
var enemies := {}          # 전투: enemy_id -> { name, parts: [...], attacks: [{..., strikes}] }
var maps := {}             # 탐험: map_id -> { width, height, tiles: [String], start: [x, y], objects: [...] }
var map_order: Array[String] = []
var survival: Array = []   # 생존 파라미터 [{ param_id, name, start, max, decay_per_hour, warn }]
var camp_actions: Array = []  # 베이스캠프 행동 (엑셀 행 순서)
var revivals: Array = []   # 부활 규칙 (위에서부터 먼저 맞는 것)
var config := {}           # key -> number


func _ready() -> void:
	load_all()


func load_all() -> void:
	episodes.clear()
	episode_order.clear()
	nodes.clear()
	choices_by_node.clear()
	items.clear()
	loot_by_spot.clear()
	characters.clear()
	endings.clear()
	abilities.clear()
	player_parts = []
	equip_slots = []
	enemies.clear()
	maps.clear()
	map_order.clear()
	survival = []
	camp_actions = []
	revivals = []

	for ep in _read_list("episodes"):
		episodes[ep.episode_id] = ep
		episode_order.append(ep.episode_id)
	for n in _read_list("nodes"):
		nodes[n.node_id] = n
	for c in _read_list("choices"):
		if not choices_by_node.has(c.node_id):
			choices_by_node[c.node_id] = []
		choices_by_node[c.node_id].append(c)
	for it in _read_list("items"):
		it.stack_max = int(it.stack_max)
		items[it.item_id] = it
	for lo in _read_list("loot"):
		lo.amount = int(lo.amount)
		lo.time_cost = int(lo.time_cost)
		if not loot_by_spot.has(lo.spot_id):
			loot_by_spot[lo.spot_id] = []
		loot_by_spot[lo.spot_id].append(lo)
	for ch in _read_list("characters"):
		characters[ch.char_id] = ch
	for en in _read_list("endings"):
		endings[en.ending_id] = en
	if FileAccess.file_exists(DATA_DIR + "abilities.json"):
		for ab in _read_list("abilities"):
			abilities[ab.ability_id] = ab
	if FileAccess.file_exists(DATA_DIR + "equip_slots.json"):
		equip_slots = _read_list("equip_slots")
	if FileAccess.file_exists(DATA_DIR + "player_parts.json"):
		player_parts = _read_list("player_parts")
	if FileAccess.file_exists(DATA_DIR + "enemies.json"):
		for en in _read_list("enemies"):
			enemies[en.enemy_id] = en
	if FileAccess.file_exists(DATA_DIR + "survival.json"):
		survival = _read_list("survival")
	if FileAccess.file_exists(DATA_DIR + "camp_actions.json"):
		camp_actions = _read_list("camp_actions")
	if FileAccess.file_exists(DATA_DIR + "revivals.json"):
		revivals = _read_list("revivals")
	if FileAccess.file_exists(DATA_DIR + "maps.json"):
		for m in _read_list("maps"):
			maps[m.map_id] = m
			map_order.append(m.map_id)
	var cfg = _read("config")
	config = cfg if cfg is Dictionary else {}


func get_config_str(key: String, default := "") -> String:
	return str(config.get(key, default))


func get_config_int(key: String, default: int) -> int:
	return int(config.get(key, default))


func character_name(char_id: String) -> String:
	if char_id == "":
		return ""
	return characters.get(char_id, {}).get("name", char_id)


## 대화 이름표 색 (#RRGGBB). 지정 안 됐으면 ""
func character_color(char_id: String) -> String:
	return characters.get(char_id, {}).get("name_color", "")


func ability_name(ability_id: String) -> String:
	return abilities.get(ability_id, {}).get("name", ability_id)


func item_name(item_id: String) -> String:
	return items.get(item_id, {}).get("name", item_id)


func _read_list(name: String) -> Array:
	var v = _read(name)
	return v if v is Array else []


func _read(name: String) -> Variant:
	var path := DATA_DIR + name + ".json"
	if not FileAccess.file_exists(path):
		push_error("[DataLoader] 파일 없음: %s (tools/xlsx_to_json.py 를 먼저 실행)" % path)
		return null
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	if parsed == null:
		push_error("[DataLoader] JSON 파싱 실패: %s" % path)
	return parsed
