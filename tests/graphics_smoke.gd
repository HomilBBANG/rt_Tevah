extends Node
## 그래픽 스모크 (창 필요): 픽셀아트 타일·시간대 환경광·광원·벽/문 그림자·실내/지하 (기획 pixelart_2d_lighting T03~T14).
## 테스트 전용 맵을 DataLoader 에 넣어서 쓴다. 스크린샷 user://graphics_smoke/.
##   Godot_v4.7-stable_win64_console.exe --path . res://tests/graphics_smoke.tscn

const FieldScript = preload("res://scenes/field/field.gd")
const VisualData = preload("res://core/visual_data.gd")
const MapRendererScript = preload("res://core/map_renderer.gd")

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
	var dmode := func(rows: Array) -> String: return VisualData.door_mode({"tiles": rows}, {"x": 1, "y": 1})
	check(dmode.call(["###", "#.#", "..."]) == "face" and dmode.call(["...", "#.#", "..."]) == "face_short"
		and dmode.call(["###", "...", "###"]) == "side" and dmode.call(["...", "#.#"]) == "bottom",
		"문이 달린 벽: 뒷벽 = 정면(키 큰 문) / 1칸 가로벽 = 1칸 문 / 옆벽 = 세로 문짝 / 맨 아랫벽 = 아래쪽 문")
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
	# ---- 오브젝트 그림 (Y 정렬·막힘·그림자)
	check(r.prop_sprites.size() == 2 and r.prop_sprites.all(func(sp): return sp.get_parent() == f.get_node("%World"))
		and f.get_node("%World").y_sort_enabled, "오브젝트 그림 2개가 인물과 같은 Y 정렬 노드에")
	var tree: Sprite2D = r.prop_sprites.filter(func(sp): return sp.get_meta("object_id") == "tg_tree")[0]
	f.player.position = f._tile_center(3, 5)   # 나무 아래 칸 → 플레이어가 앞
	check(f.player.position.y > tree.position.y, "나무 아래 칸의 플레이어가 그림 앞 (발 %.0f > %.0f)" % [f.player.position.y, tree.position.y])
	var space: PhysicsDirectSpaceState2D = f.get_world_2d().direct_space_state
	var qp := PhysicsPointQueryParameters2D.new()
	qp.position = f._tile_center(3, 4)
	qp.collision_mask = 1
	check(not space.intersect_point(qp).is_empty(), "지나갈 수 없는 오브젝트(나무) 칸 = 벽 충돌 (적 시야도 막음)")
	check(VisualData.solid_cells(f.map).size() == 3, "탁자 2칸 + 나무 1칸 막힘")
	check(r.occluder_count >= 3, "나무가 빛을 막는 그림자 조각에 들어감")
	# ---- 손전등: 손에 들면 원뿔 빛이 따라다니며 바라보는 쪽을 비춤
	GameState.add_item("flashlight", 1)
	var fi := GameState.inventory.find_custom(func(sl): return sl.id == "flashlight")
	check(GameState.equip(fi) == "" and f.held_light != null and f.held_light.get_parent() == f.player, "손전등을 손에 들면 플레이어가 빛을 들고 다님")
	f.player.facing = Vector2.RIGHT
	await _wait(0.1)
	check(is_equal_approx(f.held_light.rotation, 0.0) and f.held_light.texture == MapRendererScript.cone_texture(), "원뿔 빛, 오른쪽을 봄")
	f.player.facing = Vector2.UP
	await _wait(0.1)
	check(is_equal_approx(f.held_light.rotation, -PI / 2), "위를 보면 빛도 위로")
	f.player.position = f._tile_center(2, 4)
	f.player.facing = Vector2.RIGHT
	await _wait(0.1)
	await _snap("01b_props_flashlight")
	var hand: String = GameState.equipment.keys().filter(func(k): return GameState.equipment[k] == "flashlight")[0]
	GameState.unequip(hand)
	await _wait(0.05)
	check(f.held_light == null, "손에서 내려놓으면 빛 없음")
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
	f.renderer.set_lighting(true)

	# ---- 지붕: 도시 맵 — 밖에서는 집 안이 지붕에 가려 안 보이고, 들어간 집만 지붕이 사라짐
	GameState.clock = 12 * 60.0
	f.load_map("city")
	await _wait(0.3)
	var rr: Node2D = f.renderer
	check(rr.roof_regions.size() == 9, "지붕 묶음 = 건물 9채 (%d)" % rr.roof_regions.size())
	var house: int = rr.roof_region_at(Vector2i(6, 4))
	var other: int = rr.roof_region_at(Vector2i(36, 4))
	check(house >= 0 and other >= 0 and house != other and rr.roof_region_at(Vector2i(14, 10)) == -1, "칸마다 어느 집 지붕인지 (길은 지붕 없음)")
	check(rr.roof_regions.all(func(r): return is_equal_approx(r.layer.modulate.a, 1.0)), "밖에 있으면 모든 지붕이 덮음")
	check(rr.get_node("Roofs").z_index > 0, "지붕은 인물보다 위 (z %d)" % rr.get_node("Roofs").z_index)
	f.player.position = f._tile_center(6, 9)
	await _wait(0.3)
	await _snap("roof_outside")
	f.player.position = f._tile_center(6, 4)   # 집 안 (입구 6,7)
	await _wait(0.5)
	check(rr.roof_regions[house].layer.modulate.a < 0.05 and is_equal_approx(rr.roof_regions[other].layer.modulate.a, 1.0), "집 안에 들어가면 그 집 지붕만 사라짐")
	await _snap("roof_inside")
	f.player.position = f._tile_center(6, 9)
	await _wait(0.5)
	check(is_equal_approx(rr.roof_regions[house].layer.modulate.a, 1.0), "나오면 다시 덮음")

	# ---- 문·조사 반짝이 그림 (Tiles layer door / marker)
	GameState.clock = 23 * 60.0
	f.load_map("test_field")
	await _wait(0.2)
	var mk: Dictionary = f.renderer.markers
	var dmk: Dictionary = mk.get("fo_to_camp", {})
	var sp: Dictionary = mk.get("fo_look1", {})
	check(dmk.get("kind") == "door" and sp.get("kind") == "spark" and sp.frames == 4, "문(exit)은 문 그림, 조사 지점은 반짝이 (4장)")
	check(f.get_node("%MapView").art_ids.has("fo_to_camp") and f.get_node("%MapView").art_ids.has("fo_look1"), "그림이 있으면 예전 도형은 안 그림")
	check(sp.sprite.material is CanvasItemMaterial and sp.sprite.material.light_mode == CanvasItemMaterial.LIGHT_MODE_UNSHADED, "반짝이는 어두워도 보임 (빛 영향 없음)")
	var x0: float = sp.sprite.texture.region.position.x
	var changed := false
	for i in 8:
		await _wait(0.05)
		if sp.sprite.texture.region.position.x != x0:
			changed = true
	check(changed, "반짝이 애니메이션")
	var closed_x: float = dmk.sprite.texture.region.position.x
	var ds: Dictionary = f.spots.filter(func(x): return x.data.object_id == "fo_to_camp")[0]
	f.player.position = ds.pos + Vector2(f.tile, 0)
	f.toggle_door(ds)
	check(dmk.sprite.texture.region.position.x != closed_x, "문을 열면 열린 그림")
	f.player.position = f._tile_center(7, 6)
	await _wait(0.2)
	await _snap("door_and_sparkle_night")
	f.toggle_door(ds)
	check(dmk.sprite.texture.region.position.x == closed_x, "닫으면 닫힌 그림")
	var spot: Dictionary = f.spots.filter(func(x): return x.data.object_id == "fo_look1")[0]
	f._investigate(spot)
	await _wait(0.1)
	check(not sp.sprite.visible, "조사하면 반짝이가 사라짐")
	f.queue_free()
	await _wait(0.1)
	# ---- 창문: 실내 맵에서도 낮이면 햇빛, 밤엔 꺼짐, 커튼을 치면 막힘 (회차 상태에 남음)
	var wm := _map("indoor")
	wm.map_id = "twin"
	wm.objects = wm.objects.filter(func(o): return o.type != "light")
	wm.objects.append({"object_id": "tw_win", "type": "window", "ref": "", "name": "창문", "text": "", "condition": "", "arrive": "", "from": [],
		"default": false, "once": false, "map_id": "twin", "x": 3, "y": 0, "patrol_dir": "", "patrol_len": 0, "schedule": [], "look": "", "curtain": false})
	DataLoader.maps["twin"] = wm
	GameState.clock = 12 * 60.0
	FieldScript.next_map_id = "twin"
	var wf: Node = load("res://scenes/field/field.tscn").instantiate()
	add_child(wf)
	await _wait(0.3)
	var wr: Node2D = wf.renderer
	check(wr.windows.has("tw_win") and wr.windows.tw_win.light.enabled and wr.windows.tw_win.light.energy > 0.5
		and is_equal_approx(wr.windows.tw_win.light.rotation, PI / 2), "창문: 실내 맵 정오에 아래(바닥 쪽)로 햇빛")
	check(wr.markers.has("tw_win") and wr.markers.tw_win.has("view") and wr.markers.tw_win.view.mode == "face"
		and wr.markers.tw_win.view._glass.material != null, "기본 창문 그림 (벽면 창, 낮이라 유리가 밝음)")
	wf.player.position = wf._tile_center(3, 2)
	await _snap("window_noon")
	var ws: Dictionary = wf.spots.filter(func(x): return x.kind == "window")[0]
	wf.player.position = wf._tile_center(3, 1)
	await _wait(0.1)
	check(wf._near_spot == ws and "커튼 치기" in wf.get_node("%Prompt").text, "창문 옆에서 '커튼 치기' 안내")
	wf.interact()
	check(ws.curtain and not wr.windows.tw_win.light.enabled and wr.markers.tw_win.view.curtain and wr.markers.tw_win.view._glass.material == null
		and GameState.field_has("twin", "curtain", "tw_win"), "커튼을 치면 빛이 막히고 커튼 그림, 회차 상태에 기록")
	await _wait(0.1)
	check("커튼 걷기" in wf.get_node("%Prompt").text, "커튼을 친 뒤 안내는 '커튼 걷기'")
	await _snap("window_curtain")
	wf.toggle_curtain(ws)
	check(wr.windows.tw_win.light.enabled and not GameState.field_has("twin", "curtain", "tw_win"), "커튼 걷기 → 다시 햇빛")
	wr.set_time(0)
	check(not wr.windows.tw_win.light.enabled, "밤엔 창문 빛 없음")
	wf.queue_free()
	await _wait(0.1)
	# ---- 뒷벽 창문 (비스듬한 탑뷰): 2×2 창문 아래로 벽 한 줄 더, 그 밑이 바닥 → 빛은 바닥 가장자리에서 아래로
	var bm := _map("indoor")
	bm.map_id = "tback"
	bm.tiles = ["##############", "##############", "##############", "#......#....# ", "#......#....# ", "#............ ", "##############"]
	bm.objects = [{"object_id": "tb_win", "type": "window", "ref": "", "name": "높은 창", "text": "", "condition": "", "arrive": "", "from": [],
		"default": false, "once": false, "map_id": "tback", "x": 3, "y": 0, "w": 2, "h": 2, "patrol_dir": "", "patrol_len": 0, "schedule": [], "look": "", "curtain": false}]
	bm.start = [3, 4]
	bm.run_start = [3, 4]
	DataLoader.maps["tback"] = bm
	GameState.clock = 12 * 60.0
	FieldScript.next_map_id = "tback"
	var bf: Node = load("res://scenes/field/field.tscn").instantiate()
	add_child(bf)
	await _wait(0.3)
	var br: Node2D = bf.renderer
	check(br.windows.has("tb_win") and br.windows.tb_win.light.enabled and is_equal_approx(br.windows.tb_win.light.rotation, PI / 2)
		and absf(br.windows.tb_win.light.position.y - 3.04 * bf.tile) < 1.0 and absf(br.windows.tb_win.light.position.x - 4.0 * bf.tile) < 1.0,
		"뒷벽 창문: 빛이 창문 아래 바닥 가장자리(가운데)에서 아래로")
	check(br.markers.tb_win.view.cells == Vector2i(2, 2) and br.markers.tb_win.view.mode == "face", "2×2 창문 그림은 2×2 칸 크기로 그림")
	check(bf.get_node("HUD/Vignette").visible and bf.get_node("HUD").get_child(0).name == "Vignette", "비네트 (HUD 맨 아래)")
	bf.player.position = bf._tile_center(4, 3)
	await _wait(0.1)
	check("커튼 치기: 높은 창" in bf.get_node("%Prompt").text, "뒷벽 창문 밑 바닥에서 '커튼 치기' 안내")
	await _snap("window_back_wall")
	bf.queue_free()
	await _wait(0.1)
	# ---- 기타 가구: 흰 사각형·막힘·사용 조건·줍기(사라짐)·사용(여러 번)
	var fm := _map("indoor")
	fm.map_id = "tfur"
	var fobj := func(id: String, x: int, y: int, extra: Dictionary) -> Dictionary:
		var o := {"object_id": id, "type": "furniture", "ref": "", "name": "", "text": "", "condition": "", "arrive": "", "from": [],
			"default": false, "once": false, "map_id": "tfur", "x": x, "y": y, "patrol_dir": "", "patrol_len": 0, "schedule": [],
			"w": 1, "h": 1, "label": "", "color": "#FFFFFF", "solid": true, "role": "", "use_condition": "", "use_fail_text": "", "effects": ""}
		o.merge(extra, true)
		return o
	fm.objects = [fobj.call("tf_clock", 4, 1, {"w": 2, "h": 3, "label": "거대한 시계", "top_rows": 1}),
		fobj.call("tf_drawer", 1, 1, {"label": "철제 서랍", "role": "pickup", "effects": "item:+bandage", "use_condition": "has:knife", "use_fail_text": "잠겨 있다."}),
		fobj.call("tf_tap", 1, 5, {"label": "수도", "role": "use", "effects": "surv:thirst+10", "solid": false})]
	DataLoader.maps["tfur"] = fm
	FieldScript.next_map_id = "tfur"
	var ff: Node = load("res://scenes/field/field.tscn").instantiate()
	add_child(ff)
	await _wait(0.3)
	check(ff.furniture.size() == 3 and ff.furniture.all(func(x): return x.node.get_parent() == ff.get_node("%World")), "가구 3개 (인물과 같은 Y 정렬 노드)")
	check(ff.path_grid().is_point_solid(Vector2i(5, 3)) and not ff.path_grid().is_point_solid(Vector2i(1, 5)), "막힌 가구 칸은 길 찾기에서 막힘 (2×3 전체), 안 막힌 가구는 지나감")
	var clock: Dictionary = ff.furniture.filter(func(x): return x.data.object_id == "tf_clock")[0]
	check(not clock in ff.spots, "역할 없는 가구(장식)는 상호작용 없음")
	check(not ff.path_grid().is_point_solid(Vector2i(4, 1)) and ff.path_grid().is_point_solid(Vector2i(4, 2)), "키 큰 가구: 윗줄(top_rows 1)은 뒤로 지나감, 아래는 막힘")
	ff.player.position = ff._tile_center(4, 1)
	await get_tree().physics_frame
	check(ff.player.position.y < clock.node.position.y and clock.node.get_parent() == ff.player.get_parent(), "시계 뒤에 서면 시계 그림이 캐릭터를 가림 (Y 정렬: 시계 발이 더 아래)")
	ff.player.position = ff._tile_center(2, 1)
	await _wait(0.1)
	await _snap("furniture")
	var drawer: Dictionary = ff.furniture.filter(func(x): return x.data.object_id == "tf_drawer")[0]
	check(ff._near_spot == drawer and "줍기: 철제 서랍" in ff.get_node("%Prompt").text, "가구 옆에서 '줍기: 철제 서랍' 안내 (이름 없으면 표시 메모)")
	GameState.remove_item("knife", GameState.item_count("knife"))
	var had: int = GameState.item_count("bandage")
	await ff._use_furniture(drawer)
	check(ff.get_node("%MessagePanel").visible and "잠겨 있다." in ff.get_node("%Message").text and drawer in ff.furniture, "사용 조건이 안 맞으면 못 쓸 때 문구")
	ff.close_message()
	GameState.add_item("knife", 1)
	await ff._use_furniture(drawer)
	check(GameState.item_count("bandage") == had + 1 and not drawer in ff.furniture and GameState.field_has("tfur", "removed", "tf_drawer")
		and not ff.path_grid().is_point_solid(Vector2i(1, 1)), "조건이 맞으면 줍기: 아이템 얻고 가구는 사라짐 (회차 상태에 기록, 길도 열림)")
	ff.close_message()
	var tap: Dictionary = ff.furniture.filter(func(x): return x.data.object_id == "tf_tap")[0]
	GameState.survival["thirst"] = 50.0
	await ff._use_furniture(tap)
	ff.close_message()
	await ff._use_furniture(tap)
	ff.close_message()
	check(is_equal_approx(float(GameState.survival.thirst), 70.0) and tap in ff.furniture, "사용 가구는 여러 번 (사라지지 않음)")
	ff.queue_free()
	DataLoader.maps.erase("tfur")
	await _overhead_test()
	await _outside_window_test()
	await _wall_lamp_test()
	DataLoader.maps.erase("tback")
	DataLoader.maps.erase("twin")
	DataLoader.maps.erase("tgfx")
	SaveManager.delete_all()
	print("[graphics_smoke] 실패 %d" % _fail)
	get_tree().quit(1 if _fail > 0 else 0)


