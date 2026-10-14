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
const FuncCard = preload("res://addons/dialogue_editor/func_card.gd")
const ExprRows = preload("res://addons/expr_rows.gd")
const ToolCommon = preload("res://addons/tool_common.gd")
## '＋ 카드' 메뉴 / 그래프 오른쪽 클릭 메뉴
const ADD_MENU := [
	["line", "대사 카드 — 말하기·상황 설명"],
	["effect", "⚙ 효과 카드 — 아이템·플래그·생존 수치 등을 바꿈"],
	["branch", "◇ 조건 분기 카드 — 조건에 따라 길이 갈림"],
	["ending", "엔딩 카드 — 1단계 에피소드 대화의 끝"],
]

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
var lookups := {}                    # 조건·효과 고르기·갈 곳 목록 (ToolCommon.load_lookups)
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
	files.tooltip_text = "편집할 대화 파일 (tools/dialogues/). 다른 대화를 고르면 지금 대화는 자동 저장"
	for b in [
			["새 대화", _ask_new, "새 대화 파일을 만듭니다 (대화 ID: 영문·숫자·_)"],
			["대사 추가", add_card_at_center, "화면 가운데에 새 대사 카드를 만듭니다"]]:
		var btn := Button.new()
		btn.text = b[0]
		btn.tooltip_text = b[2]
		btn.pressed.connect(b[1])
		bar.add_child(btn)
	var add_menu := MenuButton.new()
	add_menu.text = "＋ 기능 카드 ▾"
	add_menu.flat = false
	add_menu.tooltip_text = "효과 카드·조건 분기 카드·엔딩 카드를 만듭니다.\n그래프 빈 곳을 오른쪽 클릭해도 같은 메뉴가 나옵니다"
	_fill_add_menu(add_menu.get_popup(), Callable())
	bar.add_child(add_menu)
	for b in [
			["저장", save, "지금 대화를 파일로 저장합니다"],
			["변환·검사", run_convert, "저장한 뒤 변환기를 돌려 오류를 검사합니다. 결과는 맨 아래 칸에.\n오류가 없어야 게임에 반영됩니다"],
			["미리보기", preview, "고른 카드(없으면 첫 카드)부터 실제 대화 화면으로 실행합니다"]]:
		var btn := Button.new()
		btn.text = b[0]
		btn.tooltip_text = b[2]
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
	graph.panning_scheme = GraphEdit.SCROLL_ZOOMS   # 휠 = 확대·축소 (사용법 설명과 맞춤)
	graph.connection_request.connect(_on_connect)
	graph.disconnection_request.connect(_on_disconnect)
	graph.delete_nodes_request.connect(_on_delete)
	graph.popup_request.connect(_on_graph_popup)
	graph.node_selected.connect(func(n): if n is Card: _edit_node(n))
	split.add_child(graph)
	var side := ScrollContainer.new()
	side.custom_minimum_size.x = 380
	side.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED   # 긴 글자는 칸 폭에 맞춰 줄임
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
	ToolCommon.add_help(self, 1, bar, "dialogue", HELP_TEXT)


