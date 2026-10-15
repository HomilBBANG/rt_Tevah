@tool
extends VBoxContainer
## 맵 에디터 (Godot 에디터의 '맵' 탭). tools/maps/<맵ID>.json 을 편집한다.
##   벽·바닥 칠하기, 도착 위치 P (출구로 들어올 때·베이스캠프에서 깨어날 때), 회차 시작 S,
##   물체 놓기(적·조사·NPC·거점·출구) → 오른쪽 칸에서 세부, 저장 → 변환·검사 → 테스트 플레이.
## 게임 실행 중(테스트)에서도 열 수 있도록 에디터 전용 기능은 Engine.is_editor_hint() 로 감싼다.

const Canvas = preload("res://addons/map_editor/map_canvas.gd")
const ToolCommon = preload("res://addons/tool_common.gd")
const ExprRows = preload("res://addons/expr_rows.gd")

const MAP_DIR := "res://tools/maps/"
const PLAYTEST_FILE := "user://map_playtest.json"
## 도구 묶음: [묶음 이름, [[도구 id, 버튼 글자], ...]] — 도구 줄에서 구분선으로 나눈다
const TOOL_GROUPS := [
	["", [["select", "선택"]]],
	["칠하기", [["wall", "벽"], ["floor", "바닥"], ["void", "빈 공간"]]],
	["위치", [["arrive", "도착 P"], ["run_start", "시작 S"]]],
	["물체", [["enemy", "적"], ["investigate", "조사"], ["npc", "NPC"], ["camp", "거점"]]],
	["이동", [["exit", "문"], ["passage", "통로"], ["transit", "이용"]]],
	["", [["erase", "지우개"]]],
]
const TOOL_TIPS := {
	"select": "선택·이동: 물체를 클릭하면 오른쪽 칸에 세부, 끌면 옮김.\nShift+클릭 = 여러 개, 빈 곳을 끌면 영역 선택, 빈 칸 클릭 = 맵 설정",
	"wall": "벽: 누른 채 끌어서 칠함 (지나갈 수 없음)",
	"floor": "바닥: 누른 채 끌어서 칠함 (걸어 다니는 곳)",
	"void": "빈 공간: 누른 채 끌어서 칠함 (검게 보이고 지나갈 수 없음)",
	"arrive": "도착 P: 다른 맵에서 들어올 때 서는 곳. 오른쪽 칸 '이어지는 곳'에서 어느 입구로 오면 여기 설지 고름.\n★ = 기본 P (이어지지 않은 곳 — 베이스캠프만 필수)",
	"run_start": "회차 시작 S: 새 회차를 이 맵에서 시작할 때 깨어나는 곳 (Config start_map 의 맵에서만 쓰임)",
	"enemy": "적: 놓은 뒤 오른쪽 칸에서 적 종류·순찰 방향·칸 수",
	"investigate": "조사 지점: 놓은 뒤 오른쪽 칸에서 얻는 것(Loot)·조사 문구",
	"npc": "NPC: 놓은 뒤 오른쪽 칸에서 대화(시작 노드)·나타나는 시간대",
	"camp": "베이스캠프 거점 (식사·물·씻기·잠 메뉴, 엑셀 CampActions)",
	"exit": "문: E 로 열고, 열린 문으로 걸어 들어가면 이동. 오른쪽 칸에서 이동할 맵",
	"passage": "통로: 밟으면 바로 이동 (계단·길·동굴 입구)",
	"transit": "이용: E 를 눌러야 이동 (사다리·엘리베이터 등). 이름이 안내에 나옴",
	"erase": "지우개: 클릭한 물체(또는 S)를 지움. 벽은 바닥으로 칠해서 지움",
}
const HELP_TEXT := """[b]맵 탭 쓰는 법[/b]

[b]화면[/b]
  왼쪽 — 찾기(모든 맵에서 이름·ID·종류) · 맵 목록(→ 이어지는 맵) · 표시 필터
  가운데 — 맵. 휠: 확대·축소, 휠 버튼·오른쪽 버튼 끌기: 화면 이동
  오른쪽 — 고른 물체의 설정 (아무것도 안 고르면 맵 크기·가장자리 설정)

[b]1. 모양[/b]  [b]칠하기[/b]의 벽 / 바닥 / 빈 공간을 고르고 맵 위를 끌면 칠해집니다. [b]□ 사각형[/b]을 켜거나 Shift 를 누른 채 끌면 사각형으로 채웁니다.

[b]2. 물체[/b]  [b]물체[/b]·[b]이동[/b]·[b]위치[/b]의 도구로 바닥 칸을 클릭해 놓고, 오른쪽 칸에서 고칩니다.
  · 적: 적 종류, 순찰 방향과 칸 수 (고르면 순찰 길과 시야가 보임)
  · 조사: 얻는 것(엑셀 Loot), 조사 문구    · NPC: 대화 시작 카드, 나타나는 시간대
  · 나타나는 조건: [b]＋ 조건 추가[/b]로 고름 (예: 플래그가 켜져 있을 때만)

[b]3. 맵 이동[/b]
  · 문(E 로 열고 걸어 들어감) · 통로(밟으면 바로) · 이용(E, 사다리 등) · 가장자리(맵 설정에서 위·아래·왼쪽·오른쪽 끝)
  · [b]도착 P[/b]: 들어올 때 서는 곳. 여러 개 찍고, P 를 눌러 [b]이어지는 곳[/b](어느 맵의 어느 입구로 오면 여기)을 체크합니다.
  · ★ [b]기본 P[/b]: 아무 P 에도 이어지지 않은 곳으로 들어올 때. [b]베이스캠프만 필수[/b](부활·불러오기 때 깨어나는 곳).
    다른 맵은 없어도 되지만 그러면 들어오는 곳마다 P 를 이어 둬야 합니다.
  · 문 아래에 '→ 맵 · 도착 P', P 아래에 '← 들어오는 곳'이 보입니다 (고르거나 마우스를 올렸을 때). 잘못된 연결은 빨간 ⚠.
  · 문을 [b]더블클릭[/b]하면 이어진 맵을 열고 도착 P 로 갑니다.

[b]4. 고치기[/b]  (단축키는 맵을 한 번 누른 뒤)
  · 선택: 클릭 · Shift+클릭(여러 개) · 빈 곳 끌기(영역) · Ctrl+A(모두) · Esc(해제). 고른 것들을 함께 끌어 옮기고, 오른쪽 칸에서 한꺼번에 바꿉니다.
  · ↶ ↷ 실행 취소·다시 실행 (Ctrl+Z / Ctrl+Y)  · [b]편집 ▾[/b]: 복사(Ctrl+C) · 붙여넣기(Ctrl+V, 마우스가 있는 칸) · 삭제(Delete)

[b]5. 반영[/b]  [b]저장[/b] → [b]변환·검사[/b] (오류가 있으면 아래에 결과 칸이 열림) → [b]▶ 테스트 플레이[/b] (진짜 저장은 건드리지 않음)

[b]지도 표시[/b]  [color=#3fae5f]● P[/color] 도착 P (★ 기본) · [color=#b89a2a]S[/color] 회차 시작 · [color=#d05050]● 적[/color] · [color=#e8c35a]● 조[/color] 조사 · [color=#5a8fd0]● N[/color] NPC · [color=#5fae6a]● 거[/color] 거점 · [color=#a07850]● 문[/color] · [color=#6fa8dc]● 통[/color] 통로 · [color=#c8a060]● 이[/color] 이용 · 맵 바깥 푸른 띠 = 가장자리 이동
"""
const TYPE_NAME :={"enemy": "적", "investigate": "조사 지점", "npc": "NPC", "camp": "베이스캠프 거점", "exit": "출구(문)",
	"passage": "통로", "transit": "이용 (사다리 등)", "arrive": "도착 P"}
