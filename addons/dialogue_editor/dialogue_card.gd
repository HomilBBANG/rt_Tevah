@tool
extends GraphNode
## 대본 블록 카드 (대화 노드). 그래프에서는 흐름만 보고, 대사는 아래 '대본' 칸에서 쓴다.
## 줄(slot) 구성:
##   0: 머리 (페이지 수·화자)  ← 들어오는 연결점
##   1: 대본 미리보기 (페이지마다 한 줄, 접으면 숨김)
##   2: 다음 →        → next_node (선택지가 없을 때 진행)
##   3~: 선택지 줄    → next_node, 판정(dice)·전투(combat) 선택지는 '실패/도주 →' 줄이 하나 더 (fail_next)
##   끝: + 선택지
## 연결점 번호(port)는 out_ports 순서와 같다: ["next"], ["choice", i], ["fail", i]

signal changed(key: String)
signal choice_selected(card: GraphNode, index: int)
signal node_selected_for_edit(card: GraphNode)
## 대본 미리보기 줄을 눌렀다 → 대본 칸에서 그 페이지 (page = -1 이면 블록 전체)
signal page_requested(card: GraphNode, page: int)

const ScriptPages = preload("res://core/script_pages.gd")
const TYPE_LABEL := {"normal": "일반", "item": "아이템", "dice": "판정", "combat": "전투"}
const DISPLAY_SHORT := {"narration": "묘사", "bubble": "", "system": "시스템", "subtitle": "자막"}
const PORT_COLOR := Color("8fb8ff")
const FAIL_COLOR := Color("e46a6a")
const WARN_COLOR := Color("ffb454")
const NUMS := ["①", "②", "③", "④", "⑤", "⑥", "⑦", "⑧", "⑨", "⑩"]

var data := {}            # node_id, pages, next_node, on_enter (+ 예전 speaker_id·text 는 저장할 때 첫 페이지로 맞춤)
var choices: Array = []   # 이 노드의 선택지 dict (순서 = 화면 순서)
var speakers: Array = []  # [[char_id, name], ...] — 첫 항목은 ["", "(내레이션)"]
var out_ports: Array = []
## 갈 곳 ID 가 있는지 (편집기가 넣어 줌). 없으면 줄에 ⚠
var target_exists: Callable
var _fold_btn: Button


func setup(node_data: Dictionary, node_choices: Array, speaker_list: Array) -> void:
	data = node_data
	choices = node_choices
	speakers = speaker_list
	if uses_pages():
		if not data.get("pages", []) is Array or data.get("pages", []).is_empty():
			data.pages = ScriptPages.pages_of(data)
		else:
			var norm := []
			for i in data.pages.size():
				norm.append(ScriptPages.normalize(data.pages[i], i))
			data.pages = norm
	name = data.node_id
	title = data.node_id
	resizable = true
	custom_minimum_size = Vector2(440, 0)
	if not uses_pages():
		rebuild()
		return
	_fold_btn = Button.new()
	_fold_btn.flat = true
	_fold_btn.focus_mode = Control.FOCUS_NONE
	_fold_btn.tooltip_text = "대본 미리보기 접기 / 펼치기"
	_fold_btn.pressed.connect(func():
		if data.get("fold", false):
			data.erase("fold")
		else:
			data.fold = true
		rebuild()
		changed.emit("fold:" + data.node_id))
	get_titlebar_hbox().add_child(_fold_btn)
	rebuild()


