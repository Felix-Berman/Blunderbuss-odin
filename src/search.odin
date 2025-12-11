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

DELTA_MARGIN :: 200

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

	zob_hash := data.position.hash
	tt_entry := probe_ttable(t_table, zob_hash)
	if tt_entry.hash == zob_hash {
		best_move = tt_entry.best_move
	}

	ply := 0
	iterative_deepening:
	for depth in 1..=data.max_depth {
		if found_mate do break
		best_eval := MIN_EVAL

		move_scores := score_moves(moves[:], 0, best_move, data)
		defer delete(move_scores)

		data.pv_length = {}
		move_count := 0
		for i in 0..<len(moves) {
			move := pick_move(moves[i:], move_scores[i:])
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
			curr_info := fmt.tprintfln("info depth %d currmove %s currmovenumber %d",
				depth, currmove, move_count)

			bufio.writer_write_string(&writer, curr_info)
			if time.tick_since(data.start_time) > 3 * time.Second {
				bufio.writer_flush(&writer)
			}

			eval := -negamax(MIN_EVAL, MAX_EVAL, depth - 1, ply + 1, data)

			if data.aborted do break iterative_deepening

			if eval > best_eval {
				update_pv(ply, move, data)
				best_move, best_eval = move, eval
			}
		}
		bufio.writer_reset(&writer, stdout)
		free_all(context.temp_allocator)

		eval_type: string
		if best_eval > MATE_EVAL - depth {
			ply_to_mate := MATE_EVAL - best_eval
			best_eval = (ply_to_mate + 1) / 2
			eval_type = "mate"
			found_mate = true
		} else if best_eval < -MATE_EVAL + depth {
			ply_to_mate := MATE_EVAL + best_eval
			best_eval = -ply_to_mate / 2
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
		fmt.printfln("info depth %d seldepth %d nodes %d time %d nps %d score %s %d pv %s",
			depth, data.seldepth, data.nodes, elapsed_ms, int(nps), eval_type, best_eval, pv_str)
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
			// todo: re-evaluate distance to mate on mate scores
			tt_eval := tt_entry.eval

			switch tt_entry.eval_type {
			case .Exact:
				return tt_eval
			case .LowerBound:
				// if tt_eval >= beta {
				// 	return tt_eval
				// }
				// alpha = builtin.max(alpha, tt_eval)
			case .UpperBound:
				// if tt_eval <= alpha {
				// 	return tt_eval
				// }
				// beta = builtin.min(beta, tt_eval)
			}
		}
	}

	us := data.position.turn
	moves := gen_pseudo_legal_moves(&data.position)
	move_scores := score_moves(moves[:], ply, best_move, data)
	defer {
		delete(moves)
		delete(move_scores)
	}

	move_count := 0
	for i in 0..<len(moves) {
		move := pick_move(moves[i:], move_scores[i:])
		make_move(&data.position, move)
		defer unmake_move(&data.position, move)

		// useful to see formatted move in debugger
		when ODIN_DEBUG {
			move_str := to_string(move)
			defer delete(move_str)
		}

		if is_in_check(us, &data.position) do continue
		move_count += 1

		eval := -negamax(-beta, -alpha, depth - 1, ply + 1, data)

		if data.aborted do return 0

		if eval >= beta {
			ttable_insert(t_table, TTableEntry{
				data.position.hash,
				depth,
				eval,
				.LowerBound,
				move,
			})
			return eval
		}
		
		if eval > best_eval {
			best_eval = eval
			best_move = move

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

	ttable_insert(t_table, TTableEntry{
		data.position.hash,
		depth,
		best_eval,
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
	data.pv_length[ply] = 0

	if ply >= MAX_DEPTH {
		return eval(&data.position)
	}

	alpha := alpha
	best_eval := eval(&data.position)
	best_move: Move
	move_count := 0
	if ply > data.seldepth {
		data.seldepth = ply
	}

	if best_eval >= beta {
		return best_eval
	}
	if best_eval > alpha {
		alpha = best_eval
	}

	us := data.position.turn
	moves := gen_pseudo_legal_moves(&data.position)
	move_scores := score_moves(moves[:], ply, best_move, data)
	defer {
		delete(moves)
		delete(move_scores)
	}

	for i in 0..<len(moves) {
		move := pick_move(moves[i:], move_scores[i:])
		flags := get_flags(move)
		if .Capture not_in flags do continue

		when ODIN_DEBUG {
			// useful to see formatted move in debugger
			move_str := to_string(move)
			defer delete(move_str)

			// validate static exchange accuracy
			recursive_see_val := recursive_see_root(&data.position, move)
			see_val := see(&data.position, move)
			if see_val != recursive_see_val {
				display(data.position)
				fmt.println(to_string(move, context.temp_allocator))
				fmt.println(see_val, "!=", recursive_see_val)
				panic("static exchange evaluation error")
			}
		}

		// static exchange evaluation (don't consider trades losing material)
		if see(&data.position, move) < 0 do continue

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
			moved := piece_on(&data.position, move.from) or_continue
			captured := piece_on(&data.position, move.to) or_continue
			scores[i] += 10_000 + piece_value[captured.type] - piece_value[moved.type]
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
	}

	return movelist[0]
}

threefold_repetition :: proc(info: ^SearchData, search_ply: int) -> bool {
	ply_to_search := info.position.ply - info.position.last_irreversible_ply

	if ply_to_search < 4 {
		return false
	}

	history_len := len(info.position.history)
	repetition_count: int
	for i: int = 4; i <= ply_to_search; i += 2 {
		if info.position.history[history_len - i].hash == info.position.hash {	
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
	victim, ok := piece_on(position, to)

	if !ok { // non capture
		return 0
	}

	us := position.turn
	occ := occupied(position)

	gain: [32]int
	depth := 0

	victim_type := victim.type
	gain[0] = piece_value[victim_type]

	attacker: Piece
	attackers := attackers_to(position, to)
	attacker, ok = piece_on(position, move.from)
	assert(ok, "Attempt to move from empty square")
	assert(attackers[us] & to_bitboard(move.from) != 0, 
		"Initial attacker not included in see attack set")

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

		if no_attackers {
			display(position^)
			display(att)
			fmt.println(to_string(move, context.temp_allocator))
			panic("Misalignment between piece bbs and att bb in see")
		}

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
	victim, ok := piece_on(position, to)
	assert(ok, "No victim in recursive see")

	victim_val := piece_value[victim.type]

	if victim.type == .King {
		return victim_val
	}

	// strip promotion information from flags
	set_flags(&move, {.Capture})	

	make_move(position, move)
	value += victim_val - recursive_see(position, to)
	unmake_move(position, move)

	return
}