## 테스트 맵 14x7: 가운데 벽(x=7)에 문, 왼쪽 방에 광원, 잔디·핏자국 칠함, 오른쪽 끝은 빈 공간
## 전경 가림 (기획 tevah_foreground_occlusion §9): 두 방 사이 통로 위 검은 가림막 — 화면에서는 덮이고, 걸어서 지나가짐
func _overhead_test() -> void:
	var src: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://tests/fixtures/maps/test_overhead.json"))
	var om := {"map_id": "tover", "width": 20, "height": src.tiles.size(), "tiles": src.tiles, "start": [2, 3], "run_start": [2, 3], "edges": {},
		"objects": [], "visual": src.visual, "environment": src.environment}
	DataLoader.maps["tover"] = om
	GameState.clock = 12 * 60.0
	FieldScript.next_map_id = "tover"
	var of: Node = load("res://scenes/field/field.tscn").instantiate()
	add_child(of)
	await _wait(0.3)
	var orr: Node2D = of.renderer
	var t: float = of.tile
	check(orr.overhead.get_used_cells().size() == 30 and orr.overhead.z_index > orr._roof_root.z_index and is_equal_approx(orr.overhead.modulate.a, 1.0),
		"01·02 전경 30칸, 인물·지붕보다 위(z %d), 게임에서는 불투명" % orr.overhead.z_index)
	check(not of.path_grid().is_point_solid(Vector2i(9, 3)) and of.path_grid().is_point_solid(Vector2i(9, 1)) and not of.find_path(Vector2i(2, 3), Vector2i(16, 3)).is_empty(),
		"03·04·13 통로는 길 찾기에서 열림, 전경 아래 벽(#)은 그대로 막힘")
	var q := PhysicsRayQueryParameters2D.create(Vector2(3.5, 3.5) * t, Vector2(16.5, 3.5) * t, of.WALL_LAYER | of.DOOR_LAYER)
	check(of.get_world_2d().direct_space_state.intersect_ray(q).is_empty(), "14 적 시야: 전경만으로는 막히지 않음 (통로 너머가 보임)")
	var lit := true
	for occ in orr._occ_root.get_children():
		if Geometry2D.is_point_in_polygon(Vector2(9.5, 3.5) * t, (occ as LightOccluder2D).occluder.polygon):
			lit = false
	check(lit, "15 빛: 전경 칸에 빛 막는 그림자 조각 없음")
	check(of.get_node("HUD").layer > 0 and orr.overhead.get_canvas_layer_node() == null, "17 전경은 월드에 그림 — HUD(대화·전투·글자)는 따로 위")
	# 실제로 걸어서 방 A → 통로 → 방 B
	of.player.position = of._tile_center(2, 3)
	Input.action_press("move_right")
	var under := false
	for i in 360:
		await get_tree().physics_frame
		var c := Vector2i(floori(of.player.position.x / t), floori(of.player.position.y / t))
		if orr.overhead.get_cell_source_id(c) != -1 and not under:
			under = true
			await _snap("overhead_under")
		if of.player.position.x > 15 * t:
			break
	Input.action_release("move_right")
	check(under and of.player.position.x > 15 * t, "01·03 걸어서 통로 통과 (전경 아래를 지남, x = %.1f칸)" % (of.player.position.x / t))
	# 전경 아래 벽으로는 못 감
	of.player.position = of._tile_center(9, 3)
	await get_tree().physics_frame
	Input.action_press("move_up")
	for i in 40:
		await get_tree().physics_frame
	Input.action_release("move_up")
	check(of.player.position.y > 2.9 * t, "04 전경 아래 벽(#)은 계속 막힘 (y = %.2f칸)" % (of.player.position.y / t))
	# 16 카메라가 소수점 위치로 움직여도 전경 칸 사이에 틈(밝은 줄)이 없음
	var seam := 0
	for step in 6:
		of.player.position = of._tile_center(9, 3) + Vector2(0.37 * step * 7.0, 0.23 * step * 5.0)
		await get_tree().process_frame
		await get_tree().process_frame
		var img := get_viewport().get_texture().get_image()
		var xf := get_viewport().get_canvas_transform()
		for gx in [8.0, 9.0, 10.0, 11.0]:
			for gy in [1.5, 2.0, 2.5, 5.0, 5.5, 6.0]:
				for d in [-1.0, 0.0, 1.0]:
					var sp: Vector2 = xf * (Vector2(gx, gy) * t) + Vector2(d, 0)
					if Rect2(Vector2.ZERO, Vector2(img.get_size())).has_point(sp) and img.get_pixelv(Vector2i(sp)).v > 0.12:
						seam += 1
	check(seam == 0, "16 카메라가 소수점 위치여도 전경 칸 경계에 틈 없음 (밝은 점 %d)" % seam)
	of.queue_free()
	await _wait(0.1)
	# 18 여러 NPC 가 전경 아래·밖을 지날 때: 서로는 Y 정렬, 전경은 늘 위
	var nm: Dictionary = om.duplicate(true)
	nm.map_id = "tover2"
	var npc := func(id: String, x: int, y: int) -> Dictionary:
		return {"object_id": id, "type": "npc", "ref": "", "name": id, "text": "", "condition": "", "arrive": "", "from": [], "default": false, "once": false,
			"map_id": "tover2", "x": x, "y": y, "patrol_dir": "", "patrol_len": 0, "schedule": [], "face": ""}
	nm.objects = [npc.call("n_under_a", 9, 3), npc.call("n_under_b", 9, 4), npc.call("n_room", 4, 4)]
	DataLoader.maps["tover2"] = nm
	FieldScript.next_map_id = "tover2"
	var nf: Node = load("res://scenes/field/field.tscn").instantiate()
	add_child(nf)
	await _wait(0.3)
	var world: Node2D = nf.get_node("%World")
	var ns: Array = nf.npcs.map(func(n): return n.node)
	check(ns.size() == 3 and world.y_sort_enabled and ns.all(func(n): return n.get_parent() == world and n.z_index < nf.renderer.overhead.z_index),
		"18 NPC 셋 모두 Y 정렬 노드(World)에, 전경(z %d)보다 아래" % nf.renderer.overhead.z_index)
	nf.player.position = nf._tile_center(9, 5)
	await _wait(0.2)
	await _snap("overhead_npcs")
	nf.queue_free()
	DataLoader.maps.erase("tover2")
	of = null
	DataLoader.maps.erase("tover")


