package blunderbuss

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:testing"
import "core:log"

perft :: proc(position: ^Position, depth: int) -> (nodes: int) {
	if depth == 0 {
		return 1
	}

	moves := gen_pseudo_legal_moves(position)
	defer delete(moves)

	us := position.turn

	for move, i in moves {
		make_move(position, move)
		defer unmake_move(position, move)

		if is_in_check(us, position) do continue

		nodes += perft(position, depth - 1)
	}

	return
}

perft_divide :: proc(position: ^Position, depth: int) {
	if depth == 0 {
		fmt.println(0)
	}

	total_nodes: int = 0

	moves := gen_pseudo_legal_moves(position)
	defer delete(moves)

	us := position.turn
	
	for move in moves {
		make_move(position, move)
		defer unmake_move(position, move)

		if is_in_check(us, position) do continue

		nodes := perft(position, depth - 1)
		total_nodes += nodes

		move_str := to_string(move)
		defer delete(move_str)

		fmt.printfln("{} {}", move_str, nodes)
	}

	fmt.println()
	fmt.println(total_nodes)
}

test_range :: [2]int{1, 126}

@(test)
perft_suite :: proc(t: ^testing.T) {

	perft_file, ok := os.read_entire_file("perftsuite.epd")

	if !ok {
		return
	}
	defer delete(perft_file)

	perft_str := string(perft_file)

	test_num := 0
	for line in strings.split_lines_iterator(&perft_str) {
		defer test_num += 1
		if test_num < test_range[0] do continue
		if test_num > test_range[1] do break

		fields := line
		fen, ok := strings.split_iterator(&fields, ";")
		if !ok do return

		position := parse_fen(fen) or_continue
        defer delete(position.irreversible_history)

		log.infof("perft test {}", test_num)
		log.infof("FEN: {}",  fen)

		for field in strings.split_iterator(&fields, ";") {
			depths := strings.split(field, " ")
			defer delete(depths)

			depth_str := depths[0]
			depth := depth_str[1] - '0'
			expected_nodes, ok := strconv.parse_int(depths[1])
			if !ok do return

			nodes := perft(&position, int(depth))
			
			if !testing.expect_value(t, nodes, expected_nodes) {
                log.infof("depth {}: \033[31;1mFAIL\033[0m", depth)
				return
			}

			log.infof("depth {}: \033[32;1mSUCCESS\033[0m", depth)
		}

		test_num += 1
	}
}
