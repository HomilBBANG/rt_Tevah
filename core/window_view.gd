@tool
extends Node2D
## 창문 기본 그림 (맵 물체 type=window, 그림(look)을 따로 안 골랐을 때). 타일 하나를 늘리지 않고 크기(w × h 칸)에 맞춰
## 픽셀아트로 그린다 — 틀·유리·창살·창턱·커튼. 필드와 맵 에디터가 같이 씀 (map_renderer.build_markers).
##   face   = 뒷벽(앞에서 보이는 벽면)에 붙은 창문: 틀 + 유리 + 창살 + 창턱, 커튼은 양옆에 걷혀 있다가 치면 유리를 덮음
##   side_v = 왼쪽·오른쪽 벽(위에서 보이는 벽 윗면)의 창문: 세로로 가는 유리 줄
##   side_h = 앞쪽 벽(위에서 보이는 벽 윗면)의 창문: 가로로 가는 유리 줄
## 유리는 자식 노드(_glass)에 따로 그려서, 낮에는 주변광과 상관없이 밝게(UNSHADED) — 틀·커튼은 방과 같이 어두워짐.
## 위치 = 창문 사각형의 왼쪽 위. 단위는 그림 픽셀(16 = 한 칸), px 배로 키워 그림.

const ART := 16
const WOOD := Color(0.36, 0.25, 0.16)
const WOOD_DARK := Color(0.2, 0.13, 0.08)
const WOOD_LIGHT := Color(0.5, 0.36, 0.22)
const CURTAIN := Color(0.42, 0.11, 0.13)
const CURTAIN_DARK := Color(0.28, 0.07, 0.09)
const SKY_TOP := Color(0.78, 0.86, 0.92)
const SKY_BOTTOM := Color(0.55, 0.67, 0.78)
const NIGHT := Color(0.1, 0.12, 0.18)

var cells := Vector2i(1, 1)
var mode := "face"
var px := 5.0            # 화면 픽셀 / 그림 픽셀
var curtain := false
var daylight := 1.0      # 0 (밤) ~ 1 (한낮) — 유리 밝기
var _glass: Node2D


func _init() -> void:
	_glass = Node2D.new()
	_glass.show_behind_parent = true   # 유리를 먼저, 틀·창살·커튼은 그 위에
	_glass.draw.connect(_draw_glass)
	add_child(_glass)


func setup(p_cells: Vector2i, p_mode: String, p_px: float) -> void:
	cells = Vector2i(maxi(1, p_cells.x), maxi(1, p_cells.y))
	mode = p_mode
	px = p_px
	_glass.show_behind_parent = mode == "face"   # 벽면 창: 유리 위에 틀·창살·커튼 / 가는 창: 틀 칠한 위에 유리
	refresh()


## 커튼·낮 밝기가 바뀌면 다시 그림. 낮이고 커튼이 걷혀 있으면 유리는 빛 영향 없이 밝게
func refresh() -> void:
	var lit := not curtain and daylight > 0.05
	if lit and _glass.material == null:
		var mat := CanvasItemMaterial.new()
		mat.light_mode = CanvasItemMaterial.LIGHT_MODE_UNSHADED
		_glass.material = mat
	elif not lit:
		_glass.material = null
	queue_redraw()
	_glass.queue_redraw()


## 유리 사각형 (그림 픽셀)
func glass_rect() -> Rect2:
	var w := cells.x * ART
	var h := cells.y * ART
	match mode:
		"side_v":
			return Rect2(w / 2.0 - 1, 3, 2, h - 6)
		"side_h":
			return Rect2(3, h / 2.0 - 1, w - 6, 2)
	return Rect2(4, 4, w - 8, h - 9)


func _r(x: float, y: float, w: float, h: float, c: Color, on: CanvasItem = self) -> void:
	on.draw_rect(Rect2(x * px, y * px, w * px, h * px), c)


