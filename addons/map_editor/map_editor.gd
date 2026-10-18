@tool
extends VBoxContainer
## 맵 에디터 (Godot 에디터의 '맵' 탭). tools/maps/<맵ID>.json 을 편집한다.
##   벽·바닥 칠하기, 도착 위치 P (출구로 들어올 때·베이스캠프에서 깨어날 때), 회차 시작 S,
##   물체 놓기(적·조사·NPC·거점·출구) → 오른쪽 칸에서 세부, 저장 → 변환·검사 → 테스트 플레이.
## 게임 실행 중(테스트)에서도 열 수 있도록 에디터 전용 기능은 Engine.is_editor_hint() 로 감싼다.

const Canvas = preload("res://addons/map_editor/map_canvas.gd")
const WorldView = preload("res://addons/map_editor/world_view.gd")
const ToolCommon = preload("res://addons/tool_common.gd")
const ExprRows = preload("res://addons/expr_rows.gd")
const MapRenderer = preload("res://core/map_renderer.gd")
const VisualData = preload("res://core/visual_data.gd")
const AIAssets = preload("res://core/ai/ai_assets.gd")

const MAP_DIR := "res://tools/maps/"
const PLAYTEST_FILE := "user://map_playtest.json"
## 도구 묶음: [묶음 이름, [[도구 id, 버튼 글자], ...]] — 도구 줄에서 구분선으로 나눈다
const TOOL_GROUPS := [
	["", [["select", "선택"]]],
	["칠하기", [["wall", "벽"], ["floor", "바닥"], ["void", "빈 공간"]]],
	["위치", [["arrive", "도착 P"], ["respawn", "부활 R"], ["run_start", "시작 S"]]],
	["물체", [["enemy", "적"], ["investigate", "조사"], ["npc", "NPC"], ["camp", "거점"], ["event", "이벤트"], ["furniture", "가구"]]],
	["이동", [["exit", "문"], ["passage", "통로"], ["transit", "이용"]]],
	["그래픽", [["tile", "타일"], ["tile_erase", "타일 지우기"], ["prop", "오브젝트"], ["light", "광원"], ["window", "창문"]]],
	["", [["erase", "지우개"]]],
]
const TOOL_TIPS := {
	"select": "선택·이동: 물체를 클릭하면 오른쪽 칸에 세부, 끌면 옮김.\nShift+클릭 = 여러 개, 빈 곳을 끌면 영역 선택, 빈 칸 클릭 = 맵 설정.
고른 영역(파란 테두리) 안을 잡고 끌면 벽·바닥·칠한 그림·물체를 통째로 옮김",
	"wall": "벽: 누른 채 끌어서 칠함 (지나갈 수 없음)",
	"floor": "바닥: 누른 채 끌어서 칠함 (걸어 다니는 곳)",
	"void": "빈 공간: 누른 채 끌어서 칠함 (검게 보이고 지나갈 수 없음)",
	"arrive": "도착 P: 다른 맵에서 들어올 때 서는 곳. 오른쪽 칸 '이어지는 곳'에서 어느 입구로 오면 여기 설지 고름.\n★ = 기본 P (이어지지 않은 곳 — 베이스캠프만 필수)",
	"respawn": "부활 R: 죽었다가 부활하거나 저장을 불러오면 베이스캠프의 이 자리에서 깨어남 (베이스캠프 맵에 하나, 없으면 첫 도착 P)",
	"run_start": "회차 시작 S: 새 회차를 이 맵에서 시작할 때 깨어나는 곳 (Config start_map 의 맵에서만 쓰임)",
	"enemy": "적: 놓은 뒤 오른쪽 칸에서 적 종류·순찰 방향·칸 수",
	"investigate": "조사 지점: 놓은 뒤 오른쪽 칸에서 얻는 것(Loot)·조사 문구",
	"npc": "NPC: 놓은 뒤 오른쪽 칸에서 대화(시작 노드)·나타나는 시간대",
	"camp": "베이스캠프 거점 (식사·물·씻기·잠 메뉴, 엑셀 CampActions)",
	"event": "이벤트 칸: 밟으면 대화(컷신) 시작. 게임에서는 안 보임. 오른쪽 칸에서 대화·한 번만·나타나는 조건",
	"exit": "문: E 로 열고, 열린 문으로 걸어 들어가면 이동. 오른쪽 칸에서 이동할 맵. 벽 칸에 놓으면 그 칸이 저절로 바닥이 됨",
	"passage": "통로: 밟으면 바로 이동 (계단·길·동굴 입구)",
	"transit": "이용: E 를 눌러야 이동 (사다리·엘리베이터 등). 이름이 안내에 나옴",
	"erase": "지우개: 클릭한 물체(또는 S)를 지움. 벽은 바닥으로 칠해서 지움",
	"tile": "타일 붓: 왼쪽 '타일 팔레트'에서 층·타일을 고르고 끌어서 칠함. 벽 층 = 그 칸이 벽(지나갈 수 없음), 바닥 층 = 바닥, 나머지 층은 그림만. □ 사각형·Shift 로 채우기",
	"tile_erase": "타일 지우개: 지금 층의 칠한 타일을 지움 (벽 층을 지우면 그 칸은 바닥이 됨)",
	"prop": "오브젝트 그림 (나무·가구): 왼쪽 '타일 팔레트'를 '오브젝트'로 바꿔 고르고 클릭한 칸(= 왼쪽 아래 칸)에 놓기. 인물과 앞뒤는 저절로",
	"furniture": "기타 가구: 그림 대신 흰 사각형. 클릭한 칸 = 왼쪽 위, 오른쪽 칸에서 크기·표시 메모(예: 철제 서랍)·색·역할(조사·줍기·사용·대화)·사용 조건",
	"window": "창문: 벽 칸에 놓기 — 옆에 바닥이 있거나, 비스듬한 탑뷰의 뒷벽(아래로 벽만 이어지다 바닥). 크기는 오른쪽 칸 너비·높이. 낮에는 바닥 쪽으로 햇빛이 들어오고 밤엔 어두움. 게임에서 E 로 커튼을 치면 빛이 막힘",
	"light": "광원: 클릭한 칸에 놓기 (오른쪽 칸에서 프리셋·색·밝기·범위·그림자). 고르면 끌어서 옮기기, Ctrl+C/V 복제",
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
  · [b]영역 통째로 옮기기[/b]: 빈 곳을 끌어 영역(파란 테두리)을 고른 뒤, 그 안을 잡고 끌어 놓으면 벽·바닥·칠한 그림(바닥·장식·벽·지붕)·물체가 함께 옮겨짐. 비운 자리는 바닥(기본 그림). 복사·붙여넣기도 칠한 그림까지.
  · ↶ ↷ 실행 취소·다시 실행 (Ctrl+Z / Ctrl+Y)  · [b]편집 ▾[/b]: 복사(Ctrl+C) · 붙여넣기(Ctrl+V, 마우스가 있는 칸) · 삭제(Delete)

[b]5. 반영[/b]  [b]저장[/b] → [b]변환·검사[/b] (오류가 있으면 아래에 결과 칸이 열림) → [b]▶ 테스트 플레이[/b] (진짜 저장은 건드리지 않음)

[b]5. 그래픽 (픽셀아트 · 조명)[/b] — 보이는 모습만. 지나갈 수 있는지(벽 #·바닥 .)는 위 '칠하기'가 정합니다.
  · [b]전경 가림[/b]: 팔레트 층 '전경 가림'(검은 가림막 등)으로 칠하면 게임에서 캐릭터 [b]위[/b]에 늘 그려짐 — 통로 위 천장·상단 벽. 지나가는 건 막지 않고(충돌은 벽 #), 적 시야·빛도 안 막음.
    표시 칸의 '전경 가림' 끄기 / '전경만' / '전경 투명도'(편집 미리보기 전용, 저장 안 됨)로 아래를 고치기 쉽게. '벽 판정'을 켜면 실제로 막힌 곳이 붉게.
  · [b]타일 붓[/b]: 왼쪽 [b]타일 팔레트[/b]에서 층과 타일을 고르고 끌어서 칠함. □ 사각형·Shift 로 채우기. [b]타일 지우개[/b] = 지금 층에서 지움.
    [b]벽 층[/b]에 칠하면 그 칸은 [b]벽(지나갈 수 없음)[/b], [b]바닥 층[/b]은 [b]바닥[/b]이 됨. 바닥 장식·지붕·전경 가림은 그림만. 예전 맵은 [b]편집 ▾ › 칠한 그림대로 벽·바닥 맞추기[/b].
    안 칠한 칸은 기본 바닥·기본 벽으로 보입니다. 새 타일은 그림을 art/tiles/ 에 넣고 엑셀 graphics.xlsx 'Tiles' 에 한 줄 → 변환·검사.
  · [b]오브젝트[/b] (나무·가구 그림): 타일 팔레트 층을 '오브젝트'로 바꿔 고르고 칸 클릭 (놓은 칸 = 왼쪽 아래). 인물과 앞뒤는 발 위치로 저절로.
    지나갈 수 없음·빛을 막음은 graphics.xlsx 'Props' (solid·casts_shadow). 새 그림은 art/props/ 에 넣고 Props 에 한 줄.
  · 경고: 없는 타일·오브젝트·프리셋·환경은 맵 설정 칸 맨 위에 ⚠ (없는 타일 칸은 붉은 X). 맵은 그대로 열리고 게임에서는 기본 타일로.
  · [b]광원[/b]: 칸을 클릭해 놓고, 오른쪽 칸에서 프리셋(전구·형광등·촛불·가로등·손전등)·색·밝기·범위(칸)·벽 그림자·켜짐. 끌어서 옮기기, Ctrl+C/V.
  · [b]환경[/b]: 아무것도 안 고르고 맵 설정에서 실외(낮·밤 변화) / 실내 / 지하. 색·밝기는 graphics.xlsx 'DayNight'.
  · [b]시간 미리보기[/b] (위 줄 06 · 12 · 18 · 00 · 슬라이더): 에디터에서만 그 시각의 조명으로 봄 — 게임 시각·저장은 그대로.
  · 그림자: 벽 타일(그림자 Y)과 닫힌 문이 빛을 막음. 게임에서 문을 열면 빛이 지나감.
  · 표시(왼쪽 아래): 그래픽 · 조명 · 광원 · 광원 범위 · 그림자 차단(윤곽) · 벽 판정(지나갈 수 없는 칸을 붉게)

[b]지도 표시[/b]  [color=#3fae5f]● P[/color] 도착 P (★ 기본) · [color=#b89a2a]S[/color] 회차 시작 · [color=#d05050]● 적[/color] · [color=#e8c35a]● 조[/color] 조사 · [color=#5a8fd0]● N[/color] NPC · [color=#5fae6a]● 거[/color] 거점 · [color=#c070d0]● !![/color] 이벤트 (밟으면 컷신) · [color=#a07850]● 문[/color] · [color=#6fa8dc]● 통[/color] 통로 · [color=#c8a060]● 이[/color] 이용 · 맵 바깥 푸른 띠 = 가장자리 이동
"""
const TYPE_NAME :={"enemy": "적", "investigate": "조사 지점", "npc": "NPC", "camp": "베이스캠프 거점", "exit": "출구(문)",
	"passage": "통로", "transit": "이용 (사다리 등)", "arrive": "도착 P", "event": "이벤트 칸", "light": "광원", "prop": "오브젝트 그림", "window": "창문", "furniture": "기타 가구", "respawn": "부활 R"}
const EDGES := [["up", "위"], ["down", "아래"], ["left", "왼쪽"], ["right", "오른쪽"]]

var dir := MAP_DIR                   # 테스트에서 바꿔 쓴다
var dialogue_dir := "res://tools/dialogues/"   # 맵 삭제 때 move: 를 찾는 곳
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
# ---- 그래픽 (core/map_renderer.gd — 게임과 같은 렌더러를 맵 뒤에 띄움)
var renderer: Node2D
var gfx_view: SubViewportContainer
var tile_px := 80.0                  # 게임 한 칸 (Config field_tile)
var preview_minutes := 720.0         # 시간 미리보기 (게임 시각·저장과 무관)
var palette: ItemList
var palette_layer: OptionButton
var palette_search: LineEdit
var time_label: Label
var _gfx_dirty := true
var overhead_slider: HSlider         # 전경 가림 편집용 투명도 (미리보기 전용)
var world: Control                   # 월드 맵 (모든 맵 한눈에, world_view.gd)
var world_button: Button
var _world_fitted := false
var lock_box: CheckBox               # 지금 팔레트 층 잠금


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
	_bar_btn(bar, "맵 삭제", _ask_delete_map, "지금 맵 파일을 지우기 (휴지통으로). 이 맵을 쓰는 곳이 있으면 먼저 보여 줌")
	world_button = Button.new()
	world_button.text = "🗺 월드 맵"
	world_button.toggle_mode = true
	world_button.tooltip_text = "모든 맵을 한눈에: 가장자리로 이어진 맵은 붙여서, 문·통로 연결은 선으로. 두 번 누르면 그 맵 편집"
	world_button.toggled.connect(show_world)
	bar.add_child(world_button)
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
			["선택 해제   Esc", func(): canvas.select({})], [], ["칠한 그림대로 벽·바닥 맞추기", sync_logic_to_paint], ["모두 지우기…  (빈 맵으로)", _ask_clear_all]]:
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
	# 시간 미리보기 (위 줄, 상태 글자 앞)
	var time_box := HBoxContainer.new()
	bar.add_child(time_box)
	bar.move_child(time_box, status.get_index())
	var light_cap := Label.new()
	light_cap.text = "시간 미리보기"
	light_cap.modulate = Color(1, 1, 1, 0.45)
	light_cap.tooltip_text = "에디터에서만 조명을 이 시각으로 봅니다 (게임 시각·저장은 그대로)"
	time_box.add_child(light_cap)
	for hh in [6, 12, 18, 0]:
		var hb := Button.new()
		hb.text = "%02d" % hh
		hb.flat = true
		hb.tooltip_text = "%02d:00 으로 보기" % hh
		hb.pressed.connect(func(): set_preview_time(hh * 60.0))
		time_box.add_child(hb)
	var slider := HSlider.new()
	slider.min_value = 0
	slider.max_value = 1439
	slider.step = 10
	slider.value = preview_minutes
	slider.custom_minimum_size.x = 140
	slider.size_flags_vertical = SIZE_SHRINK_CENTER
	slider.value_changed.connect(func(v): set_preview_time(v))
	slider.name = "TimeSlider"
	time_box.add_child(slider)
	time_label = Label.new()
	time_label.text = "12:00"
	time_box.add_child(time_label)
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
	canvas.notice.connect(_status)
	canvas.changed.connect(func(): _gfx_dirty = true)
	# 맵 칸 = [게임과 같은 그림·조명 (SubViewport)] 위에 [편집 선·물체 표시 (canvas)]
	var stage := Control.new()
	stage.size_flags_horizontal = SIZE_EXPAND_FILL
	stage.clip_contents = true
	split.add_child(stage)
	gfx_view = SubViewportContainer.new()
	gfx_view.stretch = true
	gfx_view.mouse_filter = MOUSE_FILTER_IGNORE
	gfx_view.set_anchors_preset(PRESET_FULL_RECT)
	stage.add_child(gfx_view)
	var vp := SubViewport.new()
	vp.handle_input_locally = false
	vp.canvas_item_default_texture_filter = Viewport.DEFAULT_CANVAS_ITEM_TEXTURE_FILTER_NEAREST
	gfx_view.add_child(vp)
	renderer = MapRenderer.new()
	renderer.roof_alpha = 0.55   # 에디터: 지붕 아래도 보이게 반투명
	vp.add_child(renderer)
	canvas.set_anchors_preset(PRESET_FULL_RECT)
	stage.add_child(canvas)
	world = WorldView.new()
	world.set_anchors_preset(PRESET_FULL_RECT)
	world.visible = false
	world.open_requested.connect(func(id):
		if id != map.get("map_id", ""):
			open_map(id)
		world_button.button_pressed = false)
	world.notice.connect(_status)
	world.link_requested.connect(link_maps)
	world.unlink_requested.connect(unlink_maps)
	stage.add_child(world)
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
	if ps.is_empty() and map.start is Array and not map.has("edges"):   # 예전 맵만 (P 를 일부러 다 지운 맵은 start 가 비어 있음)
		var st: Array = map.start
		map.objects.insert(0, {"object_id": id + "_p", "type": "arrive", "x": st[0], "y": st[1], "ref": "", "name": "기본",
			"text": "", "patrol_dir": "", "patrol_len": 0, "condition": "", "schedule": "", "arrive": "", "default": true})
	path = p
	canvas.require_default = false   # 기본 P 는 어느 맵에도 필수 아님 (2026-10-18)
	canvas.set_map(map)
	_gfx_dirty = true
	dirty = false
	_undo.clear()
	_redo.clear()
	_select_file_item(id)
	_load_all_maps()
	_edit_map()
	var gw := graphics_warnings()
	_status("열림: " + id + ("   ⚠ 그래픽 경고 %d개 (맵 설정 칸)" % gw.size() if not gw.is_empty() else ""))


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
	canvas.require_default = false
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
	else:
		map.start = null   # P 가 없는 맵 (이어지는 가장자리로만 들어옴)
	# 무손실 저장: 맵·물체의 모든 칸을 그대로 쓴다 (에디터가 모르는 칸도). 빈 기본값만 빼서 예전 맵 파일이 그대로 유지되게
	var out := {"map_id": map.map_id, "tiles": map.tiles, "start": map.get("start"), "run_start": map.get("run_start"),
		"objects": []}
	for k in map:
		if not k in out and k != "objects":
			out[k] = map[k]
	if out.get("edges", {}).is_empty():
		out.erase("edges")
	if out.get("visual") is Dictionary and out.visual.get("layers", {}).is_empty() and out.visual.size() <= 1:
		out.erase("visual")
	for o in map.objects:
		var e := {}
		for k in ["object_id", "type", "x", "y", "ref", "name", "text", "patrol_dir", "patrol_len", "condition", "schedule"]:
			e[k] = o.get(k, "" if k not in ["x", "y", "patrol_len"] else 0)
		for k in o:
			if not e.has(k):
				e[k] = o[k]
		if e.get("from", []).is_empty():
			e.erase("from")
		if not e.get("default", false):
			e.erase("default")
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
	for wmsg in graphics_warnings():
		_note("⚠ " + wmsg, Color("ffb454"))
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
	_section("환경 (조명)")
	var env: String = map.get("environment", {}).get("profile", "outdoor") if map.get("environment") is Dictionary else "outdoor"
	var profs := [["outdoor", "실외 — 낮·밤에 따라 밝기가 바뀜"], ["indoor", "실내 — 늘 같은 어두운 주변광"], ["underground", "지하 — 햇빛 없음, 광원 위주"]]
	for pid in VisualData.profiles():
		if not profs.any(func(x): return x[0] == pid):
			profs.append([pid, pid])
	_option("환경", profs, env, func(v):
		checkpoint()
		map.environment = {"profile": v}
		dirty = true
		_gfx_dirty = true)
	_hint("밝기·색은 엑셀 graphics.xlsx DayNight. 위 '시간 미리보기'로 시각마다 확인")
	_section("기본 그림 (칠하지 않은 칸)")
	for d in [["default_floor", "floor", "기본 바닥", "floor_default"], ["default_wall", "wall", "기본 벽", "wall_default"]]:
		var field: String = d[0]
		var layer: String = d[1]
		var keys: Array = VisualData.tiles().keys().filter(func(k): return str(VisualData.tiles()[k].get("layer", "")) == layer)
		var cur: String = str(map.get("visual", {}).get(field, "")) if map.get("visual") is Dictionary else ""
		_option(d[2], [["", "기본 (%s)" % d[3]]] + keys.map(func(k): return [k, "%s  (%s)" % [VisualData.tiles()[k].name, k]]), cur, func(v):
			checkpoint()
			if not map.get("visual") is Dictionary:
				map.visual = {}
			if v == "":
				map.visual.erase(field)
			else:
				map.visual[field] = v
			dirty = true
			_gfx_dirty = true)
	_hint("넓은 맵은 풀밭·숲처럼 가장 많은 그림을 기본으로 두고, 다른 곳만 칠하면 파일이 작아요")
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
			var seam := CheckBox.new()
			seam.text = "   이어지는 맵 (P 대신 같은 자리로)"
			seam.tooltip_text = "켜면 도착 P 로 가지 않고, %s 맵의 반대쪽 가장자리에서 걸어 나간 자리 그대로 이어서 들어감 (그 자리가 막혔으면 옆 칸, 없으면 P)" % e.ref
			seam.button_pressed = bool(e.get("seamless", false))
			seam.toggled.connect(func(on):
				checkpoint()
				if on:
					map.edges[dir_id].seamless = true
				else:
					map.edges[dir_id].erase("seamless")
					map.edges[dir_id].erase("offset")
				dirty = true
				_refresh_links()
				_edit_map.call_deferred())
			inspector.add_child(seam)
			if e.get("seamless", false):
				var off := _spin("   칸 어긋남", int(e.get("offset", 0)), -999, 999)
				off.tooltip_text = "두 맵이 가장자리를 따라 어긋난 칸 수. 이 맵의 %s칸이 저쪽 맵의 몇 칸이 되는지: 저쪽 = 이쪽 + 어긋남" % ("x" if dir_id in ["up", "down"] else "y")
				off.value_changed.connect(func(v):
					checkpoint("edge/%s/offset" % dir_id)
					if int(v) == 0:
						map.edges[dir_id].erase("offset")
					else:
						map.edges[dir_id].offset = int(v)
					dirty = true)
				_hint("반대 방향도 이어지게 하려면 %s 맵의 %s 가장자리도 이 맵으로 '이어지는 맵'을 켜고 어긋남을 반대 부호로" % [e.ref, Canvas.EDGE_NAME.get({"up": "down", "down": "up", "left": "right", "right": "left"}.get(dir_id, ""), "")])
			else:
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
			# 몬스터 AI: Behavior Tree 고르기 (만들기·고치기는 '몬스터 AI' 탭에서)
			var ai := AIAssets.load_dir()
			var bts: Array = ai.keys().filter(func(k): return AIAssets.kind_of(ai[k]) == "behavior_tree")
			bts.sort()
			_option("AI (Behavior Tree)", [["", "(예전 AI — 순찰·추격)"]] + bts.map(func(k): return [k, k]), o.get("bt", ""), func(v):
				set_field(o, "bt", v)
				_edit_object.call_deferred(o))
			var bt_on := bool(ai.get(str(o.get("bt", "")), {}).get("battle_on_contact", true))
			var base := ("BT 설정 따름 (%s)" % ("켬" if bt_on else "끔")) if str(o.get("bt", "")) != "" else "기본 (켬)"
			_option("닿으면 바로 전투", [["", base], ["on", "켬 — 닿는 순간 전투"], ["off", "끔 — 닿아도 전투 안 함"]], o.get("touch_battle", ""), func(v):
				set_field(o, "touch_battle", v))
			_hint("끄면 BT 의 '전투 시작'(EnterTurnBattle) Task 로만 싸웁니다." if str(o.get("bt", "")) != "" 				else "예전 AI 는 '끔' 이면 싸우지 않습니다 (따라오기만).")
			_option("다른 맵까지 따라오기", [["", "켬 — 쫓다가 플레이어가 문으로 나가면 몇 초 뒤 따라 들어옴"], ["off", "끔"]], o.get("follow", ""), func(v):
				set_field(o, "follow", v))
			if str(o.get("bt", "")) != "":
				_bb_overrides(o, ai)
		"light":
			_section("광원")
			var pres: Array = VisualData.presets()
			_option("프리셋", [["", "(직접)"]] + pres.map(func(p): return [p.preset_id, p.name]), o.get("preset", ""), func(v):
				var p := VisualData.preset(v)
				checkpoint()
				o.preset = v
				if not p.is_empty():
					for k in ["color", "energy", "radius", "shadow"]:
						o[k] = p.get(k, o.get(k))
					canvas.light_defaults = _light_from_preset(p)   # 다음에 놓을 광원도 이 프리셋
				dirty = true
				_gfx_dirty = true
				canvas.queue_redraw()
				_edit_object.call_deferred(o))
			var cp := ColorPickerButton.new()
			cp.color = Color.html(str(o.get("color", "#FFFFFF"))) if Color.html_is_valid(str(o.get("color", ""))) else Color.WHITE
			cp.edit_alpha = false
			cp.custom_minimum_size.y = 28
			cp.color_changed.connect(func(c):
				checkpoint("%s/color" % o.object_id)
				o.color = "#" + c.to_html(false).to_upper()
				dirty = true
				_gfx_dirty = true
				canvas.queue_redraw())
			_row("색", cp)
			for f in [["energy", "밝기", 0.0, 4.0, 0.05], ["radius", "범위 (칸)", 0.5, 30.0, 0.5]]:
				var sp := SpinBox.new()
				sp.min_value = f[2]
				sp.max_value = f[3]
				sp.step = f[4]
				sp.value = float(o.get(f[0], 1.0))
				var key: String = f[0]
				sp.value_changed.connect(func(v):
					checkpoint("%s/%s" % [o.object_id, key])
					o[key] = v
					dirty = true
					_gfx_dirty = true
					canvas.queue_redraw())
				_row(f[1], sp)
			for f in [["shadow", "벽 그림자"], ["enabled", "켜짐"]]:
				var cb := CheckBox.new()
				cb.text = f[1]
				cb.button_pressed = o.get(f[0], true)
				var key: String = f[0]
				cb.toggled.connect(func(on):
					checkpoint()
					o[key] = on
					dirty = true
					_gfx_dirty = true
					canvas.queue_redraw())
				inspector.add_child(cb)
			_hint("보이는 모습만 (적 시야·발견과는 상관없음). 위 '시간 미리보기'를 00 으로 두면 밤에 어떻게 보이는지 확인")
		"prop":
			_section("오브젝트 그림")
			var defs := VisualData.props()
			_option("그림", defs.keys().map(func(k): return [k, "%s  (%s)" % [defs[k].name, k]]), o.get("ref", ""), func(v):
				set_field(o, "ref", v)
				_gfx_dirty = true
				_edit_object.call_deferred(o))
			var d: Dictionary = defs.get(o.get("ref", ""), {})
			if not d.is_empty():
				_hint("%d×%d칸 (놓은 칸 = 왼쪽 아래)%s%s. 값은 graphics.xlsx Props" % [int(d.foot_w), int(d.foot_h),
					" · 지나갈 수 없음(적 시야도 막음)" if d.get("solid", false) else "", " · 빛을 막음" if d.get("casts_shadow", false) else ""])
		"event":
			_section("이벤트 (밟으면 시작)")
			_option("대화 (컷신)", dialogue_starts, o.get("ref", ""), func(v): set_field(o, "ref", v))
			var once := CheckBox.new()
			once.text = "한 번만 (한 번 본 뒤에는 다시 밟아도 안 나옴)"
			once.button_pressed = o.get("once", false)
			once.toggled.connect(func(on):
				if on:
					set_field(o, "once", true)
				else:
					checkpoint()
					o.erase("once")
					dirty = true)
			inspector.add_child(once)
			_hint("게임에서는 보이지 않습니다. 대화에 🎬 연출 카드를 넣으면 컷신이 됩니다 (그동안 플레이어는 못 움직임).")
		"npc":
			_section("NPC")
			_option("대화", dialogue_starts, o.get("ref", ""), func(v): set_field(o, "ref", v))
			_option("바라보는 방향", [["", "↓ 아래 (기본)"], ["up", "↑ 위"], ["left", "← 왼쪽"], ["right", "→ 오른쪽"]],
				o.get("face", ""), func(v): set_field(o, "face", v))
			_line("시간대", o.get("schedule", ""), func(v): set_field(o, "schedule", v), "06:00-12:00, 20:00-23:00 (비우면 항상)")
			_hint("같은 NPC(같은 대화)를 여러 곳에 두고 시간대를 나누면 시간마다 다른 자리에 나타남 (겹치면 변환할 때 경고)")
			_option("움직임", [["", "제자리"], ["radius", "반경 안에서 돌아다니기"], ["route", "정해진 길 따라 걷기"]], o.get("wander", ""), func(v):
				set_field(o, "wander", v)
				_edit_object.call_deferred(o))
			if o.get("wander", "") == "radius":
				var wr := _spin("돌아다니는 반경 (칸)", maxi(1, int(o.get("wander_radius", 3))), 1, 40)
				wr.tooltip_text = "놓은 자리 둘레 이 칸 수 안에서 가끔 걷다 멈춤 (쉬는 시간·속도는 엑셀 Config npc_wander_*)"
				wr.value_changed.connect(func(v): set_field(o, "wander_radius", int(v)))
			elif o.get("wander", "") == "route":
				_line("길 (칸 좌표)", str(o.get("route", "")), func(v): set_field(o, "route", v),
					"5,6; 9,6; 9,10 — 칸에 마우스를 올리면 좌표. 끝나면 처음으로")
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
			if o.type == "exit":   # 문 그림 (graphics.xlsx Tiles layer=door, 열림 = 같은 이름 + _open)
				var doors: Array = VisualData.tiles().keys().filter(func(k): return str(VisualData.tiles()[k].get("layer", "")) == "door" and not str(k).ends_with("_open"))
				_option("문 모양", [["", "기본 (%s)" % VisualData.default_art("door")]] + doors.map(func(k): return [k, "%s  (%s)" % [VisualData.tiles()[k].name, k]]), o.get("look", ""), func(v):
					set_field(o, "look", v)
					_gfx_dirty = true)
		"furniture":
			_edit_furniture(o)
		"window":
			_section("창문")
			var wins: Array = VisualData.tiles().keys().filter(func(k): return str(VisualData.tiles()[k].get("layer", "")) == "window" and not str(k).ends_with("_curtain"))
			_option("창문 모양", [["", "기본 (%s)" % VisualData.default_art("window")]] + wins.map(func(k): return [k, "%s  (%s)" % [VisualData.tiles()[k].name, k]]), o.get("look", ""), func(v):
				set_field(o, "look", v))
			_size_spins(o)
			var auto_in := VisualData.window_inside(map, {"x": o.x, "y": o.y})
			_option("안쪽 맵 (바깥 창문)", [["", "자동 — 가장 가까운 문의 맵 (%s)" % (auto_in if auto_in != "" else "없음")]] + map_ids.map(func(m): return [m, m]),
				o.get("inside", ""), func(v):
					set_field(o, "inside", v)
					_gfx_dirty = true)
			_hint("실외 맵의 창문은 햇빛을 내보내지 않고, 안쪽 맵에 켜진 광원이 있으면 불 켜진 창(따뜻한 빛, 밤에 또렷)으로 보입니다.")
			var cur := CheckBox.new()
			cur.text = "처음에 커튼을 쳐 둠"
			cur.tooltip_text = "켜면 맵에 처음 들어왔을 때 커튼이 쳐져 있어 빛이 안 들어옴. 게임에서 E 로 치고 걷기 (회차 저장에 남음)"
			cur.button_pressed = bool(o.get("curtain", false))
			cur.toggled.connect(func(on): set_field(o, "curtain", on))
			inspector.add_child(cur)
			_hint("놓은 칸 = 왼쪽 위. 빛은 옆의 바닥 쪽(아래 → 위 → 왼쪽 → 오른쪽 순서로 처음 찾은 쪽), 없으면 뒷벽 창문 — 아래로 벽만 이어지다 나오는 바닥으로 들어옵니다 (게임에서는 그 바닥에서 창문 밑에 서서 E). 밝기·거리는 엑셀 Config window_light_energy · window_light_radius, 시간대는 '시간 미리보기'로 확인")
		"arrive":
			_section("도착 P")
			var dcb := CheckBox.new()
			dcb.text = "★ 기본 P"
			dcb.tooltip_text = "아무 P 에도 이어지지 않은 곳으로 들어올 때 서는 P (선택 — 없으면 첫 P). 부활·불러오기는 베이스캠프의 부활 R"
			dcb.button_pressed = o.get("default", false)
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


## 몬스터별 Blackboard 시작값 (BB 키 중 '개체별 override' 를 켠 것만 — 몬스터 AI 탭 Blackboard 표에서 켬)
func _bb_overrides(o: Dictionary, ai: Dictionary) -> void:
	var bb: Dictionary = ai.get(str(ai.get(str(o.bt), {}).get("blackboard_id", "")), {})
	var keys: Array = bb.get("keys", []).filter(func(k): return k.get("instance_override", false))
	_section("개체별 Blackboard 시작값")
	if keys.is_empty():
		_hint("%s 에 개체별 override 를 켠 키가 없습니다 (몬스터 AI 탭 → Blackboard 표)" % bb.get("id", "Blackboard"))
		return
	var over: Dictionary = o.get("bb_overrides", {}) if o.get("bb_overrides") is Dictionary else {}
	for k in keys:
		var name := str(k.name)
		var row := HBoxContainer.new()
		var on := CheckBox.new()
		on.text = name
		on.button_pressed = over.has(name)
		on.tooltip_text = "켜면 이 몬스터만 시작값을 바꿈 (기본값 %s)" % [k.get("default")]
		row.add_child(on)
		var val: Control
		var cur: Variant = over.get(name, k.get("default"))
		match str(k.type):
			"bool":
				val = CheckBox.new()
				val.button_pressed = bool(cur)
				val.toggled.connect(func(v): _set_override(o, name, v))
			"int", "float":
				val = SpinBox.new()
				val.step = 1.0 if k.type == "int" else 0.1
				val.min_value = -9999
				val.max_value = 9999
				val.value = float(cur) if cur != null else 0.0
				val.value_changed.connect(func(v): _set_override(o, name, int(v) if k.type == "int" else v))
			_:
				val = LineEdit.new()
				val.text = "" if cur == null else str(cur)
				val.text_submitted.connect(func(v): _set_override(o, name, v))
		val.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		val.editable = on.button_pressed if val is LineEdit else true
		row.add_child(val)
		on.toggled.connect(func(v):
			if v:
				_set_override(o, name, val.value if val is SpinBox else (val.button_pressed if val is CheckBox else val.text))
			else:
				_set_override(o, name, null))
		inspector.add_child(row)


## v = null 이면 덮어쓰기를 끔
func _set_override(o: Dictionary, key: String, v: Variant) -> void:
	checkpoint("%s/bb/%s" % [o.get("object_id", ""), key])
	var over: Dictionary = (o.get("bb_overrides", {}) if o.get("bb_overrides") is Dictionary else {}).duplicate()
	if v == null:
		over.erase(key)
	else:
		over[key] = v
	if over.is_empty():
		o.erase("bb_overrides")
	else:
		o.bb_overrides = over
	dirty = true


func set_field(o: Dictionary, key: String, v: Variant) -> void:
	checkpoint("%s/%s" % [o.get("object_id", ""), key])
	o[key] = v
	dirty = true
	_gfx_dirty = true   # 그림(오브젝트·광원·문)에도 반영
	if key in ["ref", "arrive", "from", "object_id", "name"]:
		_refresh_links()
	canvas.queue_redraw()


## 너비·높이 (칸) — 가구·창문. 못 놓는 크기(가구: 벽·다른 물체와 겹침 / 창문: 벽이 아닌 칸·빛이 들어갈 바닥 없음)면 되돌림
func _size_spins(o: Dictionary) -> void:
	for f in [["w", "너비 (칸)"], ["h", "높이 (칸)"]]:
		var key: String = f[0]
		var sp := _spin(f[1], maxi(1, int(o.get(key, 1))), 1, 50)
		sp.value_changed.connect(func(v):
			var old := int(o.get(key, 1))
			o[key] = int(v)
			var ok: bool = canvas.fits(str(o.type), Vector2i(int(o.x), int(o.y)), o)
			o[key] = old
			if not ok:
				sp.set_value_no_signal(old)
				_status("그 크기는 놓을 수 없어요 (가구: 벽·다른 물체와 겹침 / 창문: 벽이 아닌 칸이 들어감)")
				return
			set_field(o, key, int(v)))


## 기타 가구 세부: 크기·표시 메모·색·막힘 / 역할(조사·줍기·사용·대화)과 역할별 칸 / 사용 조건·못 쓸 때 문구
func _edit_furniture(o: Dictionary) -> void:
	_section("가구")
	_line("표시 메모", o.get("label", ""), func(v):
		set_field(o, "label", v)
		canvas.queue_redraw(), "사각형 위에 보이는 글 (예: 철제 서랍, 거대한 시계)")
	_size_spins(o)
	var cp := ColorPickerButton.new()
	cp.color = Color.html(str(o.get("color", "#FFFFFF"))) if Color.html_is_valid(str(o.get("color", ""))) else Color.WHITE
	cp.edit_alpha = false
	cp.custom_minimum_size.y = 28
	cp.color_changed.connect(func(c): set_field(o, "color", "#" + c.to_html(false).to_upper()))
	_row("색", cp)
	var sol := CheckBox.new()
	sol.text = "지나갈 수 없음 (벽처럼 막고 적 시야도 가림)"
	sol.button_pressed = o.get("solid", true) != false
	sol.toggled.connect(func(on): set_field(o, "solid", on))
	inspector.add_child(sol)
	var tr := _spin("뒤로 지나가는 윗줄", clampi(int(o.get("top_rows", 0)), 0, 49), 0, 49)
	tr.tooltip_text = "위쪽 몇 줄은 막지 않고 뒤로 지나갈 수 있게 (키 큰 장롱·시계). 그 뒤에 서면 가구 그림이 캐릭터를 가림. 0 = 전부 막힘"
	tr.value_changed.connect(func(v):
		var h := maxi(1, int(o.get("h", 1)))
		if int(v) >= h:
			tr.set_value_no_signal(h - 1)
			v = h - 1
		set_field(o, "top_rows", int(v)))
	_section("역할")
	_option("E 를 누르면", [["", "(없음 — 장식)"], ["investigate", "조사 — 문구 + 얻는 것(Loot) 한 번"], ["pickup", "줍기 — 효과(아이템 얻기 등) 후 사라짐"],
		["use", "사용 — 효과, 여러 번"], ["talk", "대화 — 대화 시작"]], o.get("role", ""), func(v):
			set_field(o, "role", v)
			canvas.queue_redraw()
			_edit_object.call_deferred(o))
	var role := str(o.get("role", ""))
	if role == "":
		_hint("장식은 보이기만 합니다 (막힘은 위 체크).")
		return
	if role == "talk":
		_option("대화", dialogue_starts, o.get("ref", ""), func(v): set_field(o, "ref", v))
	if role == "investigate":
		_option("얻는 것", [["", "(없음)"]] + loot_spots, o.get("ref", ""), func(v): set_field(o, "ref", v))
	if role in ["investigate", "pickup", "use"]:
		var te := TextEdit.new()
		te.text = o.get("text", "")
		te.placeholder_text = "쓸 때 나오는 문구 (비워도 됨)" if role != "investigate" else "조사할 때 나오는 문구"
		te.custom_minimum_size.y = 70
		te.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
		te.text_changed.connect(func(): set_field(o, "text", te.text))
		inspector.add_child(te)
	if role in ["pickup", "use"]:
		_note("효과 (예: 아이템 얻기)", Color(0.8, 0.8, 0.8))
		var eff: Node = ExprRows.new().setup("effect", o.get("effects", ""), lookups)
		eff.changed.connect(func(v): set_field(o, "effects", v))
		inspector.add_child(eff)
	_section("사용 조건")
	var cond: Node = ExprRows.new().setup("cond", o.get("use_condition", ""), lookups)
	cond.changed.connect(func(v): set_field(o, "use_condition", v))
	inspector.add_child(cond)
	_line("못 쓸 때 문구", o.get("use_fail_text", ""), func(v): set_field(o, "use_fail_text", v), "비우면 '지금은 쓸 수 없다.'")


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
		"start": map.get("start"), "run_start": map.get("run_start"), "edges": map.get("edges", {}).duplicate(true),
		"visual": map.visual.duplicate(true) if map.get("visual") is Dictionary else null,
		"environment": map.environment.duplicate(true) if map.get("environment") is Dictionary else null}


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
	for k in ["visual", "environment"]:
		if snap.get(k) != null:
			map[k] = snap[k].duplicate(true)
		else:
			map.erase(k)
	_last_ck = ""
	canvas.set_map(map)
	_gfx_dirty = true
	dirty = true
	_refresh_links()
	_edit_map()


## 월드 맵 이어붙이기: a 의 dir 가장자리 → b 를 '이어지는 맵'(칸 어긋남 off), b 의 반대쪽 → a (어긋남 -off). 양쪽 파일에 바로 저장.
## 그 쪽에 다른 맵이 이어져 있었으면 바꿈 (상태 글자로 알림). 실제로 지나가려면 두 맵 모두 그쪽 맨 끝 줄이 바닥이어야
func link_maps(a: String, dir: String, b: String, off: int) -> void:
	var opp: String = {"up": "down", "down": "up", "left": "right", "right": "left"}[dir]
	var replaced := []
	for pair in [[a, dir, b, off], [b, opp, a, -off]]:
		var m := _world_map_dict(pair[0])
		if m.is_empty():
			continue
		if pair[0] == map.get("map_id", ""):
			checkpoint()
		if not m.get("edges") is Dictionary:
			m.edges = {}
		var old = m.edges.get(pair[1], {})
		if old is Dictionary and str(old.get("ref", "")) not in ["", pair[2]]:
			replaced.append("%s %s(%s 대신)" % [pair[0], Canvas.EDGE_NAME.get(pair[1], pair[1]), old.ref])
		m.edges[pair[1]] = {"ref": pair[2], "arrive": "", "seamless": true}
		if int(pair[3]) != 0:
			m.edges[pair[1]].offset = int(pair[3])
		_write_world_map(pair[0])
	_status("이어붙임: %s %s ↔ %s (칸 어긋남 %+d)%s — 지나가려면 두 맵 모두 그쪽 맨 끝 줄을 바닥으로" % [a, Canvas.EDGE_NAME.get(dir, dir), b, off,
		("   ⚠ 바꿈: " + ", ".join(replaced)) if not replaced.is_empty() else ""])
	_refresh_links()
	world.refresh(_all_maps, map.get("map_id", ""))


## 월드 맵 떼기: a ↔ b 사이 가장자리를 양쪽에서 지움
func unlink_maps(a: String, b: String) -> void:
	for pair in [[a, b], [b, a]]:
		var m := _world_map_dict(pair[0])
		if m.is_empty() or not m.get("edges") is Dictionary:
			continue
		var gone: Array = m.edges.keys().filter(func(d): return m.edges[d] is Dictionary and str(m.edges[d].get("ref", "")) == pair[1])
		if gone.is_empty():
			continue
		if pair[0] == map.get("map_id", ""):
			checkpoint()
		for d in gone:
			m.edges.erase(d)
		if m.edges.is_empty() and pair[0] != map.get("map_id", ""):
			m.erase("edges")
		_write_world_map(pair[0])
	_status("뗌: %s ↔ %s (가장자리 연결 지움)" % [a, b])
	_refresh_links()
	world.refresh(_all_maps, map.get("map_id", ""))


func _world_map_dict(id: String) -> Dictionary:
	if id == map.get("map_id", ""):
		return map
	return _all_maps.get(id, {}) if _all_maps.get(id) is Dictionary else {}


## 지금 맵은 save(), 다른 맵은 그 파일에 그대로 (에디터 저장과 같은 모양)
func _write_world_map(id: String) -> void:
	if id == map.get("map_id", ""):
		dirty = true
		save()
		return
	var f := FileAccess.open(dir + id + ".json", FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(_all_maps[id], " ", false) + "
")


## 월드 맵 보이기·숨기기 (보일 때 모든 맵을 다시 읽음 — 지금 맵은 편집 중인 내용)
func show_world(on: bool) -> void:
	if world_button and world_button.button_pressed != on:
		world_button.set_pressed_no_signal(on)
	if on:
		_load_all_maps()
		world.refresh(_all_maps, map.get("map_id", ""))
		if not _world_fitted:
			_world_fitted = true
			world.fit_all.call_deferred()
	world.visible = on
	canvas.visible = not on
	gfx_view.visible = not on and canvas.filters.graphics


## 칠한 그림대로 벽·바닥 맞추기 (예전에 '벽 외형'으로 칠해 지나갈 수 있던 칸 고치기):
## 벽 층 그림이 있는 바닥 칸 → 벽, 벽 층 그림 없이 바닥 그림만 있는 벽 칸 → 바닥. 물체·P·S 칸과 창문은 그대로. 실행 취소 가능
func sync_logic_to_paint() -> int:
	if map.is_empty():
		return 0
	var layers = (map.get("visual", {}) if map.get("visual") is Dictionary else {}).get("layers", {})
	if not layers is Dictionary:
		return 0
	var walls: Dictionary = layers.get("wall", {}) if layers.get("wall") is Dictionary else {}
	var floors: Dictionary = layers.get("floor", {}) if layers.get("floor") is Dictionary else {}
	checkpoint()
	var n := 0
	for y in map.tiles.size():
		for x in String(map.tiles[y]).length():
			var t := Vector2i(x, y)
			var k := "%d,%d" % [x, y]
			var o: Dictionary = canvas.object_at(t)
			if not o.is_empty() or canvas._is_marker(t, "start") or canvas._is_marker(t, "run_start"):
				continue
			var ch := String(map.tiles[y])[x]
			var want := ch
			if walls.has(k):
				want = "#"
			elif floors.has(k) and ch == "#":
				want = "."
			if want != ch:
				canvas._set_char(t, want)
				n += 1
	if n > 0:
		dirty = true
		_gfx_dirty = true
		canvas.changed.emit()
	_status("칠한 그림대로 맞춤: %d칸 (벽 그림 → 벽, 바닥 그림만 있는 벽 → 바닥) — Ctrl+Z 로 되돌리기" % n)
	canvas.queue_redraw()
	return n


## 모두 지우기: 크기·환경만 남기고 테두리 벽 + 바닥, 도착 P 하나만. 실행 취소(Ctrl+Z) 가능, 저장 전에는 파일 그대로
func clear_all() -> void:
	if map.is_empty():
		return
	checkpoint()
	var h: int = map.tiles.size()
	var w := 0
	for r in map.tiles:
		w = maxi(w, String(r).length())
	var tiles := []
	for y in h:
		var row := ""
		for x in w:
			row += "#" if x == 0 or y == 0 or x == w - 1 or y == h - 1 else "."
		tiles.append(row)
	var had_default: bool = map.get("objects", []).any(func(o): return o.get("type") == "arrive" and o.get("default", false))
	var p := {"object_id": str(map.map_id) + "_p", "type": "arrive", "x": w / 2, "y": h / 2, "ref": "", "name": "기본", "text": "",
		"patrol_dir": "", "patrol_len": 0, "condition": "", "schedule": "", "arrive": ""}
	if had_default or map.map_id == basecamp_id:
		p.default = true
	_restore({"tiles": tiles, "objects": [p], "start": [w / 2, h / 2], "run_start": null, "edges": {}, "visual": null,
		"environment": map.environment.duplicate(true) if map.get("environment") is Dictionary else null})
	canvas.select({})
	_status("모두 지움 (%d×%d) — Ctrl+Z 로 되돌리기, 저장해야 파일에 반영" % [w, h])


## 맵 삭제: 이 맵을 쓰는 곳 [설명] — 다른 맵의 문·통로·이용·가장자리, 효과 move:맵 (대화·거점·부활·아이템), Config
func map_references(id: String) -> Array:
	var out := []
	for e in _entrances_to(id):
		if not str(e[1]).begins_with(id + " — "):   # 자기 맵 안의 연결은 같이 사라지므로 빼고
			out.append("맵 " + str(e[1]))
	var re := RegEx.create_from_string("move:" + id + "(?![A-Za-z0-9_])")
	var seen := {}
	var srcs := []
	var d := DirAccess.open(dialogue_dir)
	if d:
		for f in d.get_files():
			if f.ends_with(".json") and not f.begins_with("_"):
				var dlg_file: Dictionary = ToolCommon.read_json(dialogue_dir + f, {})
				srcs.append(["대화 " + f.get_basename(), dlg_file.get("nodes", []) + dlg_file.get("choices", [])])
	for f in ["nodes", "choices", "camp_actions", "revivals", "items"]:   # 엑셀에서 온 것
		srcs.append([f, ToolCommon.read_json("res://data/%s.json" % f, [])])
	for src in srcs:
		for row in src[1]:
			if not row is Dictionary:
				continue
			for v in row.values():
				if v is String and re.search(v):
					var rid := str(row.get("choice_id", row.get("node_id", row.get("action_id", row.get("revival_id", row.get("item_id", "?"))))))
					var line := "%s — %s: %s" % [src[0], rid, v]
					if not seen.has(rid):
						seen[rid] = true
						out.append(line)
					break
	var cfg: Dictionary = ToolCommon.read_json("res://data/config.json", {})
	for k in ["start_map", "basecamp_map"]:
		if str(cfg.get(k, "")) == id:
			out.append("Config %s (엑셀 content.xlsx)" % k)
	return out


## 맵 파일을 지움 (휴지통으로 — 안 되면 그냥 지움). Config start_map·basecamp_map 인 맵은 못 지움. 다른 연결은 지운 뒤 변환 오류로 남음
func delete_map(id: String) -> bool:
	var cfg: Dictionary = ToolCommon.read_json("res://data/config.json", {})
	if id == basecamp_id or id == str(cfg.get("start_map", "")):
		_status("'%s' 는 베이스캠프·시작 맵이라 지울 수 없음 (엑셀 Config 를 먼저 바꾸세요)" % id)
		return false
	var p := dir + id + ".json"
	if not FileAccess.file_exists(p):
		_status("없는 맵: " + id)
		return false
	var full := ProjectSettings.globalize_path(p)
	if OS.move_to_trash(full) != OK and DirAccess.remove_absolute(full) != OK:
		_status("지울 수 없음: " + p)
		return false
	if map.get("map_id", "") == id:
		map = {}
		path = ""
		dirty = false
		_undo.clear()
		_redo.clear()
	refresh_file_list()
	_load_all_maps()
	_status("맵 삭제: %s (휴지통) — '변환·검사' 를 눌러야 게임에서도 빠짐" % id)
	return true


func _ask_delete_map() -> void:
	if map.is_empty():
		return
	var id: String = map.map_id
	var cfg: Dictionary = ToolCommon.read_json("res://data/config.json", {})
	if id == basecamp_id or id == str(cfg.get("start_map", "")):
		_status("'%s' 는 베이스캠프·시작 맵이라 지울 수 없음 (엑셀 Config 를 먼저 바꾸세요)" % id)
		return
	var refs := map_references(id)
	var dlg := ConfirmationDialog.new()
	dlg.title = "맵 삭제"
	var t := "'%s' 맵 파일을 지울까요? (tools/maps/%s.json → 휴지통)

실행 취소(Ctrl+Z)로는 되돌릴 수 없어요. 휴지통에서 꺼내면 돌아옵니다." % [id, id]
	if refs.is_empty():
		t += "

이 맵을 쓰는 곳은 없습니다."
	else:
		t += "

⚠ 이 맵을 쓰는 곳 %d개 — 지우면 변환 오류가 나니 먼저 고치세요:
  " % refs.size() + "
  ".join(refs.slice(0, 15))
		if refs.size() > 15:
			t += "
  … 외 %d개" % (refs.size() - 15)
	dlg.dialog_text = t
	dlg.ok_button_text = "삭제" if refs.is_empty() else "그래도 삭제"
	dlg.confirmed.connect(func():
		delete_map(id)
		dlg.queue_free())
	dlg.canceled.connect(dlg.queue_free)
	add_child(dlg)
	dlg.popup_centered()


func _ask_clear_all() -> void:
	if map.is_empty():
		return
	var dlg := ConfirmationDialog.new()
	dlg.title = "모두 지우기"
	dlg.dialog_text = "'%s' 를 빈 맵으로 만들까요?

벽·바닥, 칠한 그림(바닥·벽·지붕), 물체(적·NPC·문·조사·나무·광원 …), 가장자리 연결이 모두 사라지고
테두리 벽과 가운데 도착 P 하나만 남습니다. 크기와 환경(조명)은 그대로.

Ctrl+Z 로 되돌릴 수 있고, 저장하기 전에는 파일이 바뀌지 않아요." % map.map_id
	dlg.ok_button_text = "모두 지우기"
	dlg.confirmed.connect(func():
		clear_all()
		dlg.queue_free())
	dlg.canceled.connect(dlg.queue_free)
	add_child(dlg)
	dlg.popup_centered()


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
	var paint := {}   # 영역의 칠한 그림 {층: {"dx,dy": tile_key}}
	var layers = (map.get("visual", {}) if map.get("visual") is Dictionary else {}).get("layers", {})
	if r.size != Vector2i.ZERO and layers is Dictionary:
		for l in layers:
			if not layers[l] is Dictionary:
				continue
			for k in layers[l]:
				var xy := str(k).split(",")
				if xy.size() == 2 and r.has_point(Vector2i(int(xy[0]), int(xy[1]))):
					if not paint.has(l):
						paint[l] = {}
					paint[l]["%d,%d" % [int(xy[0]) - origin.x, int(xy[1]) - origin.y]] = layers[l][k]
	_clip = {"size": r.size, "tiles": tiles, "objects": rel, "paint": paint}
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
	if not _clip.tiles.is_empty():   # 칠한 그림: 붙여넣는 영역은 복사한 그대로 (원래 칠한 것은 지움)
		if not map.get("visual") is Dictionary:
			map.visual = {}
		if not map.visual.get("layers") is Dictionary:
			map.visual.layers = {}
		var layers: Dictionary = map.visual.layers
		for l in layers:
			if layers[l] is Dictionary and not canvas.locked_layers.has(l):   # 잠근 층은 그대로
				for k in layers[l].keys():
					var xy := str(k).split(",")
					if xy.size() == 2 and Rect2i(at, _clip.size).has_point(Vector2i(int(xy[0]), int(xy[1]))):
						layers[l].erase(k)
		var paint: Dictionary = _clip.get("paint", {})
		for l in paint.keys().filter(func(k): return not canvas.locked_layers.has(k)):
			if not layers.get(l) is Dictionary:
				layers[l] = {}
			for k in paint[l]:
				var xy := str(k).split(",")
				var t := at + Vector2i(int(xy[0]), int(xy[1]))
				if canvas.in_bounds(t):
					layers[l]["%d,%d" % [t.x, t.y]] = paint[l][k]
		_gfx_dirty = true
	var made := []
	for c in _clip.objects:
		var t := at + Vector2i(int(c.x), int(c.y))
		if not canvas.fits(str(c.get("type", "")), t, c) or not canvas.object_at(t).is_empty():
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
	# 타일 팔레트
	var pal_box := _fold(vb, "타일 팔레트", true)
	palette_layer = OptionButton.new()
	for l in VisualData.PAINT_LAYERS:
		palette_layer.add_item(VisualData.LAYER_NAME[l])
	palette_layer.add_item("오브젝트 (나무·가구)")
	palette_layer.tooltip_text = "칠할 그래픽 층. 벽 = 칠한 칸이 벽(지나갈 수 없음), 바닥 = 칠한 칸이 바닥, 나머지는 그림만 (바닥 → 바닥 장식 → 벽 순서로 겹침, 지붕은 인물 위 — 게임에서 집 안에 들어가면 그 집 지붕만 사라짐, 전경 가림은 인물 위에 늘 보임 — 통로 위 천장·검은 가림막, 지나가는 건 막지 않음), 또는 놓을 오브젝트 그림"
	palette_layer.item_selected.connect(func(i):
		if i < VisualData.PAINT_LAYERS.size():
			canvas.tile_layer = VisualData.PAINT_LAYERS[i]
		_sync_lock_box()
		_refresh_palette())
	pal_box.add_child(palette_layer)
	# 층 잠금: 잠근 층은 칠하기·지우기·영역 옮기기·붙여넣기에서 건드리지 않음 (편집 상태라 저장 안 됨)
	lock_box = CheckBox.new()
	lock_box.text = "🔒 이 층 잠금"
	lock_box.tooltip_text = "잠그면 이 층은 타일 붓·지우개·영역 옮기기·붙여넣기로 바뀌지 않음 (예: 바닥을 고칠 때 전경 가림 잠그기). 저장되지 않는 편집 설정"
	lock_box.toggled.connect(func(on):
		var l: String = canvas.tile_layer
		if on:
			canvas.locked_layers[l] = true
		else:
			canvas.locked_layers.erase(l)
		_status("'%s' 층 %s" % [VisualData.LAYER_NAME.get(l, l), "잠금" if on else "잠금 풂"]))
	pal_box.add_child(lock_box)
	palette_search = LineEdit.new()
	palette_search.placeholder_text = "타일 찾기"
	palette_search.clear_button_enabled = true
	palette_search.text_changed.connect(func(_t): _refresh_palette())
	pal_box.add_child(palette_search)
	palette = ItemList.new()
	palette.custom_minimum_size.y = 180
	palette.fixed_icon_size = Vector2i(40, 40)
	palette.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	palette.max_columns = 0
	palette.icon_mode = ItemList.ICON_MODE_TOP
	palette.same_column_width = true
	palette.fixed_column_width = 64
	palette.item_selected.connect(func(i):
		if _palette_props():
			canvas.prop_id = palette.get_item_metadata(i)
			set_tool("prop")
		else:
			canvas.tile_key = palette.get_item_metadata(i)
			set_tool("tile"))
	pal_box.add_child(palette)
	# 표시 필터
	var filt_box := _fold(vb, "표시", false)
	var grid := GridContainer.new()
	grid.columns = 2
	filt_box.add_child(grid)
	for f in [["tiles", "타일"], ["enemy", "적"], ["investigate", "조사"], ["npc", "NPC"], ["camp", "거점"], ["furniture", "가구"],
			["travel", "문·통로·이용"], ["arrive", "도착 P"], ["event", "이벤트"], ["sight", "순찰"], ["names", "이름표"], ["links", "연결"],
			["graphics", "그래픽"], ["lighting", "조명"], ["roof", "지붕"], ["overhead", "전경 가림"], ["overhead_only", "전경만"], ["props", "오브젝트"], ["light", "광원"], ["light_range", "광원 범위"], ["occluders", "그림자 차단"], ["logic", "벽 판정"]]:
		var cb := CheckBox.new()
		cb.text = f[1]
		cb.button_pressed = not f[0] in ["occluders", "logic", "overhead_only"]   # 그림자 차단·벽 판정·전경만은 처음엔 끔 (canvas.filters 와 같게)
		if f[0] == "logic":
			cb.tooltip_text = "지나갈 수 없는 곳(충돌)을 붉게: 벽·빈 공간·막힌 오브젝트·가구. 전경 가림은 충돌이 아니라 안 칠해짐"
		elif f[0] == "overhead":
			cb.tooltip_text = "전경 가림 층 보이기 — 끄면 그 아래 바닥·문·물체를 고치기 쉬움 (게임에는 영향 없음)"
		elif f[0] == "overhead_only":
			cb.tooltip_text = "전경 가림만 보이기 (위치 검사용)"
		var key: String = f[0]
		cb.toggled.connect(func(on):
			canvas.filters[key] = on
			canvas.select_many(canvas.selection.filter(canvas.is_visible_object))
			if key in ["graphics", "lighting", "roof", "overhead", "overhead_only"]:
				_apply_gfx_filters()
			canvas.queue_redraw())
		grid.add_child(cb)
		filter_boxes[key] = cb
	# 전경 가림 편집용 투명도 — 미리보기 전용 (맵 파일·게임 출력은 늘 불투명)
	var oa := HBoxContainer.new()
	var oal := Label.new()
	oal.text = "전경 투명도"
	oal.tooltip_text = "편집 미리보기 전용 — 저장되지 않고 게임에서는 늘 불투명"
	oa.add_child(oal)
	overhead_slider = HSlider.new()
	overhead_slider.min_value = 0
	overhead_slider.max_value = 100
	overhead_slider.value = 100
	overhead_slider.size_flags_horizontal = SIZE_EXPAND_FILL
	overhead_slider.tooltip_text = oal.tooltip_text
	overhead_slider.value_changed.connect(func(v):
		if renderer:
			renderer.set_overhead_alpha(v / 100.0))
	oa.add_child(overhead_slider)
	filt_box.add_child(oa)
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
		if e.get("seamless", false) and e.get("ref", "") in _all_maps:
			info = ["→ %s · 이어짐%s" % [e.ref, (" (어긋남 %+d)" % int(e.offset)) if int(e.get("offset", 0)) != 0 else ""], true]
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
		return ["→ %s · 첫 P" % ref, true]   # 이어진 P·기본 P 가 없으면 첫 P (기본 P 는 필수 아님)
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
	# 그래픽 (graphics.xlsx → data/graphics.json): 타일 팔레트·광원 프리셋 다시 읽기
	tile_px = float(cfg.get("field_tile", 80))
	VisualData.reload()
	var pres: Array = VisualData.presets()
	if canvas.light_defaults.is_empty() and not pres.is_empty():
		canvas.light_defaults = _light_from_preset(pres[0])
	if canvas.tile_key == "" or not VisualData.tiles().has(canvas.tile_key):
		for key in VisualData.tiles():
			if VisualData.tiles()[key].layer == canvas.tile_layer:
				canvas.tile_key = key
				break
	if canvas.prop_id == "" or not VisualData.props().has(canvas.prop_id):
		canvas.prop_id = VisualData.props().keys().front() if not VisualData.props().is_empty() else ""
	_refresh_palette()
	_apply_gfx_filters()
	_gfx_dirty = true


func _new_object_id(type: String) -> String:
	var used := {}
	for o in map.get("objects", []):
		used[o.object_id] = true
	var i := 1
	while used.has("%s_%s_%d" % [map.map_id, type, i]):
		i += 1
	return "%s_%s_%d" % [map.map_id, type, i]


# ---------------------------------------------------------------- 그래픽
## 매 프레임: 렌더러를 캔버스의 이동·확대에 맞추고, 바뀐 게 있으면 다시 그린다
func _process(_delta: float) -> void:
	if renderer == null or map.is_empty():
		return
	if _gfx_dirty:
		_gfx_dirty = false
		renderer.minutes = preview_minutes
		renderer.world_maps = _all_maps   # 바깥 창문이 안쪽 맵의 불을 봄
		renderer.build(map, tile_px)
	var k: float = canvas.cell * canvas.zoom / tile_px
	renderer.scale = Vector2(k, k)
	renderer.position = canvas.pan


func set_preview_time(m: float) -> void:
	preview_minutes = fposmod(m, 1440.0)
	if time_label:
		time_label.text = "%02d:%02d" % [int(preview_minutes) / 60, int(preview_minutes) % 60]
	var slider := find_child("TimeSlider", true, false)
	if slider and not is_equal_approx(slider.value, preview_minutes):
		slider.set_value_no_signal(preview_minutes)
	if renderer:
		renderer.set_time(preview_minutes)


func _sync_lock_box() -> void:
	if lock_box == null:
		return
	var objects := _palette_props()
	lock_box.disabled = objects
	lock_box.set_pressed_no_signal(not objects and canvas.locked_layers.has(canvas.tile_layer))


func _apply_gfx_filters() -> void:
	gfx_view.visible = canvas.filters.graphics and not (world != null and world.visible)
	canvas.graphics = canvas.filters.graphics
	if renderer:
		renderer.set_lighting(canvas.filters.lighting)
		var only: bool = canvas.filters.get("overhead_only", false)
		renderer.set_overhead_only(only)
		renderer.set_roofs_visible(canvas.filters.get("roof", true) and not only)
		renderer.set_overhead_visible(canvas.filters.get("overhead", true) or only)


## 팔레트: 지금 층의 타일 (그림 + 이름), 찾기
func _refresh_palette() -> void:
	if palette == null:
		return
	palette.clear()
	var q := palette_search.text.strip_edges().to_lower() if palette_search else ""
	if _palette_props():
		var defs := VisualData.props()
		for key in defs:
			var d: Dictionary = defs[key]
			if q != "" and not q in key.to_lower() and not q in String(d.name).to_lower():
				continue
			var i := palette.add_item(String(d.name), VisualData.texture(str(d.file), VisualData.PROPS_DIR))
			palette.set_item_metadata(i, key)
			palette.set_item_tooltip(i, "%s  (%s) — %d×%d칸%s%s" % [d.name, key, int(d.foot_w), int(d.foot_h),
				", 지나갈 수 없음" if d.get("solid", false) else "", ", 빛을 막음" if d.get("casts_shadow", false) else ""])
			if key == canvas.prop_id:
				palette.select(i)
		return
	for key in VisualData.tiles():
		var t: Dictionary = VisualData.tiles()[key]
		if t.layer != canvas.tile_layer or (q != "" and not q in key.to_lower() and not q in String(t.name).to_lower()):
			continue
		var reg := VisualData.tile_region(key)
		var icon: Texture2D = null
		if not reg.is_empty():
			var at := AtlasTexture.new()
			at.atlas = reg[0]
			at.region = reg[1]
			icon = at
		var i := palette.add_item(String(t.name), icon)
		palette.set_item_metadata(i, key)
		palette.set_item_tooltip(i, "%s  (%s)%s" % [t.name, key, "\n빛을 막음 (그림자)" if t.get("casts_shadow", false) else ""])
		if key == canvas.tile_key:
			palette.select(i)


func _palette_props() -> bool:
	return palette_layer != null and palette_layer.selected == VisualData.PAINT_LAYERS.size()


## 그래픽 경고 (게임에서는 기본 타일로 보이거나 빠짐 — 맵은 그대로 열림): 없는 타일·오브젝트·프리셋·환경, 맵 밖 칸
func graphics_warnings() -> Array:
	var out := []
	if map.is_empty() or VisualData.tiles().is_empty():
		return out
	var h: int = map.tiles.size()
	var w := 0
	for r in map.tiles:
		w = maxi(w, String(r).length())
	var layers = map.get("visual", {}).get("layers", {}) if map.get("visual") is Dictionary else {}
	if layers is Dictionary:
		for l in layers:
			if not layers[l] is Dictionary:
				continue
			var bad := {}
			var outside := 0
			for k in layers[l]:
				var key := str(layers[l][k])
				if not VisualData.tiles().has(key):
					bad[key] = true
				var xy := str(k).split(",")
				if xy.size() != 2 or int(xy[0]) >= w or int(xy[1]) >= h or int(xy[0]) < 0 or int(xy[1]) < 0:
					outside += 1
			if not bad.is_empty():
				out.append("%s 층에 없는 타일: %s (붉은 X 칸, 게임에서는 기본 타일)" % [VisualData.LAYER_NAME.get(l, l), ", ".join(bad.keys())])
			if outside > 0:
				out.append("%s 층에 맵 밖 칸 %d개 (무시됨)" % [VisualData.LAYER_NAME.get(l, l), outside])
	var prof: String = map.get("environment", {}).get("profile", "") if map.get("environment") is Dictionary else ""
	if prof != "" and not prof in VisualData.profiles():
		out.append("없는 환경 '%s' (실외로 보임)" % prof)
	var presets := VisualData.presets().map(func(p): return p.preset_id)
	for o in map.get("objects", []):
		if o.type == "light" and str(o.get("preset", "")) != "" and not o.preset in presets:
			out.append("광원 %s: 없는 프리셋 '%s' (저장된 값으로 보임)" % [o.object_id, o.preset])
		elif o.type == "prop" and not VisualData.props().has(str(o.get("ref", ""))):
			out.append("오브젝트 %s: 없는 그림 '%s' (게임에서 안 보임)" % [o.object_id, o.get("ref", "")])
	return out


static func _light_from_preset(p: Dictionary) -> Dictionary:
	return {"preset": p.get("preset_id", ""), "color": p.get("color", "#FFFFFF"), "energy": float(p.get("energy", 1.0)),
		"radius": float(p.get("radius", 4.0)), "shadow": bool(p.get("shadow", true)), "enabled": true}


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
