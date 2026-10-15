@tool
extends VBoxContainer
## 대화 에디터 (Godot 에디터의 '대화' 탭). tools/dialogues/<대화ID>.json 을 편집한다.
## "대본을 쓰고 노드로 흐름을 설계하는 에디터" (대화 에디터 기획 v1.0):
##   왼쪽  — 대화 목록 · 찾기(모든 대화) · 카드 만들기(끌어다 놓기)
##   가운데 — 위: 흐름 그래프 (대본 블록·조건 분기·효과·끝 카드, 선택지 요약)  /  아래: 대본 칸 (고른 블록의 페이지들)
##   오른쪽 — 고른 카드·선택지의 세부 (기본 / 조건 / 결과 / 고급, 접기)
##   아래  — 검사 결과 (오류·경고, 누르면 그 카드·페이지로)
## 연결선은 데이터(next_node 등)를 따른다: 연결/끊기 → 데이터 수정 → 다시 그림 (_sync_connections).
## 실행 취소는 대화 전체 스냅샷 (_touch 에서 쌓음). 게임 실행 중(테스트)에서도 열 수 있게 에디터 전용 기능은 Engine.is_editor_hint() 로 감싼다.

const Card = preload("res://addons/dialogue_editor/dialogue_card.gd")
const FuncCard = preload("res://addons/dialogue_editor/func_card.gd")
const StartCard = preload("res://addons/dialogue_editor/start_card.gd")
const DirectCard = preload("res://addons/dialogue_editor/direct_card.gd")
const ScriptPanel = preload("res://addons/dialogue_editor/script_panel.gd")
const ScriptPages = preload("res://core/script_pages.gd")
const ExprRows = preload("res://addons/expr_rows.gd")
const ToolCommon = preload("res://addons/tool_common.gd")
## 카드 만들기 메뉴 / 왼쪽 팔레트 / 그래프 오른쪽 클릭
const ADD_MENU := [
	["start", "▶ 대화 시작 — 말을 걸면 여기서 시작, 조건에 따라 첫 길을 고름 (대화마다 하나)"],
	["line", "📝 대본 블록 — 대사·상황 묘사·시스템 메시지 (여러 페이지)"],
	["branch", "◇ 조건 분기 — 조건에 따라 길이 갈림"],
	["effect", "⚙ 효과 — 아이템·플래그·생존 수치 등을 바꿈"],
	["direct", "🎬 연출 — 그림 띄우기·페이드·흔들기, 필드에서 걷기·카메라 (컷신)"],
	["ending", "■ 엔딩 — 1단계 에피소드 대화의 끝"],
]
const PALETTE := [["start", "▶ 대화 시작"], ["line", "📝 대본 블록"], ["branch", "◇ 조건 분기"], ["effect", "⚙ 효과"], ["direct", "🎬 연출"], ["ending", "■ 엔딩"]]

const DIALOGUE_DIR := "res://tools/dialogues/"
const EXIT_NAME := "__EXIT__"
const END_PREFIX := "__END__"
const PREVIEW_FILE := "user://dialogue_preview.json"
const UNDO_LIMIT := 200

var dir := DIALOGUE_DIR              # 테스트에서 바꿔 쓴다
var dialogue := {}                   # 열린 대화 { dialogue_id, episode_id, text_speed, nodes, choices }
var path := ""
var dirty := false

var graph: GraphEdit
var files: OptionButton
var file_list: ItemList
var search: LineEdit
var results: ItemList
var status: Label
var inspector: VBoxContainer
var script_panel: VBoxContainer
var log_view: TextEdit
var problems: ItemList
var check_box: VBoxContainer
var check_head: Label
var speakers: Array = []             # [[char_id, name]]
var abilities: Array = []            # [[ability_id, name]]
var enemies: Array = []              # [[enemy_id, name]] (전투 선택지)
var lookups := {}                    # 조건·효과 고르기·갈 곳 목록 (ToolCommon.load_lookups)
var _known_nodes := {}               # 변환된 데이터에 있는 node_id (다른 대화·엑셀로 가는 연결 확인용)
var _selected_card: GraphNode
var _counter := 0
var _box: VBoxContainer              # 오른쪽 칸에서 지금 채우는 구역
var _graph_split: VSplitContainer
var _save_btn: Button
var _edit_menu: MenuButton
# 실행 취소
var _undo: Array = []
var _redo: Array = []
var _snap := {}
var _last_key := ""
var _quiet := false                  # 그래프를 다시 만드는 중 (변경으로 치지 않음)
var _clipboard: Array = []           # [{data, choices, pos}]


