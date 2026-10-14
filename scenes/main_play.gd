extends Control
## 플레이 화면. 게임 로직 없음: StoryRunner·GameState 시그널을 그리고 입력만 돌려준다.
##
## 한 번의 행동 결과를 "페이지" 순서로 보여준다 (클릭/Space 로 넘김):
##   dice      — 주사위 판정 연출 (굴리는 중에 클릭하면 바로 결과)
##   system    — 획득·버림 등 시스템 메시지 (검은 상자, 가운데 정렬)
##   situation — 화자 없는 노드 (밝은 상자)
##   dialogue  — 화자 있는 노드 (초상화 + 말풍선, 직전 대사는 회색으로 위에)
##               주인공은 얼굴·이름이 나오지 않는다 (꼬리 없는 말풍선).
##               NPC는 먼저 말한 쪽이 왼쪽, 나중에 등장한 쪽이 오른쪽.
## 마지막 페이지에서 선택지를 띄우고, 선택지 없는 노드면 다음 클릭에 continue_story().
## 노드의 대본 페이지(core/script_pages.gd)는 글자가 한 자씩 나온다: 속도·{w=초} 대기·자동 넘김.
## 나오는 중에 입력 1번 = 이 페이지 전체 표시, 그다음 입력 = 다음 페이지.

const ChoiceButton = preload("res://ui/choice_button.gd")
const ScriptPages = preload("res://core/script_pages.gd")
const KIND_OF := {"narration": "situation", "bubble": "dialogue", "system": "system"}

## 탐험 필드 위에 겹쳐 띄운 NPC 대화가 끝남 (embedded 일 때만)
signal finished

# 말풍선 위치 (기획서 기준, 화면 비율). 꼬리 방향에 따라 좌우로 약간 이동. none = 주인공(꼬리 없음)
const BUBBLE_X := {"left": [0.266, 0.676], "right": [0.287, 0.697], "none": [0.287, 0.697]}
const SIDES := ["left", "right"]
const BUBBLE_Y := [0.68, 0.83]
const PREV_BUBBLE_Y := [0.485, 0.635]

## 필드에서 NPC 대화용으로 띄울 때 add_child 전에 true. 이때는 launch() 대신 필드가 start_dialogue() 를 부른다.
var embedded := false
## 처음 보여줄 노드에서 몇 번째 페이지부터 볼지 (대화 에디터 미리보기)
var start_page := 0

var _pages: Array = []          # [{kind, text, speaker_id}]
var _page_i := -1
var _choices: Array = []
var _pending_msgs: PackedStringArray = []
var _pending_dice := {}
var _ended := false
var _cur_line := {}             # 지금 말풍선의 대사 {text, speaker_id, side}
var _prev_line := {}            # 직전 대사 (회색)
var _slots := ["", ""]          # 초상화 자리 [왼쪽, 오른쪽] 에 선 NPC char_id
var _slot_spoke := [0, 0]       # 각 자리가 마지막으로 말한 순번
var _line_no := 0
var _closing := false           # 필드 대화가 끝났고 남은 페이지만 보여주는 중
var _links: Array = []          # [[signal, callable]] — 화면이 닫힐 때 끊는다
# 글자 출력 (타이핑)
var _type_label: Label          # 지금 글자가 나오는 칸 (null = 다 나옴)
var _type_shown := 0.0
var _type_total := 0
var _type_cps := 0.0
var _type_pauses: Array = []    # [[글자 위치, 초], ...] 남은 대기
var _type_wait := 0.0
var _auto_left := -1.0          # 자동 넘김까지 남은 초 (-1 = 없음)


func _ready() -> void:
	_link(StoryRunner.node_shown, _on_node_shown)
	_link(StoryRunner.choices_shown, _on_choices_shown)
	_link(StoryRunner.message, func(t): _pending_msgs.append(t))
	_link(StoryRunner.messages_cleared, func():
		_pending_msgs.clear()
		_pending_dice = {})
	_link(StoryRunner.dice_rolled, func(r): _pending_dice = r)
	_link(StoryRunner.ending_reached, _on_ending)
	_link(StoryRunner.dialogue_ended, _on_dialogue_ended)
	_link(StoryRunner.inventory_full, %Inventory.open_discard)
	_link(GameState.stats_changed, _update_status)
	_link(GameState.inventory_changed, _update_status)
	%InventoryButton.pressed.connect(%Inventory.open_browse)
	%MenuButton.pressed.connect(func(): get_tree().change_scene_to_file("res://scenes/episode_select.tscn"))
	%ClickCatcher.gui_input.connect(func(e):
		if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
			advance())
	_update_status()
	if embedded:
		# 필드 위 대화: 체력·정신력·시간 표시와 메뉴는 숨기고, 뒤의 필드가 비치게
		%Stats.visible = false
		%MenuButton.visible = false
		$Scene.color.a = 0.55
	else:
		StoryRunner.launch()


