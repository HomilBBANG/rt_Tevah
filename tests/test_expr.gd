extends Node
## 조건·효과 파서 단위 테스트. 실행:
##   Godot_v4.7-stable_win64_console.exe --headless --path . res://tests/test_expr.tscn
## 실패가 있으면 종료 코드 1.

const Expr = preload("res://core/expr.gd")


class FakeCtx:
	var items := {"knife": 1, "bandage": 2}
	var stats := {"hp": 5, "sanity": 50, "time": 120}
	var flags := ["door_open"]
	var wflags := ["ep1_clear"]
	var traits := ["medic"]
	var abilities := {"stat_a": 3}

	func item_count(id: String) -> int: return items.get(id, 0)
	func get_stat(name: String) -> int: return stats.get(name, 0)
	func get_ability(id: String) -> int: return abilities.get(id, 0)
	func get_survival(id: String) -> float: return {"hunger": 25.5}.get(id, 0.0)
	func has_flag(name: String) -> bool: return name in flags
	func has_wflag(name: String) -> bool: return name in wflags
	func has_trait(name: String) -> bool: return name in traits
	func is_severed(part_id: String) -> bool: return part_id in ["left_arm", "any"]
	func get_count(name: String) -> int: return {"run": 3, "death": 2}.get(name, 0)


var _fail := 0
var _pass := 0


