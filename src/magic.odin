package blunderbuss

import "core:slice"
import "core:simd/x86"

PEXT :: #config(PEXT, false)

MAGIC_SEED :: 18401105770426537108
ROOK_MAGICS: [64]Magic
BISHOP_MAGICS: [64]Magic

KING_TABLE: [64]u64
KNIGHT_TABLE: [64]u64
SLIDER_TABLE: [122624]u64 // ~980 Mb for perfect hashing of occ -> idx

Magic :: struct {
	mask: u64,
	mul: u64,
	offset: uint,
	shift: uint,
}

init_piece_tables :: proc() {
	offset: uint
	for sq in 0..<64 {
		rank := SQ_MASKS[sq].rank
		file := SQ_MASKS[sq].file
		diagonal := SQ_MASKS[sq].diagonal
		antidiag := SQ_MASKS[sq].antidiag

		edges := (A_FILE | H_FILE) & ~file
		edges |= (RANK_1 | RANK_8) & ~rank

		rook_mask := (rank ~ file) &~ edges
		bishop_mask := (diagonal ~ antidiag) &~ edges

		ROOK_MAGICS[sq].mask = rook_mask
		BISHOP_MAGICS[sq].mask = bishop_mask

		init_magic(sq, &offset, &ROOK_MAGICS[sq], rook_moves)
		init_magic(sq, &offset, &BISHOP_MAGICS[sq], bishop_moves)

		sq_bb := bitboard(sq)
		KING_TABLE[sq] = king_moves(sq_bb)
		KNIGHT_TABLE[sq] = knight_moves(sq_bb)
	}
}

magic_queen_moves :: proc(sq:int, occ: u64) -> u64 {
	return magic_rook_moves(sq, occ) | magic_bishop_moves(sq, occ)
}

when PEXT {
	@(enable_target_feature="bmi2")
	magic_rook_moves :: proc(sq: int, occ: u64) -> u64 {
		m := ROOK_MAGICS[sq]
		idx := x86._pext_u64(occ, m.mask)
		return SLIDER_TABLE[m.offset + uint(idx)]
	}

	@(enable_target_feature="bmi2")
	magic_bishop_moves :: proc(sq: int, occ: u64) -> u64 {
		m := BISHOP_MAGICS[sq]
		idx := x86._pext_u64(occ, m.mask)
		return SLIDER_TABLE[m.offset + uint(idx)]
	}

	@(enable_target_feature="bmi2")
	init_magic :: proc(
		sq: int,
		offset: ^uint,
		magic: ^Magic,
		move_proc: proc(int, u64) -> u64
	) {
		bit_count := pop_count(magic.mask)
		table_size: uint = 1 << uint(bit_count)

		magic.offset = offset^
		offset^ += table_size
		assert(offset^ < len(SLIDER_TABLE))

		for i in 0..<table_size {
			occ := x86._pdep_u64(u64(i), magic.mask)
			SLIDER_TABLE[magic.offset + i] = move_proc(sq, occ)
		}
	}

} else {
	magic_idx :: proc(m: Magic, occ: u64) -> uint {
		return m.offset + uint(((occ & m.mask) * m.mul) >> m.shift)
	}

	magic_rook_moves :: proc(sq: int, occ: u64) -> u64 {
		m := ROOK_MAGICS[sq]
		idx := magic_idx(m, occ)
		return SLIDER_TABLE[idx]
	}

	magic_bishop_moves :: proc(sq: int, occ: u64) -> u64 {
		m := BISHOP_MAGICS[sq]
		idx := magic_idx(m, occ)
		return SLIDER_TABLE[idx]
	}

	rng_state: u64 = MAGIC_SEED

	init_magic :: proc(
		sq: int,
		offset: ^uint,
		magic: ^Magic,
		move_proc: proc(int, u64) -> u64
	) {
		temp_occ, temp_moves: [4096]u64

		bit_count := uint(pop_count(magic.mask))
		magic.shift = 64 - bit_count
		magic.offset = offset^

		table_size: uint = 1 << bit_count
		offset^ += table_size
		assert(offset^ < len(SLIDER_TABLE))

		num_subsets := 0
		occ := magic.mask
		for {
			temp_occ[num_subsets] = occ
			temp_moves[num_subsets] = move_proc(sq, occ)
			num_subsets += 1

			if occ == 0 do break
			occ = (occ - 1) & magic.mask
		}

		magic_search: for {
			magic.mul = next_magic(&rng_state)

			slice.zero(SLIDER_TABLE[magic.offset : offset^])

			if pop_count((magic.mask * magic.mul) & 0xff00000000000000) < 6 {
				continue
			}

			for i in 0..<num_subsets {
				moves := temp_moves[i]
				idx := magic_idx(magic^, temp_occ[i])
				
				if SLIDER_TABLE[idx] == 0 {
					SLIDER_TABLE[idx] = moves
				} else if SLIDER_TABLE[idx] != moves {
					continue magic_search
				}
			}

			return
		}
	}
}

// sparse magics are more likely to be successful so 3 rands are intersected
next_magic :: proc(state: ^u64) -> u64 {
	magic := xor_shift(state)
	magic &= xor_shift(state)
	return magic & xor_shift(state)
}
