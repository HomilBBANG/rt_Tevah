extends Node
## 스토리 진행기: 현재 노드 진행, 선택지 조건 판정, 효과 적용, 시그널 발신.
## UI는 시그널을 받아 그리고, 입력만 choose() / continue_story() / use_item() / choose_discard() 로 돌려준다.

const Expr = preload("res://core/expr.gd")
const WorldContext = preload("res://core/world_context.gd")

## 노드 표시: node(Dictionary), 화자 이름
signal node_shown(node: Dictionary, speaker_name: String)
## 선택지 목록: [{ "choice": Dictionary, "enabled": bool, "dice": Dictionary, "combat": Dictionary }] — hide 조건 미충족은 빠져 있음.
## dice 는 type=dice 선택지에만 있음 (dice_preview() 결과). combat 은 type=combat 에만 ({enemy_id, enemy_name}).
## 선택지가 없는 노드면 빈 배열 (UI는 '계속' 버튼을 띄운다)
signal choices_shown(entries: Array)
## 시스템 메시지 (획득·버림 등)
signal message(text: String)
signal messages_cleared
signal ending_reached(ending_id: String)
## 필드 대화가 EXIT 에 닿음 → 필드로 복귀
signal dialogue_ended
## 인벤토리가 가득 참: UI는 버릴 칸을 고르게 하고 choose_discard(slot 또는 -1)을 호출해야 한다.
signal inventory_full(item_id: String, amount: int)
## 효과 save: 저장할 슬롯을 물어봄. 화면은 슬롯 선택 창을 띄우고 choose_save_slot(슬롯 또는 -1)을 부른다.
signal save_slot_requested
signal _save_slot_chosen(slot: int)
## 주사위 판정 결과 (dice_preview() 내용 + roll, total, success, critical). 효과 적용 전에 발신.
## critical: "success"(20, 대성공) / "fail"(1, 대실패) / "" — 1·20 은 합계와 무관하게 결과가 정해진다.
signal dice_rolled(result: Dictionary)
## combat 선택지: 전투를 띄워 달라는 요청. 화면은 전투를 띄우고 끝나면 finish_combat("win"/"fled"/"lose")를 부른다.
## win → effects·next_node, fled → fail_effects·fail_next, lose → 대화가 끝남(ended) — 사망 처리는 화면 몫.
signal combat_requested(enemy_id: String)
## 효과 move: 맵 이동 요청 (필드 화면이 받아서 대화가 끝난 뒤 이동). arrive = 도착 지점 id, 비면 P
signal travel_requested(map_id: String, arrive: String)
signal _combat_done(outcome: String)
signal _discard_chosen(slot: int)

const DICE_SIDES := 20

var busy := false    # 효과 처리 중 (입력 무시)
## 테스트용: 비어 있지 않으면 주사위 대신 앞에서부터 꺼내 쓴다.
var forced_rolls: Array[int] = []
## 테스트용: 0 보다 크면 슬롯을 묻지 않고 이 슬롯에 저장
var save_slot_override := 0
## 테스트용: 비어 있지 않으면 전투를 띄우지 않고 이 결과("win"/"fled"/"lose")로 처리
var combat_override := ""
var ended := false
## "episode" = 에피소드 진행 (엔딩·스탯 규칙·자동 저장) / "field" = 탐험 중 NPC 대화 (EXIT 로 끝)
var mode := "episode"

var _pending_episode := ""
var _pending_resume := false


# ---------------------------------------------------------------- 에피소드 시작/재개
func is_unlocked(episode_id: String) -> bool:
	var ep: Dictionary = DataLoader.episodes.get(episode_id, {})
	return Expr.evaluate(ep.get("unlock_condition", ""), WorldContext.new())


## 에피소드 선택 화면에서 호출 → 플레이 씬이 준비되면 launch()
func prepare(episode_id: String, resume: bool) -> void:
	_pending_episode = episode_id
	_pending_resume = resume


