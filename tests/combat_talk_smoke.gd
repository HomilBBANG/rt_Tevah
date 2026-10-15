extends Node
## 전투 중 '대화' 스모크 (창 필요). 더미 몬스터 enemy_test + 대화 tools/dialogues/monster_test.json. 스크린샷 user://combat_talk_smoke/.
##   Godot_v4.7-stable_win64_console.exe --path . res://tests/combat_talk_smoke.tscn

const CombatScene = preload("res://scenes/combat.tscn")

var _fail := 0


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute("user://combat_talk_smoke")
	DataLoader.config["text_speed_default"] = "instant"
	GameState.reset_run()
	# 1) 대화로 전투 끝내기 (endcombat:win = 상대가 물러남)
	var c := await _open()
	check(c.get_node("%TalkButton").text == "대화" and not c.get_node("%TalkButton").disabled
		and GameState.combat_enemy == "enemy_test", "행동 패널에 '대화', 전투 중 상대 = enemy_test")
	await _snap("01_actions")
	c.get_node("%TalkButton").pressed.emit()
	await _wait(0.3)
	check(c.talk_ui != null and GameState.node_id == "monster_test_combat", "대화 → 전투 화면 위에 몬스터의 '전투 중' 대사")
	await _snap("02_talk")
	c.talk_ui.advance()
	await _wait(0.1)
	await StoryRunner.choose("monster_test_c1")
	await _wait(0.4)
	check(c.combat.outcome == "win" and c.talk_ui == null and GameState.combat_enemy == "", "물러가게 한다 → 대화 닫힘, 전투 승리")
	await _snap("03_ended_by_talk")
	c.queue_free()
	await _wait(0.1)
	# 2) 대화를 그만두고 계속 싸우기 → 턴을 씀 (적 차례)
	c = await _open()
	c.get_node("%TalkButton").pressed.emit()
	await _wait(0.3)
	c.talk_ui.advance()
	await _wait(0.1)
	await StoryRunner.choose("monster_test_c3")
	await _wait(0.3)
	check(c.combat.outcome == "" and c.talk_ui == null and c._state in ["enemy", "player"], "계속 싸운다 → 전투로 돌아옴 (적 차례: %s)" % c._state)
	c.queue_free()
	await _wait(0.1)
	# 3) 대화가 없는 상대 → 말이 통하지 않음 (턴 안 씀)
	var keep: String = DataLoader.npc_dialogue.get("enemy_test", "")
	DataLoader.npc_dialogue.erase("enemy_test")
	c = await _open()
	c.get_node("%TalkButton").pressed.emit()
	await _wait(0.1)
	check(c.talk_ui == null and c._state == "player" and "말이 통하지 않는다" in "".join(c._log), "대화 없는 상대 → '말이 통하지 않는다', 그대로 내 차례")
	DataLoader.npc_dialogue["enemy_test"] = keep
	c.queue_free()
	print("[combat_talk_smoke] 실패 %d" % _fail)
	get_tree().quit(1 if _fail > 0 else 0)


func _open() -> Control:
	var c: Control = CombatScene.instantiate()
	c.embedded = true
	c.enemy_id_override = "enemy_test"
	add_child(c)
	await _wait(0.2)
	return c


func _wait(sec: float) -> void:
	await get_tree().create_timer(sec).timeout


func _snap(name: String) -> void:
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("user://combat_talk_smoke/%s.png" % name)


func check(ok: bool, label: String) -> void:
	print(("ok   " if ok else "FAIL ") + label)
	if not ok:
		_fail += 1
