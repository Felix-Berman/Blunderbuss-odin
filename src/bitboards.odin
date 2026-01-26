package blunderbuss

import "base:intrinsics"

// Bitboards defined from MSB -> LSB : A8 -> H1
// i.e. H1 = 0, A1 = 7, H8 = 56, A8 = 63
// This encoding makes visualising bitboards in hex form more intuitive. Reading left to right maps to 
// top left to bottom right.
// Shift operations are also easy to visualise, << shifts west/north and >> shifts east/south

A_FILE: u64 : 0x8080808080808080
B_FILE: u64 : A_FILE >> 1
C_FILE: u64 : B_FILE >> 1
D_FILE: u64 : C_FILE >> 1
E_FILE: u64 : D_FILE >> 1
F_FILE: u64 : E_FILE >> 1
G_FILE: u64 : F_FILE >> 1
H_FILE: u64 : G_FILE >> 1

RANK_1: u64 : 0xff
RANK_2: u64 : RANK_1 << 8
RANK_3: u64 : RANK_2 << 8
RANK_4: u64 : RANK_3 << 8
RANK_5: u64 : RANK_4 << 8
RANK_6: u64 : RANK_5 << 8
RANK_7: u64 : RANK_6 << 8
RANK_8: u64 : RANK_7 << 8

MAIN_DIAGONAL: u64 : 0x8040201008040201;
MAIN_ANTIDIAG: u64 : 0x0102040810204080;

EMPTY_BB: u64 : 0
FULL_BB :: ~EMPTY_BB

Direction :: enum {N, S, E, W, NW, NE, SW, SE}
DIRECTION_STEP := [Direction]int{
	.N = 8,
	.S = -8,
	.E = -1,
	.W = 1,
	.NW = 9,
	.NE = 7,
	.SW = -7,
	.SE = -9,
}

Square :: enum {
    H1 ,  G1 ,  F1 ,  E1 ,  D1 ,  C1 ,  B1 ,  A1 ,
    H2 ,  G2 ,  F2 ,  E2 ,  D2 ,  C2 ,  B2 ,  A2 ,
    H3 ,  G3 ,  F3 ,  E3 ,  D3 ,  C3 ,  B3 ,  A3 ,
    H4 ,  G4 ,  F4 ,  E4 ,  D4 ,  C4 ,  B4 ,  A4 ,
    H5 ,  G5 ,  F5 ,  E5 ,  D5 ,  C5 ,  B5 ,  A5 ,
    H6 ,  G6 ,  F6 ,  E6 ,  D6 ,  C6 ,  B6 ,  A6 ,
    H7 ,  G7 ,  F7 ,  E7 ,  D7 ,  C7 ,  B7 ,  A7 ,
    H8 ,  G8 ,  F8 ,  E8 ,  D8 ,  C8 ,  B8 ,  A8 ,
}

SqMasks :: struct {
    rank: u64,
    file: u64,
    diagonal: u64,
    antidiag: u64,
}

LegalMasks :: struct {
	checkers: u64,
	blockers: u64,
	block_ray: u64,
	pin_rays: [64]u64,
	danger: u64,
}

bitboard :: proc "contextless" (sq: $T) -> u64 
    where intrinsics.type_is_numeric(T) {
    return 1 << uint(sq)
}

lsb :: proc(bitboard: u64) -> int {
    return int(intrinsics.count_trailing_zeros(bitboard))
}

pop_lsb :: proc(bitboard: ^u64) -> int {
    sq := lsb(bitboard^)
    bitboard^ &= bitboard^ - 1
    return sq
}

mirror_vertically :: proc(bitboard: u64) -> u64 {
    return intrinsics.byte_swap(bitboard)
}

mirror_horizontally :: proc(bitboard: u64) -> u64 {
    bb := bitboard
    k1 :: 0x5555555555555555
    k2 :: 0x3333333333333333
    k4 :: 0x0f0f0f0f0f0f0f0f

    bb = ((bb >> 1) & k1) + 2 * (bb & k1)
    bb = ((bb >> 2) & k2) + 4 * (bb & k2)
    bb = ((bb >> 4) & k4) + 16 * (bb & k4)
    return bb
}

square_colour :: proc(sq: int) -> Colour {
	if (sq % 8 + sq / 8) % 2 == 0 {
		return .White
	} else {
		return .Black
	}
}

pop_count :: proc(bb: u64) -> int {
	return int(intrinsics.count_ones(bb))
}