func _init() -> void:
	size_flags_vertical = SIZE_EXPAND_FILL
	size_flags_horizontal = SIZE_EXPAND_FILL
	# ---- 위 도구줄
	var bar := HBoxContainer.new()
	add_child(bar)
	files = OptionButton.new()
	files.custom_minimum_size.x = 200
	files.tooltip_text = "편집할 대화 (tools/dialogues/)"
	files.item_selected.connect(func(i): _request_open(files.get_item_text(i)))
	bar.add_child(files)
	_bar_btn(bar, "새 대화", _ask_new, "새 대화 파일을 만듭니다 (대화 ID: 영문·숫자·_)")
	_save_btn = _bar_btn(bar, "저장", save, "지금 대화를 파일로 저장 (Ctrl+S)")
	bar.add_child(VSeparator.new())
	_bar_btn(bar, "↶", undo, "실행 취소 (그래프에서 Ctrl+Z)")
	_bar_btn(bar, "↷", redo, "다시 실행 (그래프에서 Ctrl+Y)")
	var add_menu := MenuButton.new()
	add_menu.text = "＋ 카드 ▾"
	add_menu.tooltip_text = "카드 만들기. 왼쪽 '카드 만들기'에서 그래프로 끌어 놓거나, 그래프 빈 곳 오른쪽 클릭,\n연결점에서 빈 곳으로 선을 끌어 놓아도 됩니다"
	_fill_add_menu(add_menu.get_popup(), Callable())
	bar.add_child(add_menu)
	_edit_menu = MenuButton.new()
	_edit_menu.text = "편집 ▾"
	var pm := _edit_menu.get_popup()
	for it in [["복사  Ctrl+C", copy_selected], ["붙여넣기  Ctrl+V", paste], ["복제  Ctrl+D", duplicate_selected],
			["지우기  Delete", delete_selected], ["", Callable()], ["고른 카드 가운데로  F", center_selected],
			["자동 정렬", arrange], ["모든 대본 접기", fold_all.bind(true)], ["모든 대본 펼치기", fold_all.bind(false)]]:
		if it[0] == "":
			pm.add_separator()
		else:
			pm.add_item(it[0], pm.item_count)
			pm.set_item_metadata(pm.item_count - 1, it[1])
	pm.id_pressed.connect(func(i): pm.get_item_metadata(pm.get_item_index(i)).call())
	bar.add_child(_edit_menu)
	bar.add_child(VSeparator.new())
	_bar_btn(bar, "변환·검사", run_convert, "저장한 뒤 변환기를 돌려 오류·경고를 검사합니다.\n오류가 없어야 게임에 반영됩니다")
	_bar_btn(bar, "▶ 미리보기", func(): preview(), "고른 카드(대본 칸에서 고른 페이지)부터 실제 대화 화면으로 실행합니다")
	status = Label.new()
	status.size_flags_horizontal = SIZE_EXPAND_FILL
	status.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	status.clip_text = true
	bar.add_child(status)
	ToolCommon.add_help_window(self, bar, "대화 탭 쓰는 법", HELP_TEXT)
	# ---- 왼쪽 | 가운데(그래프 / 대본) | 오른쪽
	var outer := HSplitContainer.new()
	outer.size_flags_vertical = SIZE_EXPAND_FILL
	add_child(outer)
	outer.add_child(_build_left())
	var inner := HSplitContainer.new()
	inner.size_flags_horizontal = SIZE_EXPAND_FILL
	outer.add_child(inner)
	_graph_split = VSplitContainer.new()
	_graph_split.size_flags_horizontal = SIZE_EXPAND_FILL
	_graph_split.split_offset = 0   # 둘 다 늘어나므로 가운데에서 나뉨 (그래프 / 대본 반반)
	inner.add_child(_graph_split)
	graph = GraphEdit.new()
	graph.size_flags_vertical = SIZE_EXPAND_FILL
	graph.right_disconnects = true
	graph.minimap_enabled = true
	graph.panning_scheme = GraphEdit.SCROLL_ZOOMS   # 휠 = 확대·축소 (사용법 설명과 맞춤)
	graph.connection_request.connect(_on_connect)
	graph.disconnection_request.connect(_on_disconnect)
	graph.connection_to_empty.connect(_on_connect_empty)
	graph.delete_nodes_request.connect(_on_delete)
	graph.popup_request.connect(_on_graph_popup)
	graph.copy_nodes_request.connect(copy_selected)
	graph.paste_nodes_request.connect(paste)
	graph.duplicate_nodes_request.connect(duplicate_selected)
	graph.node_selected.connect(_on_node_selected)
	graph.gui_input.connect(_graph_keys)
	graph.set_drag_forwarding(Callable(), _graph_can_drop, _graph_drop)
	_graph_split.add_child(graph)
	script_panel = ScriptPanel.new()
	script_panel.changed.connect(func(key): _touch(key))
	script_panel.preview_requested.connect(func(card, page):
		_select(card)
		preview(page))
	script_panel.maximize_toggled.connect(func(on): graph.visible = not on)
	_graph_split.add_child(script_panel)
	var side := ScrollContainer.new()
	side.custom_minimum_size.x = 380
	side.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED   # 긴 글자는 칸 폭에 맞춰 줄임
	inner.add_child(side)
	inspector = VBoxContainer.new()
	inspector.size_flags_horizontal = SIZE_EXPAND_FILL
	side.add_child(inspector)
	_box = inspector
	# ---- 아래 검사 결과 (변환·검사 뒤에만)
	check_box = VBoxContainer.new()
	check_box.visible = false
	add_child(check_box)
	var head := HBoxContainer.new()
	check_box.add_child(head)
	check_head = Label.new()
	check_head.size_flags_horizontal = SIZE_EXPAND_FILL
	head.add_child(check_head)
	var raw := Button.new()
	raw.text = "원문"
	raw.toggle_mode = true
	raw.flat = true
	raw.tooltip_text = "변환기 출력 그대로 보기"
	raw.toggled.connect(func(on):
		log_view.visible = on
		problems.visible = not on)
	head.add_child(raw)
	var close := Button.new()
	close.text = "✕"
	close.flat = true
	close.tooltip_text = "검사 결과 닫기"
	close.pressed.connect(func(): check_box.visible = false)
	head.add_child(close)
	problems = ItemList.new()
	problems.custom_minimum_size.y = 120
	problems.item_clicked.connect(func(i, _p, _b):
		var m = problems.get_item_metadata(i)
		if m is Array:
			goto(m[0], m[1], m[2]))
	check_box.add_child(problems)
	log_view = TextEdit.new()
	log_view.editable = false
	log_view.custom_minimum_size.y = 120
	log_view.visible = false
	check_box.add_child(log_view)


func _bar_btn(bar: HBoxContainer, text: String, cb: Callable, tip: String) -> Button:
	var b := Button.new()
	b.text = text
	b.flat = true
	b.tooltip_text = tip
	b.pressed.connect(cb)
	bar.add_child(b)
	return b


func _build_left() -> Control:
	var vb := VBoxContainer.new()
	vb.custom_minimum_size.x = 230
	vb.add_child(_caption("대화"))
	file_list = ItemList.new()
	file_list.custom_minimum_size.y = 150
	file_list.size_flags_vertical = SIZE_EXPAND_FILL
	file_list.item_clicked.connect(func(i, _p, _b): _request_open(file_list.get_item_metadata(i)))
	vb.add_child(file_list)
	vb.add_child(_caption("찾기"))
	search = LineEdit.new()
	search.placeholder_text = "대사·ID·플래그·아이템 (모든 대화)"
	search.clear_button_enabled = true
	search.text_changed.connect(func(_t): _run_search())
	vb.add_child(search)
	results = ItemList.new()
	results.custom_minimum_size.y = 140
	results.visible = false
	results.item_clicked.connect(func(i, _p, _b):
		var m: Array = results.get_item_metadata(i)
		goto(m[0], m[1], m[2]))
	vb.add_child(results)
	vb.add_child(_caption("카드 만들기 (그래프로 끌어 놓기)"))
	for p in PALETTE:
		var b := Button.new()
		b.text = p[1]
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.tooltip_text = "누르면 화면 가운데에, 끌면 놓은 자리에 만듭니다"
		var kind: String = p[0]
		b.pressed.connect(func(): _add_kind(kind, _center_pos()))
		b.set_drag_forwarding(func(_pos):
			var l := Label.new()
			l.text = p[1]
			b.set_drag_preview(l)
			return {"palette": kind}, Callable(), Callable())
		vb.add_child(b)
	return vb


func _caption(t: String) -> Label:
	var l := Label.new()
	l.text = t
	l.add_theme_color_override("font_color", Color("8fb8ff"))
	return l


