extends SceneTree

# Headless self-training: a brain (empty by default) plays N learning matches
# against ladder rivals, without drawing and without real time, exactly like
# Hizli Antrenman (tools/match_sim.gd with learn=true). Learning rules and
# constants come only from SnakeBrain; --set overrides them via SnakeBrain.configure().
#
# Never writes user://. The player model and --init-brain are only read. The
# only files written are the trained brain (same schema as ai_brain.json) and
# a report JSON next to it, by default under res://tools/out/.
#
# Determinism: before training match i the global RNG is seeded with
# seed*1000003 + i, and every evaluation reseeds with eval_seed + level (the
# eval_ai.gd rule). So the trained brain depends only on the training options,
# not on whether or how often evaluations run.
#
# Usage:
#   "$GODOT" --headless --path . --script res://tools/train_ai.gd -- --level=1 --matches=2000 --eval-every=500
#   (see USAGE below for all options)
#
# Exit codes: 0 = ok, 1 = failure, 2 = bad arguments.

const USAGE := """Usage: godot --headless --path . --script res://tools/train_ai.gd -- [options]
  --level=N              train against one ladder level (1-100)        } exactly one
  --ladder[=N]           climb the ladder from level N (default 1) with } of these
                         the LadderSeries rule (best of 5); progress is kept in the report only
  --matches=N            training matches (default 1000)
  --seed=N               training seed; match i uses seed N*1000003+i (default 1)
  --out=PATH             trained brain file (default res://tools/out/train_<date>_brain.json);
                         the report goes to the same name with _report.json. Never inside user://
  --init-brain=PATH|none start brain, read only (default none = empty brain)
  --player-model=PATH|none  player model for imitation, read only (default none = no imitation)
  --set=NAME=X[,NAME=X]  override SnakeBrain learning parameters (repeatable), e.g.
                         --set=alpha=0.3,epsilon_decay=0.995. Names: see SnakeBrain.tunable_names()
  --log-every=N          training curve block size in matches (default 100)
  --eval-every=N         evaluate before training, every N matches and at the end (default 0 = end only)
  --eval-matches=N       matches per evaluated level (default 200; 0 = no evaluation)
  --eval-levels=A-B      levels to evaluate (default: --level, or the --ladder start level)
  --eval-seed=N          evaluation base seed, level L uses N+L (default 1000, as eval_ai.gd)
  --eval-epsilon=X       exploration rate during evaluation (0-1); default the game's derived rate
Exit codes: 0 ok, 1 failure, 2 bad arguments."""

const MatchSim := preload("res://tools/match_sim.gd")

const DEFAULT_MATCHES := 1000
const DEFAULT_SEED := 1
const SEED_STRIDE := 1000003
const DEFAULT_LOG_EVERY := 100
const DEFAULT_EVAL_MATCHES := 200
const DEFAULT_EVAL_SEED := 1000
const OUT_DIR := "res://tools/out"

const EXIT_FAIL := 1
const EXIT_USAGE := 2


var _collector := MatchSim.ErrorCollector.new()
var _status: int = -1
var _finished: bool = false
var _max_ticks: int = 0


func _initialize() -> void:
	OS.add_logger(_collector)
	_run.call_deferred()
	_finish.call_deferred()


func _finish() -> void:
	if _finished:
		return
	_finished = true
	OS.remove_logger(_collector)
	var engine_errors := _collector.snapshot()
	if _status == -1:
		printerr("train_ai: run aborted by a runtime error")
		_status = EXIT_FAIL
	if not engine_errors.is_empty():
		for e in engine_errors:
			printerr("train_ai: engine error: ", e)
		if _status == 0:
			_status = EXIT_FAIL
	if _status == 0:
		print("TRAIN GECTI")
	elif _status == EXIT_USAGE:
		print("TRAIN KALDI: hatali arguman")
	else:
		print("TRAIN KALDI")
	quit(_status)


func _fail(reason: String) -> void:
	printerr("train_ai: ", reason)
	_status = EXIT_FAIL


# ---------------------------------------------------------------------------
# Main flow
# ---------------------------------------------------------------------------

