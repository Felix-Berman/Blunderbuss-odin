package blunderbuss

import "base:intrinsics"

// Move Encoding: https://www.chessprogramming.org/Encoding_Moves
MoveFlags :: enum{Promotion, Capture, Special1, Special0}
MoveFlagSet :: bit_set[MoveFlags; uint]
QUIET: MoveFlagSet: {}
DOUBLE_PUSH: MoveFlagSet: {.Special0}
KING_CASTLE: MoveFlagSet: {.Special1}
QUEEN_CASTLE: MoveFlagSet: {.Special1, .Special0}
CAPTURE: MoveFlagSet: {.Capture}
EP_CAPTURE: MoveFlagSet: {.Capture, .Special0}
KNIGHT_PROMOTION: MoveFlagSet: {.Promotion}
BISHOP_PROMOTION: MoveFlagSet: {.Promotion, .Special0}
ROOK_PROMOTION: MoveFlagSet: {.Promotion, .Special1}
QUEEN_PROMOTION: MoveFlagSet: {.Promotion, .Special1, .Special0}

Move :: bit_field u16 {
	from: uint | 6,
	to: uint | 6,
	flags: uint | 4,
}

NULL_MOVE :: Move{}

set_flags :: proc(move: ^Move, flags: MoveFlagSet) {
	move.flags = transmute(uint) flags
}

get_flags :: proc(move: Move) -> MoveFlagSet {
	return transmute(bit_set[MoveFlags; uint]) move.flags
}

is_dynamic :: proc(flags: MoveFlagSet) -> bool {
	return flags & {.Capture, .Promotion} != QUIET
}


build_move :: proc(from, to: $T , flags: MoveFlagSet) -> (move: Move) 
where intrinsics.type_is_numeric(T) {
	move.from = uint(from)
	move.to = uint(to)
	set_flags(&move, flags)
	return
}

gen_moves :: proc(position: ^Position, masks: LegalMasks) -> []Move {
	num_checkers := intrinsics.count_ones(masks.checkers)
	if num_checkers > 1 {
		return gen_king_evasions(position, masks)
	}

	moves := make([dynamic]Move, 0, 30)

	if num_checkers == 0 {
		gen_castling(position, masks.danger, &moves)
	}

	if position.can_ep {
		gen_en_passant(position, masks, &moves)
	}

	gen_pawn_captures(position, masks, &moves)
	gen_piece_moves(position, masks, &moves)
	gen_pawn_pushes(position, masks, &moves)

	return moves[:]
}

gen_king_evasions :: proc(position: ^Position, masks: LegalMasks) -> []Move {
	moves := make([dynamic]Move, 0, 8)
	us := position.turn
	them := toggle(us)
	occ := occupied(position)
	king := position.pieces[position.turn][.King]
	king_sq := lsb(king)
	move_bb := KING_TABLE[king_sq] &~ masks.danger
	quiets := move_bb &~ occ
	captures := move_bb & position.occupancy[them]
	
	for quiets > 0 {
		to := pop_lsb(&quiets)
		append(&moves, build_move(king_sq, to, QUIET))
	}

	for captures > 0 {
		to := pop_lsb(&captures)
		append(&moves, build_move(king_sq, to, CAPTURE))
	}

	return moves[:]
}

gen_piece_moves :: proc(position: ^Position, masks: LegalMasks, moves: ^[dynamic]Move) {
	us := position.turn
	them := toggle(us)
	occ := occupied(position)
	enemies := position.occupancy[them]
	piece_bitboards := position.pieces[us]

	for &bb, piece in piece_bitboards {
		move_proc: proc(sq: int, occ: u64) -> u64

		switch piece {
			case .Pawn:
				continue
			case .Knight:
				move_proc = knight_moves_sq
			case .Bishop:
				move_proc = magic_bishop_moves
			case .Rook:
				move_proc = magic_rook_moves
			case .Queen:
				move_proc = magic_queen_moves
			case .King:
				move_proc = king_moves_sq
		}

		for bb > 0 {
			from := pop_lsb(&bb)
			to_bb := move_proc(from, occ)

			if piece == .King {
				to_bb &~= masks.danger
			} else {
				to_bb &= masks.block_ray
			}

			quiets := to_bb &~ occ
			captures := to_bb & enemies

			for captures > 0 {
				to := pop_lsb(&captures)
				append(moves, build_move(from, to, CAPTURE))
			}

			for quiets > 0 {
				to := pop_lsb(&quiets)
				append(moves, build_move(from, to, QUIET))
			}
		}
	}
}