## 벽걸이등: 광원을 벽 칸에 — 그림은 벽에, 빛은 그 벽 앞 바닥 가장자리에서 (뒷벽 높은 곳이어도 아래 바닥으로)
func _wall_lamp_test() -> void:
	var lm := _map("indoor")
	lm.map_id = "tlamp"
	lm.tiles = ["##############", "##############", "##############", "#......#....# ", "#......#....# ", "#............ ", "##############"]
	var lamp := func(id: String, x: int, y: int, on: bool) -> Dictionary:
		return {"object_id": id, "type": "light", "ref": "", "name": id, "text": "", "condition": "", "arrive": "", "from": [], "default": false,
			"once": false, "map_id": "tlamp", "x": x, "y": y, "patrol_dir": "", "patrol_len": 0, "schedule": [],
			"preset": "wall_sconce", "color": "#FFC880", "energy": 1.0, "radius": 4.0, "shadow": true, "enabled": on}
	lm.objects = [lamp.call("tl_on", 3, 1, true), lamp.call("tl_off", 9, 2, false)]
	lm.start = [3, 4]
	lm.run_start = [3, 4]
	DataLoader.maps["tlamp"] = lm
	GameState.clock = 22 * 60.0
	FieldScript.next_map_id = "tlamp"
	var f: Node = load("res://scenes/field/field.tscn").instantiate()
	add_child(f)
	await _wait(0.3)
	var r: Node2D = f.renderer
	var on_light: PointLight2D = r.lights.filter(func(p): return p.get_meta("object_id") == "tl_on")[0]
	check(absf(on_light.position.y - 3.06 * f.tile) < 1.0 and absf(on_light.position.x - 3.5 * f.tile) < 1.0 and on_light.enabled,
		"벽걸이등: 뒷벽에 걸어도 빛은 그 아래 바닥 가장자리에서 (%.2f칸)" % (on_light.position.y / f.tile))
	check(r.markers.has("tl_on") and r.markers.tl_on.kind == "lamp" and r.markers.tl_on.sprite.material != null
		and r.markers.tl_off.sprite.material == null, "벽걸이등 그림: 켜진 등은 밝게, 꺼진 등은 방과 같이")
	f.player.position = f._tile_center(3, 4)
	await _wait(0.2)
	await _snap("wall_lamp_night")
	f.queue_free()
	DataLoader.maps.erase("tlamp")


