@tool
extends RefCounted
## 집 입체감 (피어앤헝거식 비스듬한 탑뷰) — 칠한 벽 위에 얹는 음영 (지붕은 칠한 타일 그대로). 그림이 아니라 반투명 면·선이라 어떤 타일에도 맞음.
##   WallShade: 맵 전체. 벽 앞면 위쪽(지붕·윗면 아래) 그늘, 앞면 양끝 모서리(왼쪽 밝게·오른쪽 어둡게), 앞면 밑동 선,
##              벽 오른쪽 바닥에 드리운 그림자 (빛은 왼쪽 위에서).


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
