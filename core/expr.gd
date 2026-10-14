extends RefCounted
## 조건·효과 문법 파서. tools/xlsx_to_json.py 의 검사기와 같은 문법 — 한쪽을 바꾸면 다른 쪽도 맞출 것.
##
## 조건: has:id, has:id>=2, flag:x, wflag:x, stat:hp>=30, abil:stat_a>=3, surv:hunger<30, trait:x,
##       cut:left_arm / cut:any (팔다리 절단), count:death>=1 / count:run>=2 (월드 기록) / 연산자 ! & | ( )  (우선순위 ! > & > |)
## 효과(; 구분): item:+id, item:-id, item:+id*2, stat:hp-10 / +10 / =10, setflag:x, clearflag:x,
##              setwflag:x, loot:spot, goto:node, abil:stat_a+1 / -1 / =3, surv:hunger+40, save,
##              restore:left_arm / restore:all (잘린 팔다리 복구, §10 거래)
##
## 문법 오류는 크래시하지 않는다: push_error 로 남기고 조건은 false, 효과는 그 항목만 건너뛴다.
##
## 컨텍스트(ctx)는 다음 메서드를 가진 객체: item_count(id)->int, get_stat(name)->int,
## get_ability(id)->int, get_survival(id)->float, has_flag(name)->bool, has_wflag(name)->bool, has_trait(name)->bool,
## is_severed(part_id 또는 "any")->bool, get_count(name)->int

const STATS := ["hp", "sanity", "time"]
const COUNTS := ["run", "death"]   # count: 조건 (월드 run_count·death_count)

## 테스트용: 지금까지 기록된 오류 메시지
static var errors: PackedStringArray = []

static var _atom_re: RegEx
static var _item_re: RegEx
static var _stat_re: RegEx
static var _abil_re: RegEx
static var _surv_re: RegEx
static var _simple_re: RegEx
static var _cond_cache := {}   # 조건 문자열 -> AST (오류면 null)


static func evaluate(expr: String, ctx: Object) -> bool:
	if expr.strip_edges() == "":
		return true
	var ast = _parse_condition_cached(expr)
	if ast == null:
		return false
	return _eval(ast, ctx)


## 문법만 검사 (오류면 false, 오류는 기록됨)
static func is_valid_condition(expr: String) -> bool:
	return expr.strip_edges() == "" or _parse_condition_cached(expr) != null


## 효과 문자열 → [{type, ...}]. 잘못된 항목은 오류 기록 후 제외.
static func parse_effects(text: String) -> Array:
	_init_regex()
	var out := []
	for raw in text.split(";", false):
		var e := raw.strip_edges()
		if e == "":
			continue
		var m := _item_re.search(e)
		if m:
			var n := 1 if m.get_string(3) == "" else m.get_string(3).to_int()
			if n < 1:
				_err("효과 '%s': 수량은 1 이상" % e)
				continue
			out.append({"type": "item", "id": m.get_string(2), "amount": n if m.get_string(1) == "+" else -n})
			continue
		m = _stat_re.search(e)
		if m:
			if not m.get_string(1) in STATS:
				_err("효과 '%s': 알 수 없는 스탯" % e)
				continue
			out.append({"type": "stat", "stat": m.get_string(1), "op": m.get_string(2), "value": m.get_string(3).to_int()})
			continue
		m = _abil_re.search(e)
		if m:
			out.append({"type": "abil", "ability": m.get_string(1), "op": m.get_string(2), "value": m.get_string(3).to_int()})
			continue
		m = _surv_re.search(e)
		if m:
			out.append({"type": "surv", "param": m.get_string(1), "op": m.get_string(2), "value": m.get_string(3).to_int()})
			continue
		if e == "save":
			out.append({"type": "save"})
			continue
		m = _simple_re.search(e)
		if m:
			out.append({"type": m.get_string(1), "id": m.get_string(2)})
			continue
		_err("효과 문법 오류: '%s'" % e)
	return out


# ---------------------------------------------------------------- 내부
static func _init_regex() -> void:
	if _atom_re != null:
		return
	_atom_re = RegEx.create_from_string("^(has|flag|wflag|stat|trait|abil|surv|cut|count):([A-Za-z0-9_]+)(?:(>=|<=|==|>|<)(-?\\d+(?:\\.\\d+)?))?")
	_item_re = RegEx.create_from_string("^item:([+-])([A-Za-z0-9_]+)(?:\\*(\\d+))?$")
	_stat_re = RegEx.create_from_string("^stat:([A-Za-z0-9_]+)([+\\-=])(\\d+)$")
	_abil_re = RegEx.create_from_string("^abil:([A-Za-z0-9_]+)([+\\-=])(\\d+)$")
	_surv_re = RegEx.create_from_string("^surv:([A-Za-z0-9_]+)([+\\-=])(\\d+)$")
	_simple_re = RegEx.create_from_string("^(setflag|clearflag|setwflag|loot|goto|restore):([A-Za-z0-9_]+)$")


static func _err(msg: String) -> void:
	errors.append(msg)
	push_error("[Expr] " + msg)


