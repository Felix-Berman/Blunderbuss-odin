package blunderbuss

import "core:math"
import "core:mem"
import "core:fmt"
import "core:time"
import "core:bufio"
import "core:os"
import "base:intrinsics"

MAX_EVAL :: max(int)
MIN_EVAL :: -MAX_EVAL
MATE_EVAL :: 1_000_000
MAX_DEPTH :: 64
MAX_Q_DEPTH :: 6

DELTA_MARGIN :: 200
ASPIRATION_WINDOW :: 25
NULL_MOVE_REDUCTION :: 3

TT_MOVE_SCORE :: 100_000
CAPTURE_SCORE :: 50_000
KILLER_SCORE :: 600
MAX_HISTORY :: 20_000
HISTORY_BONUS :: 400
PROMOTION_SCORE :: 800

// global tables
t_table: TTable
continuation_history: [PieceType][64][64][64]int

SearchData :: struct {
	position: Position,
	max_depth: int,
	seldepth: int,
	nodes: int,
	max_nodes: int,
	ebf: f64,
	mate: bool,
	aborted: bool,
	infinite: bool,
	start_time: time.Tick,
	allowed_time: time.Duration,
	pv_table: [MAX_DEPTH][MAX_DEPTH]Move,
	pv_length: [MAX_DEPTH]int,
	killer_moves: [MAX_DEPTH][2]Move,
}

init_data :: proc(position: Position) -> (data: SearchData) {
	data.position = position
	data.max_depth = MAX_DEPTH
	data.max_nodes = max(int)
	data.infinite = true
	data.start_time = time.tick_now()

	// perform deep copy
	if position.history != nil {
		src := position.history[:]
		data.position.history = make(
			[dynamic]HistoryData,
			len(src),
			cap(position.history)
		)
		copy(data.position.history[:], src)
	}

	return
}

deinit_data :: proc(data: ^SearchData) {
	delete(data.position.history)
	free(data)
}

search_thread :: proc(data: rawptr) {
	data := cast(^SearchData)data
	root_search(data)

	deinit_data(data)
}

