extends Node
## 스토리 진행기: 현재 노드 진행, 선택지 조건 판정, 효과 적용, 시그널 발신.
## UI는 시그널을 받아 그리고, 입력만 choose() / continue_story() / use_item() / choose_discard() 로 돌려준다.

const Expr = preload("res://core/expr.gd")
const WorldContext = preload("res://core/world_context.gd")

## 노드 표시: node(Dictionary), 화자 이름
signal node_shown(node: Dictionary, speaker_name: String)
## 선택지 목록: [{ "choice": Dictionary, "enabled": bool, "dice": Dictionary }] — hide 조건 미충족은 빠져 있음.
## dice 는 type=dice 선택지에만 있음 (dice_preview() 결과).
## 선택지가 없는 노드면 빈 배열 (UI는 '계속' 버튼을 띄운다)
signal choices_shown(entries: Array)
## 시스템 메시지 (획득·버림 등)
signal message(text: String)
signal messages_cleared
signal ending_reached(ending_id: String)
## 인벤토리가 가득 참: UI는 버릴 칸을 고르게 하고 choose_discard(slot 또는 -1)을 호출해야 한다.
signal inventory_full(item_id: String, amount: int)
## 주사위 판정 결과 (dice_preview() 내용 + roll, total, success). 효과 적용 전에 발신.
signal dice_rolled(result: Dictionary)
signal _discard_chosen(slot: int)

const DICE_SIDES := 20

var busy := false    # 효과 처리 중 (입력 무시)
## 테스트용: 비어 있지 않으면 주사위 대신 앞에서부터 꺼내 쓴다.
var forced_rolls: Array[int] = []
var ended := false

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
	ended = false
	busy = true
	await _goto(ep.start_node)
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
		result.success = result.total >= result.dc
		dice_rolled.emit(result)
		if not result.success:
			effects = c.fail_effects
			next = c.fail_next
	var redirect := await _apply_effects(Expr.parse_effects(effects))
	if not ended:
		var forced := _check_stats()
		await _goto(forced if forced != "" else (redirect if redirect != "" else next))
	busy = false


## dice 선택지의 판정 정보: 능력치, 목표값, 보정치 내역, 성공 확률.
## { ability, ability_name, dc, mod, parts: [{label, value}], chance: 0.0~1.0 }
func dice_preview(c: Dictionary) -> Dictionary:
	var ability: String = c.get("check", "")
	var parts := []
	parts.append({"label": DataLoader.ability_name(ability), "value": GameState.get_ability(ability)})
	var seen := {}
	for slot in GameState.inventory:
		if seen.has(slot.id):
			continue
		seen[slot.id] = true
		for b in DataLoader.items.get(slot.id, {}).get("dice_bonus", []):
			if b.ability == ability or b.ability == "all":
				parts.append({"label": DataLoader.item_name(slot.id), "value": int(b.value)})
	if int(c.get("mod", 0)) != 0:
		parts.append({"label": "상황", "value": int(c.mod)})
	var mod := 0
	for p in parts:
		mod += p.value
	var dc := int(c.get("dc", 0))
	# TODO(기획 확인): 1·20 대실패/대성공 규칙 없음. 필요하면 여기와 choose() 에 추가.
	var need := dc - mod   # 이 값 이상이 나와야 성공
	var chance := clampf(float(DICE_SIDES + 1 - need) / DICE_SIDES, 0.0, 1.0)
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
	if busy or ended or slot < 0 or slot >= GameState.inventory.size():
		return
	var item: Dictionary = DataLoader.items.get(GameState.inventory[slot].id, {})
	if item.get("use_effects", "") == "":
		return
	busy = true
	messages_cleared.emit()
	message.emit("사용: %s" % item.name)
	var redirect := await _apply_effects(Expr.parse_effects(item.use_effects))
	if not ended:
		var forced := _check_stats()
		if forced != "" or redirect != "":
			await _goto(forced if forced != "" else redirect)
		else:
			_show_current()
			SaveManager.save_episode()
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
		if forced != "":
			target = forced
		elif redirect != "":
			target = redirect
		else:
			_show_current()
			SaveManager.save_episode()
			return
	if target == "" and not ended:
		push_error("[StoryRunner] 이동할 노드가 비어 있음 (현재 %s)" % GameState.node_id)


## 스탯 규칙. 이동이 필요하면 대상("END:x" 또는 node_id)을, 아니면 "" 을 돌려준다.
func _check_stats() -> String:
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
	return redirect


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
		GameState.change_stat("time", "-", time_cost)
	if not found:
		message.emit("아무것도 찾지 못했다.")
