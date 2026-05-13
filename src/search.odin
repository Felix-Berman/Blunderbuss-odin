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
CHECK_SCORE :: 20_000
MAX_HISTORY :: 20_000
HISTORY_BONUS :: 400
PROMOTION_SCORE :: 800

// probably excessive beyond depth 4 but we'll find out after tuning
FUTILITY_MARGIN := [MAX_DEPTH]int{
	100, 130, 220, 370, 580, 850, 1180, 1570,
	2020, 2530, 3100, 3730, 4420, 5170, 5980, 6850,
	7780, 8770, 9820, 10930, 12100, 13330, 14620, 15970,
	17380, 18850, 20380, 21970, 23620, 25330, 27100, 28930,
	30820, 32770, 34780, 36850, 38980, 41170, 43420, 45730,
	48100, 50530, 53020, 55570, 58180, 60850, 63580, 66370,
	69220, 72130, 75100, 78130, 81220, 84370, 87580, 90850,
	94180, 97570, 101020, 104530, 108100, 111730, 115420, 119170,
}

LMR_TABLE: [64][64]int

piece_value: [PieceType]int = {
	.Pawn = 100,
	.Knight = 300,
	.Bishop =  350,
	.Rook = 500,
	.Queen = 900,
	.King = 30_000,
}

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
	pondering: bool,
	start_time: time.Tick,
	target_time: time.Duration,
	allowed_time: time.Duration,
	pv_table: [MAX_DEPTH][MAX_DEPTH]Move,
	pv_length: [MAX_DEPTH]int,
	killer_moves: [MAX_DEPTH][2]Move,
}

init_data :: proc(position: Position) -> (data: SearchData) {
	data.position = position
	data.max_depth = MAX_DEPTH
	data.max_nodes = max(int)
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
	stdout := os.to_stream(os.stdout)
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
		// if found_mate do break

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
				eval := -negamax(-beta, -alpha, depth - 1, ply + 1, data)
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

			eval_type := "cp"
			print_eval := best_eval
			if best_eval >= MATE_EVAL - MAX_DEPTH {
				ply_to_mate := MATE_EVAL - best_eval
				print_eval = (ply_to_mate + 1) / 2
				eval_type = "mate"
				found_mate = true
			} else if best_eval <= -MATE_EVAL + MAX_DEPTH {
				ply_to_mate := MATE_EVAL + best_eval
				print_eval = - ply_to_mate / 2
				eval_type = "mate"
				found_mate = true
			}

			eval_bound := ""
			if !found_mate && best_eval >= beta {
				upper_window *= 2
				eval_bound = "lowerbound"
			} else if !found_mate && best_eval <= alpha {
				lower_window *= 2
				eval_bound = "upperbound"
			}

			elapsed := time.tick_since(data.start_time)
			elapsed_ms := int(time.duration_milliseconds(elapsed))
			nps := f64(data.nodes) / time.duration_seconds(elapsed)
			len := data.pv_length[0]
			pv_str := to_string(data.pv_table[0][:len], context.temp_allocator)
			fmt.printfln(
				"info depth %d seldepth %d nodes %d time %d nps %d " +
				"hashfull %d score %s %d %s pv %s",
				depth, data.seldepth, data.nodes, elapsed_ms, int(nps),
				hashfull(t_table), eval_type, print_eval, eval_bound, pv_str
			)

			if move_count == 1 || found_mate {
				prev_best = best_move
				break iterative_deepening
			}

			// widen aspiration window and re-search if outside of bounds
			if best_eval <= alpha || best_eval >= beta {
				last_aspiration_fail = depth
				alpha = prev_eval - lower_window
				beta = prev_eval + upper_window
				continue
			}

			if prev_best != best_move {
				best_since_depth = depth
				prev_best = best_move
			}

			// decide whether to stop the search now
			if !data.infinite && !intrinsics.atomic_load(&ponder) &&
				depth - best_since_depth >= 2 && elapsed > 0 &&
				depth - last_aspiration_fail >= 2 {

				// threshold for stopping early decreases hyperbolically as
				// allocated time runs out.
				target_time := data.target_time
				if target_time == 0 {
					target_time = data.allowed_time
				}
				certainty_threshold := 1.3 * f64(target_time)/f64(elapsed)

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
			// searching if theres time to finish it
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

				target_time := data.target_time
				if target_time == 0 {
					target_time = data.allowed_time
				}

				remaining_time := target_time - elapsed
				estimated_time := f64(prev_search_time) * data.ebf
				if f64(remaining_time) < estimated_time {
					break iterative_deepening
				}
			}

			prev_eval = best_eval
			prev_search_time = time.tick_since(depth_timer)

			break
		}
	}

	move_str := to_string(prev_best)
	fmt.print("bestmove", move_str)
	delete(move_str)

	ponder_move: Move
	if data.pv_length[0] > 1 {
		ponder_move = data.pv_table[0][1]
	} else {
		hash := zobrist_move(data.position, prev_best)
		entry := probe_ttable(t_table, hash)

		if entry.hash == hash {
			ponder_move = entry.move
		}
	}
	
	if ponder_move != NULL_MOVE {
		move_str := to_string(ponder_move)
		fmt.print(" ponder", move_str)
		delete(move_str)
	}

	fmt.println()

	intrinsics.atomic_store(&is_searching, false)

	return data.nodes
}

