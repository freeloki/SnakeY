extends SceneTree

# AI evaluation: measures how the current brain plays against ladder rivals,
# headless and without drawing. The brain plays exactly as in the game
# (epsilon and imitation weight as loaded, via SnakeBrain.select_action) but it
# NEVER learns here, and this tool has no write path to user:// at all.
# The only file it writes is res://tools/out/eval_<date>.json.
#
# Usage:
#   "$GODOT" --headless --path . --script res://tools/eval_ai.gd -- --level=2 --matches=200
#   (see USAGE below for all options)
#
# Exit codes: 0 = pass, 1 = failure (bad brain file, runtime error, classifier
# drift, tick guard), 2 = bad arguments.
#
# Match loop: this MUST stay in step with scripts/fast_train.gd (_tick_once).
# Order inside a tick: advance_time -> trained decision -> rival decision -> step.
# MOVE_INTERVAL and PHASE2_DURATION below are copies of fast_train.gd constants;
# _check_loop_constants() compares them with the real script at startup.

const USAGE := """Usage: godot --headless --path . --script res://tools/eval_ai.gd -- [options]
  --level=N              one ladder level (1-100)        } exactly one of
  --levels=A-B           inclusive level range (1-100)   } these is required
  --matches=N            matches per level (default 200)
  --seed=N               base seed; level L uses seed N+L (default 1000)
  --brain=PATH|none      brain file (default user://ai_brain.json); none = untrained brain
  --player-model=PATH    player model file (default user://player_model.json); also
                         applies with --brain=none, at full imitation weight. Give a
                         missing path to measure with no player model at all
  --epsilon=X            override exploration rate (0-1); default as the game derives it
  --per-match            also store every match (outcome, scores, ticks) in the JSON
Exit codes: 0 ok, 1 failure, 2 bad arguments."""

const DEFAULT_SEED := 1000
const DEFAULT_MATCHES := 200
const MOVE_INTERVAL := 0.14
const PHASE2_DURATION := 30.0
const OUT_DIR := "res://tools/out"
const FAST_TRAIN_SCRIPT := "res://scripts/fast_train.gd"

const CAUSES := ["wall", "barrier", "self", "other_snake_body", "head_on", "time_up", "survived"]
const WILSON_Z := 1.96

const EXIT_FAIL := 1
const EXIT_USAGE := 2


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


var _collector := ErrorCollector.new()
# -1 until _run reaches a deliberate verdict. If _run aborts on a runtime error
# it stays -1 and _finish treats that as a failure.
var _status: int = -1
var _finished: bool = false
var _max_ticks: int = 0


func _initialize() -> void:
	OS.add_logger(_collector)
	# The tree is not running yet here. _finish runs even if _run aborts.
	_run.call_deferred()
	_finish.call_deferred()


func _finish() -> void:
	if _finished:
		return
	_finished = true
	OS.remove_logger(_collector)
	var engine_errors := _collector.snapshot()
	if _status == -1:
		printerr("eval_ai: run aborted by a runtime error, no result written")
		_status = EXIT_FAIL
	if not engine_errors.is_empty():
		for e in engine_errors:
			printerr("eval_ai: engine error: ", e)
		if _status == 0:
			_status = EXIT_FAIL
	if _status == 0:
		print("EVAL GECTI")
	elif _status == EXIT_USAGE:
		print("EVAL KALDI: hatali arguman")
	else:
		print("EVAL KALDI")
	quit(_status)


func _fail(reason: String) -> void:
	printerr("eval_ai: ", reason)
	_status = EXIT_FAIL


# ---------------------------------------------------------------------------
# Main flow
# ---------------------------------------------------------------------------

