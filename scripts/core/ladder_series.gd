class_name LadderSeries
extends RefCounted

## Ladder rule: a level is cleared by winning WINS_TO_CLEAR matches of a SERIES_LENGTH-match
## series. The series ends early once the outcome is decided. A draw is a non-win.
## State lives in memory only; nothing here touches the save files.

const SERIES_LENGTH := 5
const WINS_TO_CLEAR := 3
## Non-wins that make clearing impossible (3 of 5).
const LOSSES_TO_FAIL := SERIES_LENGTH - WINS_TO_CLEAR + 1

var wins: int = 0
var non_wins: int = 0


func reset() -> void:
	wins = 0
	non_wins = 0


## Records one match. Ignored once the series is finished. Returns true if it was counted.
func record(won: bool) -> bool:
	if is_finished():
		return false
	if won:
		wins += 1
	else:
		non_wins += 1
	return true


func matches_played() -> int:
	return wins + non_wins


func is_cleared() -> bool:
	return wins >= WINS_TO_CLEAR


func is_failed() -> bool:
	return non_wins >= LOSSES_TO_FAIL


func is_finished() -> bool:
	return is_cleared() or is_failed()


## Short UI text, e.g. "Seri: 2G 1K".
func status_text() -> String:
	return "Seri: %dG %dK" % [wins, non_wins]
