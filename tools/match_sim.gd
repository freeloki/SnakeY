extends RefCounted
## Headless match simulation shared by tools/eval_ai.gd and tools/train_ai.gd.
## Trained snake BOTTOM vs ladder rival TOP, independent food, no drawing and no
## real time: exactly the Hizli Antrenman (scripts/fast_train.gd) layout.
##
## The tick loop MUST stay in step with scripts/fast_train.gd (_tick_once).
## Order inside a tick: advance_time -> trained decision -> rival decision -> step,
## then (only when learning) the Q update fast_train.gd does. Every reward and
## update rule comes from SnakeBrain; nothing about learning is decided here.
## MOVE_INTERVAL and PHASE2_DURATION are copies of fast_train.gd constants;
## check_loop_constants() compares them with the real script.
##
## Used through preload (no class_name), so it adds no global class.

const MOVE_INTERVAL := 0.14
const PHASE2_DURATION := 30.0
const FAST_TRAIN_SCRIPT := "res://scripts/fast_train.gd"

const CAUSES := ["wall", "barrier", "self", "other_snake_body", "head_on", "time_up", "survived"]
const WILSON_Z := 1.96


# Collects engine and script errors (a GDScript runtime error does not change
# Godot's exit code, see tools/smoke_test.gd). Callbacks may come from other threads.
class ErrorCollector extends Logger:
	var mutex := Mutex.new()
	var errors: Array[String] = []

	func _log_error(function: String, file: String, line: int, code: String, rationale: String, _editor_notify: bool, error_type: int, _script_backtraces: Array[ScriptBacktrace]) -> void:
		if error_type == ERROR_TYPE_WARNING:
			return
		var text := rationale if not rationale.is_empty() else code
		mutex.lock()
		errors.append("%s:%d (%s): %s" % [file, line, function, text])
		mutex.unlock()

	func snapshot() -> Array[String]:
		mutex.lock()
		var out: Array[String] = errors.duplicate()
		mutex.unlock()
		return out


## "" if our loop constants match fast_train.gd, otherwise the reason.
static func check_loop_constants() -> String:
	var script := load(FAST_TRAIN_SCRIPT) as Script
	if script == null:
		return "cannot load " + FAST_TRAIN_SCRIPT + " to verify loop constants"
	var consts: Dictionary = script.get_script_constant_map()
	if not consts.has("MOVE_INTERVAL") or not is_equal_approx(float(consts["MOVE_INTERVAL"]), MOVE_INTERVAL):
		return "MOVE_INTERVAL drifted from fast_train.gd (%s vs %s)" % [str(consts.get("MOVE_INTERVAL")), str(MOVE_INTERVAL)]
	if not consts.has("PHASE2_DURATION") or not is_equal_approx(float(consts["PHASE2_DURATION"]), PHASE2_DURATION):
		return "PHASE2_DURATION drifted from fast_train.gd (%s vs %s)" % [str(consts.get("PHASE2_DURATION")), str(PHASE2_DURATION)]
	return ""


## Upper bound on ticks per match; more means a runaway loop.
static func max_ticks() -> int:
	return int(ceil((SnakeArena.PHASE1_DURATION + PHASE2_DURATION) / MOVE_INTERVAL)) + 5


static func new_arena() -> SnakeArena:
	return SnakeArena.new(PHASE2_DURATION, false)


## Plays one match on `arena` (reset here). With learn=false the brain is only
## read. With learn=true it receives the same update_q calls as fast_train.gd;
## the caller still has to call brain.finish_match() afterwards, as fast_train does.
## Returns the match summary, or {"error": text} on a runaway loop or a crash
## classifier that disagrees with arena.step().
static func play_match(arena: SnakeArena, brain: SnakeBrain, params: Dictionary, tick_limit: int, learn: bool) -> Dictionary:
	arena.reset()
	var ticks := 0
	var time_up := false
	var trained_crashed := false
	var rival_crashed := false
	var trained_cause := ""
	var rival_cause := ""

	while true:
		ticks += 1
		if ticks > tick_limit:
			return {"error": "match exceeded %d ticks (runaway loop)" % tick_limit}

		var event := arena.advance_time(MOVE_INTERVAL)
		if event == SnakeArena.TimeEvent.TIME_UP:
			time_up = true
			break

		var target_trained: Vector2i = arena.target_for(SnakeArena.Side.BOTTOM)
		var old_dist: int = SnakeArena.distance(arena.head_of(SnakeArena.Side.BOTTOM), target_trained)

		var state := arena.compute_state(SnakeArena.Side.BOTTOM)
		var action := brain.select_action(state)
		var dir_trained := SnakeArena.relative_to_direction(action, arena.direction_bottom)

		var rival_action := PresetAI.decide(arena, SnakeArena.Side.TOP, params)
		var dir_rival := SnakeArena.relative_to_direction(rival_action, arena.direction_top)

		# Classify before step(): step() reports crashes but not their cause.
		var causes := classify(arena, dir_rival, dir_trained)
		var result := arena.step(dir_rival, dir_trained)
		rival_crashed = result["top_crashed"]
		trained_crashed = result["bottom_crashed"]
		rival_cause = causes[0]
		trained_cause = causes[1]

		if rival_crashed != (rival_cause != "") or trained_crashed != (trained_cause != ""):
			return {"error": "crash classifier drifted from arena.step (tick %d, rival crashed=%s cause='%s', trained crashed=%s cause='%s')" % [ticks, str(rival_crashed), rival_cause, str(trained_crashed), trained_cause]}
		if (rival_crashed and not CAUSES.has(rival_cause)) or (trained_crashed and not CAUSES.has(trained_cause)):
			return {"error": "unclassified crash (tick %d, rival='%s', trained='%s')" % [ticks, rival_cause, trained_cause]}
		if rival_crashed or trained_crashed:
			if learn:
				brain.update_q(state, action, brain.terminal_reward(trained_crashed), "", true)
			break

		if learn:
			var new_dist: int = SnakeArena.distance(arena.head_of(SnakeArena.Side.BOTTOM), target_trained)
			var reward: float = brain.step_reward(result["bottom_ate"], old_dist, new_dist)
			var next_state := arena.compute_state(SnakeArena.Side.BOTTOM)
			brain.update_q(state, action, reward, next_state, false)

	var score_t: int = arena.score_bottom
	var score_r: int = arena.score_top
	var outcome: String
	if time_up:
		outcome = by_score(score_t, score_r)
		trained_cause = "time_up"
		rival_cause = "time_up"
	else:
		if trained_crashed and rival_crashed:
			outcome = by_score(score_t, score_r)
		elif rival_crashed:
			outcome = "W"
		else:
			outcome = "L"
		if not trained_crashed:
			trained_cause = "survived"
		if not rival_crashed:
			rival_cause = "survived"

	return {
		"outcome": outcome,
		"time_up": time_up,
		"score_trained": score_t,
		"score_rival": score_r,
		"ticks": ticks,
		"trained_cause": trained_cause,
		"rival_cause": rival_cause,
	}


