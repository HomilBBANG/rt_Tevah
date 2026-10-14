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
const TOOLS := [
	["select", "선택·이동"], ["wall", "벽"], ["floor", "바닥"], ["void", "빈 공간"], ["arrive", "도착 P"], ["run_start", "회차 시작 S"],
	["enemy", "적"], ["investigate", "조사"], ["npc", "NPC"], ["camp", "거점"], ["exit", "출구(문)"], ["passage", "통로"],
	["transit", "이용"], ["erase", "지우개"],
]
const TOOL_TIPS := {
	"select": "물체를 클릭하면 오른쪽 칸에 세부, 끌면 옮김. 빈 칸을 클릭하면 맵 크기 설정",
	"wall": "누른 채 끌어서 벽을 칠함 (지나갈 수 없음)",
	"floor": "누른 채 끌어서 바닥을 칠함 (걸어 다니는 곳)",
	"void": "누른 채 끌어서 빈 공간을 칠함 (검게 보이고 지나갈 수 없음)",
	"run_start": "회차 시작 S: 새 회차를 이 맵에서 시작할 때 깨어나는 곳 (Config start_map 의 맵에서만 쓰임)",
	"enemy": "적을 놓음 → 오른쪽 칸에서 적 종류·순찰 방향·칸 수",
	"investigate": "조사 지점을 놓음 → 오른쪽 칸에서 얻는 것(Loot)·조사 문구",
	"npc": "NPC 를 놓음 → 오른쪽 칸에서 대화(시작 노드)·나타나는 시간대",
	"camp": "베이스캠프 거점(식사·물·씻기·잠 메뉴, 엑셀 CampActions)을 놓음",
	"exit": "출구(문)를 놓음 → 오른쪽 칸에서 이동할 맵·도착 지점. 게임에서는 E 로 열고, 열린 문으로 걸어가면 이동",
	"passage": "통로를 놓음 → 밟으면 바로 이동 (열고 닫기 없음, 계단·길·동굴 입구)",
	"transit": "이용 지점을 놓음 → E 를 눌러야 이동 (사다리·엘리베이터 등). 이름이 안내에 나옴",
	"arrive": "도착 P 를 놓음 → 오른쪽 칸 '이어지는 곳'에서 어느 맵의 어느 입구로 들어오면 여기 설지 고름. ★ = 기본 P (정하지 않은 곳·부활)",
	"erase": "클릭한 물체(또는 S)를 지움. 벽은 바닥으로 칠해서 지움",
}
const HELP_TEXT := """[b]맵 탭 쓰는 법[/b]   (이 칸은 오른쪽 위 '❓ 사용법' 으로 접고 펼칩니다)

[b]1. 맵 고르기[/b] — 왼쪽 위 목록에서 맵을 고르거나 [b]새 맵[/b] (맵 ID, 너비·높이 칸 수). 맵 하나 = 파일 하나 (tools/maps/).
[b]2. 모양 칠하기[/b] — 도구 줄에서 [b]벽[/b] / [b]바닥[/b] / [b]빈 공간[/b]을 고르고, 맵 위를 누른 채 끌면 칠해집니다.
[b]3. 위치 찍기[/b] — [b]도착 P[/b]: 다른 맵에서 들어올 때 서는 곳. 여러 개 찍고, P 를 눌러 [b]이어지는 곳[/b](어느 맵의 어느 입구로 오면 여기)을 고릅니다.
      ★ 붙은 P 가 [b]기본 P[/b] — 아무 P 에도 이어지지 않은 곳으로 들어오거나 베이스캠프에서 깨어날 때. 맵마다 꼭 하나 (처음 찍은 P, P 설정에서 바꿈).  [b]회차 시작 S[/b]: 새 회차를 시작하는 곳 (시작 맵에만). 둘 다 바닥 칸에만.
[b]4. 물체 놓기[/b] — [b]적[/b] · [b]조사[/b] · [b]NPC[/b] · [b]거점[/b] · [b]출구(문)[/b] · [b]통로[/b] · [b]이용[/b] 도구로 바닥 칸을 클릭하면 놓이고, [b]오른쪽 칸[/b]에서 세부를 고릅니다.
    · 적: 적 종류, 순찰 방향과 칸 수(그 칸 수만큼 왕복). 맵에 순찰 길과 시야가 그려집니다.
    · 조사: 얻는 것(엑셀 Loot 의 spot), 조사할 때 나오는 문구.
    · NPC: 대화(시작 노드 = 대화 탭의 첫 카드), 나타나는 시간대 (예: 06:00-12:00, 20:00-23:00).
    · 맵 이동: [b]출구(문)[/b] E 로 열고 걸어 들어감 / [b]통로[/b] 밟으면 바로 / [b]이용[/b] 사다리처럼 E 를 눌러야 / [b]가장자리[/b] 빈 칸을 클릭해 나오는 맵 설정에서 위·아래·왼쪽·오른쪽 끝으로 나가면 옆 맵.
      도착하는 자리는 3번의 [b]도착 P[/b] 에서 정합니다 (문 쪽 '도착 P' 칸에서 골라도 됩니다).
      대화·아이템 효과의 '맵 이동'으로도 옮길 수 있습니다.
    · 나타나는 조건: [b]＋ 조건 추가[/b]로 골라 둡니다 (예: '플래그가 켜져 있다 met_cat' → 그 플래그가 켜졌을 때만 나타남).
[b]5. 고치기[/b] — [b]선택·이동[/b] 도구: 물체를 클릭하면 세부, 끌면 옮김. 빈 칸 클릭 = 맵 크기·가장자리 설정.  [b]지우개[/b]: 물체를 지움.
    · [b]여러 개[/b]: Shift+클릭으로 더하기, 빈 곳을 끌면 영역 선택(그 안의 물체·타일). 고른 것들을 함께 끌어 옮기고, 오른쪽 칸에서 한꺼번에 바꾸기.
    · [b]□ 사각형[/b]: 켜고(또는 Shift 를 누른 채) 벽·바닥·빈 공간을 끌면 사각형으로 채움.
    · [b]↶ 실행 취소 / ↷ 다시 실행[/b] (Ctrl+Z / Ctrl+Y),  [b]복사·붙여넣기[/b] (Ctrl+C / Ctrl+V — 마우스가 있는 칸에),  [b]삭제[/b] (Delete). 단축키는 맵을 한 번 누른 뒤.
[b]연결 보기[/b] — 문·통로·이용 아래에 '→ 맵 · 도착 P', 추가 도착 P 아래에 '← 들어오는 곳'. 잘못된 연결은 빨간 테두리와 ⚠. 문을 [b]더블클릭[/b]하면 이어진 맵을 열고 도착 P 로.
[b]왼쪽 칸[/b] — [b]찾기[/b]: 이름·ID·종류로 모든 맵에서 검색, 누르면 그 맵·물체로.  [b]맵 목록[/b]: 누르면 열기 (→ 이어지는 맵, 마우스를 올리면 들어오는 곳).  [b]표시 필터[/b]: 끈 종류는 안 보이고 고를 수도 없음.
[b]6. 화면[/b] — 휠: 확대·축소,  휠 버튼 또는 오른쪽 버튼 누른 채 끌기: 화면 이동.
[b]7. 반영하기[/b] — [b]저장[/b] → [b]변환·검사[/b] (오류는 맨 아래 칸) → [b]테스트 플레이[/b]로 이 맵에서 바로 실행 (진짜 저장은 건드리지 않음).

[b]지도 표시[/b]  [color=#3fae5f]● P[/color] 도착 P (★ 기본) · [color=#b89a2a]S[/color] 회차 시작 · [color=#d05050]● 적[/color] · [color=#e8c35a]● 조[/color] 조사 · [color=#5a8fd0]● N[/color] NPC · [color=#5fae6a]● 거[/color] 거점 · [color=#a07850]● 문[/color] 출구 · [color=#6fa8dc]● 통[/color] 통로 · [color=#c8a060]● 이[/color] 이용 · 맵 바깥 푸른 띠 = 가장자리 이동 · 흐린 빨간 원 = 적 시야, 빨간 선 = 순찰 길
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
var tool_buttons := {}
# 목록 (data/*.json 에서)
var enemies: Array = []              # [[id, 이름]]
var dialogue_starts: Array = []      # 필드 대화 노드
var loot_spots: Array = []
var map_ids: Array = []
var lookups := {}                    # 조건 고르기 (ToolCommon.load_lookups)
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
	var bar := HBoxContainer.new()
	add_child(bar)
	files = OptionButton.new()
	files.custom_minimum_size.x = 200
	files.item_selected.connect(func(i): open_map(files.get_item_text(i)))
	bar.add_child(files)
	files.tooltip_text = "편집할 맵 파일 (tools/maps/). 다른 맵을 고르면 지금 맵은 자동 저장"
	for b in [
			["새 맵", _ask_new, "새 맵 파일을 만듭니다 (맵 ID: 영문·숫자·_, 너비·높이)"],
			["저장", save, "지금 맵을 파일로 저장합니다"],
			["변환·검사", run_convert, "저장한 뒤 변환기를 돌려 오류를 검사합니다. 결과는 맨 아래 칸에.\n오류가 없어야 게임에 반영됩니다"],
			["테스트 플레이", playtest, "이 맵에서 바로 게임을 실행합니다 (진짜 저장·회차는 건드리지 않음)"],
			["↶", undo, "실행 취소 (Ctrl+Z)"], ["↷", redo, "다시 실행 (Ctrl+Y)"],
			["복사", copy_selection, "고른 물체·영역을 복사 (Ctrl+C). 영역은 선택 도구로 빈 곳을 끌어서"],
			["붙여넣기", func(): paste_at(canvas._hover), "마우스가 있는 칸에 붙여넣기 (Ctrl+V)"],
			["삭제", delete_selection, "고른 물체 지우기 (Delete)"]]:
		var btn := Button.new()
		btn.text = b[0]
		btn.tooltip_text = b[2]
		btn.pressed.connect(b[1])
		bar.add_child(btn)
	status = Label.new()
	status.size_flags_horizontal = SIZE_EXPAND_FILL
	status.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	status.clip_text = true   # 긴 상태 글자가 에디터 폭을 넓히지 않게
	status.custom_minimum_size.x = 120
	bar.add_child(status)
	# 도구
	var tools := HBoxContainer.new()
	add_child(tools)
	var group := ButtonGroup.new()
	for t in TOOLS:
		var b := Button.new()
		b.text = t[1]
		b.toggle_mode = true
		b.button_group = group
		b.tooltip_text = TOOL_TIPS.get(t[0], "")
		b.pressed.connect(set_tool.bind(t[0]))
		tools.add_child(b)
		tool_buttons[t[0]] = b
	var rect := Button.new()
	rect.text = "□ 사각형"
	rect.toggle_mode = true
	rect.tooltip_text = "켜면 벽·바닥·빈 공간을 끌어서 사각형으로 채움 (Shift 를 누른 채 끌어도 됨)"
	rect.toggled.connect(func(on): canvas.rect_mode = on)
	tools.add_child(rect)
	var help := Label.new()
	help.text = "   휠: 확대   가운데·오른쪽 끌기: 이동   Shift+클릭: 여러 개"
	help.modulate = Color(1, 1, 1, 0.6)
	help.clip_text = true
	help.size_flags_horizontal = SIZE_EXPAND_FILL
	help.custom_minimum_size.x = 40
	help.tooltip_text = help.text
	tools.add_child(help)
	# 캔버스 | 오른쪽 칸
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
	side.custom_minimum_size.x = 380
	side.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED   # 긴 글자는 칸 폭에 맞춰 줄임
	split.add_child(side)
	inspector = VBoxContainer.new()
	inspector.size_flags_horizontal = SIZE_EXPAND_FILL
	side.add_child(inspector)
	log_view = TextEdit.new()
	log_view.editable = false
	log_view.custom_minimum_size.y = 100
	log_view.placeholder_text = "변환·검사 결과가 여기에 나옵니다."
	add_child(log_view)
	ToolCommon.add_help(self, 2, bar, "map", HELP_TEXT)
	set_tool("select")


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
	# 예전 맵: 기본 도착 위치(start)를 기본 P 물체로
	if not map.objects.any(func(o): return o.type == "arrive" and o.get("default", false)):
		var st: Array = map.start if map.start != null else [1, 1]
		var at: Array = map.objects.filter(func(o): return o.type == "arrive" and o.x == st[0] and o.y == st[1])
		if not at.is_empty():
			at[0].default = true
		else:
			map.objects.insert(0, {"object_id": id + "_p", "type": "arrive", "x": st[0], "y": st[1], "ref": "", "name": "기본",
				"text": "", "patrol_dir": "", "patrol_len": 0, "condition": "", "schedule": "", "arrive": "", "default": true})
	path = p
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
		{"object_id": id + "_p", "type": "arrive", "x": w / 2, "y": h / 2, "ref": "", "name": "기본", "text": "",
		"patrol_dir": "", "patrol_len": 0, "condition": "", "schedule": "", "arrive": "", "default": true}]}
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
	if not dp.is_empty():
		map.start = [int(dp.x), int(dp.y)]   # 기본 P 자리 = start (게임·변환기가 읽음)
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
	_status("변환 성공" if ok else "변환 실패 — 아래 오류를 확인하세요")
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
	_title("맵: " + map.map_id)
	var w := String(map.tiles[0]).length() if not map.tiles.is_empty() else 0
	var ws := _spin("너비 (칸)", w, 3, 300)
	var hs := _spin("높이 (칸)", map.tiles.size(), 3, 300)
	var apply := Button.new()
	apply.text = "크기 적용"
	apply.pressed.connect(func(): resize_map(int(ws.value), int(hs.value)))
	inspector.add_child(apply)
	_hint("도착 P = 다른 맵에서 들어올 때 서는 곳 (★ 기본 P 는 꼭 하나)\nS = 새 회차를 시작하는 곳 (Config start_map 의 맵에서만 쓰임, 없으면 기본 P)\n물체를 고르면 여기에 세부가 나옵니다.")
	_title("가장자리로 나가면")
	_hint("그쪽 맨 끝 칸(바닥)에 닿으면 이동. 맵 끝에 바닥 칸을 터 두세요.")
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
			_option("    도착 지점", _arrive_options(e.ref), e.get("arrive", ""), func(v):
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
		var ll := Label.new()
		ll.text = ("연결: " if link[1] else "⚠ 연결 문제: ") + link[0]
		ll.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		ll.add_theme_color_override("font_color", Color("9cc4ec") if link[1] else Color("ff6060"))
		inspector.add_child(ll)
	if o.type in ["exit", "passage", "transit"] and o.get("ref", "") in _all_maps:
		var go := Button.new()
		go.text = "→ %s 열기 (도착 위치로)" % o.ref
		go.tooltip_text = "이어진 맵을 열고 도착하는 P 를 고릅니다 (캔버스에서 더블클릭해도 됨)"
		go.pressed.connect(follow_link.bind(o))
		inspector.add_child(go)
	_line("object_id", o.object_id, func(v): set_field(o, "object_id", v))
	_line("이름", o.get("name", ""), func(v): set_field(o, "name", v), "화면에 보이는 이름")
	match o.type:
		"enemy":
			_option("적 종류", enemies, o.get("ref", ""), func(v): set_field(o, "ref", v))
			_option("순찰 방향", [["", "(가만히)"], ["up", "위"], ["down", "아래"], ["left", "왼쪽"], ["right", "오른쪽"]],
				o.get("patrol_dir", ""), func(v): set_field(o, "patrol_dir", v))
			var sp := _spin("순찰 칸 수 (왕복)", int(o.get("patrol_len", 0)), 0, 100)
			sp.value_changed.connect(func(v): set_field(o, "patrol_len", int(v)))
		"npc":
			_option("대화 (시작 노드)", dialogue_starts, o.get("ref", ""), func(v): set_field(o, "ref", v))
			_line("루틴 시간대 (schedule)", o.get("schedule", ""), func(v): set_field(o, "schedule", v), "예: 06:00-12:00, 20:00-23:00 (비우면 항상)")
		"investigate":
			_option("얻는 것 (Loot spot)", [["", "(없음)"]] + loot_spots, o.get("ref", ""), func(v): set_field(o, "ref", v))
			var l := Label.new()
			l.text = "조사 문구"
			inspector.add_child(l)
			var te := TextEdit.new()
			te.text = o.get("text", "")
			te.custom_minimum_size.y = 110
			te.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
			te.text_changed.connect(func(): set_field(o, "text", te.text))
			inspector.add_child(te)
		"exit", "passage", "transit":
			_option("이동할 맵", map_ids.map(func(m): return [m, m]), o.get("ref", ""), func(v):
				set_field(o, "ref", v)
				set_field(o, "arrive", "")
				_edit_object.call_deferred(o))
			if o.get("ref", "") != "":
				_option("도착 P (비우면 그 맵 P 쪽 설정 → 기본 P)", _arrive_options(o.ref), o.get("arrive", ""), func(v): set_field(o, "arrive", v))
		"arrive":
			var dcb := CheckBox.new()
			dcb.text = "★ 기본 P (아무 데도 이어지지 않은 곳으로 들어오거나 베이스캠프에서 깨어날 때)"
			dcb.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			dcb.button_pressed = o.get("default", false)
			dcb.disabled = o.get("default", false)   # 기본을 바꾸려면 다른 P 에서 체크
			dcb.toggled.connect(func(on):
				if on:
					checkpoint()
					for x in map.objects:
						if x.type == "arrive":
							x.erase("default")
					o.default = true
					dirty = true
					_refresh_links()
					canvas.queue_redraw()
					_edit_object.call_deferred(o))
			inspector.add_child(dcb)
			_title("이어지는 곳")
			_hint("체크한 곳으로 이 맵에 들어오면 이 P 에 도착합니다. 아무 P 에도 이어지지 않은 곳은 ★ 기본 P.")
			var ents := _entrances_to(map.map_id)
			if ents.is_empty():
				_hint("이 맵으로 들어오는 문·통로·이용·가장자리가 아직 없습니다.")
			var from: Array = o.get("from", [])
			for e in ents:
				var cb := CheckBox.new()
				cb.text = e[1]
				cb.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
				cb.button_pressed = e[0] in from
				var src: String = e[0]
				var row := HBoxContainer.new()
				cb.size_flags_horizontal = SIZE_EXPAND_FILL
				row.add_child(cb)
				var open := Button.new()
				open.text = "↗"
				open.tooltip_text = "그 입구가 있는 맵을 열고 그 물체를 고릅니다"
				open.pressed.connect(func(): goto_entrance(src))
				row.add_child(open)
				cb.toggled.connect(func(on):
					var f: Array = o.get("from", []).duplicate()
					if on and not src in f:
						f.append(src)
					elif not on:
						f.erase(src)
					set_field(o, "from", f))
				inspector.add_child(row)
	var cl := Label.new()
	cl.text = "나타나는 조건 (맞을 때만 맵에 있음)"
	inspector.add_child(cl)
	var rows: Node = ExprRows.new().setup("cond", o.get("condition", ""), lookups)
	rows.changed.connect(func(v): set_field(o, "condition", v))
	inspector.add_child(rows)
	var del := Button.new()
	del.text = "이 물체 지우기"
	del.pressed.connect(func():
		if o.type == "arrive" and not canvas.release_p(o):
			_status("마지막 도착 P 는 지울 수 없음")
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
				_multi_option(objs, "얻는 것 (Loot spot)", [["", "(없음)"]] + loot_spots, "ref")
			"exit", "passage", "transit":
				_multi_option(objs, "이동할 맵", map_ids.map(func(m): return [m, m]), "ref")
	else:
		_hint("종류가 섞여 있어 공통 칸(나타나는 조건)만 바꿀 수 있습니다.")
	var cl := Label.new()
	cl.text = "나타나는 조건 (모두에 적용)"
	inspector.add_child(cl)
	var same := objs.all(func(o): return o.get("condition", "") == objs[0].get("condition", ""))
	var rows: Node = ExprRows.new().setup("cond", objs[0].get("condition", "") if same else "", lookups)
	rows.changed.connect(func(v):
		checkpoint("multi/condition")
		for o in objs:
			o.condition = v
		dirty = true)
	inspector.add_child(rows)
	var del := Button.new()
	del.text = "고른 %d개 지우기 (Delete)" % objs.size()
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
	scroll.custom_minimum_size.x = 260
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var vb := VBoxContainer.new()
	vb.size_flags_horizontal = SIZE_EXPAND_FILL
	vb.size_flags_vertical = SIZE_EXPAND_FILL
	scroll.add_child(vb)
	var t1 := Label.new()
	t1.text = "찾기 (모든 맵)"
	vb.add_child(t1)
	search = LineEdit.new()
	search.placeholder_text = "이름·ID·종류 (예: 고양이, 문, enemy_test)"
	search.clear_button_enabled = true
	search.text_changed.connect(func(_t): _run_search())
	vb.add_child(search)
	results = ItemList.new()
	results.custom_minimum_size.y = 140
	results.visible = false
	results.item_clicked.connect(func(i, _p, _b):
		var m: Array = results.get_item_metadata(i)
		goto_object(m[0], m[1]))
	vb.add_child(results)
	var t2 := Label.new()
	t2.text = "맵 목록 (→ 이어지는 맵)"
	vb.add_child(t2)
	map_list = ItemList.new()
	map_list.custom_minimum_size.y = 200
	map_list.size_flags_vertical = SIZE_EXPAND_FILL
	map_list.item_clicked.connect(func(i, _p, _b): open_map(map_list.get_item_metadata(i)))
	vb.add_child(map_list)
	var t3 := Label.new()
	t3.text = "표시 필터"
	vb.add_child(t3)
	var grid := GridContainer.new()
	grid.columns = 2
	vb.add_child(grid)
	for f in [["tiles", "타일"], ["enemy", "적"], ["investigate", "조사"], ["npc", "NPC"], ["camp", "거점"],
			["travel", "문·통로·이용"], ["arrive", "도착 P"], ["sight", "시야·순찰"], ["names", "이름표"], ["links", "연결 표시"]]:
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
		var i := map_list.add_item(("▶ " if mid == map.get("map_id", "") else "") + mid + ("  → " + ", ".join(outs.keys()) if not outs.is_empty() else ""))
		map_list.set_item_metadata(i, mid)
		var ins := []
		for e in _entrances_to(mid):
			ins.append(e[1])
		map_list.set_item_tooltip(i, "들어오는 곳:\n" + ("\n".join(ins) if not ins.is_empty() else "(없음)"))


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
	return ["", "기본 P"]


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
	# 문 쪽에서 고른 P 와 그 맵 P 쪽 '이어지는 곳'이 다르면 충돌
	if explicit != "":
		for a in _all_maps[ref].get("objects", []):
			if a.get("type", "") == "arrive" and a.object_id != explicit and src in a.get("from", []):
				return ["→ %s · ⚠ 도착 P 를 양쪽에서 다르게 정함" % ref, false]
	return ["→ %s · %s" % [ref, target[1]], true]


# ---------------------------------------------------------------- 도우미
func _load_lookups() -> void:
	lookups = ToolCommon.load_lookups()
	enemies = []
	for e in ToolCommon.read_json("res://data/enemies.json", []):
		enemies.append([e.enemy_id, "%s  (%s)" % [e.name, e.enemy_id]])
	dialogue_starts = []
	var names := {}
	for c in ToolCommon.read_json("res://data/characters.json", []):
		names[c.char_id] = c.name
	for n in ToolCommon.read_json("res://data/nodes.json", []):
		if n.get("episode_id", "") == "":
			var who: String = names.get(n.speaker_id, "내레이션") if n.speaker_id != "" else "내레이션"
			dialogue_starts.append([n.node_id, "%s  — %s: %s" % [n.node_id, who, String(n.text).left(14)]])
	loot_spots = []
	var seen := {}
	for l in ToolCommon.read_json("res://data/loot.json", []):
		if not seen.has(l.spot_id):
			seen[l.spot_id] = true
			loot_spots.append([l.spot_id, l.spot_id])
	var cfg: Dictionary = ToolCommon.read_json("res://data/config.json", {})
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


func _line(label: String, value: String, on_change: Callable, hint := "") -> void:
	var l := Label.new()
	l.text = label
	inspector.add_child(l)
	var e := LineEdit.new()
	e.text = value
	e.placeholder_text = hint
	e.text_changed.connect(func(v): on_change.call(v))
	inspector.add_child(e)


## items: [[값, 표시]] — 지금 값이 목록에 없으면 '(목록에 없음)' 으로 맨 위에 둔다
func _option(label: String, items: Array, current: String, on_change: Callable) -> void:
	var l := Label.new()
	l.text = label
	inspector.add_child(l)
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
	inspector.add_child(o)


func _spin(label: String, value: int, lo: int, hi: int) -> SpinBox:
	var l := Label.new()
	l.text = label
	inspector.add_child(l)
	var s := SpinBox.new()
	s.min_value = lo
	s.max_value = hi
	s.value = value
	inspector.add_child(s)
	return s