const HELP_TEXT := """[b]대화 탭 쓰는 법[/b] — 대본은 아래 칸에서 쓰고, 그래프에서는 흐름만 봅니다.

[b]화면[/b]
  왼쪽 — 대화 목록 · 찾기(모든 대화의 대사·ID·플래그·아이템) · 카드 만들기(그래프로 끌어 놓기)
  가운데 위 — 흐름 그래프.  가운데 아래 — [b]대본 칸[/b] (고른 대본 블록의 페이지들, '⤢ 크게'로 그래프 접기)
  오른쪽 — 고른 카드·선택지의 세부 (기본 / 조건 / 결과 / 고급).  아래 — 검사 결과 (누르면 그 카드·페이지로)

[b]0. NPC 대화[/b] — 대화 하나 = NPC 하나. [b]새 대화[/b]에서 NPC 를 고르면 [b]▶ 대화 시작[/b] 카드와 첫 대사 카드가 생깁니다.
  · [b]▶ 대화 시작[/b]: 말을 걸면 여기서 시작 (화면에 안 보임). [b]＋ 조건 길 추가[/b]로 길을 만들고, 위에서부터 조건이 맞는 첫 길로 갑니다. 하나도 안 맞으면 [b]그 외 →[/b].
    예) 길 1: 대화 횟수 == 0 → 첫 만남 · 길 2: 플래그 met_boss → 보스 이야기 · 그 외 → 반복 대사.  ↑ ↓ 로 길 순서(먼저 볼 것)를 바꿉니다.
  · 맵 탭에서 NPC 의 '대화'에 [b]▶ NPC 대화[/b]를 고르면 연결됩니다. 대화 시작 카드는 대화마다 하나.

[b]1. 대본 쓰기[/b] — 📝 대본 블록 카드를 고르면 아래 대본 칸에 페이지가 나옵니다.
  · 한 블록에 페이지를 여러 개: [b]＋ 페이지[/b] (본문에서 Ctrl+Enter = 그 아래에 새 페이지)
  · 페이지마다 [b]표시[/b]: 상황 묘사(밝은 상자) / 말풍선(화자 대사) / 시스템 메시지(검은 상자)
  · [b]속도[/b]: 기본·즉시·느림·보통·빠름·직접(초당 글자 수).  [b]넘김[/b]: 입력 대기 / 자동 넘김(몇 초 뒤)
  · 본문: 빈 줄 = 문단, 줄바꿈 = 강제 줄바꿈, 긴 줄은 자동 줄바꿈.  [b]⏸ 대기[/b] = 커서 자리에서 멈춤 {w=0.5} (주황색으로 보임)
  · 순서: ≡ 를 끌거나 ↑ ↓ (Alt+↑/↓).  ⧉ 복제(Ctrl+Shift+D), ✕ 삭제, ▶ 이 페이지부터 미리보기
  · 게임에서: 글자가 나오는 중에 한 번 누르면 그 페이지 전체, 한 번 더 누르면 다음 페이지

[b]2. 흐름 잇기[/b] — 카드 오른쪽 [color=#8fb8ff]●[/color] 점을 끌어 다른 카드 왼쪽 점에 놓습니다.
  · [b]다음 →[/b]: 선택지가 없을 때 / [b]선택지 줄[/b]: 고르면 (전투는 이겼을 때) / [color=#e46a6a]판정 실패 →[/color] · [color=#e46a6a]도주 →[/color]
  · 점을 [b]빈 곳[/b]에 놓으면 그 자리에 새 카드를 만들어 바로 잇습니다.  끝내려면 [b]대화 끝 (EXIT)[/b] 카드에.
  · 선 끊기: 들어가는 쪽 끝(카드 왼쪽 점)을 빈 곳으로 끌어 놓기.  없는 곳으로 가는 연결은 주황 ⚠.

[b]3. 선택지[/b] — 카드의 [b]+ 선택지[/b]. 줄에서 바로 문구를 고치고, [종류] 🔒조건 💰대가 ⚙효과가 요약으로 보입니다.
  · ⋯ = 오른쪽 칸에서 세부.  종류: 일반 / 아이템 / 판정(d20) / 전투.  ✕ = 삭제

[b]4. 기능 카드[/b] — ◇ 조건 분기(맞으면 / [color=#e46a6a]아니면[/color]) · ⚙ 효과(아이템·플래그·생존 수치·상태이상·팔다리 복구·저장·맵 이동 …)
  · 조건·효과는 [b]＋ 조건 추가 / ＋ 효과 추가[/b]로 목록에서 고릅니다 (글자로 쓸 필요 없음).

[b]4-1. 🎬 연출 (컷신)[/b] — 카드 안 [b]＋ 연출 추가[/b]로 단계를 넣고, 위에서부터 차례로 실행합니다 (그동안 대사 상자는 숨고 플레이어는 못 움직임).
  · 그림 컷신: [b]그림 띄우기[/b] (art/cutscenes/ 에 넣은 그림, 화면 가득) → 대본 블록(그림 위에 대사) → … → [b]그림 내리기[/b]. 페이드·흔들기·기다리기도.
  · 인게임 컷신: [b]걷게 하기[/b](플레이어·맵의 NPC → 칸 x·y, 벽은 돌아감) · [b]카메라 옮기기[/b] · [b]NPC 숨기기[/b] — 탐험 필드에서만 (미리보기에서는 건너뜀).
    칸 x·y 는 맵 탭에서 마우스를 올리면 보입니다. '다 걸을 때까지 기다림'을 끄면 여럿이 같이 걷습니다.
  · 시작: 맵 탭의 [b]이벤트[/b] 칸을 밟으면 (한 번만·나타나는 조건 가능), 또는 NPC 대화 중에.
  · NPC 를 컷신 도중 등장시키려면: NPC 에 '나타나는 조건 = 플래그'를 걸고, 효과 카드로 그 플래그를 켜면 바로 나타납니다.
  · 소리: [b]🔊 효과음[/b] (audio/sfx/) · [b]🎵 배경음 틀기[/b] (audio/bgm/, 반복 — 대화가 끝나도 계속) · [b]배경음 끄기[/b]. ▶ 로 들어 보기.
  · [b]↻ 바라보기[/b]: 인물이 볼 방향 (걸으면 가는 쪽을 저절로 봄). NPC 의 처음 방향은 맵 탭에서.
  · 게임에서 컷신 중에는 오른쪽 위 [b]건너뛰기 ▶▶[/b] (Esc): 바로 끝난 모습으로, 대사는 넘기고 선택지에서 멈춤.
  · 오프닝: 엑셀 Config [b]opening_dialogue[/b] 에 첫 노드 → 새 게임(캐릭터 생성 직후) 한 번.

[b]5. 고치기[/b] (그래프를 한 번 누른 뒤)
  · Ctrl+Z 실행 취소 · Ctrl+Y 다시 실행 · Ctrl+C/V 복사·붙여넣기 · Ctrl+D 복제 · Delete 지우기 · F 고른 카드 가운데로 · Ctrl+S 저장
  · 여러 카드: 빈 곳을 끌어 고르기 / Ctrl+클릭.  카드 제목의 ▾ = 대본 미리보기 접기.  편집 ▾ → 자동 정렬
  · 저장 안 한 변경이 있으면 목록에 ●, 다른 대화를 열 때 저장할지 묻습니다.

[b]6. 반영하기[/b] — 저장 → [b]변환·검사[/b] (오류는 ⛔, 경고는 ⚠ — 누르면 그 자리로) → [b]▶ 미리보기[/b]
[b]7. NPC에 붙이기[/b] — [b]맵[/b] 탭에서 NPC를 고르고 '대화 (시작 노드)'에 이 대화의 첫 카드를 고릅니다.
"""


func _ready() -> void:
	refresh_file_list()


# ---------------------------------------------------------------- 파일
func refresh_file_list() -> void:
	_load_lookups()
	var current: String = dialogue.get("dialogue_id", "")
	files.clear()
	var names := _file_names()
	for n in names:
		files.add_item(n)
	if current == "" and not names.is_empty():
		open_dialogue(names[0])
	else:
		_select_file_item(current)
	_refresh_file_list_marks()


func _file_names() -> Array:
	var names := []
	var d := DirAccess.open(dir)
	if d:
		for f in d.get_files():
			if f.ends_with(".json"):
				names.append(f.get_basename())
	names.sort()
	return names


func _refresh_file_list_marks() -> void:
	if file_list == null:
		return
	file_list.clear()
	var current: String = dialogue.get("dialogue_id", "")
	for i in files.item_count:
		var n := files.get_item_text(i)
		var who := _npc_of_file(n)
		var row := file_list.add_item(("● " if n == current and dirty else ("▶ " if n == current else "")) + n + ("   — " + who if who != "" else ""))
		file_list.set_item_metadata(row, n)
	_save_btn.text = "저장 ●" if dirty else "저장"


## 화면에서 다른 대화를 고름: 저장 안 한 변경이 있으면 물어본다. then = 연 뒤에 할 일
func _request_open(id: String, then := Callable()) -> void:
	if id == dialogue.get("dialogue_id", ""):
		if then.is_valid():
			then.call()
		return
	if not dirty:
		open_dialogue(id)
		if then.is_valid():
			then.call()
		return
	var dlg := ConfirmationDialog.new()
	dlg.title = "저장하지 않은 변경"
	dlg.dialog_text = "'%s' 에 저장하지 않은 변경이 있습니다. 어떻게 할까요?" % dialogue.get("dialogue_id", "")
	dlg.ok_button_text = "저장하고 열기"
	dlg.cancel_button_text = "취소"
	dlg.add_button("저장 안 함", true, "discard")
	var go := func():
		open_dialogue(id)
		if then.is_valid():
			then.call()
		dlg.queue_free()
	dlg.confirmed.connect(func():
		save()
		go.call())
	dlg.custom_action.connect(func(_a):
		dirty = false
		dlg.hide()
		go.call())
	dlg.canceled.connect(func():
		_select_file_item(dialogue.get("dialogue_id", ""))
		dlg.queue_free())
	add_child(dlg)
	dlg.popup_centered()