func _run() -> void:
	var cfg := _parse_args(OS.get_cmdline_user_args())
	if cfg.has("error"):
		printerr("train_ai: ", cfg["error"])
		printerr(USAGE)
		_status = EXIT_USAGE
		return

	var drift := MatchSim.check_loop_constants()
	if not drift.is_empty():
		_fail(drift)
		return

	var stamp := _stamp()
	var brain_out: String = cfg["out"]
	if brain_out.is_empty():
		brain_out = OUT_DIR.path_join("train_%s_brain.json" % stamp)
	brain_out = MatchSim.normalize_path(brain_out)
	var report_out := brain_out.get_basename() + "_report.json"
	for p in [brain_out, report_out]:
		if MatchSim.is_inside_user_dir(p):
			printerr("train_ai: --out resolves inside user://, refusing: " + p)
			_status = EXIT_USAGE
			return
	if brain_out.get_extension().to_lower() != "json":
		_fail("--out must end in .json: " + brain_out)
		return
	var err := DirAccess.make_dir_recursive_absolute(brain_out.get_base_dir())
	if err != OK:
		_fail("cannot create output dir %s (error %d)" % [brain_out.get_base_dir(), err])
		return

	var brain := _make_brain(cfg)
	if brain == null:
		return
	# From here on the brain may only ever save to brain_out.
	brain.brain_path = brain_out

	_max_ticks = MatchSim.max_ticks()
	var arena := MatchSim.new_arena()

	var ladder: bool = cfg["ladder"]
	var level: int = cfg["level"]
	var highest_cleared: int = level - 1 if ladder else 0
	var series := LadderSeries.new()
	var ladder_events: Array = []
	var params := PresetAI.level_params(level)

	var n: int = cfg["matches"]
	var eval_every: int = cfg["eval_every"]
	var evals: Array = []
	var curve: Array = []
	var block := _new_block(0, level)
	var t_start := Time.get_ticks_usec()
	var eval_usec := 0

	if eval_every > 0 and cfg["eval_matches"] > 0:
		var t0 := Time.get_ticks_usec()
		if not _evaluate(cfg, brain, 0, evals):
			return
		eval_usec += Time.get_ticks_usec() - t0

	for i in range(n):
		seed(int(cfg["seed"]) * SEED_STRIDE + i)
		var m := MatchSim.play_match(arena, brain, params, _max_ticks, true)
		if m.has("error"):
			_fail("training match %d: %s" % [i, m["error"]])
			return
		brain.finish_match()
		var won: bool = m["outcome"] == "W"
		_add_to_block(block, m, level)

		if ladder:
			series.record(won)
			if series.is_finished():
				var cleared := series.is_cleared()
				ladder_events.append({"after_matches": i + 1, "level": level, "cleared": cleared, "wins": series.wins, "non_wins": series.non_wins})
				if cleared and level > highest_cleared:
					highest_cleared = level
					level = mini(100, highest_cleared + 1)
					params = PresetAI.level_params(level)
				series.reset()

		var done := i + 1
		if done % int(cfg["log_every"]) == 0 or done == n:
			var row := _close_block(block, done, brain, highest_cleared if ladder else -1)
			curve.append(row)
			print(_curve_line(row))
			block = _new_block(done, level)

		if cfg["eval_matches"] > 0 and ((eval_every > 0 and done % eval_every == 0) or done == n):
			var t1 := Time.get_ticks_usec()
			if not _evaluate(cfg, brain, done, evals):
				return
			eval_usec += Time.get_ticks_usec() - t1

	var total_usec := Time.get_ticks_usec() - t_start

	if not _collector.snapshot().is_empty():
		_fail("engine errors during training, nothing written (listed below)")
		return

	# Remove an old file first, so a failed save cannot report a stale sha256.
	if FileAccess.file_exists(brain_out):
		var rm_err := DirAccess.remove_absolute(brain_out)
		if rm_err != OK:
			_fail("cannot replace existing brain file %s (error %d)" % [brain_out, rm_err])
			return
	brain.save_brain()
	if not FileAccess.file_exists(brain_out):
		_fail("brain was not written: " + brain_out)
		return
	var brain_sha := FileAccess.get_sha256(brain_out)

	var doc := {
		# Everything under "run" differs between runs; the rest must not.
		"run": {
			"date": stamp,
			"git_commit": MatchSim.git_commit(),
			"godot_version": Engine.get_version_info()["string"],
			"brain_out": brain_out,
			"report_out": report_out,
			"total_seconds": _r4(float(total_usec) / 1e6),
			"train_seconds": _r4(float(total_usec - eval_usec) / 1e6),
			"eval_seconds": _r4(float(eval_usec) / 1e6),
		},
		"config": {
			"mode": "ladder" if ladder else "level",
			"level": cfg["level"],
			"matches": n,
			"seed": cfg["seed"],
			"seed_rule": "seed(seed*%d + i) before training match i" % SEED_STRIDE,
			"init_brain": cfg["init_brain"],
			"init_games_played": cfg["init_games_played"],
			"player_model": cfg["model"],
			"player_model_states": brain.player_model.size(),
			"overrides": cfg["overrides"],
			"brain_params": brain.tunables(),
			"log_every": cfg["log_every"],
			"eval_every": eval_every,
			"eval_matches": cfg["eval_matches"],
			"eval_levels": cfg["eval_levels"],
			"eval_seed": cfg["eval_seed"],
			"eval_seed_rule": "seed(eval_seed + level) before each evaluated level",
			"eval_epsilon": cfg["eval_epsilon"] if cfg["has_eval_epsilon"] else null,
			"move_interval": MatchSim.MOVE_INTERVAL,
			"phase2_duration": MatchSim.PHASE2_DURATION,
		},
		"final": {
			"games_played": brain.games_played,
			"q_states": brain.q_table.size(),
			"epsilon": brain.epsilon,
			"imitation_weight": brain.imitation_weight,
			"brain_sha256": brain_sha,
			"highest_cleared": highest_cleared if ladder else null,
			"ladder_level": level if ladder else null,
		},
		"curve": curve,
		"evals": evals,
		"ladder_series": ladder_events,
	}
	var f := FileAccess.open(report_out, FileAccess.WRITE)
	if f == null:
		_fail("cannot open %s for writing (error %d)" % [report_out, FileAccess.get_open_error()])
		return
	f.store_string(JSON.stringify(doc, "\t", true))
	f.close()

	print("Sure: toplam %.1f sn (egitim %.1f, olcum %.1f), %.1f ms/egitim maci" % [
		float(total_usec) / 1e6, float(total_usec - eval_usec) / 1e6, float(eval_usec) / 1e6,
		float(total_usec - eval_usec) / 1000.0 / float(n)])
	print("BEYIN: ", brain_out, "  sha256 ", brain_sha.substr(0, 16))
	print("RAPOR: ", report_out)
	_status = 0


