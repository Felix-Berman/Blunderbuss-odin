package blunderbuss

import "core:fmt"
import "base:intrinsics"
import "base:builtin"

MAX_SCORE :: 1_000_000_000
MIN_SCORE :: -MAX_SCORE
MAX_DEPTH :: 64

SearchInfo :: struct {
	position: Position,
	max_depth: int,
	nodes: int,
	max_nodes: int,
	mate: bool,
	stop_flag: ^bool,
	aborted: bool,
}

default_info :: proc(position: Position, stop_flag: ^bool) -> (info: SearchInfo) {
	info.position = position
	info.max_depth = MAX_DEPTH
	info.nodes = 0
	info.max_nodes = builtin.max(int)
	info.mate = false
	info.stop_flag = stop_flag
	info.aborted = false
	return
}

root_search :: proc(data: rawptr) {
	info := (^SearchInfo)(data)
	best_move: Move

	moves := gen_pseudo_legal_moves(&info.position)
	defer delete(moves)
	
	iterative_deepening:
	for depth in 1..=info.max_depth {
		best_score := MIN_SCORE

		for move in moves {
			make_move(&info.position, move)
			defer unmake_move(&info.position, move)

			if is_in_check(info.position.turn, &info.position) do continue

			score := -negamax(depth, MIN_SCORE, MAX_SCORE, info)

			if info.aborted do break iterative_deepening

			if score > best_score {
				best_move, best_score = move, score
			}
		}

		fmt.printfln("info depth %d nodes %d score cp %d",
			depth, info.nodes, best_score)
	}

	fmt.println("bestmove", to_string(best_move, context.temp_allocator))

	free(info)
}

negamax :: proc(depth, alpha, beta: int, info: ^SearchInfo) -> int {
	if info.nodes % 2048 == 0 {
		if intrinsics.atomic_load_explicit(info.stop_flag, .Relaxed) {
			info.aborted = true
			return 0
		}

		if info.nodes > info.max_nodes {
			info.aborted = true
			return 0
		}
	}

	if depth == 0 {
		return eval(&info.position)
	}

	alpha := alpha
	best_score := MIN_SCORE
	info.nodes += 1

	moves := gen_pseudo_legal_moves(&info.position)
	defer delete(moves)

	for move in moves {
		make_move(&info.position, move)
		defer unmake_move(&info.position, move)

		if is_in_check(info.position.turn, &info.position) do continue

		score := -negamax(depth - 1, -beta, -alpha, info)

		if info.aborted do return 0
		
		if score > best_score {
			best_score = score

			if score > alpha {
				alpha = score
			}
		}

		if score >= beta {
			return best_score
		}
	}

	return best_score
}