root_search :: proc(data: ^SearchData) -> int {
	intrinsics.atomic_store(&is_searching, true)

	writer: bufio.Writer
	stdout := os.stream_from_handle(os.stdout)
	bufio.writer_init(&writer, stdout)
	defer bufio.writer_destroy(&writer)

	us := data.position.turn
	masks := gen_legality_masks(&data.position)
	moves := gen_moves(&data.position, masks)
	defer delete(moves)
	
	found_mate: bool
	prev_best: Move
	best_since_depth: int
	last_aspiration_fail: int
	nodes_history: [MAX_DEPTH]int = {}
	prev_search_time: time.Duration

	alpha := MIN_EVAL
	beta := MAX_EVAL
	prev_eval: int

	ply := 0
	iterative_deepening:
	for depth in 1..=data.max_depth {
		depth_timer := time.tick_now()
		if found_mate do break

		upper_window := ASPIRATION_WINDOW
		lower_window := ASPIRATION_WINDOW
		
		if depth != 1 {
			alpha = prev_eval - lower_window
			beta = prev_eval + upper_window
		}

		sort_scores := score_moves(
			moves[:], 0, prev_best, NULL_MOVE, NIL_PIECE, data
		)
		defer delete(sort_scores)
		
		aspiration_loop:
		for {
			best_move: Move
			second_move: Move
			best_eval := MIN_EVAL
			second_eval := MIN_EVAL

			data.pv_length = {}
			move_count := 0
			for i in 0..<len(moves) {
				move := pick_move(moves[i:], sort_scores[i:])
				if !is_legal(&data.position, masks, move) do continue
				
				// useful to see formatted move in debugger
				when ODIN_DEBUG {
					move_str := to_string(move)
					defer delete(move_str)
				}

				move_count += 1
				currmove := to_string(move, context.temp_allocator)
				curr_info := fmt.tprintfln(
					"info depth %d currmove %s currmovenumber %d",
					depth, currmove, move_count
				)

				bufio.writer_write_string(&writer, curr_info)
				if time.tick_since(data.start_time) > 3 * time.Second {
					bufio.writer_flush(&writer)
				}

				prev_nodes := data.nodes

				make_move(&data.position, move)
				eval := -negamax(-beta, -alpha, depth - 1, ply + 1, NULL_MOVE, data)
				unmake_move(&data.position, move)

				if data.aborted do break iterative_deepening

				if eval > best_eval {
					second_move = best_move
					second_eval = best_eval
					best_move = move
					best_eval = eval
					update_pv(ply, move, data)
				} else if eval > second_eval {
					second_move = move
					second_eval = eval
				}

				nodes_history[depth - 1] = data.nodes - prev_nodes
			}
			bufio.writer_reset(&writer, stdout)
			free_all(context.temp_allocator)

			eval_bound := ""
			if best_eval >= beta {
				upper_window *= 2
				eval_bound = " lowerbound"
			} else if best_eval <= alpha {
				lower_window *= 2
				eval_bound = " upperbound"
			}

			eval_type: string
			print_eval := best_eval
			if best_eval > MATE_EVAL - depth {
				ply_to_mate := MATE_EVAL - best_eval
				print_eval = (ply_to_mate + 1) / 2
				eval_type = "mate"
				found_mate = true
			} else if best_eval < -MATE_EVAL + depth {
				ply_to_mate := MATE_EVAL + best_eval
				print_eval = -ply_to_mate / 2
				eval_type = "mate"
				found_mate = true
			} else {
				eval_type = "cp"
			}

			elapsed := time.tick_since(data.start_time)
			elapsed_ms := int(time.duration_milliseconds(elapsed))
			nps := f64(data.nodes) / time.duration_seconds(elapsed)
			len := data.pv_length[0]
			pv_str := to_string(data.pv_table[0][:len], context.temp_allocator)
			fmt.printfln(
				"info depth %d seldepth %d nodes %d time %d nps %d " +
				"hashfull %d score %s %d%s pv %s",
				depth, data.seldepth, data.nodes, elapsed_ms, int(nps),
				hashfull(t_table), eval_type, print_eval, eval_bound, pv_str
			)

			if move_count == 1 {
				prev_best = best_move
				break iterative_deepening
			}

			// break out of aspiration if in window
			if alpha < best_eval && best_eval < beta {
				if prev_best != best_move {
					best_since_depth = depth
					prev_best = best_move
				}

				if !data.infinite && depth - best_since_depth >= 2 && 
					depth - last_aspiration_fail >= 2 && elapsed > 0 {

					// threshold for stopping early decreases hyperbolically as
					// allocated time runs out.
					certainty_threshold := 1.5 * f64(data.allowed_time)/f64(elapsed)

					pv_stability := f64(depth - best_since_depth)

					// Increase certainty if the best move is much better than
					// the second best
					best_wdl := wdl(best_eval, 0)
					second_wdl := wdl(second_eval, 0)
					eval_delta := best_wdl - second_wdl
					eval_delta *= math.log2(f64(depth + 2))

					eval_stability := 1 / f64(1 + abs(best_eval - prev_eval))

					depth_bonus := f64(depth) / 10

					certainty := 0.35 * pv_stability + 1.8 * eval_delta +
						0.6 * eval_stability + 0.15 * depth_bonus

					if certainty >= certainty_threshold {
						break iterative_deepening
					}
				}

				// estimate the time required for next depth. Only bother
				// searching if theres time to finish 20% of it
				if !data.infinite && depth > 2 {
					two_ply_ratio := f64(nodes_history[depth - 1]) /
						f64(nodes_history[depth - 3])

					ebf := math.sqrt(two_ply_ratio)
					ebf = max(1.5, min(ebf, 4))

					// moving average smoothing
					if data.ebf != 0 {
						data.ebf = data.ebf * 0.5 + ebf * 0.5
					} else {
						data.ebf = ebf
					}

					remaining_time := data.allowed_time - elapsed
					estimated_time := f64(prev_search_time) * data.ebf
					if estimated_time > f64(remaining_time) {
						break iterative_deepening
					}
				}

				prev_eval = best_eval
				prev_search_time = time.tick_since(depth_timer)

				break
			}

			last_aspiration_fail = depth
			alpha = prev_eval - lower_window
			beta = prev_eval + upper_window
		}

	}

	move_str := to_string(prev_best)
	fmt.println("bestmove", move_str)
	delete(move_str)

	intrinsics.atomic_store(&is_searching, false)

	return data.nodes
}

