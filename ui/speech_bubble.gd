extends Control
## 말풍선: 둥근 사각형 + 화자 쪽(왼쪽/오른쪽 위)으로 뻗는 꼬리.
## dimmed = 지나간 대사 (회색).

const FILL := Color("f2f2f2")
const DIM_FILL := Color("808080")
const RADIUS := 16

var tail_side := "left"
var dimmed := false
var _label: Label


func _init() -> void:
	mouse_filter = MOUSE_FILTER_IGNORE
	_label = Label.new()
	_label.set_anchors_preset(PRESET_FULL_RECT)
	_label.offset_left = 36
	_label.offset_top = 16
	_label.offset_right = -24
	_label.offset_bottom = -12
	_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_label.add_theme_color_override("font_color", Color.BLACK)
	_label.add_theme_font_size_override("font_size", 20)
	add_child(_label)


func show_line(text: String, side: String, is_dimmed: bool) -> void:
	_label.text = text
	tail_side = side
	dimmed = is_dimmed
	queue_redraw()


func _draw() -> void:
	var fill := DIM_FILL if dimmed else FILL
	var sb := StyleBoxFlat.new()
	sb.bg_color = fill
	sb.set_corner_radius_all(RADIUS)
	sb.anti_aliasing = true
	draw_style_box(sb, Rect2(Vector2.ZERO, size))
	var w := size.x
	var tail: PackedVector2Array
	if tail_side == "left":
		tail = [Vector2(1, 18), Vector2(-22, 6), Vector2(1, 42)]
	else:
		tail = [Vector2(w - 1, 18), Vector2(w + 22, 6), Vector2(w - 1, 42)]
	draw_colored_polygon(tail, fill)