func rebuild() -> void:
	for c in get_children():
		remove_child(c)
		c.queue_free()
	out_ports = []
	var pages: Array = data.get("pages", [])
	var folded: bool = data.get("fold", false)
	_fold_btn.text = "▸" if folded else "▾"
	# 0: 머리
	var row := HBoxContainer.new()
	var head := Label.new()
	head.text = "📝 대본 %d페이지   %s" % [pages.size(), _speaker_summary(pages)]
	head.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.clip_text = true
	head.modulate = Color(1, 1, 1, 0.75)
	row.add_child(head)
	var warn := _page_warnings(pages)
	if warn != "":
		var w := Label.new()
		w.text = "⚠"
		w.add_theme_color_override("font_color", WARN_COLOR)
		w.tooltip_text = warn
		w.mouse_filter = Control.MOUSE_FILTER_PASS
		row.add_child(w)
	var edit_btn := Button.new()
	edit_btn.text = "⋯"
	edit_btn.tooltip_text = "블록 세부 (ID·들어올 때 효과·갈 곳)"
	edit_btn.pressed.connect(func(): node_selected_for_edit.emit(self))
	row.add_child(edit_btn)
	_add_row(row, true, false)
	# 1: 대본 미리보기 (누르면 대본 칸에서 그 페이지)
	var preview := VBoxContainer.new()
	preview.visible = not folded
	for i in pages.size():
		var b := Button.new()
		b.flat = true
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.clip_text = true
		b.text = _page_line(i, pages[i])
		b.tooltip_text = pages[i].text if pages[i].text != "" else "(비어 있음)"
		b.custom_minimum_size.x = 400
		var idx := i
		b.pressed.connect(func(): page_requested.emit(self, idx))
		preview.add_child(b)
	if pages.is_empty():
		var l := Label.new()
		l.text = "(페이지 없음 — 대본 칸에서 ＋ 페이지)"
		l.modulate = Color(1, 1, 1, 0.5)
		preview.add_child(l)
	_add_row(preview, false, false)
	# 2: 다음 →
	var nx := Label.new()
	nx.text = "다음 →  " + _target_hint(data.get("next_node", ""))
	nx.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	nx.tooltip_text = "선택지가 없을 때 이어지는 곳"
	_mark_missing(nx, data.get("next_node", ""))
	_add_row(nx, false, true, PORT_COLOR)
	out_ports.append(["next", -1])
	# 선택지: 문구 | 종류 | 조건 | 대가 | ⋯ ✕  (갈 곳 = 오른쪽 연결점)
	for i in choices.size():
		var c: Dictionary = choices[i]
		var cr := HBoxContainer.new()
		var badge := Label.new()
		badge.text = _type_badge(c)
		badge.tooltip_text = "선택지 종류"
		badge.mouse_filter = Control.MOUSE_FILTER_PASS
		cr.add_child(badge)
		var le := LineEdit.new()
		le.text = c.get("text", "")
		le.placeholder_text = "선택지 문구"
		le.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		le.text_changed.connect(func(t):
			c.text = t
			changed.emit("choice_text:" + c.choice_id))
		le.focus_entered.connect(func(): choice_selected.emit(self, i))
		cr.add_child(le)
		if c.get("condition", "") != "":
			var cond := Label.new()
			cond.text = "🔒" if c.get("show_mode", "") != "hide" else "👁"
			cond.tooltip_text = "보이는 조건: %s\n(%s)" % [c.condition, "안 맞으면 숨김" if c.get("show_mode", "") == "hide" else "안 맞으면 회색"]
			cond.mouse_filter = Control.MOUSE_FILTER_PASS
			cr.add_child(cond)
		if c.get("cost", "") != "":
			var cost := Label.new()
			cost.text = "💰" + String(c.cost).left(8)
			cost.tooltip_text = "대가 표시: " + c.cost
			cost.mouse_filter = Control.MOUSE_FILTER_PASS
			cr.add_child(cost)
		if c.get("effects", "") != "":
			var fx := Label.new()
			fx.text = "⚙"
			fx.tooltip_text = "고르면 일어나는 효과: " + c.effects
			fx.mouse_filter = Control.MOUSE_FILTER_PASS
			cr.add_child(fx)
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
			changed.emit("choice_del"))
		cr.add_child(del)
		if not _target_ok(c.get("next_node", "")):
			cr.add_child(_missing_label(c.next_node))
		_add_row(cr, false, true, PORT_COLOR)
		out_ports.append(["choice", i])
		if c.get("type", "normal") in ["dice", "combat"]:
			var fl := Label.new()
			fl.text = ("판정 실패 →  " if c.type == "dice" else "도주 →  ") + _target_hint(c.get("fail_next", ""))
			fl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
			fl.add_theme_color_override("font_color", FAIL_COLOR)
			_mark_missing(fl, c.get("fail_next", ""))
			_add_row(fl, false, true, FAIL_COLOR)
			out_ports.append(["fail", i])
	# + 선택지
	var add := Button.new()
	add.text = "+ 선택지"
	add.pressed.connect(func(): add_choice.call_deferred())
	_add_row(add, false, false)
	size = Vector2(size.x, 0)   # 접거나 줄이 줄면 높이도 줄인다


