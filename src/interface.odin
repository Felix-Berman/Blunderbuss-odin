package blunderbuss

import "core:time"
import "core:os"
import "core:bufio"
import "core:fmt"
import "core:strings"
import "core:strconv"
import "core:thread"
import "base:intrinsics"
import "base:runtime"

stop_flag, is_searching: bool

uci_loop :: proc() {
	stdin := os.stream_from_handle(os.stdin)
	scanner: bufio.Scanner
	bufio.scanner_init(&scanner, stdin)
	defer bufio.scanner_destroy(&scanner)

	position := starting_position()
	defer delete(position.history)

	t_table = make_ttable()
	defer delete(t_table.entries)

	uci_loop:
	for {
		defer free_all(context.temp_allocator)

		if !bufio.scanner_scan(&scanner) {
			break
		}

		line := bufio.scanner_text(&scanner)
		full_line := line

		command := strings.split_iterator(&line, " ") or_continue

		switch command {
		case "quit":
			break uci_loop
		case "uci":
			fmt.println("id name Blunderbuss")
			fmt.println("id author Felix Berman")
			fmt.printfln("option name Hash type spin default %d min 0 max 64000",
				DEFAULT_HASH_SIZE_MB)
			fmt.println("option name Clear Hash type button")
			fmt.println("uciok")
		case "debug":
		case "isready":
			fmt.println("readyok")
		case "setoption":
			set_option(&line)
		case "ucinewgame":
			delete(position.history)
			position = starting_position()
			continuation_history = {}
		case "position":
			if new_position, ok := parse_position(&line); ok {
				delete(position.history)
				position = new_position
			} else {
				fmt.println("Invalid position command:", full_line)	
			}
		case "go":
			if intrinsics.atomic_load(&is_searching) do continue
			if ok := go(&line, &position); !ok {
				fmt.println("Invalid go command:", full_line)
			}
		case "stop":
			intrinsics.atomic_store_explicit(&stop_flag, true, .Relaxed)
		case "perft":
			if depth_str, ok := strings.split_iterator(&line, " "); ok {
				depth := strconv.parse_int(depth_str) or_else 0
				perft_divide(&position, depth)
			}
		case "bench":
			depth_str := strings.split_iterator(&line, " ") or_else ""
			depth := strconv.parse_int(depth_str) or_else BENCH_DEPTH
			bench(depth)
		case "print":
			display(position)
		}
	}

	if err := bufio.scanner_error(&scanner); err != nil {
		fmt.eprintfln("error scanning input: %v", err)
	}
}

set_option :: proc(line: ^string) {
	for cmd in strings.split_iterator(line, " ") {
		if strings.equal_fold(cmd, "hash") {
			if val_str, ok := strings.split_iterator(line, " "); ok {
				size := get_next_int(line) or_break
				resize_ttable(&t_table, size)
			}
		}

		if strings.equal_fold(cmd, "clear") {
			cmd2 := strings.split_iterator(line, " ") or_break
			if strings.equal_fold(cmd2, "hash") {
				clear_ttable(&t_table)
				continuation_history = {}
			}
		}
	}
}

parse_position :: proc(line: ^string) -> (position: Position, ok: bool) {
	specifier := strings.split_iterator(line, " ") or_return
	if specifier == "startpos" {
		position = starting_position()
	} else if specifier == "fen" {
		fen := strings.split_iterator(line, " moves ") or_return
		position = parse_fen(fen) or_return
	}

	for move in strings.split_iterator(line, " ") {
		if move == "moves" do continue
		make_move_str(&position, move) or_return
	}

	return position, true
}

go :: proc(line: ^string, position: ^Position) -> bool {
	data := new(SearchData, runtime.default_allocator())
	data^ = init_data(position^)
	side_time, wtime, btime, side_inc, winc, binc, movetime: int
	movestogo := 20

	for cmd in strings.split_iterator(line, " ") {
		switch cmd {
		case "depth":
			data.max_depth = get_next_int(line) or_return
		case "nodes":
			data.max_nodes = get_next_int(line) or_return
		case "wtime":
			wtime = get_next_int(line) or_return
		case "btime":
			btime = get_next_int(line) or_return
		case "winc":
			winc = get_next_int(line) or_return
		case "binc":
			binc = get_next_int(line) or_return
		case "movestogo":
			movestogo = get_next_int(line) or_return
		case "movetime":
			movetime = get_next_int(line) or_return
		case "infinite":
			data.infinite = true
		}
	}

	if position.turn == .White {
		side_time, side_inc = wtime, winc
	} else {
		side_time, side_inc = btime, binc
	}

	if movetime != 0 {
		data.allowed_time = time.Duration(movetime) * time.Millisecond
		data.infinite = false
	} else if side_time != 0 {
		data.allowed_time = time.Duration(side_time/movestogo + side_inc/2)
		data.allowed_time *= time.Millisecond
		data.infinite = false
	}

	stop_flag = false
	thread.run_with_data(data, search_thread, priority = .High)

	return true
}

get_next_int :: proc(line: ^string) -> (i: int, ok: bool) {
	str := strings.split_iterator(line, " ") or_return
	i = strconv.parse_int(str) or_return
	return i, true
}