static func _parse_condition_cached(expr: String) -> Variant:
	if _cond_cache.has(expr):
		return _cond_cache[expr]
	var ast = _parse_condition(expr)
	_cond_cache[expr] = ast
	return ast


static func _parse_condition(expr: String) -> Variant:
	var tokens = _tokenize(expr)
	if tokens == null:
		return null
	var p := {"t": tokens, "i": 0, "error": ""}
	var ast = _parse_or(p)
	if p.error == "" and p.i != tokens.size():
		p.error = "남는 토큰"
	if p.error != "":
		_err("조건 문법 오류 '%s': %s" % [expr, p.error])
		return null
	return ast


static func _tokenize(expr: String) -> Variant:
	_init_regex()
	var tokens := []
	var i := 0
	while i < expr.length():
		var c := expr[i]
		if c == " " or c == "\t" or c == "\n":
			i += 1
		elif c in ["&", "|", "!", "(", ")"]:
			tokens.append(c)
			i += 1
		else:
			var m := _atom_re.search(expr.substr(i))
			if m == null:
				_err("조건 문법 오류 '%s': 해석할 수 없는 부분 '%s'" % [expr, expr.substr(i)])
				return null
			var atom := {"kind": m.get_string(1), "id": m.get_string(2), "op": m.get_string(3), "num": m.get_string(4).to_float()}
			if atom.kind == "stat":
				if not atom.id in STATS:
					_err("조건 '%s': 알 수 없는 스탯 '%s'" % [expr, atom.id])
					return null
				if atom.op == "":
					_err("조건 '%s': stat 조건에는 비교식이 필요" % expr)
					return null
			elif atom.kind == "count":
				if not atom.id in COUNTS:
					_err("조건 '%s': 알 수 없는 기록 '%s' (가능: run, death)" % [expr, atom.id])
					return null
				if atom.op == "":
					_err("조건 '%s': count 조건에는 비교식이 필요" % expr)
					return null
			elif (atom.kind == "abil" or atom.kind == "surv") and atom.op == "":
				_err("조건 '%s': %s 조건에는 비교식이 필요" % [expr, atom.kind])
				return null
			elif not atom.kind in ["has", "abil", "surv", "count"] and atom.op != "":
				_err("조건 '%s': %s 에는 비교식을 쓸 수 없음" % [expr, atom.kind])
				return null
			tokens.append(atom)
			i += m.get_end()
	if tokens.is_empty():
		return null
	return tokens


static func _peek(p: Dictionary) -> Variant:
	return p.t[p.i] if p.i < p.t.size() else null


static func _parse_or(p: Dictionary) -> Variant:
	var left = _parse_and(p)
	while p.error == "" and _peek(p) is String and _peek(p) == "|":
		p.i += 1
		left = {"op": "or", "a": left, "b": _parse_and(p)}
	return left


static func _parse_and(p: Dictionary) -> Variant:
	var left = _parse_unary(p)
	while p.error == "" and _peek(p) is String and _peek(p) == "&":
		p.i += 1
		left = {"op": "and", "a": left, "b": _parse_unary(p)}
	return left


static func _parse_unary(p: Dictionary) -> Variant:
	if p.error != "":
		return null
	var t = _peek(p)
	if t is Dictionary:
		p.i += 1
		return {"op": "atom", "atom": t}
	if t is String and t == "!":
		p.i += 1
		return {"op": "not", "a": _parse_unary(p)}
	if t is String and t == "(":
		p.i += 1
		var inner = _parse_or(p)
		var close = _peek(p)
		if p.error == "" and not (close is String and close == ")"):
			p.error = "닫는 괄호 ')' 가 없음"
			return null
		p.i += 1
		return inner
	p.error = "조건이 와야 할 자리에 '%s'" % ("끝" if t == null else str(t))
	return null


static func _eval(n: Dictionary, ctx: Object) -> bool:
	match n.op:
		"or": return _eval(n.a, ctx) or _eval(n.b, ctx)
		"and": return _eval(n.a, ctx) and _eval(n.b, ctx)
		"not": return not _eval(n.a, ctx)
	var a: Dictionary = n.atom
	match a.kind:
		"has":
			var count: int = ctx.item_count(a.id)
			return count >= 1 if a.op == "" else _compare(count, a.op, a.num)
		"flag": return ctx.has_flag(a.id)
		"wflag": return ctx.has_wflag(a.id)
		"trait": return ctx.has_trait(a.id)
		"stat": return _compare(ctx.get_stat(a.id), a.op, a.num)
		"abil": return _compare(ctx.get_ability(a.id), a.op, a.num)
		"surv": return _compare(ctx.get_survival(a.id), a.op, a.num)
		"cut": return ctx.is_severed(a.id)
		"count": return _compare(ctx.get_count(a.id), a.op, a.num)
	return false


static func _compare(v: float, op: String, num: float) -> bool:
	match op:
		">": return v > num
		">=": return v >= num
		"<": return v < num
		"<=": return v <= num
		"==": return is_equal_approx(v, num)
	return false
