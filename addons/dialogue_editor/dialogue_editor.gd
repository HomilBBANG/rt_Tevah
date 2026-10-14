@tool
extends VBoxContainer
## 대화 에디터 (Godot 에디터의 '대화' 탭). tools/dialogues/<대화ID>.json 을 노드 그래프로 편집한다.
##
## - 대사 카드를 선으로 이어 흐름을 만든다. 카드의 '다음 →'·선택지·'판정 실패 →' 연결점에서 다른 카드의 왼쪽으로 끌면 연결.
## - 대화 끝(EXIT, 필드 대화)·엔딩(END:id, 에피소드 대화) 카드로도 연결할 수 있다.
## - 다른 파일·엑셀의 노드로 가려면 오른쪽 칸의 '이동(직접 입력)'에 node_id 를 적는다.
## - 저장 → 변환·검사(tools/xlsx_to_json.py) → 미리보기(고른 카드부터 실제 대화 화면).
## 게임 실행 중(테스트)에서도 열 수 있도록 에디터 전용 기능은 Engine.is_editor_hint() 로 감싼다.

const Card = preload("res://addons/dialogue_editor/dialogue_card.gd")
const ToolCommon = preload("res://addons/tool_common.gd")

const DIALOGUE_DIR := "res://tools/dialogues/"
const EXIT_NAME := "__EXIT__"
const END_PREFIX := "__END__"
const PREVIEW_FILE := "user://dialogue_preview.json"

var dir := DIALOGUE_DIR              # 테스트에서 바꿔 쓴다
var dialogue := {}                   # 열린 대화 { dialogue_id, episode_id, nodes, choices }
var path := ""
var dirty := false

var graph: GraphEdit
var files: OptionButton
var status: Label
var inspector: VBoxContainer
var log_view: TextEdit
var speakers: Array = []             # [[char_id, name]]
var abilities: Array = []            # [[ability_id, name]]
var enemies: Array = []              # [[enemy_id, name]] (전투 선택지)
var _selected_card: GraphNode
var _counter := 0


func _init() -> void:
	size_flags_vertical = SIZE_EXPAND_FILL
	size_flags_horizontal = SIZE_EXPAND_FILL
	# ---- 위 도구줄
	var bar := HBoxContainer.new()
	add_child(bar)
	files = OptionButton.new()
	files.custom_minimum_size.x = 220
	files.item_selected.connect(func(i): open_dialogue(files.get_item_text(i)))
	bar.add_child(files)
	for b in [["새 대화", _ask_new], ["대사 추가", add_card_at_center], ["엔딩 카드", _add_end_card],
			["저장", save], ["변환·검사", run_convert], ["미리보기", preview]]:
		var btn := Button.new()
		btn.text = b[0]
		btn.pressed.connect(b[1])
		bar.add_child(btn)
	status = Label.new()
	status.size_flags_horizontal = SIZE_EXPAND_FILL
	status.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	bar.add_child(status)
	# ---- 그래프 | 오른쪽 칸
	var split := HSplitContainer.new()
	split.size_flags_vertical = SIZE_EXPAND_FILL
	add_child(split)
	graph = GraphEdit.new()
	graph.size_flags_horizontal = SIZE_EXPAND_FILL
	graph.right_disconnects = true
	graph.connection_request.connect(_on_connect)
	graph.disconnection_request.connect(_on_disconnect)
	graph.delete_nodes_request.connect(_on_delete)
	graph.node_selected.connect(func(n): if n is Card: _edit_node(n))
	split.add_child(graph)
	var side := ScrollContainer.new()
	side.custom_minimum_size.x = 380
	split.add_child(side)
	inspector = VBoxContainer.new()
	inspector.size_flags_horizontal = SIZE_EXPAND_FILL
	side.add_child(inspector)
	# ---- 아래 변환 결과
	log_view = TextEdit.new()
	log_view.editable = false
	log_view.custom_minimum_size.y = 110
	log_view.placeholder_text = "변환·검사 결과가 여기에 나옵니다."
	add_child(log_view)


func _ready() -> void:
	refresh_file_list()


# ---------------------------------------------------------------- 파일
func refresh_file_list() -> void:
	_load_lookups()
	var current := dialogue.get("dialogue_id", "")
	files.clear()
	var names := []
	var d := DirAccess.open(dir)
	if d:
		for f in d.get_files():
			if f.ends_with(".json"):
				names.append(f.get_basename())
	names.sort()
	for n in names:
		files.add_item(n)
	if current == "" and not names.is_empty():
		open_dialogue(names[0])
	else:
		_select_file_item(current)


