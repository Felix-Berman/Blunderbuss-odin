package blunderbuss

import "core:fmt"
import "base:intrinsics"

Colour :: enum{White, Black}
PieceType :: enum{Pawn, Knight, Bishop, Rook, Queen, King}
Castling :: enum{WhiteKingside, WhiteQueenside, BlackKingside, BlackQueenside}

Position :: struct {
    bitboards: [Colour][PieceType]u64,
    occupancy: [Colour]u64,
    turn: Colour,
    castling: bit_set[Castling],
    ep_square: u8,
    halfmove_clk: u8,
    ply: u32,
}

piece_chars := [2][6]rune{
    {'P', 'N', 'B', 'R', 'Q', 'K'},
    {'p', 'n', 'b', 'r', 'q', 'k'},
}

new_position :: proc() -> (position: Position) {
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

    position.occupancy = [Colour]u64{.White = 0xffff, .Black = 0xffff << 6}
    position.turn = .White
    position.castling = ~ {}  // inverse of empty set
    position.ep_square = 64
    position.halfmove_clk = 0
    position.ply = 0
    return
}

lsb :: proc(bitboard: u64) -> u8 {
    return u8(intrinsics.count_trailing_zeros(bitboard))
}

pop_lsb :: proc(bitboard: ^u64) -> u8 {
    sq := lsb(bitboard^)
    bitboard^ &= bitboard^ - 1
    return sq
}

print_bitboard :: proc(bitboard: u64) {
    for sq := 63; sq >= 0; sq -= 1 {
        if bitboard & (1 << uint(sq)) == 0 {
            fmt.print("0 ")
        } else {
            fmt.print("1 ")
        }

        if sq % 8 == 0 {
            fmt.print("\n")
        }
    }
    fmt.println()
}

print_board :: proc(position: Position) {
    for rank := 7; rank >= 0; rank -= 1 {
        fmt.printf("%d ", rank + 1)
        for file := 7; file >= 0; file -= 1 {
            sq := rank * 8 + file
            piece_char := '-'

            outer: for colour in Colour {
                for piece in PieceType {
                    if position.bitboards[colour][piece] & (1 << uint(sq)) != 0 {
                        piece_char = piece_chars[colour][piece]
                        break outer
                    }
                }
            }

            fmt.printf("%c ", piece_char)
        }
        fmt.println()
    }
    fmt.println("  a b c d e f g h")

    fmt.print("Castling: ")
    if .WhiteKingside in position.castling { fmt.print("K") }
    if .WhiteQueenside in position.castling { fmt.print("Q") }
    if .BlackKingside in position.castling { fmt.print("k") }
    if .BlackQueenside in position.castling { fmt.print("q") }
    fmt.println()

    if position.ep_square != 64 {
        file := position.ep_square % 8
        rank := position.ep_square / 8
        fmt.printf("En passant square: %c%d\n", 'a'+file, rank+1)
    } else {
        fmt.println("En passant square: -")
    }

    fmt.println("Turn:", position.turn == Colour.White ? "w" : "b", "\n")
}

print :: proc{print_board, print_bitboard}