extends Node
## 시간·생존 파라미터·베이스캠프 행동·회차 저장 테스트 (더미 데이터 기준). 실행:
##   Godot_v4.7-stable_win64_console.exe --headless --path . res://tests/test_survival.tscn

var _fail := 0
var _pass := 0
var messages: Array[String] = []


func _ready() -> void:
	SaveManager.save_dir = "user://test_saves/"
	SaveManager.delete_all()
	StoryRunner.message.connect(func(t): messages.append(t))

	# ---------- 새 회차
	SaveManager.begin_run()
	check(GameState.run_count == 1 and GameState.current_map == "basecamp", "새 회차: 1회차, 베이스캠프에서 시작")
	check(GameState.day() == 1 and GameState.clock_text() == "08:00", "1일차 08:00")
	check(GameState.get_survival("hunger") == 80.0 and GameState.get_survival("mental") == 100.0, "생존 파라미터 시작값")
	check(GameState.player_body.size() == 6 and not GameState.player_body.head.broken, "몸 상태 새로")

	# ---------- 시간 흐름 → 감소
	GameState.advance_time(90)
	check(GameState.clock_text() == "09:30", "90분 경과 → 09:30")
	check(is_equal_approx(GameState.get_survival("hunger"), 74.0), "포만감 4/시간 → 80 - 6 = 74 (%.1f)" % GameState.get_survival("hunger"))
	check(is_equal_approx(GameState.get_survival("thirst"), 71.0), "수분 6/시간 → 80 - 9 = 71")
	GameState.advance_time(24 * 60)
	check(GameState.day() == 2 and GameState.clock_text() == "09:30", "하루 뒤 2일차")
	check(GameState.get_survival("thirst") == 0.0, "0 아래로는 안 내려감")

	# ---------- 아이템·조건
	StoryRunner.enter_field()
	GameState.add_item("food", 1)
	check(Expr.evaluate("surv:hunger<30 & has:food", GameState), "조건 surv:hunger<30")
	messages.clear()
	await StoryRunner.use_item(0)
	check(GameState.item_count("food") == 0 and GameState.get_survival("hunger") == 40.0, "통조림 사용 → 포만감 0 + 40")
	check(messages.has("사용: 통조림(테스트)") and messages.has("포만감 +40"), "사용 메시지: %s" % [messages])

	# ---------- 베이스캠프 행동
	var sleep: Dictionary = DataLoader.camp_actions.filter(func(a): return a.kind == "sleep")[0]
	check(sleep.minutes == 60, "잠은 1시간 단위")
	var before_sleep := GameState.get_survival("sleep")
	var before_clock := GameState.clock
	for i in 8:   # 필드에서 8시간을 고른 것과 같은 처리
		GameState.advance_time(sleep.minutes)
		await StoryRunner.run_effects(sleep.effects)
	check(GameState.clock - before_clock == 480.0, "8시간 자기 → 시계 +8시간")
	check(GameState.get_survival("sleep") > before_sleep, "수면 회복 (%.0f → %.0f)" % [before_sleep, GameState.get_survival("sleep")])
	GameState.change_survival("sleep", "+", 999)
	check(GameState.get_survival("sleep") == 100.0, "최대치에서 멈춤")

	# ---------- 조사 시간 (Loot time_cost → 시계)
	var t0 := GameState.clock
	await StoryRunner.run_effects("loot:spot_supply")
	check(GameState.clock - t0 == 10.0 and GameState.item_count("food") == 2 and GameState.item_count("water") == 2,
		"보급 상자 조사 → 10분, 음식·물 2개씩")

	# ---------- NPC 시간대 (FieldObjects.schedule)
	var F = preload("res://scenes/field/field.gd")
	check(F.in_schedule([], 0) and F.in_schedule([], 1439), "schedule 비면 항상")
	var day_r := [[360, 720]]   # 06:00-12:00
	check(not F.in_schedule(day_r, 359) and F.in_schedule(day_r, 360) and F.in_schedule(day_r, 719) and not F.in_schedule(day_r, 720),
		"06:00-12:00: 06:00 부터, 12:00 전까지")
	var night_r := [[1320, 120]]   # 22:00-02:00
	check(F.in_schedule(night_r, 1380) and F.in_schedule(night_r, 60) and not F.in_schedule(night_r, 130) and not F.in_schedule(night_r, 1300),
		"22:00-02:00: 자정 넘김")
	var cat: Dictionary = DataLoader.maps.basecamp.objects.filter(func(o): return o.object_id == "fo_cat")[0]
	var cat_r: Array = cat.schedule.map(func(r): return [int(r[0]), int(r[1])])   # JSON 숫자는 float
	check(cat_r == [[360, 720], [1200, 1380]], "더미 고양이 루틴 06:00-12:00, 20:00-23:00")

	# ---------- 효과 save: 베이스캠프에서만
	messages.clear()
	GameState.current_map = "test_field"
	await StoryRunner.run_effects("save")
	check(not SaveManager.has_run_save() and messages.has("여기서는 저장할 수 없다."), "탐험 지역에서는 save 효과로 저장 안 됨")
	GameState.current_map = "basecamp"
	await StoryRunner.run_effects("save")
	check(SaveManager.has_run_save() and messages.any(func(m): return m.begins_with("저장했다")), "베이스캠프에서는 save 효과로 저장")

	# ---------- 저장 → 불러오기
	GameState.player_body.left_arm.hp = 0
	GameState.player_body.left_arm.broken = true
	GameState.field_mark("test_field", "removed", "fo_enemy1")
	GameState.set_flag("showed_knife", true)
	SaveManager.save_run()
	var snap := GameState.run_to_dict()
	GameState.reset_run()
	check(not GameState.player_body.left_arm.broken, "reset 후 몸 새로")
	check(SaveManager.load_run(), "회차 불러오기")
	var now := GameState.run_to_dict()
	var surv_same := true
	for k in snap.survival:
		surv_same = surv_same and absf(now.survival[k] - snap.survival[k]) < 0.0001   # JSON 왕복 소수 오차
	now.erase("survival")
	snap.erase("survival")
	check(now == snap and surv_same, "저장 내용 그대로 복원")
	check(GameState.field_has("test_field", "removed", "fo_enemy1") and GameState.player_body.left_arm.broken,
		"처치한 적·절단 상태 유지")

	# ---------- 사망 → 저장 삭제, 회차 수 유지
	SaveManager.end_run()
	check(not SaveManager.has_run_save(), "사망 → 회차 저장 삭제 (되돌릴 수 없음)")
	GameState.world_from_dict({})
	SaveManager.load_world()
	check(GameState.run_count == 1, "회차 수는 월드에 남음")
	SaveManager.begin_run()
	check(GameState.run_count == 2 and GameState.item_count("food") == 0, "2회차: 소지품 초기화")

	SaveManager.delete_all()
	print("\n[test_survival] %d 통과, %d 실패" % [_pass, _fail])
	get_tree().quit(1 if _fail > 0 else 0)


const Expr = preload("res://core/expr.gd")


func check(ok: bool, label: String) -> void:
	if ok:
		_pass += 1
		print("ok   " + label)
	else:
		_fail += 1
		print("FAIL " + label)
