package blunderbuss

import "core:mem"
import "core:fmt"
import "core:time"
import "core:bufio"
import "core:os"
import "base:intrinsics"
import "base:builtin"

MAX_SCORE :: builtin.max(int)
MIN_SCORE :: -MAX_SCORE
MATE_SCORE :: 1_000_000
MAX_DEPTH :: 64

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
	ply := 0
	iterative_deepening:
	for depth in 1..=data.max_depth {
		if found_mate do break
		best_score := MIN_SCORE

		move_scores := score_moves(moves[:], 0, data)
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
			currmove := to_string(move)
			curr_info := fmt.aprintfln("info depth %d currmove %s currmovenumber %d",
				depth, currmove, move_count)
			defer delete(currmove)
			defer delete(curr_info)

			bufio.writer_write_string(&writer, curr_info)
			if time.tick_since(data.start_time) > 3 * time.Second {
				bufio.writer_flush(&writer)
			}

			score := -negamax(MIN_SCORE, MAX_SCORE, depth - 1, ply + 1, data)

			if data.aborted do break iterative_deepening

			if score > best_score {
				update_pv(ply, move, data)
				best_move, best_score = move, score
			}
		}
		bufio.writer_reset(&writer, stdout)

		score_type: string
		if best_score > MATE_SCORE - depth {
			ply_to_mate := MATE_SCORE - best_score
			best_score = (ply_to_mate + 1) / 2
			score_type = "mate"
			found_mate = true
		} else if best_score < -MATE_SCORE + depth {
			ply_to_mate := MATE_SCORE + best_score
			best_score = -ply_to_mate / 2
			score_type = "mate"
			found_mate = true
		} else {
			score_type = "cp"
		}

		elapsed := time.tick_since(data.start_time)
		elapsed_ms := int(time.duration_milliseconds(elapsed))
		nps := f64(data.nodes) / time.duration_seconds(elapsed)
		len := data.pv_length[0]
		pv_str := to_string(data.pv_table[0][:len])
		fmt.printfln("info depth %d seldepth %d nodes %d time %d nps %d score %s %d pv %s",
			depth, data.seldepth, data.nodes, elapsed_ms, int(nps), score_type, best_score, pv_str)
		delete(pv_str)
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

	if data.position.halfmove_clk >= 100 || threefold_repetition(data, ply) {
		return 0
	}

	data.nodes += 1
	if depth == 0 {
		return eval(&data.position)
	}

	alpha := alpha
	best_score := MIN_SCORE
	data.pv_length[ply] = 0
	move_count := 0

	us := data.position.turn
	moves := gen_pseudo_legal_moves(&data.position)
	move_scores := score_moves(moves[:], ply, data)
	defer {
		delete(moves)
		delete(move_scores)
	}

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

		score := -negamax(-beta, -alpha, depth - 1, ply + 1, data)

		if data.aborted do return 0

		if score >= beta {
			return score
		}
		
		if score > best_score {
			best_score = score

			if score > alpha {
				alpha = score
				update_pv(ply, move, data)
			}
		}
	}

	if move_count == 0 {
		if is_in_check(us, &data.position) {
			return -MATE_SCORE + ply
		}
		return 0
	}

	return best_score
}

update_pv :: proc(ply: int, move: Move, info: ^SearchData) {
	info.pv_table[ply][ply] = move
	info.pv_length[ply] = info.pv_length[ply + 1] + 1
	mem.copy_non_overlapping(
		&info.pv_table[ply][ply + 1],
		&info.pv_table[ply + 1][ply + 1],
		info.pv_length[ply + 1] * size_of(Move)
	)
}

score_moves :: proc(movelist: []Move, ply: int, data: ^SearchData) -> (scores: [dynamic]int) {
	resize(&scores, len(movelist))
	for move, i in movelist {
		if move == NULL_MOVE do break
		if move == data.pv_table[0][ply] {
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
