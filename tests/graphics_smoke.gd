extends Node
## 그래픽 스모크 (창 필요): 픽셀아트 타일·시간대 환경광·광원·벽/문 그림자·실내/지하 (기획 pixelart_2d_lighting T03~T14).
## 테스트 전용 맵을 DataLoader 에 넣어서 쓴다. 스크린샷 user://graphics_smoke/.
##   Godot_v4.7-stable_win64_console.exe --path . res://tests/graphics_smoke.tscn

const FieldScript = preload("res://scenes/field/field.gd")
const VisualData = preload("res://core/visual_data.gd")

var _fail := 0


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute("user://graphics_smoke")
	SaveManager.save_dir = "user://test_saves/"
	SaveManager.delete_all()
	SaveManager.begin_run()
	# ---- 데이터 규칙 (그림 없는 칸 = 기본 타일, 시간대 섞기)
	var m := _map("outdoor")
	check(VisualData.cell_keys(m, 1, 1).floor == "floor_grass" and VisualData.cell_keys(m, 2, 2).floor == "floor_default"
		and VisualData.cell_keys(m, 0, 0).wall == "wall_default" and VisualData.cell_keys(m, 3, 1).detail == "decal_blood",
		"칸 그림: 칠한 타일 / 안 칠한 바닥·벽 = 기본 타일 / 장식 층")
	check(VisualData.cell_keys(m, 13, 3).floor == "" and VisualData.cell_keys(m, 13, 3).wall == "", "빈 공간(공백) = 그림 없음")
	m.visual.layers.floor["2,2"] = "no_such_tile"
	check(VisualData.cell_keys(m, 2, 2).floor == "floor_default", "없는 타일 이름 → 기본 타일 (맵은 그대로)")
	var noon := VisualData.ambient("outdoor", 12 * 60)
	var night := VisualData.ambient("outdoor", 0)
	var dusk := VisualData.ambient("outdoor", 18 * 60 + 45)
	check(noon.ambient.v > 0.95 and night.ambient.v < 0.4 and dusk.ambient.v < noon.ambient.v and dusk.ambient.v > night.ambient.v,
		"시간대: 정오 밝음 / 밤 어두움 / 저녁은 그 사이 (%.2f / %.2f / %.2f)" % [noon.ambient.v, night.ambient.v, dusk.ambient.v])
	check(VisualData.ambient("indoor", 0).ambient == VisualData.ambient("indoor", 720).ambient, "실내: 시간과 상관없이 같은 주변광")
	# ---- 필드: 밤 + 광원 + 벽·문 그림자
	DataLoader.maps["tgfx"] = _map("outdoor")
	GameState.clock = 23 * 60.0
	FieldScript.next_map_id = "tgfx"
	var f: Node = load("res://scenes/field/field.tscn").instantiate()
	add_child(f)
	await _wait(0.3)
	var r: Node2D = f.renderer
	check(r != null and r.layers.floor.get_used_cells().size() > 0 and r.layers.wall.get_used_cells().size() > 0, "픽셀아트 바닥·벽 층")
	check(r.layers.floor.texture_filter == CanvasItem.TEXTURE_FILTER_NEAREST and is_equal_approx(r.layers.floor.scale.x, 5.0), "흐림 없이(nearest) 5배")
	check(r.lights.size() == 1 and r.lights[0].shadow_enabled and r.occluder_count > 0 and r.doors.has("tg_door"), "광원 1개 (그림자), 벽 그림자, 문 그림자")
	check(r._modulate.color.v < 0.4, "밤(23시) 환경광 어두움")
	f.player.position = f._tile_center(2, 4)
	await _snap("01_night_light_closed_door")
	var door: Dictionary = f.spots.filter(func(s): return s.kind == "exit")[0]
	check(r.doors.tg_door.visible, "닫힌 문은 빛을 막음")
	f.player.position = f._tile_center(2, 2)
	f.toggle_door(door)
	await _wait(0.1)
	check(door.open and not r.doors.tg_door.visible and door.body.collision_layer == 0, "문을 열면 빛이 지나감 (통과도 기존대로)")
	await _snap("02_door_open")
	# 시계가 멈추면 빛도 멈춤 / 시간이 뛰면 바로
	var before: Color = r._modulate.color
	f.frozen = true
	await _wait(0.5)
	check(r._modulate.color == before, "시간이 멈추면(대화·메뉴) 빛도 그대로")
	f.frozen = false
	GameState.advance_time(12 * 60.0)   # 잠으로 시간이 뛴 것처럼
	await _wait(0.1)
	check(r._modulate.color.v > 0.9, "시간이 뛰면(잠) 새 시각의 밝기로 바로 (%.2f)" % r._modulate.color.v)
	await _snap("03_day")
	# ---- 실내 / 지하
	for prof in ["indoor", "underground"]:
		DataLoader.maps["tgfx"] = _map(prof)
		f.load_map("tgfx")
		await _wait(0.2)
		check(f.renderer.profile() == prof and not f.renderer._sun.enabled, "%s: 햇빛 없음, 프로필 적용" % prof)
		await _snap("04_" + prof)
	# ---- 성능 (T18): 광원 20개(그림자) 켜기 / 조명 끄기 — 실측만 보고 (목표값은 기기 확인 뒤)
	var many := _map("outdoor")
	for i in 20:
		many.objects.append({"object_id": "tg_l%d" % i, "type": "light", "x": 1 + i % 11, "y": 1 + (i / 11) * 3, "color": "#FFD4A0",
			"energy": 1.0, "radius": 4.0, "shadow": true, "enabled": true})
	DataLoader.maps["tgfx"] = many
	GameState.clock = 23 * 60.0
	f.load_map("tgfx")
	var fps_on := await _fps()
	f.renderer.set_lighting(false)
	var fps_off := await _fps()
	print("[성능] 광원 %d개 + 벽 그림자 %d조각: %.0f FPS / 조명 끔: %.0f FPS" % [f.renderer.lights.size(), f.renderer.occluder_count, fps_on, fps_off])
	check(fps_on > 0, "성능 측정 (광원 켬 %.0f / 끔 %.0f FPS)" % [fps_on, fps_off])
	f.queue_free()
	DataLoader.maps.erase("tgfx")
	SaveManager.delete_all()
	print("[graphics_smoke] 실패 %d" % _fail)
	get_tree().quit(1 if _fail > 0 else 0)


