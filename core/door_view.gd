@tool
extends Node2D
## 옆벽·아래쪽 벽에 단 문 (비스듬한 탑뷰). 정면 문(뒷벽·아래가 바닥)은 Tiles 그림(2칸 높이 door_tall 등)을 쓰고, 여기서는 그 밖을 그린다.
##   side   = 위아래가 벽인 문 (왼쪽·오른쪽 벽): 위에서 보면 문짝이 세로로 얇게 서 있음 → 열면 위쪽 문설주에 붙어 가로로 젖혀짐
##   bottom = 위가 바닥인 문 (방의 아랫벽): 문짝 윗면 + 앞면이 가로로 낮게 → 열면 왼쪽 문설주에 붙어 세로로 젖혀짐
## 위치 = 문 칸 왼쪽 위. 단위는 그림 픽셀(16 = 한 칸), px 배로 키워 그림. 열림·닫힘은 open (렌더러 set_door_open).

const WOOD := Color(0.56, 0.38, 0.23)
const WOOD_DARK := Color(0.38, 0.25, 0.15)
const WOOD_TOP := Color(0.68, 0.48, 0.3)
const EDGE := Color(0.22, 0.14, 0.08)
const SHADOW := Color(0, 0, 0, 0.28)

var mode := "side"
var px := 5.0
var open := false:
	set(v):
		open = v
		queue_redraw()


func setup(p_mode: String, p_px: float) -> void:
	mode = p_mode
	px = p_px
	queue_redraw()


func _r(x: float, y: float, w: float, h: float, c: Color) -> void:
	draw_rect(Rect2(x * px, y * px, w * px, h * px), c)


func _draw() -> void:
	if mode == "side":
		_draw_side()
	else:
		_draw_bottom()


## 옆벽 문: 닫힘 = 가운데 세로 문짝 (위로 6px 솟은 높이 + 윗면), 열림 = 위 문설주에 붙은 가로 문짝
func _draw_side() -> void:
	if not open:
		_r(9, 0, 2, 16, SHADOW)                 # 그림자
		_r(6, -6, 4, 22, WOOD)                  # 문짝 (세로로 얇게, 높이만큼 위로)
		_r(6, -6, 1, 22, WOOD_DARK)
		_r(9, -6, 1, 22, EDGE)
		_r(6, -6, 4, 2, WOOD_TOP)               # 윗면
		_r(9, 7, 1, 2, Color(0.86, 0.74, 0.43))   # 손잡이
	else:
		_r(1, 3, 14, 2, SHADOW)
		_r(1, -4, 14, 6, WOOD)                  # 젖혀진 문짝 (가로, 높이만큼 위로)
		_r(1, -4, 14, 2, WOOD_TOP)
		_r(1, 1, 14, 1, EDGE)
		_r(1, -4, 1, 6, EDGE)


## 아래쪽 벽 문: 닫힘 = 가로 문짝 (윗면 + 앞면), 열림 = 왼쪽 문설주에 붙은 세로 문짝
func _draw_bottom() -> void:
	if not open:
		_r(0, 14, 16, 2, SHADOW)
		_r(0, 6, 16, 3, WOOD_TOP)               # 문짝 윗면
		_r(0, 9, 16, 6, WOOD)                   # 앞면
		for x in [5.0, 10.0]:
			_r(x, 9, 1, 6, WOOD_DARK)
		_r(0, 14, 16, 1, EDGE)
		_r(12, 11, 1, 2, Color(0.86, 0.74, 0.43))
	else:
		_r(3, 2, 2, 14, SHADOW)
		_r(0, -2, 3, 16, WOOD)                  # 젖혀진 문짝 (세로)
		_r(0, -2, 3, 2, WOOD_TOP)
		_r(2, 0, 1, 14, EDGE)
