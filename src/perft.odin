package blunderbuss

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:testing"
import "core:log"

perft :: proc(position: ^Position, depth: int) -> (nodes: int) {
	if depth == 0 {
		return 1
	}

	moves: [dynamic]Move
    defer delete(moves)

    if position.turn == .White {
        moves = gen_pseudo_legal_moves(.White, position)
    } else {
        moves = gen_pseudo_legal_moves(.Black, position)
    }

	for move, i in moves {
		make_move(position, move)
		defer unmake_move(position, move)

		if is_in_check(position.turn, position) do continue

		nodes += perft(position, depth - 1)
	}

	return
}

perft_divide :: proc(position: ^Position, depth: int) {
	assert(depth > 0)

	total_nodes: int = 0
    
	moves: [dynamic]Move
    defer delete(moves)

    if position.turn == .White {
        moves = gen_pseudo_legal_moves(.White, position)
    } else {
        moves = gen_pseudo_legal_moves(.Black, position)
    }
	

	node_counts := make(map[string]int)
	defer delete(node_counts)

	keys: [dynamic]string
	defer delete(keys)

	for move in moves {
		make_move(position, move)
		defer unmake_move(position, move)

		if is_in_check(position.turn, position) do continue

		nodes := perft(position, depth - 1)

		move_str := to_string(move)

		node_counts[move_str] = nodes
		append(&keys, move_str)

		total_nodes += nodes
	}

	slice.sort(keys[:])
	for move_str in keys {
		nodes := node_counts[move_str]
		fmt.printfln("{} {}", move_str, nodes)
	}
	fmt.println(total_nodes)

	free_all(context.temp_allocator)
}

test_range :: [2]int{0, 126}

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

		position := parse_fen(fen)
        defer delete(position.irreversible_history)

		log.infof("perft test {}\nFEN: {}", test_num, fen)

		for field in strings.split_iterator(&fields, ";") {
			depths := strings.split(field, " ")
			defer delete(depths)

			depth_str := depths[0]
			depth := depth_str[1] - '0'
			expected_nodes, ok := strconv.parse_int(depths[1])
			if !ok do return

			nodes := perft(&position, int(depth))
			
			if !testing.expect_value(t, nodes, expected_nodes) {
                log.infof("depth {}: FAIL", depth)
				return
			}

			log.infof("depth {}: SUCCESS", depth)
		}

		test_num += 1
	}
}