func _run() -> void:
	var cfg := _parse_args(OS.get_cmdline_user_args())
	if cfg.has("error"):
		printerr("eval_ai: ", cfg["error"])
		printerr(USAGE)
		_status = EXIT_USAGE
		return

	if not _check_loop_constants():
		return

	var out_dir := ProjectSettings.globalize_path(OUT_DIR)
	if _is_inside_user_dir(out_dir):
		_fail("output dir resolves inside user://, refusing: " + out_dir)
		return

	var brain := _load_brain(cfg)
	if brain == null:
		return

	# Snapshot to prove at the end that nothing learned.
	var q_before: Dictionary = brain.q_table.duplicate(true)
	var q_hash_before: int = brain.q_table.hash()
	var games_before: int = brain.games_played
	var eps_before: float = brain.epsilon
	var imit_before: float = brain.imitation_weight

	_max_ticks = int(ceil((SnakeArena.PHASE1_DURATION + PHASE2_DURATION) / MOVE_INTERVAL)) + 5

	var results: Array = []
	for level in cfg["levels"]:
		var res := _eval_level(level, cfg, brain)
		if res.is_empty() or _status == EXIT_FAIL:
			return
		results.append(res)
		print(_level_line(res))

	# No learning allowed: table, games_played and rates must be untouched.
	if brain.games_played != games_before \
			or brain.q_table.hash() != q_hash_before \
			or not brain.q_table.recursive_equal(q_before, 8) \
			or brain.epsilon != eps_before \
			or brain.imitation_weight != imit_before:
		_fail("brain state changed during evaluation (it must never learn here)")
		return

	if not _collector.snapshot().is_empty():
		return  # _finish reports them and exits 1

	var path := _write_json(out_dir, cfg, brain, results)
	if path.is_empty():
		return
	print("JSON: ", path)
	_status = 0


## Compares our copies of the loop constants with the real fast_train.gd.
func _check_loop_constants() -> bool:
	var script := load(FAST_TRAIN_SCRIPT) as Script
	if script == null:
		_fail("cannot load " + FAST_TRAIN_SCRIPT + " to verify loop constants")
		return false
	var consts: Dictionary = script.get_script_constant_map()
	if not consts.has("MOVE_INTERVAL") or not is_equal_approx(float(consts["MOVE_INTERVAL"]), MOVE_INTERVAL):
		_fail("MOVE_INTERVAL drifted from fast_train.gd (%s vs %s)" % [str(consts.get("MOVE_INTERVAL")), str(MOVE_INTERVAL)])
		return false
	if not consts.has("PHASE2_DURATION") or not is_equal_approx(float(consts["PHASE2_DURATION"]), PHASE2_DURATION):
		_fail("PHASE2_DURATION drifted from fast_train.gd (%s vs %s)" % [str(consts.get("PHASE2_DURATION")), str(PHASE2_DURATION)])
		return false
	return true


func _load_brain(cfg: Dictionary) -> SnakeBrain:
	var brain := SnakeBrain.new(cfg["brain"], cfg["model"])
	if cfg["brain"] != "none":
		if not FileAccess.file_exists(cfg["brain"]):
			_fail("brain file not found: " + cfg["brain"])
			return null
		brain.load_brain()
		# load_brain() silently leaves an empty table on a corrupt file.
		if brain.q_table.is_empty():
			_fail("brain loaded with an empty q_table (corrupt or empty file?): " + cfg["brain"])
			return null
	cfg["model_present"] = FileAccess.file_exists(cfg["model"])
	if cfg["model_present"]:
		brain.load_player_model()
		if brain.player_model.is_empty():
			_fail("player model file exists but loaded empty (corrupt?): " + cfg["model"])
			return null
	if cfg["has_epsilon"]:
		brain.epsilon = cfg["epsilon"]
	return brain


# ---------------------------------------------------------------------------
# Evaluation
# ---------------------------------------------------------------------------

