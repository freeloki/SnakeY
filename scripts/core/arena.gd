class_name SnakeArena
extends RefCounted
## Pure game rules for one two-snake match: grid, barrier phases, food, movement,
## collisions and the Q-learning state encoding. No drawing, input or Node access.
## Used by Antrenman (main), Tekli Oyun (single_player) and Hizli Antrenman (fast_train).
##
## Two layouts, selected by `mirrored_food`:
##  - true  (Antrenman): food spawns in mirrored pairs, BOTTOM (player) moves first.
##  - false (Tekli/Hizli): top and bottom food are independent, TOP (preset) moves first.

const GRID_WIDTH := 15
const HALF_HEIGHT := 11
const BARRIER_ROW := HALF_HEIGHT
const GRID_HEIGHT := HALF_HEIGHT * 2 + 1
const PHASE1_DURATION := 5.0

enum Dir { UP, DOWN, LEFT, RIGHT }
enum Side { TOP, BOTTOM }
enum TimeEvent { NONE, BARRIER_OPENED, TIME_UP }

# Clockwise order (screen coords): UP -> RIGHT -> DOWN -> LEFT -> UP
const CYCLE := [Dir.UP, Dir.RIGHT, Dir.DOWN, Dir.LEFT]

var phase2_duration: float
var mirrored_food: bool

var snake_top: Array = []
var snake_bottom: Array = []
var direction_top: int = Dir.RIGHT
var direction_bottom: int = Dir.RIGHT

var food_top: Vector2i
var food_bottom: Vector2i
var food_shared: Vector2i

var score_top: int = 0
var score_bottom: int = 0

var phase: int = 1
var elapsed: float = 0.0


func _init(p_phase2_duration: float, p_mirrored_food: bool) -> void:
	phase2_duration = p_phase2_duration
	mirrored_food = p_mirrored_food


## Starts a fresh match: snakes, scores, phase and the initial food.
func reset() -> void:
	phase = 1
	elapsed = 0.0
	score_top = 0
	score_bottom = 0

	direction_top = Dir.RIGHT
	direction_bottom = Dir.RIGHT

	var mid_x := GRID_WIDTH / 2

	snake_top.clear()
	var top_row := HALF_HEIGHT / 2
	snake_top.append(Vector2i(mid_x, top_row))
	snake_top.append(Vector2i(mid_x - 1, top_row))
	snake_top.append(Vector2i(mid_x - 2, top_row))

	snake_bottom.clear()
	var bottom_row := BARRIER_ROW + 1 + HALF_HEIGHT / 2
	snake_bottom.append(Vector2i(mid_x, bottom_row))
	snake_bottom.append(Vector2i(mid_x - 1, bottom_row))
	snake_bottom.append(Vector2i(mid_x - 2, bottom_row))

	if mirrored_food:
		var initial_food_pair := _spawn_mirrored_food_pair(snake_top, snake_bottom)
		food_top = initial_food_pair[0]
		food_bottom = initial_food_pair[1]
	else:
		food_top = _spawn_food_in_range(0, BARRIER_ROW - 1, snake_top)
		food_bottom = _spawn_food_in_range(BARRIER_ROW + 1, GRID_HEIGHT - 1, snake_bottom)


## Adds time and reports a barrier opening or the end of the match.
func advance_time(delta: float) -> int:
	elapsed += delta
	if phase == 1 and elapsed >= PHASE1_DURATION:
		phase = 2
		food_shared = _spawn_food_in_range(0, GRID_HEIGHT - 1, snake_bottom + snake_top)
		return TimeEvent.BARRIER_OPENED
	elif phase == 2 and elapsed >= PHASE1_DURATION + phase2_duration:
		return TimeEvent.TIME_UP
	return TimeEvent.NONE


# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------

static func dir_vector(d: int) -> Vector2i:
	match d:
		Dir.UP:
			return Vector2i(0, -1)
		Dir.DOWN:
			return Vector2i(0, 1)
		Dir.LEFT:
			return Vector2i(-1, 0)
		Dir.RIGHT:
			return Vector2i(1, 0)
	return Vector2i.ZERO


