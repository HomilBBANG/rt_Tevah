extends Node
## 소지품(I)·장비창(Q) 스모크 테스트: 격자, 우클릭 장착, 끌어다 놓기, 능력치 탭, 무게로 느려짐·못 움직임.
## user://equipment_smoke/ 에 스크린샷. 화면이 필요하므로 --headless 없이:
##   Godot_v4.7-stable_win64_console.exe --path . res://tests/equipment_smoke.tscn

var _shot := 0
var _fail := 0
var f: Node


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute("user://equipment_smoke")
	SaveManager.save_dir = "user://test_saves/"
	SaveManager.delete_all()
	SaveManager.begin_run()
	preload("res://scenes/field/field.gd").next_map_id = "test_field"
	f = load("res://scenes/field/field.tscn").instantiate()
	add_child(f)
	await _wait(0.3)
	for it in [["small_bag", 1], ["knife", 1], ["water", 2], ["food", 1]]:
		GameState.add_item(it[0], it[1])
	var inv: Node = f.get_node("%Inventory")
	var eq: Node = f.get_node("%Equipment")

	_press("inventory")
	await _wait(0.2)
	check(inv.visible and f.frozen and inv.get_node("%Slots").get_child_count() == 4, "I → 소지품 격자 4칸 (가방 없음), 필드 멈춤")
	_press("equipment")
	await _wait(0.2)
	check(eq.visible and inv.visible, "Q → 장비창 (소지품과 같이 열림)")
	await _snap("both_open")

	# 우클릭으로 가방 장착 → 8칸
	_cell(inv, 0).right_clicked.emit()
	await _wait(0.1)
	check(GameState.equipment.get("bag") == "small_bag" and inv.get_node("%Slots").get_child_count() == 8, "가방 우클릭 → 장착, 8칸")
	# 장비 칸 배치: 엑셀 col·row (가방 왼쪽 위, 머리, 왼손·몸·오른손, 왼다리·오른다리)
	var head: Control = _equip_cell(eq, "head")
	check(_equip_cell(eq, "bag").position == Vector2.ZERO and head.position.x > 0 and head.position.y > 0
		and _equip_cell(eq, "left_leg").position.x > 0 and eq._slots_box.get_child_count() == 7, "장비 칸 7개, 그림대로 배치")
	# 칼을 오른손으로 끌어다 놓기 (머리 칸은 칼·물 모두 안 받음, 손은 아무거나)
	var weapon: Control = _equip_cell(eq, "right_hand")
	var knife_cell: Control = _cell(inv, 0)
	var water_cell: Control = _cell(inv, 1)
	check(knife_cell.item_id == "knife" and weapon._can_drop_data(Vector2.ZERO, knife_cell.info())
		and weapon._can_drop_data(Vector2.ZERO, water_cell.info()) and not head._can_drop_data(Vector2.ZERO, knife_cell.info()),
		"손 칸: 칼·물 모두 받음 / 머리 칸: 칼 안 받음")
	weapon._drop_data(Vector2.ZERO, knife_cell.info())
	await _wait(0.1)
	check(GameState.equipment.get("right_hand") == "knife" and GameState.inventory.size() == 2, "칼을 끌어다 놓기 → 오른손, 소지품 칸에서 빠짐")
	await _snap("equipped")
	# 손을 소지품으로 끌기 → 벗기
	weapon = _equip_cell(eq, "right_hand")
	var empty_cell: Control = _cell(inv, 5)
	check(empty_cell._can_drop_data(Vector2.ZERO, weapon.info()), "소지품 칸은 장비를 받음")
	empty_cell._drop_data(Vector2.ZERO, weapon.info())
	await _wait(0.1)
	check(not GameState.equipment.has("right_hand") and GameState.item_count("knife") == 1, "장비를 소지품으로 끌기 → 벗기")
	# 장비 칸 우클릭 → 벗기 (가방을 벗으면 4칸, 소지품 3칸 + 가방 1 = 4칸 → 가능)
	_equip_cell(eq, "bag").right_clicked.emit()
	await _wait(0.1)
	check(not GameState.equipment.has("bag") and GameState.slot_count() == 4, "가방 칸 우클릭 → 벗기, 4칸")

	# 능력치 탭: 내 상태 + 육각형
	eq.open(1)
	await _wait(0.2)
	check(eq._hex.values.size() == 6 and eq._hex.values[0][0] == "근력" and eq._hex.values[0][1] == 3, "능력치 탭: 6개, 근력 3")
	await _snap("stats_tab")

	_press("equipment")
	_press("inventory")
	await _wait(0.2)
	check(not eq.visible and not inv.visible and not f.frozen, "Q·I 다시 → 닫힘, 필드 다시 움직임")

	# 무게: 최대(30) 이상이면 못 움직임, 20 이상이면 느려짐
	GameState.inventory = []
	for i in 4:
		GameState.add_item("water", 5)   # 20
	for slot in ["left_hand", "right_hand", "head", "left_leg", "right_leg"]:
		GameState.equipment[slot] = "junk"   # +10 = 30
	GameState.equipment_changed.emit()
	var x0: float = f.player.position.x
	Input.action_press("move_right")
	await _wait(0.3)
	Input.action_release("move_right")
	check(absf(f.player.position.x - x0) < 1.0 and "(못 움직임)" in f.get_node("%InventoryButton").text,
		"무게 30 → 못 움직임 (%s)" % f.get_node("%InventoryButton").text)
	await _snap("too_heavy")
	GameState.remove_item("water", 8)   # 22 → 느려짐
	Input.action_press("move_right")
	await _wait(0.5)
	Input.action_release("move_right")
	var moved: float = f.player.position.x - x0
	check(moved > f.tile * 0.6 and moved < f.tile * 1.4, "무게 22 → 절반 속도 (0.5초에 약 1칸, %.0f px)" % moved)

	SaveManager.delete_all()
	GameState.inventory = []
	print("[equipment_smoke] 스크린샷 %d장, 실패 %d → %s" % [_shot, _fail, ProjectSettings.globalize_path("user://equipment_smoke")])
	get_tree().quit(1 if _fail > 0 else 0)


func _cell(inv: Node, i: int) -> Control:
	return inv.get_node("%Slots").get_child(i)


func _equip_cell(eq: Node, slot_id: String) -> Control:
	for c in eq._slots_box.get_children():
		if c.get("slot_id") == slot_id:
			return c
	return null


func _press(action: String) -> void:
	var ev := InputEventAction.new()
	ev.action = action
	ev.pressed = true
	Input.parse_input_event(ev)


func _wait(sec: float) -> void:
	await get_tree().create_timer(sec).timeout


func _snap(name: String) -> void:
	await RenderingServer.frame_post_draw
	_shot += 1
	get_viewport().get_texture().get_image().save_png("user://equipment_smoke/%02d_%s.png" % [_shot, name])


func check(ok: bool, label: String) -> void:
	print(("ok   " if ok else "FAIL ") + label)
	if not ok:
		_fail += 1