## 대화 열기 (코드에서 부를 때는 저장 안 한 변경을 자동 저장)
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
	_reset_history()
	_select_file_item(id)
	dirty = false
	_refresh_file_list_marks()
	var who := _npc_of_file(id)
	_status("열림: %s  (%s)" % [id, ("NPC 대화: " + who if who != "" else "필드 대화") if dialogue.get("episode_id", "") == "" else "에피소드 " + dialogue.episode_id])
	_show_first_card.call_deferred()


## 연 대화의 첫 카드가 화면 왼쪽 위에 보이게
func _show_first_card() -> void:
	var cards := _cards()
	if cards.is_empty():
		return
	var top_left: Vector2 = cards[0].position_offset
	for c in cards:
		top_left = top_left.min(c.position_offset)
	graph.scroll_offset = (top_left - Vector2(40, 90)) * graph.zoom   # 90: 그래프 도구줄 아래


## 새 대화 (NPC 하나 = 대화 하나): ▶ 대화 시작 카드 + 그 NPC 의 첫 대사 카드를 만들어 잇는다.
## episode_id 는 1단계 에피소드 대화용 (비우면 필드·NPC 대화).
func new_dialogue(id: String, episode_id := "", npc_id := "") -> bool:
	id = id.strip_edges()
	if not RegEx.create_from_string("^[A-Za-z0-9_]+$").search(id):
		_status("대화 ID 는 영문·숫자·_ 만")
		return false
	DirAccess.make_dir_recursive_absolute(dir)
	if FileAccess.file_exists(dir + id + ".json"):
		_status("이미 있는 대화: " + id)
		return false
	if dirty and not dialogue.is_empty():
		save()
	dialogue = {"dialogue_id": id, "episode_id": episode_id, "nodes": [], "choices": []}
	if npc_id != "":
		dialogue.npc_id = npc_id
	path = dir + id + ".json"
	_build_graph()
	_quiet = true
	if episode_id == "":
		var st := _make_card({"node_id": id + "_start", "kind": "start", "routes": [], "speaker_id": "", "text": "", "next_node": "", "on_enter": ""},
			[], Vector2(40, 60))
		var first := _make_card({"node_id": _new_node_id(), "speaker_id": npc_id, "text": "", "next_node": "", "on_enter": ""}, [], Vector2(560, 60))
		st.data.next_node = first.data.node_id
		st.rebuild()
	else:
		_make_card({"node_id": _new_node_id(), "speaker_id": "", "text": "", "next_node": "", "on_enter": ""}, [], Vector2(40, 60))
	_quiet = false
	_sync_connections()
	save()
	_reset_history()
	refresh_file_list()
	_select_file_item(id)
	return true


func save() -> void:
	if dialogue.is_empty():
		return
	dialogue.merge(_collect(), true)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		_status("⛔ 저장 실패 (파일을 쓸 수 없음): " + path)
		return
	f.store_string(JSON.stringify(dialogue, " ", false) + "\n")
	f.close()
	dirty = false
	_refresh_file_list_marks()
	_status("저장함: " + path.get_file())


## 카드들 → 파일에 쓸 { nodes, choices }. 대본 페이지가 기본값 1개뿐이면 예전 형식(speaker_id·text)으로.
func _collect() -> Dictionary:
	var nodes := []
	var choices := []
	for card in _cards():
		nodes.append(_node_out(card))
		for c in card.choices:
			c.node_id = card.data.node_id
			choices.append(c.duplicate(true))
	return {"nodes": nodes, "choices": choices}


func _node_out(card: GraphNode) -> Dictionary:
	var n: Dictionary = card.data.duplicate(true)
	n.erase("pages")
	n.pos = [roundi(card.position_offset.x), roundi(card.position_offset.y)]
	if not card.uses_pages():
		return n
	var pages: Array = card.data.pages
	if pages.size() == 1 and ScriptPages.is_plain(pages[0]):
		n.speaker_id = pages[0].speaker_id
		n.text = pages[0].text
		return n
	n.pages = pages.map(_page_out)
	# 예전 칸은 첫 페이지와 맞춰 둔다 (목록 이름표·다른 도구용)
	n.speaker_id = pages[0].speaker_id if not pages.is_empty() else ""
	n.text = ScriptPages.parse_text(pages[0].text).text if not pages.is_empty() else ""
	return n


## 페이지는 기본값이 아닌 칸만 쓴다
func _page_out(p: Dictionary) -> Dictionary:
	var o := {"page_id": p.page_id, "display": p.display, "text": p.text}
	if p.display == "bubble":
		o.speaker_id = p.speaker_id
	if p.speed != "":
		o.speed = p.speed
	if p.advance == "auto":
		o.advance = "auto"
		o.auto_wait = p.auto_wait
	return o


# ---------------------------------------------------------------- 실행 취소
func _reset_history() -> void:
	_undo.clear()
	_redo.clear()
	_snap = _collect()
	_last_key = ""


## 무언가 바뀐 뒤에 부른다. 같은 key 로 이어지는 변경(글자 입력·끌기)은 실행 취소 한 번으로 묶인다.
func _touch(key := "") -> void:
	if _quiet or dialogue.is_empty():
		return
	dirty = true
	var now := _collect()
	if now != _snap:
		if key == "" or key != _last_key:
			_undo.append(_snap)
			if _undo.size() > UNDO_LIMIT:
				_undo.pop_front()
			_redo.clear()
		_snap = now
	_last_key = key
	_refresh_file_list_marks()
	_status("● 저장 안 함")


func undo() -> void:
	if _undo.is_empty():
		_status("더 되돌릴 것이 없음")
		return
	_redo.append(_snap)
	_restore(_undo.pop_back())
	_status("실행 취소")


func redo() -> void:
	if _redo.is_empty():
		_status("다시 실행할 것이 없음")
		return
	_undo.append(_snap)
	_restore(_redo.pop_back())
	_status("다시 실행")


func _restore(state: Dictionary) -> void:
	var keep := String(_selected_card.name) if is_instance_valid(_selected_card) else ""
	var scroll := graph.scroll_offset
	dialogue.nodes = state.nodes.duplicate(true)
	dialogue.choices = state.choices.duplicate(true)
	_build_graph()
	graph.scroll_offset = scroll
	_snap = _collect()
	_last_key = ""
	dirty = true
	_refresh_file_list_marks()
	var card := graph.get_node_or_null(NodePath(keep)) if keep != "" else null
	if card is Card:
		_select(card)


# ---------------------------------------------------------------- 그래프 만들기
func _build_graph() -> void:
	_quiet = true
	graph.clear_connections()
	for c in graph.get_children():
		if c is GraphNode:
			graph.remove_child(c)
			c.queue_free()
	_selected_card = null
	_counter = 0
	_clear_inspector()
	_empty_hint()
	script_panel.speakers = speakers.slice(1)
	script_panel.default_speaker = dialogue.get("npc_id", "")
	script_panel.edit(null)
	var by_node := {}
	for c in dialogue.get("choices", []):
		if not by_node.has(c.node_id):
			by_node[c.node_id] = []
		by_node[c.node_id].append(c)
	for n in dialogue.get("nodes", []):
		var pos: Array = n.get("pos", [40, 60])
		var data: Dictionary = n.duplicate(true)
		data.erase("pos")
		_make_card(data, by_node.get(n.node_id, []).map(func(c): return c.duplicate(true)), Vector2(pos[0], pos[1]))
	# 끝 카드: 필드 대화는 EXIT 하나, 에피소드 대화는 쓰인 엔딩마다
	if dialogue.get("episode_id", "") == "":
		_make_terminal(EXIT_NAME, "대화 끝 (EXIT)", _right_of_cards())
	for t in _all_targets():
		if t.begins_with("END:") and graph.get_node_or_null(END_PREFIX + t.substr(4)) == null:
			_make_terminal(END_PREFIX + t.substr(4), "엔딩: " + t.substr(4), _right_of_cards() + Vector2(0, 140))
	for c in _cards():
		c.rebuild()   # 모든 카드가 생긴 뒤에 다시 그려야 '없는 곳' ⚠ 표시가 맞다
	_sync_connections()
	_quiet = false


