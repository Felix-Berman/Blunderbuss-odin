package blunderbuss

import "core:fmt"
import "core:strings"

make_move :: proc(position: ^Position, move: Move) {
	// useful to see formatted move in debugger
	when ODIN_DEBUG {
		move_str := to_string(move)
		defer delete(move_str)
	}

	us := position.turn
	forward := 8 if us == .White else -8
	position.ply += 1

	// store position features that cannot be recovered after making move
	irreversibles := HistoryData {
		position.ep_sq,
		position.can_ep,
		nil,
		position.castling,
		position.halfmove_clk,
		position.hash,
		position.last_irreversible_ply,
	}

	mover, ok := piece_on(position, move.from)
	assert(ok, "Attempt to move from empty square")
	assert(mover.colour == us, "Mover colour does not align with turn")

	them := toggle(us)
	flags := get_flags(move)
	from_bb := to_bitboard(move.from)
	to_bb := to_bitboard(move.to)
	from_to_bb := from_bb | to_bb

	if mover.type == .Pawn || .Capture in flags {
		position.halfmove_clk = 0
		position.last_irreversible_ply = position.ply
	} else {
		position.halfmove_clk += 1
	}

	position.pieces[us][mover.type] &~= from_bb // wait to toggle to_bb in case of promotion
	position.occupancy[us] ~= from_to_bb
	position.hash ~= zobrist_p_sq(mover, move.from)

	if flags == EP_CAPTURE {
		captured := make_piece(them, .Pawn)
		ep_target_sq := position.ep_sq - forward
		ep_target := to_bitboard(ep_target_sq)
		position.pieces[them][.Pawn] &~= ep_target
		position.occupancy[them] &~= ep_target
		position.hash ~= zobrist_p_sq(captured, ep_target_sq)
		irreversibles.captured_piece = captured
	} else if .Capture in flags {
		captured, ok := piece_on(position, move.to)
		assert(ok, "Attempt to capture empty square")
		assert(captured.colour == them, "Captured colour does not align with opponent")
		assert(captured.type != .King, "Illegal capture of king")
		position.pieces[them][captured.type] &~= to_bb
		position.occupancy[them] &~= to_bb
		position.hash ~= zobrist_p_sq(captured, move.to)
		irreversibles.captured_piece = captured
	}

	if position.ep_sq < 64 {
		if position.can_ep {
			position.hash ~= ZOBRIST_RANDS[EP_OFFSET + position.ep_sq % 8]
			position.can_ep = false
			position.last_irreversible_ply = position.ply
		}
		position.ep_sq = 64
	}

	if flags == DOUBLE_PUSH {
		position.ep_sq = int(move.from) + forward
		possible_capturers := (to_bb << 1) &~ H_FILE | (to_bb >> 1) &~ A_FILE
		if possible_capturers & position.pieces[them][.Pawn] != 0 {
			position.hash ~= ZOBRIST_RANDS[EP_OFFSET + position.ep_sq % 8]
			position.can_ep = true
		}
	}

	if .Promotion in flags {
		switch flags &~ {.Capture} {
		case KNIGHT_PROMOTION:
			position.pieces[us][.Knight] |= to_bb
			position.hash ~= zobrist_p_sq(make_piece(us, .Knight), move.to)
		case BISHOP_PROMOTION:
			position.pieces[us][.Bishop] |= to_bb
			position.hash ~= zobrist_p_sq(make_piece(us, .Bishop), move.to)
		case ROOK_PROMOTION:
			position.pieces[us][.Rook] |= to_bb
			position.hash ~= zobrist_p_sq(make_piece(us, .Rook), move.to)
		case QUEEN_PROMOTION:
			position.pieces[us][.Queen] |= to_bb
			position.hash ~= zobrist_p_sq(make_piece(us, .Queen), move.to)
		}
	} else {
		position.pieces[us][mover.type] |= to_bb
		position.hash ~= zobrist_p_sq(mover, move.to)
	}

	if flags == KING_CASTLE {
		rook_from_to: u64 = 0x05 if us == .White else 0x05 << 56
		position.pieces[us][.Rook] ~= rook_from_to
		position.occupancy[us] ~= rook_from_to
		for rook_from_to > 0 {
			sq := pop_lsb(&rook_from_to)
			position.hash ~= zobrist_p_sq(make_piece(us, .Rook), sq)
		}
	} else if flags == QUEEN_CASTLE {
		rook_from_to: u64 = 0x90 if us == .White else 0x90 << 56
		position.pieces[us][.Rook] ~= rook_from_to
		position.occupancy[us] ~= rook_from_to
		for rook_from_to > 0 {
			sq := pop_lsb(&rook_from_to)
			position.hash ~= zobrist_p_sq(make_piece(us, .Rook), sq)
		}
	}

	if mover.type == .King {
		for right in position.castling {
			if right in CASTLING_SIDE[us] {
				position.hash ~= ZOBRIST_RANDS[CASTLING_OFFSET + int(right)]
				position.castling &~= {right}
				position.last_irreversible_ply = position.ply
			}
		}
	}

	if .WKingside in position.castling && from_to_bb & to_bitboard(Square.H1) != 0 {
		position.castling &~= {.WKingside}
		position.hash ~= ZOBRIST_RANDS[CASTLING_OFFSET + int(Castling.WKingside)]
		position.last_irreversible_ply = position.ply
	} else if .WQueenside in position.castling && from_to_bb & to_bitboard(Square.A1) != 0 {
		position.castling &~= {.WQueenside}
		position.hash ~= ZOBRIST_RANDS[CASTLING_OFFSET + int(Castling.WQueenside)]
		position.last_irreversible_ply = position.ply
	}

	if .BKingside in position.castling && from_to_bb & to_bitboard(Square.H8) != 0 {
		position.castling &~= {.BKingside}
		position.hash ~= ZOBRIST_RANDS[CASTLING_OFFSET + int(Castling.BKingside)]
		position.last_irreversible_ply = position.ply
	} else if .BQueenside in position.castling && from_to_bb & to_bitboard(Square.A8) != 0 {
		position.castling &~= {.BQueenside}
		position.hash ~= ZOBRIST_RANDS[CASTLING_OFFSET + int(Castling.BQueenside)]
		position.last_irreversible_ply = position.ply
	}

	// always apply
	append(&position.history, irreversibles)
	position.turn = them
	position.hash ~= ZOBRIST_RANDS[TURN_OFFSET]
	if us == .Black {
		position.fullmove_clk += 1
	}
	
	when ODIN_DEBUG {
		hash := zobrist_hash(position^)
		if position.hash != hash {
			fmt.println("Discrepancy between generated and updated hash")
			fmt.println(move_str)
			display(position^)

			for rand, i in ZOBRIST_RANDS {
				if hash ~ rand == position.hash {
					fmt.println("Error corrected by zobrist index:", i)
				}
			}
			assert(false)
		}
	}
}

unmake_move :: proc(position: ^Position, move: Move) {
	them := position.turn
	us := toggle(them)
	forward := 8 if us == .White else -8

	history := pop(&position.history)
	position.ep_sq = history.ep_sq
	position.can_ep = history.can_ep
	position.castling = history.castling_rights
	position.halfmove_clk = history.halfmove_clk
	position.hash = history.hash
	position.last_irreversible_ply = history.last_irreversible_ply

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
		captured := history.captured_piece.(Piece)
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
	if us == .Black {
		position.fullmove_clk -= 1
	}
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
