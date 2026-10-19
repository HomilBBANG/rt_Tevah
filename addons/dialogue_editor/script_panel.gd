@tool
extends VBoxContainer
## 대본 칸 (대화 에디터 아래쪽): 고른 대본 블록의 페이지를 대본처럼 위에서 아래로 쓴다.
## 페이지마다 표시 종류(상황 묘사·말풍선·시스템)·화자·속도·넘김·본문. {w=0.5} = 그 자리에서 0.5초 대기.
## 단축키 (본문에서): Ctrl+Enter = 아래에 새 페이지, Alt+↑/↓ = 페이지 옮기기, Ctrl+Shift+D = 페이지 복제.

signal changed(key: String)
## 이 페이지부터 미리보기
signal preview_requested(card: GraphNode, page: int)
## 크게 보기 (그래프 숨기기) 켜기·끄기
signal maximize_toggled(on: bool)

const ScriptPages = preload("res://core/script_pages.gd")
const SPEED_ITEMS := [["", "속도: 기본"], ["instant", "즉시"], ["slow", "느림"], ["normal", "보통"], ["fast", "빠름"], ["custom", "직접 (초당 글자)"]]

var card: GraphNode
var speakers: Array = []           # [[char_id, name]] — (내레이션) 빼고
var default_speaker := ""          # 이 대화의 NPC (첫 페이지를 새로 쓸 때 말풍선 화자)
var page_boxes: Array = []         # 페이지 편집 칸 (테스트에서 씀)
var _head: Label
var _list: VBoxContainer
var _scroll: ScrollContainer
var _max_btn: Button
var _add_btn: Button
var _focus_page := -1


func _init() -> void:
	size_flags_vertical = SIZE_EXPAND_FILL
	custom_minimum_size.y = 200
	var bar := HBoxContainer.new()
	add_child(bar)
	_head = Label.new()
	_head.size_flags_horizontal = SIZE_EXPAND_FILL
	_head.clip_text = true
	bar.add_child(_head)
	_add_btn = Button.new()
	_add_btn.text = "＋ 페이지"
	_add_btn.tooltip_text = "맨 아래에 새 페이지 (본문에서 Ctrl+Enter = 그 페이지 아래에)"
	_add_btn.pressed.connect(func(): add_page(page_boxes.size()))
	bar.add_child(_add_btn)
	_max_btn = Button.new()
	_max_btn.text = "⤢ 크게"
	_max_btn.toggle_mode = true
	_max_btn.tooltip_text = "그래프를 접고 대본만 크게 봅니다"
	_max_btn.toggled.connect(func(on):
		_max_btn.text = "⤡ 작게" if on else "⤢ 크게"
		maximize_toggled.emit(on))
	bar.add_child(_max_btn)
	_scroll = ScrollContainer.new()
	_scroll.size_flags_vertical = SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(_scroll)
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 8)
	_scroll.add_child(_list)
	edit(null)


## 대본 블록 카드를 연다 (null 이면 안내만). focus_page 가 있으면 그 페이지 본문으로 커서.
func edit(p_card: GraphNode, focus_page := -1) -> void:
	card = p_card
	_focus_page = focus_page
	_render()


func pages() -> Array:
	return card.data.pages if card != null else []


func add_page(at: int, from := {}) -> void:
	if card == null:
		return
	var p: Dictionary
	if from.is_empty():
		# 바로 위 페이지의 화자·표시를 이어받는다 (대본을 이어 쓰기 쉽게)
		var prev: Dictionary = pages()[at - 1] if at > 0 and at - 1 < pages().size() else {}
		if prev.is_empty() and default_speaker != "":
			prev = {"display": "bubble", "speaker_id": default_speaker}
		p = ScriptPages.normalize({"display": prev.get("display", "narration"), "speaker_id": prev.get("speaker_id", ""), "text": ""})
	else:
		p = from.duplicate(true)
	p.page_id = _new_page_id()
	pages().insert(at, p)
	_after_change("page_add", at)


