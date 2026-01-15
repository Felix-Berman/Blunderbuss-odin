package blunderbuss

import "core:slice"

MAGIC_SEED :: 18401105770426537108

KING_TABLE: [64]u64
KNIGHT_TABLE: [64]u64

ROOK_TABLE: [64][4096]u64
ROOK_MAGICS: [64]Magic
ROOK_SHIFT :: 12

BISHOP_TABLE: [64][512]u64
BISHOP_MAGICS: [64]Magic
BISHOP_SHIFT :: 9

Magic :: struct {
	mask: u64,
	mul: u64,
}

magic_rook_moves :: proc(sq: int, occ: u64) -> u64 {
	magic := ROOK_MAGICS[sq]
	idx := magic_idx(magic, ROOK_SHIFT, occ)
	return ROOK_TABLE[sq][idx]
}

magic_bishop_moves :: proc(sq: int, occ: u64) -> u64 {
	magic := BISHOP_MAGICS[sq]
	idx := magic_idx(magic, BISHOP_SHIFT, occ)
	return BISHOP_TABLE[sq][idx]
}

magic_queen_moves :: proc(sq:int, occ: u64) -> u64 {
	return magic_rook_moves(sq, occ) | magic_bishop_moves(sq, occ)
}

magic_idx :: proc(magic: Magic, shift: uint, occ: u64) -> uint {
	return uint(((occ & magic.mask) * magic.mul) >> (64 - shift))
}

find_magic :: proc(
	mask: u64,
	sq: int,
	shift: uint,
	table: []u64,
	move_proc: proc(int, u64) -> u64
) -> Magic {
	rng_state: u64 = MAGIC_SEED

	magic_search: for {
		magic_num := next_magic(&rng_state)
		magic := Magic{mask, magic_num}
		slice.zero(table)

		for occ := mask ;; occ = (occ - 1) & mask {
			moves := move_proc(sq, occ)
			idx := magic_idx(magic, shift, occ)
			
			if table[idx] == 0 {
				table[idx] = moves
			} else if moves != table[idx] {
				continue magic_search
			}

			if occ == 0 {
				return magic
			}
		}
	}
}

init_piece_tables :: proc() {
	offset := 0
	for sq in 0..<64 {
		rng_state: u64 = MAGIC_SEED

		rank := SQ_MASKS[sq].rank
		file := SQ_MASKS[sq].file
		diagonal := SQ_MASKS[sq].diagonal
		antidiag := SQ_MASKS[sq].antidiag

		edges := (A_FILE | H_FILE) & ~file
		edges |= (RANK_1 | RANK_8) & ~rank

		rook_mask := (rank ~ file) &~ edges
		bishop_mask := (diagonal ~ antidiag) &~ edges

		ROOK_MAGICS[sq] = find_magic(
			rook_mask, sq, ROOK_SHIFT, ROOK_TABLE[sq][:], rook_moves)
		BISHOP_MAGICS[sq] = find_magic(
			bishop_mask, sq, BISHOP_SHIFT, BISHOP_TABLE[sq][:], bishop_moves)

		sq_bb := bitboard(sq)
		KING_TABLE[sq] = king_moves(sq_bb)
		KNIGHT_TABLE[sq] = knight_moves(sq_bb)
	}
}

// sparse magics are more likely to be successful so 3 rands are intersected
next_magic :: proc(state: ^u64) -> u64 {
	magic := xor_shift(state)
	magic &= xor_shift(state)
	return magic & xor_shift(state)
}
