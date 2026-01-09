package blunderbuss

import "base:intrinsics"

ZOBRIST_COUNT :: 12 * 64 + 1 + 4 + 8 // piece * sq + turn + castling + en-passant
TURN_OFFSET :: 12 * 64
CASTLING_OFFSET :: TURN_OFFSET + 1
EP_OFFSET :: CASTLING_OFFSET + 4
ZOBRIST_RANDS := gen_zobrist_rands()

gen_zobrist_rands :: proc "contextless" () -> (zobrist_rands: [ZOBRIST_COUNT]u64) {
	state: u64 = 5308338
	for i in 0..<ZOBRIST_COUNT {
		zobrist_rands[i] = xor_shift(&state)
	}

	return
}

xor_shift :: proc "contextless" (x: ^u64) -> u64 {
	x^ ~= x^ << 13
	x^ ~= x^ >> 17
	x^ ~= x^ << 5
	return x^
}

zobrist_hash :: proc(position: Position) -> (hash: u64) {
	us := position.turn

	for bbs, side in position.pieces {
		for bb, piece in bbs {
			bb := bb
			for bb > 0 {
				sq := pop_lsb(&bb)
				hash ~= zobrist_p_sq(make_piece(side, piece), sq)
			}
		}
	}

	if position.turn == .Black {
		hash ~= ZOBRIST_RANDS[TURN_OFFSET]
	}

	for right in position.castling {
		hash ~= ZOBRIST_RANDS[CASTLING_OFFSET + uint(right)]
	}
	
	if position.ep_sq < 64 {
		ep_bb := bitboard(position.ep_sq)
		possible_capturers: u64

		if us == .White {
			possible_capturers = (ep_bb >> 7) &~ H_FILE | (ep_bb >> 9) &~ A_FILE
		} else {
			possible_capturers = (ep_bb << 9) &~ H_FILE | (ep_bb << 7) &~ A_FILE
		}

		if possible_capturers & position.pieces[us][.Pawn] != 0 {
			hash ~= ZOBRIST_RANDS[EP_OFFSET + position.ep_sq % 8]
		}
	}

	return
}

zobrist_p_sq :: proc(piece: Piece, sq: $T) -> u64 
where intrinsics.type_is_numeric(T) {
	return ZOBRIST_RANDS[T(piece) * 64 + sq]
}