func remove_page(i: int) -> void:
	if card == null or i < 0 or i >= pages().size():
		return
	pages().remove_at(i)
	_after_change("page_del", mini(i, pages().size() - 1))


func move_page(from: int, to: int) -> void:
	if card == null or from == to or to < 0 or to >= pages().size():
		return
	var p: Dictionary = pages()[from]
	pages().remove_at(from)
	pages().insert(to, p)
	_after_change("page_move", to)


## 자유 위치 글자: 가로·세로 위치(화면 %), 글자 크기, 정렬, 색 + 작은 화면 미리보기(누르면 그 자리로)
func _free_row(p: Dictionary, i: int) -> Control:
	var box := VBoxContainer.new()
	var row := HBoxContainer.new()
	box.add_child(row)
	var key := "page_free:%s:%d" % [card.data.node_id, i]
	var spins := {}
	for f in [["x", "가로 %", 0, 100], ["y", "세로 %", 0, 100], ["size", "크기", 8, 200]]:
		var l := Label.new()
		l.text = f[1]
		row.add_child(l)
		var sp := SpinBox.new()
		sp.min_value = f[2]
		sp.max_value = f[3]
		sp.step = 1
		sp.value = float(p.get(f[0], ScriptPages.FREE_DEFAULTS[f[0]]))
		sp.tooltip_text = "글자 묶음의 기준점: 화면 왼쪽 위 = 0, 오른쪽·아래 끝 = 100" if f[0] != "size" else "글자 크기 (px, 1920×1080 기준)"
		var k: String = f[0]
		sp.value_changed.connect(func(v):
			p[k] = int(v) if k == "size" else v
			changed.emit(key)
			_free_preview_update.call_deferred(box, p))
		row.add_child(sp)
		spins[k] = sp
	var al := OptionButton.new()
	for a in [["left", "왼쪽 맞춤 (기준점부터 →)"], ["center", "가운데"], ["right", "오른쪽 맞춤 (← 기준점까지)"]]:
		al.add_item(a[1])
		if a[0] == str(p.get("align", "center")):
			al.select(al.item_count - 1)
	al.item_selected.connect(func(ai):
		p.align = ScriptPages.ALIGNS[ai]
		changed.emit(key)
		_free_preview_update.call_deferred(box, p))
	row.add_child(al)
	var cp := ColorPickerButton.new()
	cp.color = Color.html(str(p.get("color", "#FFFFFF"))) if Color.html_is_valid(str(p.get("color", ""))) else Color.WHITE
	cp.edit_alpha = false
	cp.custom_minimum_size = Vector2(48, 28)
	cp.tooltip_text = "글자 색"
	cp.color_changed.connect(func(c):
		p.color = "#" + c.to_html(false).to_upper()
		changed.emit(key)
		_free_preview_update.call_deferred(box, p))
	row.add_child(cp)
	# 미리보기: 16:9 작은 화면, 누르면 그 자리가 기준점
	var pv := ColorRect.new()
	pv.name = "FreePreview"
	pv.color = Color(0.05, 0.05, 0.07)
	pv.custom_minimum_size = Vector2(256, 144)
	pv.size_flags_horizontal = SIZE_SHRINK_BEGIN
	pv.tooltip_text = "누르면 그 자리로 옮김 (화면 1920×1080 을 줄인 모습)"
	pv.gui_input.connect(func(ev):
		if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
			spins.x.value = roundf(clampf(ev.position.x / pv.size.x, 0, 1) * 100.0)
			spins.y.value = roundf(clampf(ev.position.y / pv.size.y, 0, 1) * 100.0))
	var t := Label.new()
	t.name = "T"
	t.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pv.add_child(t)
	var dot := ColorRect.new()
	dot.name = "Dot"
	dot.color = Color("c58cff")
	dot.size = Vector2(5, 5)
	dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pv.add_child(dot)
	box.add_child(pv)
	_free_preview_update.call_deferred(box, p)
	return box


