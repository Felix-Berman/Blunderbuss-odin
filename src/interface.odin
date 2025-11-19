package blunderbuss

import "core:os"
import "core:bufio"
import "core:fmt"
import "core:strings"
import "core:strconv"

uci_loop :: proc() {
	stdin := os.stream_from_handle(os.stdin)
	scanner: bufio.Scanner
	bufio.scanner_init(&scanner, stdin)
	defer bufio.scanner_destroy(&scanner)

	position := starting_position()
	defer delete(position.irreversible_history)

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
		case "debug":
		case "isready":
			fmt.println("readyok")
		case "setoption":
		case "ucinewgame":
			delete(position.irreversible_history)
			position = starting_position()
		case "position":
			if new_position, ok := parse_position(&line); ok {
				delete(position.irreversible_history)
				position = new_position
			} else {
				fmt.println("Invalid position command:", full_line)	
			}
		case "go":
			if ok := go(&line, &position); !ok {
				fmt.println("Invalid go command:", full_line)
			}
		case "perft":
			if depth_str, ok := strings.split_iterator(&line, " "); ok {
				depth := strconv.parse_int(depth_str) or_else 0
				perft_divide(&position, depth)
			}
		case "print":
			display(position)
		}

		for word in strings.split_iterator(&line, " ") {
			fmt.println(word)
		}
	}

	if err := bufio.scanner_error(&scanner); err != nil {
		fmt.eprintfln("error scanning input: %v", err)
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
		make_move_str(&position, move) or_return
	}

	return position, true
}

go :: proc(line: ^string, position: ^Position) -> bool {
	depth: int

	for cmd in strings.split_iterator(line, " ") {
		switch cmd {
		case "depth":
			depth_str := strings.split_iterator(line, " ") or_return
			depth = strconv.parse_int(depth_str) or_return
		}
	}

	root_search(position, depth)

	return true
}