func open_dialogue(id: String) -> void:
	if dirty and not dialogue.is_empty():
		save()
	var p := dir + id + ".json"
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(p)) if FileAccess.file_exists(p) else null
	if not parsed is Dictionary:
		_status("열 수 없음: " + p)
		return
	dialogue = parsed
	path = p
	_build_graph()
	_select_file_item(id)
	dirty = false
	_status("열림: %s  (%s)" % [id, "필드 대화" if dialogue.get("episode_id", "") == "" else "에피소드 " + dialogue.episode_id])


func new_dialogue(id: String, episode_id := "") -> bool:
	id = id.strip_edges()
	if not RegEx.create_from_string("^[A-Za-z0-9_]+$").search(id):
		_status("대화 ID 는 영문·숫자·_ 만")
		return false
	DirAccess.make_dir_recursive_absolute(dir)
	if FileAccess.file_exists(dir + id + ".json"):
		_status("이미 있는 대화: " + id)
		return false
	dialogue = {"dialogue_id": id, "episode_id": episode_id, "nodes": [], "choices": []}
	path = dir + id + ".json"
	_build_graph()
	add_card(Vector2(40, 60))
	save()
	refresh_file_list()
	_select_file_item(id)
	return true


func save() -> void:
	if dialogue.is_empty():
		return
	var nodes := []
	var choices := []
	for card in _cards():
		var n: Dictionary = card.data.duplicate()
		n.pos = [roundi(card.position_offset.x), roundi(card.position_offset.y)]
		nodes.append(n)
		for c in card.choices:
			c.node_id = card.data.node_id
			choices.append(c.duplicate())
	dialogue.nodes = nodes
	dialogue.choices = choices
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		_status("저장 실패: " + path)
		return
	f.store_string(JSON.stringify(dialogue, " ", false) + "\n")
	f.close()
	dirty = false
	_status("저장함: " + path.get_file())


# ---------------------------------------------------------------- 그래프 만들기
func _build_graph() -> void:
	graph.clear_connections()
	for c in graph.get_children():
		if c is GraphNode:
			graph.remove_child(c)
			c.queue_free()
	_selected_card = null
	_counter = 0
	_clear_inspector()
	var by_node := {}
	for c in dialogue.get("choices", []):
		if not by_node.has(c.node_id):
			by_node[c.node_id] = []
		by_node[c.node_id].append(c)
	for n in dialogue.get("nodes", []):
		var pos: Array = n.get("pos", [40, 60])
		var data: Dictionary = n.duplicate()
		data.erase("pos")
		_make_card(data, by_node.get(n.node_id, []), Vector2(pos[0], pos[1]))
	# 끝 카드: 필드 대화는 EXIT 하나, 에피소드 대화는 쓰인 엔딩마다
	if dialogue.get("episode_id", "") == "":
		_make_terminal(EXIT_NAME, "대화 끝 (EXIT)", _right_of_cards())
	for t in _all_targets():
		if t.begins_with("END:") and graph.get_node_or_null(END_PREFIX + t.substr(4)) == null:
			_make_terminal(END_PREFIX + t.substr(4), "엔딩: " + t.substr(4), _right_of_cards() + Vector2(0, 140))
	_sync_connections()


func _make_card(data: Dictionary, node_choices: Array, pos: Vector2) -> GraphNode:
	var card := Card.new()
	card.choice_id_maker = _new_choice_id
	card.setup(data, node_choices, speakers)
	card.position_offset = pos
	card.changed.connect(_on_card_changed.bind(card))
	card.choice_selected.connect(_edit_choice)
	card.node_selected_for_edit.connect(_edit_node)
	card.position_offset_changed.connect(func(): dirty = true)
	graph.add_child(card)
	return card


func _make_terminal(node_name: String, label: String, pos: Vector2) -> GraphNode:
	var t := GraphNode.new()
	t.name = node_name
	t.title = label
	t.position_offset = pos
	var l := Label.new()
	l.text = "← 여기로 연결"
	t.add_child(l)
	t.set_slot(0, true, 0, Color("8fb8ff"), false, 0, Color.WHITE)
	graph.add_child(t)
	return t


func add_card(pos: Vector2) -> GraphNode:
	var id := _new_node_id()
	var card := _make_card({"node_id": id, "speaker_id": "", "text": "", "next_node": "", "on_enter": ""}, [], pos)
	dirty = true
	_sync_connections()
	return card


func add_card_at_center() -> void:
	if dialogue.is_empty():
		_status("먼저 대화를 열거나 새로 만드세요")
		return
	var center := (graph.scroll_offset + graph.size / 2.0) / graph.zoom
	_edit_node(add_card(center - Vector2(210, 100)))


