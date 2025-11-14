package blunderbuss

import "core:strings"
import "core:unicode"
import "core:strconv"
import "base:intrinsics"

STARTING_FEN :: "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"

Colour :: enum{White, Black}
PieceType :: enum{Pawn, Knight, Bishop, Rook, Queen, King}
Piece :: struct{colour: Colour, type: PieceType}
Castling :: enum{WhiteKingside, WhiteQueenside, BlackKingside, BlackQueenside}

Position :: struct {
    pieces: [Colour][PieceType]u64,
    occupancy: [Colour]u64,
    atk_masks: [Colour]u64,
    turn: Colour,
    castling_rights: bit_set[Castling],
    ep_sq: int,
    halfmove_clk: uint,
    ply: uint,

    irreversible_history: [dynamic]Irreversibles,
}

Irreversibles :: struct {
    ep_sq: int,
    captured_piece: Maybe(Piece),
    castling_rights: bit_set[Castling],
    halfmove_clk: uint
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
    position.castling_rights = ~ {}  // inverse of empty set
    position.ep_sq = 64
    position.halfmove_clk = 0
    position.ply = 0

    gen_attack_mask(.White, &position, occupied(&position))
    gen_attack_mask(.Black, &position, occupied(&position))
    
    return
}

occupied :: proc(position: ^Position) -> u64 {
    return position.occupancy[.White] | position.occupancy[.Black]
}

toggle :: proc(colour: Colour) -> Colour {
    return Colour(int(colour) ~ 1)
}

piece_on :: proc(position: ^Position, sq: $T) -> (Piece, bool) 
    where intrinsics.type_is_numeric(T) {
    
    for colour in Colour {
        for type in PieceType {
            if position.pieces[colour][type] & to_bitboard(sq) != 0 {
                return Piece{colour, type}, true
            }
        }
    }

    return {}, false
}

is_in_check :: proc(side: Colour, position: ^Position) -> bool {
	atk: u64
	if side == .White do atk = gen_attack_mask(.Black, position, occupied(position))
	if side == .Black do atk = gen_attack_mask(.White, position, occupied(position))
    return position.pieces[side][.King] & atk != 0
}

parse_fen :: proc(fen: string) -> (position: Position) {
    fields := strings.split(fen, " ")
    defer delete(fields)
    board := fields[0]
    turn := fields[1]
    castling := fields[2]
    ep_sq := fields[3]
    halfmove_clk := fields[4]
    fullmove_clk := fields[5]

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
                        bb := to_bitboard(8*rank + file)
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

    switch turn[0] {
        case 'w':
            position.turn = .White
        case 'b':
            position.turn = .Black
    }

    for char in castling {
        switch char {
            case 'K':
                position.castling_rights |= {.WhiteKingside}
            case 'k':
                position.castling_rights |= {.BlackKingside}
            case 'Q':
                position.castling_rights |= {.WhiteQueenside}
            case 'q':
                position.castling_rights |= {.BlackQueenside}
        }
    }

    position.ep_sq = 64
    for sq_str, sq in SQ_NAMES {
        if strings.equal_fold(ep_sq, sq_str) {
            position.ep_sq = sq
            break
        }
    }

    position.halfmove_clk = strconv.parse_uint(halfmove_clk) or_else 0
    fullmove := strconv.parse_uint(fullmove_clk) or_else 1
    position.ply = 2 * (fullmove - 1) + uint(position.turn)

    occ := occupied(&position)
    gen_attack_mask(.White, &position, occ)
    gen_attack_mask(.Black, &position, occ)

    return
}
