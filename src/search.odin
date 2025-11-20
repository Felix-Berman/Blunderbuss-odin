package blunderbuss

import "core:fmt"
import "base:intrinsics"
import "base:builtin"
import "core:time"
import "core:bufio"
import "core:os"

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
	infinite: bool,
	start_time: time.Tick,
	allowed_time: time.Duration,
}

default_info :: proc(position: Position, stop_flag: ^bool) -> (info: SearchInfo) {
	info.position = position
	info.max_depth = MAX_DEPTH
	info.max_nodes = builtin.max(int)
	info.stop_flag = stop_flag
	return
}

root_search :: proc(data: rawptr) {
	info := (^SearchInfo)(data)
	best_move: Move

	writer: bufio.Writer
	stdout := os.stream_from_handle(os.stdout)
	bufio.writer_init(&writer, stdout)
	defer bufio.writer_destroy(&writer)
	
	moves := gen_pseudo_legal_moves(&info.position)
	defer delete(moves)
	
	iterative_deepening:
	for depth in 1..=info.max_depth {
		best_score := MIN_SCORE

		move_count := 0
		for move in moves {
			make_move(&info.position, move)
			defer unmake_move(&info.position, move)

			if is_in_check(info.position.turn, &info.position) do continue

			move_count += 1
			currmove := to_string(move, context.temp_allocator)
			curr_info := fmt.aprintfln("info depth %d currmove %s currmovenumber %d",
				depth, currmove, move_count, allocator = context.temp_allocator)
			bufio.writer_write_string(&writer, curr_info)
			if time.tick_since(info.start_time) > time.Second {
				bufio.writer_flush(&writer)
			}

			score := -negamax(depth, MIN_SCORE, MAX_SCORE, info)

			if info.aborted do break iterative_deepening

			if score > best_score {
				best_move, best_score = move, score
			}
		}
		bufio.writer_reset(&writer, stdout)

		elapsed := time.tick_since(info.start_time)
		elapsed_ms := int(time.duration_milliseconds(elapsed))
		nps := f64(info.nodes) / time.duration_seconds(elapsed)
		fmt.printfln("info depth %d nodes %d time %d nps %d score cp %d",
			depth, info.nodes, elapsed_ms, int(nps), best_score)
	}

	fmt.println("bestmove", to_string(best_move, context.temp_allocator))

	free(info)
}

negamax :: proc(depth, alpha, beta: int, info: ^SearchInfo) -> int {
	if info.nodes % 2048 == 0 {
		if !info.infinite && time.tick_since(info.start_time) >= info.allowed_time {
			info.aborted = true
			return 0
		}
		if intrinsics.atomic_load_explicit(info.stop_flag, .Relaxed) {
			info.aborted = true
			return 0
		}
		if info.nodes >= info.max_nodes {
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