negamax :: proc(
	alpha,
	beta,
	depth,
	ply: int,
	data: ^SearchData,
	prev_move := NULL_MOVE
) -> int {
	if data.nodes % 2048 == 0 {
		// hacky way to start timer on ponderhit since SearchData is not
		// accessible from the interface thread
		if data.pondering && !intrinsics.atomic_load(&ponder) {
			data.start_time = time.tick_now()
			data.pondering = false
		}

		if !data.infinite && !intrinsics.atomic_load(&ponder) &&
			time.tick_since(data.start_time) >= data.allowed_time {
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

	if ply >= MAX_DEPTH {
		return evaluate(&data.position)
	}

	data.pv_length[ply] = 0

	if data.position.halfmove_clk >= 100 || threefold_repetition(data, ply) {
		return 0
	}

	// mate distance pruning
	// prune node if a mate shorter than the current ply has been found
	alpha := max(alpha, -MATE_EVAL + ply)
	beta := min(beta, MATE_EVAL - ply)
	mate_window := alpha <= -MATE_EVAL + ply || beta >= MATE_EVAL - ply
	if alpha >= beta do return alpha

	if depth == 0 {
		return q_search(alpha, beta, ply, data, prev_move)
	}

	depth := depth
	best_eval := MIN_EVAL
	best_move := NULL_MOVE
	tt_depth := depth
	eval_type := EvalType.UpperBound
	is_pv := beta - alpha != 1 // otherwise we're in a null window

	prev_piece := NIL_PIECE
	if prev_move != NULL_MOVE {
		ok: bool
		prev_piece = data.position.mailbox[prev_move.to]
		assert(prev_piece != NIL_PIECE, "No piece found at previous move.to")
	}

	zob_hash := data.position.hash
	tt_entry := probe_ttable(t_table, zob_hash)
	if tt_entry.hash == zob_hash {
		best_move = tt_entry.move

		if tt_entry.depth >= depth {
			tt_eval := eval_from_tt(tt_entry.eval, ply)

			switch tt_entry.eval_type {
			case .Exact:
				return tt_eval
			case .LowerBound:
				alpha = max(alpha, tt_eval)
			case .UpperBound:
				beta = min(beta, tt_eval)
			}

			if alpha >= beta {
				return tt_eval
			}
		}
	}

	us := data.position.turn
	masks := gen_legality_masks(&data.position)
	in_check := is_in_check(&data.position, masks.danger)
	standing_pat := MIN_EVAL

	if !in_check && !mate_window {
		// reverse futility pruning
		// skip when in check, pv node, or there is a tt move
		standing_pat = evaluate(&data.position)
		margin := 150 * depth
		if !is_pv && best_move == NULL_MOVE && standing_pat >= beta + margin {
			return standing_pat
		}

		// null move pruning
		if !is_pawn_endgame(data.position) {
			null_depth := depth - NULL_MOVE_REDUCTION - 1

			if null_depth >= 0 {
				make_null_move(&data.position)
				eval := -negamax(-beta, -beta + 1, null_depth, ply + 1, data)
				unmake_null_move(&data.position)

				if eval >= beta {
					ttable_insert(&t_table, TTableEntry{
						data.position.hash,
						null_depth,
						eval_to_tt(eval, ply),
						.LowerBound,
						NULL_MOVE,
					})
					return eval
				}
			}
		}
	}

	// check extension
	if in_check && depth < MAX_DEPTH {
		depth += 1
	}

	// internal iterative reduction (IIR)
	if depth > 5 && best_move == NULL_MOVE {
		depth -= 2
	}

	moves := gen_moves(&data.position, masks)
	sort_scores := score_moves(moves[:], ply, best_move, prev_move, prev_piece, data)
	rejected_quiets := make([dynamic]Move, 0, len(moves))
	defer {
		delete(moves)
		delete(sort_scores)
		delete(rejected_quiets)
	}

	move_count := 0
	for i in 0..<len(moves) {
		move := pick_move(moves[i:], sort_scores[i:])
		if !is_legal(&data.position, masks, move) do continue
		flags := get_flags(move)
		is_check := gives_check(&data.position, move, masks)
		move_count += 1

		// useful to see formatted move in debugger
		when ODIN_DEBUG {
			move_str := to_string(move)
			defer delete(move_str)
		}

		// futility pruning
		if !in_check && !is_pv && move_count > 1 && !is_dynamic(flags) &&
			!is_check && !mate_window {
			margin := FUTILITY_MARGIN[depth - 1]
			if standing_pat + margin < alpha {
				continue
			}
		}

		// late move reduction (LMR)
		r := 0
		if !is_pv && depth > 2 && move_count > 2  && !is_check && !mate_window {
			r = LMR_TABLE[min(depth, 63)][min(move_count, 63)]
			r = max(r, 1)
			r = min(r, depth - 2)
		}

		make_move(&data.position, move)
		eval: int
		// search first move with full window
		if move_count == 1 {
			eval = -negamax(-beta, -alpha, depth - 1, ply + 1, data, move)
		} else {
			// otherwise apply null window and reduce depth
			eval = -negamax(-alpha - 1, -alpha, depth - r - 1, ply + 1, data,
				move)

			// repeat with full depth
			if eval > alpha && r > 0 {
				r = 0
				eval = -negamax(
					-alpha - 1, -alpha, depth - 1, ply + 1, data, move
				)
			}

			// repeat the full search if we can't perform a cutoff
			if eval > alpha && eval < beta && is_pv {
				r = 0
				eval = -negamax(-beta, -alpha, depth - 1, ply + 1, data, move)
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

	ttable_insert(&t_table, TTableEntry{
		data.position.hash,
		tt_depth,
		eval_to_tt(best_eval, ply),
		eval_type,
		best_move,
	})

	return best_eval
}

q_search :: proc(
	alpha,
	beta,
	ply: int,
	data: ^SearchData,
	prev_move := NULL_MOVE
) -> int {
	if data.nodes % 2048 == 0 {
		// hacky way to start timer on ponderhit since SearchData is not
		// accessible from the interface thread
		if data.pondering && !intrinsics.atomic_load(&ponder) {
			data.start_time = time.tick_now()
			data.pondering = false
		}

		if !data.infinite && !intrinsics.atomic_load(&ponder) &&
			time.tick_since(data.start_time) >= data.allowed_time {
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

	if ply >= MAX_DEPTH {
		return evaluate(&data.position)
	}

	data.pv_length[ply] = 0

	if data.position.halfmove_clk >= 100 || fast_repetition(data) {
		return 0
	}

	alpha := max(alpha, -MATE_EVAL + ply)
	beta  := min(beta,  MATE_EVAL - ply)
	if alpha >= beta do return alpha

	if ply > data.seldepth {
		data.seldepth = ply
	}

	us := data.position.turn
	them := toggle(us)
	masks := gen_legality_masks(&data.position)
	in_check := is_in_check(&data.position, masks.danger)
	best_move: Move
	best_eval := MIN_EVAL
	standing_pat: int

	prev_piece := NIL_PIECE
	if prev_move != NULL_MOVE {
		ok: bool
		prev_piece = data.position.mailbox[prev_move.to]
		assert(prev_piece != NIL_PIECE, "No piece found at previous move.to")
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
					print(data.position)
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
				captured_piece := data.position.mailbox[move.to]
				assert(captured_piece != NIL_PIECE, "no piece on captured square")
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
		eval := -q_search(-beta, -alpha, ply + 1, data, move)
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

mate_search :: proc(alpha, beta, depth, ply: int, prev_move: Move, data: ^SearchData) -> int {
	if data.nodes % 512 == 0 {
		// hacky way to start timer on ponderhit since SearchData is not
		// accessible from the interface thread
		if data.pondering && !intrinsics.atomic_load(&ponder) {
			data.start_time = time.tick_now()
			data.pondering = false
		}

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

	if ply >= MAX_DEPTH {
		return MIN_EVAL
	}

	data.pv_length[ply] = 0

	if data.position.halfmove_clk >= 100 || threefold_repetition(data, ply) {
		return 0
	}

	// mate distance pruning
	// prune node if a mate shorter than the current ply has been found
	alpha := max(alpha, -MATE_EVAL + ply)
	beta := min(beta, MATE_EVAL - ply)
	mate_window := alpha <= -MATE_EVAL + ply || beta >= MATE_EVAL - ply
	if alpha >= beta do return alpha

	if depth == 0 {
		return MIN_EVAL
	}

	best_eval := MIN_EVAL
	best_move := NULL_MOVE
	tt_depth := depth
	eval_type := EvalType.UpperBound

	us := data.position.turn
	masks := gen_legality_masks(&data.position)
	in_check := is_in_check(&data.position, masks.danger)

	zob_hash := data.position.hash
	tt_entry := probe_ttable(t_table, zob_hash)
	if tt_entry.hash == zob_hash {
		best_move = tt_entry.move

		if tt_entry.depth >= depth {
			tt_eval := eval_from_tt(tt_entry.eval, ply)

			switch tt_entry.eval_type {
			case .Exact:
				return tt_eval
			case .LowerBound:
				alpha = max(alpha, tt_eval)
			case .UpperBound:
				beta = min(beta, tt_eval)
			}

			if alpha >= beta {
				return tt_eval
			}
		}
	}

	moves := gen_moves(&data.position, masks)
	sort_scores := score_moves(
		moves[:], ply, best_move, NULL_MOVE, NIL_PIECE, data
	)

	for i in 0..<len(moves) {
		if gives_check(&data.position, moves[i], masks) {
			sort_scores[i] += CHECK_SCORE
		}
	}

	defer {
		delete(moves)
		delete(sort_scores)
	}

	move_count := 0
	for i in 0..<len(moves) {
		move := pick_move(moves[i:], sort_scores[i:])
		if !is_legal(&data.position, masks, move) do continue
		flags := get_flags(move)
		is_check := gives_check(&data.position, move, masks)
		move_count += 1

		// useful to see formatted move in debugger
		when ODIN_DEBUG {
			move_str := to_string(move)
			defer delete(move_str)
		}

		make_move(&data.position, move)
		eval := -mate_search(-beta, -alpha, depth - 1, ply + 1, move, data)
		unmake_move(&data.position, move)

		if data.aborted do return 0

		if eval > best_eval {
			best_eval = eval
			best_move = move

			if eval >= beta {
				eval_type = .LowerBound
				break
			}

			if eval > alpha {
				alpha = eval
				update_pv(ply, move, data)
				eval_type = .Exact
			}
		}
	}

	if move_count == 0 {
		if is_in_check(&data.position, masks.danger) {
			return -MATE_EVAL + ply
		}
		return 0
	}

	ttable_insert(&t_table, TTableEntry{
		data.position.hash,
		tt_depth,
		eval_to_tt(best_eval, ply),
		eval_type,
		best_move,
	})

	return best_eval
}

update_pv :: proc(ply: int, move: Move, data: ^SearchData) {
	assert(ply < MAX_DEPTH)
	data.pv_table[ply][ply] = move

	if ply >= MAX_DEPTH - 1 {
		data.pv_length[ply] = 1
		return
	}

	child_len := data.pv_length[ply + 1]
	max_child_len := MAX_DEPTH - ply - 1
	assert(child_len <= max_child_len, "PV child length exceeds table bounds")

	child_len = min(child_len, max_child_len)
	data.pv_length[ply] = child_len + 1
	mem.copy_non_overlapping(
		&data.pv_table[ply][ply + 1],
		&data.pv_table[ply + 1][ply + 1],
		child_len * size_of(Move)
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
		victim := position.mailbox[to]
		assert(victim != NIL_PIECE, "No piece on captured to square")
		victim_type = victim.type
	}

	gain[0] = piece_value[victim_type]

	attackers := attackers_to(position, to)
	attacker := position.mailbox[move.from]
	assert(attacker != NIL_PIECE, "Attempt to move from empty square")
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
	victim := position.mailbox[to]
	assert(victim != NIL_PIECE, "No victim in recursive see")
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
		victim := position.mailbox[to]
		assert(victim != NIL_PIECE, "No victim in recursive see")
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

@(init)
init_lmr :: proc "contextless" () {
	for d in 0..<64 {
		for m in 0..<64 {
			LMR_TABLE[d][m] = int(math.ln(f32(d)) * math.ln(f32(m)))
		}
	}
}
