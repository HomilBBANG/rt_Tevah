extends Node
## 고양이 대화의 전투 선택지('싸운다.')가 대화 에디터 미리보기와 실제 게임(베이스캠프) 양쪽에서 전투를 띄우는지.
## 화면이 필요하므로 --headless 없이:
##   Godot_v4.7-stable_win64_console.exe --path . res://tests/cat_combat_smoke.tscn

const FieldScript = preload("res://scenes/field/field.gd")

var _fail := 0


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute("user://cat_combat_smoke")
	# ---------- 미리보기
	var f := FileAccess.open("user://dialogue_preview.json", FileAccess.WRITE)
	f.store_string(JSON.stringify({"node": "fd_cat_a"}))
	f.close()
	var pv: Node = load("res://addons/dialogue_editor/preview.tscn").instantiate()
	add_child(pv)
	await _wait(0.3)
	await _press(pv, "[전투] 싸운다.")
	check(pv._combat != null and not pv._ui.visible, "미리보기: '싸운다.' → 전투 화면")
	await _snap("preview_combat")
	await _end_combat(pv._combat, "fled")
	check(pv._combat == null and StoryRunner.ended, "미리보기: 도주 → 대화 끝(EXIT)")
	pv.queue_free()
	await _wait(0.1)

	# ---------- 실제 게임: 베이스캠프의 고양이
	SaveManager.save_dir = "user://test_saves/"
	SaveManager.delete_all()
	SaveManager.begin_run()
	FieldScript.next_map_id = "basecamp"
	var field: Node = load("res://scenes/field/field.tscn").instantiate()
	add_child(field)
	await _wait(0.3)
	var cat: Dictionary = field.npcs.filter(func(n): return n.data.ref == "cat_start")[0]
	field._start_dialogue(cat)
	await _wait(0.3)
	await _press(field._dialogue_ui, "[전투] 싸운다.")
	check(field._combat_ui != null and field._combat_ui.combat.enemy.enemy_id == "enemy_test", "게임: '싸운다.' → 전투 (적: enemy_test)")
	await _snap("game_combat")
	await _end_combat(field._combat_ui, "win")
	await _wait(0.3)
	check(field._combat_ui == null and field._dialogue_ui == null and not field.frozen, "게임: 승리 → EXIT → 필드")
	SaveManager.delete_all()
	print("[cat_combat_smoke] 실패 %d" % _fail)
	get_tree().quit(1 if _fail > 0 else 0)


func _press(root: Node, text: String) -> void:
	for b in root.find_children("*", "Button", true, false):
		if b.text.begins_with(text) and b.is_visible_in_tree():
			b.pressed.emit()
			await _wait(0.3)
			return
	check(false, "버튼 없음: " + text)


func _end_combat(ui: Node, outcome: String) -> void:
	ui.combat.outcome = outcome
	ui._finish()
	await _wait(0.05)
	ui.get_node("%TitleButton").pressed.emit()
	await _wait(0.2)


func _wait(sec: float) -> void:
	await get_tree().create_timer(sec).timeout


func _snap(name: String) -> void:
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("user://cat_combat_smoke/%s.png" % name)


func check(ok: bool, label: String) -> void:
	print(("ok   " if ok else "FAIL ") + label)
	if not ok:
		_fail += 1
