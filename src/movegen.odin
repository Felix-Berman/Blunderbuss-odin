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

set_flags :: proc(move: ^Move, flags: MoveFlagSet) {
    move.flags = transmute(uint) flags
}

get_flags :: proc(move: Move) -> MoveFlagSet {
    return transmute(bit_set[MoveFlags; uint]) move.flags
}

build_move :: proc(from, to: $T , flags: MoveFlagSet) -> (move: Move) 
where intrinsics.type_is_numeric(T) {
    move.from = uint(from)
    move.to = uint(to)
    set_flags(&move, flags)
    return
}

gen_pseudo_legal_moves :: proc(position: ^Position) -> (moves: [dynamic]Move) {
	us := position.turn
	them := toggle(us)
    occ := occupied(position)
    enemies := position.occupancy[them]
    piece_bitboards := position.pieces[us]
	atk: u64

	if us == .White {
		atk = gen_attack_mask(.Black, position, occ)
		gen_castling(.White, position, occ, atk, &moves)
		gen_en_passant(.White, position, &moves)
		gen_pawn_captures(.White, position, &moves)
		gen_pawn_pushes(.White, position, &moves)
	} else {
		atk = gen_attack_mask(.White, position, occ)
		gen_castling(.Black, position, occ, atk, &moves)
		gen_en_passant(.Black, position, &moves)
		gen_pawn_captures(.Black, position, &moves)
		gen_pawn_pushes(.Black, position, &moves)
	}

    for &bb, piece in piece_bitboards {
        move_proc: proc(sq: int, occ: u64) -> u64

        switch piece {
            case .Pawn:
                continue
            case .Knight:
                move_proc = knight_moves_sq
            case .Bishop:
                move_proc = bishop_moves
            case .Rook:
                move_proc = rook_moves
            case .Queen:
                move_proc = queen_moves
            case .King:
                move_proc = king_moves_sq
        }

        for bb > 0 {
            from := pop_lsb(&bb)
            to_bb := move_proc(from, occ)

            quiets := to_bb &~ occ
            captures := to_bb & enemies

            for captures > 0 {
                to := pop_lsb(&captures)
                append(&moves, build_move(from, to, CAPTURE))
            }

            for quiets > 0 {
                to := pop_lsb(&quiets)
                append(&moves, build_move(from, to, QUIET))
            }
        }
    }

    return
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
    return king_moves(to_bitboard(sq))
}