const EDGES := [["up", "위"], ["down", "아래"], ["left", "왼쪽"], ["right", "오른쪽"]]

var dir := MAP_DIR                   # 테스트에서 바꿔 쓴다
var map := {}
var path := ""
var dirty := false

var canvas: Control
var files: OptionButton
var status: Label
var inspector: VBoxContainer
var log_view: TextEdit
var log_box: VBoxContainer             # 아래 결과 칸 (변환·검사 실패 때만 열림)
var tool_buttons := {}
# 목록 (data/*.json 에서)
var enemies: Array = []              # [[id, 이름]]
var dialogue_starts: Array = []      # 필드 대화 노드
var loot_spots: Array = []
var map_ids: Array = []
var lookups := {}                    # 조건 고르기 (ToolCommon.load_lookups)
var basecamp_id := "basecamp"        # Config basecamp_map — ★ 기본 P 가 꼭 있어야 하는 맵
# 실행 취소: 맵 상태 스냅샷 (tiles·objects·start·run_start·edges)
const UNDO_MAX := 100
var _undo: Array = []
var _redo: Array = []
var _pending_snap = null             # 누름 시작 때 스냅샷 — 실제로 바뀌면 실행 취소 기록에 들어감
var _last_ck := ""                   # 오른쪽 칸에서 같은 칸을 연달아 고칠 때 한 번만 기록
var _clip := {}                      # 복사한 것 { size: Vector2i, tiles: [String], objects: [상대 위치] }
# 왼쪽 칸: 검색 · 맵 목록 · 표시 필터
var _all_maps := {}                  # map_id → 맵 내용 (지금 맵은 편집 중인 것)
var map_list: ItemList
var search: LineEdit
var results: ItemList
var filter_boxes := {}


func _init() -> void:
	size_flags_vertical = SIZE_EXPAND_FILL
	size_flags_horizontal = SIZE_EXPAND_FILL
	add_theme_constant_override("separation", 2)
	# ---- 위 줄: 맵 · 파일 · 실행 취소·편집 · 변환·테스트 · 상태 · 사용법
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 2)
	add_child(bar)
	files = OptionButton.new()
	files.custom_minimum_size.x = 180
	files.fit_to_longest_item = false
	files.item_selected.connect(func(i): open_map(files.get_item_text(i)))
	files.tooltip_text = "편집할 맵 (tools/maps/). 다른 맵을 고르면 지금 맵은 자동 저장"
	bar.add_child(files)
	bar.add_child(VSeparator.new())
	_bar_btn(bar, "새 맵", _ask_new, "새 맵 파일 만들기 (맵 ID: 영문·숫자·_, 너비·높이)")
	_bar_btn(bar, "저장", save, "지금 맵을 파일로 저장")
	bar.add_child(VSeparator.new())
	_bar_btn(bar, "↶", undo, "실행 취소 (Ctrl+Z)")
	_bar_btn(bar, "↷", redo, "다시 실행 (Ctrl+Y)")
	var edit_menu := MenuButton.new()
	edit_menu.text = "편집 ▾"
	edit_menu.tooltip_text = "복사·붙여넣기·삭제·선택"
	var pm := edit_menu.get_popup()
	for it in [["복사   Ctrl+C", copy_selection], ["붙여넣기   Ctrl+V  (마우스가 있는 칸)", func(): paste_at(canvas._hover)],
			["삭제   Delete", delete_selection], [], ["모두 선택   Ctrl+A", func(): canvas.select_many(map.get("objects", []).filter(canvas.is_visible_object))],
			["선택 해제   Esc", func(): canvas.select({})]]:
		if it.is_empty():
			pm.add_separator()
			continue
		pm.add_item(it[0])
		pm.set_item_metadata(pm.item_count - 1, it[1])
	pm.index_pressed.connect(func(i): (pm.get_item_metadata(i) as Callable).call())
	bar.add_child(edit_menu)
	bar.add_child(VSeparator.new())
	_bar_btn(bar, "변환·검사", run_convert, "저장하고 변환기로 오류 검사. 오류가 없어야 게임에 반영됩니다")
	_bar_btn(bar, "▶ 테스트 플레이", playtest, "이 맵에서 바로 게임 실행 (진짜 저장·회차는 건드리지 않음)")
	status = Label.new()
	status.size_flags_horizontal = SIZE_EXPAND_FILL
	status.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	status.clip_text = true   # 긴 상태 글자가 에디터 폭을 넓히지 않게
	status.custom_minimum_size.x = 80
	status.modulate = Color(1, 1, 1, 0.7)
	bar.add_child(status)
	ToolCommon.add_help_window(self, bar, "맵 탭 쓰는 법", HELP_TEXT)
	# ---- 도구 줄: 묶음별 (선택 │ 칠하기 │ 위치 │ 물체 │ 이동 │ 지우개)
	var tools := HBoxContainer.new()
	tools.add_theme_constant_override("separation", 2)
	add_child(tools)
	var group := ButtonGroup.new()
	for gi in TOOL_GROUPS.size():
		var g: Array = TOOL_GROUPS[gi]
		if gi > 0:
			tools.add_child(VSeparator.new())
		if g[0] != "":
			var cap := Label.new()
			cap.text = g[0]
			cap.modulate = Color(1, 1, 1, 0.45)
			tools.add_child(cap)
		for t in g[1]:
			var b := Button.new()
			b.text = t[1]
			b.toggle_mode = true
			b.flat = true
			b.button_group = group
			b.tooltip_text = TOOL_TIPS.get(t[0], "")
			b.pressed.connect(set_tool.bind(t[0]))
			tools.add_child(b)
			tool_buttons[t[0]] = b
		if g[0] == "칠하기":
			var rect := Button.new()
			rect.text = "□ 사각형"
			rect.toggle_mode = true
			rect.flat = true
			rect.tooltip_text = "켜면 벽·바닥·빈 공간을 끌어서 사각형으로 채움 (Shift 를 누른 채 끌어도 됨)"
			rect.toggled.connect(func(on): canvas.rect_mode = on)
			tools.add_child(rect)
	# ---- 왼쪽 칸 │ 맵 │ 오른쪽 칸
	var outer := HSplitContainer.new()
	outer.size_flags_vertical = SIZE_EXPAND_FILL
	add_child(outer)
	outer.add_child(_build_left_panel())
	var split := HSplitContainer.new()
	split.size_flags_horizontal = SIZE_EXPAND_FILL
	outer.add_child(split)
	canvas = Canvas.new()
	canvas.size_flags_horizontal = SIZE_EXPAND_FILL
	canvas.id_maker = _new_object_id
	canvas.changed.connect(func():
		if _pending_snap != null:
			_push_undo(_pending_snap)
			_pending_snap = null
		dirty = true
		_status("수정됨 (저장 안 함)"))
	canvas.selection_changed.connect(_edit_object)
	canvas.stroke_started.connect(func():
		_pending_snap = _snapshot()
		_last_ck = "")
	canvas.request.connect(_on_canvas_request)
	canvas.activated.connect(follow_link)
	split.add_child(canvas)
	var side := ScrollContainer.new()
	side.custom_minimum_size.x = 340
	side.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED   # 긴 글자는 칸 폭에 맞춰 줄임
	split.add_child(side)
	var pad := MarginContainer.new()
	pad.size_flags_horizontal = SIZE_EXPAND_FILL
	for m in ["margin_left", "margin_right", "margin_top"]:
		pad.add_theme_constant_override(m, 8)
	side.add_child(pad)
	inspector = VBoxContainer.new()
	inspector.size_flags_horizontal = SIZE_EXPAND_FILL
	inspector.add_theme_constant_override("separation", 4)
	pad.add_child(inspector)
	# ---- 아래: 변환·검사 결과 (실패했을 때만 열림, 닫을 수 있음)
	log_box = VBoxContainer.new()
	log_box.visible = false
	add_child(log_box)
	var log_head := HBoxContainer.new()
	log_box.add_child(log_head)
	var lt := Label.new()
	lt.text = "변환·검사 결과"
	lt.size_flags_horizontal = SIZE_EXPAND_FILL
	log_head.add_child(lt)
	var lclose := Button.new()
	lclose.text = "✕"
	lclose.flat = true
	lclose.tooltip_text = "결과 닫기"
	lclose.pressed.connect(func(): log_box.visible = false)
	log_head.add_child(lclose)
	log_view = TextEdit.new()
	log_view.editable = false
	log_view.custom_minimum_size.y = 120
	log_box.add_child(log_view)
	set_tool("select")