func _ready() -> void:
	var ctx := FakeCtx.new()

	# --- 조건: 기본
	cond(ctx, "", true)
	cond(ctx, "has:knife", true)
	cond(ctx, "has:rope", false)
	cond(ctx, "has:bandage>=2", true)
	cond(ctx, "has:bandage>2", false)
	cond(ctx, "has:bandage==2", true)
	cond(ctx, "flag:door_open", true)
	cond(ctx, "flag:window_open", false)
	cond(ctx, "wflag:ep1_clear", true)
	cond(ctx, "wflag:ep2_clear", false)
	cond(ctx, "stat:sanity>=30", true)
	cond(ctx, "stat:sanity<30", false)
	cond(ctx, "stat:hp<=5", true)
	cond(ctx, "stat:time==120", true)
	cond(ctx, "stat:hp>-1", true)
	cond(ctx, "trait:medic", true)
	cond(ctx, "trait:hacker", false)
	cond(ctx, "abil:stat_a>=3", true)
	cond(ctx, "abil:stat_a>3", false)
	cond(ctx, "abil:unknown==0", true)
	cond(ctx, "surv:hunger<30", true)
	cond(ctx, "surv:hunger>=26", false)
	cond_err(ctx, "surv:hunger")
	cond(ctx, "cut:left_arm", true)
	cond(ctx, "cut:right_leg", false)
	cond(ctx, "cut:any & !cut:right_leg", true)
	cond_err(ctx, "cut:left_arm>=1")
	cond(ctx, "count:death>=2", true)
	cond(ctx, "count:run==3", true)
	cond(ctx, "count:death>2", false)
	cond_err(ctx, "count:death")
	cond_err(ctx, "count:kills>1")
	# --- 조건: 연산자
	cond(ctx, "!has:rope", true)
	cond(ctx, "!!has:rope", false)
	cond(ctx, "has:knife & flag:door_open", true)
	cond(ctx, "has:knife & has:rope", false)
	cond(ctx, "has:rope | flag:door_open", true)
	cond(ctx, "has:rope | trait:hacker", false)
	cond(ctx, "has:rope & flag:door_open | trait:medic", true)   # (F&T)|T
	cond(ctx, "has:rope & (flag:door_open | trait:medic)", false)
	cond(ctx, "!has:rope & has:knife", true)                      # (!F)&T
	cond(ctx, "!(has:rope | has:knife)", false)
	cond(ctx, "  has:knife   &   stat:sanity >= 30 ".replace(" >= ", ">="), true)
	# --- 조건: 문법 오류 → false + 오류 기록
	cond_err(ctx, "has:")
	cond_err(ctx, "has:knife &")
	cond_err(ctx, "& has:knife")
	cond_err(ctx, "has:knife && flag:door_open")
	cond_err(ctx, "stat:hp")
	cond_err(ctx, "stat:mana>3")
	cond_err(ctx, "foo:bar")
	cond_err(ctx, "flag:door_open>=1")
	cond_err(ctx, "(has:knife")
	cond_err(ctx, "has:knife)")
	cond_err(ctx, "has:knife flag:door_open")
	cond_err(ctx, "has:knife-1")
	cond_err(ctx, "!")
	cond_err(ctx, "abil:stat_a")

	# --- 효과
	eff("item:+bandage", [{"type": "item", "id": "bandage", "amount": 1}], 0)
	eff("item:-bandage", [{"type": "item", "id": "bandage", "amount": -1}], 0)
	eff("item:+bandage*2", [{"type": "item", "id": "bandage", "amount": 2}], 0)
	eff("stat:hp-10", [{"type": "stat", "stat": "hp", "op": "-", "value": 10}], 0)
	eff("stat:sanity+5", [{"type": "stat", "stat": "sanity", "op": "+", "value": 5}], 0)
	eff("stat:time=30", [{"type": "stat", "stat": "time", "op": "=", "value": 30}], 0)
	eff("setflag:x; clearflag:y ;setwflag:z", [
		{"type": "setflag", "id": "x"}, {"type": "clearflag", "id": "y"}, {"type": "setwflag", "id": "z"}], 0)
	eff("loot:spot_1;goto:node_2", [{"type": "loot", "id": "spot_1"}, {"type": "goto", "id": "node_2"}], 0)
	eff("abil:stat_a+1;abil:stat_b=4", [
		{"type": "abil", "ability": "stat_a", "op": "+", "value": 1},
		{"type": "abil", "ability": "stat_b", "op": "=", "value": 4}], 0)
	eff("abil:stat_a", [], 1)
	eff("surv:hunger+40;surv:sleep=10", [
		{"type": "surv", "param": "hunger", "op": "+", "value": 40},
		{"type": "surv", "param": "sleep", "op": "=", "value": 10}], 0)
	eff("save;setflag:x", [{"type": "save"}, {"type": "setflag", "id": "x"}], 0)
	eff("save:now", [], 1)
	eff("restore:left_arm;item:-gold", [{"type": "restore", "id": "left_arm"}, {"type": "item", "id": "gold", "amount": -1}], 0)
	eff("restore:all", [{"type": "restore", "id": "all"}], 0)
	eff("restore:", [], 1)
	eff("", [], 0)
	eff(";;", [], 0)
	eff("item:+", [], 1)
	eff("item:+bandage*0", [], 1)
	eff("stat:mana-3", [], 1)
	eff("stat:hp-10;bogus;setflag:y", [
		{"type": "stat", "stat": "hp", "op": "-", "value": 10}, {"type": "setflag", "id": "y"}], 1)

	print("\n[test_expr] %d 통과, %d 실패" % [_pass, _fail])
	get_tree().quit(1 if _fail > 0 else 0)


func cond(ctx, expr: String, expected: bool) -> void:
	var before := Expr.errors.size()
	var got := Expr.evaluate(expr, ctx)
	check(got == expected and Expr.errors.size() == before,
		"조건 '%s' → %s (기대 %s, 새 오류 %d)" % [expr, got, expected, Expr.errors.size() - before])


func cond_err(ctx, expr: String) -> void:
	var before := Expr.errors.size()
	var got := Expr.evaluate(expr, ctx)
	check(got == false and Expr.errors.size() > before, "오류 조건 '%s' → %s, 오류 기록 %d" % [expr, got, Expr.errors.size() - before])


func eff(text: String, expected: Array, expected_errors: int) -> void:
	var before := Expr.errors.size()
	var got := Expr.parse_effects(text)
	var errs := Expr.errors.size() - before
	check(got == expected and errs == expected_errors, "효과 '%s' → %s (오류 %d, 기대 %d)" % [text, got, errs, expected_errors])


func check(ok: bool, label: String) -> void:
	if ok:
		_pass += 1
	else:
		_fail += 1
		print("FAIL: " + label)
