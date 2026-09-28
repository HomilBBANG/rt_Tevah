extends Node
## ep_test1 / ep_test2 더미 데이터로 StoryRunner 를 처음부터 엔딩까지 돌려보는 통합 테스트. 실행:
##   Godot_v4.7-stable_win64_console.exe --headless --path . res://tests/test_story.tscn
## 저장은 user://test_saves/ 에 하므로 실제 세이브는 건드리지 않는다.
## 더미 데이터(tools/sheets/content.xlsx)의 ID에 의존한다.

var node_id := ""
var entries: Array = []
var messages: Array[String] = []
var ending := ""
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
	check(GameState.inventory.size() == 8, "8칸 가득 (%d)" % GameState.inventory.size())
	check(GameState.item_count("junk") == 7 and GameState.item_count("bandage") == 0 and GameState.item_count("knife") == 1,
		"붕대 버리고 잡동사니 7개, 칼 유지")
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
	check(GameState.item_count("pill") == 1 and GameState.item_count("junk") == 6, "알약 획득 (잡동사니 1 버림)")
	check(_enabled("c_d4"), "복합조건 (has:pill) 활성")
	var pill_slot := GameState.inventory.find_custom(func(s): return s.id == "pill")
	await StoryRunner.use_item(pill_slot)
	check(GameState.item_count("pill") == 0 and node_id == "t1_d", "알약 사용 → 소모")
	check(not _enabled("c_d4"), "알약 소모 후 복합조건 다시 비활성")

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
	check(node_id == "t2_a" and GameState.item_count("knife") == 0, "ep_test2 시작 (인벤토리 초기화)")
	await StoryRunner.choose("c2_a1")
	check(ending == "end_t2_clear", "ep_test2 클리어")


func _fresh_to_d() -> void:
	ending = ""
	await StoryRunner.start_episode("ep_test1")
	await StoryRunner.continue_story()
	await StoryRunner.choose("c_a4")


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