func _exit_tree() -> void:
	for l in _links:
		if l[0].is_connected(l[1]):
			l[0].disconnect(l[1])
	_links.clear()


func _link(sig: Signal, callable: Callable) -> void:
	sig.connect(callable)
	_links.append([sig, callable])


func _unhandled_input(event: InputEvent) -> void:
	var go := event.is_action_pressed("ui_accept") or (InputMap.has_action("interact") and event.is_action_pressed("interact"))
	if go and not %Inventory.visible:
		advance()
		get_viewport().set_input_as_handled()


## 다음 페이지로. 마지막 페이지이고 선택지 없는 노드면 스토리를 진행.
func advance() -> void:
	_auto_left = -1.0
	if _type_label != null:
		_finish_typing()   # 나오는 중 → 이 페이지 전체 표시
		return
	if StoryRunner.busy or %Choices.get_child_count() > 0:
		return
	if %DicePanel.is_rolling:
		%DicePanel.skip()
		return
	if _page_i < _pages.size() - 1:
		_next_page()
	elif _closing:
		finished.emit()
	elif not _ended and _choices.is_empty():
		StoryRunner.continue_story()


func _next_page() -> void:
	_page_i += 1
	_show_page(_pages[_page_i])


# ---------------------------------------------------------------- StoryRunner 시그널
func _on_node_shown(node: Dictionary, _speaker_name: String) -> void:
	_pages = []
	_flush_messages()
	for p in ScriptPages.pages_of(node):
		var parsed := ScriptPages.parse_text(p.text)
		_pages.append({"kind": KIND_OF[p.display], "text": parsed.text, "pauses": parsed.pauses, "speaker_id": p.speaker_id,
			"cps": ScriptPages.cps(p.speed, DataLoader.config, node.get("text_speed", "")),
			"advance": p.advance, "auto_wait": p.auto_wait})


func _on_choices_shown(entries: Array) -> void:
	_choices = entries
	_ended = false
	_start_pages()


func _on_ending(ending_id: String) -> void:
	_pages = []
	_flush_messages()
	# TODO(기획 확인): Endings 시트에 제목·본문이 없어 엔딩 ID만 시스템 상자로 표시한다.
	_pages.append({"kind": "system", "text": "— 엔딩: %s —" % ending_id, "speaker_id": ""})
	_choices = []
	_ended = true
	%InventoryButton.disabled = true
	_start_pages()


## 필드 대화가 EXIT 에 닿음: 남은 시스템 메시지가 있으면 보여준 뒤 닫는다
func _on_dialogue_ended() -> void:
	_pages = []
	_flush_messages()
	_choices = []
	_closing = true
	if _pages.is_empty():
		finished.emit()
	else:
		_start_pages()


func _flush_messages() -> void:
	if not _pending_dice.is_empty():
		_pages.append({"kind": "dice", "result": _pending_dice, "text": "", "speaker_id": ""})
		_pending_dice = {}
	if not _pending_msgs.is_empty():
		_pages.append({"kind": "system", "text": "\n".join(_pending_msgs), "speaker_id": ""})
		_pending_msgs.clear()


func _start_pages() -> void:
	_clear_choices()
	_page_i = clampi(start_page, 0, maxi(_pages.size() - 1, 0)) - 1
	start_page = 0
	if not _pages.is_empty():
		_next_page()


# ---------------------------------------------------------------- 그리기
func _show_page(p: Dictionary) -> void:
	_clear_choices()
	_type_label = null
	_auto_left = -1.0
	%SituationBox.visible = p.kind == "situation"
	%SystemBox.visible = p.kind == "system"
	%DicePanel.visible = p.kind == "dice"
	var is_dialogue: bool = p.kind == "dialogue"
	%Bubble.visible = is_dialogue
	%PrevBubble.visible = false
	%PortraitLeft.visible = false
	%PortraitRight.visible = false
	match p.kind:
		"situation":
			%SituationText.text = p.text
			_cur_line = {}
			_prev_line = {}
			_slots = ["", ""]
		"system":
			%SystemText.text = p.text
		"dice":
			%DicePanel.play(p.result)
		"dialogue":
			_show_dialogue(p)
	match p.kind:
		"situation": _begin_typing(%SituationText, p)
		"system": _begin_typing(%SystemText, p)
		"dialogue": _begin_typing(%Bubble.text_label(), p)
		_: _page_done()


## 글자를 한 자씩 내보내기 시작 (속도 0 = 즉시)
func _begin_typing(label: Label, p: Dictionary) -> void:
	label.visible_characters_behavior = TextServer.VC_CHARS_AFTER_SHAPING
	_type_total = label.text.length()
	_type_cps = float(p.get("cps", 0.0))
	if _type_cps <= 0.0 or _type_total == 0:
		label.visible_characters = -1
		_page_done()
		return
	_type_label = label
	_type_shown = 0.0
	_type_wait = 0.0
	_type_pauses = p.get("pauses", []).duplicate()
	label.visible_characters = 0
	%AdvanceHint.visible = false