func _bar_btn(bar: HBoxContainer, text: String, action: Callable, tip: String) -> void:
	var b := Button.new()
	b.text = text
	b.flat = true
	b.tooltip_text = tip
	b.pressed.connect(action)
	bar.add_child(b)


func _ready() -> void:
	refresh_file_list()


# ---------------------------------------------------------------- 파일
func refresh_file_list() -> void:
	_load_lookups()
	var current: String = map.get("map_id", "")
	files.clear()
	map_ids = []
	var d := DirAccess.open(dir)
	if d:
		for f in d.get_files():
			if f.ends_with(".json"):
				map_ids.append(f.get_basename())
	map_ids.sort()
	for m in map_ids:
		files.add_item(m)
	if current == "" and not map_ids.is_empty():
		open_map(map_ids[0])
	else:
		_select_file_item(current)


func open_map(id: String) -> void:
	if dirty and not map.is_empty():
		save()
	var p := dir + id + ".json"
	var parsed = ToolCommon.read_json(p, null)
	if not parsed is Dictionary:
		_status("열 수 없음: " + p)
		return
	map = parsed
	map.map_id = id
	for o in map.get("objects", []):
		o.x = int(o.x)
		o.y = int(o.y)
		o.patrol_len = int(o.get("patrol_len", 0))
	if not map.has("objects"):
		map.objects = []
	for key in ["start", "run_start"]:   # JSON 숫자는 float → 칸 좌표는 int
		var pos = map.get(key)
		map[key] = [int(pos[0]), int(pos[1])] if pos is Array and pos.size() == 2 else null
	# 예전 맵 (도착 P 물체가 하나도 없음): 기본 도착 위치(start)를 ★ 기본 P 물체로
	var ps: Array = map.objects.filter(func(o): return o.type == "arrive")
	if ps.is_empty():
		var st: Array = map.start if map.start != null else [1, 1]
		map.objects.insert(0, {"object_id": id + "_p", "type": "arrive", "x": st[0], "y": st[1], "ref": "", "name": "기본",
			"text": "", "patrol_dir": "", "patrol_len": 0, "condition": "", "schedule": "", "arrive": "", "default": true})
	elif id == basecamp_id and not ps.any(func(o): return o.get("default", false)):
		ps[0].default = true   # 베이스캠프는 기본 P 필수
	path = p
	canvas.require_default = id == basecamp_id
	canvas.set_map(map)
	dirty = false
	_undo.clear()
	_redo.clear()
	_select_file_item(id)
	_load_all_maps()
	_edit_map()
	_status("열림: " + id)


func new_map(id: String, w: int, h: int) -> bool:
	id = id.strip_edges()
	if not RegEx.create_from_string("^[A-Za-z0-9_]+$").search(id):
		_status("맵 ID 는 영문·숫자·_ 만")
		return false
	if FileAccess.file_exists(dir + id + ".json"):
		_status("이미 있는 맵: " + id)
		return false
	DirAccess.make_dir_recursive_absolute(dir)
	w = clampi(w, 3, 300)
	h = clampi(h, 3, 300)
	var tiles := []
	for y in h:
		var row := ""
		for x in w:
			row += "#" if x == 0 or y == 0 or x == w - 1 or y == h - 1 else "."
		tiles.append(row)
	map = {"map_id": id, "tiles": tiles, "start": [w / 2, h / 2], "run_start": null, "objects": [
		{"object_id": id + "_p", "type": "arrive", "x": w / 2, "y": h / 2, "ref": "", "name": "", "text": "",
		"patrol_dir": "", "patrol_len": 0, "condition": "", "schedule": "", "arrive": ""}]}
	if id == basecamp_id:
		map.objects[0].default = true
	canvas.require_default = id == basecamp_id
	path = dir + id + ".json"
	canvas.set_map(map)
	_undo.clear()
	_redo.clear()
	save()
	refresh_file_list()
	_select_file_item(id)
	_edit_map()
	return true


func save() -> void:
	if map.is_empty():
		return
	var dp: Dictionary = canvas.default_p()
	var ps: Array = map.objects.filter(func(o): return o.type == "arrive")
	if not dp.is_empty():
		map.start = [int(dp.x), int(dp.y)]   # 기본 P 자리 = start (게임·변환기가 읽음)
	elif not ps.is_empty():
		map.start = [int(ps[0].x), int(ps[0].y)]   # 기본 P 가 없으면 첫 P (테스트 플레이 시작 자리)
	var out := {"map_id": map.map_id, "tiles": map.tiles, "start": map.get("start"), "run_start": map.get("run_start"),
		"objects": []}
	# 새로 생긴 항목(가장자리 edges, 도착 지점 arrive)은 쓸 때만 파일에 적는다 (예전 맵 파일이 그대로 유지되게)
	if not map.get("edges", {}).is_empty():
		out.edges = map.edges
	for o in map.objects:
		var e := {}
		for k in ["object_id", "type", "x", "y", "ref", "name", "text", "patrol_dir", "patrol_len", "condition", "schedule"]:
			e[k] = o.get(k, "" if k not in ["x", "y", "patrol_len"] else 0)
		if o.get("arrive", "") != "" or o.has("arrive"):
			e.arrive = o.get("arrive", "")
		if not o.get("from", []).is_empty():
			e.from = o.from
		if o.get("default", false):
			e.default = true
		out.objects.append(e)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		_status("저장 실패: " + path)
		return
	f.store_string(JSON.stringify(out, " ", false) + "\n")
	f.close()
	dirty = false
	_load_all_maps()
	_status("저장함: " + path.get_file())


