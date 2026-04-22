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
		position.ep_target,
		position.can_ep,
		nil,
		position.castling,
		position.halfmove_clk,
		position.hash,
		position.last_irreversible_ply,
	}

	mover := position.mailbox[move.from]
	assert(mover != NIL_PIECE, "No piece on move.from")
	assert(mover.colour == us, "Mover colour does not align with turn")

	them := toggle(us)
	flags := get_flags(move)
	from_bb := bitboard(move.from)
	to_bb := bitboard(move.to)
	from_to_bb := from_bb | to_bb

	if mover.type == .Pawn || .Capture in flags {
		position.halfmove_clk = 0
		position.last_irreversible_ply = position.ply
	} else {
		position.halfmove_clk += 1
	}

	position.pieces[us][mover.type] &~= from_bb // wait to toggle to_bb in case of promotion
	position.occupancy[us] ~= from_to_bb
	position.mailbox[move.from] = NIL_PIECE
	position.hash ~= zobrist_p_sq(mover, move.from)

	if flags == EP_CAPTURE {
		captured := make_piece(them, .Pawn)
		ep_target_sq := position.ep_target
		ep_target := bitboard(ep_target_sq)
		position.pieces[them][.Pawn] &~= ep_target
		position.occupancy[them] &~= ep_target
		position.mailbox[ep_target_sq] = NIL_PIECE
		position.hash ~= zobrist_p_sq(captured, ep_target_sq)
		irreversibles.captured_piece = captured
	} else if .Capture in flags {
		captured := position.mailbox[move.to]
		assert(captured != NIL_PIECE, "Attempt to capture empty square")
		assert(captured.colour == them, "Captured colour does not align with opponent")
		assert(captured.type != .King, "Illegal capture of king")
		position.pieces[them][captured.type] &~= to_bb
		position.occupancy[them] &~= to_bb
		position.mailbox[move.to] = NIL_PIECE
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
		position.ep_target = 64
	}

	if flags == DOUBLE_PUSH {
		position.ep_sq = int(move.from) + forward
		position.ep_target = int(move.to)
		possible_capturers := (to_bb << 1) &~ H_FILE | (to_bb >> 1) &~ A_FILE
		if possible_capturers & position.pieces[them][.Pawn] != 0 {
			position.hash ~= ZOBRIST_RANDS[EP_OFFSET + position.ep_sq % 8]
			position.can_ep = true
		}
	}

	if .Promotion in flags {
		piece: Piece
		switch flags &~ {.Capture} {
		case KNIGHT_PROMOTION:
			piece = make_piece(us, .Knight)
		case BISHOP_PROMOTION:
			piece = make_piece(us, .Bishop)
		case ROOK_PROMOTION:
			piece = make_piece(us, .Rook)
		case QUEEN_PROMOTION:
			piece = make_piece(us, .Queen)
		}

		position.pieces[piece.colour][piece.type] |= to_bb
		position.mailbox[move.to] = piece
		position.hash ~= zobrist_p_sq(piece, move.to)
	} else {
		position.pieces[us][mover.type] |= to_bb
		position.mailbox[move.to] = mover
		position.hash ~= zobrist_p_sq(mover, move.to)
	}

	if flags == KING_CASTLE {
		rook := make_piece(us, .Rook)
		from: Square = .H1 if us == .White else .H8
		to: Square = .F1 if us == .White else .F8
		rook_from_to: u64 = 0x05 if us == .White else 0x05 << 56

		position.pieces[us][.Rook] ~= rook_from_to
		position.occupancy[us] ~= rook_from_to
		position.mailbox[from] = NIL_PIECE
		position.mailbox[to] = rook

		for rook_from_to > 0 {
			sq := pop_lsb(&rook_from_to)
			position.hash ~= zobrist_p_sq(make_piece(us, .Rook), sq)
		}
	} else if flags == QUEEN_CASTLE {
		rook := make_piece(us, .Rook)
		from: Square = .A1 if us == .White else .A8
		to: Square = .D1 if us == .White else .D8
		rook_from_to: u64 = 0x90 if us == .White else 0x90 << 56

		position.pieces[us][.Rook] ~= rook_from_to
		position.occupancy[us] ~= rook_from_to
		position.mailbox[from] = NIL_PIECE
		position.mailbox[to] = rook

		for rook_from_to > 0 {
			sq := pop_lsb(&rook_from_to)
			position.hash ~= zobrist_p_sq(make_piece(us, .Rook), sq)
		}
	}

	for right in position.castling {
		mask := CASTLING_MASK[right]

		if from_to_bb & mask != 0 {
			position.castling &~= {right}
			position.hash ~= ZOBRIST_RANDS[CASTLING_OFFSET + int(right)]
			position.last_irreversible_ply = position.ply
		}
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
			print(position^)

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
	position.ep_target = history.ep_target
	position.can_ep = history.can_ep
	position.castling = history.castling_rights
	position.halfmove_clk = history.halfmove_clk
	position.hash = history.hash
	position.last_irreversible_ply = history.last_irreversible_ply

	mover := position.mailbox[move.to]
	assert(mover != NIL_PIECE && mover.colour == us)

	flags := get_flags(move)
	from_bb := bitboard(move.from)
	to_bb := bitboard(move.to)
	from_to_bb := from_bb | to_bb

	position.pieces[us][mover.type] &~= to_bb // wait to toggle from_bb in case of promotion
	position.occupancy[us] ~= from_to_bb
	position.mailbox[move.to] = NIL_PIECE

	if flags == EP_CAPTURE {
		ep_target := bitboard(position.ep_sq - forward)
		position.pieces[them][.Pawn] |= ep_target
		position.occupancy[them] |= ep_target
		position.mailbox[lsb(ep_target)] = make_piece(them, .Pawn)
	} else if .Capture in flags {
		captured := history.captured_piece.(Piece)
		position.pieces[them][captured.type] |= to_bb
		position.occupancy[them] |= to_bb
		position.mailbox[move.to] = captured
	}

	if .Promotion in flags {
		position.pieces[us][.Pawn] |= from_bb
		position.mailbox[move.from] = make_piece(us, .Pawn)
	} else {
		position.pieces[us][mover.type] |= from_bb
		position.mailbox[move.from] = mover
	}

	if flags == KING_CASTLE {
		rook := make_piece(us, .Rook)
		rook_from_to: u64 = 0x05 if us == .White else 0x05 << 56
		from: Square = .H1 if us == .White else .H8
		to: Square = .F1 if us == .White else .F8

		position.pieces[us][.Rook] ~= rook_from_to
		position.occupancy[us] ~= rook_from_to
		position.mailbox[from] = rook
		position.mailbox[to] = NIL_PIECE
	} else if flags == QUEEN_CASTLE {
		rook := make_piece(us, .Rook)
		rook_from_to: u64 = 0x90 if us == .White else 0x90 << 56
		from: Square = .A1 if us == .White else .A8
		to: Square = .D1 if us == .White else .D8

		position.pieces[us][.Rook] ~= rook_from_to
		position.occupancy[us] ~= rook_from_to
		position.mailbox[from] = rook
		position.mailbox[to] = NIL_PIECE
	}

	position.turn = us
	position.ply -= 1
	if us == .Black {
		position.fullmove_clk -= 1
	}
}

