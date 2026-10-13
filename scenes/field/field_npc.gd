extends StaticBody2D
## 탐험 중 NPC (아트 전 placeholder: 파란 원 + 이름). 플레이어는 통과할 수 없고, 가까이서 조사 키로 대화.

var radius := 15.0
var display_name := ""


func _draw() -> void:
	draw_circle(Vector2.ZERO, radius, Color("5a8fd0"))
	draw_circle(Vector2.ZERO, radius, Color("15233a"), false, 2.0, true)
	var f := ThemeDB.fallback_font
	var w := f.get_string_size(display_name, HORIZONTAL_ALIGNMENT_LEFT, -1, 15).x
	var pos := Vector2(-w / 2.0, -radius - 8)
	draw_string_outline(f, pos, display_name, HORIZONTAL_ALIGNMENT_LEFT, -1, 15, 5, Color.BLACK)
	draw_string(f, pos, display_name, HORIZONTAL_ALIGNMENT_LEFT, -1, 15, Color("cfe0ff"))