func _make_card(data: Dictionary, node_choices: Array, pos: Vector2) -> GraphNode:
	var kind: String = data.get("kind", "")
	var card: GraphNode = StartCard.new() if kind == "start" else (DirectCard.new() if kind == "direct" else
		(FuncCard.new() if kind in ["effect", "branch"] else Card.new()))
	if card is FuncCard or card is StartCard or card is DirectCard:
		card.lookups = lookups
	card.choice_id_maker = _new_choice_id
	card.target_exists = _target_exists
	card.setup(data, node_choices, speakers)
	card.position_offset = pos
	card.changed.connect(_on_card_changed.bind(card))
	card.choice_selected.connect(_edit_choice)
	card.node_selected_for_edit.connect(func(c): _select(c))
	card.page_requested.connect(func(c, page): _select(c, page))
	card.position_offset_changed.connect(func(): _touch("move:" + String(card.name)))
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
	# NPC 대화면 새 블록은 그 NPC 의 말풍선으로 시작
	var card := _make_card({"node_id": id, "speaker_id": dialogue.get("npc_id", ""), "text": "", "next_node": "", "on_enter": ""}, [], pos)
	_sync_connections()
	_touch()
	return card


## 기능 카드 (kind: effect / branch / direct)
func add_func_card(kind: String, pos: Vector2) -> GraphNode:
	var data := {"node_id": _new_node_id(), "kind": kind, "speaker_id": "", "text": "", "next_node": "", "on_enter": ""}
	if kind == "direct":
		data.steps = []
	if kind == "branch":
		data.condition = ""
		data.fail_next = ""
	var card := _make_card(data, [], pos)
	_sync_connections()
	_touch()
	return card


func _fill_add_menu(pm: PopupMenu, at: Callable) -> void:
	for i in ADD_MENU.size():
		pm.add_item(ADD_MENU[i][1], i)
	pm.id_pressed.connect(func(i): _add_kind(ADD_MENU[i][0], at.call() if at.is_valid() else _center_pos()))


## 그래프 빈 곳 오른쪽 클릭 → 그 자리에 카드 만들기 메뉴
func _on_graph_popup(at_position: Vector2) -> void:
	var pos := _graph_pos(at_position)
	var pm := PopupMenu.new()
	_fill_add_menu(pm, func(): return pos)
	add_child(pm)
	pm.popup_hide.connect(pm.queue_free)
	pm.popup_on_parent(Rect2i(Vector2i(get_global_mouse_position()), Vector2i.ZERO))


## 연결점에서 빈 곳으로 선을 끌어 놓음 → 그 자리에 새 카드를 만들고 바로 잇는다
func _on_connect_empty(from: StringName, from_port: int, release: Vector2) -> void:
	var card := graph.get_node_or_null(NodePath(from))
	if not card is Card:
		return
	var pos := _graph_pos(release)
	var pm := PopupMenu.new()
	var kinds := [["line", "📝 새 대본 블록"], ["branch", "◇ 새 조건 분기"], ["effect", "⚙ 새 효과"], ["direct", "🎬 새 연출"]]
	if dialogue.get("episode_id", "") == "":
		kinds.append(["exit", "대화 끝 (EXIT)"])
	for i in kinds.size():
		pm.add_item(kinds[i][1], i)
	pm.id_pressed.connect(func(i):
		var target := "EXIT"
		if kinds[i][0] != "exit":
			var nc: GraphNode = add_card(pos) if kinds[i][0] == "line" else add_func_card(kinds[i][0], pos)
			target = nc.data.node_id
		var tgt: Array = card.port_target(from_port)
		tgt[0][tgt[1]] = target
		_after_target_change(card)
		var made := graph.get_node_or_null(NodePath(target))
		if made is Card:
			_select(made, 0))
	add_child(pm)
	pm.popup_hide.connect(pm.queue_free)
	pm.popup_on_parent(Rect2i(Vector2i(get_global_mouse_position()), Vector2i.ZERO))


func _graph_pos(local: Vector2) -> Vector2:
	return (graph.scroll_offset + local) / graph.zoom


func _center_pos() -> Vector2:
	return (graph.scroll_offset + graph.size / 2.0) / graph.zoom - Vector2(210, 100)


func _add_kind(kind: String, pos: Vector2) -> void:
	if dialogue.is_empty():
		_status("먼저 대화를 열거나 새로 만드세요")
		return
	match kind:
		"start":
			var have := _start_card()
			if have:
				_select(have)
				center_on(have)
				_status("대화 시작 카드는 대화마다 하나입니다 — 이미 있는 카드로 갔습니다")
				return
			var data := {"node_id": dialogue.get("dialogue_id", "dlg") + "_start", "kind": "start", "routes": [], "speaker_id": "", "text": "", "next_node": "", "on_enter": ""}
			while graph.get_node_or_null(NodePath(data.node_id)) != null:
				data.node_id += "_"
			var sc := _make_card(data, [], pos)
			_sync_connections()
			_touch()
			_select(sc)
		"line": _select(add_card(pos), 0)
		"ending": _add_end_card()
		_: _select(add_func_card(kind, pos))


func add_card_at_center() -> void:
	_add_kind("line", _center_pos())


func _add_end_card() -> void:
	if dialogue.is_empty():
		return
	var id := "ending_%d" % (_counter + 1)
	_counter += 1
	_make_terminal(END_PREFIX + id, "엔딩: " + id, _right_of_cards())
	_status("엔딩 카드 '%s' — Endings 시트의 ending_id 로 이름을 맞추려면 연결 후 오른쪽 칸에서 갈 곳을 END:<id> 로 고치세요" % id)


func _graph_can_drop(_pos: Vector2, d: Variant) -> bool:
	return d is Dictionary and d.has("palette")


func _graph_drop(pos: Vector2, d: Variant) -> void:
	_add_kind(d.palette, _graph_pos(pos))


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
	_sync_connections()
	_touch()
	if _selected_card == card and _box_mode == "node":
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


func _target_exists(t: String) -> bool:
	return t == "EXIT" or t.begins_with("END:") or graph.get_node_or_null(NodePath(t)) != null or _known_nodes.has(t)


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
			script_panel.edit(null)
	for card in _cards():
		card.rebuild()
	_sync_connections()
	_touch()


func _on_card_changed(key: String, card: GraphNode) -> void:
	_touch(key)
	_sync_connections.call_deferred()
	if card == _selected_card and key == "choice_del" and _box_mode == "choice":
		_edit_node(card)   # 지운 선택지의 세부가 남지 않게


# ---------------------------------------------------------------- 고르기·이동
func _on_node_selected(n: Node) -> void:
	if n is Card:
		_select(n)


## 카드를 고른다: 오른쪽 칸 = 카드 세부, 아래 대본 칸 = 그 블록 (page 가 있으면 그 페이지로)
func _select(card: GraphNode, page := -1) -> void:
	if not is_instance_valid(card):
		return
	_edit_node(card)
	if not card.uses_pages():
		script_panel.edit(null)
	elif script_panel.card != card or page >= 0:
		script_panel.edit(card, page)
	if not card.selected:
		for c in graph.get_children():
			if c is GraphNode:
				c.selected = c == card


func _selected_cards() -> Array:
	return _cards().filter(func(c): return c.selected)


func center_selected() -> void:
	var sel := _selected_cards()
	if sel.is_empty() and is_instance_valid(_selected_card):
		sel = [_selected_card]
	if not sel.is_empty():
		center_on(sel[0])


func center_on(card: GraphNode) -> void:
	graph.scroll_offset = (card.position_offset + card.size / 2.0) * graph.zoom - graph.size / 2.0


