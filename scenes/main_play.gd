extends Control
## 플레이 화면. 게임 로직 없음: StoryRunner·GameState 시그널을 그리고 입력만 돌려준다.
##
## 한 번의 행동 결과를 "페이지" 순서로 보여준다 (클릭/Space 로 넘김):
##   system    — 획득·버림 등 시스템 메시지 (검은 상자, 가운데 정렬)
##   situation — 화자 없는 노드 (밝은 상자)
##   dialogue  — 화자 있는 노드 (초상화 + 말풍선, 직전 대사는 회색으로 위에)
## 마지막 페이지에서 선택지를 띄우고, 선택지 없는 노드면 다음 클릭에 continue_story().

const ChoiceButton = preload("res://ui/choice_button.gd")

# 말풍선 위치 (기획서 3~4페이지 기준, 화면 비율). 꼬리 방향에 따라 좌우로 약간 이동.
const BUBBLE_X := {"left": [0.266, 0.676], "right": [0.287, 0.697]}
const BUBBLE_Y := [0.68, 0.83]
const PREV_BUBBLE_Y := [0.485, 0.635]

var _pages: Array = []          # [{kind, text, speaker_id}]
var _page_i := -1
var _choices: Array = []
var _pending_msgs: PackedStringArray = []
var _ended := false
var _cur_line := {}             # 지금 말풍선의 대사 {text, speaker_id, side}
var _prev_line := {}            # 직전 대사 (회색)
var _right_char := ""           # 오른쪽 초상화에 서 있는 캐릭터


func _ready() -> void:
	StoryRunner.node_shown.connect(_on_node_shown)
	StoryRunner.choices_shown.connect(_on_choices_shown)
	StoryRunner.message.connect(func(t): _pending_msgs.append(t))
	StoryRunner.messages_cleared.connect(func(): _pending_msgs.clear())
	StoryRunner.ending_reached.connect(_on_ending)
	StoryRunner.inventory_full.connect(%Inventory.open_discard)
	GameState.stats_changed.connect(_update_status)
	GameState.inventory_changed.connect(_update_status)
	%InventoryButton.pressed.connect(%Inventory.open_browse)
	%MenuButton.pressed.connect(func(): get_tree().change_scene_to_file("res://scenes/episode_select.tscn"))
	%ClickCatcher.gui_input.connect(func(e):
		if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
			advance())
	_update_status()
	StoryRunner.launch()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_accept") and not %Inventory.visible:
		advance()
		get_viewport().set_input_as_handled()


## 다음 페이지로. 마지막 페이지이고 선택지 없는 노드면 스토리를 진행.
func advance() -> void:
	if StoryRunner.busy or %Choices.get_child_count() > 0:
		return
	if _page_i < _pages.size() - 1:
		_next_page()
	elif not _ended and _choices.is_empty():
		StoryRunner.continue_story()


func _next_page() -> void:
	_page_i += 1
	_show_page(_pages[_page_i])


# ---------------------------------------------------------------- StoryRunner 시그널
func _on_node_shown(node: Dictionary, _speaker_name: String) -> void:
	_pages = []
	_flush_messages()
	var speaker: String = node.get("speaker_id", "")
	_pages.append({"kind": "dialogue" if speaker != "" else "situation", "text": node.get("text", ""), "speaker_id": speaker})


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


func _flush_messages() -> void:
	if not _pending_msgs.is_empty():
		_pages.append({"kind": "system", "text": "\n".join(_pending_msgs), "speaker_id": ""})
		_pending_msgs.clear()


func _start_pages() -> void:
	_clear_choices()
	_page_i = -1
	if not _pages.is_empty():
		_next_page()


# ---------------------------------------------------------------- 그리기
func _show_page(p: Dictionary) -> void:
	_clear_choices()
	%SituationBox.visible = p.kind == "situation"
	%SystemBox.visible = p.kind == "system"
	var is_dialogue: bool = p.kind == "dialogue"
	%Bubble.visible = is_dialogue
	%PrevBubble.visible = false
	%PortraitLeft.visible = is_dialogue
	%PortraitRight.visible = is_dialogue
	match p.kind:
		"situation":
			%SituationText.text = p.text
			_cur_line = {}
			_prev_line = {}
			_right_char = ""
		"system":
			%SystemText.text = p.text
		"dialogue":
			_show_dialogue(p)

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


func _show_dialogue(p: Dictionary) -> void:
	# TODO(기획 확인): 주인공은 왼쪽, 그 밖의 화자는 오른쪽에 세운다.
	var protagonist: String = DataLoader.episodes.get(GameState.episode_id, {}).get("protagonist_id", "")
	var side := "left" if p.speaker_id == protagonist else "right"
	if side == "right":
		_right_char = p.speaker_id
	var line := {"text": p.text, "speaker_id": p.speaker_id, "side": side}
	# 같은 노드를 다시 보여줄 때(아이템 사용 후 등)는 대사 기록을 밀지 않는다
	if not _cur_line.is_empty() and _cur_line != line:
		_prev_line = _cur_line
	_cur_line = line

	%PortraitLeft.show_character(DataLoader.character_name(protagonist), side == "left")
	%PortraitRight.show_character(DataLoader.character_name(_right_char), side == "right")
	_place(%Bubble, BUBBLE_X[side], BUBBLE_Y)
	%Bubble.show_line(p.text, side, false, DataLoader.character_name(p.speaker_id), DataLoader.character_color(p.speaker_id))
	if not _prev_line.is_empty():
		_place(%PrevBubble, BUBBLE_X[_prev_line.side], PREV_BUBBLE_Y)
		%PrevBubble.show_line(_prev_line.text, _prev_line.side, true,
			DataLoader.character_name(_prev_line.speaker_id), DataLoader.character_color(_prev_line.speaker_id))
		%PrevBubble.visible = true


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
