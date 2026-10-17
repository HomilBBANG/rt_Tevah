"""마을 구역 맵 도면(300 x 188) → tools/maps/new_america.json
좌표는 도면 그림에서 잰 값 (그림 x → 칸 = (px-38)*300/1184, y → 칸 = (py-128)*188/678).
논리: '#' = 숲·건물·울타리·물 (못 지나감), '.' = 풀밭·길.
그림: 기본 바닥 = 풀(floor_grass), 기본 벽 = 숲(forest). 길·흙길·건물 벽·울타리·물·지붕만 칠함."""
import json, math, random

W, H = 300, 188
random.seed(20261017)
grid = [["#"] * W for _ in range(H)]
floor, wall, roof = {}, {}, {}
objs = []


def inside(x, y):
    return 0 <= x < W and 0 <= y < H


def noise(x, y):
    h = (x * 73856093) ^ (y * 19349663) ^ 0x5bd1e995
    return (h % 1000) / 1000.0


def open_cell(x, y):
    if inside(x, y):
        grid[y][x] = "."


def seg_dist(px, py, ax, ay, bx, by):
    dx, dy = bx - ax, by - ay
    t = 0.0 if dx == dy == 0 else max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy)))
    return math.hypot(px - (ax + t * dx), py - (ay + t * dy))


def polyline(pts, width, key, margin=3):
    xs = [p[0] for p in pts]; ys = [p[1] for p in pts]
    for y in range(max(0, min(ys) - width - margin), min(H, max(ys) + width + margin + 1)):
        for x in range(max(0, min(xs) - width - margin), min(W, max(xs) + width + margin + 1)):
            d = min(seg_dist(x, y, *pts[i], *pts[i + 1]) for i in range(len(pts) - 1))
            if d <= width / 2.0 + margin + noise(x, y) * 2:
                open_cell(x, y)          # 길 옆 풀밭 (숲 가장자리는 들쭉날쭉)
            if d <= width / 2.0:
                floor[f"{x},{y}"] = key


def clearing(x0, y0, x1, y1):
    for y in range(y0, y1 + 1):
        for x in range(x0, x1 + 1):
            edge = min(x - x0, x1 - x, y - y0, y1 - y)
            if edge >= 3 or noise(x, y) < 0.35 + edge * 0.2:
                open_cell(x, y)


def ellipse(cx, cy, rx, ry, fn):
    for y in range(int(cy - ry) - 1, int(cy + ry) + 2):
        for x in range(int(cx - rx) - 1, int(cx + rx) + 2):
            if inside(x, y) and ((x - cx) / rx) ** 2 + ((y - cy) / ry) ** 2 <= 1.0:
                fn(x, y)


# ---- 빈터 (마을·연못가)
clearing(26, 70, 200, 174)
clearing(150, 58, 205, 102)
clearing(198, 98, 286, 180)
ellipse(227, 41, 36, 25, open_cell)

# ---- 길 (돌길 floor_default, 흙길 floor_dirt)
ROAD, DIRT = "floor_default", "floor_dirt"
polyline([(0, 45), (40, 46), (80, 46), (117, 48), (142, 57), (158, 75), (168, 90), (175, 98)], 6, ROAD)       # 서쪽 도로 (외부로 연결)
polyline([(172, 0), (168, 20), (166, 40), (168, 60), (171, 80), (175, 98)], 6, ROAD)                           # 북쪽 길
polyline([(175, 98), (193, 104), (218, 103), (244, 95), (270, 89), (299, 86)], 6, ROAD)                        # 교회 방향 (동쪽)
polyline([(232, 100), (245, 110), (256, 121), (275, 132), (299, 142)], 5, ROAD)                                # 남동쪽 길
polyline([(178, 100), (181, 130), (183, 160), (184, 176)], 4, DIRT)                                           # 남쪽 흙길
polyline([(170, 108), (150, 116), (130, 122), (110, 127), (90, 130), (70, 130), (50, 127), (36, 124)], 4, DIRT)  # 집들 앞 흙길
polyline([(212, 106), (212, 146), (224, 146)], 3, DIRT)        # 창고 H 앞
polyline([(256, 122), (252, 140), (261, 170)], 3, DIRT)        # 창고 I 앞

# ---- 연못 (물 = 못 지나감)
def water(x, y):
    grid[y][x] = "#"
    wall[f"{x},{y}"] = "water"
    floor.pop(f"{x},{y}", None)
ellipse(228, 41, 15, 11, water)

# ---- 울타리 (마당, 문 = 틈)
def fence_rect(x0, y0, x1, y1, gaps):
    for x in range(x0, x1 + 1):
        for y in (y0, y1):
            if not any(gy == y and gx0 <= x <= gx1 for gy, gx0, gx1 in gaps):
                grid[y][x] = "#"; wall[f"{x},{y}"] = "fence_wood"; floor.pop(f"{x},{y}", None)
    for y in range(y0, y1 + 1):
        for x in (x0, x1):
            if not any(gy == y and gx0 <= x <= gx1 for gy, gx0, gx1 in gaps):
                grid[y][x] = "#"; wall[f"{x},{y}"] = "fence_wood"; floor.pop(f"{x},{y}", None)
    for y in range(y0 + 1, y1):           # 마당 안은 풀밭
        for x in range(x0 + 1, x1):
            grid[y][x] = "."

