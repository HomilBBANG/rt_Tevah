extends Control
## 말풍선: 둥근 사각형 + 화자 쪽(왼쪽/오른쪽 위)으로 뻗는 꼬리. tail_side = "none" 이면 꼬리 없음(주인공).
## dimmed = 지나간 대사 (회색). 화자 이름표는 말풍선 위 테두리에 걸쳐 꼬리 쪽 모서리에 붙는다.

const FILL := Color("f2f2f2")
const DIM_FILL := Color("808080")
const RADIUS := 27
const DEFAULT_NAME_COLOR := Color("f2f2f2")

var tail_side := "left"
var dimmed := false
var _label: Label
var _name: Label


func _init() -> void:
	mouse_filter = MOUSE_FILTER_IGNORE
	_label = Label.new()
	_label.set_anchors_preset(PRESET_FULL_RECT)
	_label.offset_left = 60
	_label.offset_top = 37
	_label.offset_right = -40
	_label.offset_bottom = -20
	_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_label.add_theme_color_override("font_color", Color.BLACK)
	_label.add_theme_font_size_override("font_size", 33)
	add_child(_label)

	_name = Label.new()
	_name.anchor_right = 1.0
	_name.offset_top = -33
	_name.offset_bottom = 20
	_name.offset_left = 37
	_name.offset_right = -37
	_name.add_theme_font_size_override("font_size", 40)
	_name.add_theme_color_override("font_outline_color", Color(0.08, 0.08, 0.08))
	_name.add_theme_constant_override("outline_size", 13)
	add_child(_name)


## name_color 가 비어 있으면 기본색
func show_line(text: String, side: String, is_dimmed: bool, speaker_name := "", name_color := "") -> void:
	_label.text = text
	_name.text = speaker_name
	_name.visible = speaker_name != ""
	_name.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT if side == "left" else HORIZONTAL_ALIGNMENT_RIGHT
	_name.add_theme_color_override("font_color",
		Color.html(name_color) if Color.html_is_valid(name_color) else DEFAULT_NAME_COLOR)
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
	if tail_side == "none":
		return
	elif tail_side == "left":
		tail = [Vector2(2, 30), Vector2(-37, 10), Vector2(2, 70)]
	else:
		tail = [Vector2(w - 2, 30), Vector2(w + 37, 10), Vector2(w - 2, 70)]
	draw_colored_polygon(tail, fill)