func _eval_level(level: int, cfg: Dictionary, brain: SnakeBrain) -> Dictionary:
	# Reseed per level so the result does not depend on which other levels ran.
	seed(int(cfg["seed"]) + level)
	var params := PresetAI.level_params(level)
	# Same layout as Hizli Antrenman: rival TOP, trained BOTTOM, independent food.
	var arena := SnakeArena.new(PHASE2_DURATION, false)

	var n: int = cfg["matches"]
	var wins := 0
	var losses := 0
	var draws := 0
	var time_ups := 0
	var sum_trained := 0
	var sum_rival := 0
	var sum_ticks := 0
	var trained_causes := _zero_causes()
	var rival_causes := _zero_causes()
	var sequence: Array = []

	for i in range(n):
		var m := _play_match(arena, brain, params)
		if _status == EXIT_FAIL:
			return {}
		match m["outcome"]:
			"W":
				wins += 1
			"L":
				losses += 1
			_:
				draws += 1
		if m["time_up"]:
			time_ups += 1
		sum_trained += m["score_trained"]
		sum_rival += m["score_rival"]
		sum_ticks += m["ticks"]
		trained_causes[m["trained_cause"]] += 1
		rival_causes[m["rival_cause"]] += 1
		if cfg["per_match"]:
			sequence.append([m["outcome"], m["score_trained"], m["score_rival"], m["ticks"]])

	var wilson := _wilson(wins, n)
	var res := {
		"level": level,
		"matches": n,
		"wins": wins,
		"losses": losses,
		"draws": draws,
		"win_pct": _r4(100.0 * float(wins) / float(n)),
		"win_pct_ci95": [_r4(100.0 * wilson[0]), _r4(100.0 * wilson[1])],
		"avg_score_trained": _r4(float(sum_trained) / float(n)),
		"avg_score_rival": _r4(float(sum_rival) / float(n)),
		"avg_ticks": _r4(float(sum_ticks) / float(n)),
		"time_up": time_ups,
		"death_causes_trained": trained_causes,
		"death_causes_rival": rival_causes,
	}
	if cfg["per_match"]:
		res["match_log"] = sequence
	return res


## Plays one match. Mirrors fast_train.gd:_tick_once without any learning.
func _play_match(arena: SnakeArena, brain: SnakeBrain, params: Dictionary) -> Dictionary:
	arena.reset()
	var ticks := 0
	var time_up := false
	var trained_crashed := false
	var rival_crashed := false
	var trained_cause := ""
	var rival_cause := ""

	while true:
		ticks += 1
		if ticks > _max_ticks:
			_fail("match exceeded %d ticks (runaway loop)" % _max_ticks)
			return {}

		var event := arena.advance_time(MOVE_INTERVAL)
		if event == SnakeArena.TimeEvent.TIME_UP:
			time_up = true
			break

		var state := arena.compute_state(SnakeArena.Side.BOTTOM)
		var action := brain.select_action(state)
		var dir_trained := SnakeArena.relative_to_direction(action, arena.direction_bottom)

		var rival_action := PresetAI.decide(arena, SnakeArena.Side.TOP, params)
		var dir_rival := SnakeArena.relative_to_direction(rival_action, arena.direction_top)

		# Classify before step(): step() reports crashes but not their cause.
		var causes := _classify(arena, dir_rival, dir_trained)
		var result := arena.step(dir_rival, dir_trained)
		rival_crashed = result["top_crashed"]
		trained_crashed = result["bottom_crashed"]
		rival_cause = causes[0]
		trained_cause = causes[1]

		if rival_crashed != (rival_cause != "") or trained_crashed != (trained_cause != ""):
			_fail("crash classifier drifted from arena.step (tick %d, rival crashed=%s cause='%s', trained crashed=%s cause='%s')" % [ticks, str(rival_crashed), rival_cause, str(trained_crashed), trained_cause])
			return {}
		if (rival_crashed and not CAUSES.has(rival_cause)) or (trained_crashed and not CAUSES.has(trained_cause)):
			_fail("unclassified crash (tick %d, rival='%s', trained='%s')" % [ticks, rival_cause, trained_cause])
			return {}
		if rival_crashed or trained_crashed:
			break

	var score_t: int = arena.score_bottom
	var score_r: int = arena.score_top
	var outcome: String
	if time_up:
		outcome = _by_score(score_t, score_r)
		trained_cause = "time_up"
		rival_cause = "time_up"
	else:
		if trained_crashed and rival_crashed:
			outcome = _by_score(score_t, score_r)
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
func _by_score(score_trained: int, score_rival: int) -> String:
	if score_trained > score_rival:
		return "W"
	if score_trained < score_rival:
		return "L"
	return "D"


