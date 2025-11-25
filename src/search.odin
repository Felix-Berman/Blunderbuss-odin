package blunderbuss

import "core:mem"
import "core:fmt"
import "core:time"
import "core:bufio"
import "core:os"
import "base:intrinsics"
import "base:builtin"

MAX_SCORE :: 1_000_000_000
MIN_SCORE :: -MAX_SCORE
MAX_DEPTH :: 32

SearchInfo :: struct {
	position: Position,
	max_depth: int,
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

default_info :: proc(position: Position) -> (info: SearchInfo) {
	info.position = position
	info.max_depth = MAX_DEPTH
	info.max_nodes = builtin.max(int)

	// perform deep copy
	if position.irreversible_history != nil {
		src := position.irreversible_history[:]
		info.position.irreversible_history = make(
			[dynamic]Irreversibles,
			len(src),
			cap(position.irreversible_history)
		)
		copy(info.position.irreversible_history[:], src)
	}
	return
}

root_search :: proc(data: rawptr) {
	intrinsics.atomic_store(&is_searching, true)

	info := cast(^SearchInfo)data
	defer {
		delete(info.position.irreversible_history)
		free(info)
	}

	writer: bufio.Writer
	stdout := os.stream_from_handle(os.stdout)
	bufio.writer_init(&writer, stdout)
	defer bufio.writer_destroy(&writer)

	us := info.position.turn
	moves := gen_pseudo_legal_moves(&info.position)
	defer delete(moves)
	
	found_mate: bool
	best_move: Move
	ply := 0
	iterative_deepening:
	for depth in 1..=info.max_depth {
		if found_mate do break
		best_score := MIN_SCORE

		info.pv_length = {}
		move_count := 0
		for i in 0..<len(moves) {
			move := pick_move(moves[i:], ply, info)
			make_move(&info.position, move)
			defer unmake_move(&info.position, move)

			if is_in_check(us, &info.position) do continue

			move_count += 1
			currmove := to_string(move)
			curr_info := fmt.aprintfln("info depth %d currmove %s currmovenumber %d",
				depth, currmove, move_count)
			defer delete(currmove)
			defer delete(curr_info)

			bufio.writer_write_string(&writer, curr_info)
			if time.tick_since(info.start_time) > time.Second {
				bufio.writer_flush(&writer)
			}

			score := -negamax(MIN_SCORE, MAX_SCORE, depth - 1, ply + 1, info)

			if info.aborted do break iterative_deepening

			if score > best_score {
				update_pv(ply, move, info)
				best_move, best_score = move, score
			}
		}
		bufio.writer_reset(&writer, stdout)

		score_type: string
		if builtin.abs(best_score) == MAX_SCORE {
			score_type = "mate"
			best_score = info.pv_length[0]
			found_mate = true
		} else {
			score_type = "cp"
		}

		elapsed := time.tick_since(info.start_time)
		elapsed_ms := int(time.duration_milliseconds(elapsed))
		nps := f64(info.nodes) / time.duration_seconds(elapsed)
		len := info.pv_length[0]
		pv_str := to_string(info.pv_table[0][:len])
		fmt.printfln("info depth %d nodes %d time %d nps %d score %s %d pv %s",
			depth, info.nodes, elapsed_ms, int(nps), score_type, best_score, pv_str)
		delete(pv_str)
	}

	move_str := to_string(best_move)
	fmt.println("bestmove", move_str)
	delete(move_str)

	intrinsics.atomic_store(&is_searching, false)
}

negamax :: proc(alpha, beta, depth, ply: int, info: ^SearchInfo) -> int {
	if info.nodes % 2048 == 0 {
		if !info.infinite && time.tick_since(info.start_time) >= info.allowed_time {
			info.aborted = true
			return 0
		}
		if intrinsics.atomic_load(&stop_flag) {
			info.aborted = true
			return 0
		}
		if info.nodes >= info.max_nodes {
			info.aborted = true
			return 0
		}
	}

	info.nodes += 1
	if depth == 0 {
		return eval(&info.position)
	}

	alpha := alpha
	best_score := MIN_SCORE
	info.pv_length[ply] = 0

	us := info.position.turn
	moves := gen_pseudo_legal_moves(&info.position)
	defer delete(moves)

	for i in 0..<len(moves) {
		move := pick_move(moves[i:], ply, info)
		make_move(&info.position, move)
		defer unmake_move(&info.position, move)

		if is_in_check(us, &info.position) do continue

		score := -negamax(-beta, -alpha, depth - 1, ply + 1, info)

		if info.aborted do return 0
		
		if score > best_score {
			best_score = score

			if score > alpha {
				alpha = score
				update_pv(ply, move, info)
			}
		}

		if score >= beta {
			return best_score
		}
	}

	return best_score
}

update_pv :: proc(ply: int, move: Move, info: ^SearchInfo) {
	info.pv_table[ply][ply] = move
	info.pv_length[ply] = info.pv_length[ply + 1] + 1
	mem.copy_non_overlapping(
		&info.pv_table[ply][ply + 1],
		&info.pv_table[ply + 1][ply + 1],
		info.pv_length[ply + 1] * size_of(Move)
	)
}

pick_move :: proc(movelist: []Move, ply: int, info: ^SearchInfo) -> Move {
	for move, i in movelist {
		if move == NULL_MOVE do break
		if move == info.pv_table[0][ply] {
			move_temp := movelist[0]
			movelist[0] = move
			movelist[i] = move_temp
		}
	}

	return movelist[0]
}