## Relative actions are 0=straight, 1=turn left, 2=turn right (never a reversal).
static func relative_to_direction(action: int, heading: int) -> int:
	var idx: int = CYCLE.find(heading)
	if action == 0:
		return heading
	elif action == 1:
		return CYCLE[(idx + 3) % 4]
	else:
		return CYCLE[(idx + 1) % 4]


static func direction_to_relative(new_dir: int, old_dir: int) -> int:
	if new_dir == old_dir:
		return 0
	var idx: int = CYCLE.find(old_dir)
	if new_dir == CYCLE[(idx + 3) % 4]:
		return 1
	return 2


static func distance(a: Vector2i, b: Vector2i) -> int:
	return absi(a.x - b.x) + absi(a.y - b.y)


func is_blocked(pos: Vector2i, own_body: Array, other_body: Array) -> bool:
	if pos.x < 0 or pos.x >= GRID_WIDTH or pos.y < 0 or pos.y >= GRID_HEIGHT:
		return true
	if phase == 1 and pos.y == BARRIER_ROW:
		return true
	if own_body.has(pos):
		return true
	if phase == 2 and other_body.has(pos):
		return true
	return false


func head_of(side: int) -> Vector2i:
	return snake_top[0] if side == Side.TOP else snake_bottom[0]


func body_of(side: int) -> Array:
	return snake_top if side == Side.TOP else snake_bottom


func direction_of(side: int) -> int:
	return direction_top if side == Side.TOP else direction_bottom


## The food this side is currently chasing.
func target_for(side: int) -> Vector2i:
	if phase == 2:
		return food_shared
	return food_top if side == Side.TOP else food_bottom


# ---------------------------------------------------------------------------
# Q-learning state (bit layout and key format are shared with ai_brain.json:
# do not change them without a migration plan).
# ---------------------------------------------------------------------------

func compute_state(side: int) -> String:
	var own_body: Array = body_of(side)
	var other_body: Array = snake_bottom if side == Side.TOP else snake_top
	var heading: int = direction_of(side)
	var head: Vector2i = own_body[0]
	var target: Vector2i = target_for(side)
	var opp_head: Vector2i = other_body[0]

	var bits := 0
	if _danger_for_action(0, head, heading, own_body, other_body):
		bits |= 1
	if _danger_for_action(1, head, heading, own_body, other_body):
		bits |= 2
	if _danger_for_action(2, head, heading, own_body, other_body):
		bits |= 4
	if target.y < head.y:
		bits |= 8
	if target.y > head.y:
		bits |= 16
	if target.x < head.x:
		bits |= 32
	if target.x > head.x:
		bits |= 64
	if opp_head.y < head.y:
		bits |= 128
	if opp_head.y > head.y:
		bits |= 256
	if opp_head.x < head.x:
		bits |= 512
	if opp_head.x > head.x:
		bits |= 1024
	var opp_dist: int = absi(opp_head.x - head.x) + absi(opp_head.y - head.y)
	if opp_dist <= 5:
		bits |= 2048
	if phase == 2:
		bits |= 4096

	return str(bits) + "_" + str(heading)


func _danger_for_action(action: int, head: Vector2i, heading: int, own_body: Array, other_body: Array) -> bool:
	var d: int = relative_to_direction(action, heading)
	var np: Vector2i = head + dir_vector(d)
	return is_blocked(np, own_body, other_body)


# ---------------------------------------------------------------------------
# Movement
# ---------------------------------------------------------------------------