## 테스트 맵 14x7: 가운데 벽(x=7)에 문, 왼쪽 방에 광원, 잔디·핏자국 칠함, 오른쪽 끝은 빈 공간
func _map(profile: String) -> Dictionary:
	var tiles := ["##############", "#......#....# ", "#......#....# ", "#............ ", "#......#....# ", "#......#....# ", "##############"]
	var obj := func(id: String, type: String, x: int, y: int, extra := {}) -> Dictionary:
		var o := {"object_id": id, "type": type, "ref": "", "name": id, "text": "", "condition": "", "arrive": "", "from": [],
			"default": false, "once": false, "map_id": "tgfx", "x": x, "y": y, "patrol_dir": "", "patrol_len": 0, "schedule": []}
		o.merge(extra, true)
		return o
	return {"map_id": "tgfx", "width": 14, "height": 7, "tiles": tiles, "start": [2, 4], "run_start": [2, 4], "edges": {},
		"objects": [obj.call("tg_door", "exit", 7, 3, {"ref": "basecamp"}),
			obj.call("tg_lamp", "light", 4, 2, {"preset": "warm_bulb", "color": "#FFD4A0", "energy": 1.2, "radius": 5.0, "shadow": true, "enabled": true})],
		"visual": {"layers": {"floor": {"1,1": "floor_grass", "2,1": "floor_grass", "9,2": "floor_wood"}, "detail": {"3,1": "decal_blood"}}},
		"environment": {"profile": profile}}


## 1.5초 동안 평균 FPS (vsync 가 켜져 있으면 화면 주사율에서 멈춤)
func _fps() -> float:
	await _wait(0.5)
	var frames := 0
	var t0 := Time.get_ticks_usec()
	while Time.get_ticks_usec() - t0 < 1500000:
		await get_tree().process_frame
		frames += 1
	return frames / ((Time.get_ticks_usec() - t0) / 1e6)


func _wait(sec: float) -> void:
	await get_tree().create_timer(sec).timeout


func _snap(name: String) -> void:
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("user://graphics_smoke/%s.png" % name)


func check(ok: bool, label: String) -> void:
	print(("ok   " if ok else "FAIL ") + label)
	if not ok:
		_fail += 1
