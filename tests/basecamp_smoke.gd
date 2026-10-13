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

	# 고양이 루틴: 06:00-12:00, 20:00-23:00. 지금 08:00 → 와 있음. (9,2) 아래에서 말 걸어 저장
	check(f.npcs.size() == 1 and f.npcs[0].active and f.npcs[0].node.visible, "08:00 고양이가 와 있음")
	_teleport(9, 3)
	await _wait(0.15)
	check("대화: 고양이" in f.get_node("%Prompt").text, "고양이 근처 → 대화 안내")
	_press("interact")
	await _wait(0.3)
	var dlg: Node = f._dialogue_ui
	await _snap("cat")
	_find_button(dlg, "쓰다듬는다 (저장)").pressed.emit()
	await _wait(0.2)
	check(SaveManager.has_run_save(), "고양이를 쓰다듬어 저장")
	await _snap("cat_saved")
	dlg.advance()
	await _wait(0.2)
	check(f._dialogue_ui == null and not f.frozen, "'저장했다' 보여준 뒤 필드로")
	SaveManager.delete_run_save()

	# 거점 메뉴
	_teleport(4, 3)   # 거점 (4,2) 아래
	await _wait(0.15)
	check("거점" in f.get_node("%Prompt").text, "거점 근처 → 안내")
	_press("interact")
	await _wait(0.2)
	check(f.get_node("%CampPanel").visible and f.frozen, "거점 메뉴 열림, 시간 멈춤")
	check(_find_button(f, "식사 (통조림 1개)  (30분)").disabled, "통조림 없으면 식사 불가")
	check(_find_button(f, "씻기 (물 1병)  (30분)").disabled, "물 없으면 씻기 불가")
	await _press_button("닫기")
	GameState.add_item("water", 1)
	_press("interact")
	await _wait(0.2)
	var t0 := GameState.clock
	await _press_button("씻기 (물 1병)  (30분)")
	check(is_equal_approx(GameState.clock - t0, 30.0) and GameState.get_survival("hygiene") == 100.0, "씻기: 30분, 위생 회복")
	check(GameState.item_count("water") == 0 and _find_button(f, "씻기 (물 1병)  (30분)").disabled, "물 1병 소모 → 다시 비활성")
	check(_find_button(f, "저장").text == "", "따로 '저장' 버튼은 없음 (잠·고양이로만)")
	await _press_button("잠자기  (1시간 단위)")
	check(f._sleep_pick.hours == 8 and f._sleep_value.text == "8시간", "처음엔 8시간 (sleep_default_hours)")
	await _keys("ui_right", 10)
	check(f._sleep_pick.hours == 12, "→ 로 늘리기, 최대 12시간에서 멈춤")
	await _keys("ui_left", 20)
	check(f._sleep_pick.hours == 1 and f._sleep_value.text == "1시간", "← 로 줄이기, 1시간에서 멈춤")
	await _keys("move_right", 7)
	check(f._sleep_pick.hours == 8 and "16:" in f._sleep_wake.text, "D 키로도 조절, 일어날 시각 표시: %s" % f._sleep_wake.text)
	await _snap("sleep_picker")
	await _keys("interact", 1)
	await _wait(0.3)
	var hhmm := GameState.clock_text()
	check(hhmm.begins_with("16:"), "8시간 잠 → 16시대 (%s)" % hhmm)
	check(SaveManager.has_run_save() and "저장했다" in f.get_node("%CampResult").text, "고양이가 있어도 잠자면 저장")
	check(not f.npcs[0].active and not f.npcs[0].node.visible, "16시 → 고양이 떠남 (루틴 밖)")
	await _snap("camp_menu_cat_gone")
	await _press_button("잠자기  (1시간 단위)")
	await _keys("ui_left", 4)
	check(f._sleep_pick.hours == 4, "8 → 4시간")
	await _press_button("잠들기")
	await _wait(0.3)
	check(GameState.clock_text().begins_with("20:") and f.npcs[0].active and f.npcs[0].node.visible, "4시간 더 → 20시대, 고양이 돌아옴")
	var saved_at := GameState.clock_text()
	await _press_button("닫기")
	await _snap("cat_back")

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
	check(GameState.current_map == "basecamp" and GameState.clock_text() == saved_at and GameState.item_count("food") == 0,
		"마지막 저장(베이스캠프에서 자고 일어난 %s)으로 돌아감" % saved_at)

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


## 키를 눌렀다 뗀다 (떼지 않으면 move_* 가 계속 눌린 상태로 남는다)
func _keys(action: String, times: int) -> void:
	for i in times:
		_press(action)
		await get_tree().process_frame
		var up := InputEventAction.new()
		up.action = action
		up.pressed = false
		Input.parse_input_event(up)
		await get_tree().process_frame


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
