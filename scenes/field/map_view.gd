extends Node2D
## 맵 바닥·벽 그리기 (아트 전 placeholder) + 상호작용 지점 표시
##   조사(spot): 노란 마름모 (조사하면 회색) / 거점(camp): 초록 천막 / 출구(exit): 닫힌 문은 갈색, 열린 문은 어두운 틈
##   빈 공간(' ')과 맵 바깥은 검은색

const FLOOR := Color("2a2d36")
const FLOOR_ALT := Color("2d3039")
const WALL := Color("12131a")
const WALL_EDGE := Color("3c3f4a")

var tiles: Array = []
var tile := 48.0
var spots: Array = []     # [{ kind, pos: Vector2, done: bool }]


func _draw() -> void:
	# 맵 바깥도 검게 (카메라가 맵 가장자리보다 조금 더 보여 줌)
	var w := 0
	for r in tiles:
		w = maxi(w, String(r).length())
	draw_rect(Rect2(Vector2(-4000, -4000), Vector2(w * tile + 8000, tiles.size() * tile + 8000)), Color.BLACK)
	for y in tiles.size():
		var row: String = tiles[y]
		for x in row.length():
			var r := Rect2(x * tile, y * tile, tile, tile)
			if row[x] == " ":
				continue   # 빈 공간: 검은 배경 그대로
			elif row[x] == "#":
				draw_rect(r, WALL)
				draw_rect(r, WALL_EDGE, false, 2.0)
			else:
				draw_rect(r, FLOOR if (x + y) % 2 == 0 else FLOOR_ALT)
	for s in spots:
		var c: Vector2 = s.pos
		match s.kind:
			"camp":
				var k := tile * 0.36
				draw_colored_polygon(PackedVector2Array([c + Vector2(0, -k), c + Vector2(k, k * 0.8), c + Vector2(-k, k * 0.8)]), Color("5fae6a"))
				draw_line(c + Vector2(0, -k), c + Vector2(0, k * 0.8), Color("2c5a33"), 3.0)
			"exit":
				var door := Rect2(c - Vector2(tile * 0.42, tile * 0.46), Vector2(tile * 0.84, tile * 0.92))
				if s.get("open", false):
					draw_rect(door, Color("0b0b0e"))
					draw_rect(door, Color("8a6a44"), false, 4.0)
				else:
					draw_rect(door, Color("8a6a44"))
					draw_circle(c + Vector2(tile * 0.24, 0), 5.0, Color("e8d0a0"))
			_:
				var k := tile * 0.18
				var pts := PackedVector2Array([c + Vector2(0, -k), c + Vector2(k, 0), c + Vector2(0, k), c + Vector2(-k, 0)])
				draw_colored_polygon(pts, Color("6a6a6a") if s.done else Color("e8c35a"))
