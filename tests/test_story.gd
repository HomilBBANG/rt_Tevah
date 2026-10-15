extends Node
## ep_test1 / ep_test2 더미 데이터로 StoryRunner 를 처음부터 엔딩까지 돌려보는 통합 테스트. 실행:
##   Godot_v4.7-stable_win64_console.exe --headless --path . res://tests/test_story.tscn
## 저장은 user://test_saves/ 에 하므로 실제 세이브는 건드리지 않는다.
## 더미 데이터(tools/sheets/*.xlsx, tools/dialogues/)의 ID에 의존한다.

var node_id := ""
var entries: Array = []
var messages: Array[String] = []
var ending := ""
var last_dice := {}
var dialogue_done := 0
var discard_answers: Array[int] = []
var full_events := 0

var _fail := 0
var _pass := 0


func _ready() -> void:
	seed(12345)
	SaveManager.save_dir = "user://test_saves/"
	SaveManager.delete_all()
	StoryRunner.node_shown.connect(func(n, _s): node_id = n.node_id)
	StoryRunner.choices_shown.connect(func(e): entries = e)
	StoryRunner.message.connect(func(t): messages.append(t))
	StoryRunner.messages_cleared.connect(func(): messages.clear())
	StoryRunner.ending_reached.connect(func(id): ending = id)
	StoryRunner.dice_rolled.connect(func(r): last_dice = r)
	StoryRunner.dialogue_ended.connect(func(): dialogue_done += 1)
	StoryRunner.inventory_full.connect(_on_full)
	await _run()
	SaveManager.delete_all()
	print("\n[test_story] %d 통과, %d 실패" % [_pass, _fail])
	get_tree().quit(1 if _fail > 0 else 0)


func _on_full(_item: String, _amount: int) -> void:
	full_events += 1
	var answer: int = discard_answers.pop_front() if not discard_answers.is_empty() else -1
	StoryRunner.choose_discard.call_deferred(answer)


