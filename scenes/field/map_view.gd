extends Node2D
## 맵 바닥·벽 그리기 (아트 전 placeholder) + 조사 지점 표시

const FLOOR := Color("2a2d36")
const FLOOR_ALT := Color("2d3039")
const WALL := Color("12131a")
const WALL_EDGE := Color("3c3f4a")

var tiles: Array = []
var tile := 48.0
var spots: Array = []     # [{ pos: Vector2, done: bool }]


func _draw() -> void:
	for y in tiles.size():
		var row: String = tiles[y]
		for x in row.length():
			var r := Rect2(x * tile, y * tile, tile, tile)
			if row[x] == "#":
				draw_rect(r, WALL)
				draw_rect(r, WALL_EDGE, false, 1.0)
			else:
				draw_rect(r, FLOOR if (x + y) % 2 == 0 else FLOOR_ALT)
	for s in spots:
		var c: Vector2 = s.pos
		var k := tile * 0.18
		var pts := PackedVector2Array([c + Vector2(0, -k), c + Vector2(k, 0), c + Vector2(0, k), c + Vector2(-k, 0)])
		draw_colored_polygon(pts, Color("6a6a6a") if s.done else Color("e8c35a"))