## Applies both directions for one tick. On a collision nobody moves; otherwise
## both snakes move (and eat) in the layout's order.
## Returns {top_crashed, bottom_crashed, top_ate, bottom_ate}.
func step(new_dir_top: int, new_dir_bottom: int) -> Dictionary:
	direction_top = new_dir_top
	direction_bottom = new_dir_bottom

	# Targets are fixed before anyone moves, even if the first snake's meal respawns food.
	var target_top: Vector2i = target_for(Side.TOP)
	var target_bottom: Vector2i = target_for(Side.BOTTOM)

	var new_head_top: Vector2i = snake_top[0] + dir_vector(direction_top)
	var new_head_bottom: Vector2i = snake_bottom[0] + dir_vector(direction_bottom)

	var top_crashed := is_blocked(new_head_top, snake_top, snake_bottom)
	var bottom_crashed := is_blocked(new_head_bottom, snake_bottom, snake_top)

	if new_head_bottom == new_head_top:
		bottom_crashed = true
		top_crashed = true
	else:
		if snake_top.has(new_head_bottom):
			bottom_crashed = true
		if snake_bottom.has(new_head_top):
			top_crashed = true

	var result := {
		"top_crashed": top_crashed,
		"bottom_crashed": bottom_crashed,
		"top_ate": false,
		"bottom_ate": false,
	}
	if top_crashed or bottom_crashed:
		return result

	if mirrored_food:
		result["bottom_ate"] = _move_snake(Side.BOTTOM, new_head_bottom, target_bottom)
		result["top_ate"] = _move_snake(Side.TOP, new_head_top, target_top)
	else:
		result["top_ate"] = _move_snake(Side.TOP, new_head_top, target_top)
		result["bottom_ate"] = _move_snake(Side.BOTTOM, new_head_bottom, target_bottom)
	return result


func _move_snake(side: int, new_head: Vector2i, target: Vector2i) -> bool:
	var body: Array = body_of(side)
	body.insert(0, new_head)
	var ate: bool = new_head == target
	if not ate:
		body.pop_back()
		return false

	if side == Side.TOP:
		score_top += 1
	else:
		score_bottom += 1

	if phase == 1:
		if mirrored_food:
			var respawn_pair := _spawn_mirrored_food_pair(snake_top, snake_bottom)
			food_top = respawn_pair[0]
			food_bottom = respawn_pair[1]
		elif side == Side.TOP:
			food_top = _spawn_food_in_range(0, BARRIER_ROW - 1, snake_top)
		else:
			food_bottom = _spawn_food_in_range(BARRIER_ROW + 1, GRID_HEIGHT - 1, snake_bottom)
	else:
		food_shared = _spawn_food_in_range(0, GRID_HEIGHT - 1, snake_bottom + snake_top)
	return true


# ---------------------------------------------------------------------------
# Food
# ---------------------------------------------------------------------------

func _spawn_food_in_range(row_min: int, row_max: int, exclude_cells: Array) -> Vector2i:
	var free_cells: Array = []
	for x in range(GRID_WIDTH):
		for y in range(row_min, row_max + 1):
			var p := Vector2i(x, y)
			if not exclude_cells.has(p):
				free_cells.append(p)
	if free_cells.is_empty():
		return Vector2i(-1, -1)
	return free_cells[randi() % free_cells.size()]


## In phase 1 the food appears at mirrored points of the top and bottom halves
## (same column, same distance from the barrier), so the AI faces the mirror
## image of what the player just faced and imitation learning stays meaningful.
func _spawn_mirrored_food_pair(exclude_top: Array, exclude_bottom: Array) -> Array:
	var candidates: Array = []
	for x in range(GRID_WIDTH):
		for y in range(0, BARRIER_ROW):
			var top := Vector2i(x, y)
			var bottom := Vector2i(x, 2 * BARRIER_ROW - y)
			if not exclude_top.has(top) and not exclude_bottom.has(bottom):
				candidates.append([top, bottom])
	if candidates.is_empty():
		# No free mirrored cell (very rare): fall back to independent placement.
		var fallback_top: Vector2i = _spawn_food_in_range(0, BARRIER_ROW - 1, exclude_top)
		var fallback_bottom: Vector2i = _spawn_food_in_range(BARRIER_ROW + 1, GRID_HEIGHT - 1, exclude_bottom)
		return [fallback_top, fallback_bottom]
	return candidates[randi() % candidates.size()]