func _run() -> void:
	# ---------- 기본 진행 · 조건부 선택지
	check(not StoryRunner.is_unlocked("ep_test2"), "처음엔 ep_test2 잠김")
	await StoryRunner.start_episode("ep_test1")
	check(node_id == "t1_intro" and entries.is_empty(), "시작 노드 t1_intro, 선택지 없음")
	check(GameState.item_count("bandage") == 1 and GameState.has_flag("intro_seen"), "on_enter 효과 (붕대, 플래그)")
	await StoryRunner.continue_story()
	check(node_id == "t1_a", "next_node 로 t1_a")
	check(_ids() == ["c_a1", "c_a2", "c_a4"], "hide 선택지 숨김: %s" % [_ids()])
	check(not _enabled("c_a2"), "gray 선택지 비활성")
	await StoryRunner.choose("c_a2")
	check(node_id == "t1_a", "비활성 선택지는 무시")

	# ---------- 탐색 (loot)
	await StoryRunner.choose("c_a1")
	check(node_id == "t1_b", "일반 선택지 → t1_b")
	await StoryRunner.choose("c_b2")
	check("아무것도 찾지 못했다." in messages and GameState.get_stat("time") == 115, "빈 탐색: 메시지, 시간 -5 (%d)" % GameState.get_stat("time"))
	await StoryRunner.choose("c_b1")
	check(GameState.item_count("knife") == 1 and GameState.get_stat("time") == 105, "탐색으로 칼 획득, 시간 -10")
	await StoryRunner.choose("c_b4")
	check(_ids() == ["c_a1", "c_a2", "c_a3", "c_a4"] and _enabled("c_a2") and _enabled("c_a3"), "칼 보유 → 조건부 선택지 활성/표시")

	# ---------- 인벤토리 초과
	await StoryRunner.choose("c_a1")
	discard_answers = [0, -1]   # 첫 요청: 0번 칸(붕대) 버림, 두 번째: 포기
	await StoryRunner.choose("c_b3")
	check(full_events == 2, "인벤토리 초과 요청 2회 (%d)" % full_events)
	# 칸 수 = Config inventory_slots (가방 없음). 붕대·칼 + 잡동사니로 가득 → 붕대 버리고 잡동사니 1개 더
	var slots := GameState.slot_count()
	check(GameState.inventory.size() == slots, "%d칸 가득 (%d)" % [slots, GameState.inventory.size()])
	check(GameState.item_count("junk") == slots - 1 and GameState.item_count("bandage") == 0 and GameState.item_count("knife") == 1,
		"붕대 버리고 잡동사니 %d개, 칼 유지" % (slots - 1))
	check(messages.any(func(m): return m.begins_with("포기")), "포기 메시지")

	# ---------- 저장 후 재개
	var snapshot := GameState.episode_to_dict()
	GameState.reset_for_episode(DataLoader.episodes.ep_test1)
	check(SaveManager.has_episode_save("ep_test1"), "진행 파일 존재")
	StoryRunner.prepare("ep_test1", true)
	await StoryRunner.launch()
	check(GameState.episode_to_dict() == snapshot and node_id == "t1_b", "재개 후 상태 동일")

	# ---------- 칼 경로 → 플래그 조건 · 능력 조건 · 아이템 사용
	await StoryRunner.choose("c_b4")
	await StoryRunner.choose("c_a2")
	check(node_id == "t1_c" and GameState.has_flag("used_knife"), "칼 선택지 → t1_c, 플래그")
	await StoryRunner.continue_story()
	check(node_id == "t1_d" and _enabled("c_d2"), "flag 조건 선택지 활성")
	check(_ids().has("c_d3") and not _enabled("c_d4"), "trait 선택지 표시, 복합조건 비활성")
	discard_answers = [1]   # 가득 차 있으므로 1번 칸(잡동사니) 버리고 알약 받기
	await StoryRunner.choose("c_d3")
	check(GameState.item_count("pill") == 1 and GameState.item_count("junk") == slots - 2, "알약 획득 (잡동사니 1 버림)")
	check(_enabled("c_d4"), "복합조건 (has:pill) 활성")
	var pill_slot := GameState.inventory.find_custom(func(s): return s.id == "pill")
	await StoryRunner.use_item(pill_slot)
	check(GameState.item_count("pill") == 0 and node_id == "t1_d", "알약 사용 → 소모")
	check(not _enabled("c_d4"), "알약 소모 후 복합조건 다시 비활성")

	# ---------- 주사위 판정 (칼 소지 중: 근력 3 + 칼 1)
	await StoryRunner.choose("c_d8")
	check(node_id == "t1_e", "판정 테스트 노드")
	var d1 := _dice("c_e1")
	check(d1.mod == 4 and d1.parts.size() == 2 and is_equal_approx(d1.chance, 0.65),
		"판정 A 미리보기: 보정 +4 (능력치 3 + 칼 1), 성공 65%% (%s)" % [d1])
	var d2 := _dice("c_e2")
	check(d2.mod == -5 and is_equal_approx(d2.chance, 0.3), "판정 B 미리보기: 상황 보정 -5, 성공 30%% (%s)" % [d2])
	check(not _enabled("c_e4"), "abil 조건 (근력 >= 4) 비활성")
	StoryRunner.forced_rolls = [8]
	await StoryRunner.choose("c_e1")
	check(last_dice.roll == 8 and last_dice.total == 12 and last_dice.success, "판정 성공: 8 + 4 = 12 >= 12")
	check(node_id == "t1_dice_ok" and GameState.has_flag("dice_ok"), "성공 → effects·next_node")
	await StoryRunner.continue_story()
	var hp := GameState.get_stat("hp")
	StoryRunner.forced_rolls = [7]
	await StoryRunner.choose("c_e1")
	check(not last_dice.success and node_id == "t1_dice_fail" and GameState.get_stat("hp") == hp - 5,
		"판정 실패: 7 + 4 = 11 < 12 → fail_effects·fail_next")
	await StoryRunner.continue_story()
	# 대성공·대실패: 판정 B (보정 -5, 목표 10) 는 20 이면 합계 15 여도 성공, 판정 A 는 1 이면 무조건 실패
	StoryRunner.forced_rolls = [20]
	await StoryRunner.choose("c_e2")
	check(last_dice.success and last_dice.critical == "success" and node_id == "t1_dice_ok", "20 → 대성공")
	await StoryRunner.continue_story()
	StoryRunner.forced_rolls = [1]
	await StoryRunner.choose("c_e1")
	check(not last_dice.success and last_dice.critical == "fail" and node_id == "t1_dice_fail", "1 → 대실패")
	await StoryRunner.continue_story()
	StoryRunner.forced_rolls = [12]
	await StoryRunner.choose("c_e1")
	check(last_dice.success and last_dice.critical == "", "일반 판정은 critical 없음")
	await StoryRunner.continue_story()
	var impossible := StoryRunner.dice_preview({"check": "strength", "dc": 99, "mod": 0})
	var certain := StoryRunner.dice_preview({"check": "strength", "dc": 1, "mod": 0})
	check(is_equal_approx(impossible.chance, 0.05) and is_equal_approx(certain.chance, 0.95), "확률 5%~95% 로 제한")
	await StoryRunner.choose("c_e3")
	check(GameState.get_ability("strength") == 4 and _enabled("c_e4"), "능력치 성장 abil:strength+1 → 조건 충족")
	check(is_equal_approx(_dice("c_e1").chance, 0.7), "성장 후 판정 A 70%")
	var snap := GameState.episode_to_dict()
	GameState.reset_for_episode(DataLoader.episodes.ep_test1)
	StoryRunner.prepare("ep_test1", true)
	await StoryRunner.launch()
	check(GameState.get_ability("strength") == 4 and GameState.episode_to_dict() == snap, "능력치 성장 저장·재개")

	# ---------- 대가형 · 사망
	await _fresh_to_d()
	check(GameState.get_stat("hp") == 90 and GameState.get_stat("time") == 110, "대가형 선택지 (체력·시간 -10)")
	await StoryRunner.choose("c_d5")
	check(ending == "end_t1_death" and StoryRunner.ended, "hp 0 → 사망 엔딩")
	check(not SaveManager.has_episode_save("ep_test1"), "엔딩 후 진행 파일 삭제")
	check(not StoryRunner.is_unlocked("ep_test2"), "사망 엔딩으로는 해금 안 됨")

	# ---------- 광기 · 시간 초과
	await _fresh_to_d()
	await StoryRunner.choose("c_d6")
	check(ending == "end_t1_madness", "sanity 0 → 광기 엔딩")
	await _fresh_to_d()
	await StoryRunner.choose("c_d7")
	check(node_id == "t1_timeout" and ending == "", "time 0 → 시간 초과 노드")
	await StoryRunner.continue_story()
	check(ending == "end_t1_timeout", "시간 초과 엔딩")

	# ---------- 클리어 → 월드 플래그 → ep_test2 해금
	await _fresh_to_d()
	await StoryRunner.choose("c_d1")
	check(ending == "end_t1_clear" and GameState.has_wflag("ep_test1_clear"), "클리어 엔딩, 월드 플래그")
	check(StoryRunner.is_unlocked("ep_test2"), "ep_test2 해금")
	GameState.world_from_dict({})
	SaveManager.load_world()
	check(GameState.has_wflag("ep_test1_clear"), "월드 플래그 저장·로드")

	ending = ""
	await StoryRunner.start_episode("ep_test2")
	check(node_id == "t2_npc1" and GameState.item_count("knife") == 0, "ep_test2 시작 (인벤토리 초기화)")
	await StoryRunner.continue_story()
	await StoryRunner.continue_story()
	check(node_id == "t2_a", "NPC 2인 대화 후 t2_a")
	await StoryRunner.choose("c2_a1")
	check(ending == "end_t2_clear", "ep_test2 클리어")

	# ---------- 필드 대화 (에피소드 없이, Config protagonist_id = char_t1)
	ending = ""
	GameState.reset_run()
	check(GameState.protagonist_id == "char_t1" and GameState.get_ability("strength") == 3, "탐험 회차: 주인공 능력치 로드")
	await StoryRunner.start_dialogue("fd_npc1_a")
	check(node_id == "fd_npc1_a" and StoryRunner.mode == "field", "NPC 1 대화 시작")
	check(_ids() == ["fdc1", "fdc2", "fdc3", "fdc4"] and not _enabled("fdc2"), "일반·아이템(칼 없음 → 회색)·판정·끝내기")
	check(_dice("fdc3").mod == 3, "판정 보정 = 주인공 근력 3")
	await StoryRunner.choose("fdc4")
	check(dialogue_done == 1 and StoryRunner.ended and ending == "", "EXIT → 대화 끝 (엔딩 아님)")
	GameState.add_item("knife", 1)
	await StoryRunner.start_dialogue("fd_npc1_a")
	check(_enabled("fdc2"), "칼 소지 → 아이템 선택지 활성")
	await StoryRunner.choose("fdc2")
	check(node_id == "fd_npc1_b" and GameState.has_flag("showed_knife"), "아이템 선택지 → 다음 노드, 플래그")
	await StoryRunner.continue_story()
	check(dialogue_done == 2, "next_node EXIT → 대화 끝")
	await StoryRunner.start_dialogue("fd_npc1_a")
	StoryRunner.forced_rolls = [1]
	await StoryRunner.choose("fdc3")
	check(node_id == "fd_npc1_fail" and last_dice.critical == "fail", "대화 판정 실패 → fail_next")
	await StoryRunner.continue_story()
	await StoryRunner.start_dialogue("fd_npc2_a")
	check(_ids().has("fdc5"), "다른 NPC 대화에서 플래그로 열린 선택지")
	await StoryRunner.choose("fdc6")
	check(dialogue_done == 4 and not SaveManager.has_episode_save(""), "필드 대화는 에피소드 저장 안 함")

	# ---------- 전투 선택지 (type=combat, check=enemy_id): 이기면 next_node, 도주하면 fail_next, 지면 대화 끝
	var fights := []
	StoryRunner.combat_requested.connect(func(id): fights.append(id))
	await StoryRunner.start_dialogue("fd_npc2_a")
	var fight_entry: Array = entries.filter(func(e): return e.choice.choice_id == "fdc7")
	check(fight_entry.size() == 1 and fight_entry[0].combat.enemy_name == "적 A (테스트)", "전투 선택지: 적 이름 표시")
	StoryRunner.combat_override = "win"
	await StoryRunner.choose("fdc7")
	check(node_id == "fd_npc2_win" and GameState.has_flag("beat_npc2") and not GameState.has_flag("fled_npc2"), "전투 승리 → effects·next_node")
	await StoryRunner.continue_story()
	await StoryRunner.start_dialogue("fd_npc2_a")
	StoryRunner.combat_override = "fled"
	await StoryRunner.choose("fdc7")
	check(node_id == "fd_npc2_fled" and GameState.has_flag("fled_npc2"), "전투 도주 → fail_effects·fail_next")
	await StoryRunner.continue_story()
	var done_before := dialogue_done
	await StoryRunner.start_dialogue("fd_npc2_a")
	StoryRunner.combat_override = "lose"
	await StoryRunner.choose("fdc7")
	check(StoryRunner.ended and not StoryRunner.busy and dialogue_done == done_before and node_id == "fd_npc2_a",
		"전투 패배 → 대화 끝 (dialogue_ended 없음, 사망 처리는 화면 몫)")
	StoryRunner.combat_override = ""
	# 화면이 전투를 띄우는 경우: combat_requested → finish_combat
	await StoryRunner.start_dialogue("fd_npc2_a")
	StoryRunner.choose("fdc7")
	check(fights == ["enemy_test"] and StoryRunner.busy, "combat_requested(enemy_test) 후 결과 대기")
	StoryRunner.finish_combat("win")
	await get_tree().process_frame
	check(node_id == "fd_npc2_win" and not StoryRunner.busy, "finish_combat(win) → 대화 계속")
	await StoryRunner.continue_story()

	# ---------- 기능 카드: 효과 카드(보이지 않고 효과만) → 조건 분기 카드(맞으면 / 아니면)
	GameState.inventory = []
	GameState.set_flag("fx_done", false)
	await StoryRunner.start_dialogue("fd_npc2_a")
	await StoryRunner.choose("fdc8")
	check(node_id == "fd_npc2_yes" and GameState.item_count("water") == 1 and GameState.has_flag("fx_done"),
		"효과 카드(물+1, 플래그) → 조건 분기 맞음 → 맞으면 카드 (%s)" % node_id)
	await StoryRunner.continue_story()
	await StoryRunner.start_dialogue("fd_npc2_br")
	check(node_id == "fd_npc2_yes", "조건 분기 카드에서 바로 시작해도 판정")
	await StoryRunner.continue_story()
	GameState.inventory = []
	await StoryRunner.start_dialogue("fd_npc2_br")
	check(node_id == "fd_npc2_no", "물이 없으면 → 아니면 카드")
	await StoryRunner.continue_story()

	# ---------- 대화 횟수 count:talk (첫 대화 = 0, 같은 시작 노드마다 셈, 회차 저장에 들어감)
	GameState.reset_run()
	await StoryRunner.start_dialogue("fd_npc1_a")
	check(GameState.get_count("talk") == 0 and StoryRunner.Expr.evaluate("count:talk==0", GameState), "첫 대화: count:talk == 0")
	await StoryRunner.start_dialogue("fd_npc1_a")
	check(GameState.get_count("talk") == 1 and StoryRunner.Expr.evaluate("count:talk==1", GameState), "두 번째: count:talk == 1 (반복 대사)")
	await StoryRunner.start_dialogue("fd_npc2_a")
	check(GameState.get_count("talk") == 0, "다른 대화는 따로 셈 (npc2 첫 대화 = 0)")
	var saved := GameState.run_to_dict()
	GameState.run_from_dict(JSON.parse_string(JSON.stringify(saved)))
	await StoryRunner.start_dialogue("fd_npc1_a")
	check(GameState.get_count("talk") == 2, "저장·불러오기 뒤에도 이어짐 (npc1 세 번째 = 2)")
	GameState.reset_run()
	await StoryRunner.start_dialogue("fd_npc1_a")
	check(GameState.get_count("talk") == 0, "새 회차면 처음부터")

	# ---------- 대화 시작 카드 (kind=start): 위에서부터 조건이 맞는 첫 길, 없으면 그 외
	DataLoader.nodes["tst_start"] = {"node_id": "tst_start", "kind": "start", "speaker_id": "", "text": "", "on_enter": "",
		"next_node": "fd_npc2_a", "pages": [], "routes": [
			{"condition": "count:talk==0", "next_node": "fd_npc1_a"},
			{"condition": "flag:tst_x", "next_node": "fd_npc1_b"}]}
	GameState.reset_run()
	await StoryRunner.start_dialogue("tst_start")
	check(node_id == "fd_npc1_a", "시작 카드: 첫 대화 → 길 1 (%s)" % node_id)
	await StoryRunner.start_dialogue("tst_start")
	check(node_id == "fd_npc2_a", "두 번째 대화, 플래그 없음 → 그 외 (%s)" % node_id)
	GameState.set_flag("tst_x", true)
	await StoryRunner.start_dialogue("tst_start")
	check(node_id == "fd_npc1_b", "플래그가 켜지면 → 길 2 (%s)" % node_id)
	DataLoader.nodes.erase("tst_start")
	await StoryRunner.start_dialogue("cat_start")
	check(node_id == "fd_cat_a", "고양이 대화 시작 카드 → fd_cat_a")

	# ---------- 전투 중 대화 (전투 화면의 '대화' 버튼): 조건 combat:, 효과 endcombat:, 하던 대화 상태 되돌리기
	check(DataLoader.npc_dialogue.get("enemy_test", "") == "monster_test_start" and DataLoader.npc_dialogue.get("char_cat", "") == "cat_start",
		"NPC → 대화 시작 카드 (몬스터 enemy_test, 고양이)")
	await StoryRunner.start_dialogue("monster_test_start")
	check(node_id == "monster_test_idle", "전투 밖에서 말 걸면 → 그 외 길")
	await StoryRunner.continue_story()
	await StoryRunner.start_dialogue("fd_npc2_a")          # 대화 중에 전투가 시작됐다고 치고
	var outer := StoryRunner.save_state()
	GameState.combat_enemy = "enemy_test"
	check(StoryRunner.Expr.evaluate("combat:any & combat:enemy_test & !combat:char_cat", GameState), "조건 combat:any / combat:상대")
	StoryRunner.combat_end = ""
	await StoryRunner.start_dialogue("monster_test_start")
	check(node_id == "monster_test_combat", "전투 중에 말 걸면 → '전투 중이다' 길 (%s)" % node_id)
	await StoryRunner.choose("monster_test_c1")
	check(StoryRunner.combat_end == "win" and StoryRunner.ended, "endcombat:win → 대화 끝, 전투 화면이 읽을 값 win")
	StoryRunner.restore_state(outer)
	check(GameState.node_id == "fd_npc2_a" and not StoryRunner.ended, "전투 중 대화가 끝나면 하던 대화(fd_npc2_a)로 되돌림")
	# 전투 중 대화에서 전투 선택지 = 대화를 끝내고 하던 전투로 (전투 안의 전투 없음)
	var fights_before := fights.size()
	DataLoader.nodes["tct_a"] = {"node_id": "tct_a", "kind": "", "speaker_id": "", "text": "x", "next_node": "", "on_enter": "", "pages": []}
	DataLoader.choices_by_node["tct_a"] = [{"choice_id": "tct_c", "node_id": "tct_a", "text": "싸운다", "condition": "", "show_mode": "",
		"cost": "", "effects": "", "next_node": "EXIT", "type": "combat", "check": "enemy_test", "dc": 0, "mod": 0, "fail_effects": "", "fail_next": "EXIT"}]
	await StoryRunner.start_dialogue("tct_a")
	await StoryRunner.choose("tct_c")
	check(fights.size() == fights_before and StoryRunner.ended, "전투 중 대화의 '싸운다' → 새 전투 없이 대화 끝")
	DataLoader.nodes.erase("tct_a")
	DataLoader.choices_by_node.erase("tct_a")
	GameState.combat_enemy = ""
	check(not StoryRunner.Expr.evaluate("combat:any", GameState), "전투가 끝나면 combat:any 거짓")


func _fresh_to_d() -> void:
	ending = ""
	await StoryRunner.start_episode("ep_test1")
	await StoryRunner.continue_story()
	await StoryRunner.choose("c_a4")


func _dice(choice_id: String) -> Dictionary:
	for e in entries:
		if e.choice.choice_id == choice_id:
			return e.get("dice", {})
	return {}


func _ids() -> Array:
	return entries.map(func(e): return e.choice.choice_id)


func _enabled(choice_id: String) -> bool:
	for e in entries:
		if e.choice.choice_id == choice_id:
			return e.enabled
	return false


func check(ok: bool, label: String) -> void:
	if ok:
		_pass += 1
		print("ok   " + label)
	else:
		_fail += 1
		print("FAIL " + label)
