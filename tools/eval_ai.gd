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
# Match loop: tools/match_sim.gd (shared with tools/train_ai.gd), which MUST stay
# in step with scripts/fast_train.gd (_tick_once). Here it always runs with
# learn=false. Its loop constants are compared with fast_train.gd at startup.

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

const MatchSim := preload("res://tools/match_sim.gd")

const DEFAULT_SEED := 1000
const DEFAULT_MATCHES := 200
const MOVE_INTERVAL := MatchSim.MOVE_INTERVAL
const PHASE2_DURATION := MatchSim.PHASE2_DURATION
const OUT_DIR := "res://tools/out"

const EXIT_FAIL := 1
const EXIT_USAGE := 2


var _collector := MatchSim.ErrorCollector.new()
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

	var drift := MatchSim.check_loop_constants()
	if not drift.is_empty():
		_fail(drift)
		return

	var out_dir := ProjectSettings.globalize_path(OUT_DIR)
	if MatchSim.is_inside_user_dir(out_dir):
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

	_max_ticks = MatchSim.max_ticks()

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
	var arena := MatchSim.new_arena()

	var n: int = cfg["matches"]
	var wins := 0
	var losses := 0
	var draws := 0
	var time_ups := 0
	var sum_trained := 0
	var sum_rival := 0
	var sum_ticks := 0
	var trained_causes := MatchSim.zero_causes()
	var rival_causes := MatchSim.zero_causes()
	var sequence: Array = []

	for i in range(n):
		var m := MatchSim.play_match(arena, brain, params, _max_ticks, false)
		if m.has("error"):
			_fail(m["error"])
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

	var wilson := MatchSim.wilson(wins, n)
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
			"git_commit": MatchSim.git_commit(),
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