func _make_brain(cfg: Dictionary) -> SnakeBrain:
	var init: String = cfg["init_brain"]
	var model: String = cfg["model"]
	# The constructor paths are only used for loading here; brain_path is
	# replaced with the output path before anything could be saved.
	var brain := SnakeBrain.new(init if init != "none" else "", model if model != "none" else "")
	var conf_err := brain.configure(cfg["overrides"])
	if not conf_err.is_empty():
		printerr("train_ai: ", conf_err)
		_status = EXIT_USAGE
		return null
	if init != "none":
		if not FileAccess.file_exists(init):
			_fail("init brain not found: " + init)
			return null
		brain.load_brain()
		if brain.q_table.is_empty():
			_fail("init brain loaded with an empty q_table (corrupt or empty file?): " + init)
			return null
	cfg["init_games_played"] = brain.games_played
	if model != "none":
		if not FileAccess.file_exists(model):
			_fail("player model not found: " + model)
			return null
		brain.load_player_model()
		if brain.player_model.is_empty():
			_fail("player model loaded empty (corrupt?): " + model)
			return null
	return brain


# ---------------------------------------------------------------------------
# Evaluation (read only, same rules as tools/eval_ai.gd)
# ---------------------------------------------------------------------------

func _evaluate(cfg: Dictionary, brain: SnakeBrain, after: int, evals: Array) -> bool:
	var games_before := brain.games_played
	var states_before := brain.q_table.size()
	var hash_before := brain.q_table.hash()
	var eps_saved := brain.epsilon
	if cfg["has_eval_epsilon"]:
		brain.epsilon = cfg["eval_epsilon"]
	var eps_used := brain.epsilon

	var arena := MatchSim.new_arena()
	var levels: Array = []
	for level: int in cfg["eval_levels"]:
		seed(int(cfg["eval_seed"]) + level)
		var params := PresetAI.level_params(level)
		var n: int = cfg["eval_matches"]
		var wins := 0
		var losses := 0
		var draws := 0
		var sum_t := 0
		var sum_r := 0
		var tc := MatchSim.zero_causes()
		for i in range(n):
			var m := MatchSim.play_match(arena, brain, params, _max_ticks, false)
			if m.has("error"):
				brain.epsilon = eps_saved
				_fail("eval level %d: %s" % [level, m["error"]])
				return false
			match m["outcome"]:
				"W":
					wins += 1
				"L":
					losses += 1
				_:
					draws += 1
			sum_t += m["score_trained"]
			sum_r += m["score_rival"]
			tc[m["trained_cause"]] += 1
		var w := MatchSim.wilson(wins, n)
		levels.append({
			"level": level,
			"matches": n,
			"wins": wins,
			"losses": losses,
			"draws": draws,
			"win_pct": _r4(100.0 * float(wins) / float(n)),
			"win_pct_ci95": [_r4(100.0 * w[0]), _r4(100.0 * w[1])],
			"avg_score_trained": _r4(float(sum_t) / float(n)),
			"avg_score_rival": _r4(float(sum_r) / float(n)),
			"death_causes_trained": tc,
		})
	brain.epsilon = eps_saved

	if brain.games_played != games_before or brain.q_table.size() != states_before or brain.q_table.hash() != hash_before:
		_fail("brain changed during evaluation (it must never learn there)")
		return false

	var entry := {"after_matches": after, "epsilon": eps_used, "imitation_weight": brain.imitation_weight, "q_states": states_before, "levels": levels}
	evals.append(entry)
	print(_eval_line(entry))
	return true


