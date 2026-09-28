extends Button
## 선택지 버튼: "텍스트  [대가]" 표시, 조건 미충족이면 회색(비활성).


func _init() -> void:
	alignment = HORIZONTAL_ALIGNMENT_LEFT
	autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	custom_minimum_size.y = 34
	add_theme_font_size_override("font_size", 17)
	add_theme_color_override("font_color", Color("eeeeee"))
	add_theme_color_override("font_hover_color", Color.WHITE)
	add_theme_color_override("font_focus_color", Color.WHITE)
	add_theme_color_override("font_pressed_color", Color.WHITE)
	add_theme_color_override("font_disabled_color", Color("777777"))
	add_theme_stylebox_override("normal", _box(Color(0, 0, 0, 0.72), Color("555555")))
	add_theme_stylebox_override("hover", _box(Color(0.12, 0.12, 0.12, 0.88), Color("dddddd")))
	add_theme_stylebox_override("pressed", _box(Color(0.2, 0.2, 0.2, 0.9), Color("ffffff")))
	add_theme_stylebox_override("focus", _box(Color(0, 0, 0, 0), Color("dddddd")))
	add_theme_stylebox_override("disabled", _box(Color(0, 0, 0, 0.45), Color("333333")))


func setup(entry: Dictionary) -> void:
	var c: Dictionary = entry.choice
	text = c.text if c.cost == "" else "%s  [%s]" % [c.text, c.cost]
	disabled = not entry.enabled


func _box(bg: Color, border: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.set_border_width_all(1)
	sb.content_margin_left = 14
	sb.content_margin_right = 14
	sb.content_margin_top = 5
	sb.content_margin_bottom = 5
	return sb
