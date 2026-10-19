@tool
extends RefCounted
## 집 입체감 (피어앤헝거식 비스듬한 탑뷰) — 칠한 타일 위에 얹는 음영. 그림이 아니라 반투명 면·선이라 어떤 타일에도 맞음.
##   RoofShade: 지붕 묶음(집 한 채) 하나를 비스듬한 시점의 지붕으로 직접 그림 (칠한 지붕 타일의 평균 색 기와, 빛은 왼쪽 위):
##              맞배(gable) = 뒤 경사 얇게·앞 경사 크게 / 정면 박공(front) = 벽색 세모 + 양쪽 경사가 뒤로 / 모임(hip) = 앞 사다리꼴·옆 세모.
##              처마는 지붕 칸 아래 벽 위로 3px 나와 그림자를 드리움, 굴뚝 선택. flat = 예전처럼 타일 그대로 + 위에서 본 음영.
##   WallShade: 맵 전체. 벽 앞면 위쪽(지붕·윗면 아래) 그늘, 앞면 양끝 모서리(왼쪽 밝게·오른쪽 어둡게), 앞면 밑동 선,
##              벽 오른쪽 바닥에 드리운 그림자 (빛은 왼쪽 위에서).


class RoofShade extends Node2D:
	var cells := {}     # Vector2i → true
	var tile := 80.0
	var shape := ""     # "" 자동 / gable 맞배 / front 정면 박공 / hip 모임 / flat 예전 (VisualData.ROOF_SHAPES)
	var chimney := false
	var roof_color := Color(0.45, 0.35, 0.3)    # 칠한 지붕 타일의 평균 색
	var wall_color := Color(0.76, 0.72, 0.63)   # 정면 박공 세모 (지붕 바로 아래 벽 색)
	var P := 5.0        # 그림 1px 의 화면 크기 (tile / 16)

	func _draw() -> void:
		if cells.is_empty():
			return
		var lo := Vector2i(1 << 30, 1 << 30)
		var hi := Vector2i(-(1 << 30), -(1 << 30))
		for c in cells:
			lo = Vector2i(mini(lo.x, c.x), mini(lo.y, c.y))
			hi = Vector2i(maxi(hi.x, c.x), maxi(hi.y, c.y))
		# ㄱ·ㄷ 자 지붕도: 네모 덩어리로 나눠 덩어리마다 (큰 것부터). 비스듬한 그림은 뒤(위) 덩어리부터 그려 앞 덩어리가 덮게
		var rs := rects(cells, lo, hi)
		if shape == "flat":
			for r in rs:
				_hip_top(r.position.x * tile, r.position.y * tile, r.end.x * tile, r.end.y * tile)
			return
		P = tile / 16.0
		var main: Rect2i = rs[0] if not rs.is_empty() else Rect2i()
		rs.sort_custom(func(a, b): return a.position.y < b.position.y)
		for r: Rect2i in rs:
			var k := shape
			if k == "":
				k = "front" if r.size.x <= 5 and r.size.x <= r.size.y + 2 else "gable"
			var X0 := r.position.x * 16
			var X1 := r.end.x * 16
			var Y0 := r.position.y * 16
			var Y1 := r.end.y * 16
			match k:
				"front":
					_front(X0, X1, Y0, Y1, chimney and r == main)
				"hip":
					_hip(X0, X1, Y0, Y1, chimney and r == main)
				_:
					_gable(X0, X1, Y0, Y1, chimney and r == main)

	## 네모 하나 (그림 px 단위)
	func _r(x: float, y: float, w: float, h: float, c: Color) -> void:
		draw_rect(Rect2(x * P, y * P, w * P, h * P), c)

	## 볼록 다각형(그림 px)을 기와로 칠함: 3px 줄마다 아래 줄 어둡게, 6px 마다 이음, 기와마다 밝기 살짝 다르게. light = 줄(y)마다 밝기
	func _shingles(poly: PackedVector2Array, light: Callable) -> void:
		var y0 := INF
		var y1 := -INF
		for p in poly:
			y0 = minf(y0, p.y)
			y1 = maxf(y1, p.y)
		for y in range(int(floor(y0)), int(ceil(y1))):
			var span := _span(poly, y + 0.5)
			if span.x >= span.y:
				continue
			var xa := int(round(span.x))
			var xb := int(round(span.y))
			var row := floori((y - y0) / 3.0)
			var base: Color = roof_color * float(light.call(y))
			base.a = 1.0
			if (y - int(floor(y0))) % 3 == 2:
				_r(xa, y, xb - xa, 1, _k(base, 0.72))   # 줄 경계
				continue
			var off := (row % 2) * 3
			var x := xa
			while x < xb:
				var nx := mini(xb, x - posmod(x - off, 6) + 6)
				var h := absi(hash(Vector2i(x - posmod(x - off, 6), row))) % 9
				_r(x, y, nx - x, 1, _k(base, 0.94 + h * 0.015))
				if posmod(x - off, 6) == 0:
					_r(x, y, 1, 1, _k(base, 0.8))   # 이음
				x = nx

	static func _k(c: Color, f: float) -> Color:
		return Color(clampf(c.r * f, 0, 1), clampf(c.g * f, 0, 1), clampf(c.b * f, 0, 1), 1)

	## 가로줄 y 와 볼록 다각형이 겹치는 x 범위 (Vector2(xa, xb), 없으면 xa >= xb)
	static func _span(poly: PackedVector2Array, y: float) -> Vector2:
		var xa := INF
		var xb := -INF
		for i in poly.size():
			var a := poly[i]
			var b := poly[(i + 1) % poly.size()]
			if (a.y <= y and b.y > y) or (b.y <= y and a.y > y):
				var x := a.x + (y - a.y) * (b.x - a.x) / (b.y - a.y)
				xa = minf(xa, x)
				xb = maxf(xb, x)
		return Vector2(xa, xb)

	func _line(a: Vector2, b: Vector2, c: Color, w := 1.0) -> void:
		draw_line(a * P, b * P, c, w * P)

	## 지붕 바깥 테두리 (땅·벽과 구분되게, 1px 어둡게)
	func _outline(poly: PackedVector2Array) -> void:
		for i in poly.size():
			_line(poly[i], poly[(i + 1) % poly.size()], _k(roof_color, 0.4))

	## 처마 아래 벽에 드리운 그림자 (y 부터 4줄)
	func _eave_shadow(xa: float, xb: float, y: float) -> void:
		for i in 4:
			_r(xa, y + i, xb - xa, 1, Color(0, 0, 0, 0.45 - i * 0.11))

	func _chimney(x: float, base: float, h := 12.0) -> void:
		var brick := Color(0.47, 0.27, 0.22)
		_r(x, base - h, 6, h, brick)
		for yy in range(int(base - h), int(base), 3):
			_r(x, yy, 6, 1, _k(brick, 0.78))
		_r(x + 4, base - h, 2, h, _k(brick, 0.72))
		_r(x - 1, base - h - 2, 8, 2, Color(0.31, 0.3, 0.28))

	## 맞배 (용마루 가로): 뒤 경사는 위에 얇게, 앞 경사가 크게, 처마는 벽 위로 3px 나옴
	func _gable(X0: float, X1: float, Y0: float, Y1: float, chim: bool) -> void:
		var ridge := Y0 + maxf(4.0, (Y1 - Y0) * 0.22)
		var ey := Y1 + 3
		_shingles(PackedVector2Array([Vector2(X0 - 2, Y0), Vector2(X1 + 2, Y0), Vector2(X1 + 2, ridge), Vector2(X0 - 2, ridge)]), func(_y): return 0.62)
		_shingles(PackedVector2Array([Vector2(X0 - 3, ridge), Vector2(X1 + 3, ridge), Vector2(X1 + 3, ey), Vector2(X0 - 3, ey)]),
			func(y): return 1.1 - 0.28 * (y - ridge) / maxf(1.0, ey - ridge))   # 용마루 쪽이 빛을 더 받음
		_r(X0 - 2, ridge - 1, X1 - X0 + 4, 2, _k(roof_color, 1.35))   # 용마루
		_r(X0 - 3, ey - 1, X1 - X0 + 6, 1, _k(roof_color, 0.55))      # 처마 끝
		_r(X1 + 1, ridge, 2, ey - ridge, _k(roof_color, 0.6))         # 오른쪽 처마 옆면 그늘
		_r(X0 - 3, ridge, 1, ey - ridge, _k(roof_color, 1.12))        # 왼쪽 끝 빛
		_outline(PackedVector2Array([Vector2(X0 - 3, Y0), Vector2(X1 + 3, Y0), Vector2(X1 + 3, ey), Vector2(X0 - 3, ey)]))
		_eave_shadow(X0, X1, ey)
		if chim:
			_chimney(X1 - 14, ridge + 4)

	## 정면 박공 (용마루 앞뒤): 아래쪽에 벽색 세모, 양쪽 경사가 뒤(위)로 — 왼쪽 밝게·오른쪽 어둡게
	func _front(X0: float, X1: float, Y0: float, Y1: float, chim: bool) -> void:
		var cx := (X0 + X1) / 2.0
		var depth := Y1 - Y0
		var tri := minf((X1 - X0) / 2.0 - 2, depth * 0.6)
		var ay := Y1 - tri
		var D := ay - Y0
		var le := Vector2(X0 - 3, Y1 + 2)
		var re := Vector2(X1 + 3, Y1 + 2)
		var up := Vector2(0, -D)
		_shingles(PackedVector2Array([Vector2(cx, ay) + up, le + up, le, Vector2(cx, ay)]), func(_y): return 1.05)
		_shingles(PackedVector2Array([Vector2(cx, ay) + up, Vector2(cx, ay), re, re + up]), func(_y): return 0.62)
		var tri_poly := PackedVector2Array([Vector2(cx, ay + 2) * P, Vector2(X0, Y1 + 1) * P, Vector2(X1, Y1 + 1) * P])
		draw_colored_polygon(tri_poly, wall_color)                             # 박공 (벽)
		draw_colored_polygon(PackedVector2Array([Vector2(cx, ay + 2) * P, Vector2(X1, Y1 + 1) * P, Vector2(X1 - 2, Y1 + 1) * P]), _k(wall_color, 0.8))
		_line(Vector2(cx, ay), le, _k(roof_color, 0.5), 2)                     # 박공널
		_line(Vector2(cx, ay), re, _k(roof_color, 0.42), 2)
		_line(Vector2(cx, ay), Vector2(cx, ay) + up, _k(roof_color, 1.3), 2)   # 용마루 (뒤로)
		_outline(PackedVector2Array([Vector2(cx, ay) + up, le + up, le, re, re + up]))
		if chim:
			_chimney(cx + 10, Y0 + D * 0.55, 9)

	## 모임: 앞 사다리꼴, 양옆 세모, 뒤 얇게
	func _hip(X0: float, X1: float, Y0: float, Y1: float, chim: bool) -> void:
		var ridge := Y0 + maxf(4.0, (Y1 - Y0) * 0.15)
		var inset := minf((X1 - X0) * 0.25, (Y1 - Y0) * 0.6)
		var ex0 := X0 - 3
		var ex1 := X1 + 3
		var ey := Y1 + 3
		var rl := Vector2(X0 + inset, ridge)
		var rr := Vector2(X1 - inset, ridge)
		_shingles(PackedVector2Array([Vector2(ex0, Y0), Vector2(ex1, Y0), rr, rl]), func(_y): return 0.6)
		_shingles(PackedVector2Array([rl, rr, Vector2(ex1, ey), Vector2(ex0, ey)]), func(_y): return 1.0)
		_shingles(PackedVector2Array([Vector2(ex0, Y0), rl, Vector2(ex0, ey)]), func(_y): return 0.86)
		_shingles(PackedVector2Array([Vector2(ex1, Y0), Vector2(ex1, ey), rr]), func(_y): return 0.58)
		_line(rl, rr, _k(roof_color, 1.35), 2)
		for e in [[rl, Vector2(ex0, ey)], [rr, Vector2(ex1, ey)], [rl, Vector2(ex0, Y0)], [rr, Vector2(ex1, Y0)]]:
			_line(e[0], e[1], _k(roof_color, 0.5))
		_r(ex0, ey - 1, ex1 - ex0, 1, _k(roof_color, 0.5))
		_outline(PackedVector2Array([Vector2(ex0, Y0), Vector2(ex1, Y0), Vector2(ex1, ey), Vector2(ex0, ey)]))
		_eave_shadow(X0, X1, ey)
		if chim:
			_chimney(X0 + 10, ridge + 2, 10)

	## 남은 칸에서 가장 큰 네모를 차례로 떼어냄 (ㄱ자 지붕 = 큰 지붕 하나 + 날개)
	static func rects(cs: Dictionary, lo: Vector2i, hi: Vector2i) -> Array:
		var left := cs.duplicate()
		var out: Array = []
		while not left.is_empty():
			var best := Rect2i()
			var heights := {}
			for y in range(lo.y, hi.y + 1):
				for x in range(lo.x, hi.x + 1):
					heights[x] = (int(heights.get(x, 0)) + 1) if left.has(Vector2i(x, y)) else 0
				for x in range(lo.x, hi.x + 1):   # 이 줄을 밑변으로 하는 네모들 (작은 지붕이라 단순하게)
					var hmin := 1 << 30
					for x2 in range(x, hi.x + 1):
						hmin = mini(hmin, int(heights[x2]))
						if hmin == 0:
							break
						var area := hmin * (x2 - x + 1)
						if area > best.get_area():
							best = Rect2i(x, y - hmin + 1, x2 - x + 1, hmin)
			if best.get_area() == 0:
				break
			out.append(best)
			for yy in range(best.position.y, best.end.y):
				for xx in range(best.position.x, best.end.x):
					left.erase(Vector2i(xx, yy))
		return out

	## 평면(flat): 위에서 본 모임지붕 음영 — 용마루는 위에서 38%, 양옆은 깊이의 45%(폭이 좁으면 폭의 30%)만큼 안으로
	func _hip_top(x0: float, y0: float, x1: float, y1: float) -> void:
		var depth := y1 - y0
		var yr := y0 + depth * 0.38
		var inset := minf(depth * 0.45, (x1 - x0) * 0.3)
		var rl := Vector2(x0 + inset, yr)
		var rr := Vector2(x1 - inset, yr)
		draw_colored_polygon(PackedVector2Array([Vector2(x0, y0), Vector2(x1, y0), rr, rl]), Color(0, 0, 0, 0.55))      # 뒤 경사
		draw_colored_polygon(PackedVector2Array([Vector2(x0, y0), rl, Vector2(x0, y1)]), Color(0, 0, 0, 0.22))          # 왼쪽 경사
		draw_colored_polygon(PackedVector2Array([Vector2(x1, y0), Vector2(x1, y1), rr]), Color(0, 0, 0, 0.6))           # 오른쪽 경사
		draw_colored_polygon(PackedVector2Array([rl, rr, Vector2(x1, y1), Vector2(x0, y1)]), Color(1, 0.95, 0.85, 0.12)) # 앞 경사 (빛)
		var line := tile * 0.06
		draw_line(rl, rr, Color(1, 0.95, 0.85, 0.55), line * 1.5)                   # 용마루
		draw_line(Vector2(x0, y0), rl, Color(0, 0, 0, 0.5), line)                    # 추녀
		draw_line(Vector2(x1, y0), rr, Color(0, 0, 0, 0.5), line)
		draw_line(rl, Vector2(x0, y1), Color(1, 0.95, 0.85, 0.3), line)
		draw_line(rr, Vector2(x1, y1), Color(0, 0, 0, 0.6), line)
		draw_rect(Rect2(x0, y0, x1 - x0, y1 - y0), Color(0, 0, 0, 0.7), false, line)   # 지붕 테두리
		_eave(x0, x1, y1)

	## 처마 끝: 밝은 끝선 + 그 아래 벽에 드리운 그림자
	func _eave(xa: float, xb: float, y: float) -> void:
		draw_rect(Rect2(xa, y - tile * 0.09, xb - xa, tile * 0.09), Color(1, 0.95, 0.85, 0.25))   # 처마 끝 (빛 받는 모서리)
		for i in 5:
			var a := 0.6 * (1.0 - i / 5.0)
			draw_rect(Rect2(xa, y + tile * 0.07 * i, xb - xa, tile * 0.07), Color(0, 0, 0, a))