## Returns [rival_cause, trained_cause] for the move about to be passed to
## arena.step(). "" means that snake does not crash. Mirrors step()/is_blocked().
func _classify(arena: SnakeArena, dir_top: int, dir_bottom: int) -> Array:
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


func _cause_for(arena: SnakeArena, new_head: Vector2i, own: Array, other: Array, heads_equal: bool) -> String:
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


func _zero_causes() -> Dictionary:
	var d := {}
	for c in CAUSES:
		d[c] = 0
	return d


## 95% Wilson score interval for a proportion, as fractions [low, high].
func _wilson(successes: int, n: int) -> Array:
	var p := float(successes) / float(n)
	var z2 := WILSON_Z * WILSON_Z
	var denom := 1.0 + z2 / float(n)
	var centre := (p + z2 / (2.0 * float(n))) / denom
	var half := WILSON_Z * sqrt(p * (1.0 - p) / float(n) + z2 / (4.0 * float(n) * float(n))) / denom
	return [maxf(0.0, centre - half), minf(1.0, centre + half)]


func _r4(x: float) -> float:
	return snappedf(x, 0.0001)


func _level_line(res: Dictionary) -> String:
	var ci: Array = res["win_pct_ci95"]
	var tc: Dictionary = res["death_causes_trained"]
	var rc: Dictionary = res["death_causes_rival"]
	return "L%03d  kazanma %%%.1f [%.1f-%.1f]  G%d K%d B%d  skor %.2f-%.2f  tick %.1f  sure_doldu %d  |  yilan: duvar %d bariyer %d kendi %d govde %d kafa %d  |  rakip: duvar %d bariyer %d kendi %d govde %d kafa %d" % [
		res["level"], res["win_pct"], ci[0], ci[1], res["wins"], res["losses"], res["draws"],
		res["avg_score_trained"], res["avg_score_rival"], res["avg_ticks"], res["time_up"],
		tc["wall"], tc["barrier"], tc["self"], tc["other_snake_body"], tc["head_on"],
		rc["wall"], rc["barrier"], rc["self"], rc["other_snake_body"], rc["head_on"],
	]


# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------

