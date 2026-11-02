class_name PresetAI
extends RefCounted
## Ladder rival logic: difficulty parameters per level and the move decision.
## Used by Tekli Oyun (single_player) and Hizli Antrenman (fast_train).
## Uses the global RNG (randf / randi) in a fixed order; keep it that way.

const LADDER_PATH := "user://ladder_progress.json"


## Difficulty parameters for a level (1-100): {mistake, safety, aggression}.
static func level_params(level: int) -> Dictionary:
	var t: float = float(level - 1) / 99.0
	var mistake: float = lerp(0.55, 0.0, t)
	var safety: float = lerp(0.0, 1.0, t)
	var aggro_t: float = clamp(float(level - 25) / 75.0, 0.0, 1.0)
	var aggression: float = lerp(0.0, 1.0, aggro_t)
	return {"mistake": mistake, "safety": safety, "aggression": aggression}


static func level_tier_name(level: int) -> String:
	if level <= 20:
		return "Cok Kolay"
	elif level <= 40:
		return "Kolay"
	elif level <= 60:
		return "Orta"
	elif level <= 80:
		return "Zor"
	else:
		return "Cok Zor"


## Picks a relative action (0=straight, 1=left, 2=right) for the rival on `side`.
## `params` is a level_params() dictionary.
static func decide(arena: SnakeArena, side: int, params: Dictionary) -> int:
	var mistake: float = params["mistake"]
	var safety: float = params["safety"]
	var aggression: float = params["aggression"]

	var own_body: Array = arena.body_of(side)
	var other_body: Array = arena.snake_bottom if side == SnakeArena.Side.TOP else arena.snake_top
	var head: Vector2i = own_body[0]
	var target: Vector2i = arena.target_for(side)
	var opp_head: Vector2i = other_body[0]
	var heading: int = arena.direction_of(side)

	var candidates: Array = []
	for a in [0, 1, 2]:
		var d: int = SnakeArena.relative_to_direction(a, heading)
		var np: Vector2i = head + SnakeArena.dir_vector(d)
		if not arena.is_blocked(np, own_body, other_body):
			candidates.append({"action": a, "pos": np})

	if candidates.is_empty():
		return 0

	if randf() < mistake:
		var pick: Dictionary = candidates[randi() % candidates.size()]
		return pick["action"]

	var best_action: int = candidates[0]["action"]
	var best_score := -INF
	for c in candidates:
		var np: Vector2i = c["pos"]
		var food_dist: int = absi(np.x - target.x) + absi(np.y - target.y)
		var s: float = -float(food_dist)
		if safety > 0.0:
			var space: int = flood_fill_count(arena, np, own_body, other_body)
			s += safety * float(space) * 0.15
		if aggression > 0.0 and arena.phase == 2:
			var opp_dist: int = absi(np.x - opp_head.x) + absi(np.y - opp_head.y)
			s += aggression * (-float(opp_dist)) * 0.5
		if s > best_score:
			best_score = s
			best_action = c["action"]
	return best_action


static func flood_fill_count(arena: SnakeArena, start: Vector2i, own_body: Array, other_body: Array) -> int:
	var visited := {}
	visited[start] = true
	var queue: Array = [start]
	var count := 0
	while not queue.is_empty():
		var cur: Vector2i = queue.pop_front()
		count += 1
		for d in [Vector2i(0, -1), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(1, 0)]:
			var np: Vector2i = cur + d
			if visited.has(np):
				continue
			if arena.is_blocked(np, own_body, other_body):
				continue
			visited[np] = true
			queue.append(np)
	return count


## Reads the highest cleared ladder level from user://ladder_progress.json (0 if missing or invalid).
static func load_highest_cleared() -> int:
	if FileAccess.file_exists(LADDER_PATH):
		var f := FileAccess.open(LADDER_PATH, FileAccess.READ)
		if f:
			var data = JSON.parse_string(f.get_as_text())
			f.close()
			if typeof(data) == TYPE_DICTIONARY and data.has("highest_cleared"):
				return int(data["highest_cleared"])
	return 0


static func save_highest_cleared(value: int) -> void:
	var f := FileAccess.open(LADDER_PATH, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify({"highest_cleared": value}))
		f.close()
