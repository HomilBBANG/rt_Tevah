extends Node
## 장비·가방·무게 규칙 (GameState). 실행:
##   Godot_v4.7-stable_win64_console.exe --headless --path . res://tests/test_equipment.tscn
## 더미 데이터: small_bag(가방 칸, +4칸, 무게 1), knife(무기 칸, 무게 1), junk(무게 2), Config inventory_slots 8,
## carry_heavy_weight 20, carry_max_weight 30, carry_heavy_speed_mult 0.5

var _pass := 0
var _fail := 0


func _ready() -> void:
	GameState.reset_run()
	check(GameState.slot_count() == 8 and GameState.equipment.is_empty(), "처음: 8칸, 장비 없음")

	# 가방 장착 → 칸 +4, 인벤토리에서 빠짐
	GameState.add_item("small_bag", 1)
	GameState.add_item("knife", 1)
	check(GameState.equip(0) == "" and GameState.equipment.get("bag") == "small_bag", "가방 장착")
	check(GameState.slot_count() == 12 and GameState.inventory.size() == 1, "칸 8 → 12, 가방은 인벤토리에서 빠짐")
	check(GameState.equip(0) == "" and GameState.equipment.get("weapon") == "knife" and GameState.inventory.is_empty(), "칼 → 무기 칸")
	check(GameState.item_count("knife") == 1, "장착한 것도 소지 개수에 들어감 (has: 조건)")
	GameState.add_item("water", 1)
	check(GameState.equip(0) != "" and GameState.item_count("water") == 1, "장착할 수 없는 아이템 → 거절")

	# 가방을 벗으면 칸이 줄어 다 안 들어가면 못 벗는다
	GameState.inventory = []
	GameState.add_item("junk", 8)    # 8칸 (stack_max 1)
	GameState.add_item("food", 5)    # 9번째 칸
	check(GameState.inventory.size() == 9, "가방 덕분에 9칸 사용")
	check(GameState.unequip("bag") != "" and GameState.equipment.has("bag"), "벗으면 9+1칸 > 8칸 → 못 벗음")
	GameState.remove_item("food", 5)
	GameState.remove_item("junk", 2)
	check(GameState.unequip("bag") == "" and not GameState.equipment.has("bag") and GameState.slot_count() == 8,
		"칸이 남으면 벗기 → 인벤토리로, 8칸")

	# 무게: 칼 1(장착) + 잡동사니 6x2 + 가방 1 = 14 → 보통
	check(is_equal_approx(GameState.carry_weight(), 14.0), "무게 = 소지품 + 장비 (%.1f)" % GameState.carry_weight())
	check(GameState.carry_speed_mult() == 1.0, "20 미만 → 속도 그대로")
	GameState.inventory = []
	GameState.add_item("junk", 7)   # 14 + 칼 1 = 15 (7칸)
	GameState.add_item("water", 5)  # +5 = 20 (8칸)
	check(is_equal_approx(GameState.carry_weight(), 20.0) and GameState.carry_speed_mult() == 0.5, "20 이상 → 느려짐 (x0.5)")
	GameState.inventory = []
	GameState.add_item("water", 5)
	GameState.add_item("water", 5)
	GameState.add_item("water", 5)
	GameState.add_item("water", 5)
	GameState.add_item("water", 5)
	GameState.add_item("junk", 2)   # 25 + 4 + 칼 1 = 30
	check(GameState.carry_weight() >= 30.0 and GameState.carry_speed_mult() == 0.0, "최대 무게 30 → 못 움직임")

	# 장착한 아이템을 효과로 빼기 (item:-knife)
	GameState.inventory = []
	check(GameState.remove_item("knife", 1) == 1 and not GameState.equipment.has("weapon"), "item:-knife → 손에 든 칼이 빠짐")

	# 저장·불러오기
	GameState.add_item("small_bag", 1)
	GameState.equip(0)
	var d := GameState.run_to_dict()
	GameState.reset_run()
	GameState.run_from_dict(JSON.parse_string(JSON.stringify(d)))
	check(GameState.equipment.get("bag") == "small_bag" and GameState.slot_count() == 12, "저장·불러오기: 장비 유지")

	# 판정 보정: 장착한 칼의 dice_bonus(strength+1)
	var dp := StoryRunner.dice_preview({"check": "strength", "dc": 10, "mod": 0})
	check(not dp.parts.any(func(p): return p.label == DataLoader.item_name("knife")), "칼이 없으면 보정 없음")
	GameState.add_item("knife", 1)
	GameState.equip(0)
	dp = StoryRunner.dice_preview({"check": "strength", "dc": 10, "mod": 0})
	check(dp.parts.any(func(p): return p.label == DataLoader.item_name("knife") and p.value == 1), "장착한 칼도 판정 보정 +1")

	print("\n[test_equipment] %d 통과, %d 실패" % [_pass, _fail])
	get_tree().quit(1 if _fail > 0 else 0)


func check(ok: bool, label: String) -> void:
	if ok:
		_pass += 1
		print("ok   " + label)
	else:
		_fail += 1
		print("FAIL " + label)
