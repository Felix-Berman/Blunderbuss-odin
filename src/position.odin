package blunderbuss

import "core:strings"
import "core:unicode"
import "core:strconv"

STARTING_FEN :: "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"

Colour :: enum u8 {White, Black}
PieceType :: enum u8 {Pawn, Knight, Bishop, Rook, Queen, King}
Castling :: enum u8 {WKingside, WQueenside, BKingside, BQueenside}
CASTLING_SIDE: [Colour]bit_set[Castling] = {
	.White = {.WKingside, .WQueenside},
	.Black = {.BKingside, .BQueenside}
}

Piece :: bit_field u8 {
	colour: Colour | 1,
	type: PieceType | 3,
}

NIL_PIECE := transmute(Piece)~u8(0)

make_piece :: proc(colour: Colour, type: PieceType) -> Piece {
	return {
		type = type,
		colour = colour,
	}
}

Position :: struct {
	pieces: [Colour][PieceType]u64,
	occupancy: [Colour]u64,
	mailbox: [64]Piece,
	turn: Colour,
	castling: bit_set[Castling],
	ep_sq: int,
	ep_target: int,
	can_ep: bool,
	halfmove_clk: uint,
	fullmove_clk: uint,
	ply: int,
	hash: u64,
	last_irreversible_ply: int,
	history: [dynamic]HistoryData,
}

HistoryData :: struct {
	ep_sq: int,
	ep_target: int,
	can_ep: bool,
	captured_piece: Maybe(Piece),
	castling_rights: bit_set[Castling],
	halfmove_clk: uint,
	hash: u64,
	last_irreversible_ply: int
}

starting_position :: proc() -> (position: Position) {
	position.pieces[.White][.Pawn] = 0xff00
	position.pieces[.White][.Knight] = 0x42
	position.pieces[.White][.Bishop] = 0x24
	position.pieces[.White][.Rook] = 0x81
	position.pieces[.White][.King] = 0x08
	position.pieces[.White][.Queen] = 0x10
	position.pieces[.Black][.Pawn] = 0xff << (6*8)
	position.pieces[.Black][.Knight] = 0x42 << (7*8)
	position.pieces[.Black][.Bishop] = 0x24 << (7*8)
	position.pieces[.Black][.Rook] = 0x81 << (7*8)
	position.pieces[.Black][.King] = 0x08 << (7*8)
	position.pieces[.Black][.Queen] = 0x10 << (7*8)

	position.occupancy = [Colour]u64{.White = 0xffff, .Black = 0xffff << (6*8)}
	position.turn = .White
	position.castling = ~{}  // inverse of empty set
	position.ep_sq = 64
	position.halfmove_clk = 0
	position.ply = 0

	fill_mailbox(&position)
	position.hash = zobrist_hash(position)

	return
}

occupied :: proc(position: ^Position) -> u64 {
	return position.occupancy[.White] | position.occupancy[.Black]
}

toggle :: proc(colour: Colour) -> Colour {
	return Colour(int(colour) ~ 1)
}

fill_mailbox :: proc(position: ^Position) {
	position.mailbox = NIL_PIECE

	for side in Colour {
		for piece in PieceType {
			bb := position.pieces[side][piece]
			for bb > 0 {
				sq := pop_lsb(&bb)
				position.mailbox[sq] = make_piece(side, piece)
			}
		}
	}
}

is_in_check :: proc(position: ^Position, atk: u64) -> bool {
	return atk & position.pieces[position.turn][.King] != 0
}

parse_fen :: proc(fen: string) -> (position: Position, ok: bool) {
	fen := fen

	board := strings.split_iterator(&fen, " ") or_return

	rank := 7
	file := 7
	for row in strings.split_iterator(&board, "/") {
		for char in row {
			if unicode.is_digit(char) {
				file -= strconv.digit_to_int(char) or_continue
			}

			outer: 
			for pieces, colour in piece_chars {
				for piece_char, piece in pieces {
					if char == piece_char {
						bb := bitboard(8*rank + file)
						position.pieces[colour][piece] |= bb
						position.occupancy[colour] |= bb
						file -= 1
						break outer
					}
				}
			}
		}
		file = 7
		rank -= 1
	}

	turn := strings.split_iterator(&fen, " ") or_return

	switch turn {
		case "w":
			position.turn = .White
		case "b":
			position.turn = .Black
	}

	castling := strings.split_iterator(&fen, " ") or_return

	for char in castling {
		switch char {
			case 'K':
				position.castling |= {.WKingside}
			case 'k':
				position.castling |= {.BKingside}
			case 'Q':
				position.castling |= {.WQueenside}
			case 'q':
				position.castling |= {.BQueenside}
		}
	}

	ep_str := strings.split_iterator(&fen, " ") or_return

	position.ep_sq = 64
	for sq_str, sq in SQ_NAMES {
		if strings.equal_fold(ep_str, sq_str) {
			position.ep_sq = sq
			position.can_ep = can_ep(&position)

			if position.turn == .White {
				position.ep_target = sq - 8
			} else {
				position.ep_target = sq + 8
			}

			break
		}
	}

	halfmove_clk := strings.split_iterator(&fen, " ") or_else "0"
	fullmove_clk := strings.split_iterator(&fen, " ") or_else "1"

	position.halfmove_clk = strconv.parse_uint(halfmove_clk) or_else 0
	fullmove := strconv.parse_uint(fullmove_clk) or_else 1
	position.fullmove_clk = fullmove

	fill_mailbox(&position)
	position.hash = zobrist_hash(position)

	return position, true
}

can_ep :: proc(position: ^Position) -> bool {
	us := position.turn
	ep_bb := bitboard(position.ep_sq)
	possible_capturers: u64

	if us == .White {
		possible_capturers = (ep_bb >> 7) &~ H_FILE | (ep_bb >> 9) &~ A_FILE
	} else {
		possible_capturers = (ep_bb << 9) &~ H_FILE | (ep_bb << 7) &~ A_FILE
	}

	if possible_capturers & position.pieces[us][.Pawn] != 0 {
		return true
	}

	return false
}

is_pawn_endgame :: proc(position: Position) -> bool {
	pieces: u64

	for side in position.pieces {
		for bb, piece in side {
			if piece == .Pawn || piece == .King {
				continue
			}
			
			pieces |= bb
		}
	}

	return pieces == 0
}
