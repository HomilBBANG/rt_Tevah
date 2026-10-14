extends Node
## 캐릭터 생성 화면·타이틀 스모크 (창 필요). 스크린샷 user://creation_smoke/. 실행:
##   Godot_v4.7-stable_win64_console.exe --path . res://tests/creation_smoke.tscn

const Creation = preload("res://scenes/character_creation.tscn")
const Title = preload("res://scenes/title.tscn")

var _fail := 0


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute("user://creation_smoke")
	SaveManager.save_dir = "user://test_saves/"
	SaveManager.delete_all()
	# 타이틀: 캐릭터가 없으면 '새 게임' 하나
	var t: Control = Title.instantiate()
	add_child(t)
	await _wait(0.2)
	check(t.get_node("%NewRunButton").text == "새 게임" and t.find_child("NewGameButton", true, false) == null, "타이틀(캐릭터 없음): 새 게임")
	t.queue_free()
	# 생성 화면
	var cc: Control = Creation.instantiate()
	add_child(cc)
	await _wait(0.2)
	await _snap("01_creation_empty")
	cc._rows.heavy_smoker.button_pressed = true      # 체크박스 클릭과 같음
	await _wait(0.1)
	cc._rows.high_intellect.button_pressed = true
	await _wait(0.1)
	cc._show_detail("high_intellect")
	check(cc.selected == ["heavy_smoker", "high_intellect"] and cc._points_label.text.ends_with("1"), "체크 → 남은 P 1")
	check(cc._rows.lucky.disabled and cc._rows.iron_mind.disabled, "못 고르는 특성 회색 (행운아: 선택 불가, 강철 멘탈: 포인트 부족)")
	await _snap("02_creation_picked")
	cc._confirm()
	await _wait(0.2)
	await _snap("03_creation_confirm")
	var dlg := cc.get_children().filter(func(c): return c is ConfirmationDialog)
	check(dlg.size() == 1 and "고지능자" in dlg[0].dialog_text and "1P" in dlg[0].dialog_text, "최종 확인: 고른 특성·남은 P 요약")
	dlg[0].hide()
	cc.queue_free()
	# 타이틀: 캐릭터가 있으면 '새 회차' + '새 게임 (캐릭터 다시 만들기)'
	GameState.create_character(["high_intellect"])
	var t2: Control = Title.instantiate()
	add_child(t2)
	await _wait(0.2)
	check(t2.get_node("%NewRunButton").text == "새 회차" and t2.find_child("NewGameButton", true, false) != null, "타이틀(캐릭터 있음): 새 회차 + 새 게임")
	await _snap("04_title_with_character")
	SaveManager.delete_all()
	print("[creation_smoke] 실패 %d" % _fail)
	get_tree().quit(1 if _fail > 0 else 0)


func _wait(sec: float) -> void:
	await get_tree().create_timer(sec).timeout


func _snap(name: String) -> void:
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("user://creation_smoke/%s.png" % name)


func check(ok: bool, label: String) -> void:
	print(("ok   " if ok else "FAIL ") + label)
	if not ok:
		_fail += 1
