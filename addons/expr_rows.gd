@tool
extends VBoxContainer
## 조건·효과 만들기 (직접 입력 대신 고르기). 문자열 하나를 줄 목록으로 보여 주고, 고칠 때마다 changed(문자열).
##   mode "effect": 효과 줄들을 ; 로 이음      예) item:+food*2;setflag:met
##   mode "cond":   조건 줄들을 & (모두) 또는 | (하나라도) 로 이음   예) has:knife & !flag:met
## 문법은 core/expr.gd · tools/xlsx_to_json.py 와 같다. 괄호처럼 줄로 나타낼 수 없는 식은 '직접 입력' 칸으로만 고친다.
##
## lookups (ToolCommon.load_lookups()): items, survival, abilities, parts, loot, flags, wflags, traits — [[id, 이름], ...] 또는 [id, ...]

signal changed(text: String)

const EFFECTS := [
	["item_add", "아이템 얻기", ["item", "amount"]],
	["item_remove", "아이템 잃기", ["item", "amount"]],
	["setflag", "플래그 켜기", ["flag"]],
	["clearflag", "플래그 끄기", ["flag"]],
	["setwflag", "월드 플래그 켜기 (회차가 바뀌어도 남음)", ["wflag"]],
	["surv", "생존 수치 바꾸기", ["surv", "op_change", "num"]],
	["abil", "능력치 바꾸기", ["abil", "op_change", "num"]],
	["restore", "잘린 팔다리 복구", ["part_all"]],
	["status_add", "상태이상 걸기", ["status"]],
	["status_remove", "상태이상 풀기", ["status"]],
	["trait_add", "특성 얻기 (사건·거래, 다음 회차에도 남음)", ["trait_pick"]],
	["trait_remove", "특성 잃기", ["trait_pick"]],
	["endcombat", "전투 끝내기 (전투 중 대화에서)", ["combat_end"]],
	["loot", "아이템 굴리기 (Loot 표)", ["loot"]],
	["save", "저장하기 (베이스캠프에서만)", []],
	["move", "맵 이동 (필드 대화·아이템)", ["dest"]],
	["stat", "스탯 바꾸기 (1단계 에피소드용)", ["stat", "op_change", "num"]],
]
const CONDS := [
	["has", "아이템을 가지고 있다", ["item", "atleast"]],
	["not_has", "아이템이 없다", ["item"]],
	["flag", "플래그가 켜져 있다", ["flag"]],
	["not_flag", "플래그가 꺼져 있다", ["flag"]],
	["wflag", "월드 플래그가 켜져 있다", ["wflag"]],
	["not_wflag", "월드 플래그가 꺼져 있다", ["wflag"]],
	["surv", "생존 수치", ["surv", "op_cmp", "num"]],
	["abil", "능력치", ["abil", "op_cmp", "num"]],
	["cut", "팔다리가 잘렸다", ["part_any"]],
	["not_cut", "팔다리가 잘리지 않았다", ["part_any"]],
	["combat", "전투 중이다 (대화 버튼으로 말을 걸었을 때)", ["combat_enemy"]],
	["status", "상태이상에 걸려 있다", ["status"]],
	["not_status", "상태이상에 걸려 있지 않다", ["status"]],
	["count", "대화 횟수 · 죽은 횟수 · 회차 수", ["count_kind", "op_cmp", "num"]],
	["trait", "특성이 있다 (player.xlsx Traits)", ["trait"]],
	["stat", "스탯 (1단계 에피소드용)", ["stat", "op_cmp", "num"]],
]
const OP_CHANGE := [["+", "+ 늘리기"], ["-", "- 줄이기"], ["=", "= 정하기"]]
const OP_CMP := [["<", "보다 작다 (<)"], ["<=", "이하 (<=)"], [">=", "이상 (>=)"], [">", "보다 크다 (>)"], ["==", "같다 (==)"]]
const STATS := [["hp", "hp"], ["sanity", "sanity"], ["time", "time"]]
const COUNT_KINDS := [["talk", "이 대화를 한 횟수 (처음 = 0)"], ["death", "죽은 횟수"], ["run", "회차 수"]]

var mode := "effect"
var lookups := {}
var _rows: Array = []        # [{kind, p: {...}}]
var _join := "&"
var _text := ""
var _raw := false            # 줄로 나타낼 수 없음 → 직접 입력만
var _raw_edit: LineEdit
var _show_raw := false


func setup(p_mode: String, text: String, p_lookups: Dictionary) -> Node:
	mode = p_mode
	lookups = p_lookups
	size_flags_horizontal = SIZE_EXPAND_FILL
	_load_text(text)
	_render()
	return self


## 지금 내용 (문자열)
func get_text() -> String:
	return _text


