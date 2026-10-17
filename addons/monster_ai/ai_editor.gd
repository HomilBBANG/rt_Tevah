@tool
extends Control
## '몬스터 AI' 탭 — Unreal 의 Behavior Tree / Blackboard 작업 흐름을 닮은 독립 에디터 (기획 tevah_monster_bt_blueprint_style_spec_v2.0 §2, §3, §4, §6).
## 화면: 위 Content 줄(새 BT·BB·템플릿·저장·Compile·되돌리기) / 왼쪽 AI Assets(BT_·BB_·BTT_) + 노드 팔레트 /
##       가운데 탭(Behavior Tree 그래프 · Blackboard 표 · Task Graph · Debugger) / 오른쪽 Details / 아래 검사 결과.
## 원본 자산은 tools/ai/<id>.json, 'Compile' = 검사 + data/ai.json (게임이 읽는 묶음). 코드 컴파일이 아님 (테바 전용 용어).
## 맵 에디터는 여기서 만든 BT_ 를 고르기만 한다 (BT 편집은 여기서만).

const Assets = preload("res://core/ai/ai_assets.gd")
const Tasks = preload("res://core/ai/bt_tasks.gd")
const Blackboard = preload("res://core/ai/blackboard.gd")
const Runner = preload("res://core/ai/bt_runner.gd")
const Canvas = preload("res://addons/monster_ai/bt_canvas.gd")
const GraphView = preload("res://addons/monster_ai/graph_view.gd")
const DebugView = preload("res://addons/monster_ai/debug_view.gd")
const Graph = preload("res://core/ai/task_graph.gd")

const TAB_BT := 0
const TAB_BB := 1
const TAB_GRAPH := 2
const PREFIX := {"behavior_tree": "BT_", "blackboard": "BB_", "task_graph": "BTT_"}
const KIND_HELP := {
	"Root": ["Root (Behavior Tree 의 시작)", "트리의 시작. 여기서 이 트리가 쓸 Blackboard 자산을 고른다. 자식은 Selector 나 Sequence 하나."],
	"Selector": ["BTComposite_Selector", "왼쪽 자식부터 시도해서 하나라도 성공(또는 실행 중)이면 거기 머문다. 실패하면 다음 자식. = 'OR, 우선순위 목록'"],
	"Sequence": ["BTComposite_Sequence", "왼쪽 자식부터 차례로 실행. 하나라도 실패하면 전체 실패. = 'AND, 순서대로'"],
	"SimpleParallel": ["BTComposite_SimpleParallel", "주 Task(0, '주')를 실행하는 동안 배경 분기(1, '배')를 반복. 주 Task 가 끝나면 끝 (Immediate = 배경 바로 중단, Delayed = 배경이 지금 바퀴를 마칠 때까지). 결과 = 주 Task 결과."],
}
const ABORT_HELP := {"None": "중단 안 함 (들어갈 때만 판정)", "Self": "Self — 실행 중인 이 분기의 조건이 false 가 되면 중단",
	"LowerPriority": "Lower Priority — 이 조건이 true 가 되면 오른쪽(낮은 우선순위)에서 실행 중인 것을 중단하고 이쪽으로",
	"Both": "Both — Self + Lower Priority"}
const OP_LABEL := {"is_set": "있음 (Is Set)", "is_not_set": "없음 (Is Not Set)", "==": "==", "!=": "!=", "<": "<", "<=": "<=", ">": ">", ">=": ">="}

var dir := Assets.SRC_DIR       # 테스트에서 바꿔 쓴다
var out_path := Assets.OUT_PATH
var assets := {}
var current := ""
var selected := ""
var dirty := {}
var _hist := {}                 # id -> {undo: [], redo: [], key: ""}
var _clip := {}                 # 복사한 노드 묶음 {root, nodes}

var asset_tree: Tree
var palette: Tree
var tabs: TabContainer
var canvas: Control
var bb_box: VBoxContainer
var details: VBoxContainer
var problems: ItemList
var status: Label
var find_edit: LineEdit
var help_panel: PanelContainer
var graph_view: Control
var _back_to := ""              # Task Graph 를 연 BT (◀ 돌아가기)
var debug_view: Control
var _problem_nodes: Array = []
var _listing := false           # 목록을 다시 그리는 중 (고른 표시가 다시 열기를 부르지 않게)


func _ready() -> void:
	_build()
	reload_assets()


# ================================================================ 화면
func _build() -> void:
	for c in get_children():
		c.queue_free()
	if not get_parent() is Container:
		set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	add_child(root)
	# --- 위 Content 줄
	var bar := HBoxContainer.new()
	root.add_child(bar)
	var lbl := Label.new()
	lbl.text = "몬스터 AI  "
	bar.add_child(lbl)
	_btn(bar, "＋ Behavior Tree", "새 BT_ 자산", _ask_new.bind("behavior_tree"))
	_btn(bar, "＋ Blackboard", "새 BB_ 자산", _ask_new.bind("blackboard"))
	_btn(bar, "＋ Task Graph", "새 BTT_ 자산 (Blueprint 스타일로 Task 속을 짜기)", _ask_new.bind("task_graph"))
	var tpl := MenuButton.new()
	tpl.text = "템플릿 ▾"
	tpl.tooltip_text = "예제를 새 이름으로 복사"
	var tpls := [["behavior_tree", "BT_Infected_Field", "BT: 감염자 기본 (순찰·추격·수색·전투)"],
		["behavior_tree", "BT_02_HearAndSearch", "BT: 실습 2 — 소리 감지·확인"],
		["behavior_tree", "BT_03_Stalker", "BT: 실습 3 — 수색을 Task Graph 로"],
		["behavior_tree", "BT_Battle_Test", "BT: 전투 — 상황에 따라 공격 고르기"],
		["task_graph", "BTT_SearchLastPosition", "Task Graph: 마지막 위치 수색 (이동 실패·Abort 포함)"]]
	for i in tpls.size():
		tpl.get_popup().add_item(tpls[i][2], i)
	tpl.get_popup().id_pressed.connect(func(i): _ask_new(tpls[i][0], tpls[i][1]))
	bar.add_child(tpl)
	bar.add_child(VSeparator.new())
	_btn(bar, "저장", "바뀐 자산을 tools/ai 에 저장 (Ctrl+S)", save)
	_btn(bar, "Compile", "테바의 Compile = 코드 컴파일이 아니라 BT 검사 + 게임이 읽는 data/ai.json 만들기", compile)
	bar.add_child(VSeparator.new())
	_btn(bar, "↶", "되돌리기 (Ctrl+Z)", undo)
	_btn(bar, "↷", "다시 (Ctrl+Y)", redo)
	find_edit = LineEdit.new()
	find_edit.placeholder_text = "노드 찾기 (이름·종류)"
	find_edit.custom_minimum_size.x = 220
	find_edit.text_submitted.connect(func(t): find_node(t))
	bar.add_child(find_edit)
	var sp := Control.new()
	sp.size_flags_horizontal = SIZE_EXPAND_FILL
	bar.add_child(sp)
	_btn(bar, "❓ 사용법", "", func(): help_panel.visible = not help_panel.visible)
	help_panel = PanelContainer.new()
	help_panel.visible = false
	var help := RichTextLabel.new()
	help.bbcode_enabled = true
	help.fit_content = true
	help.text = _help_text()
	help_panel.add_child(help)
	root.add_child(help_panel)
	# --- 가운데: 왼쪽 | 탭 | Details
	var split := HSplitContainer.new()
	split.size_flags_vertical = SIZE_EXPAND_FILL
	root.add_child(split)
	var left := VSplitContainer.new()
	left.custom_minimum_size.x = 250
	split.add_child(left)
	asset_tree = Tree.new()
	asset_tree.hide_root = true
	asset_tree.size_flags_vertical = SIZE_EXPAND_FILL
	asset_tree.item_selected.connect(func():
		var it := asset_tree.get_selected()
		if it and it.get_metadata(0) and not _listing and it.get_metadata(0) != current:
			_back_to = ""
			open_asset(it.get_metadata(0)))
	left.add_child(asset_tree)
	palette = Tree.new()
	palette.hide_root = true
	palette.size_flags_vertical = SIZE_EXPAND_FILL
	palette.tooltip_text = "두 번 누르면 고른 노드에 넣기 (Composite·Task = 자식, Decorator·Service = 붙이기)"
	palette.item_activated.connect(func():
		var it := palette.get_selected()
		if it and it.get_metadata(0):
			add_from_palette(it.get_metadata(0)))
	left.add_child(palette)
	var mid := HSplitContainer.new()
	mid.size_flags_horizontal = SIZE_EXPAND_FILL
	split.add_child(mid)
	tabs = TabContainer.new()
	tabs.size_flags_horizontal = SIZE_EXPAND_FILL
	mid.add_child(tabs)
	canvas = Canvas.new()
	canvas.name = "Behavior Tree"
	canvas.node_selected.connect(func(id): _select(id, false))
	canvas.node_activated.connect(_activate)
	canvas.reorder_requested.connect(func(id, i): move_node(id, i))
	canvas.context_requested.connect(_context_menu)
	tabs.add_child(canvas)
	var bbs := ScrollContainer.new()
	bbs.name = "Blackboard"
	bb_box = VBoxContainer.new()
	bb_box.size_flags_horizontal = SIZE_EXPAND_FILL
	bbs.add_child(bb_box)
	tabs.add_child(bbs)
	graph_view = GraphView.new()
	graph_view.name = "Task Graph"
	graph_view.ed = self
	tabs.add_child(graph_view)
	debug_view = DebugView.new()
	debug_view.name = "Debugger"
	debug_view.ed = self
	tabs.add_child(debug_view)
	var ds := ScrollContainer.new()
	ds.custom_minimum_size.x = 380
	ds.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	details = VBoxContainer.new()
	details.size_flags_horizontal = SIZE_EXPAND_FILL
	ds.add_child(details)
	mid.add_child(ds)
	# --- 아래: 검사 결과 + 상태
	problems = ItemList.new()
	problems.custom_minimum_size.y = 90
	problems.item_clicked.connect(func(i, _p, _b): _goto_problem(i))
	root.add_child(problems)
	status = Label.new()
	status.text = "테바의 Compile 은 BT 검사·런타임 빌드입니다 (코드 컴파일 아님)."
	root.add_child(status)
	_fill_palette()