# ---------------------------------------------------------------------------
# Training curve
# ---------------------------------------------------------------------------

func _new_block(start: int, level: int) -> Dictionary:
	return {
		"from": start, "level_min": level, "level_max": level,
		"n": 0, "wins": 0, "losses": 0, "draws": 0, "time_up": 0,
		"sum_t": 0, "sum_r": 0, "sum_ticks": 0,
		"tc": MatchSim.zero_causes(), "rc": MatchSim.zero_causes(),
	}


func _add_to_block(b: Dictionary, m: Dictionary, level: int) -> void:
	b["n"] += 1
	b["level_min"] = mini(b["level_min"], level)
	b["level_max"] = maxi(b["level_max"], level)
	match m["outcome"]:
		"W":
			b["wins"] += 1
		"L":
			b["losses"] += 1
		_:
			b["draws"] += 1
	if m["time_up"]:
		b["time_up"] += 1
	b["sum_t"] += m["score_trained"]
	b["sum_r"] += m["score_rival"]
	b["sum_ticks"] += m["ticks"]
	b["tc"][m["trained_cause"]] += 1
	b["rc"][m["rival_cause"]] += 1


func _close_block(b: Dictionary, done: int, brain: SnakeBrain, highest_cleared: int) -> Dictionary:
	var n: int = b["n"]
	var row := {
		"matches_from": b["from"],
		"matches_to": done,
		"level_min": b["level_min"],
		"level_max": b["level_max"],
		"matches": n,
		"wins": b["wins"],
		"losses": b["losses"],
		"draws": b["draws"],
		"win_pct": _r4(100.0 * float(b["wins"]) / float(n)),
		"avg_score_trained": _r4(float(b["sum_t"]) / float(n)),
		"avg_score_rival": _r4(float(b["sum_r"]) / float(n)),
		"avg_ticks": _r4(float(b["sum_ticks"]) / float(n)),
		"time_up": b["time_up"],
		"death_causes_trained": b["tc"],
		"death_causes_rival": b["rc"],
		"epsilon_end": brain.epsilon,
		"q_states_end": brain.q_table.size(),
	}
	if highest_cleared >= 0:
		row["highest_cleared_end"] = highest_cleared
	return row


func _curve_line(r: Dictionary) -> String:
	var tc: Dictionary = r["death_causes_trained"]
	var lv := "L%03d" % r["level_min"] if r["level_min"] == r["level_max"] else "L%03d-%03d" % [r["level_min"], r["level_max"]]
	var hc := "" if not r.has("highest_cleared_end") else "  gecilen %d" % r["highest_cleared_end"]
	return "egitim %6d-%6d  %s  kazanma %%%.1f  skor %.2f-%.2f  eps %.3f  durum %d%s  |  yilan: duvar %d kendi %d govde %d kafa %d sure %d" % [
		r["matches_from"] + 1, r["matches_to"], lv, r["win_pct"], r["avg_score_trained"], r["avg_score_rival"],
		r["epsilon_end"], r["q_states_end"], hc,
		tc["wall"], tc["self"], tc["other_snake_body"], tc["head_on"], tc["time_up"],
	]


func _eval_line(e: Dictionary) -> String:
	var parts: Array[String] = []
	for l: Dictionary in e["levels"]:
		var ci: Array = l["win_pct_ci95"]
		parts.append("L%03d %%%.1f [%.1f-%.1f] skor %.2f-%.2f" % [l["level"], l["win_pct"], ci[0], ci[1], l["avg_score_trained"], l["avg_score_rival"]])
	return "OLCUM %6d mac sonra  eps %.3f  |  %s" % [e["after_matches"], e["epsilon"], "  |  ".join(parts)]


