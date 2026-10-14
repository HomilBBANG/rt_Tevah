@tool
extends GraphNode
## 대사 카드 하나 (대화 노드). 줄(slot) 구성:
##   0: 화자          ← 들어오는 연결점
##   1: 대사
##   2: 다음 →        → next_node (선택지가 없을 때 진행)
##   3~: 선택지 줄    → next_node, 판정(dice)·전투(combat) 선택지는 '실패/도주 →' 줄이 하나 더 (fail_next)
##   끝: + 선택지
## 연결점 번호(port)는 out_ports 순서와 같다: ["next"], ["choice", i], ["fail", i]

signal changed
signal choice_selected(card: GraphNode, index: int)
signal node_selected_for_edit(card: GraphNode)

const TYPE_LABEL := {"normal": "일반", "item": "아이템", "dice": "판정", "combat": "전투"}
const PORT_COLOR := Color("8fb8ff")
const FAIL_COLOR := Color("e46a6a")

var data := {}            # node_id, speaker_id, text, next_node, on_enter
var choices: Array = []   # 이 노드의 선택지 dict (순서 = 화면 순서)
var speakers: Array = []  # [[char_id, name], ...] — 첫 항목은 ["", "(내레이션)"]
var out_ports: Array = []


func setup(node_data: Dictionary, node_choices: Array, speaker_list: Array) -> void:
	data = node_data
	choices = node_choices
	speakers = speaker_list
	name = data.node_id
	title = data.node_id
	resizable = true
	custom_minimum_size = Vector2(420, 0)
	rebuild()


func rebuild() -> void:
	for c in get_children():
		remove_child(c)
		c.queue_free()
	out_ports = []
	# 0: 화자
	var row := HBoxContainer.new()
	var lb := Label.new()
	lb.text = "화자"
	row.add_child(lb)
	var sp := OptionButton.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for i in speakers.size():
		sp.add_item(speakers[i][1], i)
		if speakers[i][0] == data.get("speaker_id", ""):
			sp.select(i)
	sp.item_selected.connect(func(i):
		data.speaker_id = speakers[i][0]
		changed.emit())
	row.add_child(sp)
	var edit_btn := Button.new()
	edit_btn.text = "⋯"
	edit_btn.tooltip_text = "노드 세부 (ID·들어올 때 효과·직접 입력 이동)"
	edit_btn.pressed.connect(func(): node_selected_for_edit.emit(self))
	row.add_child(edit_btn)
	_add_row(row, true, false)
	# 1: 대사
	var te := TextEdit.new()
	te.text = data.get("text", "")
	te.custom_minimum_size = Vector2(380, 90)
	te.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	te.placeholder_text = "대사 / 상황 묘사"
	te.text_changed.connect(func():
		data.text = te.text
		changed.emit())
	_add_row(te, false, false)
	# 2: 다음 →
	var nx := Label.new()
	nx.text = "다음 →  " + _target_hint(data.get("next_node", ""))
	nx.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	nx.tooltip_text = "선택지가 없을 때 이어지는 곳"
	_add_row(nx, false, true, PORT_COLOR)
	out_ports.append(["next", -1])
	# 선택지
	for i in choices.size():
		var c: Dictionary = choices[i]
		var cr := HBoxContainer.new()
		var badge := Label.new()
		badge.text = "[%s]" % TYPE_LABEL.get(c.get("type", "normal"), "일반")
		cr.add_child(badge)
		var le := LineEdit.new()
		le.text = c.get("text", "")
		le.placeholder_text = "선택지 문구"
		le.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		le.text_changed.connect(func(t):
			c.text = t
			changed.emit())
		le.focus_entered.connect(func(): choice_selected.emit(self, i))
		cr.add_child(le)
		var more := Button.new()
		more.text = "⋯"
		more.tooltip_text = "선택지 세부 (조건·효과·판정)"
		more.pressed.connect(func(): choice_selected.emit(self, i))
		cr.add_child(more)
		var del := Button.new()
		del.text = "✕"
		del.tooltip_text = "선택지 삭제"
		del.pressed.connect(func():
			choices.remove_at(i)
			rebuild()
			changed.emit())
		cr.add_child(del)
		_add_row(cr, false, true, PORT_COLOR)
		out_ports.append(["choice", i])
		if c.get("type", "normal") in ["dice", "combat"]:
			var fl := Label.new()
			fl.text = ("판정 실패 →  " if c.type == "dice" else "도주 →  ") + _target_hint(c.get("fail_next", ""))
			fl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
			fl.add_theme_color_override("font_color", FAIL_COLOR)
			_add_row(fl, false, true, FAIL_COLOR)
			out_ports.append(["fail", i])
	# + 선택지
	var add := Button.new()
	add.text = "+ 선택지"
	add.pressed.connect(func(): add_choice.call_deferred())
	_add_row(add, false, false)


## 선택지 추가 (ID 는 편집기가 정해 준다 → choice_id_maker)
var choice_id_maker: Callable

func add_choice() -> void:
	var cid: String = choice_id_maker.call() if choice_id_maker.is_valid() else "%s_c%d" % [data.node_id, choices.size() + 1]
	choices.append({"choice_id": cid, "node_id": data.node_id, "text": "", "condition": "", "show_mode": "", "cost": "",
		"effects": "", "next_node": "", "type": "normal", "check": "", "dc": 0, "mod": 0, "fail_effects": "", "fail_next": ""})
	rebuild()
	changed.emit()


## 연결점 번호 → 데이터 필드의 [dict, 키]
func port_target(port: int) -> Array:
	var p: Array = out_ports[port]
	match p[0]:
		"next": return [data, "next_node"]
		"choice": return [choices[p[1]], "next_node"]
		_: return [choices[p[1]], "fail_next"]


func _add_row(ctrl: Control, left: bool, right: bool, right_color := PORT_COLOR) -> void:
	add_child(ctrl)
	set_slot(get_child_count() - 1, left, 0, PORT_COLOR, right, 0, right_color)


## 연결선이 없을 때(다른 파일·엑셀 노드로 가는 경우) 보여줄 글자
func _target_hint(t: String) -> String:
	return "" if t == "" else "(%s)" % t