# ---------------------------------------------------------------- 문자열 ↔ 줄
func _load_text(text: String) -> void:
	_text = text.strip_edges()
	_rows = []
	_raw = false
	_join = "&"
	if _text == "":
		return
	var parts: PackedStringArray
	if mode == "effect":
		parts = _text.split(";", false)
	else:
		if "(" in _text or ")" in _text or ("&" in _text and "|" in _text):
			_raw = true
			return
		_join = "|" if "|" in _text else "&"
		parts = _text.split(_join, false)
	for part in parts:
		var row := _parse_effect(part.strip_edges()) if mode == "effect" else _parse_cond(part.strip_edges())
		if row.is_empty():
			_raw = true
			_rows = []
			return
		_rows.append(row)


func _to_text() -> String:
	var out := PackedStringArray()
	for r in _rows:
		var t := _row_text(r)
		if t != "":
			out.append(t)
	return ";".join(out) if mode == "effect" else (" %s " % _join).join(out)


func _row_text(r: Dictionary) -> String:
	var p: Dictionary = r.p
	match r.kind:
		"item_add", "item_remove":
			if p.item == "":
				return ""
			return "item:%s%s%s" % ["+" if r.kind == "item_add" else "-", p.item, "*%d" % p.amount if p.amount > 1 else ""]
		"setflag", "clearflag", "setwflag", "restore", "loot", "endcombat", "combat":
			var v: String = p.get(_params_of(r.kind)[0], "")
			return "" if v == "" else "%s:%s" % [r.kind, v]
		"save":
			return "save"
		"move":
			return "" if p.dest == "" else "move:" + p.dest
		"status_add", "status_remove":
			return "" if p.status == "" else "status:%s%s" % ["+" if r.kind == "status_add" else "-", p.status]
		"status", "not_status":
			return "" if p.status == "" else "%sstatus:%s" % ["!" if r.kind == "not_status" else "", p.status]
		"trait_add", "trait_remove":
			return "" if p.trait_pick == "" else "trait:%s%s" % ["+" if r.kind == "trait_add" else "-", p.trait_pick]
		"has":
			if p.item == "":
				return ""
			return "has:%s%s" % [p.item, ">=%d" % p.atleast if p.atleast > 1 else ""]
		"not_has":
			return "" if p.item == "" else "!has:" + p.item
		"flag", "wflag", "trait":
			var v: String = p.get(_params_of(r.kind)[0], "")
			return "" if v == "" else "%s:%s" % [r.kind, v]
		"not_flag", "not_wflag":
			var v: String = p.get(_params_of(r.kind)[0], "")
			return "" if v == "" else "!%s:%s" % [r.kind.substr(4), v]
		"cut", "not_cut":
			return "" if p.part_any == "" else "%scut:%s" % ["!" if r.kind == "not_cut" else "", p.part_any]
	# 이름 + 연산 + 숫자 (surv / abil / stat / count)
	var name_key: String = _params_of(r.kind)[0]
	var nm: String = p.get(name_key, "")
	if nm == "":
		return ""
	var op: String = p.get("op_change", p.get("op_cmp", ""))
	return "%s:%s%s%d" % [r.kind, nm, op, int(p.num)]


static var _re := {}

static func _rx(key: String, pattern: String) -> RegEx:
	if not _re.has(key):
		_re[key] = RegEx.create_from_string(pattern)
	return _re[key]


func _parse_effect(e: String) -> Dictionary:
	var m := _rx("item", "^item:([+-])(\\w+)(?:\\*(\\d+))?$").search(e)
	if m:
		return {"kind": "item_add" if m.get_string(1) == "+" else "item_remove",
			"p": {"item": m.get_string(2), "amount": maxi(1, m.get_string(3).to_int())}}
	m = _rx("simple", "^(setflag|clearflag|setwflag|restore|loot|endcombat):(\\w+)$").search(e)
	if m:
		return {"kind": m.get_string(1), "p": {_params_of(m.get_string(1))[0]: m.get_string(2)}}
	m = _rx("change", "^(surv|abil|stat):(\\w+)([+\\-=])(\\d+)$").search(e)
	if m:
		return {"kind": m.get_string(1), "p": {_params_of(m.get_string(1))[0]: m.get_string(2),
			"op_change": m.get_string(3), "num": m.get_string(4).to_int()}}
	if e == "save":
		return {"kind": "save", "p": {}}
	m = _rx("move", "^move:(\\w+(?:@\\w+)?)$").search(e)
	if m:
		return {"kind": "move", "p": {"dest": m.get_string(1)}}
	m = _rx("status_fx", "^status:([+-])(\\w+)$").search(e)
	if m:
		return {"kind": "status_add" if m.get_string(1) == "+" else "status_remove", "p": {"status": m.get_string(2)}}
	m = _rx("trait_fx", "^trait:([+-])(\\w+)$").search(e)
	if m:
		return {"kind": "trait_add" if m.get_string(1) == "+" else "trait_remove", "p": {"trait_pick": m.get_string(2)}}
	return {}