func _parse_args(args: PackedStringArray) -> Dictionary:
	var cfg := {
		"levels": [],
		"matches": DEFAULT_MATCHES,
		"seed": DEFAULT_SEED,
		"brain": SnakeBrain.DEFAULT_BRAIN_PATH,
		"model": SnakeBrain.DEFAULT_PLAYER_MODEL_PATH,
		"epsilon": 0.0,
		"has_epsilon": false,
		"per_match": false,
	}
	var level_given := false
	for a in args:
		if not a.begins_with("--"):
			return {"error": "unexpected argument '%s'" % a}
		var eq := a.find("=")
		var key: String = a.substr(2) if eq < 0 else a.substr(2, eq - 2)
		var val: String = "" if eq < 0 else a.substr(eq + 1)
		match key:
			"level":
				if level_given:
					return {"error": "use only one of --level / --levels"}
				if not val.is_valid_int() or int(val) < 1 or int(val) > 100:
					return {"error": "--level must be an integer 1-100, got '%s'" % val}
				cfg["levels"] = [int(val)]
				level_given = true
			"levels":
				if level_given:
					return {"error": "use only one of --level / --levels"}
				var parts := val.split("-")
				if parts.size() != 2 or not parts[0].is_valid_int() or not parts[1].is_valid_int():
					return {"error": "--levels must look like A-B, got '%s'" % val}
				var lo := int(parts[0])
				var hi := int(parts[1])
				if lo < 1 or hi > 100 or lo > hi:
					return {"error": "--levels range must satisfy 1 <= A <= B <= 100, got '%s'" % val}
				var list: Array = []
				for l in range(lo, hi + 1):
					list.append(l)
				cfg["levels"] = list
				level_given = true
			"matches":
				if not val.is_valid_int() or int(val) < 1:
					return {"error": "--matches must be a positive integer, got '%s'" % val}
				cfg["matches"] = int(val)
			"seed":
				if not val.is_valid_int():
					return {"error": "--seed must be an integer, got '%s'" % val}
				cfg["seed"] = int(val)
			"brain":
				if val.is_empty():
					return {"error": "--brain needs a path or 'none'"}
				cfg["brain"] = val
			"player-model":
				if val.is_empty():
					return {"error": "--player-model needs a path"}
				cfg["model"] = val
			"epsilon":
				if not val.is_valid_float() or float(val) < 0.0 or float(val) > 1.0:
					return {"error": "--epsilon must be a number 0-1, got '%s'" % val}
				cfg["epsilon"] = float(val)
				cfg["has_epsilon"] = true
			"per-match":
				cfg["per_match"] = true
			_:
				return {"error": "unknown option '--%s'" % key}
	if not level_given:
		return {"error": "--level or --levels is required"}
	return cfg


# ---------------------------------------------------------------------------
# Output (the only write path of this tool)
# ---------------------------------------------------------------------------

func _is_inside_user_dir(abs_path: String) -> bool:
	var user_dir := OS.get_user_data_dir().replace("\\", "/").trim_suffix("/").to_lower()
	var p := abs_path.replace("\\", "/").to_lower()
	return p == user_dir or p.begins_with(user_dir + "/")


func _write_json(out_dir: String, cfg: Dictionary, brain: SnakeBrain, results: Array) -> String:
	var err := DirAccess.make_dir_recursive_absolute(out_dir)
	if err != OK:
		_fail("cannot create output dir %s (error %d)" % [out_dir, err])
		return ""

	var now := Time.get_datetime_dict_from_system()
	var stamp := "%04d-%02d-%02dT%02d-%02d-%02d" % [now["year"], now["month"], now["day"], now["hour"], now["minute"], now["second"]]
	var path := out_dir.path_join("eval_%s.json" % stamp)
	var suffix := 2
	while FileAccess.file_exists(path):
		path = out_dir.path_join("eval_%s_%d.json" % [stamp, suffix])
		suffix += 1

	var doc := {
		# Everything under "run" differs between runs; "config" + "results" must not.
		"run": {
			"date": stamp,
			"git_commit": _git_commit(),
			"godot_version": Engine.get_version_info()["string"],
		},
		"config": {
			"seed_base": cfg["seed"],
			"seed_rule": "seed(seed_base + level) before each level",
			"matches_per_level": cfg["matches"],
			"levels": cfg["levels"],
			"brain": cfg["brain"],
			"player_model": cfg["model"],
			"player_model_present": cfg["model_present"],
			"player_model_states": brain.player_model.size(),
			"games_played": brain.games_played,
			"q_states": brain.q_table.size(),
			"epsilon": brain.epsilon,
			"epsilon_overridden": cfg["has_epsilon"],
			"imitation_weight": brain.imitation_weight,
			"move_interval": MOVE_INTERVAL,
			"phase2_duration": PHASE2_DURATION,
			"learning": false,
		},
		"results": results,
	}
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		_fail("cannot open %s for writing (error %d)" % [path, FileAccess.get_open_error()])
		return ""
	f.store_string(JSON.stringify(doc, "\t", true))
	f.close()
	return path


## Short commit hash read straight from .git (no process spawn); "unknown" if not found.
func _git_commit() -> String:
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


func _read_text(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var t := f.get_as_text()
	f.close()
	return t