func _r4(x: float) -> float:
	return snappedf(x, 0.0001)


func _stamp() -> String:
	var now := Time.get_datetime_dict_from_system()
	return "%04d-%02d-%02dT%02d-%02d-%02d" % [now["year"], now["month"], now["day"], now["hour"], now["minute"], now["second"]]


# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------

func _parse_args(args: PackedStringArray) -> Dictionary:
	var cfg := {
		"ladder": false,
		"level": 0,
		"matches": DEFAULT_MATCHES,
		"seed": DEFAULT_SEED,
		"out": "",
		"init_brain": "none",
		"init_games_played": 0,
		"model": "none",
		"overrides": {},
		"log_every": DEFAULT_LOG_EVERY,
		"eval_every": 0,
		"eval_matches": DEFAULT_EVAL_MATCHES,
		"eval_levels": [],
		"eval_seed": DEFAULT_EVAL_SEED,
		"eval_epsilon": 0.0,
		"has_eval_epsilon": false,
	}
	var mode_given := false
	for a in args:
		if not a.begins_with("--"):
			return {"error": "unexpected argument '%s'" % a}
		var eq := a.find("=")
		var key: String = a.substr(2) if eq < 0 else a.substr(2, eq - 2)
		var val: String = "" if eq < 0 else a.substr(eq + 1)
		match key:
			"level", "ladder":
				if mode_given:
					return {"error": "use only one of --level / --ladder"}
				mode_given = true
				cfg["ladder"] = key == "ladder"
				if key == "ladder" and val.is_empty():
					val = "1"
				if not val.is_valid_int() or int(val) < 1 or int(val) > 100:
					return {"error": "--%s must be an integer 1-100, got '%s'" % [key, val]}
				cfg["level"] = int(val)
			"matches", "log-every", "eval-every", "eval-matches":
				var minimum := 1 if key in ["matches", "log-every"] else 0
				if not val.is_valid_int() or int(val) < minimum:
					return {"error": "--%s must be an integer >= %d, got '%s'" % [key, minimum, val]}
				cfg[key.replace("-", "_")] = int(val)
			"seed", "eval-seed":
				if not val.is_valid_int():
					return {"error": "--%s must be an integer, got '%s'" % [key, val]}
				cfg[key.replace("-", "_")] = int(val)
			"out":
				if val.is_empty():
					return {"error": "--out needs a path"}
				cfg["out"] = val
			"init-brain":
				if val.is_empty():
					return {"error": "--init-brain needs a path or 'none'"}
				cfg["init_brain"] = val
			"player-model":
				if val.is_empty():
					return {"error": "--player-model needs a path or 'none'"}
				cfg["model"] = val
			"set":
				for pair in val.split(",", false):
					var kv := pair.split("=")
					if kv.size() != 2 or kv[0].is_empty() or not kv[1].is_valid_float():
						return {"error": "--set expects NAME=NUMBER pairs, got '%s'" % pair}
					if not SnakeBrain.tunable_names().has(kv[0]):
						return {"error": "unknown brain parameter '%s' (known: %s)" % [kv[0], ", ".join(SnakeBrain.tunable_names())]}
					cfg["overrides"][kv[0]] = float(kv[1])
			"eval-levels":
				var parts := val.split("-")
				if parts.size() == 1 and parts[0].is_valid_int():
					parts = PackedStringArray([parts[0], parts[0]])
				if parts.size() != 2 or not parts[0].is_valid_int() or not parts[1].is_valid_int():
					return {"error": "--eval-levels must look like A-B, got '%s'" % val}
				var lo := int(parts[0])
				var hi := int(parts[1])
				if lo < 1 or hi > 100 or lo > hi:
					return {"error": "--eval-levels range must satisfy 1 <= A <= B <= 100, got '%s'" % val}
				var list: Array = []
				for l in range(lo, hi + 1):
					list.append(l)
				cfg["eval_levels"] = list
			"eval-epsilon":
				if not val.is_valid_float() or float(val) < 0.0 or float(val) > 1.0:
					return {"error": "--eval-epsilon must be a number 0-1, got '%s'" % val}
				cfg["eval_epsilon"] = float(val)
				cfg["has_eval_epsilon"] = true
			_:
				return {"error": "unknown option '--%s'" % key}
	if not mode_given:
		return {"error": "--level or --ladder is required"}
	if cfg["eval_levels"].is_empty():
		cfg["eval_levels"] = [cfg["level"]]
	return cfg
