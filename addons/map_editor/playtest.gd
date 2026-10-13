extends Node
## 맵 에디터의 '테스트 플레이': user://map_playtest.json 의 맵에서 새 회차처럼 실행.
## 저장은 user://playtest_saves/ 에만 하므로 실제 저장 슬롯·회차 수는 건드리지 않는다.

const FieldScript = preload("res://scenes/field/field.gd")


func _ready() -> void:
	var d = JSON.parse_string(FileAccess.get_file_as_string("user://map_playtest.json")) \
		if FileAccess.file_exists("user://map_playtest.json") else null
	var map_id: String = d.get("map", "") if d is Dictionary else ""
	SaveManager.save_dir = "user://playtest_saves/"
	SaveManager.begin_run()
	if DataLoader.maps.has(map_id):
		GameState.current_map = map_id
		FieldScript.next_map_id = map_id
	get_tree().change_scene_to_file.call_deferred("res://scenes/field/field.tscn")