fence_rect(34, 74, 70, 103, [(103, 50, 53)])      # 집 A 마당 (아래 문)
fence_rect(95, 85, 124, 111, [(111, 108, 111)])   # 집 C
fence_rect(79, 136, 104, 158, [(136, 90, 93)])    # 집 D (위 문 — 흙길 쪽)
fence_rect(113, 138, 140, 160, [(138, 125, 128)]) # 집 E
fence_rect(151, 145, 178, 168, [(145, 163, 166)]) # 점포 F

# ---- 밭 (흙)
for x0, y0, x1, y1 in [(36, 108, 56, 122), (65, 80, 69, 95), (186, 150, 200, 164)]:
    for y in range(y0, y1 + 1):
        for x in range(x0, x1 + 1):
            if grid[y][x] == ".":
                floor[f"{x},{y}"] = DIRT

# ---- 건물: 바닥 칸 전부 막힘, 아래 3줄 = 앞벽(나무 벽), 나머지 = 지붕. 내부는 별도 인테리어 맵 (도면 설계 포인트)
BUILDINGS = [("집 A", 40, 80, 24, 18, "roof_red"), ("집 B", 64, 108, 18, 14, "roof_slate"), ("집 C", 100, 90, 20, 16, "roof_slate"),
             ("집 D", 84, 140, 16, 14, "roof_red"), ("집 E", 118, 142, 18, 14, "roof_brown"), ("점 F", 156, 150, 18, 14, "roof_green"),
             ("창고", 161, 121, 10, 10, "roof_brown"), ("창고 H", 218, 114, 14, 26, "roof_slate"), ("창고 I", 255, 145, 14, 20, "roof_red")]
footprints = set()
for name, bx, by, bw, bh, rk in BUILDINGS:
    for y in range(by, by + bh):
        for x in range(bx, bx + bw):
            grid[y][x] = "#"
            floor.pop(f"{x},{y}", None)
            footprints.add((x, y))
            if y >= by + bh - 2:   # 앞벽 2줄 (나무 벽 face_rows 2)
                wall[f"{x},{y}"] = "wall_wood"
            else:
                wall[f"{x},{y}"] = "wall_wood"
                roof[f"{x},{y}"] = rk
    # 앞 마당 흙 (문 앞)
    for y in range(by + bh, by + bh + 2):
        for x in range(bx + bw // 2 - 2, bx + bw // 2 + 2):
            if inside(x, y) and grid[y][x] == ".":
                floor[f"{x},{y}"] = DIRT


def obj(oid, typ, x, y, **kw):
    o = {"object_id": oid, "type": typ, "x": x, "y": y, "ref": "", "name": "", "text": "", "patrol_dir": "", "patrol_len": 0,
         "condition": "", "schedule": ""}
    o.update(kw)
    objs.append(o)


occupied = set()

# ---- 나무 (빈터의 풀밭에 듬성듬성, 길·흙·건물 근처 피함)
def free_for_tree(x, y):
    if not inside(x, y) or grid[y][x] != "." or f"{x},{y}" in floor or (x, y) in occupied:
        return False
    for dy in range(-2, 3):
        for dx in range(-2, 3):
            if (x + dx, y + dy) in footprints or (x + dx, y + dy) in occupied or f"{x+dx},{y+dy}" in floor:
                return False
    return True

n = 0
tries = 0
while n < 230 and tries < 40000:
    tries += 1
    x, y = random.randrange(28, 286), random.randrange(56, 178)
    if free_for_tree(x, y):
        n += 1
        obj(f"na_tree{n}", "prop", x, y, ref="tree", name="나무")
        occupied.add((x, y))

# ---- 전봇대·가로등 (길가)
lamp = {"preset": "street_lamp", "color": "#FFE0B0", "energy": 1.2, "radius": 6.0, "shadow": True, "enabled": True}
for i, (x, y) in enumerate([(179, 93), (150, 61), (120, 52), (205, 99), (246, 102), (60, 133), (140, 127)]):
    while grid[y][x] != "." or f"{x},{y}" in floor or (x, y) in occupied:
        y += 1
    obj(f"na_lamp{i+1}", "prop", x, y, ref="lamp_post", name="가로등")
    occupied.add((x, y))
    lx, ly = x + 1, y
    while grid[ly][lx] != "." or (lx, ly) in occupied:
        lx += 1
    obj(f"na_light{i+1}", "light", lx, ly, name="가로등 불빛", **lamp)
    occupied.add((lx, ly))

# ---- 도착 P (서쪽 도로 = 기본, 교회 방향)
obj("na_west", "arrive", 2, 45, name="서쪽 도로 (외부로 연결)", arrive="", default=True)
obj("na_east", "arrive", 297, 86, name="교회 방향 (동쪽)", arrive="")
for o in objs:
    assert grid[o["y"]][o["x"]] == ".", o
    if o["type"] != "light":
        pass

tiles = ["".join(r) for r in grid]
m = {"map_id": "new_america", "tiles": tiles, "start": [2, 45], "run_start": None, "objects": objs,
     "visual": {"layers": {"floor": floor, "wall": wall, "roof": roof}, "default_floor": "floor_grass", "default_wall": "forest"},
     "environment": {"profile": "outdoor"}}
open("tools/maps/new_america.json", "w", encoding="utf-8", newline="\n").write(json.dumps(m, ensure_ascii=False, separators=(",", ":")) + "\n")
print("open", sum(r.count(".") for r in tiles), "trees", n, "floor", len(floor), "wall", len(wall), "roof", len(roof))
