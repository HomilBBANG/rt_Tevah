extends Control
## 전투 화면 (프로토타입). 규칙은 core/combat/combat.gd, 여기서는 입력·타이밍 측정·그리기만.
##
## 플레이어 턴: 공격(적 부위 클릭) / 방어 / 도주
## 적 턴: 공격 전조 → 회피 원이 고리에 닿는 순간 맞는 방향키(W/A/S/D 또는 방향키·패드) 입력

const Combat = preload("res://core/combat/combat.gd")
const InputActions = preload("res://core/input_actions.gd")

## 탐험 필드 안에서 띄웠을 때: 끝나면 결과("win"/"lose"/"fled")를 알린다
signal finished(outcome: String)

## 회피 입력 액션 → 키 글자 (기획서 §8.1)
const DODGE_ACTIONS := {"dodge_up": "W", "dodge_left": "A", "dodge_down": "S", "dodge_right": "D"}
const RESULT_TEXT := {"perfect": "완벽 회피!", "normal": "회피"}
const TURN_PAUSE := 0.6

## 다음에 싸울 적 (비어 있으면 첫 번째 적)
static var next_enemy_id := ""

var combat := Combat.new()
## 필드에서 띄울 때 add_child 전에 채운다
var embedded := false
var enemy_id_override := ""
var player_state := {}
var _state := ""              # player / target / enemy / over
var _log: PackedStringArray = []
var _strike_start := 0
var _pressed_key := ""
var _press_time := 0


func _ready() -> void:
	InputActions.ensure()
	var enemy_id: String = enemy_id_override if enemy_id_override != "" else next_enemy_id
	if enemy_id == "" and not DataLoader.enemies.is_empty():
		enemy_id = DataLoader.enemies.keys().front()
	if enemy_id == "" or not combat.setup(enemy_id, player_state):
		_add_log("[오류] 전투 데이터가 없습니다. tools/xlsx_to_json.py 를 실행했는지 확인하세요.")
		return
	%EnemyName.text = combat.enemy.name
	for d in [[%PlayerBody, combat.player_parts, combat.player_order], [%EnemyBody, combat.enemy_parts, combat.enemy_order]]:
		d[0].parts = d[1]
		d[0].order = d[2]
	%EnemyBody.part_clicked.connect(_on_target_chosen)
	%AttackButton.pressed.connect(_on_attack)
	%DefendButton.pressed.connect(_on_defend)
	%FleeButton.pressed.connect(_on_flee)
	%CancelButton.pressed.connect(_player_turn)
	if embedded:
		%RetryButton.visible = false
		%QuitButton.visible = false
		%TitleButton.text = "계속"
		%TitleButton.pressed.connect(func(): finished.emit(combat.outcome))
	else:
		%RetryButton.pressed.connect(func(): get_tree().reload_current_scene())
		%TitleButton.pressed.connect(func(): get_tree().change_scene_to_file("res://scenes/title.tscn"))
		%QuitButton.pressed.connect(func(): get_tree().change_scene_to_file("res://scenes/title.tscn"))
	%PlayerBody.refresh()
	_add_log("%s 이(가) 나타났다." % combat.enemy.name)
	_player_turn()


# ---------------------------------------------------------------- 플레이어 턴
func _player_turn() -> void:
	_state = "player"
	%EnemyBody.selectable = false
	%EnemyBody.show_hit_chance = false
	%EnemyBody.refresh()
	%PlayerBody.set_highlight("")
	%Actions.visible = true
	%CancelButton.visible = false
	%AttackButton.disabled = not combat.can_attack()
	%FleeButton.disabled = not combat.can_flee()
	%Prompt.text = "행동을 고르세요."


func _on_attack() -> void:
	if _state != "player":
		return
	_state = "target"
	%EnemyBody.selectable = true
	%EnemyBody.show_hit_chance = true
	%EnemyBody.refresh()
	%Actions.visible = false
	%CancelButton.visible = true
	%Prompt.text = "노릴 부위를 고르세요."


func _on_target_chosen(part_id: String) -> void:
	if _state != "target":
		return
	var res := combat.player_attack(part_id)
	if res.is_empty():
		return
	var part_name: String = combat.enemy_parts[part_id].name
	if not res.hit:
		_add_log("%s 을(를) 노렸지만 빗나갔다." % part_name)
	elif res.killed:
		_add_log("%s 파괴! %s 쓰러졌다." % [part_name, combat.enemy.name])
	elif res.broken:
		_add_log("%s 파괴! (-%d)" % [part_name, res.damage])
	else:
		_add_log("%s 명중 (-%d)" % [part_name, res.damage])
	%EnemyBody.refresh()
	await _after_player_action()


