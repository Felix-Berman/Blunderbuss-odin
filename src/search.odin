package blunderbuss

import "core:mem"
import "core:fmt"
import "core:time"
import "core:bufio"
import "core:os"
import "base:intrinsics"
import "base:builtin"

MAX_EVAL :: builtin.max(int)
MIN_EVAL :: -MAX_EVAL
MATE_EVAL :: 1_000_000
MAX_DEPTH :: 64
MAX_Q_DEPTH :: 6

DELTA_MARGIN :: 200
ASPIRATION_WINDOW :: 25
NULL_MOVE_REDUCTION :: 3

SearchData :: struct {
	position: Position,
	max_depth: int,
	seldepth: int,
	nodes: int,
	max_nodes: int,
	mate: bool,
	aborted: bool,
	infinite: bool,
	start_time: time.Tick,
	allowed_time: time.Duration,
	pv_table: [MAX_DEPTH][MAX_DEPTH]Move,
	pv_length: [MAX_DEPTH]int,
	killer_moves: [MAX_DEPTH][2]Move,
}

default_data :: proc(position: Position) -> (data: SearchData) {
	data.position = position
	data.max_depth = MAX_DEPTH
	data.max_nodes = builtin.max(int)
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

search_thread :: proc(data: rawptr) {
	data := cast(^SearchData)data
	root_search(data)

	delete(data.position.history)
	free(data)
}

root_search :: proc(data: ^SearchData) -> int {
	intrinsics.atomic_store(&is_searching, true)

	writer: bufio.Writer
	stdout := os.stream_from_handle(os.stdout)
	bufio.writer_init(&writer, stdout)
	defer bufio.writer_destroy(&writer)

	us := data.position.turn
	moves := gen_pseudo_legal_moves(&data.position)
	defer delete(moves)
	
	found_mate: bool
	best_move: Move

	alpha := MIN_EVAL
	beta := MAX_EVAL
	prev_eval: int

	ply := 0
	iterative_deepening:
	for depth in 1..=data.max_depth {
		if found_mate do break

		upper_window := ASPIRATION_WINDOW
		lower_window := ASPIRATION_WINDOW
		
		if depth != 1 {
			alpha = prev_eval - lower_window
			beta = prev_eval + upper_window
		}
		
		aspiration_loop:
		for {
			best_eval := MIN_EVAL

			sort_scores := score_moves(moves[:], 0, best_move, data)
			defer delete(sort_scores)

			data.pv_length = {}
			move_count := 0
			for i in 0..<len(moves) {
				move := pick_move(moves[i:], sort_scores[i:])
				make_move(&data.position, move)
				defer unmake_move(&data.position, move)
				
				// useful to see formatted move in debugger
				when ODIN_DEBUG {
					move_str := to_string(move)
					defer delete(move_str)
				}

				if is_in_check(us, &data.position) do continue

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

				eval := -negamax(-beta, -alpha, depth - 1, ply + 1, data)

				if data.aborted do break iterative_deepening

				if eval > best_eval {
					update_pv(ply, move, data)
					best_move, best_eval = move, eval
				}
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

			// break out of aspiration if in window
			if alpha < best_eval && best_eval < beta {
				prev_eval = best_eval
				break
			}
			alpha = prev_eval - lower_window
			beta = prev_eval + upper_window
		}
	}

	move_str := to_string(best_move)
	fmt.println("bestmove", move_str)
	delete(move_str)

	intrinsics.atomic_store(&is_searching, false)

	return data.nodes
}

negamax :: proc(alpha, beta, depth, ply: int, data: ^SearchData) -> int {
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

	if depth == 0 {
		return q_search(alpha, beta, ply, data)
	}

	alpha := alpha
	beta := beta
	best_eval := MIN_EVAL
	best_move := NULL_MOVE
	eval_type := EvalType.UpperBound

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
				alpha = builtin.max(alpha, tt_eval)
			case .UpperBound:
				if tt_eval <= alpha {
					return tt_eval
				}
				beta = builtin.min(beta, tt_eval)
			}

			if alpha >= beta {
				return alpha
			}
		}
	}

	us := data.position.turn
	moves := gen_pseudo_legal_moves(&data.position)
	sort_scores := score_moves(moves[:], ply, best_move, data)
	defer {
		delete(moves)
		delete(sort_scores)
	}

	if !is_in_check(us, &data.position) && !is_pawn_endgame(data.position) {
		null_depth := depth - NULL_MOVE_REDUCTION - 1

		if null_depth >= 0 {
			make_null_move(&data.position)
			eval := -negamax(-beta, -beta + 1, null_depth, ply + 1, data)
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

	is_pv := beta - alpha > 1 // otherwise we're in a null window

	move_count := 0
	for i in 0..<len(moves) {
		move := pick_move(moves[i:], sort_scores[i:])
		make_move(&data.position, move)
		defer unmake_move(&data.position, move)

		// useful to see formatted move in debugger
		when ODIN_DEBUG {
			move_str := to_string(move)
			defer delete(move_str)
		}

		if is_in_check(us, &data.position) do continue
		move_count += 1

		eval: int
		if move_count == 1 {
			eval = -negamax(-beta, -alpha, depth - 1, ply + 1, data)
		} else {
			eval = -negamax(-alpha - 1, -alpha, depth - 1, ply + 1, data)
			if eval > alpha && eval < beta && is_pv {
				eval = -negamax(-beta, -alpha, depth - 1, ply + 1, data)
			}
		}

		if data.aborted do return 0

		
		if eval > best_eval {
			best_eval = eval
			best_move = move

			if eval >= beta {
				if QUIET == get_flags(move) {
					store_killer(move, ply, data)
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
	}

	if move_count == 0 {
		if is_in_check(us, &data.position) {
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
		depth,
		tt_eval,
		eval_type,
		best_move,
	})

	return best_eval
}

q_search :: proc(alpha, beta, ply: int, data: ^SearchData) -> int {
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
	if ply >= MAX_DEPTH {
		return eval(&data.position)
	}

	if ply > data.seldepth {
		data.seldepth = ply
	}

	data.pv_length[ply] = 0

	us := data.position.turn
	them := toggle(us)
	in_check := is_in_check(us, &data.position)
	alpha := alpha
	standing_pat := eval(&data.position)
	best_move: Move

	if !in_check {
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
	}

	moves := gen_pseudo_legal_moves(&data.position)
	sort_scores := score_moves(moves[:], ply, best_move, data)
	defer {
		delete(moves)
		delete(sort_scores)
	}

	best_eval := standing_pat
	move_count := 0
	for i in 0..<len(moves) {
		move := pick_move(moves[i:], sort_scores[i:])
		flags := get_flags(move)
		if !in_check && !is_dynamic(flags) do continue

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
		if !in_check && .Capture in flags {
			captured_val: int
			if flags == EP_CAPTURE {
				captured_val = piece_value[.Pawn]
			} else if .Capture in flags {
				captured_piece, ok := piece_on(&data.position, move.to)
				assert(ok, "no piece on captured square")
				captured_val = piece_value[captured_piece.type]
			}

			if .Promotion in flags {
				switch flags &~ {.Capture} {
				case KNIGHT_PROMOTION:
					captured_val += piece_value[.Knight]
				case BISHOP_PROMOTION:
					captured_val += piece_value[.Bishop]
				case ROOK_PROMOTION:
					captured_val += piece_value[.Rook]
				case QUEEN_PROMOTION:
					captured_val += piece_value[.Queen]
				}
				captured_val -= piece_value[.Pawn]
			}
			
			if standing_pat + captured_val + DELTA_MARGIN < alpha {
				continue
			}

			// static exchange evaluation (don't consider trades losing material)
			// see value already computed during sort scoring
			if .Promotion not_in flags && sort_scores[i] < 0 {
				continue
			}
		}

		make_move(&data.position, move)
		defer unmake_move(&data.position, move)

		if is_in_check(us, &data.position) do continue
		move_count += 1

		eval := -q_search(-beta, -alpha, ply + 1, data)

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
	data.pv_table[ply][ply] = move

	if ply >= 63 {
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
//	killer moves
//	negative trades/captures
//	remaining moves
score_moves :: proc(movelist: []Move, ply: int, best_move: Move, data: ^SearchData) -> (scores: [dynamic]int) {
	resize(&scores, len(movelist))
	for move, i in movelist {
		if move == NULL_MOVE do break
		if move == best_move {
			scores[i] = 100_000
			continue
		}

		flags := get_flags(move)
		if .Capture in flags {
			see_val := see(&data.position, move)
			scores[i] += see_val
			
			if see_val >= 0 {
				scores[i] += 10_000
			}
		} else {
			for killer in data.killer_moves[ply] {
				if move == killer {
					scores[i] += 9_900
				}
			}
		}
	}

	return
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

see :: proc(position: ^Position, move: Move) -> int {
	to := int(move.to)
	to_bb := to_bitboard(to)
	victim_type: PieceType
	us := position.turn
	occ := occupied(position)
	gain: [32]int
	depth := 0

	if EP_CAPTURE == get_flags(move) {
		victim_type = .Pawn
		ep_bb := to_bitboard(position.ep_sq)
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
		attackers[us] & to_bitboard(move.from) != 0,
		"Initial attacker not included in see attack set"
	)

	victim_type = attacker.type
	occ &~= to_bitboard(move.from)
	us = toggle(us)

	for depth < 32 {
		// calculate gain
		depth += 1
		gain[depth] = piece_value[victim_type] - gain[depth - 1]

		// include revealed x-ray attacks
		bishop_attacks := bishop_moves(to, occ)
		rook_attacks := rook_moves(to, occ)
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
		occ &~= to_bitboard(next_sq)
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
	value += builtin.max(0, victim_val - recursive_see(position, to))
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
	if data.killer_moves[ply][0] != move {
		data.killer_moves[ply][1] = data.killer_moves[ply][0]
		data.killer_moves[ply][0] = move
	}
}