func _add_end_card() -> void:
	if dialogue.is_empty():
		return
	var id := "ending_%d" % (_counter + 1)
	_counter += 1
	_make_terminal(END_PREFIX + id, "엔딩: " + id, _right_of_cards())
	_status("엔딩 카드 '%s' — Endings 시트의 ending_id 로 이름을 맞추려면 연결 후 오른쪽 칸에서 이동을 END:<id> 로 고치세요" % id)


# ---------------------------------------------------------------- 연결 = 데이터의 이동 대상
func _on_connect(from: StringName, from_port: int, to: StringName, _to_port: int) -> void:
	var card := graph.get_node_or_null(NodePath(from))
	if not card is Card:
		return
	var tgt: Array = card.port_target(from_port)
	tgt[0][tgt[1]] = _target_of(String(to))
	_after_target_change(card)


func _on_disconnect(from: StringName, from_port: int, _to: StringName, _to_port: int) -> void:
	var card := graph.get_node_or_null(NodePath(from))
	if not card is Card:
		return
	var tgt: Array = card.port_target(from_port)
	tgt[0][tgt[1]] = ""
	_after_target_change(card)


func _after_target_change(card: GraphNode) -> void:
	card.rebuild()
	dirty = true
	_sync_connections()
	if _selected_card == card:
		_edit_node(card)


## 데이터의 이동 대상들로 연결선을 다시 그린다 (연결이 데이터를 따른다)
func _sync_connections() -> void:
	graph.clear_connections()
	for card in _cards():
		for port in card.out_ports.size():
			var tgt: Array = card.port_target(port)
			var to := _node_name_of(str(tgt[0].get(tgt[1], "")))
			if to != "" and graph.get_node_or_null(NodePath(to)) != null:
				graph.connect_node(card.name, port, to, 0)


func _target_of(node_name: String) -> String:
	if node_name == EXIT_NAME:
		return "EXIT"
	if node_name.begins_with(END_PREFIX):
		return "END:" + node_name.substr(END_PREFIX.length())
	return node_name


func _node_name_of(target: String) -> String:
	if target == "EXIT":
		return EXIT_NAME
	if target.begins_with("END:"):
		return END_PREFIX + target.substr(4)
	return target


func _on_delete(names: Array) -> void:
	for n in names:
		var node := graph.get_node_or_null(NodePath(n))
		if node == null:
			continue
		var target := _target_of(String(n))
		for card in _cards():
			for port in card.out_ports.size():
				var tgt: Array = card.port_target(port)
				if tgt[0].get(tgt[1], "") == target:
					tgt[0][tgt[1]] = ""
		graph.remove_child(node)
		node.queue_free()
		if node == _selected_card:
			_selected_card = null
			_clear_inspector()
	for card in _cards():
		card.rebuild()
	dirty = true
	_sync_connections()


func _on_card_changed(card: GraphNode) -> void:
	dirty = true
	_sync_connections.call_deferred()
	if _selected_card == card:
		_status("수정됨 (저장 안 함)")


# ---------------------------------------------------------------- 오른쪽 칸 (세부)
func _edit_node(card: GraphNode) -> void:
	_selected_card = card
	_clear_inspector()
	var d: Dictionary = card.data
	_title("대사 카드")
	_line("node_id", d.node_id, func(v): _rename_node(card, v))
	_line("들어올 때 효과 (on_enter)", d.get("on_enter", ""), _setter(d, "on_enter"),
		"예: item:+bandage;setflag:met")
	_line("이동 (직접 입력)", d.get("next_node", ""), func(v):
		d.next_node = v
		_after_target_change(card), "다른 파일·엑셀 노드로 갈 때 node_id. EXIT / END:id")
	_hint("선택지가 있으면 '다음 →' 대신 선택지가 나온다.")