## 크기 바꾸기: 늘리면 바깥은 빈 공간, 줄이면 밖으로 나간 물체·위치는 지움
func resize_map(w: int, h: int) -> void:
	checkpoint()
	w = clampi(w, 3, 300)
	h = clampi(h, 3, 300)
	var tiles := []
	for y in h:
		var row := String(map.tiles[y]) if y < map.tiles.size() else ""
		row = row.substr(0, w)
		while row.length() < w:
			row += " "
		tiles.append(row)
	map.tiles = tiles
	map.objects = map.objects.filter(func(o): return o.x < w and o.y < h)
	if not map.objects.any(func(o): return o.type == "arrive"):   # 도착 P 가 모두 잘려 나가면 (1,1) 에 기본 P
		map.objects.append({"object_id": map.map_id + "_p", "type": "arrive", "x": 1, "y": 1, "ref": "", "name": "기본",
			"text": "", "patrol_dir": "", "patrol_len": 0, "condition": "", "schedule": "", "arrive": "", "default": true})
	elif not map.objects.any(func(o): return o.type == "arrive" and o.get("default", false)):
		map.objects.filter(func(o): return o.type == "arrive")[0].default = true
	for key in ["start", "run_start"]:
		var p = map.get(key)
		if p is Array and (int(p[0]) >= w or int(p[1]) >= h):
			map[key] = [1, 1] if key == "start" else null
	canvas.set_map(map)
	dirty = true
	_edit_map()


# ---------------------------------------------------------------- 변환·테스트 플레이
func run_convert() -> bool:
	if dirty:
		save()
	var ok: bool = ToolCommon.run_convert(log_view)
	log_box.visible = not ok
	_status("변환 성공 ✓" if ok else "변환 실패 — 아래 결과를 확인하세요")
	if ok:
		_load_lookups()
	return ok


## 이 맵에서 새 회차처럼 바로 실행 (실제 저장·회차 수는 건드리지 않음)
func playtest() -> void:
	if map.is_empty() or not run_convert():
		return
	var f := FileAccess.open(PLAYTEST_FILE, FileAccess.WRITE)
	f.store_string(JSON.stringify({"map": map.map_id}))
	f.close()
	if Engine.is_editor_hint():
		EditorInterface.play_custom_scene("res://addons/map_editor/playtest.tscn")


# ---------------------------------------------------------------- 오른쪽 칸
func set_tool(t: String) -> void:
	canvas.tool = t
	if tool_buttons.has(t):
		tool_buttons[t].button_pressed = true


func _edit_map() -> void:
	_refresh_links()
	_clear_inspector()
	if map.is_empty():
		return
	_title("맵  " + map.map_id)
	_hint("물체를 고르면 여기에 설정이 나옵니다.")
	_section("크기 (칸)")
	var w := String(map.tiles[0]).length() if not map.tiles.is_empty() else 0
	var row := HBoxContainer.new()
	var ws := SpinBox.new()
	ws.min_value = 3
	ws.max_value = 300
	ws.value = w
	ws.prefix = "너비"
	ws.size_flags_horizontal = SIZE_EXPAND_FILL
	var hs := SpinBox.new()
	hs.min_value = 3
	hs.max_value = 300
	hs.value = map.tiles.size()
	hs.prefix = "높이"
	hs.size_flags_horizontal = SIZE_EXPAND_FILL
	var apply := Button.new()
	apply.text = "적용"
	apply.pressed.connect(func(): resize_map(int(ws.value), int(hs.value)))
	row.add_child(ws)
	row.add_child(hs)
	row.add_child(apply)
	inspector.add_child(row)
	_section("가장자리로 나가면")
	_hint("그쪽 맨 끝 바닥 칸에 닿으면 이동 (맵 끝에 바닥을 터 두세요)")
	if not map.has("edges") or not map.edges is Dictionary:
		map.edges = {}
	for d in EDGES:
		var dir_id: String = d[0]
		var e: Dictionary = map.edges.get(dir_id, {})
		_option("%s →" % d[1], [["", "(없음)"]] + map_ids.map(func(m): return [m, m]), e.get("ref", ""), func(v):
			checkpoint()
			if v == "":
				map.edges.erase(dir_id)
			else:
				map.edges[dir_id] = {"ref": v, "arrive": ""}
			dirty = true
			canvas.queue_redraw()
			_edit_map.call_deferred())
		if e.get("ref", "") != "":
			_option("   도착 P", _arrive_options(e.ref), e.get("arrive", ""), func(v):
				checkpoint()
				map.edges[dir_id].arrive = v
				dirty = true)


func _edit_object(o: Dictionary) -> void:
	if canvas.selection.size() > 1:
		_edit_multi(canvas.selection)
		return
	if o.is_empty():
		_edit_map()
		return
	_clear_inspector()
	_title("%s  (%d, %d)" % [TYPE_NAME.get(o.type, o.type), o.x, o.y])
	var link: Array = canvas.link_labels.get(o.object_id, [])
	if not link.is_empty():
		_note(("" if link[1] else "⚠ ") + link[0], Color("9cc4ec") if link[1] else Color("ff6060"))
	if o.type in ["exit", "passage", "transit"] and o.get("ref", "") in _all_maps:
		var go := Button.new()
		go.text = "→ %s 열기" % o.ref
		go.tooltip_text = "이어진 맵을 열고 도착하는 P 를 고릅니다 (맵에서 더블클릭해도 됨)"
		go.pressed.connect(follow_link.bind(o))
		inspector.add_child(go)
	_section("기본")
	_line("ID", o.object_id, func(v): set_field(o, "object_id", v))
	_line("이름", o.get("name", ""), func(v): set_field(o, "name", v), "화면에 보이는 이름")
	match o.type:
		"enemy":
			_section("적")
			_option("종류", enemies, o.get("ref", ""), func(v): set_field(o, "ref", v))
			_option("순찰 방향", [["", "(가만히)"], ["up", "위"], ["down", "아래"], ["left", "왼쪽"], ["right", "오른쪽"]],
				o.get("patrol_dir", ""), func(v): set_field(o, "patrol_dir", v))
			var sp := _spin("순찰 칸 수", int(o.get("patrol_len", 0)), 0, 100)
			sp.tooltip_text = "그 칸 수만큼 왕복"
			sp.value_changed.connect(func(v): set_field(o, "patrol_len", int(v)))
		"npc":
			_section("NPC")
			_option("대화", dialogue_starts, o.get("ref", ""), func(v): set_field(o, "ref", v))
			_line("시간대", o.get("schedule", ""), func(v): set_field(o, "schedule", v), "06:00-12:00, 20:00-23:00 (비우면 항상)")
		"investigate":
			_section("조사")
			_option("얻는 것", [["", "(없음)"]] + loot_spots, o.get("ref", ""), func(v): set_field(o, "ref", v))
			var te := TextEdit.new()
			te.text = o.get("text", "")
			te.placeholder_text = "조사할 때 나오는 문구"
			te.custom_minimum_size.y = 90
			te.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
			te.text_changed.connect(func(): set_field(o, "text", te.text))
			inspector.add_child(te)
		"exit", "passage", "transit":
			_section("이동")
			_option("이동할 맵", map_ids.map(func(m): return [m, m]), o.get("ref", ""), func(v):
				set_field(o, "ref", v)
				set_field(o, "arrive", "")
				_edit_object.call_deferred(o))
			if o.get("ref", "") != "":
				_option("도착 P", _arrive_options(o.ref), o.get("arrive", ""), func(v): set_field(o, "arrive", v))
		"arrive":
			_section("도착 P")
			var dcb := CheckBox.new()
			var base: bool = map.map_id == basecamp_id
			dcb.text = "★ 기본 P"
			dcb.tooltip_text = "아무 P 에도 이어지지 않은 곳으로 들어올 때 서는 P.%s" % (
				"\n베이스캠프는 부활·불러오기 때 깨어나는 곳이라 꼭 하나 (다른 P 에서 체크해야 옮겨짐)" if base else "\n이 맵은 없어도 됨 (그러면 들어오는 곳마다 P 를 이어 둘 것)")
			dcb.button_pressed = o.get("default", false)
			dcb.disabled = base and o.get("default", false)
			dcb.toggled.connect(func(on):
				checkpoint()
				for x in map.objects:
					if x.type == "arrive" and (on or x == o):
						x.erase("default")
				if on:
					o.default = true
				dirty = true
				_refresh_links()
				canvas.queue_redraw()
				_edit_object.call_deferred(o))
			inspector.add_child(dcb)
			_section("이어지는 곳")
			_hint("체크한 입구로 이 맵에 들어오면 이 P 에 섭니다")
			var ents := _entrances_to(map.map_id)
			if ents.is_empty():
				_hint("이 맵으로 들어오는 곳이 아직 없습니다")
			var from: Array = o.get("from", [])
			for e in ents:
				var cb := CheckBox.new()
				cb.text = e[1]
				cb.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
				cb.button_pressed = e[0] in from
				var src: String = e[0]
				var erow := HBoxContainer.new()
				cb.size_flags_horizontal = SIZE_EXPAND_FILL
				erow.add_child(cb)
				var open := Button.new()
				open.text = "↗"
				open.flat = true
				open.tooltip_text = "그 입구가 있는 맵을 열고 그 물체를 고릅니다"
				open.pressed.connect(func(): goto_entrance(src))
				erow.add_child(open)
				cb.toggled.connect(func(on):
					var f: Array = o.get("from", []).duplicate()
					if on and not src in f:
						f.append(src)
					elif not on:
						f.erase(src)
					set_field(o, "from", f))
				inspector.add_child(erow)
	_section("나타나는 조건")
	var rows: Node = ExprRows.new().setup("cond", o.get("condition", ""), lookups)
	rows.changed.connect(func(v): set_field(o, "condition", v))
	inspector.add_child(rows)
	inspector.add_child(HSeparator.new())
	var del := Button.new()
	del.text = "이 물체 지우기"
	del.add_theme_color_override("font_color", Color("ff7070"))
	del.pressed.connect(func():
		if o.type == "arrive" and not canvas.release_p(o):
			_status("베이스캠프의 마지막 기본 P 는 지울 수 없음")
			return
		checkpoint()
		map.objects.erase(o)
		canvas.select({})
		dirty = true
		_refresh_links())
	inspector.add_child(del)


