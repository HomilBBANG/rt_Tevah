extends Control
## 초상화 자리. 아트가 들어오기 전까지 실루엣 + 이름으로 대신 그린다.
## 말하는 쪽은 밝게(active), 듣는 쪽은 회색.

const ACTIVE := Color("c8b49c")
const INACTIVE := Color("5c5f66")

var _active := true
var _label: Label


func _init() -> void:
	mouse_filter = MOUSE_FILTER_IGNORE
	_label = Label.new()
	_label.set_anchors_preset(PRESET_BOTTOM_WIDE)
	_label.offset_top = -67
	_label.offset_bottom = -20
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.add_theme_font_size_override("font_size", 30)
	_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_label.add_theme_constant_override("outline_size", 10)
	add_child(_label)


func show_character(char_name: String, active: bool) -> void:
	_label.text = char_name
	_active = active
	_label.modulate = Color.WHITE if active else Color(0.6, 0.6, 0.6)
	visible = char_name != ""
	queue_redraw()


func _draw() -> void:
	var c := ACTIVE if _active else INACTIVE
	var w := size.x
	var h := size.y
	var head_r := minf(w * 0.16, h * 0.12)
	draw_circle(Vector2(w * 0.5, h * 0.08 + head_r), head_r, c)
	var body := StyleBoxFlat.new()
	body.bg_color = c
	body.corner_radius_top_left = int(w * 0.25)
	body.corner_radius_top_right = int(w * 0.25)
	body.anti_aliasing = true
	var top := h * 0.08 + head_r * 2.2
	draw_style_box(body, Rect2(w * 0.18, top, w * 0.64, h - top))
