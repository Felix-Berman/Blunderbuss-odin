package blunderbuss

import "core:fmt"

MAX_SCORE :: 1_000_000_000
MIN_SCORE :: -MAX_SCORE

root_search :: proc(position: ^Position, depth: int) {
	best_move: Move
	best_score := MIN_SCORE

	moves := gen_pseudo_legal_moves(position)
	defer delete(moves)

	for move in moves {
		make_move(position, move)
		defer unmake_move(position, move)

		if is_in_check(position.turn, position) do continue

		score := -negamax(position, depth - 1, MIN_SCORE, MAX_SCORE)

		if score > best_score {
			best_move, best_score = move, score
		}
	}

	fmt.println("score", best_score)
	fmt.println("bestmove", to_string(best_move, context.temp_allocator))
}

negamax :: proc(position: ^Position, depth, alpha, beta: int) -> int {
	alpha := alpha
	best_score := MIN_SCORE

	if depth == 0 {
		return eval(position)
	}

	moves := gen_pseudo_legal_moves(position)
	defer delete(moves)

	for move in moves {
		make_move(position, move)
		defer unmake_move(position, move)

		if is_in_check(position.turn, position) do continue

		score := -negamax(position, depth - 1, -beta, -alpha)
		
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
