extends Node2D
## 맵 바닥·벽 그리기 (아트 전 placeholder) + 상호작용 지점 표시
##   조사(spot): 노란 마름모 (조사하면 회색) / 거점(camp): 초록 천막 / 출구(exit): 갈색 문

const FLOOR := Color("2a2d36")
const FLOOR_ALT := Color("2d3039")
const WALL := Color("12131a")
const WALL_EDGE := Color("3c3f4a")

var tiles: Array = []
var tile := 48.0
var spots: Array = []     # [{ kind, pos: Vector2, done: bool }]


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
		match s.kind:
			"camp":
				var k := tile * 0.36
				draw_colored_polygon(PackedVector2Array([c + Vector2(0, -k), c + Vector2(k, k * 0.8), c + Vector2(-k, k * 0.8)]), Color("5fae6a"))
				draw_line(c + Vector2(0, -k), c + Vector2(0, k * 0.8), Color("2c5a33"), 2.0)
			"exit":
				draw_rect(Rect2(c - Vector2(tile * 0.3, tile * 0.42), Vector2(tile * 0.6, tile * 0.84)), Color("8a6a44"))
				draw_circle(c + Vector2(tile * 0.16, 0), 3.0, Color("e8d0a0"))
			_:
				var k := tile * 0.18
				var pts := PackedVector2Array([c + Vector2(0, -k), c + Vector2(k, 0), c + Vector2(0, k), c + Vector2(-k, 0)])
				draw_colored_polygon(pts, Color("6a6a6a") if s.done else Color("e8c35a"))