## map_id 맵으로 들어오는 곳 [[id, 설명]]: 다른 맵 파일들의 문·통로·이용(object_id)과 가장자리("맵:방향")
func _entrances_to(map_id: String) -> Array:
	var out := []
	var type_name := {"exit": "문", "passage": "통로", "transit": "이용"}
	var edge_name := {"up": "위", "down": "아래", "left": "왼쪽", "right": "오른쪽"}
	var d := DirAccess.open(dir)
	if d == null:
		return out
	for f in d.get_files():
		if not f.ends_with(".json"):
			continue
		var mid := f.get_basename()
		var m: Dictionary = map if mid == map_id else ToolCommon.read_json(dir + f, {})
		for o in m.get("objects", []):
			if o.get("type", "") in type_name and o.get("ref", "") == map_id:
				var nm: String = o.get("name", "") if o.get("name", "") != "" else o.object_id
				var note := "  (문 쪽에서 다른 P 를 골랐음)" if o.get("arrive", "") != "" else ""
				out.append([o.object_id, "%s — %s: %s%s" % [mid, type_name[o.type], nm, note]])
		for dir_id in m.get("edges", {}):
			if m.edges[dir_id].get("ref", "") == map_id:
				out.append(["%s:%s" % [mid, dir_id], "%s — %s 가장자리" % [mid, edge_name.get(dir_id, dir_id)]])
	return out


## map_id 맵의 도착 지점 목록 [["", P], [arrive id, 이름]] (그 맵 파일에서 읽음 — 지금 연 맵이면 편집 중인 내용)
func _arrive_options(map_id: String) -> Array:
	var objs: Array = map.objects if map_id == map.get("map_id", "") else ToolCommon.read_json(dir + map_id + ".json", {}).get("objects", [])
	var out := [["", "(그 맵 P 쪽 설정대로 — 없으면 ★ 기본 P)"]]
	for o in objs:
		if o.get("type", "") == "arrive":
			out.append([o.object_id, "P: %s  (%s)" % [o.get("name", "") if o.get("name", "") != "" else o.object_id, o.object_id]])
	return out


func set_field(o: Dictionary, key: String, v: Variant) -> void:
	checkpoint("%s/%s" % [o.get("object_id", ""), key])
	o[key] = v
	dirty = true
	if key in ["ref", "arrive", "from", "object_id", "name"]:
		_refresh_links()
	canvas.queue_redraw()


# ---------------------------------------------------------------- 여러 개 고쳤을 때 (속성 묶음 편집)
func _edit_multi(objs: Array) -> void:
	_clear_inspector()
	_title("%d개 선택" % objs.size())
	var names := objs.map(func(o): return "%s %s" % [TYPE_NAME.get(o.type, o.type), o.name if o.name != "" else o.object_id])
	_hint("\n".join(names.slice(0, 12)) + ("\n…" if names.size() > 12 else ""))
	var types := {}
	for o in objs:
		types[o.type] = true
	if types.size() == 1:
		_hint("같은 종류라 아래 값을 한꺼번에 바꿀 수 있습니다. 값이 서로 다르면 '(고르세요)'.")
		match objs[0].type:
			"enemy":
				_multi_option(objs, "적 종류", enemies, "ref")
				_multi_option(objs, "순찰 방향", [["", "(가만히)"], ["up", "위"], ["down", "아래"], ["left", "왼쪽"], ["right", "오른쪽"]], "patrol_dir")
			"npc":
				_multi_option(objs, "대화 (시작 노드)", dialogue_starts, "ref")
			"investigate":
				_multi_option(objs, "얻는 것", [["", "(없음)"]] + loot_spots, "ref")
			"exit", "passage", "transit":
				_multi_option(objs, "이동할 맵", map_ids.map(func(m): return [m, m]), "ref")
	else:
		_hint("종류가 섞여 있어 공통 칸(나타나는 조건)만 바꿀 수 있습니다.")
	_section("나타나는 조건 (모두에 적용)")
	var same := objs.all(func(o): return o.get("condition", "") == objs[0].get("condition", ""))
	var rows: Node = ExprRows.new().setup("cond", objs[0].get("condition", "") if same else "", lookups)
	rows.changed.connect(func(v):
		checkpoint("multi/condition")
		for o in objs:
			o.condition = v
		dirty = true)
	inspector.add_child(rows)
	inspector.add_child(HSeparator.new())
	var del := Button.new()
	del.text = "고른 %d개 지우기 (Delete)" % objs.size()
	del.add_theme_color_override("font_color", Color("ff7070"))
	del.pressed.connect(delete_selection)
	inspector.add_child(del)


func _multi_option(objs: Array, label: String, items: Array, key: String) -> void:
	var cur: String = objs[0].get(key, "")
	if not objs.all(func(o): return o.get(key, "") == cur):
		cur = ""
	_option(label, items, cur, func(v):
		checkpoint("multi/" + key)
		for o in objs:
			o[key] = v
		dirty = true
		_refresh_links()
		canvas.queue_redraw())


## 캔버스 단축키 (Ctrl+Z·Y·C·V, Delete)
func _on_canvas_request(action: String) -> void:
	match action:
		"undo": undo()
		"redo": redo()
		"copy": copy_selection()
		"paste": paste_at(canvas._hover)
		"delete": delete_selection()