func _parse_cond(c: String) -> Dictionary:
	var m := _rx("has", "^(!?)has:(\\w+)(?:>=(\\d+))?$").search(c)
	if m:
		if m.get_string(1) == "!":
			return {} if m.get_string(3) != "" else {"kind": "not_has", "p": {"item": m.get_string(2)}}
		return {"kind": "has", "p": {"item": m.get_string(2), "atleast": maxi(1, m.get_string(3).to_int())}}
	m = _rx("flag", "^(!?)(flag|wflag|cut|status):(\\w+)$").search(c)
	if m:
		var k := m.get_string(2)
		var key: String = _params_of(k)[0]
		return {"kind": ("not_" if m.get_string(1) == "!" else "") + k, "p": {key: m.get_string(3)}}
	m = _rx("trait", "^trait:(\\w+)$").search(c)
	if m:
		return {"kind": "trait", "p": {"trait": m.get_string(1)}}
	m = _rx("combat", "^combat:(\\w+)$").search(c)
	if m:
		return {"kind": "combat", "p": {"combat_enemy": m.get_string(1)}}
	m = _rx("cmp", "^(surv|abil|stat|count):(\\w+)(>=|<=|==|>|<)(-?\\d+)$").search(c)
	if m:
		return {"kind": m.get_string(1), "p": {_params_of(m.get_string(1))[0]: m.get_string(2),
			"op_cmp": m.get_string(3), "num": m.get_string(4).to_int()}}
	return {}


func _catalog() -> Array:
	return EFFECTS if mode == "effect" else CONDS


func _params_of(kind: String) -> Array:
	for k in _catalog():
		if k[0] == kind:
			return k[2]
	for k in EFFECTS + CONDS:   # 다른 모드 이름 (파싱 중)
		if k[0] == kind:
			return k[2]
	return []


func _default_row(kind: String) -> Dictionary:
	var p := {}
	for param in _params_of(kind):
		match param:
			"amount", "atleast": p[param] = 1
			"num": p[param] = 0 if mode == "effect" else 30
			"op_change": p[param] = "+"
			"op_cmp": p[param] = "<" if kind == "surv" else ">="
			_:
				var opts := _options(param)
				p[param] = opts[0][0] if not opts.is_empty() and not param in ["flag", "wflag", "trait"] else ""
	return {"kind": kind, "p": p}


func _options(param: String) -> Array:
	match param:
		"item": return lookups.get("items", [])
		"surv": return lookups.get("survival", [])
		"abil": return lookups.get("abilities", [])
		"part_all": return [["all", "잘린 곳 모두"]] + lookups.get("parts", [])
		"part_any": return [["any", "아무 팔다리나"]] + lookups.get("parts", [])
		"loot": return lookups.get("loot", [])
		"status": return lookups.get("statuses", [])
		"trait_pick": return lookups.get("trait_list", [])
		"combat_end": return [["win", "상대가 물러남 (이긴 것과 같음 — 맵에서 사라짐)"], ["flee", "빠져나옴 (도주와 같음)"]]
		"combat_enemy": return [["any", "아무 상대"]] + lookups.get("enemies", [])
		"dest": return lookups.get("dests", [])
		"stat": return STATS
		"count_kind": return COUNT_KINDS
		"op_change": return OP_CHANGE
		"op_cmp": return OP_CMP
	return []


# ---------------------------------------------------------------- 화면
func _render() -> void:
	for c in get_children():
		remove_child(c)
		c.queue_free()
	if _raw:
		var warn := Label.new()
		warn.text = "괄호 등이 섞인 식이라 목록으로 못 보여요. 아래 '직접 입력' 칸에서 고치세요."
		warn.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		warn.modulate = Color(1, 0.8, 0.5)
		add_child(warn)
	else:
		if mode == "cond" and _rows.size() >= 2:
			var join := OptionButton.new()
			join.fit_to_longest_item = false
			join.clip_text = true
			join.add_item("모두 맞아야 함 (그리고 &)")
			join.add_item("하나만 맞아도 됨 (또는 |)")
			join.select(0 if _join == "&" else 1)
			join.item_selected.connect(func(i):
				_join = "&" if i == 0 else "|"
				_emit())
			add_child(join)
		for i in _rows.size():
			add_child(_row_box(i))
		if _rows.is_empty():
			var none := Label.new()
			none.text = "(없음 — 아래에서 추가)" if mode == "effect" else "(조건 없음 = 항상)"
			none.modulate = Color(1, 1, 1, 0.5)
			add_child(none)
		var add := MenuButton.new()
		add.text = "＋ 효과 추가" if mode == "effect" else "＋ 조건 추가"
		add.flat = false
		add.tooltip_text = "추가할 종류를 고르세요"
		var pm := add.get_popup()
		var cat := _catalog()
		for k in cat.size():
			pm.add_item(cat[k][1], k)
		pm.id_pressed.connect(func(k):
			_rows.append(_default_row(cat[k][0]))
			_emit()
			_render())
		add_child(add)
	var raw_toggle := CheckButton.new()
	raw_toggle.text = "직접 입력 보기"
	raw_toggle.button_pressed = _show_raw or _raw
	raw_toggle.disabled = _raw
	raw_toggle.toggled.connect(func(on):
		_show_raw = on
		_raw_edit.visible = on)
	add_child(raw_toggle)
	_raw_edit = LineEdit.new()
	_raw_edit.text = _text
	_raw_edit.visible = _show_raw or _raw
	_raw_edit.placeholder_text = "예: item:+food;setflag:met" if mode == "effect" else "예: has:knife & !flag:met"
	_raw_edit.text_submitted.connect(_on_raw)
	_raw_edit.focus_exited.connect(func(): if _raw_edit.text != _text: _on_raw(_raw_edit.text))
	add_child(_raw_edit)