func _process(delta: float) -> void:
	if _type_label == null:
		if _auto_left >= 0.0 and not %Inventory.visible:
			_auto_left -= delta
			if _auto_left < 0.0:
				advance()
		return
	if _type_wait > 0.0:
		_type_wait -= delta
		return
	_type_shown += _type_cps * delta
	if not _type_pauses.is_empty() and _type_shown >= _type_pauses[0][0]:
		_type_shown = _type_pauses[0][0]
		_type_wait = _type_pauses[0][1]
		_type_pauses.pop_front()
	if _type_shown >= _type_total:
		_finish_typing()
	else:
		_type_label.visible_characters = int(_type_shown)


func _finish_typing() -> void:
	if _type_label != null:
		_type_label.visible_characters = -1
		_type_label = null
	_page_done()


## 페이지가 다 나옴: 마지막 페이지면 선택지, 자동 넘김이면 타이머
func _page_done() -> void:
	var p: Dictionary = _pages[_page_i] if _page_i >= 0 and _page_i < _pages.size() else {}
	var last := _page_i == _pages.size() - 1
	if last and _ended:
		var b := ChoiceButton.new()
		b.text = "에피소드 선택으로"
		b.pressed.connect(func(): get_tree().change_scene_to_file("res://scenes/episode_select.tscn"))
		%Choices.add_child(b)
	elif last and not _choices.is_empty():
		%PrevBubble.visible = false   # 선택지와 겹치지 않도록 지나간 대사는 숨김
		for e in _choices:
			var b := ChoiceButton.new()
			b.setup(e)
			b.pressed.connect(StoryRunner.choose.bind(e.choice.choice_id))
			%Choices.add_child(b)
	%AdvanceHint.visible = %Choices.get_child_count() == 0
	if p.get("advance", "input") == "auto" and %Choices.get_child_count() == 0:
		_auto_left = float(p.get("auto_wait", 1.0))


func _show_dialogue(p: Dictionary) -> void:
	var protagonist: String = GameState.protagonist_id
	var side := "none"
	if p.speaker_id != protagonist:
		var i := _slots.find(p.speaker_id)
		if i == -1:
			i = _slots.find("")
		if i == -1:
			# TODO(기획 확인): 세 번째 NPC가 말하면 더 오래 말하지 않은 쪽 자리를 넘겨준다.
			i = 0 if _slot_spoke[0] <= _slot_spoke[1] else 1
		_slots[i] = p.speaker_id
		_line_no += 1
		_slot_spoke[i] = _line_no
		side = SIDES[i]
	var line := {"text": p.text, "speaker_id": p.speaker_id, "side": side}
	# 같은 노드를 다시 보여줄 때(아이템 사용 후 등)는 대사 기록을 밀지 않는다
	if not _cur_line.is_empty() and _cur_line != line:
		_prev_line = _cur_line
	_cur_line = line

	# 초상화: 다른 NPC가 말할 때만 회색. 주인공이 말할 때는 둘 다 그대로.
	var portraits := [%PortraitLeft, %PortraitRight]
	for j in 2:
		portraits[j].show_character(DataLoader.character_name(_slots[j]), side == "none" or side == SIDES[j])
	_show_line(%Bubble, line, BUBBLE_Y, false)
	if not _prev_line.is_empty():
		_show_line(%PrevBubble, _prev_line, PREV_BUBBLE_Y, true)
		%PrevBubble.visible = true


func _show_line(bubble: Control, line: Dictionary, y: Array, dimmed: bool) -> void:
	_place(bubble, BUBBLE_X[line.side], y)
	var is_npc: bool = line.side != "none"
	bubble.show_line(line.text, line.side, dimmed,
		DataLoader.character_name(line.speaker_id) if is_npc else "",
		DataLoader.character_color(line.speaker_id) if is_npc else "")


func _place(c: Control, x: Array, y: Array) -> void:
	c.anchor_left = x[0]
	c.anchor_right = x[1]
	c.anchor_top = y[0]
	c.anchor_bottom = y[1]
	c.offset_left = 0
	c.offset_right = 0
	c.offset_top = 0
	c.offset_bottom = 0


func _update_status() -> void:
	%Stats.text = "체력 %d/%d    정신력 %d/%d    시간 %d/%d" % [
		GameState.get_stat("hp"), GameState.stat_max("hp"),
		GameState.get_stat("sanity"), GameState.stat_max("sanity"),
		GameState.get_stat("time"), GameState.stat_max("time")]
	%InventoryButton.text = "인벤토리 (%d/%d)" % [GameState.inventory.size(), GameState.slot_count()]


func _clear_choices() -> void:
	for c in %Choices.get_children():
		%Choices.remove_child(c)
		c.queue_free()