func launch() -> void:
	mode = "episode"
	if _pending_resume and SaveManager.load_episode(_pending_episode):
		ended = false
		busy = false
		_show_current()
		return
	await start_episode(_pending_episode)


func start_episode(episode_id: String) -> void:
	var ep: Dictionary = DataLoader.episodes.get(episode_id, {})
	if ep.is_empty():
		push_error("[StoryRunner] 없는 에피소드: %s" % episode_id)
		return
	SaveManager.delete_episode_save(episode_id)
	GameState.reset_for_episode(ep)
	GameState.talk_now = 0
	mode = "episode"
	ended = false
	busy = true
	await _goto(ep.start_node)
	busy = false


## 탐험 중 NPC 대화 시작. 게임 상태(인벤토리·플래그·능력치)는 그대로 쓰고, 대화가 EXIT 에 닿으면 dialogue_ended.
## 시그널을 받을 화면을 먼저 띄운 뒤 호출할 것.
func start_dialogue(node_id: String) -> void:
	GameState.begin_talk(node_id)   # 조건 count:talk = 이 대화를 전에 한 횟수
	mode = "field"
	ended = false
	busy = true
	messages_cleared.emit()
	await _goto(node_id)
	busy = false


# ---------------------------------------------------------------- 입력
func choose(choice_id: String) -> void:
	if busy or ended:
		return
	var c := _find_choice(choice_id)
	if c.is_empty() or not Expr.evaluate(c.condition, GameState):
		return
	busy = true
	messages_cleared.emit()
	var effects: String = c.effects
	var next: String = c.next_node
	if c.get("type", "normal") == "dice":
		var result := dice_preview(c)
		result.roll = _roll()
		result.total = result.roll + result.mod
		result.critical = "success" if result.roll == DICE_SIDES else ("fail" if result.roll == 1 else "")
		result.success = result.critical == "success" or (result.critical == "" and result.total >= result.dc)
		dice_rolled.emit(result)
		if not result.success:
			effects = c.fail_effects
			next = c.fail_next
	elif c.get("type", "normal") == "combat":
		var outcome := await _fight(c.check)
		if outcome == "lose":
			ended = true
			busy = false
			return
		if outcome != "win":
			effects = c.fail_effects
			next = c.fail_next
	var redirect := await _apply_effects(Expr.parse_effects(effects))
	if not ended:
		var forced := _check_stats()
		await _goto(forced if forced != "" else (redirect if redirect != "" else next))
	busy = false


## combat 선택지: 전투 결과 "win" / "fled" / "lose"
func _fight(enemy_id: String) -> String:
	if combat_override != "":
		return combat_override
	if mode != "field":
		push_error("[StoryRunner] combat 선택지는 필드 대화에서만: %s" % enemy_id)
		return "fled"
	combat_requested.emit(enemy_id)
	return await _combat_done


## 화면이 combat_requested 로 띄운 전투가 끝남
func finish_combat(outcome: String) -> void:
	_combat_done.emit(outcome)


## dice 선택지의 판정 정보: 능력치, 목표값, 보정치 내역, 성공 확률.
## { ability, ability_name, dc, mod, parts: [{label, value}], chance: 0.0~1.0 }
func dice_preview(c: Dictionary) -> Dictionary:
	var ability: String = c.get("check", "")
	var parts := []
	parts.append({"label": DataLoader.ability_name(ability), "value": GameState.get_ability(ability)})
	var seen := {}
	# 소지품 + 장착한 장비
	for id in GameState.inventory.map(func(s): return s.id) + GameState.equipment.values():
		if seen.has(id):
			continue
		seen[id] = true
		for b in DataLoader.items.get(id, {}).get("dice_bonus", []):
			if b.ability == ability or b.ability == "all":
				parts.append({"label": DataLoader.item_name(id), "value": int(b.value)})
	if int(c.get("mod", 0)) != 0:
		parts.append({"label": "상황", "value": int(c.mod)})
	var mod := 0
	for p in parts:
		mod += p.value
	var dc := int(c.get("dc", 0))
	# 1(대실패)·20(대성공) 때문에 확률은 항상 1/20 ~ 19/20
	var need := dc - mod   # 이 값 이상이 나와야 성공
	var chance := clampf(float(DICE_SIDES + 1 - need) / DICE_SIDES, 1.0 / DICE_SIDES, (DICE_SIDES - 1.0) / DICE_SIDES)
	return {"ability": ability, "ability_name": DataLoader.ability_name(ability), "dc": dc,
		"mod": mod, "parts": parts, "chance": chance}