func _on_raw(t: String) -> void:
	_load_text(t)
	_text = t.strip_edges()
	changed.emit(_text)
	_render.call_deferred()


func _row_box(i: int) -> Control:
	var r: Dictionary = _rows[i]
	var box := VBoxContainer.new()
	var top := HBoxContainer.new()
	box.add_child(top)
	var kind := OptionButton.new()
	kind.fit_to_longest_item = false
	kind.clip_text = true
	kind.size_flags_horizontal = SIZE_EXPAND_FILL
	var cat := _catalog()
	for k in cat.size():
		kind.add_item(cat[k][1], k)
		if cat[k][0] == r.kind:
			kind.select(k)
	kind.item_selected.connect(func(k):
		_rows[i] = _default_row(cat[k][0])
		_emit()
		_render.call_deferred())
	top.add_child(kind)
	var del := Button.new()
	del.text = "✕"
	del.tooltip_text = "이 줄 지우기"
	del.pressed.connect(func():
		_rows.remove_at(i)
		_emit()
		_render.call_deferred())
	top.add_child(del)
	var params := HFlowContainer.new()
	for param in _params_of(r.kind):
		params.add_child(_param_widget(r, param))
	if params.get_child_count() > 0:
		box.add_child(params)
	box.add_child(HSeparator.new())
	return box


func _param_widget(r: Dictionary, param: String) -> Control:
	var p: Dictionary = r.p
	match param:
		"amount", "atleast", "num":
			var sp := SpinBox.new()
			sp.min_value = 1 if param != "num" else (0 if mode == "effect" else -999)
			sp.max_value = 999
			sp.value = int(p.get(param, 1))
			if param == "amount":
				sp.prefix = "x"
			elif param == "atleast":
				sp.suffix = "개 이상"
			sp.value_changed.connect(func(v):
				p[param] = int(v)
				_emit())
			return sp
		"flag", "wflag", "trait":
			var h := HBoxContainer.new()
			var le := LineEdit.new()
			le.custom_minimum_size.x = 220
			le.size_flags_horizontal = SIZE_EXPAND_FILL
			le.text = p.get(param, "")
			le.placeholder_text = {"flag": "플래그 이름 (영문)", "wflag": "월드 플래그 이름 (영문)", "trait": "특성 ID (▾ 로 고르기)"}[param]
			le.text_changed.connect(func(t):
				p[param] = t.strip_edges()
				_emit())
			h.add_child(le)
			var known: Array = lookups.get({"flag": "flags", "wflag": "wflags", "trait": "traits"}[param], [])
			var pick := MenuButton.new()
			pick.text = "▾"
			pick.flat = false
			pick.tooltip_text = "이미 쓰고 있는 이름에서 고르기"
			pick.disabled = known.is_empty()
			for n in known:
				pick.get_popup().add_item(n)
			pick.get_popup().index_pressed.connect(func(idx):
				le.text = known[idx]
				p[param] = known[idx]
				_emit())
			h.add_child(pick)
			return h
	var o := OptionButton.new()
	o.fit_to_longest_item = false
	o.clip_text = true
	o.custom_minimum_size.x = 120
	var opts := _options(param)
	var cur: String = str(p.get(param, ""))
	var found := false
	for k in opts.size():
		o.add_item(opts[k][1], k)
		if opts[k][0] == cur:
			o.select(k)
			found = true
	if not found and cur != "":
		o.add_item("%s (목록에 없음)" % cur, opts.size())
		o.select(opts.size())
	o.item_selected.connect(func(k):
		if k < opts.size():
			p[param] = opts[k][0]
			_emit())
	return o


func _emit() -> void:
	_text = _to_text()
	if _raw_edit:
		_raw_edit.text = _text
	changed.emit(_text)
