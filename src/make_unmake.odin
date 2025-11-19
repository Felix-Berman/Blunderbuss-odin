package blunderbuss

import "core:strings"

make_move :: proc(position: ^Position, move: Move) {
    us := position.turn
    forward := 8 if us == .White else -8

    position.halfmove_clk += 1 // increment at start and reset if required

    // store position features that cannot be recovered after making move
    irreversibles := Irreversibles{
        position.ep_sq,
        nil,
        position.castling_rights,
        position.halfmove_clk
    }

    mover, ok := piece_on(position, move.from)
    assert(ok && mover.colour == us)

    them := toggle(us)
    flags := get_flags(move)
    from_bb := to_bitboard(move.from)
    to_bb := to_bitboard(move.to)
    from_to_bb := from_bb | to_bb

    position.pieces[us][mover.type] &~= from_bb // wait to toggle to_bb in case of promotion
    position.occupancy[us] ~= from_to_bb

    if flags == EP_CAPTURE {
        ep_target := to_bitboard(position.ep_sq - forward)
        position.pieces[them][.Pawn] &~= ep_target
        position.occupancy[them] &~= ep_target
        irreversibles.captured_piece = Piece{them, .Pawn}
    } else if .Capture in flags {
        captured, ok := piece_on(position, move.to)
        assert(ok && captured.colour == them)
        position.pieces[them][captured.type] &~= to_bb
        position.occupancy[them] &~= to_bb
        irreversibles.captured_piece = captured
    }

    // ep_sq must be reset before double push to distinguish between value from this move or previous move
    position.ep_sq = 64 
    if flags == DOUBLE_PUSH {
        position.ep_sq = int(move.from) + forward
    }

    if .Promotion in flags {
		switch flags &~ {.Capture} {
		case KNIGHT_PROMOTION:
            position.pieces[us][.Knight] |= to_bb
		case BISHOP_PROMOTION:
            position.pieces[us][.Bishop] |= to_bb
		case ROOK_PROMOTION:
            position.pieces[us][.Rook] |= to_bb
		case QUEEN_PROMOTION:
            position.pieces[us][.Queen] |= to_bb
        }
    } else {
        position.pieces[us][mover.type] |= to_bb
    }

    if flags == KING_CASTLE {
        rook_from_to: u64 = 0x05 if us == .White else 0x05 << 56
        position.pieces[us][.Rook] ~= rook_from_to
        position.occupancy[us] ~= rook_from_to
        position.castling_rights &~= CASTLING_SIDE[us]
    } else if flags == QUEEN_CASTLE {
        rook_from_to: u64 = 0x90 if us == .White else 0x90 << 56
        position.pieces[us][.Rook] ~= rook_from_to
        position.occupancy[us] ~= rook_from_to
        position.castling_rights &~= CASTLING_SIDE[us]
    } else if mover.type == .King {
        position.castling_rights &~= CASTLING_SIDE[us]
    }

	if from_to_bb & to_bitboard(Square.H1) != 0 {
		position.castling_rights &~= {.WhiteKingside}
	} else if from_to_bb & to_bitboard(Square.A1) != 0 {
			position.castling_rights &~= {.WhiteQueenside}
	} 

	if from_to_bb & to_bitboard(Square.H8) != 0 {
		position.castling_rights &~= {.BlackKingside}
	} else if from_to_bb & to_bitboard(Square.A8) != 0 {
		position.castling_rights &~= {.BlackQueenside}
	}


    // always apply
    append(&position.irreversible_history, irreversibles)
    position.turn = them
    position.ply += 1
}

unmake_move :: proc(position: ^Position, move: Move) {
    them := position.turn
    us := toggle(them)
    forward := 8 if us == .White else -8

    irreversibles := pop(&position.irreversible_history)
    position.ep_sq = irreversibles.ep_sq
    position.castling_rights = irreversibles.castling_rights
    position.halfmove_clk = irreversibles.halfmove_clk

    mover, ok := piece_on(position, move.to)
    assert(ok && mover.colour == us)

    flags := get_flags(move)
    from_bb := to_bitboard(move.from)
    to_bb := to_bitboard(move.to)
    from_to_bb := from_bb | to_bb

    position.pieces[us][mover.type] &~= to_bb // wait to toggle from_bb in case of promotion
    position.occupancy[us] ~= from_to_bb

    if flags == EP_CAPTURE {
        ep_target := to_bitboard(position.ep_sq - forward)
        position.pieces[them][.Pawn] |= ep_target
        position.occupancy[them] |= ep_target
    } else if .Capture in flags {
        captured := irreversibles.captured_piece.(Piece)
        position.pieces[them][captured.type] |= to_bb
        position.occupancy[them] |= to_bb
    }

    if .Promotion in flags {
        position.pieces[us][.Pawn] |= from_bb
    } else {
        position.pieces[us][mover.type] |= from_bb
    }

    if flags == KING_CASTLE {
        rook_from_to: u64 = 0x05 if us == .White else 0x05 << 56
        position.pieces[us][.Rook] ~= rook_from_to
        position.occupancy[us] ~= rook_from_to
    } else if flags == QUEEN_CASTLE {
        rook_from_to: u64 = 0x90 if us == .White else 0x90 << 56
        position.pieces[us][.Rook] ~= rook_from_to
        position.occupancy[us] ~= rook_from_to
    }

    position.turn = us
    position.ply -= 1
}

make_move_str :: proc(position: ^Position, str: string) -> (ok: bool) {
	moves := gen_pseudo_legal_moves(position)
	defer delete(moves)

	for move in moves {
		move_str := to_string(move)
		defer delete(move_str)
		if strings.equal_fold(move_str, str) {
			make_move(position, move)
			if is_in_check(toggle(position.turn), position) {
				unmake_move(position, move)
				return
			}

			ok = true
			break
		}
	}

	return
}