negamax :: proc(alpha, beta, depth, ply: int, prev_move: Move, data: ^SearchData) -> int {
	if data.nodes % 2048 == 0 {
		if !data.infinite && time.tick_since(data.start_time) >= data.allowed_time {
			data.aborted = true
			return 0
		}
		if intrinsics.atomic_load(&stop_flag) {
			data.aborted = true
			return 0
		}
		if data.nodes >= data.max_nodes {
			data.aborted = true
			return 0
		}
	}

	data.pv_length[ply] = 0
	data.nodes += 1

	if data.position.halfmove_clk >= 100 || threefold_repetition(data, ply) {
		return 0
	}

	if ply == MAX_DEPTH {
		return evaluate(&data.position)
	}

	if depth == 0 {
		return q_search(alpha, beta, ply, prev_move, data)
	}

	alpha := alpha
	beta := beta
	depth := depth
	best_eval := MIN_EVAL
	best_move := NULL_MOVE
	tt_depth := depth
	eval_type := EvalType.UpperBound
	is_pv := beta - alpha != 1 // otherwise we're in a null window

	prev_piece := NIL_PIECE
	if prev_move != NULL_MOVE {
		ok: bool
		prev_piece, ok = piece_on(&data.position, prev_move.to)
		assert(ok, "No piece found at previous move.to")
	}

	zob_hash := data.position.hash
	tt_entry := probe_ttable(t_table, zob_hash)
	if tt_entry.hash == zob_hash {
		best_move = tt_entry.best_move

		if tt_entry.depth >= depth {
			tt_eval := tt_entry.eval
			if tt_eval >= MATE_EVAL - MAX_DEPTH {
				tt_eval -= ply
			} else if tt_eval <= -MATE_EVAL + MAX_DEPTH {
				tt_eval += ply
			}

			switch tt_entry.eval_type {
			case .Exact:
				return tt_eval
			case .LowerBound:
				if tt_eval >= beta {
					return tt_eval
				}
				alpha = max(alpha, tt_eval)
			case .UpperBound:
				if tt_eval <= alpha {
					return tt_eval
				}
				beta = min(beta, tt_eval)
			}

			if alpha >= beta {
				return alpha
			}
		}
	}


	us := data.position.turn
	masks := gen_legality_masks(&data.position)
	moves := gen_moves(&data.position, masks)
	sort_scores := score_moves(moves[:], ply, best_move, prev_move, prev_piece, data)
	rejected_quiets := make([dynamic]Move, 0, len(moves))
	defer {
		delete(moves)
		delete(sort_scores)
		delete(rejected_quiets)
	}

	// reverse futility pruning
	// skip when in check, pv node, or there is a tt move
	eval := evaluate(&data.position)
	margin := 150 * depth
	in_check := is_in_check(&data.position, masks.danger)
	if !in_check && !is_pv && best_move == NULL_MOVE && eval >= beta + margin {
		return eval
	}

	// null move pruning
	if !in_check && !is_pawn_endgame(data.position) {
		null_depth := depth - NULL_MOVE_REDUCTION - 1

		if null_depth >= 0 {
			make_null_move(&data.position)
			eval := -negamax(-beta, -beta + 1, null_depth, ply + 1, NULL_MOVE, data)
			unmake_null_move(&data.position)

			if eval >= beta {
				ttable_insert(&t_table, TTableEntry{
					data.position.hash,
					null_depth,
					eval,
					.LowerBound,
					NULL_MOVE,
				})
				return eval
			}
		}
	}

	move_count := 0
	for i in 0..<len(moves) {
		move := pick_move(moves[i:], sort_scores[i:])
		if !is_legal(&data.position, masks, move) do continue
		flags := get_flags(move)
		move_count += 1

		// useful to see formatted move in debugger
		when ODIN_DEBUG {
			move_str := to_string(move)
			defer delete(move_str)
		}

		// late move reduction (LMR)
		r := 0
		if !is_pv && depth > 2 && move_count > 2 {
			r = cast(int)math.floor(math.ln(f32(depth)) * math.ln(f32(move_count)))
			r = max(r, 1)
			r = min(r, depth - 2)
		}

		make_move(&data.position, move)
		eval: int
		// search first move with full window
		if move_count == 1 {
			eval = -negamax(-beta, -alpha, depth - 1, ply + 1, move, data)
		} else {
			// otherwise apply null window and reduce depth
			eval = -negamax(-alpha - 1, -alpha, depth - r - 1, ply + 1, move, data)

			// repeat with full depth
			if eval > alpha && r > 0 {
				r = 0
				eval = -negamax(
					-alpha - 1, -alpha, depth - 1, ply + 1, move, data
				)
			}

			// repeat the full search if we can't perform a cutoff
			if eval > alpha && eval < beta && is_pv {
				r = 0
				eval = -negamax(-beta, -alpha, depth - 1, ply + 1, move, data)
			}
		}
		unmake_move(&data.position, move)

		if data.aborted do return 0

		if eval > best_eval {
			best_eval = eval
			best_move = move
			tt_depth = depth - r

			if eval >= beta {
				if !is_dynamic(flags) {
					store_killer(move, ply, data)
					bonus := min(depth*depth, HISTORY_BONUS)
					update_history(prev_piece, prev_move, move, depth*depth)

					// history maluses
					for move in rejected_quiets {
						update_history(prev_piece, prev_move, move, -bonus/2)
					}
				}
				eval_type = .LowerBound
				break
			}

			if eval > alpha {
				alpha = eval
				update_pv(ply, move, data)
				eval_type = .Exact
			}
		}

		if flags & {.Capture, .Promotion} == QUIET {
			append(&rejected_quiets, move)
		}
	}

	if move_count == 0 {
		if is_in_check(&data.position, masks.danger) {
			return -MATE_EVAL + ply
		}
		return 0
	}

	// Store mate scores in transposition table relative to node instead of root
	tt_eval := best_eval
	if tt_eval >= MATE_EVAL - MAX_DEPTH {
		tt_eval += ply
	} else if tt_eval <= -MATE_EVAL + MAX_DEPTH {
		tt_eval -= ply
	}

	ttable_insert(&t_table, TTableEntry{
		data.position.hash,
		tt_depth,
		tt_eval,
		eval_type,
		best_move,
	})

	return best_eval
}

