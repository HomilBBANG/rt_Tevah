extends Node
## 특성 (기획 tevah_character_creation_status_effects_spec_v0.1): 캐릭터 생성 포인트·막힘 이유, 특성 얻기·잃기 효과,
## 회차가 바뀌어도 남기, 저장 슬롯을 불러오면 그 저장의 특성 (§5.4 안 B), 완전히 새 게임. 실행:
##   Godot_v4.7-stable_win64_console.exe --headless --path . res://tests/test_traits.tscn
## 데이터: player.xlsx Traits (high_intellect -6, heavy_smoker +2, lucky 선택 불가 …), Config creation_start_points 5

const Creation = preload("res://scenes/character_creation.tscn")

var _pass := 0
var _fail := 0
var _msgs: Array = []


func _ready() -> void:
	SaveManager.save_dir = "user://test_saves/"
	SaveManager.delete_all()
	StoryRunner.message.connect(func(t): _msgs.append(t))
	check(DataLoader.traits.size() == 40 and DataLoader.get_config_int("creation_start_points", 0) == 5, "특성 40종, 시작 포인트 5")

	# ---- 캐릭터 생성 화면 (계산·막힘 이유)
	var cc: Control = Creation.instantiate()
	add_child(cc)
	await get_tree().process_frame
	check(cc.remaining() == 5, "처음 남은 P = 5")
	check(cc.block_reason("high_intellect").begins_with("포인트 부족"), "고지능자(-6) 는 5P 로 못 고름: %s" % cc.block_reason("high_intellect"))
	cc.toggle("heavy_smoker")
	check(cc.remaining() == 7 and cc.block_reason("high_intellect") == "", "골초(+2) 고르면 7P → 고지능자 고를 수 있음")
	cc.toggle("high_intellect")
	check(cc.remaining() == 1 and cc.selected == ["heavy_smoker", "high_intellect"], "고지능자(-6) → 남은 1P (기획 인수 테스트 1)")
	check(cc.block_reason("lucky") == "아직 고를 수 없는 특성", "행운아: 선택 불가 이유")
	cc.toggle("heavy_smoker")   # 부정 특성을 빼면 -1P → 시작 못 함
	await get_tree().process_frame
	check(cc.remaining() == -1 and cc._start_btn.disabled, "골초를 빼면 -1P → 생존 시작 막힘")
	cc.toggle("heavy_smoker")
	await get_tree().process_frame
	check(not cc._start_btn.disabled, "다시 고르면 시작 가능")
	# 충돌 규칙 (데이터의 conflicts 는 아직 비어 있어서 잠깐 넣어 본다)
	DataLoader.traits.brave.conflicts = ["coward"]
	cc.selected = []
	check(cc.block_reason("coward") == "", "용감함을 안 골랐으면 겁쟁이 OK")
	cc.toggle("brave")
	check(cc.block_reason("coward").contains("같이 고를 수 없음"), "용감함을 고르면 겁쟁이 막힘: %s" % cc.block_reason("coward"))
	cc.selected = ["coward"]
	check(cc.block_reason("brave").contains("같이 고를 수 없음"), "반대쪽(겁쟁이 → 용감함)도 막힘")
	DataLoader.traits.brave.conflicts = []
	cc.selected = ["high_intellect", "heavy_smoker"]
	# 생존 시작 = 캐릭터 만들기 + 첫 회차 (화면 이동은 테스트에서 하지 않음)
	GameState.create_character(cc.selected.duplicate())
	SaveManager.begin_run()
	cc.queue_free()
	check(GameState.character_created and GameState.owned_trait_ids() == ["high_intellect", "heavy_smoker"]
		and GameState.owned_traits[0].from == "creation", "생성 확정: 특성 2개 (from creation)")
	check(GameState.has_trait("high_intellect") and StoryRunner.Expr.evaluate("trait:heavy_smoker & !trait:brave", GameState), "조건 trait: 이 가진 특성을 봄")

	# ---- 사건으로 얻기·잃기 (효과 trait:+id / trait:-id)
	await StoryRunner.run_effects("trait:+brave;trait:+brave")
	check(GameState.owned_trait_ids().count("brave") == 1 and GameState.owned_traits[2].from == "event", "사건으로 용감함 (두 번 얻어도 하나)")
	check(_msgs.any(func(m): return "특성을 얻었다: 용감함" in m), "알림: 특성을 얻었다: 용감함")
	# ---- 저장 슬롯 (안 B): 슬롯에 그때의 특성
	GameState.current_map = DataLoader.get_config_str("basecamp_map")
	SaveManager.save_run(1)          # 고지능자·골초·용감함
	await StoryRunner.run_effects("trait:-heavy_smoker;trait:+coward")
	check(not GameState.has_trait("heavy_smoker") and GameState.has_trait("coward"), "골초 잃고 겁쟁이 얻음")
	# ---- 죽고 다음 회차: 지금 특성 그대로 (생성 화면 없음)
	SaveManager.end_run()
	SaveManager.begin_run()
	GameState.world_from_dict(JSON.parse_string(FileAccess.get_file_as_string(SaveManager.world_path())))   # 다시 켠 것처럼 월드 파일에서
	check(GameState.owned_trait_ids() == ["high_intellect", "brave", "coward"] and GameState.character_created,
		"죽고 새 회차 → 특성 유지 (고지능자·용감함·겁쟁이): %s" % [GameState.owned_trait_ids()])
	# ---- 옛 슬롯 불러오기 → 그 저장의 특성 (안 B), 월드에도
	check(SaveManager.load_run(1) and GameState.owned_trait_ids() == ["high_intellect", "heavy_smoker", "brave"],
		"슬롯 1 불러오기 → 저장 때 특성 (골초 있음, 겁쟁이 없음): %s" % [GameState.owned_trait_ids()])
	var world: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(SaveManager.world_path()))
	check(world.owned_traits.map(func(t): return t.trait_id) == ["high_intellect", "heavy_smoker", "brave"], "불러온 특성이 월드에도 기록 (이 뒤로 죽어도 이어짐)")
	# 특성 기록이 없는 예전 저장은 지금 특성 그대로
	var old := GameState.run_to_dict()
	old.erase("owned_traits")
	GameState.set_trait("coward", true)
	GameState.run_from_dict(old)
	check(GameState.has_trait("coward"), "특성 기록 없는 예전 저장 → 지금 특성 그대로")
	# ---- 완전히 새 게임
	SaveManager.new_game()
	check(not GameState.character_created and GameState.owned_traits.is_empty() and GameState.run_count == 0, "새 게임: 특성·회차 기록 지움")
	check(SaveManager.has_run_save(1), "새 게임이어도 저장 슬롯은 남음")

	SaveManager.delete_all()
	print("[test_traits] %d 통과, %d 실패" % [_pass, _fail])
	get_tree().quit(1 if _fail > 0 else 0)


func check(ok: bool, label: String) -> void:
	print(("ok   " if ok else "FAIL ") + label)
	if ok:
		_pass += 1
	else:
		_fail += 1