king_moves :: proc(king: u64) -> (move_bb: u64) {
	move_bb |= (king << 1) &~ H_FILE
	move_bb |= (king << 7) &~ A_FILE
	move_bb |= (king << 8)
	move_bb |= (king << 9) &~ H_FILE
	move_bb |= (king >> 9) &~ A_FILE
	move_bb |= (king >> 8)
	move_bb |= (king >> 7) &~ H_FILE
	move_bb |= (king >> 1) &~ A_FILE
	return
}

knight_moves :: proc(knight: u64) -> (move_bb: u64) {
	move_bb |= knight << 6 &~ (A_FILE | B_FILE)
	move_bb |= knight << 15 &~ A_FILE
	move_bb |= knight << 17 &~ H_FILE
	move_bb |= knight << 10 &~ (H_FILE | G_FILE)
	move_bb |= knight >> 6 &~ (H_FILE | G_FILE)
	move_bb |= knight >> 15 &~ H_FILE
	move_bb |= knight >> 17 &~ A_FILE
	move_bb |= knight >> 10 &~ (A_FILE | B_FILE)
	return
}

// wrappers for generalised move procedure pointer
king_moves_sq :: proc(sq: int, _: u64) -> u64 {
	return KING_TABLE[sq]
}

knight_moves_sq :: proc(sq: int, _: u64) -> u64 {
	return KNIGHT_TABLE[sq]
}

bishop_moves :: proc(sq: int, occ: u64) -> u64 {
	return diagonal_attacks(sq, occ) | antidiag_attacks(sq, occ)
}

rook_moves :: proc(sq: int, occ: u64) -> u64 {
	return rank_attacks(sq, occ) | file_attacks(sq, occ)
}

queen_moves :: proc(sq: int, occ: u64) -> u64 {
	return rank_attacks(sq, occ) | file_attacks(sq, occ) | diagonal_attacks(sq, occ) | antidiag_attacks(sq, occ)
}

pawn_attacks :: proc(side: Colour, pawns: u64) -> u64 {
	if side == .White {
		return ((pawns << 9) &~ H_FILE) | ((pawns << 7) &~ A_FILE)
	} else {
		return ((pawns >> 7) &~ H_FILE) | ((pawns >> 9) &~ A_FILE)
	}
}

gen_pawn_pushes :: proc(position: ^Position, masks: LegalMasks, moves: ^[dynamic]Move) {
	side := position.turn
	forward := 8 if side == .White else -8

	pawns := position.pieces[side][.Pawn]
	occ := occupied(position)

	single_push, double_push, promotions: u64

	if side == .White {
		single_push = (pawns << 8) &~ occ
		double_push = ((single_push & RANK_3) << 8) &~ occ
		promotions = single_push & RANK_8
	} else {
		single_push = (pawns >> 8) &~ occ
		double_push = ((single_push & RANK_6) >> 8) &~ occ
		promotions = single_push & RANK_1
	}

	single_push &~= promotions

	single_push &= masks.block_ray
	double_push &= masks.block_ray
	promotions &= masks.block_ray

	for single_push > 0 {
		to := pop_lsb(&single_push)
		from := to - forward
		append(moves, build_move(from, to, QUIET))
	}

	for double_push > 0 {
		to := pop_lsb(&double_push)
		from := to - 2 * forward
		append(moves, build_move(from, to, DOUBLE_PUSH))
	}

	for promotions > 0 {
		to := pop_lsb(&promotions)
		from := to - forward
		append(moves, build_move(from, to, QUEEN_PROMOTION))
		append(moves, build_move(from, to, ROOK_PROMOTION))
		append(moves, build_move(from, to, KNIGHT_PROMOTION))
		append(moves, build_move(from, to, BISHOP_PROMOTION))
	}
}

