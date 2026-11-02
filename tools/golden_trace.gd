extends SceneTree

# Behaviour-preservation test for the core refactor (Phase 1).
#
# Drives the three game scripts with a fixed RNG seed and no real-time input,
# then prints one "HASH <scenario> <sha256>" line per scenario. The hash covers
# the save files and every end-of-match message, so a single shifted RNG call or
# a changed move order produces a different hash.
#
# Run it through tools/run_golden.sh, which points user:// at a throwaway folder.
# This script refuses to run without that folder's marker file, because it
# deletes and rewrites the save files.

const MARKER_PATH := "user://golden_isolated.marker"
const FIXTURE_DIR := "user://fixture/"
const BRAIN_FILE := "ai_brain.json"
const PLAYER_MODEL_FILE := "player_model.json"
const LADDER_FILE := "ladder_progress.json"
const BEST_SCORE_FILE := "snakey_save.json"
const SAVE_FILES := [BRAIN_FILE, PLAYER_MODEL_FILE, LADDER_FILE, BEST_SCORE_FILE]

const MAX_TICKS_PER_MATCH := 5000
const TICK_DELTA := 0.14
const FAST_CLOCK_DELTA := 0.7

# Player simulation in Training mode (values of the Dir enum, stable by contract).
const DIR_UP := 0
const DIR_DOWN := 1
const DIR_LEFT := 2
const DIR_RIGHT := 3
const DIR_VECTORS := {
	DIR_UP: Vector2i(0, -1),
	DIR_DOWN: Vector2i(0, 1),
	DIR_LEFT: Vector2i(-1, 0),
	DIR_RIGHT: Vector2i(1, 0),
}
const DIR_OPPOSITE := {
	DIR_UP: DIR_DOWN,
	DIR_DOWN: DIR_UP,
	DIR_LEFT: DIR_RIGHT,
	DIR_RIGHT: DIR_LEFT,
}
const PLAYER_START := Vector2i(7, 17)
const PLAYER_MIN_ROW := 12
const PLAYER_MAX_ROW := 22
const PLAYER_MAX_COLUMN := 14
const PLAYER_KEEP_STRAIGHT_CHANCE := 0.7

var _failed: bool = false


func _initialize() -> void:
	# The tree is not running yet here, so nodes added now would not get _ready.
	_run_all.call_deferred()


func _run_all() -> void:
	if not FileAccess.file_exists(MARKER_PATH):
		printerr("golden_trace: isolation marker missing, refusing to touch user data at ", OS.get_user_data_dir())
		quit(2)
		return

	print("USER_DIR ", OS.get_user_data_dir())

	for use_fixture: bool in [true, false]:
		var brain_name := "trained" if use_fixture else "empty"
		for match_seed: int in [1, 2]:
			_run_training("training_%s_seed%d" % [brain_name, match_seed], use_fixture, match_seed, 30)
		for level: int in [1, 50, 90]:
			_run_single("single_%s_level%d" % [brain_name, level], use_fixture, level, 15)
			_run_fast("fast_%s_level%d" % [brain_name, level], use_fixture, level, 40)
		# A faster clock reaches the open phase and time-up before the snakes crash.
		_run_training("training_%s_fastclock" % brain_name, use_fixture, 3, 30, FAST_CLOCK_DELTA)
		_run_single("single_%s_fastclock" % brain_name, use_fixture, 50, 15, FAST_CLOCK_DELTA)

	quit(1 if _failed else 0)


# --- Scenario runners -------------------------------------------------------

func _run_training(scenario: String, use_fixture: bool, match_seed: int, matches: int, delta: float = TICK_DELTA) -> void:
	_reset_save_files(use_fixture, 0)
	var node: Node = _spawn("res://scenes/main.tscn")
	seed(match_seed)
	var input_rng := RandomNumberGenerator.new()
	input_rng.seed = match_seed

	var log_lines: Array = []
	for _m in range(matches):
		node._start_match()
		node.move_timer.stop()
		var head := PLAYER_START
		var heading := DIR_RIGHT
		var ticks := 0
		while not node.match_over:
			heading = _pick_player_direction(head, heading, input_rng)
			node._queue_direction(heading)
			node._process(delta)
			if node.match_over:
				break
			node._on_move_timer_timeout()
			head += DIR_VECTORS[heading]
			ticks += 1
			if ticks > MAX_TICKS_PER_MATCH:
				_fail(scenario, "match did not end")
				break
		log_lines.append("%d|%s" % [ticks, node.message_label.text])

	_report(scenario, node, log_lines)