# ---------------------------------------------------------------- 실행 취소 / 다시 실행
func _snapshot() -> Dictionary:
	return {"tiles": map.get("tiles", []).duplicate(), "objects": map.get("objects", []).duplicate(true),
		"start": map.get("start"), "run_start": map.get("run_start"), "edges": map.get("edges", {}).duplicate(true)}


func _push_undo(snap: Dictionary) -> void:
	_undo.append(snap)
	if _undo.size() > UNDO_MAX:
		_undo.pop_front()
	_redo.clear()


## 바꾸기 직전에 부른다. key 가 같으면 연달아 고친 것을 한 번으로 묶는다 (글자 입력 등)
func checkpoint(key := "") -> void:
	_pending_snap = null   # 누름 중 기록과 겹치지 않게
	if map.is_empty() or (key != "" and key == _last_ck):
		return
	_last_ck = key
	_push_undo(_snapshot())


func undo() -> void:
	if _undo.is_empty():
		_status("되돌릴 것이 없음")
		return
	_redo.append(_snapshot())
	_restore(_undo.pop_back())
	_status("실행 취소 (남은 %d)" % _undo.size())


func redo() -> void:
	if _redo.is_empty():
		_status("다시 실행할 것이 없음")
		return
	_undo.append(_snapshot())
	_restore(_redo.pop_back())
	_status("다시 실행")


func _restore(snap: Dictionary) -> void:
	map.tiles = snap.tiles.duplicate()
	map.objects = snap.objects.duplicate(true)
	map.start = snap.start
	map.run_start = snap.run_start
	map.edges = snap.edges.duplicate(true)
	_last_ck = ""
	canvas.set_map(map)
	dirty = true
	_refresh_links()
	_edit_map()


# ---------------------------------------------------------------- 복사 / 붙여넣기 / 삭제
## 영역을 골랐으면 그 안의 타일·물체, 아니면 고른 물체들
func copy_selection() -> void:
	var r: Rect2i = canvas.region
	var objs: Array = canvas.objects_in(r) if r.size != Vector2i.ZERO else canvas.selection
	if r.size == Vector2i.ZERO and objs.is_empty():
		_status("복사할 것이 없음 — 물체를 고르거나 빈 곳을 끌어 영역을 고르세요")
		return
	var origin := r.position
	if r.size == Vector2i.ZERO:
		origin = Vector2i(objs.map(func(o): return int(o.x)).min(), objs.map(func(o): return int(o.y)).min())
	var tiles := []
	if r.size != Vector2i.ZERO:
		for y in range(r.position.y, r.end.y):
			tiles.append(String(map.tiles[y]).substr(r.position.x, r.size.x) if y < map.tiles.size() else "")
	var rel := []
	for o in objs:
		var c: Dictionary = o.duplicate(true)
		c.x = int(o.x) - origin.x
		c.y = int(o.y) - origin.y
		rel.append(c)
	_clip = {"size": r.size, "tiles": tiles, "objects": rel}
	_status("복사함: 물체 %d개%s" % [rel.size(), ", 타일 %dx%d" % [r.size.x, r.size.y] if not tiles.is_empty() else ""])


## 칸 at 을 왼쪽 위로 붙여넣기 (맵 밖은 버림, 바닥이 아니거나 물체가 있는 칸의 물체는 건너뜀). 새 물체는 새 ID
func paste_at(at: Vector2i) -> void:
	if _clip.is_empty() or map.is_empty():
		_status("붙여넣을 것이 없음 — 먼저 복사하세요")
		return
	if not canvas.in_bounds(at):
		at = Vector2i(1, 1)
	checkpoint()
	for y in _clip.tiles.size():
		var row: String = _clip.tiles[y]
		for x in row.length():
			var t := at + Vector2i(x, y)
			if canvas.in_bounds(t):
				var ch := row[x]
				var ro := String(map.tiles[t.y])
				map.tiles[t.y] = ro.substr(0, t.x) + ch + ro.substr(t.x + 1)
	var made := []
	for c in _clip.objects:
		var t := at + Vector2i(int(c.x), int(c.y))
		if not canvas.is_floor(t) or not canvas.object_at(t).is_empty():
			continue
		var o: Dictionary = c.duplicate(true)
		o.object_id = _new_object_id(o.type)
		o.x = t.x
		o.y = t.y
		map.objects.append(o)
		made.append(o)
	dirty = true
	_refresh_links()
	canvas.select_many(made, Rect2i(at, _clip.size) if _clip.size != Vector2i.ZERO else Rect2i())
	canvas.changed.emit()
	_status("붙여넣기: 물체 %d개" % made.size())


func delete_selection() -> void:
	if canvas.selection.is_empty():
		return
	checkpoint()
	for o in canvas.selection:
		if o.type == "arrive" and not canvas.release_p(o):
			_status("마지막 도착 P 는 남겨 둠")
			continue
		map.objects.erase(o)
	dirty = true
	canvas.select({})
	_refresh_links()
	_status("지움")


# ---------------------------------------------------------------- 왼쪽 칸: 검색 · 맵 목록 · 표시 필터
func _build_left_panel() -> Control:
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size.x = 230
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var vb := VBoxContainer.new()
	vb.size_flags_horizontal = SIZE_EXPAND_FILL
	vb.size_flags_vertical = SIZE_EXPAND_FILL
	vb.add_theme_constant_override("separation", 4)
	scroll.add_child(vb)
	# 찾기
	var find_box := _fold(vb, "찾기", true)
	search = LineEdit.new()
	search.placeholder_text = "이름·ID·종류 (모든 맵)"
	search.clear_button_enabled = true
	search.text_changed.connect(func(_t): _run_search())
	find_box.add_child(search)
	results = ItemList.new()
	results.custom_minimum_size.y = 120
	results.visible = false
	results.item_clicked.connect(func(i, _p, _b):
		var m: Array = results.get_item_metadata(i)
		goto_object(m[0], m[1]))
	find_box.add_child(results)
	# 맵 목록
	var list_box := _fold(vb, "맵 목록", true)
	map_list = ItemList.new()
	map_list.custom_minimum_size.y = 180
	map_list.size_flags_vertical = SIZE_EXPAND_FILL
	map_list.tooltip_text = "누르면 열기 (마우스를 올리면 이어지는 맵)"
	map_list.item_clicked.connect(func(i, _p, _b): open_map(map_list.get_item_metadata(i)))
	list_box.add_child(map_list)
	list_box.size_flags_vertical = SIZE_EXPAND_FILL
	# 표시 필터
	var filt_box := _fold(vb, "표시", false)
	var grid := GridContainer.new()
	grid.columns = 2
	filt_box.add_child(grid)
	for f in [["tiles", "타일"], ["enemy", "적"], ["investigate", "조사"], ["npc", "NPC"], ["camp", "거점"],
			["travel", "문·통로·이용"], ["arrive", "도착 P"], ["sight", "순찰"], ["names", "이름표"], ["links", "연결"]]:
		var cb := CheckBox.new()
		cb.text = f[1]
		cb.button_pressed = true
		var key: String = f[0]
		cb.toggled.connect(func(on):
			canvas.filters[key] = on
			canvas.select_many(canvas.selection.filter(canvas.is_visible_object))
			canvas.queue_redraw())
		grid.add_child(cb)
		filter_boxes[key] = cb
	return scroll


