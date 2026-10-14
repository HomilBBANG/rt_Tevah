extends Control
## 전투 화면. 규칙은 core/combat/combat.gd, 여기서는 입력·타이밍 측정·그리기만.
##
## 배치: 왼쪽 위 적 이름 / 가운데 적 그림 / 왼쪽 아래 내 상태(부위 HP) / 가운데 아래 텍스트 창 / 그 오른쪽 행동 버튼
## 텍스트 창: 시스템 메시지 + 행동 세부 선택지(공격할 부위 등)
## 플레이어 턴: 공격(텍스트 창에서 적 부위 선택) / 특수(스킬·무기 던지기 등, 아직 없음) / 아이템(인벤토리, 소모품 사용)
##   / 도주(주사위 1~100 ≤ 적의 도주 성공률)
## 적 턴: 공격 전조 → 회피 원이 고리에 닿는 순간 맞는 방향키(W/A/S/D 또는 방향키·패드) 입력

const Combat = preload("res://core/combat/combat.gd")
const InputActions = preload("res://core/input_actions.gd")

## 탐험 필드 안에서 띄웠을 때: 끝나면 결과("win"/"lose"/"fled")를 알린다
signal finished(outcome: String)

## 회피 입력 액션 → 키 글자 (기획서 §8.1)
const DODGE_ACTIONS := {"dodge_up": "W", "dodge_left": "A", "dodge_down": "S", "dodge_right": "D"}
const RESULT_TEXT := {"perfect": "완벽 회피!", "normal": "회피"}
const TURN_PAUSE := 0.6
const FLEE_ROLL_TIME := 0.7
const LOG_LINES := 3
const DODGE_HINT := "[color=#999999][font_size=24]회피:  W 머리  ·  A 왼팔/왼다리  ·  S 몸통  ·  D 오른팔/오른다리[/font_size][/color]"

## 다음에 싸울 적 (비어 있으면 첫 번째 적)
static var next_enemy_id := ""

var combat := Combat.new()
## 필드에서 띄울 때 add_child 전에 채운다
var embedded := false
var enemy_id_override := ""
var player_state := {}
var _state := ""              # player / target / special / item / rolling / enemy / over
var _log: PackedStringArray = []
var _prompt := ""             # 텍스트 창 마지막 줄 (안내·주사위 등)
var _intro := ""              # "적 이(가) 나타났다." — 첫 행동 결과가 나오기 전까지만 보임 (로그에 남기지 않음)
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
	%EnemyFigure.set_image(combat.enemy.image)
	%PlayerBody.figure = true
	%PlayerBody.parts = combat.player_parts
	%PlayerBody.order = combat.player_order
	%PlayerBody.mouse_filter = Control.MOUSE_FILTER_IGNORE
	%AttackButton.pressed.connect(_on_attack)
	%SpecialButton.pressed.connect(_on_special)
	%ItemButton.pressed.connect(_on_item)
	%FleeButton.pressed.connect(_on_flee)
	%Inventory.use_handler = _on_item_used
	%Inventory.allow_equip = false   # TODO(기획): 전투 중 장비 바꾸기 — 지금은 소모품 사용만
	%Inventory.visibility_changed.connect(func():
		if not %Inventory.visible and _state == "item":
			_player_turn())
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
	_intro = "%s 이(가) 나타났다." % combat.enemy.name
	_player_turn()


# ---------------------------------------------------------------- 플레이어 턴
func _player_turn() -> void:
	_state = "player"
	%PlayerBody.set_highlight("")
	_clear_options()
	_set_actions(true)
	_set_prompt("행동을 고르세요.")


func _set_actions(on: bool) -> void:
	%AttackButton.disabled = not on or not combat.can_attack()
	%SpecialButton.disabled = not on
	%ItemButton.disabled = not on
	%FleeButton.disabled = not on or not combat.can_flee()


## 공격 → 텍스트 창에 적 부위 선택지
func _on_attack() -> void:
	if _state != "player":
		return
	_state = "target"
	_set_actions(false)
	_set_prompt("노릴 부위를 고르세요.")
	_clear_options()
	for id in combat.enemy_order:
		var p: Dictionary = combat.enemy_parts[id]
		var b := _option_button("%s  %d/%d  ·  명중 %d%%" % [p.name, p.hp, p.max_hp, roundi(p.hit_chance)] if not p.broken
			else "%s  파괴" % p.name)
		b.disabled = p.broken
		b.pressed.connect(_on_target_chosen.bind(id))
	_option_button("취소").pressed.connect(_player_turn)
	%Options.visible = true


func _on_target_chosen(part_id: String) -> void:
	if _state != "target":
		return
	var res := combat.player_attack(part_id)
	if res.is_empty():
		return
	_clear_options()
	var part_name: String = combat.enemy_parts[part_id].name
	if not res.hit:
		_add_log("%s 을(를) 노렸지만 빗나갔다." % part_name)
	else:
		%EnemyFigure.flash()
		if res.killed:
			_add_log("%s 파괴! %s 쓰러졌다." % [part_name, combat.enemy.name])
		elif res.broken:
			_add_log("%s 파괴! (-%d)" % [part_name, res.damage])
		else:
			_add_log("%s 명중 (-%d)" % [part_name, res.damage])
	await _after_player_action()


