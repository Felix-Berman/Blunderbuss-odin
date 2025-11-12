package blunderbuss

import "core:strings"
import "core:fmt"
import "base:intrinsics"

SQ_NAMES := [64]string{
    "h1", "g1", "f1", "e1", "d1", "c1", "b1", "a1",
    "h2", "g2", "f2", "e2", "d2", "c2", "b2", "a2",
    "h3", "g3", "f3", "e3", "d3", "c3", "b3", "a3",
    "h4", "g4", "f4", "e4", "d4", "c4", "b4", "a4",
    "h5", "g5", "f5", "e5", "d5", "c5", "b5", "a5",
    "h6", "g6", "f6", "e6", "d6", "c6", "b6", "a6",
    "h7", "g7", "f7", "e7", "d7", "c7", "b7", "a7",
    "h8", "g8", "f8", "e8", "d8", "c8", "b8", "a8",
}

piece_chars: [Colour][PieceType]rune = {
    .White = {.Pawn = 'P', .Knight = 'N', .Bishop = 'B', .Rook = 'R', .Queen = 'Q', .King = 'K'},
    .Black = {.Pawn = 'p', .Knight = 'n', .Bishop = 'b', .Rook = 'r', .Queen = 'q', .King = 'k'},
}

to_string_sq :: proc(sq: Square) -> string {
    return SQ_NAMES[uint(sq)]
}

to_string_sq_int :: proc(sq: int) -> string {
    return SQ_NAMES[uint(sq)]
}

to_string_sq_uint :: proc(sq: uint) -> string {
    return SQ_NAMES[sq]
}

to_string_bitboard :: proc(bitboard: u64) -> string {
    builder := strings.builder_make()
    defer strings.builder_destroy(&builder)

    for sq := 63; sq >= 0; sq -= 1 {
        if bitboard & (1 << uint(sq)) == 0 {
            fmt.sbprint(&builder, "0 ")
        } else {
            fmt.sbprint(&builder, "1 ")
        }

        if sq % 8 == 0 {
            fmt.sbprintln(&builder)
        }
    }

    return strings.to_string(builder)
}

to_string_board :: proc(position: Position) -> string {
    builder := strings.builder_make()
    defer strings.builder_destroy(&builder)

    for rank := 7; rank >= 0; rank -= 1 {
        fmt.sbprintf(&builder, "%d ", rank + 1)

        for file := 7; file >= 0; file -= 1 {
            sq := rank * 8 + file
            piece_char := '-'

            outer: for colour in Colour {
                for piece in PieceType {
                    if position.pieces[colour][piece] & (1 << uint(sq)) != 0 {
                        piece_char = piece_chars[colour][piece]
                        break outer
                    }
                }
            }

            fmt.sbprintf(&builder, "%c ", piece_char)
        }
        fmt.sbprintln(&builder)
    }
    fmt.sbprintln(&builder, "  a b c d e f g h")

    fmt.sbprint(&builder, "Castling: ")
    if .WhiteKingside in position.castling_rights { fmt.sbprint(&builder, 'K') }
    if .WhiteQueenside in position.castling_rights { fmt.sbprint(&builder, 'Q') }
    if .BlackKingside in position.castling_rights { fmt.sbprint(&builder, 'k') }
    if .BlackQueenside in position.castling_rights { fmt.sbprint(&builder, 'q') }
    fmt.sbprintln(&builder)

    if position.ep_sq != 64 {
        file := position.ep_sq % 8
        rank := position.ep_sq / 8
        fmt.sbprintfln(&builder, "En passant square: %c%d", 'a'+file, rank+1)
    } else {
        fmt.sbprintln(&builder, "En passant square: -")
    }

    fmt.sbprintln(&builder, "Turn:", position.turn == Colour.White ? "w" : "b")

    return strings.to_string(builder)
}

to_string_move :: proc(move: Move) -> string {
    builder := strings.builder_make()
    defer strings.builder_destroy(&builder)
    fmt.sbprintf(&builder, "%s%s", to_string(move.from), to_string(move.to))

    flags := get_flags(move)
    switch flags &~ CAPTURE {
        case KNIGHT_PROMOTION:
            strings.write_rune(&builder, 'n')
        case BISHOP_PROMOTION:
            strings.write_rune(&builder, 'b')
        case ROOK_PROMOTION:
            strings.write_rune(&builder, 'r')
        case QUEEN_PROMOTION:
            strings.write_rune(&builder, 'q')
    }

    return strings.to_string(builder)
}

to_string :: proc {
    to_string_board, 
    to_string_bitboard, 
    to_string_sq,
    to_string_sq_int,
    to_string_sq_uint,
    to_string_move,
}