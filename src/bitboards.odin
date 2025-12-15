package blunderbuss

import "base:builtin"
import  "base:intrinsics"

// Bitboards defined from MSB -> LSB : A8 -> H1
// i.e. H1 = 0, A1 = 7, H8 = 56, A8 = 63
// This encoding makes visualising bitboards in hex form more intuitive.
// Reading left to right maps to top left to bottom right.
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

to_bitboard :: proc "contextless" (sq: $T) -> u64 
    where intrinsics.type_is_numeric(T) {
    return 1 << uint(sq)
}

SqMasks :: struct {
    rank_mask: u64,
    file_mask: u64,
    diagonal_mask: u64,
    antidiag_mask: u64,
	king_zone: u64,
}

init_sq_masks :: proc "contextless" () -> (masks: [64]SqMasks) {
    for rank: uint = 0; rank < 8; rank += 1 {
        for file: uint = 0; file < 8; file += 1 {
            sq := 8*rank + file

            masks[sq].rank_mask = RANK_1 << (8*rank)
            masks[sq].file_mask = H_FILE << file

            if rank >= file {
                masks[sq].diagonal_mask = MAIN_DIAGONAL << ((rank - file) * 8)
            } else {
                masks[sq].diagonal_mask = MAIN_DIAGONAL >> ((file - rank) * 8)
            }

            if rank + file >= 7 {
                masks[sq].antidiag_mask = MAIN_ANTIDIAG << ((rank + file - 7) * 8)
            } else {
                masks[sq].antidiag_mask = MAIN_ANTIDIAG >> ((7 - rank - file) * 8)
            }

			for i: uint = 0; i <= 4; i += 1 {
				if rank + i - 2 < 0 || rank + i + 2 > 7do continue
				for j: uint = 0; j <= 4; j += 1 {
					if file + j - 2 < 0 || file + j + 2 > 7 do continue

					set_sq := 8 * (rank + i - 2) + file + j - 2
					masks[sq].king_zone |= to_bitboard(set_sq)
				}
			}
        }
    }
    return
}

lsb :: proc(bitboard: u64) -> int {
    return int(intrinsics.count_trailing_zeros(bitboard))
}

msb :: proc(bitboard: u64) -> int {
	return int(intrinsics.count_leading_zeros(bitboard))
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

manhatten_distance :: proc(sq1, sq2: $T) -> int
    where intrinsics.type_is_numeric(T) {
	return builtin.abs(sq1 % 8 - sq2 % 8) + builtin.abs(sq1 / 8 - sq2 / 8)
}

chebyshev_distance :: proc(sq1, sq2: $T) -> int
	where intrinsics.type_is_numberic(T) {
	d_rank := builtin.abs(sq1 % 8 - sq2 % 8)
	d_file := builtin.abs(sq1 / 8 - sq2 / 8)
	return builtin.max(d_rank, d_file)
}