## 대본 페이지가 있는 카드인가 (기능 카드는 false)
func uses_pages() -> bool:
	return true


## 선택지 추가 (ID 는 편집기가 정해 준다 → choice_id_maker)
var choice_id_maker: Callable

func add_choice() -> void:
	var cid: String = choice_id_maker.call() if choice_id_maker.is_valid() else "%s_c%d" % [data.node_id, choices.size() + 1]
	choices.append({"choice_id": cid, "node_id": data.node_id, "text": "", "condition": "", "show_mode": "", "cost": "",
		"effects": "", "next_node": "", "type": "normal", "check": "", "dc": 0, "mod": 0, "fail_effects": "", "fail_next": ""})
	rebuild()
	changed.emit("choice_add")


## 연결점 번호 → 데이터 필드의 [dict, 키]
func port_target(port: int) -> Array:
	var p: Array = out_ports[port]
	match p[0]:
		"next": return [data, "next_node"]
		"choice": return [choices[p[1]], "next_node"]
		_: return [choices[p[1]], "fail_next"]


## 첫 페이지 글자 (목록·검색에 보일 짧은 글)
func summary() -> String:
	var pages: Array = data.get("pages", [])
	return ScriptPages.parse_text(pages[0].text).text if not pages.is_empty() else ""


func _add_row(ctrl: Control, left: bool, right: bool, right_color := PORT_COLOR) -> void:
	add_child(ctrl)
	set_slot(get_child_count() - 1, left, 0, PORT_COLOR, right, 0, right_color)


## 연결선이 없을 때(다른 파일·엑셀 노드로 가는 경우) 보여줄 글자
func _target_hint(t: String) -> String:
	return "" if t == "" else "(%s)" % t


func _target_ok(t: String) -> bool:
	return t == "" or not target_exists.is_valid() or target_exists.call(t)


func _mark_missing(l: Label, t: String) -> void:
	if not _target_ok(t):
		l.text += "  ⚠ 없는 곳"
		l.add_theme_color_override("font_color", WARN_COLOR)
		l.tooltip_text = "'%s' 노드를 찾을 수 없습니다 (지워졌거나 이름이 바뀜)" % t
		l.mouse_filter = Control.MOUSE_FILTER_PASS


func _missing_label(t: String) -> Label:
	var l := Label.new()
	l.text = "⚠"
	l.add_theme_color_override("font_color", WARN_COLOR)
	l.tooltip_text = "갈 곳 '%s' 을(를) 찾을 수 없습니다" % t
	l.mouse_filter = Control.MOUSE_FILTER_PASS
	return l


func _type_badge(c: Dictionary) -> String:
	var t: String = c.get("type", "normal")
	match t:
		"dice": return "[판정 %s DC%d]" % [c.get("check", ""), int(c.get("dc", 0))]
		"combat": return "[전투 %s]" % c.get("check", "")
	return "[%s]" % TYPE_LABEL.get(t, "일반")


func _speaker_name(id: String) -> String:
	for s in speakers:
		if s[0] == id:
			return String(s[1]).get_slice("  (", 0)
	return id


func _speaker_summary(pages: Array) -> String:
	var names := []
	for p in pages:
		var n: String = _speaker_name(p.speaker_id) if p.display == "bubble" else ""
		if n != "" and not n in names:
			names.append(n)
	return ", ".join(names)


func _page_line(i: int, p: Dictionary) -> String:
	var who: String = _speaker_name(p.speaker_id) if p.display == "bubble" else (
		"자막 " + _speaker_name(p.speaker_id) if p.display == "subtitle" and p.speaker_id != "" else DISPLAY_SHORT[p.display])
	var txt: String = ScriptPages.parse_text(p.text).text.replace("\n", " ⏎ ")
	return "%s [%s] %s" % [NUMS[i] if i < NUMS.size() else str(i + 1), who, txt if txt != "" else "(비어 있음)"]


func _page_warnings(pages: Array) -> String:
	var out := []
	for i in pages.size():
		for w in ScriptPages.problems(pages[i]):
			out.append("페이지 %d: %s" % [i + 1, w])
	return "\n".join(out)
