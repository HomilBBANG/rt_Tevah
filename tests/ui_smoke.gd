extends Node
## UI 스모크 테스트: 각 화면을 띄우고 버튼을 눌러가며 스크린샷을 user://ui_smoke/ 에 저장한다.
## 화면이 필요하므로 --headless 없이 실행:
##   Godot_v4.7-stable_win64.exe --path . res://tests/ui_smoke.tscn

var _shot := 0


func _ready() -> void:
	seed(1)
	SaveManager.save_dir = "user://test_saves/"
	SaveManager.delete_all()
	DirAccess.make_dir_recursive_absolute("user://ui_smoke")

	var title := _open("res://scenes/title.tscn")
	await _snap("title")
	title.queue_free()

	var sel := _open("res://scenes/episode_select.tscn")
	await _snap("episode_select_locked")
	sel.queue_free()

	StoryRunner.prepare("ep_test1", false)
	var play := _open("res://scenes/main_play.tscn")
	await _frames(3)
	await _snap("intro")
	await _press(play, "계속")
	await _snap("node_a")
	await _press(play, "선택지 1 (일반)")
	await _press(play, "탐색 (spot_b)  [시간 -10]")
	await _snap("after_loot")
	await _press(play, "잡동사니 9개 줍기 (인벤토리 초과)")
	await _snap("inventory_full")
	await _press(play, "잡동사니(테스트) 포기")
	await _press(play, "인벤토리 (8/8)")
	await _press(play, "칼(테스트) x1")
	await _snap("inventory_browse")
	await _press(play, "닫기")
	await _press(play, "노드 A로")
	await _snap("node_a_with_knife")
	await _press(play, "선택지 4 (대가형)  [체력 -10, 시간 -10]")
	await _press(play, "정상 클리어")
	await _snap("ending")
	play.queue_free()

	sel = _open("res://scenes/episode_select.tscn")
	await _snap("episode_select_unlocked")

	SaveManager.delete_all()
	print("[ui_smoke] 스크린샷 %d장 → %s" % [_shot, ProjectSettings.globalize_path("user://ui_smoke")])
	get_tree().quit()


func _open(path: String) -> Node:
	var n: Node = load(path).instantiate()
	add_child(n)
	return n


func _press(root: Node, text: String) -> void:
	var b := _find_button(root, text)
	if b == null:
		push_error("[ui_smoke] 버튼 없음: " + text)
		print("[ui_smoke] 버튼 없음: " + text)
	elif b.disabled:
		print("[ui_smoke] 비활성 버튼: " + text)
	else:
		b.pressed.emit()
	await _frames(3)


func _find_button(root: Node, text: String) -> Button:
	for c in root.find_children("*", "Button", true, false):
		if c.text == text and c.is_visible_in_tree():
			return c
	return null


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _snap(name: String) -> void:
	await RenderingServer.frame_post_draw
	_shot += 1
	get_viewport().get_texture().get_image().save_png("user://ui_smoke/%02d_%s.png" % [_shot, name])