func _btn(parent: Control, text: String, tip: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.tooltip_text = tip
	b.pressed.connect(cb)
	parent.add_child(b)
	return b


func _fill_palette() -> void:
	palette.clear()
	var r := palette.create_item()
	if Assets.kind_of(cur()) == "task_graph":
		for cat in Graph.CATS:
			var gi := palette.create_item(r)
			gi.set_text(0, cat)
			gi.set_selectable(0, false)
			for k in Graph.NODES:
				if Graph.NODES[k].cat == cat:
					var it := palette.create_item(gi)
					it.set_text(0, Graph.NODES[k].title)
					it.set_metadata(0, "gnode:" + k)
					it.set_tooltip_text(0, "UE 대응: %s\n%s" % [Graph.NODES[k].ue, Graph.NODES[k].desc])
		return
	var dom := Assets.bt_domain(cur_bt())
	var groups := [["Composites", [["composite:Selector", "Selector  ? (OR)"], ["composite:Sequence", "Sequence  → (AND)"], ["composite:SimpleParallel", "Simple Parallel  ⇉"]]],
		["Tasks (%s)" % dom, Tasks.TASKS.keys().filter(func(k): return Assets.task_domain(k) in ["any", dom]).map(func(k): return ["task:" + k, k])],
		["Decorators", Assets.DECORATORS.keys().map(func(k): return ["decorator:" + k, "◇ " + k])],
		["Services", Tasks.SERVICES.keys().map(func(k): return ["service:" + k, "⟳ " + k])]]
	for g in groups:
		var gi := palette.create_item(r)
		gi.set_text(0, g[0])
		gi.set_selectable(0, false)
		for e in g[1]:
			var it := palette.create_item(gi)
			it.set_text(0, e[1])
			it.set_metadata(0, e[0])
			it.set_tooltip_text(0, _palette_tip(e[0]))


func _palette_tip(key: String) -> String:
	var p := key.split(":")
	match p[0]:
		"composite": return "UE 대응: %s\n%s" % KIND_HELP[p[1]]
		"task": return "UE 대응: %s\n%s" % [Tasks.TASKS[p[1]].ue, Tasks.TASKS[p[1]].desc]
		"decorator": return "UE 대응: %s\n%s" % [Assets.DECORATORS[p[1]].ue, Assets.DECORATORS[p[1]].desc]
		"service": return "UE 대응: %s\n%s" % [Tasks.SERVICES[p[1]].ue, Tasks.SERVICES[p[1]].desc]
	return ""


func _help_text() -> String:
	return """[b]읽는 순서[/b] (Unreal 과 같음): 위 Root → 왼쪽 자식이 먼저(카드 왼쪽 위 노란 숫자 = 순서) → 카드 위 파란 ◇ Decorator 가 모두 참이어야 들어감 → 보라 ▶ Task 실행.
[b]Selector[/b] = 왼쪽부터 시도, 하나 성공하면 끝 (우선순위 목록). [b]Sequence[/b] = 왼쪽부터 차례로, 하나 실패하면 끝.
[b]Observer Aborts[/b] (◇ 옆 ⤴): Self = 내 조건이 거짓이 되면 나를 중단 / Lower Priority = 내 조건이 참이 되면 오른쪽 것을 중단하고 나로 / Both = 둘 다.
[b]Service[/b] (초록 ⟳) = 그 분기가 실행 중인 동안만 정해진 초마다 Blackboard 를 갱신 (예: 시야 감지).
[b]조작[/b]: 카드 누르기 = 고르기 · 좌우로 끌기 = 순서 바꾸기 · 오른쪽 클릭 = 노드 찾아 넣기 · 휠 = 확대 · 가운데 버튼/빈 곳 끌기 = 이동 · F = 고른 카드로 · Delete = 지우기 · Ctrl+C/V = 복사·붙여넣기 · Ctrl+Z/Y.
[b]테바 전용[/b]: 'Compile' 은 검사 + data/ai.json 만들기. 초는 모두 실제 초(전투·대화·메뉴 중엔 멈춤). Blackboard Vector2 는 칸 좌표(2D)."""


# ================================================================ 자산
func reload_assets() -> void:
	assets = Assets.load_dir(dir)
	dirty.clear()
	_hist.clear()
	refresh_list()
	if current == "" or not assets.has(current):
		var bts := _ids_of("behavior_tree")
		current = ""
		if not bts.is_empty():
			open_asset(bts[0])
		else:
			_refresh_all()
	else:
		open_asset(current)


func _ids_of(kind: String) -> Array:
	var out := assets.keys().filter(func(i): return Assets.kind_of(assets[i]) == kind)
	out.sort()
	return out


func refresh_list() -> void:
	_listing = true
	asset_tree.clear()
	var r := asset_tree.create_item()
	for g in [["behavior_tree", "Behavior Tree (BT_)"], ["blackboard", "Blackboard (BB_)"], ["task_graph", "Task Graph (BTT_)"]]:
		var gi := asset_tree.create_item(r)
		gi.set_text(0, g[1])
		gi.set_selectable(0, false)
		for id in _ids_of(g[0]):
			var it := asset_tree.create_item(gi)
			it.set_text(0, ("● " if dirty.has(id) else "") + id)
			it.set_metadata(0, id)
			it.set_tooltip_text(0, str(assets[id].get("description", "")))
			if id == current:
				it.select(0)
	_listing = false


func open_asset(id: String) -> void:
	if not assets.has(id):
		return
	current = id
	match Assets.kind_of(assets[id]):
		"behavior_tree":
			selected = str(assets[id].get("root_id", ""))
			tabs.current_tab = TAB_BT
			canvas.set_tree(assets[id])
			canvas.selected = selected
			canvas.breakpoints = breakpoints_of(id)
		"blackboard":
			selected = ""
			tabs.current_tab = TAB_BB
		"task_graph":
			selected = ""
			tabs.current_tab = TAB_GRAPH
			graph_view.selected = ""
			graph_view.set_graph(assets[id], _back_to)
	_fill_palette()
	_refresh_all()
	if debug_view:
		debug_view._highlight()   # 디버거: 이 BT 를 쓰는 몬스터를 고르고 있으면 카드에 실행 경로


## Task Graph 에서 ◀ 돌아가기 → 그 그래프를 연 BT, 그 Task 카드
func go_back() -> void:
	var to := _back_to
	var task := ""
	for n in assets.get(to, {}).get("nodes", []):
		if str(n.get("params", {}).get("graph_id", "")) == current:
			task = str(n.id)
	_back_to = ""
	open_asset(to)
	if task != "":
		_select(task, true)


func cur() -> Dictionary:
	return assets.get(current, {})


func cur_bt() -> Dictionary:
	var a := cur()
	return a if Assets.kind_of(a) == "behavior_tree" else {}


## 지금 보이는 Blackboard (BT 면 그 트리의 BB, BB 면 그 자신)
func cur_bb() -> Dictionary:
	var a := cur()
	if Assets.kind_of(a) == "blackboard":
		return a
	return assets.get(str(a.get("blackboard_id", "")), {})


func node(id: String) -> Dictionary:
	for n in cur_bt().get("nodes", []):
		if str(n.id) == id:
			return n
	return {}


func parent_of(id: String) -> String:
	for n in cur_bt().get("nodes", []):
		if id in n.get("children", []):
			return str(n.id)
	return ""


func _refresh_all() -> void:
	refresh_list()
	canvas.relayout()
	_validate_current()
	_build_details()
	_build_bb()


func _changed() -> void:
	dirty[current] = true
	_refresh_all()


## 바꾸기 전에 부른다 — 실행 취소용 스냅샷 (같은 key 로 이어지는 입력은 한 번만)
func _touch(key := "") -> void:
	if current == "":
		return
	if not _hist.has(current):
		_hist[current] = {"undo": [], "redo": [], "key": ""}
	var h: Dictionary = _hist[current]
	if key == "" or key != h.key:
		h.undo.append(assets[current].duplicate(true))
		if h.undo.size() > 100:
			h.undo.pop_front()
		h.redo.clear()
	h.key = key


func undo() -> void:
	var h: Dictionary = _hist.get(current, {})
	if h.is_empty() or h.undo.is_empty():
		_status("되돌릴 것이 없음")
		return
	h.redo.append(assets[current].duplicate(true))
	assets[current] = h.undo.pop_back()
	h.key = ""
	_after_history()


func redo() -> void:
	var h: Dictionary = _hist.get(current, {})
	if h.is_empty() or h.redo.is_empty():
		_status("다시 할 것이 없음")
		return
	h.undo.append(assets[current].duplicate(true))
	assets[current] = h.redo.pop_back()
	h.key = ""
	_after_history()


func _after_history() -> void:
	dirty[current] = true
	if Assets.kind_of(assets[current]) == "behavior_tree":
		canvas.set_tree(assets[current])
		if node(selected).is_empty():
			selected = str(assets[current].get("root_id", ""))
		canvas.selected = selected
	elif Assets.kind_of(assets[current]) == "task_graph":
		graph_view.set_graph(assets[current], _back_to)
	_refresh_all()


func save() -> bool:
	var ok := true
	for id in dirty.keys():
		var f := FileAccess.open(dir + id + ".json", FileAccess.WRITE)
		if f == null:
			_status("⛔ 저장 실패: %s (%s)" % [id, error_string(FileAccess.get_open_error())])
			ok = false
			continue
		f.store_string(JSON.stringify(assets[id], " ", false) + "\n")
		f.close()
		dirty.erase(id)
	if ok:
		_status("저장함")
	refresh_list()
	if Engine.is_editor_hint():
		EditorInterface.get_resource_filesystem().scan()
	return ok


## 게임이 보낸 BT 몬스터 상태 (ai_debugger_plugin → 여기 → Debugger 탭)
func on_snapshot(data: Dictionary) -> void:
	debug_view.on_snapshot(data)


func on_session_stopped() -> void:
	debug_view.on_session_stopped()


# ---------------------------------------------------------------- 디버거 연결 (브레이크포인트·일시정지)
var debugger: EditorDebuggerPlugin = null   # plugin.gd 가 넣음 (테스트에서는 없음)
var breakpoints := {}           # bt id -> {node id: true}
var sent: Array = []            # 테스트용: 게임으로 보낸 메시지 기록


func breakpoints_of(bt_id: String) -> Dictionary:
	return breakpoints.get(bt_id, {})


func toggle_breakpoint(id: String) -> void:
	if not breakpoints.has(current):
		breakpoints[current] = {}
	if breakpoints[current].has(id):
		breakpoints[current].erase(id)
	else:
		breakpoints[current][id] = true
	canvas.breakpoints = breakpoints[current]
	canvas.queue_redraw()
	send_breakpoints()
	_build_details()


func send_breakpoints() -> void:
	var out := {}
	for bt in breakpoints:
		out[bt] = breakpoints[bt].keys()
	send_to_game("monster_ai:breakpoints", [out])


## 실행 중인 게임으로 (Godot 디버거 세션). 게임이 없으면 아무것도 안 함
func send_to_game(message: String, data: Array) -> void:
	sent.append([message, data])
	if debugger == null:
		return
	for s in debugger.get_sessions():
		if s.is_active():
			s.send_message(message, data)


func has_unsaved() -> bool:
	return not dirty.is_empty()


## Compile: 모든 자산 검사 → 오류가 없으면 data/ai.json
func compile() -> bool:
	var errs := Assets.compile(assets, out_path)
	problems.clear()
	_problem_nodes.clear()
	if errs.is_empty():
		_status("Compile 완료 → %s (검사 통과 %d 개 자산)" % [out_path, assets.size()])
		problems.add_item("✓ Compile 완료 — 오류 없음")
		_problem_nodes.append(["", ""])
		if Engine.is_editor_hint():
			EditorInterface.get_resource_filesystem().scan()
		return true
	for id in errs:
		for e in errs[id]:
			problems.add_item("⛔ %s · %s: %s" % [id, e.node, e.msg])
			_problem_nodes.append([id, e.node])
	_status("Compile 실패 — 오류 %d 개 (아래 목록을 누르면 그 노드로)" % problems.item_count)
	return false


func _validate_current() -> void:
	problems.clear()
	_problem_nodes.clear()
	var errs := Assets.validate(cur(), assets) if current != "" else []
	var by_node := {}
	for e in errs:
		problems.add_item("⛔ %s: %s" % [e.node, e.msg])
		_problem_nodes.append([current, e.node])
		by_node[e.node] = e.msg
	canvas.errors = by_node
	if errs.is_empty() and current != "":
		problems.add_item("✓ %s 검사 통과" % current)
		_problem_nodes.append(["", ""])


func _goto_problem(i: int) -> void:
	if i >= _problem_nodes.size() or _problem_nodes[i][0] == "":
		return
	if _problem_nodes[i][0] != current:
		open_asset(_problem_nodes[i][0])
	if Assets.kind_of(cur()) == "task_graph":
		graph_view.focus_node(_problem_nodes[i][1])
	elif not node(_problem_nodes[i][1]).is_empty():
		_select(_problem_nodes[i][1], true)


func _status(t: String) -> void:
	status.text = t


# ---------------------------------------------------------------- 새 자산
func _ask_new(kind: String, template := "") -> void:
	var dlg := ConfirmationDialog.new()
	dlg.title = "새 " + {"behavior_tree": "Behavior Tree", "blackboard": "Blackboard", "task_graph": "Task Graph"}[kind]
	var box := VBoxContainer.new()
	var le := LineEdit.new()
	le.text = PREFIX[kind]
	box.add_child(le)
	var bbo := OptionButton.new()
	if kind in ["behavior_tree", "task_graph"] and template == "":
		var l := Label.new()
		l.text = "Blackboard 자산"
		box.add_child(l)
		for b in _ids_of("blackboard"):
			bbo.add_item(b)
		box.add_child(bbo)
	dlg.add_child(box)
	dlg.confirmed.connect(func():
		var id := le.text.strip_edges()
		if kind == "behavior_tree":
			new_bt(id, bbo.get_item_text(bbo.selected) if bbo.item_count > 0 else "", template)
		elif kind == "task_graph":
			new_graph(id, bbo.get_item_text(bbo.selected) if bbo.item_count > 0 else "", template)
		else:
			new_bb(id)
		dlg.queue_free())
	dlg.canceled.connect(dlg.queue_free)
	add_child(dlg)
	dlg.popup_centered(Vector2i(420, 0))
	le.grab_focus.call_deferred()
	le.caret_column = le.text.length()


func _id_ok(id: String, kind: String) -> bool:
	if not id.begins_with(PREFIX[kind]) or not RegEx.create_from_string("^[A-Za-z0-9_]+$").search(id):
		_status("이름은 %s 로 시작, 영문·숫자·_ 만" % PREFIX[kind])
		return false
	if assets.has(id) or FileAccess.file_exists(dir + id + ".json"):
		_status("이미 있는 이름: " + id)
		return false
	return true


func new_bt(id: String, bb_id: String, template := "") -> bool:
	if not _id_ok(id, "behavior_tree"):
		return false
	var a: Dictionary
	if template != "" and assets.has(template):
		a = assets[template].duplicate(true)
		a.id = id
	else:
		a = {"schema_version": Assets.SCHEMA, "asset_type": "behavior_tree", "id": id, "domain": "field", "blackboard_id": bb_id,
			"battle_on_contact": true,
			"root_id": "root", "nodes": [{"id": "root", "kind": "Root", "children": ["selector_1"]},
				{"id": "selector_1", "kind": "Selector", "name": "AI Root", "children": []}], "editor_layout": {}}
	assets[id] = a
	dirty[id] = true
	open_asset(id)
	_status("새 Behavior Tree: " + id)
	return true


## 새 Task Graph: Receive Execute AI → Finish Execute(성공) 로 바로 검사를 통과하는 모양에서 시작
func new_graph(id: String, bb_id: String, template := "") -> bool:
	if not _id_ok(id, "task_graph"):
		return false
	var a: Dictionary
	if template != "" and assets.has(template):
		a = assets[template].duplicate(true)
		a.id = id
	else:
		a = {"schema_version": Assets.SCHEMA, "asset_type": "task_graph", "id": id, "blackboard_id": bb_id, "variables": [],
			"nodes": [{"id": "evt_execute", "type": "ReceiveExecuteAI", "pos": [0, 0]},
				{"id": "finish", "type": "FinishExecute", "params": {"success": true}, "pos": [320, 0]},
				{"id": "evt_abort", "type": "ReceiveAbortAI", "pos": [0, 200]},
				{"id": "stop", "type": "StopMovement", "pos": [320, 200]},
				{"id": "finish_abort", "type": "FinishAbort", "pos": [600, 200]}],
			"connections": [{"from_node": "evt_execute", "from_pin": "exec_out", "to_node": "finish", "to_pin": "exec_in"},
				{"from_node": "evt_abort", "from_pin": "exec_out", "to_node": "stop", "to_pin": "exec_in"},
				{"from_node": "stop", "from_pin": "exec_out", "to_node": "finish_abort", "to_pin": "exec_in"}]}
	assets[id] = a
	dirty[id] = true
	_back_to = ""
	open_asset(id)
	_status("새 Task Graph: %s — BT 의 Task 종류 'TaskGraph' 로 쓰세요" % id)
	return true


func new_bb(id: String) -> bool:
	if not _id_ok(id, "blackboard"):
		return false
	assets[id] = {"schema_version": Assets.SCHEMA, "asset_type": "blackboard", "id": id, "keys": [
		{"name": "TargetActor", "type": "entity_ref", "default": null},
		{"name": "HasLineOfSight", "type": "bool", "default": false}]}
	dirty[id] = true
	open_asset(id)
	_status("새 Blackboard: " + id)
	return true


# ================================================================ BT 노드 편집
func _select(id: String, focus: bool) -> void:
	selected = id
	canvas.selected = id
	if focus:
		canvas.focus_node(id)
	canvas.queue_redraw()
	_build_details()


func _activate(id: String) -> void:
	var n := node(id)
	if str(n.get("task_type", "")) == "TaskGraph":
		var g := str(n.get("params", {}).get("graph_id", ""))
		if assets.has(g):
			_back_to = current
			open_asset(g)
			return
	_select(id, true)


func _new_id(base: String) -> String:
	var used := {}
	for n in cur_bt().get("nodes", []):
		used[str(n.id)] = true
	var i := 1
	while used.has("%s_%d" % [base, i]):
		i += 1
	return "%s_%d" % [base, i]


## 고른 노드(또는 그 부모)에 팔레트 항목 넣기
func add_from_palette(key: String, target := "") -> String:
	if cur_bt().is_empty() and not key.begins_with("gnode:"):
		_status("Behavior Tree 를 먼저 여세요")
		return ""
	if target == "":
		target = selected
	var p := key.split(":")
	match p[0]:
		"gnode": return graph_view.add_node(p[1], graph_view._view_center())
		"composite": return add_node(target, p[1], "")
		"task": return add_node(target, "Task", p[1])
		"decorator": return target if add_decorator(target, p[1]) else ""
		"service": return target if add_service(target, p[1]) else ""
	return ""


## parent 의 마지막 자식으로 새 노드. parent 가 Task 면 그 부모에 (Task 바로 오른쪽)
func add_node(parent: String, kind: String, task_type: String) -> String:
	var pn := node(parent)
	var at := -1
	if pn.is_empty():
		_status("노드를 먼저 고르세요")
		return ""
	if str(pn.kind) == "Task":
		var pp := parent_of(parent)
		at = node(pp).children.find(parent) + 1
		parent = pp
		pn = node(pp)
	if str(pn.kind) == "Root" and not pn.get("children", []).is_empty():
		_status("Root 의 자식은 하나뿐입니다 — 그 아래 Selector/Sequence 에 넣으세요")
		return ""
	if str(pn.kind) == "Root" and kind == "Task":
		_status("Root 바로 아래에는 Selector 나 Sequence")
		return ""
	_touch()
	var id := _new_id(task_type.to_snake_case() if kind == "Task" else kind.to_lower())
	var n := {"id": id, "kind": kind, "name": "", "children": []}
	if kind == "Task":
		n.erase("children")
		n.task_type = task_type
		n.params = default_params(task_type)
	if kind == "SimpleParallel":
		n.finish_mode = "Immediate"
	cur_bt().nodes.append(n)
	if not pn.has("children"):
		pn.children = []
	if at >= 0:
		pn.children.insert(at, id)
	else:
		pn.children.append(id)
	_changed()
	_select(id, false)
	return id


static func default_params(task_type: String) -> Dictionary:
	var p := {}
	for spec in Tasks.TASKS.get(task_type, {}).get("params", []):
		if spec[2] != null and str(spec[2]) != "":
			p[spec[0]] = spec[2]
	return p


func delete_node(id: String) -> void:
	var n := node(id)
	if n.is_empty() or str(n.kind) == "Root":
		_status("Root 는 지울 수 없음")
		return
	_touch()
	var gone := {}
	var todo := [id]
	while not todo.is_empty():
		var x: String = todo.pop_back()
		gone[x] = true
		for c in node(x).get("children", []):
			todo.append(str(c))
	var p := parent_of(id)
	if p != "":
		node(p).children.erase(id)
	cur_bt().nodes = cur_bt().nodes.filter(func(m): return not gone.has(str(m.id)))
	selected = p
	canvas.selected = p
	_changed()
	_status("지움: %s (아래 %d 개 포함)" % [id, gone.size()])


## 형제 사이 순서 바꾸기 (children 순서 = 우선순위)
func move_node(id: String, to: int) -> void:
	var p := parent_of(id)
	if p == "":
		return
	var kids: Array = node(p).children
	var from := kids.find(id)
	to = clampi(to, 0, kids.size() - 1)
	if from == to:
		return
	_touch()
	kids.remove_at(from)
	kids.insert(to, id)
	_changed()
	_status("%s → %d 번째 (왼쪽일수록 먼저)" % [id, to])


func add_decorator(id: String, type: String) -> bool:
	var n := node(id)
	if n.is_empty() or str(n.kind) == "Root":
		_status("Decorator 는 Composite·Task 에 붙입니다 (Root 제외)")
		return false
	_touch()
	var d := {"type": type, "observer_aborts": "None"}
	if type == "Blackboard":
		var keys: Array = cur_bb().get("keys", [])
		d.key = str(keys[0].name) if not keys.is_empty() else ""
		d.operator = "is_set"
	else:
		d.seconds = 1.0
	if not n.has("decorators"):
		n.decorators = []
	n.decorators.append(d)
	_changed()
	return true


func add_service(id: String, type: String) -> bool:
	var n := node(id)
	if n.is_empty() or str(n.kind) == "Root":
		_status("Service 는 Composite·Task 에 붙입니다 (Root 제외)")
		return false
	_touch()
	if not n.has("services"):
		n.services = []
	n.services.append({"type": type, "interval": 0.5, "random_deviation": 0.0, "run_on_activation": true})
	_changed()
	return true


func copy_selected() -> void:
	var n := node(selected)
	if n.is_empty() or str(n.kind) == "Root":
		return
	var list := []
	var todo := [selected]
	while not todo.is_empty():
		var x: String = todo.pop_front()
		list.append(node(x).duplicate(true))
		for c in node(x).get("children", []):
			todo.append(str(c))
	_clip = {"root": selected, "nodes": list}
	_status("복사: %s (%d 개)" % [selected, list.size()])


func paste() -> String:
	if _clip.is_empty() or cur_bt().is_empty():
		return ""
	var target := selected
	var tn := node(target)
	if tn.is_empty():
		return ""
	_touch()
	var at := -1
	if str(tn.kind) == "Task":
		at = node(parent_of(target)).children.find(target) + 1
		target = parent_of(target)
		tn = node(target)
	if str(tn.kind) == "Root" and not tn.children.is_empty():
		_status("Root 의 자식은 하나뿐입니다")
		return ""
	var ren := {}
	for n in _clip.nodes:
		ren[str(n.id)] = _new_id(str(n.id).rstrip("0123456789").trim_suffix("_"))
		cur_bt().nodes.append({"id": ren[str(n.id)]})   # 자리 맡기 (다음 새 ID 가 겹치지 않게)
	cur_bt().nodes = cur_bt().nodes.filter(func(m): return m.size() > 1)
	for n in _clip.nodes:
		var c: Dictionary = n.duplicate(true)
		c.id = ren[str(n.id)]
		if c.has("children"):
			c.children = c.children.map(func(k): return ren.get(str(k), str(k)))
		cur_bt().nodes.append(c)
	var new_root: String = ren[_clip.root]
	if at >= 0:
		tn.children.insert(at, new_root)
	else:
		tn.children.append(new_root)
	_changed()
	_select(new_root, true)
	_status("붙여넣기: %s" % new_root)
	return new_root


func find_node(text: String) -> void:
	text = text.strip_edges().to_lower()
	if text == "":
		return
	var hits: Array = cur_bt().get("nodes", []).filter(func(n):
		return text in (str(n.id) + " " + str(n.get("name", "")) + " " + str(n.get("task_type", n.kind))).to_lower())
	if hits.is_empty():
		_status("찾을 수 없음: " + text)
		return
	var ids: Array = hits.map(func(n): return str(n.id))
	var i := (ids.find(selected) + 1) % ids.size()
	_select(ids[i], true)
	_status("찾기 %d/%d: %s" % [i + 1, ids.size(), ids[i]])


func _context_menu(screen_pos: Vector2, id: String) -> void:
	if cur_bt().is_empty():
		return
	var pop := PopupPanel.new()
	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(300, 360)
	var le := LineEdit.new()
	le.placeholder_text = "노드 찾기 (예: MoveTo, Blackboard, Selector)"
	box.add_child(le)
	var list := ItemList.new()
	list.size_flags_vertical = SIZE_EXPAND_FILL
	box.add_child(list)
	pop.add_child(box)
	var all := []
	for k in ["composite:Selector", "composite:Sequence"]:
		all.append(k)
	for k in Tasks.TASKS:
		all.append("task:" + k)
	for k in Assets.DECORATORS:
		all.append("decorator:" + k)
	for k in Tasks.SERVICES:
		all.append("service:" + k)
	var fill := func(t: String):
		list.clear()
		for k in all:
			if t == "" or t.to_lower() in k.to_lower():
				list.add_item(k.replace("composite:", "").replace("task:", "Task: ").replace("decorator:", "◇ ").replace("service:", "⟳ "))
				list.set_item_metadata(list.item_count - 1, k)
				list.set_item_tooltip(list.item_count - 1, _palette_tip(k))
	fill.call("")
	le.text_changed.connect(fill)
	var target := id if id != "" else selected
	var pick := func(i):
		add_from_palette(list.get_item_metadata(i), target)
		pop.hide()
	list.item_activated.connect(pick)
	le.text_submitted.connect(func(_t):
		if list.item_count > 0:
			pick.call(0))
	pop.popup_hide.connect(pop.queue_free)
	add_child(pop)
	pop.popup(Rect2i(Vector2i(screen_pos), Vector2i(300, 360)))
	le.grab_focus.call_deferred()


func _shortcut_input(e: InputEvent) -> void:
	if not is_visible_in_tree() or not (e is InputEventKey) or not e.pressed or e.echo:
		return
	var f := get_viewport().gui_get_focus_owner()
	var typing := f is LineEdit or f is TextEdit or f is SpinBox
	if e.ctrl_pressed and e.keycode == KEY_S:
		save()
	elif typing:
		return
	elif e.ctrl_pressed and e.keycode == KEY_Z:
		undo()
	elif e.ctrl_pressed and e.keycode == KEY_Y:
		redo()
	elif e.ctrl_pressed and e.keycode == KEY_C and canvas.has_focus():
		copy_selected()
	elif e.ctrl_pressed and e.keycode == KEY_V and canvas.has_focus():
		paste()
	elif e.keycode == KEY_DELETE and canvas.has_focus():
		delete_node(selected)
	elif e.keycode == KEY_F and canvas.has_focus():
		canvas.focus_node(selected)
	elif e.keycode == KEY_F9 and canvas.has_focus() and selected != "" and node(selected).get("kind", "") != "Root":
		toggle_breakpoint(selected)
	else:
		return
	get_viewport().set_input_as_handled()


# ================================================================ Details
func _build_details() -> void:
	for c in details.get_children():
		details.remove_child(c)
		c.queue_free()
	var a := cur()
	if a.is_empty():
		return
	if Assets.kind_of(a) == "task_graph":
		graph_view.build_details(details)
		return
	if Assets.kind_of(a) == "blackboard":
		_head("Blackboard: " + current, "UE 대응: Blackboard Asset — 몬스터가 '지금 무엇을 알고 있는가'. 값은 몬스터마다 따로.")
		_note("가운데 'Blackboard' 탭에서 키를 편집합니다.")
		return
	if Assets.kind_of(a) != "behavior_tree":
		_head(current, "")
		return
	var n := node(selected)
	if n.is_empty():
		_note("노드를 고르세요")
		return
	var kind := str(n.kind)
	var id := str(n.id)
	if kind == "Task":
		var tt: Dictionary = Tasks.TASKS.get(str(n.get("task_type", "")), {})
		_head("Task: %s" % n.get("task_type", "?"), "UE 대응: %s\n%s" % [tt.get("ue", "?"), tt.get("desc", "")])
	else:
		_head(kind, "UE 대응: %s\n%s" % KIND_HELP[kind] if KIND_HELP.has(kind) else "")
	_note("ID: " + id)
	var parent := parent_of(id)
	if parent != "":
		_note("순서: %s 의 %d 번째 자식 (0 이 가장 먼저)" % [parent, node(parent).children.find(id)])
	_line_edit("이름", str(n.get("name", "")), func(t):
		_touch("name:" + id)
		n.name = t
		dirty[current] = true
		canvas.relayout()
		refresh_list())
	if kind == "Root":
		var bbs := _ids_of("blackboard")
		_option("Blackboard Asset", bbs.map(func(b): return [b, b]), str(cur_bt().get("blackboard_id", "")), func(v):
			_touch()
			cur_bt().blackboard_id = v
			_changed())
		var dom := Assets.bt_domain(cur_bt())
		_option("쓰는 곳 (domain)", [["field", "field — 탐험 필드에서 움직임"], ["battle", "battle — 턴제 전투에서 공격 고르기 (npc.xlsx Npcs battle_bt)"]], dom, func(v):
			_touch()
			cur_bt().domain = v
			_fill_palette()
			_changed())
		if dom == "battle":
			_note("전투 BT: 적 차례마다 처음부터 한 바퀴 → UseAttack / UseRandomAttack 이 고른 공격. 아무것도 못 고르면 가중치. Blackboard 에 전투가 SelfHpRatio·PlayerHpRatio·Turn·Self_<부위>_Broken·Player_<부위>_Broken 을 씀 (있는 키만).")
			return
		var touch := CheckBox.new()
		touch.text = "닿으면 바로 전투 (테바 전용)"
		touch.tooltip_text = "켜면 이 BT 를 쓰는 몬스터에 플레이어가 닿는 순간 전투 (예전 AI 처럼).
끄면 트리의 EnterTurnBattle Task 가 실행될 때만 전투.
둘 다 있어도 전투는 한 번만 시작됩니다. (Unreal 에는 없는 테바 규칙)"
		touch.button_pressed = bool(cur_bt().get("battle_on_contact", true))
		touch.toggled.connect(func(v):
			_touch()
			cur_bt().battle_on_contact = v
			_changed())
		details.add_child(touch)
	if kind == "SimpleParallel":
		_option("Finish Mode", [["Immediate", "Immediate — 주 Task 가 끝나면 배경 바로 중단"], ["Delayed", "Delayed — 배경이 지금 바퀴를 마칠 때까지 기다림"]],
			str(n.get("finish_mode", "Immediate")), func(v):
				_touch()
				n.finish_mode = v
				_changed())
		_note("자식 0 '주' = 주 Task (Task 만), 1 '배' = 배경 분기 (주 Task 가 도는 동안 반복)")
	if kind == "Task":
		var dom2 := Assets.bt_domain(cur_bt())
		var types := Tasks.TASKS.keys().filter(func(k): return Assets.task_domain(k) in ["any", dom2]).map(func(k): return [k, k])
		_option("Task 종류", types, str(n.task_type), func(v):
			_touch()
			n.task_type = v
			n.params = default_params(v)
			_changed())
		_task_params(n)
	if kind != "Root":
		var row := HBoxContainer.new()
		_btn(row, "◀ 왼쪽(먼저)", "형제 사이에서 앞으로", func(): move_node(id, node(parent).children.find(id) - 1))
		_btn(row, "오른쪽 ▶", "형제 사이에서 뒤로", func(): move_node(id, node(parent).children.find(id) + 1))
		_btn(row, "복사", "Ctrl+C", copy_selected)
		_btn(row, "지우기", "Delete (아래 노드 포함)", func(): delete_node(id))
		details.add_child(row)
		var bp := Button.new()
		bp.text = ("● 브레이크포인트 끄기" if breakpoints_of(current).has(id) else "○ 브레이크포인트") + " (F9)"
		bp.tooltip_text = "게임을 실행하는 동안 이 노드에 들어가면 모든 몬스터가 멈춤 (Debugger 탭의 재개·한 단계)"
		bp.pressed.connect(func(): toggle_breakpoint(id))
		details.add_child(bp)
	if kind in ["Root", "Selector", "Sequence", "SimpleParallel"]:
		var add := MenuButton.new()
		add.text = "＋ 자식 넣기 ▾"
		var pm := add.get_popup()
		var dom3 := Assets.bt_domain(cur_bt())
		var keys := ["composite:Selector", "composite:Sequence", "composite:SimpleParallel"] + Tasks.TASKS.keys().filter(func(k): return Assets.task_domain(k) in ["any", dom3]).map(func(k): return "task:" + k)
		for i in keys.size():
			pm.add_item(keys[i].replace("composite:", "").replace("task:", "Task: "), i)
		pm.id_pressed.connect(func(i): add_from_palette(keys[i], id))
		details.add_child(add)
	if kind == "Root":
		return
	# Decorators
	_section("◇ Decorators (모두 참이어야 들어감 — AND)")
	var ds: Array = n.get("decorators", [])
	for i in ds.size():
		_decorator_box(n, ds, i)
	var addd := MenuButton.new()
	addd.text = "＋ Decorator ▾"
	for k in Assets.DECORATORS:
		addd.get_popup().add_item(k)
	addd.get_popup().index_pressed.connect(func(i): add_decorator(id, Assets.DECORATORS.keys()[i]))
	details.add_child(addd)
	# Services (전투 BT 는 없음 — 차례마다 한 번에 판정)
	if Assets.bt_domain(cur_bt()) == "battle":
		return
	_section("⟳ Services (이 분기가 실행 중인 동안만, 정해진 초마다)")
	var ss: Array = n.get("services", [])
	for i in ss.size():
		_service_box(n, ss, i)
	var adds := MenuButton.new()
	adds.text = "＋ Service ▾"
	for k in Tasks.SERVICES:
		adds.get_popup().add_item(k)
	adds.get_popup().index_pressed.connect(func(i): add_service(id, Tasks.SERVICES.keys()[i]))
	details.add_child(adds)


func _head(t: String, tip: String) -> void:
	var l := Label.new()
	l.text = t
	l.add_theme_font_size_override("font_size", 20)
	details.add_child(l)
	if tip != "":
		_note(tip)


func _note(t: String) -> void:
	var l := Label.new()
	l.text = t
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.modulate = Color(1, 1, 1, 0.7)
	details.add_child(l)


func _section(t: String) -> void:
	details.add_child(HSeparator.new())
	var l := Label.new()
	l.text = t
	details.add_child(l)


func _row(label: String, parent: Control = null) -> HBoxContainer:
	var row := HBoxContainer.new()
	var l := Label.new()
	l.text = label
	l.custom_minimum_size.x = 120
	row.add_child(l)
	(parent if parent else details).add_child(row)
	return row


func _line_edit(label: String, value: String, cb: Callable, parent: Control = null) -> LineEdit:
	var le := LineEdit.new()
	le.text = value
	le.size_flags_horizontal = SIZE_EXPAND_FILL
	le.text_changed.connect(cb)
	_row(label, parent).add_child(le)
	return le


func _option(label: String, items: Array, value: String, cb: Callable, parent: Control = null) -> OptionButton:
	var ob := OptionButton.new()
	ob.size_flags_horizontal = SIZE_EXPAND_FILL
	var found := false
	for it in items:
		ob.add_item(str(it[1]))
		ob.set_item_metadata(ob.item_count - 1, it[0])
		if str(it[0]) == value:
			ob.select(ob.item_count - 1)
			found = true
	if not found and value != "":
		ob.add_item("⚠ " + value)
		ob.set_item_metadata(ob.item_count - 1, value)
		ob.select(ob.item_count - 1)
	elif not found:
		ob.add_item("(고르기)")
		ob.set_item_metadata(ob.item_count - 1, "")
		ob.select(ob.item_count - 1)
	ob.item_selected.connect(func(i): cb.call(ob.get_item_metadata(i)))
	_row(label, parent).add_child(ob)
	return ob


## 타입에 맞는 값 칸 (bool·int·float·string·vector2·entity_ref)
func _value_editor(type: String, value: Variant, cb: Callable) -> Control:
	match type:
		"bool":
			var cb2 := CheckBox.new()
			cb2.button_pressed = bool(value) if value != null else false
			cb2.toggled.connect(cb)
			return cb2
		"int", "float":
			var sb := SpinBox.new()
			sb.step = 1.0 if type == "int" else 0.1
			sb.allow_greater = true
			sb.allow_lesser = true
			sb.min_value = -9999
			sb.max_value = 99999
			sb.value = float(value) if value != null else 0.0
			sb.value_changed.connect(func(v): cb.call(int(v) if type == "int" else v))
			return sb
		"vector2":
			var le := LineEdit.new()
			le.placeholder_text = "x, y (비우면 없음)"
			le.text = "" if value == null else ("%s, %s" % [value[0], value[1]] if value is Array else "%s, %s" % [value.x, value.y])
			le.text_changed.connect(func(t):
				var p: PackedStringArray = str(t).split(",")
				cb.call([float(p[0]), float(p[1])] if p.size() == 2 and p[0].strip_edges().is_valid_float() and p[1].strip_edges().is_valid_float() else null))
			return le
	var le2 := LineEdit.new()
	le2.text = "" if value == null else str(value)
	le2.editable = type != "entity_ref"
	le2.placeholder_text = "(런타임 전용)" if type == "entity_ref" else ""
	le2.text_changed.connect(cb)
	return le2


func _keys_of_types(types: Array) -> Array:
	var out := []
	for k in cur_bb().get("keys", []):
		if types.is_empty() or str(k.type) in types:
			out.append([str(k.name), "%s  (%s)" % [k.name, k.type]])
	return out


func _task_params(n: Dictionary) -> void:
	var specs: Array = Tasks.TASKS.get(str(n.task_type), {}).get("params", [])
	if specs.is_empty():
		_note("(설정할 값 없음)")
		return
	if not n.has("params"):
		n.params = {}
	var p: Dictionary = n.params
	for spec in specs:
		var name: String = spec[0]
		var kind: String = spec[1]
		var tip: String = spec[3]
		var set_v := func(v):
			_touch("param:%s:%s" % [n.id, name])
			if v == null or str(v) == "":
				p.erase(name)
			else:
				p[name] = v
			dirty[current] = true
			canvas.relayout()
			_validate_current()
			refresh_list()
		if kind.begins_with("key"):
			var types: Array = [] if kind == "key_any" else Array(kind.substr(4).split("|"))
			var ob := _option(name, [["", "(없음)"]] + _keys_of_types(types), str(p.get(name, "")), set_v)
			ob.tooltip_text = "Blackboard Key Selector — %s%s" % [tip, "" if types.is_empty() else " (타입: %s)" % "/".join(types)]
		elif kind == "number":
			var row := _row(name)
			var sb: Control = _value_editor("float", p.get(name, spec[2]), set_v)
			sb.tooltip_text = tip + ("  (실제 초 — 필드가 멈춘 동안은 안 흐름)" if "초" in tip else "")
			row.add_child(sb)
		elif kind == "bool":
			var row := _row(name)
			var c: Control = _value_editor("bool", p.get(name, spec[2]), set_v)
			c.tooltip_text = tip
			row.add_child(c)
		elif kind == "value":
			var t := cur_bb_key_type(str(p.get("key", "")))
			var row := _row(name)
			row.add_child(_value_editor(t if t != "" else "string", p.get(name), set_v))
		elif kind == "graph":
			_option(name, _ids_of("task_graph").map(func(g): return [g, g]), str(p.get(name, "")), set_v)
		elif kind == "bt":   # Run Behavior: 같은 Blackboard·같은 domain 의 다른 BT
			var same := _ids_of("behavior_tree").filter(_can_run_behavior)
			_option(name, same.map(func(b): return [b, b]), str(p.get(name, "")), set_v)
		elif kind == "attack":   # 전투 BT: NpcAttacks 의 공격 (data/enemies.json)
			var atks := Assets.attack_ids()
			_option(name, atks.keys().map(func(a): return [a, "%s  (%s)" % [atks[a], a]]), str(p.get(name, "")), set_v)


## Run Behavior 로 부를 수 있는 BT: 자기 말고, 같은 Blackboard·같은 domain
func _can_run_behavior(b: String) -> bool:
	return b != current and str(assets[b].get("blackboard_id", "")) == str(cur_bt().get("blackboard_id", "")) 		and Assets.bt_domain(assets[b]) == Assets.bt_domain(cur_bt())


func cur_bb_key_type(key: String) -> String:
	for k in cur_bb().get("keys", []):
		if str(k.name) == key:
			return str(k.type)
	return ""


func _decorator_box(n: Dictionary, ds: Array, i: int) -> void:
	var d: Dictionary = ds[i]
	var box := VBoxContainer.new()
	var panel := PanelContainer.new()
	panel.add_child(box)
	details.add_child(panel)
	var top := HBoxContainer.new()
	var t := Label.new()
	t.text = "◇ %d. %s" % [i + 1, d.get("type", "?")]
	t.tooltip_text = "UE 대응: %s\n%s" % [Assets.DECORATORS.get(str(d.type), {}).get("ue", "?"), Assets.DECORATORS.get(str(d.type), {}).get("desc", "")]
	t.mouse_filter = MOUSE_FILTER_PASS
	t.size_flags_horizontal = SIZE_EXPAND_FILL
	top.add_child(t)
	_btn(top, "✕", "이 Decorator 지우기", func():
		_touch()
		ds.remove_at(i)
		_changed())
	box.add_child(top)
	var key_of := "deco:%s:%d:" % [n.id, i]
	var upd := func(field: String, v):
		_touch(key_of + field)
		d[field] = v
		dirty[current] = true
		canvas.relayout()
		_validate_current()
		refresh_list()
	_line_edit("표시 이름", str(d.get("name", "")), func(v): upd.call("name", v), box)
	if str(d.type) == "Blackboard":
		_option("Key", _keys_of_types([]), str(d.get("key", "")), func(v):
			_touch()
			d.key = v
			_changed(), box)
		var kt := cur_bb_key_type(str(d.get("key", "")))
		var ops := ["is_set", "is_not_set", "==", "!="] + (["<", "<=", ">", ">="] if kt in ["int", "float"] else [])
		_option("조건", ops.map(func(o): return [o, OP_LABEL[o]]), str(d.get("operator", "is_set")), func(v):
			_touch()
			d.operator = v
			_changed(), box)
		if not str(d.get("operator", "is_set")) in ["is_set", "is_not_set"]:
			var row := _row("값", box)
			row.add_child(_value_editor(kt if kt != "" else "string", d.get("value"), func(v): upd.call("value", v)))
	elif str(d.type) == "Cooldown":
		var row := _row("초", box)
		row.add_child(_value_editor("float", d.get("seconds", 1.0), func(v): upd.call("seconds", v)))
	var inv := CheckBox.new()
	inv.text = "Inverse Condition (반대로)"
	inv.button_pressed = bool(d.get("inverse", false))
	inv.toggled.connect(func(v): upd.call("inverse", v))
	box.add_child(inv)
	if str(d.type) == "Blackboard":
		var ob := _option("Observer Aborts", ["None", "Self", "LowerPriority", "Both"].map(func(o): return [o, o]), str(d.get("observer_aborts", "None")), func(v):
			_touch()
			d.observer_aborts = v
			_changed(), box)
		ob.tooltip_text = "\n".join(ABORT_HELP.values())
		var help := Label.new()
		help.text = ABORT_HELP.get(str(d.get("observer_aborts", "None")), "")
		help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		help.modulate = Color(1, 1, 1, 0.6)
		box.add_child(help)


func _service_box(n: Dictionary, ss: Array, i: int) -> void:
	var s: Dictionary = ss[i]
	var box := VBoxContainer.new()
	var panel := PanelContainer.new()
	panel.add_child(box)
	details.add_child(panel)
	var top := HBoxContainer.new()
	var t := Label.new()
	t.text = "⟳ %d. %s" % [i + 1, s.get("type", "?")]
	t.tooltip_text = "UE 대응: %s\n%s" % [Tasks.SERVICES.get(str(s.type), {}).get("ue", "?"), Tasks.SERVICES.get(str(s.type), {}).get("desc", "")]
	t.mouse_filter = MOUSE_FILTER_PASS
	t.size_flags_horizontal = SIZE_EXPAND_FILL
	top.add_child(t)
	_btn(top, "✕", "이 Service 지우기", func():
		_touch()
		ss.remove_at(i)
		_changed())
	box.add_child(top)
	var key_of := "serv:%s:%d:" % [n.id, i]
	for f in [["interval", "주기 (실제 초)", "float"], ["random_deviation", "± 무작위 (초)", "float"], ["run_on_activation", "들어갈 때 바로 한 번", "bool"]]:
		var row := _row(f[1], box)
		var field: String = f[0]
		row.add_child(_value_editor(f[2], s.get(field, {"interval": 0.5, "random_deviation": 0.0, "run_on_activation": true}[field]), func(v):
			_touch(key_of + field)
			s[field] = v
			dirty[current] = true
			canvas.relayout()
			_validate_current()
			refresh_list()))


# ================================================================ Blackboard 탭
func _build_bb() -> void:
	for c in bb_box.get_children():
		bb_box.remove_child(c)
		c.queue_free()
	var bb := cur_bb()
	var title := Label.new()
	bb_box.add_child(title)
	if bb.is_empty():
		title.text = "이 트리의 Root 에서 Blackboard 자산을 고르세요."
		return
	var bb_id := str(bb.id)
	title.text = "Blackboard: %s   — 키 = 몬스터가 아는 것. 값은 몬스터마다 따로 (회차가 바뀌면 기본값으로)" % bb_id
	var head := HBoxContainer.new()
	for h in [["이름", 260], ["타입", 120], ["기본값", 180], ["개체별 override", 130], ["쓰는 곳", 80], ["", 40]]:
		var l := Label.new()
		l.text = h[0]
		l.custom_minimum_size.x = h[1]
		head.add_child(l)
	bb_box.add_child(head)
	var keys: Array = bb.get("keys", [])
	for i in keys.size():
		var k: Dictionary = keys[i]
		var row := HBoxContainer.new()
		var name_e := LineEdit.new()
		name_e.text = str(k.name)
		name_e.custom_minimum_size.x = 260
		name_e.tooltip_text = "이름을 바꾸면 이 키를 쓰는 Decorator·Task 를 찾아 함께 바꿀지 묻습니다 (Enter)"
		name_e.text_submitted.connect(func(t): rename_key(bb_id, str(k.name), t.strip_edges()))
		name_e.focus_exited.connect(func():
			if name_e.text.strip_edges() != str(k.name):
				rename_key(bb_id, str(k.name), name_e.text.strip_edges()))
		row.add_child(name_e)
		var tb := OptionButton.new()
		tb.custom_minimum_size.x = 120
		for t in Blackboard.TYPES:
			tb.add_item(t)
			if t == str(k.type):
				tb.select(tb.item_count - 1)
		tb.item_selected.connect(func(ti):
			_bb_edit(bb_id, func():
				k.type = Blackboard.TYPES[ti]
				k.default = null if k.type in ["vector2", "entity_ref"] else Blackboard.coerce(k.type, null)))
		row.add_child(tb)
		var dv := _value_editor(str(k.type), k.get("default"), func(v): _bb_edit(bb_id, func(): k.default = v, "bbdef:%s:%s" % [bb_id, k.name], false))
		dv.custom_minimum_size.x = 180
		row.add_child(dv)
		var ov := CheckBox.new()
		ov.button_pressed = bool(k.get("instance_override", false))
		ov.tooltip_text = "맵 에디터에서 몬스터마다 시작값을 다르게 줄 수 있음 (예: 시야 거리)"
		ov.custom_minimum_size.x = 130
		ov.toggled.connect(func(v): _bb_edit(bb_id, func(): k.instance_override = v, "", false))
		row.add_child(ov)
		var refs := key_refs(bb_id, str(k.name))
		var rl := Label.new()
		rl.text = str(refs.size())
		rl.tooltip_text = "\n".join(refs) if not refs.is_empty() else "쓰는 곳 없음"
		rl.mouse_filter = MOUSE_FILTER_PASS
		rl.custom_minimum_size.x = 80
		row.add_child(rl)
		_btn(row, "✕", "키 지우기 (쓰는 곳이 있으면 못 지움)", func(): delete_key(bb_id, str(k.name)))
		bb_box.add_child(row)
	_btn(bb_box, "＋ 키", "새 키", func(): add_key(bb_id))


## Blackboard 자산 고치기 (지금 연 자산이 BT 여도 그 BB 를 고친다)
func _bb_edit(bb_id: String, fn: Callable, key := "", rebuild := true) -> void:
	var keep := current
	current = bb_id
	_touch(key)
	fn.call()
	dirty[bb_id] = true
	current = keep
	if rebuild:
		_refresh_all()
	else:
		_validate_current()
		refresh_list()


func add_key(bb_id: String) -> void:
	var bb: Dictionary = assets[bb_id]
	var names: Array = bb.keys.map(func(k): return str(k.name))
	var i := 1
	while names.has("NewKey%d" % i):
		i += 1
	_bb_edit(bb_id, func(): bb.keys.append({"name": "NewKey%d" % i, "type": "bool", "default": false}))


## 이 BB 의 키를 쓰는 곳 ["BT_x / node (Decorator)", …]
func key_refs(bb_id: String, key: String) -> Array:
	var out := []
	for id in _ids_of("behavior_tree"):
		var bt: Dictionary = assets[id]
		if str(bt.get("blackboard_id", "")) != bb_id:
			continue
		for n in bt.get("nodes", []):
			for d in n.get("decorators", []):
				if str(d.get("key", "")) == key:
					out.append("%s / %s (Decorator)" % [id, n.id])
			if str(n.get("kind", "")) == "Task":
				for spec in Tasks.TASKS.get(str(n.get("task_type", "")), {}).get("params", []):
					if str(spec[1]).begins_with("key") and str(n.get("params", {}).get(spec[0], spec[2])) == key:   # 비어 있으면 기본값을 씀
						out.append("%s / %s (Task %s)" % [id, n.id, spec[0]])
	for id in _ids_of("task_graph"):
		if str(assets[id].get("blackboard_id", "")) != bb_id:
			continue
		for n in assets[id].get("nodes", []):
			if str(n.get("params", {}).get("key", "")) == key:
				out.append("%s / %s (%s)" % [id, n.id, n.type])
	return out


func delete_key(bb_id: String, key: String) -> void:
	var refs := key_refs(bb_id, key)
	if not refs.is_empty():
		_status("⛔ '%s' 는 %d 곳에서 씁니다 — 먼저 바꾸세요: %s" % [key, refs.size(), ", ".join(refs)])
		return
	var bb: Dictionary = assets[bb_id]
	_bb_edit(bb_id, func(): bb.keys = bb.keys.filter(func(k): return str(k.name) != key))


## 키 이름 바꾸기: 쓰는 곳이 있으면 묻고 모두 함께 바꾼다
func rename_key(bb_id: String, old: String, new_name: String, confirm := true) -> bool:
	if new_name == old or new_name == "":
		return false
	if not RegEx.create_from_string("^[A-Za-z_][A-Za-z0-9_]*$").search(new_name):
		_status("키 이름은 영문·숫자·_")
		_build_bb()
		return false
	var bb: Dictionary = assets[bb_id]
	if bb.keys.any(func(k): return str(k.name) == new_name):
		_status("이미 있는 키: " + new_name)
		_build_bb()
		return false
	var refs := key_refs(bb_id, old)
	if refs.is_empty() or not confirm:
		_do_rename(bb_id, old, new_name)
		return true
	var dlg := ConfirmationDialog.new()
	dlg.title = "키 이름 바꾸기"
	dlg.dialog_text = "'%s' 를 쓰는 곳 %d 개도 '%s' 로 함께 바꿉니다:\n%s" % [old, refs.size(), new_name, "\n".join(refs)]
	dlg.confirmed.connect(func():
		_do_rename(bb_id, old, new_name)
		dlg.queue_free())
	dlg.canceled.connect(func():
		_build_bb()
		dlg.queue_free())
	add_child(dlg)
	dlg.popup_centered()
	return true


func _do_rename(bb_id: String, old: String, new_name: String) -> void:
	var touched := []
	for id in _ids_of("behavior_tree"):
		var bt: Dictionary = assets[id]
		if str(bt.get("blackboard_id", "")) != bb_id:
			continue
		var hit := false
		for n in bt.get("nodes", []):
			for d in n.get("decorators", []):
				if str(d.get("key", "")) == old:
					d.key = new_name
					hit = true
			if str(n.get("kind", "")) == "Task":
				for spec in Tasks.TASKS.get(str(n.get("task_type", "")), {}).get("params", []):
					if str(spec[1]).begins_with("key") and str(n.get("params", {}).get(spec[0], spec[2])) == old:
						if not n.has("params"):
							n.params = {}
						n.params[spec[0]] = new_name
						hit = true
		if hit:
			dirty[id] = true
			touched.append(id)
	for id in _ids_of("task_graph"):
		if str(assets[id].get("blackboard_id", "")) != bb_id:
			continue
		var hit := false
		for n in assets[id].get("nodes", []):
			if str(n.get("params", {}).get("key", "")) == old:
				n.params.key = new_name
				hit = true
		if hit:
			dirty[id] = true
			touched.append(id)
	var bb: Dictionary = assets[bb_id]
	_bb_edit(bb_id, func():
		for k in bb.keys:
			if str(k.name) == old:
				k.name = new_name)
	_status("키 이름 바꿈: %s → %s%s" % [old, new_name, "" if touched.is_empty() else " (함께 바꾼 트리: %s)" % ", ".join(touched)])