## Same rule as fast_train.gd: strictly more points wins; equal points is a draw
## here (the game counts a draw as "not won", which is still a non-win).
static func by_score(score_trained: int, score_rival: int) -> String:
	if score_trained > score_rival:
		return "W"
	if score_trained < score_rival:
		return "L"
	return "D"


## Returns [rival_cause, trained_cause] for the move about to be passed to
## arena.step(). "" means that snake does not crash. Mirrors step()/is_blocked().
static func classify(arena: SnakeArena, dir_top: int, dir_bottom: int) -> Array:
	var new_top: Vector2i = arena.snake_top[0] + SnakeArena.dir_vector(dir_top)
	var new_bottom: Vector2i = arena.snake_bottom[0] + SnakeArena.dir_vector(dir_bottom)
	var heads_equal := new_top == new_bottom
	# Swapping cells: step() sees two body hits, but it is really a head-on crash.
	if new_top == arena.snake_bottom[0] and new_bottom == arena.snake_top[0]:
		return ["head_on", "head_on"]
	return [
		_cause_for(arena, new_top, arena.snake_top, arena.snake_bottom, heads_equal),
		_cause_for(arena, new_bottom, arena.snake_bottom, arena.snake_top, heads_equal),
	]


static func _cause_for(arena: SnakeArena, new_head: Vector2i, own: Array, other: Array, heads_equal: bool) -> String:
	if arena.is_blocked(new_head, own, other):
		if new_head.x < 0 or new_head.x >= SnakeArena.GRID_WIDTH or new_head.y < 0 or new_head.y >= SnakeArena.GRID_HEIGHT:
			return "wall"
		if arena.phase == 1 and new_head.y == SnakeArena.BARRIER_ROW:
			return "barrier"
		if own.has(new_head):
			return "self"
		if arena.phase == 2 and other.has(new_head):
			return "other_snake_body"
		return "unclassified"  # is_blocked changed in a way we do not know
	# Not blocked by the map or the bodies: the remaining crash rules of step().
	if heads_equal:
		return "head_on"
	if other.has(new_head):
		return "other_snake_body"
	return ""


static func zero_causes() -> Dictionary:
	var d := {}
	for c in CAUSES:
		d[c] = 0
	return d


## 95% Wilson score interval for a proportion, as fractions [low, high].
static func wilson(successes: int, n: int) -> Array:
	var p := float(successes) / float(n)
	var z2 := WILSON_Z * WILSON_Z
	var denom := 1.0 + z2 / float(n)
	var centre := (p + z2 / (2.0 * float(n))) / denom
	var half := WILSON_Z * sqrt(p * (1.0 - p) / float(n) + z2 / (4.0 * float(n) * float(n))) / denom
	return [maxf(0.0, centre - half), minf(1.0, centre + half)]


## Absolute, simplified form of a res://, user://, absolute or relative path
## (relative paths resolve against res://, as FileAccess does). ".." is folded.
static func normalize_path(path: String) -> String:
	var p := path.replace("\\", "/")
	if p.is_relative_path() and not p.begins_with("res://") and not p.begins_with("user://"):
		p = "res://" + p
	return ProjectSettings.globalize_path(p).replace("\\", "/").simplify_path()


## True if the path (any form, see normalize_path) is the user:// folder or inside it.
static func is_inside_user_dir(path: String) -> bool:
	var user_dir := normalize_path(OS.get_user_data_dir()).trim_suffix("/").to_lower()
	var p := normalize_path(path).to_lower()
	return p == user_dir or p.begins_with(user_dir + "/")


## Short commit hash read straight from .git (no process spawn); "unknown" if not found.
static func git_commit() -> String:
	var git_dir := ProjectSettings.globalize_path("res://").path_join(".git")
	var head := _read_text(git_dir.path_join("HEAD")).strip_edges()
	if head.is_empty():
		return "unknown"
	if not head.begins_with("ref: "):
		return head.substr(0, 7)
	var ref := head.substr(5)
	var sha := _read_text(git_dir.path_join(ref)).strip_edges()
	if sha.is_empty():
		for line in _read_text(git_dir.path_join("packed-refs")).split("\n"):
			if line.ends_with(" " + ref):
				sha = line.split(" ")[0]
	return "unknown" if sha.is_empty() else sha.substr(0, 7)


static func _read_text(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var t := f.get_as_text()
	f.close()
	return t