gen_pawn_captures :: proc(position: ^Position, masks: LegalMasks, moves: ^[dynamic]Move) {
	side := position.turn

	west := 9 if side == .White else -7
	east := 7 if side == .White else -9

	pawns := position.pieces[side][.Pawn]
	targets := position.occupancy[toggle(side)] & masks.block_ray

	west_captures := (pawns << 9 if side == .White else pawns >> 7) &~ H_FILE & targets
	east_captures := (pawns << 7 if side == .White else pawns >> 9) &~ A_FILE & targets
	
	west_promotions := west_captures & (RANK_8 if side == .White else RANK_1)
	east_promotions := east_captures & (RANK_8 if side == .White else RANK_1)

	west_captures &~= west_promotions
	east_captures &~= east_promotions

	for west_captures > 0 {
		to := pop_lsb(&west_captures)
		from := to - west
		append(moves, build_move(from, to, CAPTURE))
	}

	for east_captures > 0 {
		to := pop_lsb(&east_captures)
		from := to - east
		append(moves, build_move(from, to, CAPTURE))
	}

	for west_promotions > 0 {
		to := pop_lsb(&west_promotions)
		from := to - west
		append(moves, build_move(from, to, QUEEN_PROMOTION + CAPTURE))
		append(moves, build_move(from, to, ROOK_PROMOTION + CAPTURE))
		append(moves, build_move(from, to, KNIGHT_PROMOTION + CAPTURE))
		append(moves, build_move(from, to, BISHOP_PROMOTION + CAPTURE))
	}

	for east_promotions > 0 {
		to := pop_lsb(&east_promotions)
		from := to - east
		append(moves, build_move(from, to, QUEEN_PROMOTION + CAPTURE))
		append(moves, build_move(from, to, ROOK_PROMOTION + CAPTURE))
		append(moves, build_move(from, to, KNIGHT_PROMOTION + CAPTURE))
		append(moves, build_move(from, to, BISHOP_PROMOTION + CAPTURE))
	}
}

// assumes en passant is legal
gen_en_passant :: proc(position: ^Position, masks: LegalMasks, moves: ^[dynamic]Move) {
	side := position.turn
	to := position.ep_sq
	to_bb := bitboard(to)

	target_pawn := to_bb >> 8 if side == .White else to_bb << 8
	if target_pawn & masks.checkers == 0 && to_bb & masks.block_ray == 0 {
		return
	}

	pawns := position.pieces[side][.Pawn]
	from_bb := pawns & pawn_attacks(toggle(side), to_bb)

	for from_bb > 0 {
		from := pop_lsb(&from_bb)
		append(moves, build_move(from, to, EP_CAPTURE))
	}
}

// assumes not in check
gen_castling :: proc(position: ^Position, danger: u64, moves: ^[dynamic]Move) {
	side := position.turn
	occ := occupied(position)
	from: Square = .E1 if side == .White else .E8
	to_kingside: Square = .G1 if side == .White else .G8
	to_queenside: Square = .C1 if side == .White else .C8

	// squares that must be vaccant and not attacked
	k_mask: u64 = 0x06 if side == .White else 0x06 << 56
	q_occ: u64 = 0x70 if side == .White else 0x70 << 56
	q_check: u64 = 0x30 if side == .White else 0x30 << 56

	kingside: Castling = .WKingside if side == .White else .BKingside
	queenside: Castling = .WQueenside if side == .White else .BQueenside

	if kingside in position.castling && k_mask & (danger | occ) == 0 {
		append(moves, build_move(from, to_kingside, KING_CASTLE))
	}
	if queenside in position.castling && (q_occ & occ) | (q_check & danger) == 0 {
		append(moves, build_move(from, to_queenside, QUEEN_CASTLE))
	}
}

