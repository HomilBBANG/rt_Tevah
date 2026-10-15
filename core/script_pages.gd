extends RefCounted
## 대본 블록의 페이지 (대화 에디터 v1.0 기획 §4). 런타임(main_play)·대화 에디터·테스트가 같이 쓴다.
##
## 노드의 `pages` 가 있으면 그 목록, 없으면 예전처럼 노드의 speaker_id·text 로 페이지 1개.
## 페이지: { page_id, display, speaker_id, text, speed, advance, auto_wait }
##   display   — narration(상황 묘사 상자) / bubble(말풍선, 화자 필요) / system(시스템 메시지 상자)
##               / subtitle(자막 — 상자 없이 화면 아래 글자만, 영상 자막처럼. 화자는 있어도 되고 없어도 됨)
##   speed     — "" = 기본 (대화 파일 text_speed → Config text_speed_default) / instant / slow / normal / fast / 숫자(초당 글자 수)
##   advance   — input(입력 대기, 기본) / auto(다 나오고 auto_wait 초 뒤 자동 넘김)
##   text 안의 {w=0.5} = 그 자리에서 0.5초 멈춤. 빈 줄 = 문단, 줄바꿈 = 강제 줄바꿈, 나머지는 자동 줄바꿈.

const DISPLAYS := ["narration", "bubble", "system", "subtitle"]
const DISPLAY_LABEL := {"narration": "상황 묘사", "bubble": "말풍선", "system": "시스템 메시지", "subtitle": "자막 (대화창 없이)"}
## 화자를 쓰는 표시 (말풍선은 꼭, 자막은 골라도 되고 안 골라도 됨)
const WITH_SPEAKER := ["bubble", "subtitle"]
const SPEEDS := ["instant", "slow", "normal", "fast"]
const SPEED_LABEL := {"": "기본", "instant": "즉시", "slow": "느림", "normal": "보통", "fast": "빠름"}
## Config 가 없을 때 쓰는 값 (초당 글자 수). TODO(기획 §10.3): 읽기 속도 기본값·구두점 지연 미정
const DEFAULT_CPS := {"slow": 15.0, "normal": 35.0, "fast": 70.0}
const PAUSE_RE := "\\{w=(\\d+(?:\\.\\d+)?)\\}"


## 노드 → 페이지 목록 (빠진 칸은 기본값으로 채움)
static func pages_of(node: Dictionary) -> Array:
	var raw: Array = node.get("pages", []) if node.get("pages", []) is Array else []
	if raw.is_empty():
		var sp: String = node.get("speaker_id", "")
		raw = [{"display": "bubble" if sp != "" else "narration", "speaker_id": sp, "text": node.get("text", "")}]
	var out := []
	for i in raw.size():
		out.append(normalize(raw[i], i))
	return out


static func normalize(p: Dictionary, index := 0) -> Dictionary:
	var sp: String = str(p.get("speaker_id", ""))
	var display: String = str(p.get("display", ""))
	if not display in DISPLAYS:
		display = "bubble" if sp != "" else "narration"
	return {
		"page_id": str(p.get("page_id", "")) if str(p.get("page_id", "")) != "" else "p%d" % (index + 1),
		"display": display,
		"speaker_id": sp if display in WITH_SPEAKER else "",
		"text": str(p.get("text", "")),
		"speed": str(p.get("speed", "")),
		"advance": "auto" if str(p.get("advance", "")) == "auto" else "input",
		"auto_wait": float(p.get("auto_wait", 1.0)) if str(p.get("auto_wait", "")) != "" else 1.0,
	}


## 기본값만 가진 페이지인가 (편집기가 예전 형식 — pages 없이 — 으로 저장해도 되는지)
static func is_plain(p: Dictionary) -> bool:
	return p.speed == "" and p.advance == "input" and not RegEx.create_from_string(PAUSE_RE).search(p.text) \
		and p.display == ("bubble" if p.speaker_id != "" else "narration")   # 예전 형식은 말풍선·상황 묘사만 (시스템·자막은 pages 로)


## {w=0.5} 표시를 빼고, 멈출 자리를 돌려준다 → { text, pauses: [[글자 위치, 초], ...] }
static func parse_text(raw: String) -> Dictionary:
	var rx := RegEx.create_from_string(PAUSE_RE)
	var text := ""
	var pauses := []
	var at := 0
	for m in rx.search_all(raw):
		text += raw.substr(at, m.get_start() - at)
		pauses.append([text.length(), float(m.get_string(1))])
		at = m.get_end()
	text += raw.substr(at)
	return {"text": text, "pauses": pauses}


## 속도 → 초당 글자 수 (0 = 즉시). config 는 DataLoader.config 같은 사전.
static func cps(speed: String, config: Dictionary, fallback := "") -> float:
	if speed == "":
		speed = fallback if fallback != "" else str(config.get("text_speed_default", "normal"))
	if speed == "instant":
		return 0.0
	if speed in DEFAULT_CPS:
		return float(config.get("text_speed_" + speed, DEFAULT_CPS[speed]))
	if speed.is_valid_float():
		return maxf(0.0, speed.to_float())
	return float(config.get("text_speed_normal", DEFAULT_CPS.normal))


## 문법 검사 (에디터 경고·테스트용, 변환기 검사와 같은 규칙). 문제 목록을 돌려준다.
static func problems(p: Dictionary) -> Array:
	var out := []
	if p.display == "bubble" and p.speaker_id == "":
		out.append("말풍선에 화자가 없음")
	if String(p.text).strip_edges() == "":
		out.append("본문이 비어 있음")
	var rest := RegEx.create_from_string(PAUSE_RE).sub(p.text, "", true)
	if "{" in rest or "}" in rest:
		out.append("알 수 없는 { } 표시 (대기는 {w=0.5} 꼴)")
	if p.speed != "" and not p.speed in SPEEDS and not (p.speed.is_valid_float() and p.speed.to_float() > 0):
		out.append("속도 값이 이상함: '%s'" % p.speed)
	return out
