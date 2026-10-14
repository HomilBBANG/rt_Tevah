extends Button
## 선택지 버튼: "텍스트  [대가]" 표시, 조건 미충족이면 회색(비활성).
## 종류 표시: item → "[아이템]", dice → "[판정 65%] … (능력치 A +4 · 목표 12)"


func _init() -> void:
	alignment = HORIZONTAL_ALIGNMENT_LEFT
	autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	custom_minimum_size.y = 57
	add_theme_font_size_override("font_size", 28)
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
	var label: String = c.text
	match c.get("type", "normal"):
		"item":
			label = "[아이템] " + label
		"dice":
			var d: Dictionary = entry.dice
			label = "[판정 %d%%] %s   (%s %s%d · 목표 %d)" % [roundi(d.chance * 100), label,
				d.ability_name, "+" if d.mod >= 0 else "", d.mod, d.dc]
		"combat":
			label = "[전투] %s   (%s)" % [label, entry.combat.enemy_name]
	text = label if c.cost == "" else "%s  [%s]" % [label, c.cost]
	disabled = not entry.enabled


func _box(bg: Color, border: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.set_border_width_all(2)
	sb.content_margin_left = 23
	sb.content_margin_right = 23
	sb.content_margin_top = 8
	sb.content_margin_bottom = 8
	return sb
