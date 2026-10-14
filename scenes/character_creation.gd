extends Control
## 캐릭터 생성 (완전히 새 게임에서만, 기획 tevah_character_creation_status_effects_spec_v0.1 §2).
## 특성을 고른다: 긍정 특성은 포인트 소비, 부정 특성은 포인트 획득. 남은 P = Config creation_start_points + 고른 특성 points 합.
##   왼쪽 — 긍정/부정·분류 거르기, 이름·효과 찾기 / 가운데 — 특성 목록 (못 고르면 회색 + 이유) / 오른쪽 — 자세히
##   아래 — 지금 고른 것, [초기화] [이전] [생존 시작] (남은 P 가 0 아래면 시작 못 함, 시작 전에 최종 확인)
## 사망 후 다음 회차에서는 다시 뜨지 않는다 (특성은 GameState.owned_traits 로 이어짐).

const FIELD := "res://scenes/field/field.tscn"
const TITLE := "res://scenes/title.tscn"
const POS_COLOR := Color("7fd48a")
const NEG_COLOR := Color("ff8a7a")
const DIM := Color(0.55, 0.55, 0.58)

var selected: Array = []        # 고른 trait_id (고른 순서)
var start_points := 5
var _polarity := ""             # "" 전체 / positive / negative
var _category := ""
var _focus_id := ""
var _points_label: Label
var _list: VBoxContainer
var _detail: RichTextLabel
var _picked: Label
var _start_btn: Button
var _search: LineEdit
var _rows := {}                 # trait_id -> CheckBox (테스트에서 씀)


func _ready() -> void:
	start_points = DataLoader.get_config_int("creation_start_points", 5)
	set_anchors_preset(PRESET_FULL_RECT)
	var bg := ColorRect.new()
	bg.color = Color(0.06, 0.06, 0.07)
	bg.set_anchors_preset(PRESET_FULL_RECT)
	add_child(bg)
	var root := VBoxContainer.new()
	root.set_anchors_preset(PRESET_FULL_RECT)
	root.offset_left = 60
	root.offset_right = -60
	root.offset_top = 40
	root.offset_bottom = -40
	root.add_theme_constant_override("separation", 16)
	add_child(root)
	# ---- 위: 제목 | 남은 P
	var top := HBoxContainer.new()
	root.add_child(top)
	var title := Label.new()
	title.text = "TEVAH   /   새 게임   /   생존자 생성"
	title.add_theme_font_size_override("font_size", 36)
	title.size_flags_horizontal = SIZE_EXPAND_FILL
	top.add_child(title)
	_points_label = Label.new()
	_points_label.add_theme_font_size_override("font_size", 36)
	top.add_child(_points_label)
	root.add_child(HSeparator.new())
	# ---- 가운데: 거르기 | 목록 | 자세히
	var mid := HBoxContainer.new()
	mid.size_flags_vertical = SIZE_EXPAND_FILL
	mid.add_theme_constant_override("separation", 24)
	root.add_child(mid)
	mid.add_child(_build_filters())
	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = SIZE_EXPAND_FILL
	scroll.size_flags_stretch_ratio = 1.3
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	mid.add_child(scroll)
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 4)
	scroll.add_child(_list)
	var detail_box := PanelContainer.new()
	detail_box.size_flags_horizontal = SIZE_EXPAND_FILL
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.1, 0.1, 0.12)
	sb.set_content_margin_all(20)
	detail_box.add_theme_stylebox_override("panel", sb)
	mid.add_child(detail_box)
	_detail = RichTextLabel.new()
	_detail.bbcode_enabled = true
	_detail.fit_content = true
	detail_box.add_child(_detail)
	root.add_child(HSeparator.new())
	# ---- 아래: 고른 것 | 버튼
	_picked = Label.new()
	_picked.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(_picked)
	var bottom := HBoxContainer.new()
	bottom.add_theme_constant_override("separation", 16)
	root.add_child(bottom)
	var reset := Button.new()
	reset.text = "초기화"
	reset.pressed.connect(func():
		selected.clear()
		refresh())
	bottom.add_child(reset)
	var gap := Control.new()
	gap.size_flags_horizontal = SIZE_EXPAND_FILL
	bottom.add_child(gap)
	var back := Button.new()
	back.text = "이전"
	back.pressed.connect(func(): get_tree().change_scene_to_file(TITLE))
	bottom.add_child(back)
	_start_btn = Button.new()
	_start_btn.text = "생존 시작"
	_start_btn.pressed.connect(_confirm)
	bottom.add_child(_start_btn)
	refresh()