## 특수 → 텍스트 창에 특수 행동 목록 (스킬 사용·무기 던지기 등)
## TODO(기획): 특수 행동 데이터(스킬 시트, 신성력 소모, 던질 수 있는 무기)가 정해지면 목록을 채운다. 지금은 비어 있음
func _on_special() -> void:
	if _state != "player":
		return
	_state = "special"
	_set_actions(false)
	_clear_options()
	_set_prompt("아직 쓸 수 있는 특수 행동이 없다.")
	_option_button("취소").pressed.connect(_player_turn)
	%Options.visible = true


## 아이템 → 인벤토리 (소모품 사용). TODO(기획): 장비 착용 — 장비 시스템이 아직 없음
func _on_item() -> void:
	if _state != "player":
		return
	_state = "item"
	_set_actions(false)
	_set_prompt("사용할 아이템을 고르세요.")
	%Inventory.open_browse()


func _on_item_used(slot: int) -> void:
	if _state != "item":
		return
	_state = "using"
	%Inventory.hide()
	combat.player_use_item()
	# 효과(restore: 등)가 전투 중 몸 상태에 바로 닿도록 GameState 와 같은 사전을 쓴다
	var prev_body: Dictionary = GameState.player_body
	GameState.player_body = combat.player_parts
	StoryRunner.message.connect(_add_log)
	var used: bool = await StoryRunner.use_item_in_combat(slot)
	StoryRunner.message.disconnect(_add_log)
	if not embedded:
		GameState.player_body = prev_body
	%PlayerBody.refresh()
	if not used:
		_player_turn()
	elif Combat.item_uses_turn():
		await _after_player_action()
	else:
		_player_turn()


## 도주 → 주사위 굴림 연출 후 성공/실패
func _on_flee() -> void:
	if _state != "player":
		return
	_state = "rolling"
	_set_actions(false)
	var chance := roundi(combat.flee_chance())
	var t := 0.0
	while t < FLEE_ROLL_TIME:
		_set_prompt("도주 시도…  주사위 [font_size=40]%d[/font_size]  (%d 이하면 성공)" % [randi_range(1, 100), chance])
		await get_tree().create_timer(0.05).timeout
		t += 0.05
	var ok := combat.player_flee()
	var roll: int = combat.last_flee.get("roll", 0)
	_add_log("주사위 %d / %d 이하 → %s" % [roll, chance, "도주 성공!" if ok else "도주 실패!"])
	await _after_player_action()


func _after_player_action() -> void:
	_state = "enemy"
	_clear_options()
	_set_actions(false)
	_set_prompt("")
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
		_set_prompt("[color=#ffb070]%s 의 %s![/color]\n%s" % [combat.enemy.name, attack.name, DODGE_HINT])
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
	_clear_options()
	_set_actions(false)
	match combat.outcome:
		"win": _set_prompt("[b]승리[/b]")
		"lose": _set_prompt("[b][color=#e46a6a]사망[/color][/b]")
		"fled": _set_prompt("[b]도주 성공[/b]")
	%EndButtons.visible = true


# ---------------------------------------------------------------- 텍스트 창
func _add_log(line: String) -> void:
	_intro = ""
	_log.append(line)
	if _log.size() > LOG_LINES:
		_log = _log.slice(_log.size() - LOG_LINES)
	_redraw_text()


func _set_prompt(text: String) -> void:
	_prompt = text
	_redraw_text()


## 지난 메시지는 흐리게, 가장 최근 메시지는 하얗게, 그 아래 안내(_prompt)
func _redraw_text() -> void:
	var lines := PackedStringArray()
	# 텍스트 창은 4줄 남짓: 선택지·결과 버튼이 뜨면 최근 메시지 하나만, 안내가 길면 그만큼 덜
	var keep := LOG_LINES
	if _state in ["target", "special", "over"]:
		keep = 1
	elif _prompt != "":
		keep = clampi(4 - _prompt.count("\n") - 1, 1, LOG_LINES)
	var shown := _log.slice(maxi(0, _log.size() - keep))
	if shown.is_empty() and _intro != "":
		shown = PackedStringArray([_intro])
	for i in shown.size():
		var col := "#ffffff" if i == shown.size() - 1 and _prompt == "" else "#b8a8a8"
		lines.append("[color=%s]%s[/color]" % [col, shown[i]])
	if _prompt != "":
		lines.append(_prompt)
	%Message.text = "[center]%s[/center]" % "\n".join(lines)


func _clear_options() -> void:
	for c in %Options.get_children():
		%Options.remove_child(c)
		c.queue_free()
	%Options.visible = false


## 행동 버튼과 같은 모양의 선택지 버튼
func _option_button(text: String) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(0, 46)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.add_theme_font_size_override("font_size", 24)
	for s in ["normal", "hover", "pressed", "disabled", "focus"]:
		b.add_theme_stylebox_override(s, %AttackButton.get_theme_stylebox(s))
	%Options.add_child(b)
	return b
