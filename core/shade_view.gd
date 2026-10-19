@tool
extends RefCounted
## 집 입체감 (피어앤헝거식 비스듬한 탑뷰) — 칠한 타일 위에 얹는 음영. 그림이 아니라 반투명 면·선이라 어떤 타일에도 맞음.
##   RoofShade: 지붕 묶음(집 한 채) 하나. 네모 묶음이면 모임지붕 — 뒤 경사(어둡게)·양옆 경사(왼쪽 약간, 오른쪽 더 어둡게)·
##              앞 경사(밝게) + 용마루·추녀 선 + 처마 끝 선과 처마 아래 그림자. 네모가 아니면 위 줄일수록 어둡게.
##   WallShade: 맵 전체. 벽 앞면 위쪽(지붕·윗면 아래) 그늘, 앞면 양끝 모서리(왼쪽 밝게·오른쪽 어둡게), 앞면 밑동 선,
##              벽 오른쪽 바닥에 드리운 그림자 (빛은 왼쪽 위에서).


class RoofShade extends Node2D:
	var cells := {}     # Vector2i → true
	var tile := 80.0

	func _draw() -> void:
		if cells.is_empty():
			return
		var lo := Vector2i(1 << 30, 1 << 30)
		var hi := Vector2i(-(1 << 30), -(1 << 30))
		for c in cells:
			lo = Vector2i(mini(lo.x, c.x), mini(lo.y, c.y))
			hi = Vector2i(maxi(hi.x, c.x), maxi(hi.y, c.y))
		# ㄱ·ㄷ 자 지붕도: 네모 덩어리로 나눠 덩어리마다 모임지붕 (줄마다 이어진 칸 → 위아래로 같은 폭이면 합침)
		for r in rects(cells, lo, hi):
			_hip(r.position.x * tile, r.position.y * tile, r.end.x * tile, r.end.y * tile)

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

	## 모임지붕: 용마루는 위에서 38%, 양옆은 깊이의 45%(폭이 좁으면 폭의 30%)만큼 안으로
	func _hip(x0: float, y0: float, x1: float, y1: float) -> void:
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