func _edit_choice(card: GraphNode, index: int) -> void:
	_selected_card = card
	_clear_inspector()
	if index >= card.choices.size():
		return
	var c: Dictionary = card.choices[index]
	_title("선택지  (%s)" % card.data.node_id)
	_line("choice_id", c.choice_id, _setter(c, "choice_id"))
	_line("문구", c.get("text", ""), func(v):
		c.text = v
		card.rebuild()
		dirty = true)
	_option("종류", ["normal", "item", "dice", "combat"], ["일반", "아이템 (조건에 has: 필요)", "판정 (주사위)", "전투 (이기면 이동, 도주하면 도주 이동)"],
			c.get("type", "normal"), func(v):
		c.type = v
		if v == "combat" and not c.get("check", "") in enemies.map(func(e): return e[0]):
			c.check = enemies[0][0] if not enemies.is_empty() else ""
		elif v == "dice" and not c.get("check", "") in abilities.map(func(a): return a[0]):
			c.check = abilities[0][0] if not abilities.is_empty() else ""
		elif not v in ["dice", "combat"]:
			# 판정·전투 전용 칸을 비워 둬야 변환기 검사를 통과한다
			for k in ["check", "fail_effects", "fail_next"]:
				c[k] = ""
		card.rebuild()
		_after_target_change(card)
		_edit_choice(card, index))
	_line("조건 (condition)", c.get("condition", ""), _setter(c, "condition"), "예: has:knife & flag:met")
	_option("조건이 안 맞을 때", ["gray", "hide"], ["회색으로 보임", "숨김"], c.get("show_mode", "") if c.get("show_mode", "") != "" else "gray",
		_show_mode_setter(c))
	_line("대가 표시 (cost)", c.get("cost", ""), _setter(c, "cost"), "표시만. 실제 차감은 효과에")
	_line("효과 (effects)", c.get("effects", ""), _setter(c, "effects"), "예: item:-water;surv:thirst+50;save")
	_line("이동 (직접 입력)", c.get("next_node", ""), func(v):
		c.next_node = v
		_after_target_change(card), "연결선 대신 node_id / EXIT / END:id")
	if c.get("type", "normal") == "dice":
		_title("판정")
		_option("능력치 (check)", abilities.map(func(a): return a[0]), abilities.map(func(a): return a[1]), c.get("check", ""),
			_setter(c, "check"))
		_spin("목표값 (dc)", int(c.get("dc", 10)), 1, 40, _setter(c, "dc"))
		_spin("상황 보정 (mod)", int(c.get("mod", 0)), -20, 20, _setter(c, "mod"))
		_line("실패 효과 (fail_effects)", c.get("fail_effects", ""), _setter(c, "fail_effects"))
		_line("실패 이동 (직접 입력)", c.get("fail_next", ""), func(v):
			c.fail_next = v
			_after_target_change(card))
	elif c.get("type", "normal") == "combat":
		_title("전투")
		_option("적 (check)", enemies.map(func(e): return e[0]), enemies.map(func(e): return e[1]), c.get("check", ""),
			_setter(c, "check"))
		_line("도주 효과 (fail_effects)", c.get("fail_effects", ""), _setter(c, "fail_effects"))
		_line("도주 이동 (직접 입력)", c.get("fail_next", ""), func(v):
			c.fail_next = v
			_after_target_change(card))
		var note := Label.new()
		note.text = "이기면 효과·이동, 도주하면 도주 효과·이동.\n지면 대화가 끝나고 사망 처리 (부활 규칙)."
		note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		inspector.add_child(note)


func _rename_node(card: GraphNode, new_id: String) -> void:
	new_id = new_id.strip_edges()
	var old: String = card.data.node_id
	if new_id == old or new_id == "" or graph.get_node_or_null(NodePath(new_id)) != null:
		return
	for other in _cards():
		for port in other.out_ports.size():
			var tgt: Array = other.port_target(port)
			if tgt[0].get(tgt[1], "") == old:
				tgt[0][tgt[1]] = new_id
	card.data.node_id = new_id
	for c in card.choices:
		c.node_id = new_id
	card.name = new_id
	card.title = new_id
	dirty = true
	_sync_connections()


# ---------------------------------------------------------------- 변환·미리보기
## 변환 스크립트 실행 결과를 아래 칸에 표시. 성공하면 true.
func run_convert() -> bool:
	if dirty:
		save()
	var ok: bool = ToolCommon.run_convert(log_view)
	_status("변환 성공" if ok else "변환 실패 — 아래 오류를 확인하세요")
	return ok


## 고른 카드(없으면 첫 카드)부터 실제 대화 화면으로 실행
func preview() -> void:
	if dialogue.is_empty() or _cards().is_empty():
		return
	if not run_convert():
		return
	var start: String = (_selected_card if _selected_card is Card else _cards()[0]).data.node_id
	var f := FileAccess.open(PREVIEW_FILE, FileAccess.WRITE)
	f.store_string(JSON.stringify({"node": start}))
	f.close()
	if Engine.is_editor_hint():
		EditorInterface.play_custom_scene("res://addons/dialogue_editor/preview.tscn")


# ---------------------------------------------------------------- 도우미
func _cards() -> Array:
	return graph.get_children().filter(func(c): return c is Card)