## 접고 펼치는 구역: 머리글 버튼 + 내용 상자 (내용 상자를 돌려준다)
func _fold(parent: Control, title: String, open: bool) -> VBoxContainer:
	var head := Button.new()
	head.flat = true
	head.alignment = HORIZONTAL_ALIGNMENT_LEFT
	head.toggle_mode = true
	head.button_pressed = open
	parent.add_child(head)
	var body := VBoxContainer.new()
	body.visible = open
	parent.add_child(body)
	var set_text := func(on: bool): head.text = ("▾ " if on else "▸ ") + title
	set_text.call(open)
	head.toggled.connect(func(on):
		body.visible = on
		set_text.call(on))
	return body


## 모든 맵 파일을 읽어 둔다 (연결 검사·맵 목록·검색). 지금 맵은 편집 중인 내용으로
func _load_all_maps() -> void:
	_all_maps = {}
	var d := DirAccess.open(dir)
	if d:
		for f in d.get_files():
			if f.ends_with(".json"):
				_all_maps[f.get_basename()] = ToolCommon.read_json(dir + f, {})
	if not map.is_empty():
		_all_maps[map.map_id] = map
	_refresh_links()
	_refresh_map_list()
	_run_search()


func _refresh_map_list() -> void:
	if map_list == null:
		return
	map_list.clear()
	for mid in map_ids:
		var m: Dictionary = _all_maps.get(mid, {})
		var outs := {}
		for o in m.get("objects", []):
			if o.get("type", "") in ["exit", "passage", "transit"] and o.get("ref", "") != "":
				outs[o.ref] = true
		for d in m.get("edges", {}):
			if m.edges[d].get("ref", "") != "":
				outs[m.edges[d].ref] = true
		var i := map_list.add_item(("▶ " if mid == map.get("map_id", "") else "   ") + mid)
		map_list.set_item_metadata(i, mid)
		var ins := []
		for e in _entrances_to(mid):
			ins.append("  " + e[1])
		map_list.set_item_tooltip(i, "%s\n\n→ 나가는 곳: %s\n← 들어오는 곳:\n%s" % [mid, ", ".join(outs.keys()) if not outs.is_empty() else "(없음)",
			"\n".join(ins) if not ins.is_empty() else "  (없음)"])


func _run_search() -> void:
	if results == null:
		return
	results.clear()
	var q := search.text.strip_edges().to_lower()
	results.visible = q != ""
	if q == "":
		return
	var enemy_names := {}
	for e in enemies:
		enemy_names[e[0]] = e[1]
	for mid in map_ids:
		for o in _all_maps.get(mid, {}).get("objects", []):
			var hay := " ".join([o.get("object_id", ""), o.get("name", ""), o.get("ref", ""), o.get("type", ""),
				TYPE_NAME.get(o.get("type", ""), ""), enemy_names.get(o.get("ref", ""), "")]).to_lower()
			if q in hay:
				var nm: String = o.get("name", "") if o.get("name", "") != "" else o.get("object_id", "")
				var i := results.add_item("%s — %s (%s)" % [mid, nm, TYPE_NAME.get(o.get("type", ""), o.get("type", ""))])
				results.set_item_metadata(i, [mid, o.get("object_id", "")])
	if results.item_count == 0:
		results.add_item("(없음)")
		results.set_item_disabled(0, true)


## 맵을 열고 그 물체를 골라 화면 가운데로
func goto_object(map_id: String, object_id: String) -> void:
	if map.get("map_id", "") != map_id:
		open_map(map_id)
	for o in map.get("objects", []):
		if o.object_id == object_id:
			canvas.select(o)
			canvas.center_on(Vector2i(int(o.x), int(o.y)))
			return


## 이어지는 곳(object_id 또는 "맵:방향")이 있는 맵을 연다
func goto_entrance(src: String) -> void:
	if ":" in src:
		open_map(src.split(":")[0])
		canvas.select({})
		return
	for mid in _all_maps:
		for o in _all_maps[mid].get("objects", []):
			if o.get("object_id", "") == src:
				goto_object(mid, src)
				return


## 문·통로·이용: 이어진 맵을 열고 도착하는 P 를 고른다 (더블클릭·버튼)
func follow_link(o: Dictionary) -> void:
	if not o.get("type", "") in ["exit", "passage", "transit"] or not o.get("ref", "") in _all_maps:
		return
	var target := _arrival_of(o.object_id, o.ref, o.get("arrive", ""))
	if target[0] != "":
		goto_object(o.ref, target[0])
	else:
		open_map(o.ref)
		var st = map.get("start")
		if st is Array:
			canvas.center_on(Vector2i(int(st[0]), int(st[1])))
	_status("%s 에서 이어진 맵: %s (%s)" % [o.object_id, o.ref, target[1]])


## 들어온 곳 src 가 ref 맵의 어디에 도착하나 → [도착 P object_id (기본 P 면 ""), 이름]
func _arrival_of(src: String, ref: String, explicit: String) -> Array:
	var m: Dictionary = _all_maps.get(ref, {})
	for a in m.get("objects", []):
		if a.get("type", "") != "arrive":
			continue
		if (explicit != "" and a.object_id == explicit) or (explicit == "" and src in a.get("from", [])):
			return [a.object_id, a.get("name", "") if a.get("name", "") != "" else a.object_id]
	for a in m.get("objects", []):
		if a.get("type", "") == "arrive" and a.get("default", false) and explicit == "":
			return [a.object_id, "★ " + (a.get("name", "") if a.get("name", "") != "" else "기본 P")]
	if explicit == "" and not m.get("objects", []).any(func(a): return a.get("type", "") == "arrive"):
		return ["", "P"]   # 예전 맵: start 가 기본
	return ["", ""]   # 설 P 가 없음


## 연결 표시 글자·검사 (문·통로·이용 → 어디, 추가 도착 P ← 어디서, 가장자리)
func _refresh_links() -> void:
	if canvas == null or map.is_empty():
		return
	_all_maps[map.map_id] = map
	var labels := {}
	var ents := {}
	for e in _entrances_to(map.map_id):
		ents[e[0]] = e[1]
	for o in map.objects:
		if o.type in ["exit", "passage", "transit"]:
			labels[o.object_id] = _link_out(o.object_id, o.get("ref", ""), o.get("arrive", ""))
		elif o.type == "arrive":
			var from: Array = o.get("from", [])
			if from.is_empty():
				labels[o.object_id] = ["← (그 밖의 모든 곳)" if o.get("default", false) else "← (이어진 곳 없음)", true]
			else:
				var bad := from.filter(func(f): return not ents.has(f))
				var names := from.map(func(f): return String(ents.get(f, f)).split(" — ")[-1] if ents.has(f) else "⚠ " + f)
				labels[o.object_id] = ["← " + ", ".join(names), bad.is_empty()]
	for d in map.get("edges", {}):
		var e: Dictionary = map.edges[d]
		var info := _link_out("%s:%s" % [map.map_id, d], e.get("ref", ""), e.get("arrive", ""))
		labels["edge:" + d] = ["%s %s" % [Canvas.EDGE_NAME.get(d, d), info[0]], info[1]]
	canvas.link_labels = labels
	canvas.queue_redraw()