const HELP_TEXT := """[b]대화 탭 쓰는 법[/b]   (이 칸은 오른쪽 위 '❓ 사용법' 으로 접고 펼칩니다)

[b]1. 대화 고르기[/b] — 왼쪽 위 목록에서 대화를 고르거나 [b]새 대화[/b]. 대화 하나 = 파일 하나 (tools/dialogues/).
[b]2. 대사 쓰기[/b] — [b]대사 추가[/b]로 카드를 만들고, 카드 안에서 [b]화자[/b]를 고르고 대사를 씁니다. 화자를 (내레이션)으로 두면 상황 설명.
[b]3. 선으로 잇기[/b] — 카드 오른쪽의 [color=#8fb8ff]●[/color] 점을 마우스로 끌어 다른 카드 왼쪽 위의 점에 놓습니다.
    · [b]다음 →[/b] : 선택지가 없을 때 이어지는 곳
    · [b]선택지 줄[/b] : 그 선택지를 고르면 가는 곳 (전투 선택지는 [b]이겼을 때[/b])
    · [color=#e46a6a]판정 실패 →[/color] / [color=#e46a6a]도주 →[/color] : 주사위에 실패했을 때 / 전투에서 도망쳤을 때 가는 곳
    · 대화를 끝내려면 [b]대화 끝 (EXIT)[/b] 카드에 잇습니다.
    · 선 끊기: 선이 들어가는 쪽 끝(카드 왼쪽 점)을 잡아 빈 곳으로 끌어 놓습니다.
[b]4. 선택지[/b] — 카드 아래 [b]+ 선택지[/b]. 선택지 옆 [b]⋯[/b] 를 누르면 오른쪽 칸에서 종류·조건·효과를 고칩니다. [b]✕[/b] = 선택지 삭제.
    · 종류: [b]일반[/b] / [b]아이템[/b](그 아이템이 있으면 고를 수 있음) / [b]판정[/b](주사위 d20) / [b]전투[/b](적과 싸움, 지면 사망 처리)
[b]5. 기능 카드[/b] — 도구줄 [b]＋ 기능 카드 ▾[/b] 또는 그래프 빈 곳 [b]오른쪽 클릭[/b]. 화면에는 안 보이고 지나가면서 일을 합니다.
    · [color=#7fd48a]⚙ 효과 카드[/color] : 아이템 얻기·잃기, 플래그 켜기·끄기, 생존 수치·능력치 바꾸기, 잘린 팔다리 복구, 아이템 굴리기, 저장 … 을 골라 차례로 실행 → [b]다음 →[/b]
    · [color=#b99be0]◇ 조건 분기 카드[/color] : 아이템이 있다, 플래그가 켜져 있다, 생존 수치가 몇 이하, 팔다리가 잘렸다, 죽은 횟수 … 를 골라 확인 → 맞으면 / [color=#e46a6a]아니면[/color]
[b]6. 조건·효과 고르기[/b] — 오른쪽 칸과 기능 카드의 [b]＋ 조건 추가 / ＋ 효과 추가[/b] 를 눌러 종류를 고르고, 아이템·수치를 목록에서 고릅니다. 글자로 쓸 필요 없습니다.
    · 플래그 = 이야기 진행을 기억하는 스위치. 이름은 영문으로 짓고(예: met_cat), 켜기 → 나중에 '플래그가 켜져 있다' 조건으로 확인. ▾ 로 이미 쓰는 이름을 고를 수 있습니다.
    · 갈 곳도 오른쪽 칸 목록에서 고를 수 있습니다 (선으로 잇는 것과 같음, 다른 대화의 카드로 갈 때 사용).
[b]7. 카드 지우기[/b] — 카드를 클릭해 고른 뒤 Delete 키.   [b]화면[/b] — 휠: 확대·축소,  휠 버튼 누른 채 끌기: 화면 이동,  빈 곳 끌기: 여러 카드 고르기.
[b]8. 반영하기[/b] — [b]저장[/b] → [b]변환·검사[/b] (오류는 맨 아래 칸) → [b]미리보기[/b]로 확인. 오류가 하나라도 있으면 게임에 반영되지 않습니다.
[b]9. NPC에 붙이기[/b] — [b]맵[/b] 탭에서 NPC를 고르고 '대화 (시작 노드)'에 이 대화의 첫 카드를 고릅니다.
"""


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
	_empty_hint()
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
	var card: GraphNode = FuncCard.new() if data.get("kind", "") in ["effect", "branch"] else Card.new()
	if card is FuncCard:
		card.lookups = lookups
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


## 기능 카드 (kind: effect / branch)
func add_func_card(kind: String, pos: Vector2) -> GraphNode:
	var data := {"node_id": _new_node_id(), "kind": kind, "speaker_id": "", "text": "", "next_node": "", "on_enter": ""}
	if kind == "branch":
		data.condition = ""
		data.fail_next = ""
	var card := _make_card(data, [], pos)
	dirty = true
	_sync_connections()
	return card


func _fill_add_menu(pm: PopupMenu, at: Callable) -> void:
	for i in ADD_MENU.size():
		pm.add_item(ADD_MENU[i][1], i)
	pm.id_pressed.connect(func(i): _add_kind(ADD_MENU[i][0], at.call() if at.is_valid() else _center_pos()))


## 그래프 빈 곳 오른쪽 클릭 → 그 자리에 카드 만들기 메뉴
func _on_graph_popup(at_position: Vector2) -> void:
	var pos := (graph.scroll_offset + at_position) / graph.zoom
	var pm := PopupMenu.new()
	_fill_add_menu(pm, func(): return pos)
	add_child(pm)
	pm.popup_hide.connect(pm.queue_free)
	pm.popup_on_parent(Rect2i(Vector2i(get_global_mouse_position()), Vector2i.ZERO))


func _center_pos() -> Vector2:
	return (graph.scroll_offset + graph.size / 2.0) / graph.zoom - Vector2(210, 100)