func _all_targets() -> Array:
	var out := []
	for n in dialogue.get("nodes", []):
		out.append(n.get("next_node", ""))
	for c in dialogue.get("choices", []):
		out.append(c.get("next_node", ""))
		out.append(c.get("fail_next", ""))
	return out


func _right_of_cards() -> Vector2:
	var x := 40.0
	for c in _cards():
		x = maxf(x, c.position_offset.x + 520)
	return Vector2(x, 60)


func _new_node_id() -> String:
	var base: String = dialogue.get("dialogue_id", "dlg")
	while true:
		_counter += 1
		var id := "%s_%d" % [base, _counter]
		if graph.get_node_or_null(NodePath(id)) == null:
			return id
	return ""


func _new_choice_id() -> String:
	var base: String = dialogue.get("dialogue_id", "dlg")
	var used := {}
	for card in _cards():
		for c in card.choices:
			used[c.choice_id] = true
	var i := 1
	while used.has("%s_c%d" % [base, i]):
		i += 1
	return "%s_c%d" % [base, i]


func _load_lookups() -> void:
	speakers = [["", "(내레이션)"]]
	for ch in _read_json("res://data/characters.json", []):
		speakers.append([ch.char_id, "%s  (%s)" % [ch.name, ch.char_id]])
	abilities = []
	for a in _read_json("res://data/abilities.json", []):
		abilities.append([a.ability_id, "%s  (%s)" % [a.name, a.ability_id]])
	enemies = []
	for e in _read_json("res://data/enemies.json", []):
		enemies.append([e.enemy_id, "%s  (%s)" % [e.name, e.enemy_id]])


func _read_json(p: String, default: Variant) -> Variant:
	if not FileAccess.file_exists(p):
		return default
	var v = JSON.parse_string(FileAccess.get_file_as_string(p))
	return v if v != null else default


func _select_file_item(id: String) -> void:
	for i in files.item_count:
		if files.get_item_text(i) == id:
			files.select(i)


func _status(t: String) -> void:
	status.text = t


func _ask_new() -> void:
	var dlg := ConfirmationDialog.new()
	dlg.title = "새 대화"
	var box := VBoxContainer.new()
	var id := LineEdit.new()
	id.placeholder_text = "대화 ID (영문·숫자·_, 예: hana_first_meet)"
	var ep := LineEdit.new()
	ep.placeholder_text = "에피소드 ID (비우면 필드 대화)"
	box.add_child(id)
	box.add_child(ep)
	dlg.add_child(box)
	dlg.confirmed.connect(func():
		new_dialogue(id.text, ep.text.strip_edges())
		dlg.queue_free())
	dlg.canceled.connect(dlg.queue_free)
	add_child(dlg)
	dlg.popup_centered(Vector2i(480, 160))


func _clear_inspector() -> void:
	for c in inspector.get_children():
		inspector.remove_child(c)
		c.queue_free()


func _title(t: String) -> void:
	var l := Label.new()
	l.text = t
	l.add_theme_font_size_override("font_size", 18)
	inspector.add_child(l)


func _hint(t: String) -> void:
	var l := Label.new()
	l.text = t
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.modulate = Color(1, 1, 1, 0.6)
	inspector.add_child(l)


func _setter(d: Dictionary, key: String) -> Callable:
	return func(v):
		d[key] = v
		dirty = true


func _show_mode_setter(c: Dictionary) -> Callable:
	return func(v):
		c.show_mode = "" if v == "gray" else v
		dirty = true


func _line(label: String, value: String, on_change: Callable, hint := "") -> void:
	var l := Label.new()
	l.text = label
	inspector.add_child(l)
	var e := LineEdit.new()
	e.text = value
	e.placeholder_text = hint
	e.text_submitted.connect(func(v): on_change.call(v))
	e.focus_exited.connect(func(): if e.text != value: on_change.call(e.text))
	inspector.add_child(e)


func _option(label: String, values: Array, labels: Array, current: String, on_change: Callable) -> void:
	var l := Label.new()
	l.text = label
	inspector.add_child(l)
	var o := OptionButton.new()
	for i in values.size():
		o.add_item(labels[i], i)
		if values[i] == current:
			o.select(i)
	o.item_selected.connect(func(i): on_change.call(values[i]))
	inspector.add_child(o)


func _spin(label: String, value: int, lo: int, hi: int, on_change: Callable) -> void:
	var l := Label.new()
	l.text = label
	inspector.add_child(l)
	var s := SpinBox.new()
	s.min_value = lo
	s.max_value = hi
	s.value = value
	s.value_changed.connect(func(v): on_change.call(int(v)))
	inspector.add_child(s)