class WallShade extends Node2D:
	var faces := {}     # 벽 앞면 칸 Vector2i → true
	var walls := {}     # 벽(#) 칸
	var floors := {}    # 바닥 칸
	var roofs := {}     # 지붕 칸
	var tile := 80.0

	func _draw() -> void:
		var t := tile
		for c in faces:
			var r := Rect2(Vector2(c) * t, Vector2(t, t))
			var top := not faces.has(c + Vector2i.UP)   # 앞면 맨 위 (지붕·윗면 바로 아래) — 그늘
			if top:
				for i in 4:
					draw_rect(Rect2(r.position + Vector2(0, t * 0.08 * i), Vector2(t, t * 0.08)), Color(0, 0, 0, 0.45 * (1.0 - i / 4.0)))
			if not faces.has(c + Vector2i.LEFT):    # 앞면 왼쪽 끝 = 빛 받는 모서리
				draw_rect(Rect2(r.position, Vector2(t * 0.1, t)), Color(1, 0.95, 0.85, 0.16))
			if not faces.has(c + Vector2i.RIGHT):   # 오른쪽 끝 = 그늘진 모서리 (옆벽이 살짝 보이는 듯)
				draw_rect(Rect2(r.position + Vector2(t * 0.8, 0), Vector2(t * 0.2, t)), Color(0, 0, 0, 0.45))
			if floors.has(c + Vector2i.DOWN):      # 밑동
				draw_rect(Rect2(r.position + Vector2(0, t * 0.9), Vector2(t, t * 0.1)), Color(0, 0, 0, 0.4))
		for c in walls.keys() + roofs.keys():   # 벽·지붕(집) 오른쪽 바닥에 그림자 (오른쪽으로 갈수록 옅게)
			if floors.has(c + Vector2i.RIGHT) and not roofs.has(c + Vector2i.RIGHT):
				var p := Vector2(c + Vector2i.RIGHT) * t
				for i in 6:
					draw_rect(Rect2(p + Vector2(t * 0.1 * i, 0), Vector2(t * 0.1, t)), Color(0, 0, 0, 0.4 * (1.0 - i / 6.0)))
			if floors.has(c + Vector2i.DOWN) and not faces.has(c):   # 앞면이 없는 벽(울타리·물 등) 아래 바닥
				var q := Vector2(c + Vector2i.DOWN) * t
				draw_rect(Rect2(q, Vector2(t, t * 0.12)), Color(0, 0, 0, 0.2))