make_move_str :: proc(position: ^Position, str: string) -> (ok: bool) {
	masks := gen_legality_masks(position)
	moves := gen_moves(position, masks)
	defer delete(moves)

	for move in moves {
		move_str := to_string(move)
		defer delete(move_str)
		if strings.equal_fold(move_str, str) {
			if !is_legal(position, masks, move) {
				return false
			}

			make_move(position, move)

			return true
		}
	}

	return
}

make_null_move :: proc(position: ^Position) {
	us := position.turn
	them := toggle(us)
	position.ply += 1

	// store position features that cannot be recovered after making move
	irreversibles := HistoryData{
		position.ep_sq,
		position.ep_target,
		position.can_ep,
		nil,
		position.castling,
		position.halfmove_clk,
		position.hash,
		position.last_irreversible_ply,
	}

	position.last_irreversible_ply = position.ply // repetitions break at null

	if position.ep_sq < 64 {
		if position.can_ep {
			position.hash ~= ZOBRIST_RANDS[EP_OFFSET + position.ep_sq % 8]
			position.can_ep = false
		}
		position.ep_sq = 64
	}

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
			print(position^)

			for rand, i in ZOBRIST_RANDS {
				if hash ~ rand == position.hash {
					fmt.println("Error corrected by zobrist index:", i)
				}
			}
			assert(false)
		}
	}
}

unmake_null_move :: proc(position: ^Position) {
	them := position.turn
	us := toggle(them)

	history := pop(&position.history)
	position.ep_sq = history.ep_sq
	position.can_ep = history.can_ep
	position.castling = history.castling_rights
	position.halfmove_clk = history.halfmove_clk
	position.hash = history.hash
	position.last_irreversible_ply = history.last_irreversible_ply

	position.turn = us
	position.ply -= 1
	if us == .Black {
		position.fullmove_clk -= 1
	}
}