## 대화 file 의 node_id 로 가서 고르고 가운데에 (page = 대본 칸에서 열 페이지, -1 = 없음)
func goto(file: String, node_id: String, page := -1) -> void:
	_request_open(file, func():
		var card := graph.get_node_or_null(NodePath(node_id))
		if card is Card:
			_select(card, page)
			center_on(card))


func _graph_keys(e: InputEvent) -> void:
	if not (e is InputEventKey and e.pressed and not e.echo):
		return
	var cmd: bool = e.ctrl_pressed or e.meta_pressed
	if cmd and e.keycode == KEY_Z and not e.shift_pressed:
		undo()
	elif cmd and (e.keycode == KEY_Y or (e.keycode == KEY_Z and e.shift_pressed)):
		redo()
	elif cmd and e.keycode == KEY_S:
		save()
	elif e.keycode == KEY_F and not cmd:
		center_selected()
	else:
		return
	graph.accept_event()


# ---------------------------------------------------------------- 복사·붙여넣기·복제
func copy_selected() -> void:
	var sel := _selected_cards().filter(func(c): return not c is StartCard)   # 대화 시작 카드는 대화마다 하나
	if sel.is_empty():
		return
	_clipboard = []
	for c in sel:
		_clipboard.append({"data": c.data.duplicate(true), "choices": c.choices.duplicate(true), "pos": c.position_offset})
	_status("카드 %d장 복사" % sel.size())


## 복사한 카드를 새 ID 로 붙인다. 복사한 카드끼리의 연결은 새 ID 로 따라가고, 바깥으로 가는 연결은 그대로.
func paste(offset := Vector2(60, 60)) -> Array:
	if _clipboard.is_empty() or dialogue.is_empty():
		return []
	var ids := {}
	for it in _clipboard:
		ids[it.data.node_id] = _new_node_id()
	var made := []
	var used_choice := {}
	_quiet = true
	for it in _clipboard:
		var d: Dictionary = it.data.duplicate(true)
		d.node_id = ids[d.node_id]
		for k in ["next_node", "fail_next"]:
			if ids.has(d.get(k, "")):
				d[k] = ids[d[k]]
		var chs := []
		for c in it.choices:
			var nc: Dictionary = c.duplicate(true)
			nc.choice_id = _new_choice_id(used_choice)
			used_choice[nc.choice_id] = true
			nc.node_id = d.node_id
			for k in ["next_node", "fail_next"]:
				if ids.has(nc.get(k, "")):
					nc[k] = ids[nc[k]]
			chs.append(nc)
		made.append(_make_card(d, chs, it.pos + offset))
	_quiet = false
	_sync_connections()
	for c in graph.get_children():
		if c is GraphNode:
			c.selected = c in made
	_touch()
	_status("카드 %d장 붙여넣기" % made.size())
	return made


func duplicate_selected() -> void:
	var keep := _clipboard
	copy_selected()
	paste(Vector2(40, 40))
	_clipboard = keep


func delete_selected() -> void:
	var names := _selected_cards().map(func(c): return c.name)
	if not names.is_empty():
		_on_delete(names)


func arrange() -> void:
	_quiet = true
	if _selected_cards().is_empty():
		for c in graph.get_children():
			if c is GraphNode:
				c.selected = true
	graph.arrange_nodes()
	_quiet = false
	_touch()


func fold_all(on: bool) -> void:
	_quiet = true
	for c in _cards():
		if c.uses_pages():
			if on:
				c.data.fold = true
			else:
				c.data.erase("fold")
			c.rebuild()
	_quiet = false
	_touch()


# ---------------------------------------------------------------- 오른쪽 칸 (세부)
var _box_mode := ""   # "node" / "choice" / ""