gen_attack_mask :: proc($side: Colour, position: ^Position, occ: u64) -> (atk: u64) {
	king := position.pieces[side][.King]
	knights := position.pieces[side][.Knight]
	bishop_queen := position.pieces[side][.Bishop] | position.pieces[side][.Queen]
	rook_queen := position.pieces[side][.Rook] | position.pieces[side][.Queen]
	pawns := position.pieces[side][.Pawn]

	atk |= KING_TABLE[lsb(king)]
	atk |= knight_moves(knights)
	atk |= pawn_attacks(side, pawns)

	for bishop_queen > 0 {
		sq := pop_lsb(&bishop_queen)
		atk |= magic_bishop_moves(sq, occ)
	}
	for rook_queen > 0 {
		sq := pop_lsb(&rook_queen)
		atk |= magic_rook_moves(sq, occ)
	}

	return
}

gen_legality_masks :: proc(position: ^Position) -> (masks: LegalMasks) {
	us := position.turn
	them := toggle(us)
	pieces := position.pieces
	king_bb_us := pieces[us][.King]
	king_sq_us := lsb(king_bb_us)
	king_bb_them := pieces[them][.King]
	king_sq_them := lsb(king_bb_them)
	pawns_them := pieces[them][.Pawn]
	knights_them := pieces[them][.Knight]
	bishoplike_them := pieces[them][.Bishop] | pieces[them][.Queen]
	rooklike_them := pieces[them][.Rook] | pieces[them][.Queen]
	occ_us := position.occupancy[us]
	occ_them := position.occupancy[them]
	occ_kingless := occupied(position) &~ pieces[us][.King]

	attackers := magic_bishop_moves(king_sq_us, occ_them) & bishoplike_them
	attackers |= magic_rook_moves(king_sq_us, occ_them) & rooklike_them

	for attackers > 0 {
		from := pop_lsb(&attackers)
		from_bb := bitboard(from)
		blockers := BETWEEN[king_sq_us][from] & occ_us
		if blockers == 0 {
			masks.checkers |= from_bb
			masks.block_ray |= BETWEEN[king_sq_us][from]
		} else if intrinsics.count_ones(blockers) == 1 {
			masks.pinned |= blockers
			masks.pin_rays[lsb(blockers)] = BETWEEN[king_sq_us][from] | from_bb
		}
	}

	masks.checkers |= KNIGHT_TABLE[king_sq_us] & pieces[them][.Knight]
	masks.checkers |= pawn_attacks(us, king_bb_us) & pieces[them][.Pawn]

	if masks.checkers == 0 {
		masks.block_ray = FULL_BB
	} else if intrinsics.count_ones(masks.checkers) == 1 {
		masks.block_ray |= masks.checkers
	}

	masks.danger |= KING_TABLE[king_sq_them]
	masks.danger |= pawn_attacks(them, pawns_them)
	masks.danger |= knight_moves(knights_them)
	
	for bishoplike_them > 0 {
		from := pop_lsb(&bishoplike_them)
		masks.danger |= magic_bishop_moves(from, occ_kingless)
	}

	for rooklike_them > 0 {
		from := pop_lsb(&rooklike_them)
		masks.danger |= magic_rook_moves(from, occ_kingless)
	}

	return
}

is_legal :: proc(position: ^Position, masks: LegalMasks, move: Move) -> bool {
	from_bb := bitboard(move.from)
	to_bb := bitboard(move.to)
	flags := get_flags(move)

	// pinned piece must move along pin ray
	if from_bb & masks.pinned != 0 {
		return to_bb & masks.pin_rays[move.from] != 0
	}

	if flags == EP_CAPTURE {
		king_sq := lsb(position.pieces[position.turn][.King])
		ep_target := bitboard(position.ep_target)
		
		if king_sq / 8 == int(move.from) / 8 {
			them := toggle(position.turn)
			occ := occupied(position) &~ (from_bb | ep_target)
			rooklike := position.pieces[them][.Rook] | position.pieces[them][.Queen]
			return rank_attacks(king_sq, occ) & rooklike == 0
		}
	}


	return true
}

