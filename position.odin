package blunderbuss

Colour :: enum{White, Black}
PieceType :: enum{Pawn, Knight, Bishop, Rook, Queen, King}
Castling :: enum{WhiteKingside, WhiteQueenside, BlackKingside, BlackQueenside}

Position :: struct {
    bitboards: [Colour][PieceType]u64,
    occupancy: [Colour]u64,
    turn: Colour,
    castling_rights: bit_set[Castling],
    ep_sq: int,
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