func _on_defend() -> void:
	if _state != "player":
		return
	combat.player_defend()
	_add_log("방어 자세를 취했다.")
	await _after_player_action()


func _on_flee() -> void:
	if _state != "player":
		return
	if combat.player_flee():
		_add_log("도망쳤다.")
	else:
		_add_log("도주 실패!")
	await _after_player_action()


func _after_player_action() -> void:
	_state = "enemy"
	%EnemyBody.selectable = false
	%EnemyBody.show_hit_chance = false
	%EnemyBody.refresh()
	%Actions.visible = false
	%CancelButton.visible = false
	if combat.outcome != "":
		_finish()
		return
	await get_tree().create_timer(TURN_PAUSE).timeout
	await _enemy_turn()


# ---------------------------------------------------------------- 적 턴
func _enemy_turn() -> void:
	var attack := combat.choose_enemy_attack()
	if attack.is_empty():
		_add_log("%s 은(는) 공격할 수 없다." % combat.enemy.name)
	else:
		%Prompt.text = "%s 의 %s!" % [combat.enemy.name, attack.name]
		for strike in attack.strikes:
			var res := await _run_strike(attack, strike)
			var part_name: String = combat.player_parts[res.part].name
			if res.judgement != Combat.DODGE_FAIL:
				%DodgeTimer.show_result(RESULT_TEXT[res.judgement], Color("7fd48a"))
				_add_log("%s — %s" % [attack.name, RESULT_TEXT[res.judgement]])
			else:
				var text := "피격! %s -%d" % [part_name, res.damage]
				if res.dead:
					text = "%s 파괴 — 사망" % part_name
				elif res.severed:
					text = "%s 절단!" % part_name
				%DodgeTimer.show_result(text, Color("e46a6a"))
				_add_log("%s — %s" % [attack.name, text])
			%PlayerBody.set_highlight("")
			%PlayerBody.refresh()
			await get_tree().create_timer(TURN_PAUSE).timeout
			if combat.outcome != "":
				break
	combat.end_enemy_turn()
	%DodgeTimer.clear()
	if combat.outcome != "":
		_finish()
	else:
		_player_turn()


## 타격 하나: 전조를 보여주며 시간을 재고, 첫 입력 하나로 판정
func _run_strike(attack: Dictionary, strike: Dictionary) -> Dictionary:
	var windup := float(attack.windup)
	var late := Combat.config_float("combat_normal_window", 0.2)
	var switch_at := windup * Combat.config_float("combat_feint_switch", 0.55)
	_pressed_key = ""
	_strike_start = Time.get_ticks_usec()
	while true:
		var t := (Time.get_ticks_usec() - _strike_start) / 1e6
		if _pressed_key != "" or t > windup + late:
			break
		var shown: String = strike.telegraph if attack.pattern == "feint" and t < switch_at else strike.target
		%PlayerBody.set_highlight(shown)
		%DodgeTimer.show_progress(t / windup, combat.player_parts[shown].name)
		await get_tree().process_frame
	var offset := (_press_time - _strike_start) / 1e6 - windup
	var judgement := Combat.judge_dodge(_pressed_key, combat.dodge_key_for(strike), offset)
	return combat.apply_strike(attack, strike, judgement)


func _unhandled_input(event: InputEvent) -> void:
	if _state != "enemy" or _pressed_key != "":
		return
	for action in DODGE_ACTIONS:
		if event.is_action_pressed(action):
			press_dodge(DODGE_ACTIONS[action])
			get_viewport().set_input_as_handled()
			return


## 회피 키 입력 (테스트에서도 호출)
func press_dodge(key: String) -> void:
	if _pressed_key == "":
		_press_time = Time.get_ticks_usec()
		_pressed_key = key


# ---------------------------------------------------------------- 끝
func _finish() -> void:
	_state = "over"
	%Actions.visible = false
	%CancelButton.visible = false
	%EndPanel.visible = true
	match combat.outcome:
		"win": %EndText.text = "승리"
		"lose": %EndText.text = "사망"
		"fled": %EndText.text = "도주 성공"
	%Prompt.text = ""


func _add_log(line: String) -> void:
	_log.append(line)
	if _log.size() > 4:
		_log = _log.slice(_log.size() - 4)
	%Log.text = "\n".join(_log)
