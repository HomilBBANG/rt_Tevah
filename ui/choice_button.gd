extends Button
## 선택지 버튼: "텍스트  [대가]" 표시, 조건 미충족이면 회색(비활성).


func setup(entry: Dictionary) -> void:
	var c: Dictionary = entry.choice
	text = c.text if c.cost == "" else "%s  [%s]" % [c.text, c.cost]
	disabled = not entry.enabled
	alignment = HORIZONTAL_ALIGNMENT_LEFT
	autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	custom_minimum_size.y = 40