func _add_kind(kind: String, pos: Vector2) -> void:
	if dialogue.is_empty():
		_status("먼저 대화를 열거나 새로 만드세요")
		return
	match kind:
		"line": _edit_node(add_card(pos))
		"ending": _add_end_card()
		_: _edit_node(add_func_card(kind, pos))


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
			_empty_hint()
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
	if card is FuncCard:
		var branch: bool = d.kind == "branch"
		_title("조건 분기 카드" if branch else "효과 카드")
		_line("카드 ID", d.node_id, func(v): _rename_node(card, v))
		_hint(("조건은 카드 안에서 고릅니다. 맞으면 '맞으면 →', 아니면 빨간 '아니면 →' 으로 갑니다."
			if branch else "효과는 카드 안에서 고릅니다. 실행한 뒤 '다음 →' 으로 갑니다.")
			+ "\n화면에는 보이지 않습니다.")
		_target("맞으면 갈 곳" if branch else "다음 갈 곳", d, "next_node", card)
		if branch:
			_target("아니면 갈 곳", d, "fail_next", card)
		return
	_title("대사 카드")
	_line("카드 ID", d.node_id, func(v): _rename_node(card, v))
	_expr("이 카드에 들어올 때 효과", "effect", d.get("on_enter", ""), _setter(d, "on_enter"))
	_target("다음 갈 곳 (선택지가 없을 때)", d, "next_node", card)
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
	_expr("보이는 조건 (맞아야 고를 수 있음)", "cond", c.get("condition", ""), _setter(c, "condition"))
	_option("조건이 안 맞을 때", ["gray", "hide"], ["회색으로 보임", "숨김"], c.get("show_mode", "") if c.get("show_mode", "") != "" else "gray",
		_show_mode_setter(c))
	_line("대가 표시 (cost)", c.get("cost", ""), _setter(c, "cost"), "버튼에 보이는 글자만. 실제 차감은 효과에")
	_expr("고르면 일어나는 효과" if c.get("type", "normal") != "combat" else "이겼을 때 효과", "effect",
		c.get("effects", ""), _setter(c, "effects"))
	_target("갈 곳" if not c.get("type", "normal") in ["dice", "combat"] else ("성공하면 갈 곳" if c.type == "dice" else "이기면 갈 곳"),
		c, "next_node", card)
	if c.get("type", "normal") == "dice":
		_title("판정")
		_option("능력치 (check)", abilities.map(func(a): return a[0]), abilities.map(func(a): return a[1]), c.get("check", ""),
			_setter(c, "check"))
		_spin("목표값 (dc)", int(c.get("dc", 10)), 1, 40, _setter(c, "dc"))
		_spin("상황 보정 (mod)", int(c.get("mod", 0)), -20, 20, _setter(c, "mod"))
		_expr("실패했을 때 효과", "effect", c.get("fail_effects", ""), _setter(c, "fail_effects"))
		_target("실패하면 갈 곳", c, "fail_next", card)
	elif c.get("type", "normal") == "combat":
		_title("전투")
		_option("적 (check)", enemies.map(func(e): return e[0]), enemies.map(func(e): return e[1]), c.get("check", ""),
			_setter(c, "check"))
		_expr("도망쳤을 때 효과", "effect", c.get("fail_effects", ""), _setter(c, "fail_effects"))
		_target("도망치면 갈 곳", c, "fail_next", card)
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
		out.append(n.get("fail_next", ""))
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
	lookups = ToolCommon.load_lookups()
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


## 조건·효과 칸: 직접 입력 대신 목록에서 고르기 (addons/expr_rows.gd)
func _expr(label: String, mode: String, value: String, on_change: Callable) -> void:
	var l := Label.new()
	l.text = label
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	inspector.add_child(l)
	var rows: Node = ExprRows.new().setup(mode, value, lookups)
	rows.changed.connect(func(t): on_change.call(t))
	inspector.add_child(rows)


## 갈 곳 고르기: 대화 끝 / 엔딩 / 이 대화의 카드 / 다른 대화·엑셀의 노드 (같은 에피소드 범위만)
func _target(label: String, d: Dictionary, key: String, card: GraphNode) -> void:
	var episode: String = dialogue.get("episode_id", "")
	var opts := [["", "(없음 · 연결선으로 정함)"]]
	if episode == "":
		opts.append(["EXIT", "대화 끝 (EXIT)"])
	for e in lookups.get("endings", []):
		if episode != "" and e[1] == episode:
			opts.append(["END:" + e[0], "엔딩: " + e[0]])
	var here := {}
	for c in _cards():
		var id: String = c.data.node_id
		here[id] = true
		var what: String = ("(조건 분기)" if c.data.kind == "branch" else "(효과 카드)") if c is FuncCard else String(c.data.get("text", "")).left(18)
		opts.append([id, "이 대화: %s — %s" % [id, what]])
	for n in lookups.get("nodes", []):
		if not here.has(n[0]) and n[1] == episode:
			opts.append([n[0], "다른 곳: %s — %s" % [n[0], n[2]]])
	var cur: String = d.get(key, "")
	if cur != "" and not opts.any(func(o): return o[0] == cur):
		opts.append([cur, "%s (목록에 없음)" % cur])
	_option(label, opts.map(func(o): return o[0]), opts.map(func(o): return o[1]), cur, func(v):
		d[key] = v
		_after_target_change(card))


## 아무것도 고르지 않았을 때 오른쪽 칸 안내
func _empty_hint() -> void:
	_title("세부 칸")
	_hint("· 카드를 클릭하면 카드 세부 (ID·들어올 때 효과·이동)\n· 선택지 옆 ⋯ 를 누르면 선택지 세부 (종류·조건·효과·판정·전투)\n\n자세한 쓰는 법은 오른쪽 위 '❓ 사용법'.")


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
	o.fit_to_longest_item = false
	o.clip_text = true
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