q_search :: proc(alpha, beta, ply: int, prev_move: Move, data: ^SearchData) -> int {
	if data.nodes % 2048 == 0 {
		if !data.infinite && time.tick_since(data.start_time) >= data.allowed_time {
			data.aborted = true
			return 0
		}
		if intrinsics.atomic_load(&stop_flag) {
			data.aborted = true
			return 0
		}
		if data.nodes >= data.max_nodes {
			data.aborted = true
			return 0
		}
	}

	data.nodes += 1

	if data.position.halfmove_clk >= 100 || fast_repetition(data) {
		return 0
	}

	if ply >= MAX_DEPTH {
		return evaluate(&data.position)
	}

	if ply > data.seldepth {
		data.seldepth = ply
	}

	data.pv_length[ply] = 0

	us := data.position.turn
	them := toggle(us)
	masks := gen_legality_masks(&data.position)
	in_check := is_in_check(&data.position, masks.danger)
	alpha := alpha
	best_move: Move
	best_eval := MIN_EVAL
	standing_pat: int

	prev_piece := NIL_PIECE
	if prev_move != NULL_MOVE {
		ok: bool
		prev_piece, ok = piece_on(&data.position, prev_move.to)
		assert(ok, "No piece found at previous move.to")
	}

	if !in_check {
		standing_pat = evaluate(&data.position)
		if standing_pat >= beta {
			return standing_pat
		}
		if standing_pat > alpha {
			alpha = standing_pat
		}

		big_delta := piece_value[.Queen]

		may_promote: u64 = RANK_7 if us == .White else RANK_2
		if may_promote & data.position.pieces[us][.Pawn] != 0 {
			big_delta += piece_value[.Queen] - piece_value[.Pawn]
		}

		// exit early if it's very unlikely for any move to improve alpha
		if standing_pat + big_delta < alpha {
			return standing_pat
		}

		best_eval = standing_pat
	}

	moves := gen_moves(&data.position, masks)
	sort_scores := score_moves(
		moves[:], ply, best_move, prev_move, prev_piece, data
	)

	defer {
		delete(moves)
		delete(sort_scores)
	}

	move_count := 0
	for i in 0..<len(moves) {
		move := pick_move(moves[i:], sort_scores[i:])
		if !is_legal(&data.position, masks, move) do continue
		flags := get_flags(move)
		if !in_check && !is_dynamic(flags) do continue
		move_count += 1

		when ODIN_DEBUG {
			// useful to see formatted move in debugger
			move_str := to_string(move)
			defer delete(move_str)

			if .Capture in flags {
				// validate static exchange accuracy
				see_val := see(&data.position, move)
				recursive_see_val := recursive_see_root(&data.position, move)
				if see_val != recursive_see_val {
					display(data.position)
					fmt.println(to_string(move, context.temp_allocator))
					fmt.println(see_val, "!=", recursive_see_val)
					panic("static exchange evaluation error")
				}
			}
		}

		// delta pruning
		if !in_check && .Capture in flags && .Promotion not_in flags {
			captured_val: int
			if flags == EP_CAPTURE {
				captured_val = piece_value[.Pawn]
			} else if .Capture in flags {
				captured_piece, ok := piece_on(&data.position, move.to)
				assert(ok, "no piece on captured square")
				captured_val = piece_value[captured_piece.type]
			}
			
			if standing_pat + captured_val + DELTA_MARGIN < alpha {
				continue
			}

			// static exchange evaluation (don't consider trades losing material)
			// see value already computed during sort scoring
			if sort_scores[i] < 0 {
				continue
			}
		}

		make_move(&data.position, move)
		eval := -q_search(-beta, -alpha, ply + 1, move, data)
		unmake_move(&data.position, move)

		if data.aborted do return 0
		
		if eval >= beta {
			return eval
		}

		if eval > best_eval {
			best_eval = eval

			if eval > alpha {
				alpha = eval
				update_pv(ply, move, data)
			}
		}
	}

	if in_check && move_count == 0 {
		return -MATE_EVAL + ply
	}

	return best_eval
}