func _free_preview_update(box: Control, p: Dictionary) -> void:
	var pv: Control = box.get_node_or_null("FreePreview")
	if pv == null:
		return
	var k := pv.custom_minimum_size.x / 1920.0
	var t: Label = pv.get_node("T")
	t.text = ScriptPages.parse_text(str(p.get("text", ""))).text
	t.add_theme_font_size_override("font_size", maxi(4, int(float(p.get("size", 38)) * k)))
	var c := str(p.get("color", "#FFFFFF"))
	t.add_theme_color_override("font_color", Color.html(c) if Color.html_is_valid(c) else Color.WHITE)
	var al := str(p.get("align", "center"))
	t.horizontal_alignment = {"left": HORIZONTAL_ALIGNMENT_LEFT, "right": HORIZONTAL_ALIGNMENT_RIGHT}.get(al, HORIZONTAL_ALIGNMENT_CENTER)
	t.reset_size()
	var at := Vector2(float(p.get("x", 50)) / 100.0, float(p.get("y", 50)) / 100.0) * pv.custom_minimum_size
	var px := at.x - (t.size.x / 2.0 if al == "center" else (t.size.x if al == "right" else 0.0))
	t.position = Vector2(px, at.y - t.size.y / 2.0)
	pv.get_node("Dot").position = at - Vector2(2, 2)


func _after_change(key: String, focus := -1) -> void:
	card.rebuild()
	changed.emit(key + ":" + card.data.node_id)
	edit(card, focus)


func _new_page_id() -> String:
	var used := {}
	for p in pages():
		used[p.page_id] = true
	var i := 1
	while used.has("p%d" % i):
		i += 1
	return "p%d" % i


# ---------------------------------------------------------------- 그리기
func _render() -> void:
	for c in _list.get_children():
		_list.remove_child(c)
		c.queue_free()
	page_boxes = []
	_add_btn.disabled = card == null
	if card == null:
		_head.text = "대본"
		var l := Label.new()
		l.text = "그래프에서 대본 블록 카드를 고르면 여기서 대사를 씁니다.\n한 블록에 여러 페이지(상황 묘사 → 말풍선 → 시스템 메시지 …)를 이어 쓸 수 있습니다."
		l.modulate = Color(1, 1, 1, 0.55)
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_list.add_child(l)
		return
	_head.text = "대본 블록: %s   (%d페이지)" % [card.data.node_id, pages().size()]
	for i in pages().size():
		var box := _page_box(i)
		_list.add_child(box)
		page_boxes.append(box)
	if _focus_page >= 0 and _focus_page < page_boxes.size():
		var target: Control = page_boxes[_focus_page]
		var te: TextEdit = target.get_meta("text_edit")
		(func():
			# 그사이 다시 그려졌으면(빠른 연속 편집) 건너뜀
			if is_instance_valid(te) and te.is_inside_tree():
				te.grab_focus()
				_scroll.ensure_control_visible(target)).call_deferred()


