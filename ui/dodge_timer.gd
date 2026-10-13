extends Control
## 회피 타이밍 표시: 바깥 원이 줄어들어 안쪽 고리와 겹치는 순간이 타격 시점.
## 가운데에 공격 대상 부위(전조)를 표시한다. 어떤 키를 누를지는 플레이어가 판단한다.

const TARGET_RADIUS := 57.0
const START_RADIUS := 200.0

var progress := -1.0      # 0 = 전조 시작, 1 = 타격. <0 이면 숨김
var label := ""           # 전조 부위 이름
var result_text := ""
var result_color := Color.WHITE
var _font: Font


func _init() -> void:
	mouse_filter = MOUSE_FILTER_IGNORE
	_font = ThemeDB.fallback_font


func show_progress(p: float, part_name: String) -> void:
	progress = p
	label = part_name
	result_text = ""
	queue_redraw()


func show_result(text: String, color: Color) -> void:
	progress = -1.0
	result_text = text
	result_color = color
	queue_redraw()


func clear() -> void:
	progress = -1.0
	result_text = ""
	queue_redraw()


func _draw() -> void:
	var c := size / 2.0
	if progress >= 0.0:
		draw_arc(c, TARGET_RADIUS, 0, TAU, 48, Color("dddddd"), 5, true)
		var r := lerpf(START_RADIUS, TARGET_RADIUS, clampf(progress, 0.0, 1.2))
		var col := Color("ff9a3c").lerp(Color("ff4040"), clampf(progress, 0.0, 1.0))
		draw_arc(c, maxf(7.0, r), 0, TAU, 64, col, 7, true)
		_center_text(label, c + Vector2(0, 10), 30, Color.WHITE)
	elif result_text != "":
		_center_text(result_text, c + Vector2(0, 17), 50, result_color)


func _center_text(text: String, pos: Vector2, fs: int, col: Color) -> void:
	var w := _font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	draw_string_outline(_font, pos - Vector2(w / 2.0, 0), text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, 10, Color.BLACK)
	draw_string(_font, pos - Vector2(w / 2.0, 0), text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col)