func _draw_glass() -> void:
	var g := glass_rect()
	if curtain:
		return
	var day := clampf(daylight, 0.0, 1.0)
	var rows := int(g.size.y)
	for i in rows:   # 위가 밝은 하늘, 아래로 갈수록 조금 진하게
		var t := float(i) / maxf(1.0, rows - 1.0)
		var c := SKY_TOP.lerp(SKY_BOTTOM, t)
		_r(g.position.x, g.position.y + i, g.size.x, 1, NIGHT.lerp(c, day) * Color(0.92 + 0.08 * day, 0.92 + 0.08 * day, 0.92 + 0.08 * day), _glass)
	if mode == "face" and day > 0.05 and g.size.x >= 4:   # 비스듬한 반사 줄
		for s in [2.0, 5.0]:
			for i in mini(int(g.size.y), 6):
				var x: float = g.position.x + s + i * 0.5
				if x < g.end.x - 1:
					_r(x, g.position.y + 1 + i, 1, 1, Color(1, 1, 1, 0.22 * day), _glass)


func _draw() -> void:
	var g := glass_rect()
	if mode != "face":
		# 벽 윗면의 가는 창: 틀 한 줄로 두르고, 커튼이면 붉은 천
		_r(g.position.x - 1, g.position.y - 1, g.size.x + 2, g.size.y + 2, WOOD_DARK)
		if curtain:
			_r(g.position.x, g.position.y, g.size.x, g.size.y, CURTAIN)
		return
	var w := float(cells.x * ART)
	var h := float(cells.y * ART)
	# 바깥 틀 (그림자 한 줄 + 나무 틀 2px)
	var frame := Rect2(2, 2, w - 4, h - 5)
	_r(frame.position.x - 1, frame.position.y - 1, frame.size.x + 2, frame.size.y + 2, Color(0, 0, 0, 0.35))
	_frame_ring(frame, 2, WOOD)
	_frame_ring(frame, 1, WOOD_DARK)   # 바깥 가장자리 진하게
	# 창살: 가운데 세로 한 줄(넓으면 여러 줄), 가로는 8px 정도마다
	var cols := maxi(1, int(round(g.size.x / 9.0)))
	for i in range(1, cols + 1):
		var x := g.position.x + g.size.x * i / (cols + 1.0) - 0.5
		if cols == 1 and g.size.x < 6:
			break
		_r(round(x), g.position.y, 1, g.size.y, WOOD)
	var rws := maxi(1, int(round(g.size.y / 9.0)))
	for i in range(1, rws + 1):
		var y := g.position.y + g.size.y * i / (rws + 1.0) - 0.5
		_r(g.position.x, round(y), g.size.x, 1, WOOD)
	# 커튼: 치면 유리를 덮고(주름), 걷으면 양옆에 조금 + 위에 커튼 봉
	if curtain:
		_drape(g.position.x, g.size.x, g)
	else:
		var side := clampf(floor(g.size.x / 6.0), 1.0, 4.0)
		_drape(g.position.x, side, g)
		_drape(g.end.x - side, side, g)
	_r(frame.position.x - 1, frame.position.y, frame.size.x + 2, 1, WOOD_LIGHT)   # 커튼 봉
	# 창턱: 틀보다 조금 넓게, 아래에 그림자
	_r(1, h - 4, w - 2, 2, WOOD_LIGHT)
	_r(1, h - 2, w - 2, 1, Color(0, 0, 0, 0.3))


## 틀 사각형의 두께 t 테두리 (가운데는 비움 — 유리가 보이게)
func _frame_ring(r: Rect2, t: float, c: Color) -> void:
	_r(r.position.x, r.position.y, r.size.x, t, c)
	_r(r.position.x, r.end.y - t, r.size.x, t, c)
	_r(r.position.x, r.position.y, t, r.size.y, c)
	_r(r.end.x - t, r.position.y, t, r.size.y, c)


## 커튼 천: x 부터 폭 width, 유리 높이만큼. 세로 주름
func _drape(x: float, width: float, g: Rect2) -> void:
	for i in int(width):
		_r(x + i, g.position.y, 1, g.size.y, CURTAIN if (int(x) + i) % 3 != 0 else CURTAIN_DARK)
	_r(x, g.end.y - 1, width, 1, CURTAIN_DARK)