update_pv :: proc(ply: int, move: Move, data: ^SearchData) {
	assert(ply < MAX_DEPTH)
	data.pv_table[ply][ply] = move

	if ply >= MAX_DEPTH - 1 {
		data.pv_length[ply] = 0
		return
	}

	data.pv_length[ply] = data.pv_length[ply + 1] + 1
	mem.copy_non_overlapping(
		&data.pv_table[ply][ply + 1],
		&data.pv_table[ply + 1][ply + 1],
		data.pv_length[ply + 1] * size_of(Move)
	)
}

// score moves in order of:
//	TT move
//	positive trades/captures
//	equal trades
//	promotions
//	killer moves
//	continuation history
//	negative trades/captures
score_moves :: proc(
	movelist: []Move,
	ply: int,
	best_move, prev_move: Move,
	prev_piece: Piece,
	data: ^SearchData
) -> []int {

	scores := make([]int, len(movelist))

	move_loop:
	for move, i in movelist {
		if move == NULL_MOVE do break

		if move == best_move {
			scores[i] = TT_MOVE_SCORE
			continue
		}

		flags := get_flags(move)

		if .Promotion in flags {
			switch flags &~ {.Capture} {
			case KNIGHT_PROMOTION:
				scores[i] += piece_value[.Knight]
			case BISHOP_PROMOTION:
				scores[i] += piece_value[.Bishop]
			case ROOK_PROMOTION:
				scores[i] += piece_value[.Rook]
			case QUEEN_PROMOTION:
				scores[i] += piece_value[.Queen]
			}

			scores[i] -= piece_value[.Pawn]
		}

		if .Capture in flags {
			see_val := see(&data.position, move)
			scores[i] += see_val

			if see_val >= 0 {
				scores[i] += CAPTURE_SCORE
			} else {
				scores[i] -= CAPTURE_SCORE
			}

			continue
		}

		if is_dynamic(flags) {
			continue
		}

		if prev_move != NULL_MOVE {
			scores[i] += continuation_history[prev_piece.type][prev_move.to][move.from][move.to]
		}

		for killer in data.killer_moves[ply] {
			if move == killer {
				scores[i] = max(scores[i], KILLER_SCORE)
			}
		}

	}

	return scores
}