attackers_to :: proc(position: ^Position, sq: int) -> (attackers: [Colour]u64) {
	bb := bitboard(sq)
	occ := occupied(position)
	pieces := position.pieces
	
	attackers[.White] = (bb >> 9 | bb >> 7) & pieces[.White][.Pawn]
	attackers[.Black] = (bb << 9 | bb << 7) & pieces[.Black][.Pawn]
	
	for side in Colour {
		bishop_like := pieces[side][.Bishop] | pieces[side][.Queen]
		rook_like := pieces[side][.Rook] | pieces[side][.Queen]
		
		attackers[side] |= KNIGHT_TABLE[sq] & pieces[side][.Knight]
		attackers[side] |= magic_bishop_moves(sq, occ) & bishop_like
		attackers[side] |= magic_rook_moves(sq, occ) & rook_like
		attackers[side] |= KING_TABLE[sq] & pieces[side][.King]
	}
	
	return
}

// calculate sliding attacks using hyperbola quintessence: 
// https://www.chessprogramming.org/Hyperbola_Quintessence

diagonal_attacks :: proc(sq: int, occ: u64) -> u64 {
	sq_bb  := bitboard(sq)
	forward := occ & SQ_MASKS[sq].diagonal// remove all but relevant blockers
	reverse := mirror_vertically(forward)
	forward -= 2 * sq_bb						// remove sliders and carry borrow from least significant blocker
	reverse -= 2 * mirror_vertically(sq_bb)
	forward ~= mirror_vertically(reverse)		// combine directions
	return forward & SQ_MASKS[sq].diagonal// mask to relevant sliding axis
}

antidiag_attacks :: proc(sq: int, occ: u64) -> u64 {
	sq_bb := bitboard(sq)
	forward := occ & SQ_MASKS[sq].antidiag// remove all but relevant blockers
	reverse := mirror_vertically(forward)
	forward -= 2 * sq_bb						// remove sliders and carry borrow from least significant blocker
	reverse -= 2 * mirror_vertically(sq_bb)
	forward ~= mirror_vertically(reverse)		// combine directions
	return forward & SQ_MASKS[sq].antidiag// mask to relevant sliding axis
}

file_attacks :: proc(sq: int, occ: u64) -> u64 {
	sq_bb := bitboard(sq)
	forward := occ & SQ_MASKS[sq].file// remove all but relevant blockers
	reverse := mirror_vertically(forward)
	forward -= 2 * sq_bb						// remove sliders and carry borrow from least significant blocker
	reverse -= 2 * mirror_vertically(sq_bb)
	forward ~= mirror_vertically(reverse)		// combine directions
	return forward & SQ_MASKS[sq].file// mask to relevant sliding axis
}

rank_attacks :: proc(sq: int, occ: u64) -> u64 {
	sq_bb := bitboard(sq)
	forward := occ & SQ_MASKS[sq].rank// remove all but relevant blockers
	reverse := mirror_horizontally(forward)
	forward -= 2 * sq_bb						// remove sliders and carry borrow from least significant blocker
	reverse -= 2 * mirror_horizontally(sq_bb)
	forward ~= mirror_horizontally(reverse)		// combine directions
	return forward & SQ_MASKS[sq].rank// mask to relevant sliding axis
}

// compute rank attacks for all rooks in bitboard
setwise_rank_attacks :: proc(sliders, occ: u64) -> u64 {
	west := occ | H_FILE						// add blockers on eastern edge to prevent wrapping
	occ_mirr := mirror_horizontally(occ)		// do the same for reverse direction
	east := occ_mirr | H_FILE
	west -= 2 * sliders							// remove sliders and carry borrow from least significant blocker
	east -= 2 * mirror_horizontally(sliders)
	west ~= occ									// set least significat blocker back to one and all others to 0
	east ~= occ_mirr
	west &~= H_FILE								// unset wrapping protection bits
	east &~= H_FILE
	return west ~ mirror_horizontally(east)		// combine directions
}