func _roll() -> int:
	if not forced_rolls.is_empty():
		return forced_rolls.pop_front()
	return randi_range(1, DICE_SIDES)


## 선택지 없는 노드에서 '계속'
func continue_story() -> void:
	if busy or ended:
		return
	var node: Dictionary = DataLoader.nodes.get(GameState.node_id, {})
	if node.is_empty() or not DataLoader.choices_by_node.get(GameState.node_id, []).is_empty():
		return
	busy = true
	messages_cleared.emit()
	await _goto(node.next_node)
	busy = false


func use_item(slot: int) -> void:
	# 필드에서는 대화 밖에서도(ended) 아이템을 쓸 수 있다
	var outside := mode == "field" and ended
	if busy or (ended and not outside) or slot < 0 or slot >= GameState.inventory.size():
		return
	var item: Dictionary = DataLoader.items.get(GameState.inventory[slot].id, {})
	if item.get("use_effects", "") == "":
		return
	busy = true
	messages_cleared.emit()
	message.emit("사용: %s" % item.name)
	var redirect := await _apply_effects(Expr.parse_effects(item.use_effects))
	if outside:
		busy = false
		return
	if not ended:
		var forced := _check_stats()
		if forced != "" or redirect != "":
			await _goto(forced if forced != "" else redirect)
		else:
			_show_current()
			SaveManager.save_episode()
	busy = false


## 전투 중 아이템 사용: 대화 진행 상태(busy·ended)와 상관없이 효과만 적용한다 (goto 무시).
## 대화 선택지로 시작한 전투에서는 choose() 가 전투 결과를 기다리는 중이라 use_item() 을 쓸 수 없다.
func use_item_in_combat(slot: int) -> bool:
	if slot < 0 or slot >= GameState.inventory.size():
		return false
	var item: Dictionary = DataLoader.items.get(GameState.inventory[slot].id, {})
	if item.get("use_effects", "") == "":
		return false
	message.emit("사용: %s" % item.name)
	await _apply_effects(Expr.parse_effects(item.use_effects))
	return true


## 탐험 필드에 들어옴: 대화 밖 상태 (아이템 사용·효과 실행 가능)
func enter_field() -> void:
	mode = "field"
	ended = true
	busy = false


## 대화 밖(필드 조사·베이스캠프 행동)에서 효과 실행. goto 는 무시. 메시지는 message 시그널로.
func run_effects(text: String) -> void:
	enter_field()
	busy = true
	await _apply_effects(Expr.parse_effects(text))
	busy = false


## 인벤토리 초과 시 버릴 칸 (-1 = 새 아이템 포기). inventory_full 을 받은 뒤 호출.
func choose_discard(slot: int) -> void:
	_discard_chosen.emit(slot)


func current_node() -> Dictionary:
	return DataLoader.nodes.get(GameState.node_id, {})