func _page_box(i: int) -> Control:
	var p: Dictionary = pages()[i]
	var panel := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.16, 0.18, 0.22)
	sb.border_color = {"narration": Color("c9c9c9"), "bubble": Color("8fb8ff"), "system": Color("7a7a7a"), "subtitle": Color("ffd27a"), "free": Color("c58cff")}[p.display]
	sb.border_width_left = 4
	sb.set_corner_radius_all(4)
	sb.set_content_margin_all(8)
	panel.add_theme_stylebox_override("panel", sb)
	panel.set_drag_forwarding(Callable(), _can_drop.bind(i), _drop.bind(i))
	var vb := VBoxContainer.new()
	panel.add_child(vb)
	var row := HBoxContainer.new()
	vb.add_child(row)
	# 끌어서 순서 바꾸기
	var handle := Label.new()
	handle.text = "≡ %d" % (i + 1)
	handle.tooltip_text = "끌어서 순서 바꾸기"
	handle.mouse_filter = Control.MOUSE_FILTER_STOP
	handle.mouse_default_cursor_shape = Control.CURSOR_MOVE
	handle.set_drag_forwarding(_drag.bind(i), Callable(), Callable())
	row.add_child(handle)
	# 표시 종류
	var disp := OptionButton.new()
	for d in ScriptPages.DISPLAYS:
		disp.add_item(ScriptPages.DISPLAY_LABEL[d])
	disp.select(ScriptPages.DISPLAYS.find(p.display))
	disp.tooltip_text = "상황 묘사 = 밝은 상자 / 말풍선 = 화자의 대사 / 시스템 메시지 = 검은 상자 / 자막 = 상자 없이 화면 아래 글자만 (인트로·영상 자막) / 자유 위치 글자 = 상자 없이 화면 아무 곳에 (위치·크기·정렬·색)"
	disp.item_selected.connect(func(k):
		p.display = ScriptPages.DISPLAYS[k]
		if p.display == "bubble" and p.speaker_id == "" and not speakers.is_empty():
			p.speaker_id = speakers[0][0]
		elif not p.display in ScriptPages.WITH_SPEAKER:
			p.speaker_id = ""
		if p.display == "free":
			for fk in ScriptPages.FREE_DEFAULTS:
				if not p.has(fk):
					p[fk] = ScriptPages.FREE_DEFAULTS[fk]
		_after_change("page_display", i))
	row.add_child(disp)
	# 화자 (말풍선일 때만)
	if p.display in ScriptPages.WITH_SPEAKER:
		var sp := OptionButton.new()
		sp.fit_to_longest_item = false
		sp.custom_minimum_size.x = 170
		sp.clip_text = true
		var found := false
		# 자막은 화자 없이도 (이름 없이 글자만)
		var people: Array = ([["", "(화자 없음)"]] if p.display == "subtitle" else []) + speakers
		for k in people.size():
			sp.add_item(people[k][1])
			if people[k][0] == p.speaker_id:
				sp.select(k)
				found = true
		if not found:
			sp.add_item("(화자 고르기)" if p.speaker_id == "" else p.speaker_id + " (없음)")
			sp.select(sp.item_count - 1)
		sp.item_selected.connect(func(k):
			if k < people.size():
				p.speaker_id = people[k][0]
				_after_change("page_speaker", i))
		row.add_child(sp)
	# 속도
	var speed := OptionButton.new()
	var sel := 5
	for k in SPEED_ITEMS.size():
		speed.add_item(SPEED_ITEMS[k][1])
		if SPEED_ITEMS[k][0] == p.speed:
			sel = k
	speed.select(sel)
	speed.tooltip_text = "글자가 나오는 속도. 기본 = 대화 파일 설정 → 엑셀 Config text_speed_default"
	row.add_child(speed)
	var cps := SpinBox.new()
	cps.min_value = 1
	cps.max_value = 200
	cps.suffix = "자/초"
	cps.value = p.speed.to_float() if p.speed.is_valid_float() else 35
	cps.visible = sel == 5
	cps.value_changed.connect(func(v):
		p.speed = str(int(v))
		changed.emit("page_cps:%s:%d" % [card.data.node_id, i]))
	row.add_child(cps)
	speed.item_selected.connect(func(k):
		p.speed = str(int(cps.value)) if SPEED_ITEMS[k][0] == "custom" else SPEED_ITEMS[k][0]
		_after_change("page_speed", i))
	# 넘김
	var adv := OptionButton.new()
	adv.add_item("입력 대기")
	adv.add_item("자동 넘김")
	adv.select(1 if p.advance == "auto" else 0)
	adv.tooltip_text = "입력 대기 = 플레이어가 누를 때까지 / 자동 넘김 = 다 나오고 몇 초 뒤 다음 페이지"
	row.add_child(adv)
	var wait := SpinBox.new()
	wait.min_value = 0
	wait.max_value = 30
	wait.step = 0.1
	wait.suffix = "초"
	wait.value = p.auto_wait
	wait.visible = p.advance == "auto"
	wait.value_changed.connect(func(v):
		p.auto_wait = v
		changed.emit("page_wait:%s:%d" % [card.data.node_id, i]))
	row.add_child(wait)
	adv.item_selected.connect(func(k):
		p.advance = "auto" if k == 1 else "input"
		_after_change("page_advance", i))
	var gap := Control.new()
	gap.size_flags_horizontal = SIZE_EXPAND_FILL
	row.add_child(gap)
	var free_box: Control = null
	if p.display == "free":
		free_box = _free_row(p, i)
		vb.add_child(free_box)
	# 본문
	var te := TextEdit.new()
	te.text = p.text
	te.placeholder_text = "본문 (빈 줄 = 문단, 줄바꿈 = 강제 줄바꿈, 긴 줄은 자동 줄바꿈)"
	te.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	te.scroll_fit_content_height = true
	te.custom_minimum_size.y = 70
	te.syntax_highlighter = _highlighter()
	panel.set_meta("text_edit", te)
	var warn := Label.new()
	warn.add_theme_color_override("font_color", Color("ffb454"))
	warn.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	var show_warn := func():
		var w := ScriptPages.problems(p)
		warn.text = "⚠ " + " · ".join(w) if not w.is_empty() else ""
		warn.visible = not w.is_empty()
	show_warn.call()
	te.text_changed.connect(func():
		p.text = te.text
		if free_box != null:
			_free_preview_update(free_box, p)
		show_warn.call()
		card.rebuild()
		changed.emit("page_text:%s:%d" % [card.data.node_id, i]))
	te.gui_input.connect(_page_keys.bind(i, te))
	# 페이지 버튼
	for b in [["⏸ 대기", "커서 자리에 멈춤 표시 {w=0.5} 넣기 (숫자 = 초)", func(): _insert_pause(te)],
			["▶", "이 페이지부터 미리보기", func(): preview_requested.emit(card, i)],
			["⧉", "페이지 복제 (Ctrl+Shift+D)", func(): add_page(i + 1, p)],
			["↑", "위로 (Alt+↑)", func(): move_page(i, i - 1)],
			["↓", "아래로 (Alt+↓)", func(): move_page(i, i + 1)],
			["✕", "페이지 삭제", func(): remove_page(i)]]:
		var btn := Button.new()
		btn.text = b[0]
		btn.tooltip_text = b[1]
		btn.flat = true
		btn.pressed.connect(b[2])
		row.add_child(btn)
	vb.add_child(te)
	vb.add_child(warn)
	return panel