func _run_single(scenario: String, use_fixture: bool, level: int, matches: int, delta: float = TICK_DELTA) -> void:
	_reset_save_files(use_fixture, level - 1)
	var node: Node = _spawn("res://scenes/single_player.tscn")
	node.chosen_level = level
	seed(level)

	var log_lines: Array = []
	for m in range(matches):
		if m == 0:
			node._on_start_pressed()
		else:
			node._start_match()
		node.move_timer.stop()
		var ticks := 0
		while not node.match_over:
			node._process(delta)
			if node.match_over:
				break
			node._on_move_timer_timeout()
			ticks += 1
			if ticks > MAX_TICKS_PER_MATCH:
				_fail(scenario, "match did not end")
				break
		log_lines.append("%d|%s" % [ticks, node.message_label.text])

	_report(scenario, node, log_lines)


func _run_fast(scenario: String, use_fixture: bool, level: int, matches: int) -> void:
	_reset_save_files(use_fixture, level - 1)
	var node: Node = _spawn("res://scenes/fast_train.tscn")
	node.turbo = true
	node.session_target = matches
	seed(level)

	node._on_start_session_pressed()
	var frames := 0
	while node.session_running:
		node._process(TICK_DELTA)
		frames += 1
		if frames > MAX_TICKS_PER_MATCH * matches:
			_fail(scenario, "session did not end")
			break

	var log_lines: Array = ["%d|%s|%s" % [frames, node.session_label.text, node.message_label.text]]
	_report(scenario, node, log_lines)


# --- Helpers ----------------------------------------------------------------

func _spawn(scene_path: String) -> Node:
	var scene: PackedScene = load(scene_path)
	var node: Node = scene.instantiate()
	root.add_child(node)
	if not node.is_node_ready():
		_fail(scene_path, "_ready did not run")
	node.set_process(false)
	node.set_process_unhandled_input(false)
	return node


func _pick_player_direction(head: Vector2i, heading: int, input_rng: RandomNumberGenerator) -> int:
	var options: Array = []
	for d: int in [DIR_UP, DIR_DOWN, DIR_LEFT, DIR_RIGHT]:
		if d != DIR_OPPOSITE[heading] and _player_cell_allowed(head + DIR_VECTORS[d]):
			options.append(d)
	if options.has(heading) and input_rng.randf() < PLAYER_KEEP_STRAIGHT_CHANCE:
		return heading
	return options[input_rng.randi() % options.size()]


func _player_cell_allowed(cell: Vector2i) -> bool:
	return cell.x >= 0 and cell.x <= PLAYER_MAX_COLUMN and cell.y >= PLAYER_MIN_ROW and cell.y <= PLAYER_MAX_ROW


func _reset_save_files(use_fixture: bool, highest_cleared: int) -> void:
	for file_name: String in SAVE_FILES:
		var path: String = "user://" + file_name
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)
	if use_fixture:
		for file_name: String in [BRAIN_FILE, PLAYER_MODEL_FILE]:
			var error := DirAccess.copy_absolute(FIXTURE_DIR + file_name, "user://" + file_name)
			if error != OK:
				_fail("fixture", "cannot copy %s (error %d)" % [file_name, error])
	var f := FileAccess.open("user://" + LADDER_FILE, FileAccess.WRITE)
	f.store_string(JSON.stringify({"highest_cleared": highest_cleared}))
	f.close()


func _report(scenario: String, node: Node, log_lines: Array) -> void:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	for line: String in log_lines:
		context.update((line + "\n").to_utf8_buffer())
	for file_name: String in SAVE_FILES:
		var path: String = "user://" + file_name
		var content := "<missing>"
		if FileAccess.file_exists(path):
			content = FileAccess.get_file_as_string(path)
		context.update(("%s:%s\n" % [file_name, content]).to_utf8_buffer())
	print("HASH %s %s" % [scenario, context.finish().hex_encode()])
	# Human-readable coverage note; not part of the comparison.
	print("INFO %s %s" % [scenario, _coverage_note(log_lines)])
	node.free()


func _fail(scenario: String, reason: String) -> void:
	printerr("golden_trace: %s: %s" % [scenario, reason])
	_failed = true


func _coverage_note(log_lines: Array) -> String:
	var time_up := 0
	var head_on := 0
	var first_snake_scored := 0
	var scored := RegEx.create_from_string("(Sen|Yilanin): [1-9]")
	for line: String in log_lines:
		if line.contains("Sure Doldu"):
			time_up += 1
		if line.contains("Carpisma"):
			head_on += 1
		if scored.search(line) != null:
			first_snake_scored += 1
	return "matches=%d time_up=%d head_on=%d bottom_snake_scored=%d last=%s" % [log_lines.size(), time_up, head_on, first_snake_scored, str(log_lines[-1]).replace("\n", " / ")]