pick_move :: proc(movelist: []Move, scores: []int) -> Move {
	best_score, best_i: int

	for score, i in scores {
		if score > best_score {
			best_score, best_i = score, i
		}
	}

	if best_i != 0 {
		move_temp := movelist[0]
		movelist[0] = movelist[best_i]
		movelist[best_i] = move_temp

		score_temp := scores[0]
		scores[0] = scores[best_i]
		scores[best_i] = score_temp
	}

	return movelist[0]
}

threefold_repetition :: proc(data: ^SearchData, search_ply: int) -> bool {
	ply_to_search := data.position.ply - data.position.last_irreversible_ply

	if ply_to_search < 4 {
		return false
	}

	history_len := len(data.position.history)
	repetition_count: int
	for i: int = 4; i <= ply_to_search; i += 2 {
		if data.position.history[history_len - i].hash == data.position.hash {
			if search_ply > 2 do return true
			repetition_count += 1
			if repetition_count == 2 do return true	
		}
	}

	return false
}

fast_repetition :: proc(data: ^SearchData) -> bool {
    ply_to_search := data.position.ply - data.position.last_irreversible_ply

    history_len := len(data.position.history)
    current_hash := data.position.hash

    if ply_to_search >= 4 && history_len >= 4 {
        if data.position.history[history_len - 4].hash == current_hash {
            return true
        }
    }

    if ply_to_search >= 6 && history_len >= 6 {
        if data.position.history[history_len - 6].hash == current_hash {
            return true
        }
    }

    return false
}

