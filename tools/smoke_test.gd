extends SceneTree

# Smoke test: loads every scene under res://scenes/, runs each for a few frames
# and fails if any error was reported. Godot's exit code ignores script errors,
# so a Logger collects every error message the engine prints during the run.
#
# Run it through tools/run_smoke.sh, which points user:// at a throwaway folder.
# Scenes such as main.tscn start a match on their own and may save the brain, so
# this script refuses to run without that folder's marker file.
#
# Exit codes: 0 = pass, 1 = failure, 2 = refused (no isolation marker).

const MARKER_PATH := "user://smoke_isolated.marker"
const SCENE_DIR := "res://scenes/"
const FRAMES_PER_SCENE := 60
const WATCHDOG_SECONDS := 60.0
const EXIT_FAIL := 1
const EXIT_REFUSED := 2


# Collects engine and script errors. Callbacks may arrive from other threads.
class ErrorCollector extends Logger:
	var mutex := Mutex.new()
	var errors: Array[String] = []

	func _log_error(function: String, file: String, line: int, code: String, rationale: String, _editor_notify: bool, error_type: int, _script_backtraces: Array[ScriptBacktrace]) -> void:
		# Warnings are not failures.
		if error_type == ERROR_TYPE_WARNING:
			return
		var text := rationale if not rationale.is_empty() else code
		mutex.lock()
		errors.append("%s:%d (%s): %s" % [file, line, function, text])
		mutex.unlock()

	func count() -> int:
		mutex.lock()
		var n := errors.size()
		mutex.unlock()
		return n

	func snapshot(from_index: int) -> Array[String]:
		mutex.lock()
		var out: Array[String] = errors.slice(from_index)
		mutex.unlock()
		return out


var _collector := ErrorCollector.new()
var _failures: int = 0
var _finished: bool = false


func _initialize() -> void:
	# The tree is not running yet here, so nodes added now would not get _ready.
	_run_all.call_deferred()


func _run_all() -> void:
	if not FileAccess.file_exists(MARKER_PATH):
		printerr("smoke_test: isolation marker missing, refusing to run against ", OS.get_user_data_dir())
		quit(EXIT_REFUSED)
		return

	OS.add_logger(_collector)
	_start_watchdog()

	var scenes := _find_scenes()
	if scenes.is_empty():
		_fail("scenes", "no .tscn found in " + SCENE_DIR)
	for scene_path in scenes:
		await _run_scene(scene_path)

	_finish()


func _find_scenes() -> Array[String]:
	var found: Array[String] = []
	var dir := DirAccess.open(SCENE_DIR)
	if dir == null:
		return found
	for file_name in dir.get_files():
		# Exported builds list "x.tscn.remap"; load() wants the plain name.
		if file_name.ends_with(".remap"):
			file_name = file_name.trim_suffix(".remap")
		if file_name.ends_with(".tscn") and not found.has(SCENE_DIR + file_name):
			found.append(SCENE_DIR + file_name)
	found.sort()
	return found


func _run_scene(scene_path: String) -> void:
	var first_error := _collector.count()
	var problems: Array[String] = []

	var packed := load(scene_path) as PackedScene
	if packed == null:
		problems.append("load() did not return a PackedScene")
	else:
		var node := packed.instantiate()
		if node == null:
			problems.append("instantiate() returned null")
		else:
			if node.get_script() == null:
				problems.append("root node has no script (parse error?)")
			root.add_child(node)
			if not node.is_node_ready():
				problems.append("_ready did not run")
			for _i in range(FRAMES_PER_SCENE):
				await process_frame
				# A scene may switch scenes or free itself; stop waiting then.
				if not is_instance_valid(node):
					break
			# Scenes may have replaced themselves via change_scene_to_*.
			if is_instance_valid(node):
				node.free()
			if current_scene != null and is_instance_valid(current_scene):
				current_scene.free()
				current_scene = null

	for message in _collector.snapshot(first_error):
		problems.append("engine error: " + message)

	if problems.is_empty():
		print("SMOKE ", scene_path, ": OK (", FRAMES_PER_SCENE, " frames)")
	else:
		print("SMOKE ", scene_path, ": FAIL")
		for p in problems:
			_fail(scene_path, p)


func _start_watchdog() -> void:
	var timer := create_timer(WATCHDOG_SECONDS)
	timer.timeout.connect(_on_watchdog)


func _on_watchdog() -> void:
	if _finished:
		return
	_fail("watchdog", "run exceeded %d seconds" % int(WATCHDOG_SECONDS))
	_finish()


func _fail(scope: String, reason: String) -> void:
	printerr("smoke_test: ", scope, ": ", reason)
	_failures += 1


func _finish() -> void:
	if _finished:
		return
	_finished = true
	OS.remove_logger(_collector)
	if _failures == 0:
		print("SMOKE GECTI")
		quit(0)
	else:
		print("SMOKE KALDI: %d hata" % _failures)
		quit(EXIT_FAIL)
