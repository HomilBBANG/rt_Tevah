extends Node
## 장비·가방·무게 규칙 (GameState). 실행:
##   Godot_v4.7-stable_win64_console.exe --headless --path . res://tests/test_equipment.tscn
## 더미 데이터: 장비 칸 가방·머리·왼손·몸·오른손·왼다리·오른다리 (손 = 아무 아이템), small_bag(가방, +4칸, 무게 1),
## knife(손, 무게 1), junk(무게 2), water(무게 1, 5개씩), Config inventory_slots 4,
## carry_heavy_weight 20, carry_max_weight 30, carry_heavy_speed_mult 0.5

var _pass := 0
var _fail := 0


func _ready() -> void:
	GameState.reset_run()
	check(GameState.slot_count() == 4 and GameState.equipment.is_empty(), "가방 없이 4칸, 장비 없음")

	# 가방 장착 → 칸 +4, 인벤토리에서 빠짐
	GameState.add_item("small_bag", 1)
	GameState.add_item("knife", 1)
	check(GameState.equip(0) == "" and GameState.equipment.get("bag") == "small_bag", "가방 우클릭 장착 → 가방 칸")
	check(GameState.slot_count() == 8 and GameState.inventory.size() == 1, "칸 4 → 8, 가방은 소지품에서 빠짐")
	check(GameState.equip(0) == "" and GameState.equipment.get("left_hand") == "knife", "칼 → 빈 손(왼손)")
	check(GameState.item_count("knife") == 1, "손에 든 것도 소지 개수에 들어감 (has: 조건)")

	# 손에는 아무 아이템이나, 손에 든 것은 소지품 칸을 차지하지 않음
	GameState.add_item("water", 1)
	check(GameState.equip(0) == "" and GameState.equipment.get("right_hand") == "water" and GameState.inventory.is_empty(),
		"물도 손에 들 수 있음 (오른손), 소지품 0칸")
	GameState.add_item("food", 1)
	check(GameState.equip(0) == "" and GameState.equipment.get("left_hand") == "food" and GameState.item_count("knife") == 1
		and GameState.inventory[0].id == "knife", "양손이 차 있으면 왼손과 바꿔 들기 → 칼은 소지품으로")
	check(not GameState.can_equip_in("knife", "head") and GameState.equip(0, "head") != "", "칼은 머리 칸에 못 넣음")
	check(GameState.can_equip_in("small_bag", "bag") and not GameState.can_equip_in("water", "bag"), "가방 칸은 가방만")

	# 가방을 벗으면 칸이 줄어 다 안 들어가면 못 벗는다
	GameState.equipment = {"bag": "small_bag"}
	GameState.inventory = []
	GameState.add_item("junk", 8)    # 가방 덕분에 8칸
	check(GameState.inventory.size() == 8, "가방 덕분에 8칸 사용")
	check(GameState.unequip("bag") != "" and GameState.equipment.has("bag"), "벗으면 8+1칸 > 4칸 → 못 벗음")
	GameState.remove_item("junk", 5)
	check(GameState.unequip("bag") == "" and not GameState.equipment.has("bag") and GameState.slot_count() == 4,
		"3+1칸 ≤ 4칸 → 벗기, 4칸")

	# 무게 = 소지품 + 장비
	GameState.equipment = {}
	GameState.inventory = []
	for i in 4:
		GameState.add_item("water", 5)   # 4칸 x 5 = 20
	check(is_equal_approx(GameState.carry_weight(), 20.0) and GameState.carry_speed_mult() == 0.5, "무게 20 → 느려짐 (x0.5)")
	GameState.inventory = [{"id": "water", "count": 5}]
	check(GameState.carry_speed_mult() == 1.0, "무게 5 → 속도 그대로")
	GameState.inventory = []
	for i in 4:
		GameState.add_item("water", 5)
	for slot in ["left_hand", "right_hand", "head", "left_leg", "right_leg"]:
		GameState.equipment[slot] = "junk"   # +10 = 30
	check(is_equal_approx(GameState.carry_weight(), 30.0) and GameState.carry_speed_mult() == 0.0, "손·장비 무게도 포함, 30 → 못 움직임")

	# 장착한 아이템을 효과로 빼기 (item:-knife)
	GameState.inventory = []
	GameState.equipment = {"right_hand": "knife"}
	check(GameState.remove_item("knife", 1) == 1 and GameState.equipment.is_empty(), "item:-knife → 손에 든 칼이 빠짐")

	# 저장·불러오기
	GameState.add_item("small_bag", 1)
	GameState.equip(0)
	var d := GameState.run_to_dict()
	GameState.reset_run()
	GameState.run_from_dict(JSON.parse_string(JSON.stringify(d)))
	check(GameState.equipment.get("bag") == "small_bag" and GameState.slot_count() == 8, "저장·불러오기: 장비 유지")

	# 판정 보정: 손에 든 칼의 dice_bonus(strength+1)
	var dp := StoryRunner.dice_preview({"check": "strength", "dc": 10, "mod": 0})
	check(not dp.parts.any(func(p): return p.label == DataLoader.item_name("knife")), "칼이 없으면 보정 없음")
	GameState.add_item("knife", 1)
	GameState.equip(0)
	dp = StoryRunner.dice_preview({"check": "strength", "dc": 10, "mod": 0})
	check(dp.parts.any(func(p): return p.label == DataLoader.item_name("knife") and p.value == 1), "손에 든 칼도 판정 보정 +1")

	print("\n[test_equipment] %d 통과, %d 실패" % [_pass, _fail])
	get_tree().quit(1 if _fail > 0 else 0)


func check(ok: bool, label: String) -> void:
	if ok:
		_pass += 1
		print("ok   " + label)
	else:
		_fail += 1
		print("FAIL " + label)