## {w=…} 대기 표시를 눈에 띄게 (태그를 외우지 않아도 버튼으로 넣고, 색으로 보인다)
func _highlighter() -> CodeHighlighter:
	var h := CodeHighlighter.new()
	h.add_color_region("{", "}", Color("ffb454"))
	h.number_color = Color(0.9, 0.9, 0.9)
	h.symbol_color = Color(0.9, 0.9, 0.9)
	h.function_color = Color(0.9, 0.9, 0.9)
	h.member_variable_color = Color(0.9, 0.9, 0.9)
	return h


func _insert_pause(te: TextEdit) -> void:
	te.insert_text_at_caret("{w=0.5}")
	te.grab_focus()


func _page_keys(e: InputEvent, i: int, te: TextEdit) -> void:
	if not (e is InputEventKey and e.pressed):
		return
	if e.keycode == KEY_ENTER and e.ctrl_pressed:
		add_page(i + 1)
	elif e.keycode == KEY_UP and e.alt_pressed:
		move_page(i, i - 1)
	elif e.keycode == KEY_DOWN and e.alt_pressed:
		move_page(i, i + 1)
	elif e.keycode == KEY_D and e.ctrl_pressed and e.shift_pressed:
		add_page(i + 1, pages()[i])
	else:
		return
	te.accept_event()


# ---------------------------------------------------------------- 끌어서 순서 바꾸기
func _drag(_pos: Vector2, i: int) -> Variant:
	var l := Label.new()
	l.text = "페이지 %d 옮기는 중" % (i + 1)
	set_drag_preview(l)
	return {"script_page": i, "card": card}


func _can_drop(_pos: Vector2, d: Variant, _i: int) -> bool:
	return d is Dictionary and d.has("script_page") and d.card == card


func _drop(_pos: Vector2, d: Variant, i: int) -> void:
	move_page(d.script_page, i)