func _build_filters() -> Control:
	var vb := VBoxContainer.new()
	vb.custom_minimum_size.x = 300
	vb.add_theme_constant_override("separation", 8)
	_search = LineEdit.new()
	_search.placeholder_text = "이름·효과 찾기"
	_search.clear_button_enabled = true
	_search.text_changed.connect(func(_t): refresh())
	vb.add_child(_search)
	var group := ButtonGroup.new()
	for p in [["", "전체"], ["positive", "긍정적 특성 (P 소비)"], ["negative", "부정적 특성 (P 획득)"]]:
		vb.add_child(_filter_btn(p[1], group, p[0] == "", func():
			_polarity = p[0]
			refresh()))
	vb.add_child(HSeparator.new())
	var cats := [""]
	for t in DataLoader.traits.values():
		if t.get("category", "") != "" and not t.category in cats:
			cats.append(t.category)
	var cgroup := ButtonGroup.new()
	for c in cats:
		vb.add_child(_filter_btn("모든 분류" if c == "" else c, cgroup, c == "", func():
			_category = c
			refresh()))
	return vb


func _filter_btn(text: String, group: ButtonGroup, on: bool, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.toggle_mode = true
	b.button_group = group
	b.button_pressed = on
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.pressed.connect(cb)
	return b


# ---------------------------------------------------------------- 계산
func remaining() -> int:
	var p := start_points
	for id in selected:
		p += int(DataLoader.traits.get(id, {}).get("points", 0))
	return p


## 고를 수 없는 이유 ("" = 고를 수 있음). 이미 고른 것은 항상 "" (풀 수 있게)
func block_reason(id: String) -> String:
	if id in selected:
		return ""
	var t: Dictionary = DataLoader.traits.get(id, {})
	if not t.get("selectable", true):
		return "아직 고를 수 없는 특성"
	for other in selected:
		if other in t.get("conflicts", []) or id in DataLoader.traits.get(other, {}).get("conflicts", []):
			return "'%s' 와(과) 같이 고를 수 없음" % DataLoader.traits.get(other, {}).get("name", other)
	var pts := int(t.get("points", 0))
	if pts < 0 and remaining() + pts < 0:
		return "포인트 부족 (%dP 필요, 남은 %dP)" % [-pts, remaining()]
	return ""


func toggle(id: String) -> void:
	if id in selected:
		selected.erase(id)
	elif block_reason(id) == "":
		selected.append(id)
	_focus_id = id
	refresh()


# ---------------------------------------------------------------- 그리기
func refresh() -> void:
	var rem := remaining()
	_points_label.text = "남은 P:  %d" % rem
	_points_label.add_theme_color_override("font_color", NEG_COLOR if rem < 0 else Color.WHITE)
	for c in _list.get_children():
		_list.remove_child(c)
		c.queue_free()
	_rows = {}
	var q := _search.text.strip_edges().to_lower() if _search else ""
	for pol in ["positive", "negative"]:
		if _polarity != "" and _polarity != pol:
			continue
		var head := Label.new()
		head.text = "긍정적 특성" if pol == "positive" else "부정적 특성"
		head.add_theme_color_override("font_color", POS_COLOR if pol == "positive" else NEG_COLOR)
		_list.add_child(head)
		for t in DataLoader.traits.values():
			if t.polarity != pol or (_category != "" and t.get("category", "") != _category):
				continue
			if q != "" and not (q in String(t.name).to_lower() or q in String(t.get("description", "")).to_lower()):
				continue
			_list.add_child(_row(t))
	_picked.text = "현재 선택: " + (" · ".join(selected.map(func(id): return DataLoader.traits.get(id, {}).get("name", id))) if not selected.is_empty() else "(없음)")
	_start_btn.disabled = rem < 0
	_start_btn.tooltip_text = "남은 포인트가 0 아래면 시작할 수 없습니다" if rem < 0 else ""
	_show_detail(_focus_id)


func _row(t: Dictionary) -> Control:
	var id: String = t.trait_id
	var hb := HBoxContainer.new()
	var cb := CheckBox.new()
	cb.text = t.name
	cb.button_pressed = id in selected
	cb.size_flags_horizontal = SIZE_EXPAND_FILL
	var why := block_reason(id)
	cb.disabled = why != ""
	cb.tooltip_text = why if why != "" else String(t.get("description", ""))
	cb.toggled.connect(func(_on): toggle.call_deferred(id))   # 목록을 다시 그리므로 클릭이 끝난 뒤에
	cb.focus_entered.connect(func(): _show_detail(id))
	cb.mouse_entered.connect(func(): _show_detail(id))
	hb.add_child(cb)
	_rows[id] = cb
	if why != "":
		var r := Label.new()
		r.text = why
		r.add_theme_font_size_override("font_size", 20)
		r.add_theme_color_override("font_color", DIM)
		hb.add_child(r)
	var pts := Label.new()
	pts.text = "%+dP" % int(t.points)
	pts.custom_minimum_size.x = 80
	pts.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	pts.add_theme_color_override("font_color", POS_COLOR if t.polarity == "positive" else NEG_COLOR)
	hb.add_child(pts)
	return hb


func _show_detail(id: String) -> void:
	if not DataLoader.traits.has(id):
		_detail.text = "[color=#8c8c94]특성에 마우스를 올리거나 고르면 자세한 내용이 여기에 나옵니다.\n\n긍정 특성은 포인트를 쓰고, 부정 특성은 포인트를 줍니다.\n고른 특성은 죽어도 다음 회차에 남습니다.[/color]"
		return
	_focus_id = id
	var t: Dictionary = DataLoader.traits[id]
	var pos: bool = t.polarity == "positive"
	var lines := ["[font_size=34][b]%s[/b][/font_size]" % t.name,
		"[color=%s]%s · %s[/color]" % [("#" + POS_COLOR.to_html(false)) if pos else ("#" + NEG_COLOR.to_html(false)),
			"긍정 특성 — %dP 소비" % -int(t.points) if pos else "부정 특성 — %dP 획득" % int(t.points), t.get("category", "")],
		"", String(t.get("description", ""))]
	if not t.get("conflicts", []).is_empty():
		lines.append("")
		lines.append("[color=#8c8c94]같이 고를 수 없음: %s[/color]" % ", ".join(t.conflicts.map(func(c): return DataLoader.traits.get(c, {}).get("name", c))))
	var why := block_reason(id)
	if why != "":
		lines.append("")
		lines.append("[color=#ffb454]%s[/color]" % why)
	_detail.text = "\n".join(lines)


# ---------------------------------------------------------------- 시작
func _confirm() -> void:
	if remaining() < 0:
		return
	var dlg := ConfirmationDialog.new()
	dlg.title = "생존 시작"
	var names := selected.map(func(id): return "%s (%+dP)" % [DataLoader.traits[id].name, int(DataLoader.traits[id].points)])
	dlg.dialog_text = "이 특성으로 시작합니다.\n\n%s\n\n남은 포인트: %dP (남은 포인트는 사라집니다)\n특성은 죽어도 다음 회차에 남습니다." % [
		"\n".join(names) if not names.is_empty() else "(특성 없음)", remaining()]
	dlg.ok_button_text = "시작"
	dlg.cancel_button_text = "돌아가기"
	dlg.confirmed.connect(start_game)
	dlg.canceled.connect(dlg.queue_free)
	add_child(dlg)
	dlg.popup_centered()


## 고른 특성으로 캐릭터를 만들고 첫 회차 시작
func start_game() -> void:
	GameState.create_character(selected.duplicate())
	SaveManager.begin_run()   # 월드 저장도 함께 (특성·생성 완료)
	get_tree().change_scene_to_file(FIELD)