see :: proc(position: ^Position, move: Move) -> int {
	to := int(move.to)
	to_bb := bitboard(to)
	victim_type: PieceType
	us := position.turn
	occ := occupied(position)
	gain: [32]int
	depth := 0

	if EP_CAPTURE == get_flags(move) {
		victim_type = .Pawn
		ep_bb := bitboard(position.ep_sq)
		occ &~= ep_bb >> 8 if us == .White else ep_bb << 8
	} else {
		victim, ok := piece_on(position, to)
		assert(ok, "No piece on captured to square")
		victim_type = victim.type
	}

	gain[0] = piece_value[victim_type]

	attackers := attackers_to(position, to)
	attacker, ok := piece_on(position, move.from)
	assert(ok, "Attempt to move from empty square")
	assert(
		attackers[us] & bitboard(move.from) != 0,
		"Initial attacker not included in see attack set"
	)

	victim_type = attacker.type
	occ &~= bitboard(move.from)
	us = toggle(us)

	for depth < 32 {
		// calculate gain
		depth += 1
		gain[depth] = piece_value[victim_type] - gain[depth - 1]

		// include revealed x-ray attacks
		bishop_attacks := magic_bishop_moves(to, occ)
		rook_attacks := magic_rook_moves(to, occ)
		attackers[.White] |= bishop_attacks & position.pieces[.White][.Bishop]
		attackers[.Black] |= bishop_attacks & position.pieces[.Black][.Bishop]
		attackers[.White] |= bishop_attacks & position.pieces[.White][.Queen]
		attackers[.Black] |= bishop_attacks & position.pieces[.Black][.Queen]
		attackers[.White] |= rook_attacks & position.pieces[.White][.Rook]
		attackers[.Black] |= rook_attacks & position.pieces[.Black][.Rook]
		attackers[.White] |= rook_attacks & position.pieces[.White][.Queen]
		attackers[.Black] |= rook_attacks & position.pieces[.Black][.Queen]

		// find least valuable attacker
		att := attackers[us] & occ
		if att == 0 {
			break
		}

		if victim_type == .King {
			gain[depth - 1] = -gain[depth]
			break
		}

		next_attacker: PieceType
		next_sq: int

		no_attackers := true
		for piece in PieceType {
			if bb := att & position.pieces[us][piece]; bb != 0 {
				next_attacker = piece
				next_sq = lsb(bb)
				no_attackers = false
				break
			}
		}

		assert(
			!no_attackers,
			"Misalignment between piece bbs and att bb in see"
		)

		victim_type = next_attacker
		occ &~= bitboard(next_sq)
		us = toggle(us)
	}
	
	// walk back sequence of captures
	for d := depth - 1; d > 0; d -= 1 {
		// side at depth d will only make capture if it improves current value
		// gained
		if gain[d - 1] > -gain[d] {
			gain[d - 1] = -gain[d]
		}
	}

	return gain[0]
}

recursive_see :: proc(position: ^Position, to: int) -> (value: int) {
	us := position.turn
	victim, ok := piece_on(position, to)
	assert(ok, "No victim in recursive see")
	victim_val := piece_value[victim.type]

	attackers := attackers_to(position, to)
	next_attacker: PieceType
	from: int

	no_attackers := true
	for piece in PieceType {
		if bb := attackers[us] & position.pieces[us][piece]; bb != 0 {
			next_attacker = piece
			from = lsb(bb)
			no_attackers = false
			break
		}
	}

	if no_attackers {
		return 0
	}

	if victim.type == .King {
		return victim_val
	}

	move := build_move(from, to, {.Capture})
	make_move(position, move)
	value += max(0, victim_val - recursive_see(position, to))
	unmake_move(position, move)

	return
}

recursive_see_root :: proc(position: ^Position, move: Move) -> (value: int) {
	move := move
	to := int(move.to)

	victim_type: PieceType
	if EP_CAPTURE == get_flags(move) {
		victim_type = .Pawn
	} else {
		victim, ok := piece_on(position, to)
		assert(ok, "No victim in recursive see")
		victim_type = victim.type

		// strip promotion information from flags
		set_flags(&move, {.Capture})	
	}

	victim_val := piece_value[victim_type]

	if victim_type == .King {
		return victim_val
	}

	make_move(position, move)
	value += victim_val - recursive_see(position, to)
	unmake_move(position, move)

	return
}

store_killer :: proc(move: Move, ply: int, data: ^SearchData) {
	assert(ply < MAX_DEPTH)

	if data.killer_moves[ply][0] != move {
		data.killer_moves[ply][1] = data.killer_moves[ply][0]
		data.killer_moves[ply][0] = move
	}
}

update_history :: proc(prev_piece: Piece, prev_move, move: Move, bonus: int) {
	if prev_move == NULL_MOVE do return

	bonus := bonus
	history := &continuation_history[prev_piece.type][prev_move.to][move.from][move.to]

	// history gravity:
	// entries with higher scores recieve a smaller fraction of bonus
	history^ += bonus - abs(bonus) * history^ / MAX_HISTORY
}	
