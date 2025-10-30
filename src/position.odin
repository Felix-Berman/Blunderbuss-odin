package blunderbuss

import "core:strings"
import "core:unicode"
import "core:strconv"

STARTING_FEN :: "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"

Colour :: enum{White, Black}
PieceType :: enum{Pawn, Knight, Bishop, Rook, Queen, King}
Castling :: enum{WhiteKingside, WhiteQueenside, BlackKingside, BlackQueenside}

Position :: struct {
    bitboards: [Colour][PieceType]u64,
    occupancy: [Colour]u64,
    turn: Colour,
    castling_rights: bit_set[Castling],
    ep_sq: int,
    halfmove_clk: uint,
    ply: uint,
}

starting_position :: proc() -> (position: Position) {
    position.bitboards[.White][.Pawn] = 0xff00
    position.bitboards[.White][.Knight] = 0x42
    position.bitboards[.White][.Bishop] = 0x24
    position.bitboards[.White][.Rook] = 0x81
    position.bitboards[.White][.King] = 0x08
    position.bitboards[.White][.Queen] = 0x10
    position.bitboards[.Black][.Pawn] = 0xff << (6*8)
    position.bitboards[.Black][.Knight] = 0x42 << (7*8)
    position.bitboards[.Black][.Bishop] = 0x24 << (7*8)
    position.bitboards[.Black][.Rook] = 0x81 << (7*8)
    position.bitboards[.Black][.King] = 0x08 << (7*8)
    position.bitboards[.Black][.Queen] = 0x10 << (7*8)

    position.occupancy = [Colour]u64{.White = 0xffff, .Black = 0xffff << (6*8)}
    position.turn = .White
    position.castling_rights = ~ {}  // inverse of empty set
    position.ep_sq = 64
    position.halfmove_clk = 0
    position.ply = 0
    return
}

occupied :: proc(position: ^Position) -> u64 {
    return position.occupancy[.White] | position.occupancy[.Black]
}

toggle :: proc(colour: Colour) -> Colour {
    return .Black if colour == .White else .White
}

parse_fen :: proc(fen: string) -> (position: Position) {
    fields := strings.split(fen, " ")
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
                        position.bitboards[colour][piece] |= to_bitboard(8*rank + file)
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
        if strings.to_lower(ep_sq) == sq_str {
            position.ep_sq = sq
            break
        }
    }

    position.halfmove_clk = strconv.parse_uint(halfmove_clk) or_else 0
    fullmove := strconv.parse_uint(fullmove_clk) or_else 1
    position.ply = 2 * (fullmove - 1) + uint(position.turn)

    return
}