# ---------------------------------------------------------------- 진행
func _goto(target: String) -> void:
	var hops := 0
	while target != "" and not ended:
		hops += 1
		if hops > 100:
			push_error("[StoryRunner] 노드 이동이 100번 넘게 이어짐 (goto 순환?): %s" % target)
			return
		if target == "EXIT":
			ended = true
			dialogue_ended.emit()
			return
		if target.begins_with("END:"):
			_finish(target.substr(4))
			return
		var node: Dictionary = DataLoader.nodes.get(target, {})
		if node.is_empty():
			push_error("[StoryRunner] 없는 노드: %s" % target)
			message.emit("[오류] 없는 노드: %s" % target)
			return
		GameState.node_id = target
		var redirect := await _apply_effects(Expr.parse_effects(node.on_enter))
		if ended:
			return
		var forced := _check_stats()
		var kind: String = node.get("kind", "")
		if forced != "":
			target = forced
		elif redirect != "":
			target = redirect
		elif kind == "effect":
			# 효과 카드: on_enter 만 실행하고 화면에 보이지 않은 채 다음으로
			target = node.next_node
		elif kind == "start":
			# 대화 시작 카드: 길을 위에서부터 보고 조건이 맞는 첫 길로, 없으면 '그 외' (next_node)
			target = node.next_node
			for r in node.get("routes", []):
				if Expr.evaluate(r.get("condition", ""), GameState):
					target = r.get("next_node", "")
					break
		elif kind == "branch":
			# 조건 분기 카드: 맞으면 next_node, 아니면 fail_next
			target = node.next_node if Expr.evaluate(node.get("condition", ""), GameState) else node.get("fail_next", "")
		else:
			_show_current()
			SaveManager.save_episode()
			return
	if target == "" and not ended:
		push_error("[StoryRunner] 이동할 노드가 비어 있음 (현재 %s)" % GameState.node_id)


## 스탯 규칙. 이동이 필요하면 대상("END:x" 또는 node_id)을, 아니면 "" 을 돌려준다.
func _check_stats() -> String:
	# TODO(기획 §5): 탐험 중 생존 파라미터(배고픔·수면·위생·멘탈)가 들어오면 필드 대화에도 연결
	if mode == "field":
		return ""
	var ep: Dictionary = DataLoader.episodes.get(GameState.episode_id, {})
	if GameState.get_stat("hp") <= 0:
		return "END:" + ep.get("death_ending", "")
	if GameState.get_stat("sanity") <= 0:
		return "END:" + ep.get("madness_ending", "")
	if GameState.get_stat("time") <= 0 and not GameState.timed_out:
		GameState.timed_out = true
		return ep.get("timeout_node", "")
	return ""


func _finish(ending_id: String) -> void:
	ended = true
	var ending: Dictionary = DataLoader.endings.get(ending_id, {})
	if ending.is_empty():
		push_error("[StoryRunner] 없는 엔딩: %s" % ending_id)
	for f in ending.get("world_flags_set", []):
		GameState.set_wflag(f)
	SaveManager.save_world()
	SaveManager.delete_episode_save(GameState.episode_id)
	ending_reached.emit(ending_id)


func _show_current() -> void:
	var node := current_node()
	node_shown.emit(node, DataLoader.character_name(node.get("speaker_id", "")))
	var entries := []
	for c in DataLoader.choices_by_node.get(GameState.node_id, []):
		var ok := Expr.evaluate(c.condition, GameState)
		var mode: String = c.show_mode if c.show_mode != "" else "gray"
		if not ok and mode == "hide":
			continue
		var entry := {"choice": c, "enabled": ok}
		if c.get("type", "normal") == "dice":
			entry.dice = dice_preview(c)
		elif c.get("type", "normal") == "combat":
			entry.combat = {"enemy_id": c.check, "enemy_name": DataLoader.enemies.get(c.check, {}).get("name", c.check)}
		entries.append(entry)
	choices_shown.emit(entries)


func _find_choice(choice_id: String) -> Dictionary:
	for c in DataLoader.choices_by_node.get(GameState.node_id, []):
		if c.choice_id == choice_id:
			return c
	return {}