func _link_out(src: String, ref: String, explicit: String) -> Array:
	if ref == "":
		return ["→ ? (이동할 맵 없음)", false]
	if not _all_maps.has(ref):
		return ["→ ⚠ 없는 맵 %s" % ref, false]
	var target := _arrival_of(src, ref, explicit)
	if explicit != "" and target[0] == "":
		return ["→ %s · ⚠ 없는 도착 P %s" % [ref, explicit], false]
	if target[1] == "":
		return ["→ %s · ⚠ 설 P 없음 (그 맵 P 의 이어지는 곳에 체크하거나 기본 P)" % ref, false]
	# 문 쪽에서 고른 P 와 그 맵 P 쪽 '이어지는 곳'이 다르면 충돌
	if explicit != "":
		for a in _all_maps[ref].get("objects", []):
			if a.get("type", "") == "arrive" and a.object_id != explicit and src in a.get("from", []):
				return ["→ %s · ⚠ 도착 P 를 양쪽에서 다르게 정함" % ref, false]
	return ["→ %s · %s" % [ref, target[1]], true]


# ---------------------------------------------------------------- 도우미
func _load_lookups() -> void:
	lookups = ToolCommon.load_lookups()
	# 적 물체 = 마주치면 전투. 몬스터(Npcs kind=monster)를 먼저, 그 밖의 싸울 수 있는 NPC 는 뒤에
	enemies = []
	var others := []
	for e in ToolCommon.read_json("res://data/enemies.json", []):
		if e.get("kind", "") == "monster":
			enemies.append([e.enemy_id, "%s  (%s)" % [e.name, e.enemy_id]])
		else:
			others.append([e.enemy_id, "%s  (%s) — NPC" % [e.name, e.enemy_id]])
	enemies.append_array(others)
	dialogue_starts = []
	var names := {}
	for c in ToolCommon.read_json("res://data/characters.json", []):
		names[c.char_id] = c.name
	# NPC 대화의 ▶ 대화 시작 카드를 먼저, 그 밑에 중간 카드(대화 중간부터 시작)
	var mids := []
	for n in ToolCommon.read_json("res://data/nodes.json", []):
		if n.get("episode_id", "") != "":
			continue
		if n.get("kind", "") == "start":
			var npc: String = n.get("npc_id", "")
			dialogue_starts.append([n.node_id, "▶ %s 대화  (%s)" % [names.get(npc, npc) if npc != "" else "NPC 미정", n.node_id]])
		elif not n.get("kind", "") in ["effect", "branch"]:
			var who: String = names.get(n.speaker_id, "내레이션") if n.speaker_id != "" else "내레이션"
			mids.append([n.node_id, "   %s  — %s: %s" % [n.node_id, who, String(n.text).left(14)]])
	dialogue_starts.append_array(mids)
	loot_spots = []
	var seen := {}
	for l in ToolCommon.read_json("res://data/loot.json", []):
		if not seen.has(l.spot_id):
			seen[l.spot_id] = true
			loot_spots.append([l.spot_id, l.spot_id])
	var cfg: Dictionary = ToolCommon.read_json("res://data/config.json", {})
	basecamp_id = str(cfg.get("basecamp_map", "basecamp"))
	canvas.sight_tiles = float(cfg.get("field_enemy_sight", 5))


func _new_object_id(type: String) -> String:
	var used := {}
	for o in map.get("objects", []):
		used[o.object_id] = true
	var i := 1
	while used.has("%s_%s_%d" % [map.map_id, type, i]):
		i += 1
	return "%s_%s_%d" % [map.map_id, type, i]


func _select_file_item(id: String) -> void:
	for i in files.item_count:
		if files.get_item_text(i) == id:
			files.select(i)


func _status(t: String) -> void:
	status.text = t


func _ask_new() -> void:
	var dlg := ConfirmationDialog.new()
	dlg.title = "새 맵"
	var box := VBoxContainer.new()
	var id := LineEdit.new()
	id.placeholder_text = "맵 ID (영문·숫자·_, 예: ruins_east)"
	box.add_child(id)
	var row := HBoxContainer.new()
	var w := SpinBox.new()
	w.min_value = 3
	w.max_value = 300
	w.value = 30
	w.prefix = "너비"
	var h := SpinBox.new()
	h.min_value = 3
	h.max_value = 300
	h.value = 20
	h.prefix = "높이"
	row.add_child(w)
	row.add_child(h)
	box.add_child(row)
	dlg.add_child(box)
	dlg.confirmed.connect(func():
		new_map(id.text, int(w.value), int(h.value))
		dlg.queue_free())
	dlg.canceled.connect(dlg.queue_free)
	add_child(dlg)
	dlg.popup_centered(Vector2i(480, 160))


func _clear_inspector() -> void:
	for c in inspector.get_children():
		inspector.remove_child(c)
		c.queue_free()


## 맨 위 제목
func _title(t: String) -> void:
	var l := Label.new()
	l.text = t
	l.add_theme_font_size_override("font_size", 18)
	inspector.add_child(l)


## 구역 머리글 (구분선 + 흐린 글자)
func _section(t: String) -> void:
	var gap := Control.new()
	gap.custom_minimum_size.y = 4
	inspector.add_child(gap)
	var row := HBoxContainer.new()
	var l := Label.new()
	l.text = t
	l.modulate = Color(0.65, 0.78, 1.0)
	row.add_child(l)
	var line := HSeparator.new()
	line.size_flags_horizontal = SIZE_EXPAND_FILL
	line.size_flags_vertical = SIZE_SHRINK_CENTER
	row.add_child(line)
	inspector.add_child(row)


func _hint(t: String) -> void:
	var l := Label.new()
	l.text = t
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.modulate = Color(1, 1, 1, 0.5)
	inspector.add_child(l)


## 색 있는 알림 상자 (연결 정보 등)
func _note(t: String, col: Color) -> void:
	var box := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(col, 0.12)
	sb.border_color = Color(col, 0.6)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(3)
	sb.set_content_margin_all(6)
	box.add_theme_stylebox_override("panel", sb)
	var l := Label.new()
	l.text = t
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.add_theme_color_override("font_color", col)
	box.add_child(l)
	inspector.add_child(box)


## '이름 | 입력칸' 한 줄
func _row(label: String, ctrl: Control) -> void:
	var row := HBoxContainer.new()
	var l := Label.new()
	l.text = label
	l.custom_minimum_size.x = 110
	l.clip_text = true
	l.modulate = Color(1, 1, 1, 0.75)
	l.tooltip_text = label
	l.mouse_filter = MOUSE_FILTER_PASS
	row.add_child(l)
	ctrl.size_flags_horizontal = SIZE_EXPAND_FILL
	row.add_child(ctrl)
	inspector.add_child(row)


func _line(label: String, value: String, on_change: Callable, hint := "") -> void:
	var e := LineEdit.new()
	e.text = value
	e.placeholder_text = hint
	e.text_changed.connect(func(v): on_change.call(v))
	_row(label, e)


## items: [[값, 표시]] — 지금 값이 목록에 없으면 '(목록에 없음)' 으로 맨 위에 둔다
func _option(label: String, items: Array, current: String, on_change: Callable) -> void:
	var o := OptionButton.new()
	o.fit_to_longest_item = false
	o.clip_text = true
	var list := items.duplicate()
	if current != "" and not list.any(func(it): return it[0] == current):
		list.push_front([current, current + "  (목록에 없음 — 변환·검사로 확인)"])
	if current == "" and not list.any(func(it): return it[0] == ""):
		list.push_front(["", "(고르세요)"])
	for i in list.size():
		o.add_item(list[i][1], i)
		if list[i][0] == current:
			o.select(i)
	o.item_selected.connect(func(i): on_change.call(list[i][0]))
	_row(label, o)


func _spin(label: String, value: int, lo: int, hi: int) -> SpinBox:
	var s := SpinBox.new()
	s.min_value = lo
	s.max_value = hi
	s.value = value
	_row(label, s)
	return s