## 실외 맵의 창문(건물 바깥): 햇빛을 내보내지 않음. 문이 이어진 안쪽 맵에 켜진 광원이 있으면 불 켜진 창 (밤에 따뜻한 빛)
func _outside_window_test() -> void:
	var o := func(id: String, type: String, x: int, y: int, extra := {}) -> Dictionary:
		var d := {"object_id": id, "type": type, "ref": "", "name": id, "text": "", "condition": "", "arrive": "", "from": [], "default": false,
			"once": false, "map_id": "tout", "x": x, "y": y, "patrol_dir": "", "patrol_len": 0, "schedule": []}
		d.merge(extra, true)
		return d
	var tiles := ["##########", "#..####..#", "#..####..#", "#........#", "#........#", "##########"]
	var outm := {"map_id": "tout", "width": 10, "height": 6, "tiles": tiles, "start": [1, 4], "run_start": [1, 4], "edges": {},
		"objects": [o.call("to_door", "exit", 4, 3, {"ref": "tin"}), o.call("to_win", "window", 5, 1, {"w": 1, "h": 1, "curtain": false, "inside": ""})],
		"visual": {"layers": {}}, "environment": {"profile": "outdoor"}}
	var inm := {"map_id": "tin", "width": 4, "height": 4, "tiles": ["####", "#..#", "#..#", "####"], "start": [1, 1], "run_start": [1, 1], "edges": {},
		"objects": [o.call("ti_lamp", "light", 1, 1, {"enabled": true, "color": "#FFD4A0", "energy": 1.0, "radius": 3.0, "shadow": true})], "visual": {"layers": {}}}
	DataLoader.maps["tout"] = outm
	DataLoader.maps["tin"] = inm
	GameState.clock = 0.0
	FieldScript.next_map_id = "tout"
	var f: Node = load("res://scenes/field/field.tscn").instantiate()
	add_child(f)
	await _wait(0.3)
	var w: Dictionary = f.renderer.windows.to_win
	check(w.outside and w.lit and w.light.enabled and w.light.energy > 0.6 and f.renderer.markers.to_win.view.lamp, "바깥 창문: 안쪽 맵에 불 → 밤에 불 켜진 창 (따뜻한 빛)")
	f.renderer.set_time(12 * 60)
	check(w.light.energy < 0.2 and w.light.color != VisualData.daylight(12 * 60).color, "바깥 창문 낮: 햇빛을 내보내지 않음 (불빛만 약하게)")
	f.queue_free()
	await _wait(0.1)
	inm.objects[0].enabled = false
	FieldScript.next_map_id = "tout"
	f = load("res://scenes/field/field.tscn").instantiate()
	add_child(f)
	await _wait(0.3)
	check(not f.renderer.windows.to_win.lit and not f.renderer.windows.to_win.light.enabled, "안쪽 불이 꺼져 있으면 바깥 창문은 빛 없음")
	f.queue_free()
	DataLoader.maps.erase("tout")
	DataLoader.maps.erase("tin")


func _map(profile: String) -> Dictionary:
	var tiles := ["##############", "#......#....# ", "#......#....# ", "#............ ", "#......#....# ", "#......#....# ", "##############"]
	var obj := func(id: String, type: String, x: int, y: int, extra := {}) -> Dictionary:
		var o := {"object_id": id, "type": type, "ref": "", "name": id, "text": "", "condition": "", "arrive": "", "from": [],
			"default": false, "once": false, "map_id": "tgfx", "x": x, "y": y, "patrol_dir": "", "patrol_len": 0, "schedule": []}
		o.merge(extra, true)
		return o
	return {"map_id": "tgfx", "width": 14, "height": 7, "tiles": tiles, "start": [2, 4], "run_start": [2, 4], "edges": {},
		"objects": [obj.call("tg_door", "exit", 7, 3, {"ref": "basecamp"}),
			obj.call("tg_lamp", "light", 4, 2, {"preset": "warm_bulb", "color": "#FFD4A0", "energy": 1.2, "radius": 5.0, "shadow": true, "enabled": true}),
			obj.call("tg_tree", "prop", 3, 4, {"ref": "tree"}), obj.call("tg_table", "prop", 9, 5, {"ref": "table"})],
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