func _edit_node(card: GraphNode) -> void:
	_selected_card = card
	_box_mode = "node"
	_clear_inspector()
	var d: Dictionary = card.data
	if card is DirectCard:
		_title("🎬 연출")
		_section("기본")
		_hint("카드 안에서 '＋ 연출 추가'로 단계를 넣습니다. 위에서부터 차례로 실행하고 다 끝나면 '다음 →'.
· 그림 띄우기: art/cutscenes/ 에 넣은 그림 (화면 가득, 그 위에 대사 상자가 뜸)
· 페이드: 검게·하얗게 덮기 / 걷기
· 걷게 하기·카메라·NPC 숨기기: 탐험 필드에서만 (미리보기에서는 건너뜀)
연출 중에는 대사 상자가 숨고 플레이어는 움직일 수 없습니다.")
		_section("결과")
		_target("다음 갈 곳", d, "next_node", card)
		_section("고급", false)
		_line("카드 ID", d.node_id, func(v): _rename_node(card, v))
		return
	if card is StartCard:
		_title("▶ 대화 시작")
		_section("기본")
		_hint("NPC 에게 말을 걸면 여기서 시작합니다 (화면에 안 보임).\n카드 안의 길을 위에서부터 보고 조건이 맞는 첫 길로, 하나도 안 맞으면 '그 외 →'.\n예) 길 1: 대화 횟수 == 0 → 첫 만남 / 그 외 → 반복 대사")
		var npcs := [["", "(정하지 않음)"]] + _npc_list()
		_option("이 대화의 NPC", npcs.map(func(x): return x[0]), npcs.map(func(x): return x[1]), dialogue.get("npc_id", ""), func(v):
			if v == "":
				dialogue.erase("npc_id")
			else:
				dialogue.npc_id = v
			script_panel.default_speaker = v
			_touch()
			_refresh_file_list_marks())
		_hint("맵 탭에서 NPC 를 놓고 '대화'에 이 카드(%s)를 고르면 연결됩니다." % d.node_id)
		_section("결과")
		_target("그 외 갈 곳", d, "next_node", card)
		_section("고급", false)
		_line("카드 ID", d.node_id, func(v): _rename_node(card, v))
		return
	if card is FuncCard:
		var branch: bool = d.kind == "branch"
		_title("◇ 조건 분기" if branch else "⚙ 효과")
		_section("기본")
		_hint(("조건은 카드 안에서 고릅니다. 맞으면 '맞으면 →', 아니면 빨간 '아니면 →' 으로 갑니다."
			if branch else "효과는 카드 안에서 고릅니다. 실행한 뒤 '다음 →' 으로 갑니다.") + "\n화면에는 보이지 않습니다.")
		_section("결과")
		_target("맞으면 갈 곳" if branch else "다음 갈 곳", d, "next_node", card)
		if branch:
			_target("아니면 갈 곳", d, "fail_next", card)
		_section("고급", false)
		_line("카드 ID", d.node_id, func(v): _rename_node(card, v))
		return
	_title("📝 대본 블록")
	_section("기본")
	_hint("대사는 가운데 아래 [대본] 칸에서 씁니다.")
	_section("결과")
	_expr("이 블록에 들어올 때 효과", "effect", d.get("on_enter", ""), _setter(d, "on_enter", "on_enter:" + d.node_id))
	_target("다음 갈 곳 (선택지가 없을 때)", d, "next_node", card)
	_hint("선택지가 있으면 '다음 →' 대신 선택지가 나옵니다.")
	_section("고급", false)
	_line("카드 ID", d.node_id, func(v): _rename_node(card, v))


func _edit_choice(card: GraphNode, index: int) -> void:
	_selected_card = card
	_box_mode = "choice"
	if script_panel.card != card and card.uses_pages():
		script_panel.edit(card)
	_clear_inspector()
	if index >= card.choices.size():
		return
	var c: Dictionary = card.choices[index]
	var key: String = "choice:" + c.choice_id
	var t: String = c.get("type", "normal")
	_title("선택지  (%s)" % card.data.node_id)
	_section("기본")
	_line("문구", c.get("text", ""), func(v):
		c.text = v
		card.rebuild()
		_touch(key + ":text"))
	_option("종류", ["normal", "item", "dice", "combat"], ["일반", "아이템 (조건에 has: 필요)", "판정 (주사위 d20)", "전투 (이기면 이동, 도주하면 도주 이동)"],
			t, func(v):
		c.type = v
		if v == "combat" and not c.get("check", "") in enemies.map(func(e): return e[0]):
			c.check = enemies[0][0] if not enemies.is_empty() else ""
		elif v == "dice" and not c.get("check", "") in abilities.map(func(a): return a[0]):
			c.check = abilities[0][0] if not abilities.is_empty() else ""
		elif not v in ["dice", "combat"]:
			# 판정·전투 전용 칸을 비워 둬야 변환기 검사를 통과한다
			for k in ["check", "fail_effects", "fail_next"]:
				c[k] = ""
		_after_target_change(card)
		_edit_choice(card, index))
	_line("대가 표시", c.get("cost", ""), func(v):
		c.cost = v
		card.rebuild()
		_touch(key + ":cost"), "버튼에 보이는 글자만. 실제 차감은 '결과'의 효과에")
	_section("조건")
	_expr("보이는 조건 (맞아야 고를 수 있음)", "cond", c.get("condition", ""), func(v):
		c.condition = v
		card.rebuild()
		_touch(key + ":cond"))
	_option("조건이 안 맞을 때", ["gray", "hide"], ["회색으로 보임 (비활성)", "숨김"], c.get("show_mode", "") if c.get("show_mode", "") != "" else "gray",
		func(v):
			c.show_mode = "" if v == "gray" else v
			card.rebuild()
			_touch())
	_section("결과")
	_expr("고르면 일어나는 효과" if t != "combat" else "이겼을 때 효과", "effect", c.get("effects", ""), func(v):
		c.effects = v
		card.rebuild()
		_touch(key + ":fx"))
	_target("갈 곳" if not t in ["dice", "combat"] else ("성공하면 갈 곳" if t == "dice" else "이기면 갈 곳"), c, "next_node", card)
	if t == "dice":
		_section("판정 (d20 + 보정 ≥ 목표값)")
		_option("능력치", abilities.map(func(a): return a[0]), abilities.map(func(a): return a[1]), c.get("check", ""),
			func(v):
				c.check = v
				card.rebuild()
				_touch())
		_spin("목표값 (dc)", int(c.get("dc", 10)), 1, 40, func(v):
			c.dc = v
			card.rebuild()
			_touch(key + ":dc"))
		_spin("상황 보정 (mod)", int(c.get("mod", 0)), -20, 20, _setter(c, "mod", key + ":mod"))
		_expr("실패했을 때 효과", "effect", c.get("fail_effects", ""), _setter(c, "fail_effects", key + ":ffx"))
		_target("실패하면 갈 곳", c, "fail_next", card)
	elif t == "combat":
		_section("전투")
		_option("적", enemies.map(func(e): return e[0]), enemies.map(func(e): return e[1]), c.get("check", ""),
			func(v):
				c.check = v
				card.rebuild()
				_touch())
		_expr("도망쳤을 때 효과", "effect", c.get("fail_effects", ""), _setter(c, "fail_effects", key + ":ffx"))
		_target("도망치면 갈 곳", c, "fail_next", card)
		_hint("이기면 효과·이동, 도주하면 도주 효과·이동.\n지면 대화가 끝나고 사망 처리 (부활 규칙).")
	_section("고급", false)
	_line("choice_id", c.choice_id, _setter(c, "choice_id", key + ":id"))


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
	for other in _cards():
		other.rebuild()
	_sync_connections()
	_touch()


# ---------------------------------------------------------------- 변환·검사·미리보기
## 변환 스크립트를 돌려 아래 검사 칸에 오류·경고를 보인다. 성공하면 true.
func run_convert() -> bool:
	if dirty:
		save()
	var ok: bool = ToolCommon.run_convert(log_view)
	_load_lookups()
	for c in _cards():
		c.rebuild()
	var counts := _fill_problems()
	check_head.text = ("⛔ 변환 실패 — 오류 %d개" % counts[0] if not ok else "✓ 변환 성공") + \
		("   ·   ⚠ 경고 %d개" % counts[1] if counts[1] > 0 else "") + "   (누르면 그 자리로)"
	check_box.visible = not ok or counts[1] > 0
	if not ok and counts[0] == 0:
		log_view.visible = true   # 변환기를 못 돌림 등 → 원문을 보여 준다
		problems.visible = false
	_status("변환 성공 ✓" if ok else "변환 실패 — 아래 검사 결과를 확인하세요")
	return ok


## 변환기 출력에서 오류·경고 줄을 뽑아 목록으로. 줄에 있는 대화 노드·선택지 ID 로 갈 곳을 찾는다. → [오류 수, 경고 수]
func _fill_problems() -> Array:
	problems.clear()
	var index := _id_index()
	var id_rx := RegEx.create_from_string("\\(([A-Za-z0-9_]+)\\)")
	var page_rx := RegEx.create_from_string("페이지 (\\d+)")
	var n := [0, 0]
	for raw in log_view.text.split("\n"):
		var line := raw.strip_edges()
		var warn := line.begins_with("경고 [")
		if not (warn or line.begins_with("[")):
			continue
		if warn:
			line = line.substr(3)
		n[1 if warn else 0] += 1
		var i := problems.add_item(("⚠ " if warn else "⛔ ") + line)
		problems.set_item_custom_fg_color(i, Color("ffb454") if warn else Color("ff7070"))
		for m in id_rx.search_all(line):
			if index.has(m.get_string(1)):
				var pm := page_rx.search(line)
				var at: Array = index[m.get_string(1)]
				problems.set_item_metadata(i, [at[0], at[1], int(pm.get_string(1)) - 1 if pm else -1])
				problems.set_item_tooltip(i, "눌러서 %s · %s 로 가기" % [at[0], at[1]])
				break
	return n


## 모든 대화 파일의 node_id·choice_id → [대화 파일, node_id]
func _id_index() -> Dictionary:
	var out := {}
	for f in _file_names():
		var d = _read_json(dir + f + ".json", {})
		if not d is Dictionary:
			continue
		for nd in d.get("nodes", []):
			out[str(nd.get("node_id", ""))] = [f, str(nd.get("node_id", ""))]
		for c in d.get("choices", []):
			out[str(c.get("choice_id", ""))] = [f, str(c.get("node_id", ""))]
	return out


## 고른 카드(없으면 첫 카드)의 page 번째 페이지부터 실제 대화 화면으로 실행
func preview(page := -1) -> void:
	if dialogue.is_empty() or _cards().is_empty():
		return
	if not run_convert():
		return
	var card: GraphNode = _selected_card if _selected_card is Card else _cards()[0]
	if page < 0:
		page = 0
	var f := FileAccess.open(PREVIEW_FILE, FileAccess.WRITE)
	f.store_string(JSON.stringify({"node": card.data.node_id, "page": page}))
	f.close()
	if Engine.is_editor_hint():
		EditorInterface.play_custom_scene("res://addons/dialogue_editor/preview.tscn")


# ---------------------------------------------------------------- 찾기 (모든 대화)
func _run_search() -> void:
	results.clear()
	var q := search.text.strip_edges().to_lower()
	results.visible = q != ""
	if q == "":
		return
	var current: String = dialogue.get("dialogue_id", "")
	for f in _file_names():
		var d = _collect() if f == current else _read_json(dir + f + ".json", {})
		if not d is Dictionary:
			continue
		for nd in d.get("nodes", []):
			var nid := str(nd.get("node_id", ""))
			var pages: Array = ScriptPages.pages_of(nd) if not nd.get("kind", "") in ["effect", "branch"] else []
			var hit := false
			for i in pages.size():
				if q in String(pages[i].text).to_lower():
					_result(f, nid, i, "%s · %s · %d쪽: %s" % [f, nid, i + 1, ScriptPages.parse_text(pages[i].text).text.left(30)])
					hit = true
			if not hit:
				for k in ["node_id", "on_enter", "condition", "next_node", "fail_next", "speaker_id", "routes"]:
					if q in str(nd.get(k, "")).to_lower():
						_result(f, nid, -1, "%s · %s  (%s: %s)" % [f, nid, k, str(nd.get(k, "")).left(30)])
						break
		for c in d.get("choices", []):
			for k in ["text", "choice_id", "condition", "effects", "fail_effects", "next_node", "fail_next", "check"]:
				if q in str(c.get(k, "")).to_lower():
					_result(f, str(c.get("node_id", "")), -1, "%s · %s · 선택지 '%s'  (%s)" % [f, c.get("node_id", ""), str(c.get("text", "")).left(20), k])
					break
		if results.item_count >= 200:
			break
	if results.item_count == 0:
		results.add_item("(없음)")
		results.set_item_disabled(0, true)


func _result(f: String, node_id: String, page: int, label: String) -> void:
	var i := results.add_item(label)
	results.set_item_metadata(i, [f, node_id, page])
	results.set_item_tooltip(i, label)


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


func _new_choice_id(extra_used := {}) -> String:
	var base: String = dialogue.get("dialogue_id", "dlg")
	var used := extra_used.duplicate()
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
	_known_nodes = {}
	for n in lookups.get("nodes", []):
		_known_nodes[n[0]] = true
	enemies = []
	for e in _read_json("res://data/enemies.json", []):
		enemies.append([e.enemy_id, "%s  (%s)" % [e.name, e.enemy_id]])
	if script_panel:
		script_panel.speakers = speakers.slice(1)


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
	dlg.title = "새 NPC 대화"
	var box := VBoxContainer.new()
	var l := Label.new()
	l.text = "누구의 대화인가요? (NPC 하나 = 대화 하나, npc.xlsx Npcs)"
	box.add_child(l)
	var npc := OptionButton.new()
	var npcs := _npc_list()
	for x in npcs:
		npc.add_item(x[1])
	box.add_child(npc)
	var id := LineEdit.new()
	id.placeholder_text = "대화 ID (영문·숫자·_)"
	box.add_child(id)
	var suggest := func(i: int):
		if i >= 0 and i < npcs.size():
			id.text = String(npcs[i][0]).trim_prefix("char_").trim_prefix("npc_")
	npc.item_selected.connect(suggest)
	suggest.call(0)
	dlg.add_child(box)
	dlg.confirmed.connect(func():
		new_dialogue(id.text, "", npcs[npc.selected][0] if npc.selected >= 0 and npc.selected < npcs.size() else "")
		dlg.queue_free())
	dlg.canceled.connect(dlg.queue_free)
	add_child(dlg)
	dlg.popup_centered(Vector2i(520, 200))


## NPC 목록 [[char_id, "이름  (id)"]] — 플레이어 빼고
func _npc_list() -> Array:
	var out := []
	for ch in _read_json("res://data/characters.json", []):
		if not ch.get("is_player", false):
			out.append([ch.char_id, "%s  (%s)" % [ch.name, ch.char_id]])
	return out


## 대화 파일의 NPC 이름 (목록 표시용)
func _npc_of_file(id: String) -> String:
	var npc: String = dialogue.get("npc_id", "") if id == dialogue.get("dialogue_id", "") else str(_read_json(dir + id + ".json", {}).get("npc_id", ""))
	if npc == "":
		return ""
	for s in speakers:
		if s[0] == npc:
			return String(s[1]).get_slice("  (", 0)
	return npc


func _start_card() -> GraphNode:
	for c in _cards():
		if c is StartCard:
			return c
	return null


func _clear_inspector() -> void:
	for c in inspector.get_children():
		inspector.remove_child(c)
		c.queue_free()
	_box = inspector


## 접을 수 있는 구역 (기본 / 조건 / 결과 / 고급). 이후 칸은 이 구역 안에 들어간다.
func _section(t: String, open := true) -> void:
	var head := Button.new()
	head.flat = true
	head.toggle_mode = true
	head.button_pressed = open
	head.alignment = HORIZONTAL_ALIGNMENT_LEFT
	head.add_theme_color_override("font_color", Color("8fb8ff"))
	head.add_theme_color_override("font_pressed_color", Color("8fb8ff"))
	inspector.add_child(head)
	var body := VBoxContainer.new()
	body.visible = open
	inspector.add_child(body)
	head.text = ("▾ " if open else "▸ ") + t
	head.toggled.connect(func(on):
		body.visible = on
		head.text = ("▾ " if on else "▸ ") + t)
	_box = body


## 조건·효과 칸: 직접 입력 대신 목록에서 고르기 (addons/expr_rows.gd)
func _expr(label: String, mode: String, value: String, on_change: Callable) -> void:
	var l := Label.new()
	l.text = label
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_box.add_child(l)
	var rows: Node = ExprRows.new().setup(mode, value, lookups)
	rows.changed.connect(func(t): on_change.call(t))
	_box.add_child(rows)


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
		if c is StartCard:
			continue   # 대화 시작 카드로는 이을 수 없음 (들어오는 점 없음)
		var what: String = "(연출)" if c is DirectCard else (("(조건 분기)" if c.data.kind == "branch" else "(효과 카드)") if c is FuncCard else c.summary().left(18))
		opts.append([id, "이 대화: %s — %s" % [id, what]])
	for n in lookups.get("nodes", []):
		if not here.has(n[0]) and n[1] == episode:
			opts.append([n[0], "다른 곳: %s — %s" % [n[0], n[2]]])
	var cur: String = d.get(key, "")
	if cur != "" and not opts.any(func(o): return o[0] == cur):
		opts.append([cur, "⚠ %s (없는 곳)" % cur])
	_option(label, opts.map(func(o): return o[0]), opts.map(func(o): return o[1]), cur, func(v):
		d[key] = v
		_after_target_change(card))


## 아무것도 고르지 않았을 때 오른쪽 칸 안내
func _empty_hint() -> void:
	_box_mode = ""
	_title("세부 칸")
	_hint("· 카드를 클릭하면 카드 세부 (들어올 때 효과·갈 곳)\n· 선택지 옆 ⋯ 를 누르면 선택지 세부 (종류·조건·효과·판정·전투)\n· 대사는 가운데 아래 [대본] 칸에서\n\n자세한 쓰는 법은 오른쪽 위 '❓ 사용법'.")


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
	_box.add_child(l)


func _setter(d: Dictionary, key: String, touch_key := "") -> Callable:
	return func(v):
		d[key] = v
		_touch(touch_key)


func _line(label: String, value: String, on_change: Callable, hint := "") -> void:
	var l := Label.new()
	l.text = label
	_box.add_child(l)
	var e := LineEdit.new()
	e.text = value
	e.placeholder_text = hint
	e.text_submitted.connect(func(v): on_change.call(v))
	e.focus_exited.connect(func(): if e.text != value: on_change.call(e.text))
	_box.add_child(e)


func _option(label: String, values: Array, labels: Array, current: String, on_change: Callable) -> void:
	var l := Label.new()
	l.text = label
	_box.add_child(l)
	var o := OptionButton.new()
	o.fit_to_longest_item = false
	o.clip_text = true
	for i in values.size():
		o.add_item(labels[i], i)
		if values[i] == current:
			o.select(i)
	o.item_selected.connect(func(i): on_change.call(values[i]))
	_box.add_child(o)


func _spin(label: String, value: int, lo: int, hi: int, on_change: Callable) -> void:
	var l := Label.new()
	l.text = label
	_box.add_child(l)
	var s := SpinBox.new()
	s.min_value = lo
	s.max_value = hi
	s.value = value
	s.value_changed.connect(func(v): on_change.call(int(v)))
	_box.add_child(s)