knight_moves_sq :: proc(sq: int, _: u64) -> u64 {
    return knight_moves(to_bitboard(sq))
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

gen_pawn_pushes :: proc($side: Colour, position: ^Position, moves: ^[dynamic]Move) {
    forward :: 8 when side == .White else -8

    pawns := position.pieces[side][.Pawn]
    occ := occupied(position)

    single_push := (pawns << 8 when side == .White else pawns >> 8) &~ occ
    double_push := ((single_push & RANK_3) << 8 when side == .White else (single_push & RANK_6) >> 8) &~ occ

    promotions := single_push & (RANK_8 when side == .White else RANK_1)
    single_push &~= promotions

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

gen_pawn_captures :: proc($side: Colour, position: ^Position, moves: ^[dynamic]Move) {
    west :: 9 when side == .White else -7
    east :: 7 when side == .White else -9

    pawns := position.pieces[side][.Pawn]
    targets := position.occupancy[toggle(side)]

    west_captures := (pawns << 9 when side == .White else pawns >> 7) &~ H_FILE & targets
    east_captures := (pawns << 7 when side == .White else pawns >> 9) &~ A_FILE & targets
    
    west_promotions := west_captures & (RANK_8 when side == .White else RANK_1)
    east_promotions := east_captures & (RANK_8 when side == .White else RANK_1)

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
gen_en_passant :: proc($side: Colour, position: ^Position, moves: ^[dynamic]Move) {
    pawns := position.pieces[side][.Pawn]
    to := position.ep_sq
    to_bb := to_bitboard(to)
    from_bb: u64

    when side == .White {
        from_bb = ((to_bb >> 7) &~ H_FILE) | ((to_bb >> 9) &~ A_FILE)
    } else {
        from_bb = ((to_bb << 9) &~ H_FILE) | ((to_bb << 7) &~ A_FILE)
    }

    from_bb &= pawns

    for from_bb > 0 {
        from := pop_lsb(&from_bb)
        append(moves, build_move(from, to, EP_CAPTURE))
    }
}

// assumes not in check
gen_castling :: proc($side: Colour, position: ^Position, occ, atk: u64, moves: ^[dynamic]Move) {
    from: Square : .E1 when side == .White else .E8
    to_kingside: Square : .G1 when side == .White else .G8
    to_queenside: Square : .C1 when side == .White else .C8

    // squares that must be vaccant and not attacked
	kingside_check_mask :: 0x0e when side == .White else 0x0e << 56
    kingside_block_mask :: 0x06 when side == .White else 0x06 << 56
    queenside_check_mask :: 0x38 when side == .White else 0x38 << 56
    queenside_block_mask :: 0x70 when side == .White else 0x30 << 56

    kingside: Castling = .WhiteKingside when side == .White else .BlackKingside
    queenside: Castling = .WhiteQueenside when side == .White else .BlackQueenside

    kingside_legal := kingside in position.castling_rights &&
		kingside_check_mask & atk == 0 && kingside_block_mask & occ == 0
    queenside_legal := queenside in position.castling_rights &&
		queenside_check_mask & atk == 0 && queenside_block_mask & occ == 0

    if kingside_legal {
        append(moves, build_move(from, to_kingside, KING_CASTLE))
    }
    if queenside_legal {
        append(moves, build_move(from, to_queenside, QUEEN_CASTLE))
    }
}

gen_attack_mask :: proc($side: Colour, position: ^Position, occ: u64) -> (atk: u64) {
    king := position.pieces[side][.King]
    knights := position.pieces[side][.Knight]
    bishop_queen := position.pieces[side][.Bishop] | position.pieces[side][.Queen]
    rook_queen := position.pieces[side][.Rook] | position.pieces[side][.Queen]
    pawns := position.pieces[side][.Pawn]

    when side == .White {
        atk |= ((pawns << 9) &~ H_FILE) | ((pawns << 7) &~ A_FILE)
    } else {
        atk |= ((pawns >> 7) &~ H_FILE) | ((pawns >> 9) &~ A_FILE)
    }

    atk |= king_moves(king)
    atk |= knight_moves(knights)

    for bishop_queen > 0 {
        sq := pop_lsb(&bishop_queen)
        atk |= bishop_moves(sq, occ)
    }
    for rook_queen > 0 {
        sq := pop_lsb(&rook_queen)
        atk |= rook_moves(sq, occ)
    }

    position.atk_masks[side] = atk
    return
}

// calculate sliding attacks using hyperbola quintessence: 
// https://www.chessprogramming.org/Hyperbola_Quintessence

diagonal_attacks :: proc(sq: int, occ: u64) -> u64 {
    sq_bb  := to_bitboard(sq)
    forward := occ & SQ_MASKS[sq].diagonal_mask // remove all but relevant blockers
    reverse := mirror_vertically(forward)
    forward -= 2 * sq_bb                        // remove sliders and carry borrow from least significant blocker
    reverse -= 2 * mirror_vertically(sq_bb)
    forward ~= mirror_vertically(reverse)       // combine directions
    return forward & SQ_MASKS[sq].diagonal_mask // mask to relevant sliding axis
}

antidiag_attacks :: proc(sq: int, occ: u64) -> u64 {
    sq_bb := to_bitboard(sq)
    forward := occ & SQ_MASKS[sq].antidiag_mask // remove all but relevant blockers
    reverse := mirror_vertically(forward)
    forward -= 2 * sq_bb                        // remove sliders and carry borrow from least significant blocker
    reverse -= 2 * mirror_vertically(sq_bb)
    forward ~= mirror_vertically(reverse)       // combine directions
    return forward & SQ_MASKS[sq].antidiag_mask // mask to relevant sliding axis
}

file_attacks :: proc(sq: int, occ: u64) -> u64 {
    sq_bb := to_bitboard(sq)
    forward := occ & SQ_MASKS[sq].file_mask     // remove all but relevant blockers
    reverse := mirror_vertically(forward)
    forward -= 2 * sq_bb                        // remove sliders and carry borrow from least significant blocker
    reverse -= 2 * mirror_vertically(sq_bb)
    forward ~= mirror_vertically(reverse)       // combine directions
    return forward & SQ_MASKS[sq].file_mask     // mask to relevant sliding axis
}

rank_attacks :: proc(sq: int, occ: u64) -> u64 {
    sq_bb := to_bitboard(sq)
    forward := occ & SQ_MASKS[sq].rank_mask     // remove all but relevant blockers
    reverse := mirror_horizontally(forward)
    forward -= 2 * sq_bb                        // remove sliders and carry borrow from least significant blocker
    reverse -= 2 * mirror_horizontally(sq_bb)
    forward ~= mirror_horizontally(reverse)     // combine directions
    return forward & SQ_MASKS[sq].rank_mask     // mask to relevant sliding axis
}

// compute rank attacks for all rooks in bitboard
setwise_rank_attacks :: proc(sliders, occ: u64) -> u64 {
    west := occ | H_FILE                        // add blockers on eastern edge to prevent wrapping
    occ_mirr := mirror_horizontally(occ)        // do the same for reverse direction
    east := occ_mirr | H_FILE
    west -= 2 * sliders                         // remove sliders and carry borrow from least significant blocker
    east -= 2 * mirror_horizontally(sliders)
    west ~= occ                                 // set least significat blocker back to one and all others to 0
    east ~= occ_mirr
    west &~= H_FILE                             // unset wrapping protection bits
    east &~= H_FILE
    return west ~ mirror_horizontally(east)     // combine directions
}
