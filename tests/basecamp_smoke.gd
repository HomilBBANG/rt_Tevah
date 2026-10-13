extends Node
## 베이스캠프·생존 스모크 테스트: 새 회차 → 거점 행동·저장 → 탐험 맵 이동 → 시간 흐름·보급 → 소지품으로 식사
## → 이어하기. user://basecamp_smoke/ 에 스크린샷. 화면이 필요하므로 --headless 없이:
##   Godot_v4.7-stable_win64_console.exe --path . res://tests/basecamp_smoke.tscn

const FieldScript = preload("res://scenes/field/field.gd")

var _shot := 0
var _fail := 0
var f: Node


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute("user://basecamp_smoke")
	SaveManager.save_dir = "user://test_saves/"
	SaveManager.delete_all()
	SaveManager.begin_run()
	f = load("res://scenes/field/field.tscn").instantiate()
	add_child(f)
	await _wait(0.3)
	check(f.map.map_id == "basecamp", "새 회차는 베이스캠프에서")
	await _snap("basecamp")

	# 거점 메뉴
	_teleport(4, 3)   # 거점 (4,2) 아래
	await _wait(0.15)
	check("거점" in f.get_node("%Prompt").text, "거점 근처 → 안내")
	_press("interact")
	await _wait(0.2)
	check(f.get_node("%CampPanel").visible and f.frozen, "거점 메뉴 열림, 시간 멈춤")
	check(_find_button(f, "식사 (통조림 1개)  (30분)").disabled, "통조림 없으면 식사 불가")
	var t0 := GameState.clock
	await _press_button("씻기  (30분)")
	check(is_equal_approx(GameState.clock - t0, 30.0) and GameState.get_survival("hygiene") == 100.0, "씻기: 30분, 위생 회복")
	await _press_button("푹 자기  (8시간)")
	check(is_equal_approx(GameState.clock - t0, 510.0), "수면 8시간 → 16:30 (%s)" % GameState.clock_text())
	await _snap("camp_menu")
	await _press_button("저장")
	check(SaveManager.has_run_save() and "저장했다" in f.get_node("%CampResult").text, "베이스캠프에서 저장")
	await _press_button("닫기")

	# 탐험 맵으로
	_teleport(7, 5)   # 출구 (7,6) 위
	await _wait(0.15)
	_press("interact")
	await _wait(0.3)
	check(f.map.map_id == "test_field" and GameState.current_map == "test_field", "출구 → 탐험 지역")
	# 실시간 흐름: 1초 ≈ 2분
	var t1 := GameState.clock
	var h1 := GameState.get_survival("hunger")
	await _wait(1.0)
	check(GameState.clock - t1 > 1.5 and GameState.get_survival("hunger") < h1, "탐험 중 시간 흐름·포만감 감소 (+%.1f분)" % (GameState.clock - t1))

	# 보급 상자 (11,6) → 음식·물, 10분
	_teleport(10, 6)
	await _wait(0.15)
	var t2 := GameState.clock
	_press("interact")
	await _wait(0.3)
	check(GameState.item_count("food") == 2 and GameState.item_count("water") == 2, "보급 상자: 통조림·물 2개씩")
	check(GameState.clock - t2 >= 10.0, "조사 시간 10분")
	await _snap("supply")
	_press("interact")
	await _wait(0.1)

	# 소지품 열어 통조림 먹기
	var h2 := GameState.get_survival("hunger")
	_press("inventory")
	await _wait(0.2)
	check(f.get_node("%Inventory").visible and f.frozen, "소지품 열림, 시간 멈춤")
	await _press_button("통조림(테스트) x2")
	await _snap("inventory")
	await _press_button("사용")
	check(GameState.item_count("food") == 1 and GameState.get_survival("hunger") > h2, "통조림 사용 → 포만감 회복")
	await _press_button("닫기")
	await _wait(0.1)
	check(not f.frozen, "소지품 닫으면 다시 흐름")
	await _snap("field_hud")

	# 저장 안 하고 종료 → 이어하기는 마지막 베이스캠프 저장 (16:30, 통조림 없음)
	f.queue_free()
	await _wait(0.1)
	check(SaveManager.load_run(), "이어하기")
	check(GameState.current_map == "basecamp" and GameState.clock_text() == "16:30" and GameState.item_count("food") == 0,
		"마지막 저장(베이스캠프 16:30)으로 돌아감")

	SaveManager.delete_all()
	print("[basecamp_smoke] 스크린샷 %d장, 실패 %d → %s" % [_shot, _fail, ProjectSettings.globalize_path("user://basecamp_smoke")])
	get_tree().quit(1 if _fail > 0 else 0)


func _find_button(root: Node, text: String) -> Button:
	for c in root.find_children("*", "Button", true, false):
		if c.text == text and c.is_visible_in_tree():
			return c
	return Button.new()


func _press_button(text: String) -> void:
	var b := _find_button(f, text)
	if not b.is_inside_tree():
		check(false, "버튼 없음: " + text)
	else:
		b.pressed.emit()
	await _wait(0.15)


func _teleport(tx: float, ty: float) -> void:
	f.player.position = Vector2((tx + 0.5) * f.tile, (ty + 0.5) * f.tile)


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
	get_viewport().get_texture().get_image().save_png("user://basecamp_smoke/%02d_%s.png" % [_shot, name])


func check(ok: bool, label: String) -> void:
	print(("ok   " if ok else "FAIL ") + label)
	if not ok:
		_fail += 1