# ---------------------------------------------------------------- 효과
## 효과를 순서대로 적용하고, goto 가 있었으면 마지막 goto 대상을 돌려준다.
func _apply_effects(effects: Array) -> String:
	var redirect := ""
	for e in effects:
		match e.type:
			"item":
				if e.amount > 0:
					await _give_item(e.id, e.amount)
				else:
					var removed := GameState.remove_item(e.id, -e.amount)
					if removed < -e.amount:
						push_warning("[StoryRunner] %s 를 %d개 빼려 했으나 %d개만 있었음" % [e.id, -e.amount, removed])
			"stat":
				GameState.change_stat(e.stat, e.op, e.value)
			"surv":
				GameState.change_survival(e.param, e.op, e.value)
				var p := GameState.survival_def(e.param)
				message.emit("%s %s%d" % [p.get("name", e.param), "" if e.op == "=" else e.op, e.value])
			"abil":
				GameState.change_ability(e.ability, e.op, e.value)
				message.emit("%s %s%d" % [DataLoader.ability_name(e.ability), "" if e.op == "=" else e.op, e.value])
			"setflag":
				GameState.set_flag(e.id, true)
			"clearflag":
				GameState.set_flag(e.id, false)
			"setwflag":
				GameState.set_wflag(e.id)
				SaveManager.save_world()
			"loot":
				await _do_loot(e.id)
			"goto":
				redirect = e.id
			"save":
				await _save_run()
			"move":
				if mode == "field":
					travel_requested.emit(e.map, e.arrive)
				else:
					push_warning("[StoryRunner] move:%s — 맵 이동은 필드에서만" % e.map)
			"status":
				if GameState.set_status(e.id, e.op == "+"):
					var nm: String = DataLoader.status_effects.get(e.id, {}).get("name", e.id)
					message.emit(("%s 상태가 되었다." if e.op == "+" else "%s 이(가) 나았다.") % nm)
			"restore":
				var restored := GameState.restore_limb(e.id)
				if restored.is_empty():
					push_warning("[StoryRunner] restore:%s — 잘린 부위가 없음" % e.id)
				else:
					message.emit("%s 이(가) 돌아왔다." % ", ".join(restored))
	return redirect


## 효과 save: 베이스캠프에서만 회차 저장 (고양이에게 저장하기 등)
func _save_run() -> void:
	if not SaveManager.can_save_run():
		message.emit("여기서는 저장할 수 없다.")
		return
	var slot := save_slot_override
	if slot <= 0:
		save_slot_requested.emit()
		slot = await _save_slot_chosen
	if slot > 0:
		SaveManager.save_run(slot)
		message.emit("슬롯 %d 에 저장했다.  (%d일차 %s)" % [slot, GameState.day(), GameState.clock_text()])
	else:
		message.emit("저장하지 않았다.")


## 저장 슬롯 선택 결과 (-1 = 저장 안 함). save_slot_requested 를 받은 뒤 호출.
func choose_save_slot(slot: int) -> void:
	_save_slot_chosen.emit(slot)


func _give_item(item_id: String, amount: int) -> void:
	var name := DataLoader.item_name(item_id)
	var left := GameState.add_item(item_id, amount)
	if left < amount:
		message.emit("획득: %s x%d" % [name, amount - left])
	while left > 0:
		inventory_full.emit(item_id, left)
		var slot: int = await _discard_chosen
		if slot < 0 or slot >= GameState.inventory.size():
			message.emit("포기: %s x%d" % [name, left])
			return
		var dropped := GameState.remove_slot(slot)
		message.emit("버림: %s x%d" % [DataLoader.item_name(dropped.id), dropped.count])
		var before := left
		left = GameState.add_item(item_id, left)
		if left < before:
			message.emit("획득: %s x%d" % [name, before - left])


func _do_loot(spot_id: String) -> void:
	var rows: Array = DataLoader.loot_by_spot.get(spot_id, [])
	if rows.is_empty():
		push_error("[StoryRunner] 없는 탐색 지점: %s" % spot_id)
		return
	# TODO(기획 확인): 한 지점의 소요 시간 = 그 지점 행들의 time_cost 합계, 성공 여부와 무관하게 차감.
	var time_cost := 0
	var found := false
	for r in rows:
		time_cost += r.time_cost
		if randf() * 100.0 < float(r.chance):
			found = true
			await _give_item(r.item_id, r.amount)
	if time_cost > 0:
		if mode == "field":
			GameState.advance_time(time_cost)   # 탐험: 게임 시계가 흐름 (§4)
		else:
			GameState.change_stat("time", "-", time_cost)
	if not found:
		message.emit("아무것도 찾지 못했다.")
