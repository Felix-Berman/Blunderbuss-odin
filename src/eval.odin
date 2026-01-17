package blunderbuss

import "base:intrinsics"
import "core:math"

piece_value: [PieceType]int = {
	.Pawn = 100,
	.Knight = 300,
	.Bishop = 350,
	.Rook = 500,
	.Queen = 900,
	.King = 30_000
}

piece_phase: [PieceType]int = {
	.Pawn = 0,
	.Knight = 1,
	.Bishop = 1,
	.Rook = 2,
	.Queen = 4,
	.King = 0,
}

MG_DOUBLED_PAWN_WEIGHT :: 30
EG_DOUBLED_PAWN_WEIGHT :: 70
MG_TRIPLED_PAWN_PENALTY :: 10
EG_TRIPLED_PAWN_PENALTY :: 50
MG_ISOLATED_PAWN_PENALTY :: 15
EG_ISOLATED_PAWN_PENALTY :: 30
MG_PASSED_PAWN_WEIGHT :: 10
EG_PASSED_PAWN_WEIGHT :: 20
MG_BACKWARD_PAWN_PENALTY :: 5
EG_BACKWARD_PAWN_PENALTY :: 10
MG_BISHOP_PAIR_WEIGHT :: 10
EG_BISHOP_PAIR_WEIGHT :: 50

MG_MOBILITY_WEIGHT: [PieceType]int = {
	.Pawn = 0,
	.Knight = 4,
	.Bishop = 3,
	.Rook = 2,
	.Queen = 1,
	.King = 0,
}

EG_MOBILITY_WEIGHT: [PieceType]int = {
	.Pawn = 0,
	.Knight = 4,
	.Bishop = 4,
	.Rook = 4,
	.Queen = 2,
	.King = 5,
}

wdl :: proc(eval: int, phase: int) -> f64 {
	scale := 400 * (24 - phase)/24
	return 1 / (1 + math.pow(10, -f64(eval/400)))
}


evaluate :: proc(position: ^Position) -> (int, int) {
	mg_material: [Colour]int
	eg_material: [Colour]int
	us := position.turn
	them := toggle(us)
	phase := 0

	bishop_count: [Colour]int

	for bbs, side in position.pieces {
		for bb, piece in bbs {
			bb := bb
			for bb > 0 {
				sq := pop_lsb(&bb)
				if side == .White {
					sq ~= 56
				}

				mg_material[side] += piece_value[piece] + mg_piece_sq_tbl[piece][sq]
				eg_material[side] += piece_value[piece] + eg_piece_sq_tbl[piece][sq]
				phase += piece_phase[piece]

				if piece == .Bishop {
					bishop_count[side] += 1
				}
			}
		}
	}

	// in case of promotion
	if phase > 24 {
		phase = 24
	}

	mg_eval := mg_material[us] - mg_material[them]
	eg_eval := eg_material[us] - eg_material[them]

	pawns_us := position.pieces[us][.Pawn]
	pawns_them := position.pieces[them][.Pawn]
	mg_pawn_us, eg_pawn_us := pawn_structure(us, pawns_us, pawns_them)
	mg_pawn_them, eg_pawn_them := pawn_structure(them, pawns_them, pawns_us)

	mg_eval += mg_pawn_us - mg_pawn_them
	eg_eval += eg_pawn_us - eg_pawn_them

	if bishop_count[us] >= 2 {
		mg_eval += MG_BISHOP_PAIR_WEIGHT
		eg_eval += EG_BISHOP_PAIR_WEIGHT
	}
	if bishop_count[them] >= 2 {
		mg_eval -= MG_BISHOP_PAIR_WEIGHT
		eg_eval -= EG_BISHOP_PAIR_WEIGHT
	}

	mg_mobility_us, eg_mobility_us := mobility(position, us)
	mg_mobility_them, eg_mobility_them := mobility(position, them)
	mg_eval += mg_mobility_us - mg_mobility_them
	eg_eval += eg_mobility_us - eg_mobility_them

	return (mg_eval * phase + eg_eval * (24 - phase)) / 24, phase
}

mobility :: proc(position: ^Position, us: Colour) -> (mg, eg: int) {
	them := toggle(us)
	occ := occupied(position)

	enemy_pawns := position.pieces[them][.Pawn]
	pawn_controlled := pawn_attacks(them, enemy_pawns)

	for bb, piece in position.pieces[us] {
		from_bb := bb

		for from_bb > 0 {
			from := pop_lsb(&from_bb)

			to_bb: u64
			switch piece {
			case .Pawn:
				continue
			case .Knight:
				to_bb = KNIGHT_TABLE[from]
			case .Bishop:
				to_bb = magic_bishop_moves(from, occ)
			case .Rook:
				to_bb = magic_rook_moves(from, occ)
			case .Queen:
				to_bb = magic_queen_moves(from, occ)
			case .King:
				to_bb = KING_TABLE[from]
			}

			to_bb &~= position.occupancy[us] | pawn_controlled
			mobility := int(intrinsics.count_ones(to_bb))

			mg += MG_MOBILITY_WEIGHT[piece] * mobility
			eg += EG_MOBILITY_WEIGHT[piece] * mobility
		}

	}

	return
}

pawn_structure :: proc(us: Colour, pawns_us, pawns_them: u64) -> (mg, eg: int) {
	them := toggle(us)
	pawn_iter := pawns_us
	file_count: [8]int
	is_isolated: [8]bool

	for pawn_iter > 0 {
		sq := pop_lsb(&pawn_iter)

		rank_idx := sq / 8
		file_idx := sq % 8
		file_count[file_idx] += 1
		
		file := SQ_MASKS[sq].file
		file_left := (file << 1) &~ H_FILE
		file_right := (file >> 1) &~ A_FILE

		ahead_mask := file | file_left | file_right
		behind_mask := file_left | file_right
		pushed_distance: int
		sentry_mask: u64
		if us == .White {
			ahead_mask <<= uint(8 * rank_idx + 8)
			behind_mask >>= uint(8 * (7 - rank_idx))
			pushed_distance = rank_idx
			sentry_mask = bitboard(sq + 17) | bitboard(sq + 15)
		} else {
			pushed_distance = 7 - rank_idx
			ahead_mask >>= uint(8 * pushed_distance + 8)
			behind_mask >>= uint(8 * rank_idx)
			sentry_mask = bitboard(sq - 17) | bitboard(sq - 15)
		}

		if (file_left | file_right) & pawns_us == 0 {
			is_isolated[file_idx] = true
		}

		if ahead_mask & pawns_them == 0 {
			mg += pushed_distance * MG_PASSED_PAWN_WEIGHT
			eg += pushed_distance * EG_PASSED_PAWN_WEIGHT
		}

		if behind_mask & pawns_us == 0 && sentry_mask & pawns_them != 0 {
			mg -= MG_BACKWARD_PAWN_PENALTY
			eg -= EG_BACKWARD_PAWN_PENALTY
		}
	}

	for file in 0..<8 {
		if is_isolated[file] {
			mg -= MG_ISOLATED_PAWN_PENALTY
			eg -= EG_ISOLATED_PAWN_PENALTY
		}

		count := file_count[file]
		if count <= 1 do continue

		mg -= (count - 1) * MG_DOUBLED_PAWN_WEIGHT
		eg -= (count - 1) * EG_DOUBLED_PAWN_WEIGHT
		if count >= 3 {
			mg -= MG_TRIPLED_PAWN_PENALTY
			eg -= EG_TRIPLED_PAWN_PENALTY
		}
	}

	return
}

mg_piece_sq_tbl: [PieceType][64]int = {
	.Pawn = mg_pawn_tbl,
	.Knight = mg_knight_tbl,
	.Bishop = mg_bishop_tbl,
	.Rook = mg_rook_tbl,
	.Queen = mg_queen_tbl,
	.King = mg_king_tbl,
}

eg_piece_sq_tbl: [PieceType][64]int = {
	.Pawn = eg_pawn_tbl,
	.Knight = eg_knight_tbl,
	.Bishop = eg_bishop_tbl,
	.Rook = eg_rook_tbl,
	.Queen = eg_queen_tbl,
	.King = eg_king_tbl,
}


mg_pawn_tbl: [64]int = {
	 0,  0,  0,  0,  0,  0,  0,  0,
	50, 50, 50, 50, 50, 50, 50, 50,
	10, 10, 20, 30, 30, 20, 10, 10,
	 5,  5, 10, 25, 25, 10,  5,  5,
	 0,  0,  0, 20, 20,  0,  0,  0,
	 5, -5,-10,  0,  0,-10, -5,  5,
	 5, 10, 10,-20,-20, 10, 10,  5,
	 0,  0,  0,  0,  0,  0,  0,  0,
}

eg_pawn_tbl: [64]int = {
	 0,  0,  0,  0,  0,  0,  0,  0,
	50, 50, 50, 50, 50, 50, 50, 50,
	10, 10, 20, 30, 30, 20, 10, 10,
	 5,  5, 10, 25, 25, 10,  5,  5,
	 0,  0,  0, 20, 20,  0,  0,  0,
	 5, -5,-10,  0,  0,-10, -5,  5,
	 5, 10, 10,-20,-20, 10, 10,  5,
	 0,  0,  0,  0,  0,  0,  0,  0,
}

mg_knight_tbl: [64]int = {
	-50,-40,-30,-30,-30,-30,-40,-50,
	-40,-20,  0,  0,  0,  0,-20,-40,
	-30,  0, 10, 15, 15, 10,  0,-30,
	-30,  5, 15, 20, 20, 15,  5,-30,
	-30,  0, 15, 20, 20, 15,  0,-30,
	-30,  5, 10, 15, 15, 10,  5,-30,
	-40,-20,  0,  5,  5,  0,-20,-40,
	-50,-40,-30,-30,-30,-30,-40,-50,
}

eg_knight_tbl: [64]int = {
	-50,-40,-30,-30,-30,-30,-40,-50,
	-40,-20,  0,  0,  0,  0,-20,-40,
	-30,  0, 10, 15, 15, 10,  0,-30,
	-30,  5, 15, 20, 20, 15,  5,-30,
	-30,  0, 15, 20, 20, 15,  0,-30,
	-30,  5, 10, 15, 15, 10,  5,-30,
	-40,-20,  0,  5,  5,  0,-20,-40,
	-50,-40,-30,-30,-30,-30,-40,-50,
}

mg_bishop_tbl: [64]int = {
	-20,-10,-10,-10,-10,-10,-10,-20,
	-10,  0,  0,  0,  0,  0,  0,-10,
	-10,  0,  5, 10, 10,  5,  0,-10,
	-10,  5,  5, 10, 10,  5,  5,-10,
	-10,  0, 10, 10, 10, 10,  0,-10,
	-10, 10, 10, 10, 10, 10, 10,-10,
	-10,  5,  0,  0,  0,  0,  5,-10,
	-20,-10,-10,-10,-10,-10,-10,-20,
}

eg_bishop_tbl: [64]int = {
	-20,-10,-10,-10,-10,-10,-10,-20,
	-10,  0,  0,  0,  0,  0,  0,-10,
	-10,  0,  5, 10, 10,  5,  0,-10,
	-10,  5,  5, 10, 10,  5,  5,-10,
	-10,  0, 10, 10, 10, 10,  0,-10,
	-10, 10, 10, 10, 10, 10, 10,-10,
	-10,  5,  0,  0,  0,  0,  5,-10,
	-20,-10,-10,-10,-10,-10,-10,-20,
}

mg_rook_tbl: [64]int = {
	  0,  0,  0,  0,  0,  0,  0,  0,
	  5, 10, 10, 10, 10, 10, 10,  5,
	 -5,  0,  0,  0,  0,  0,  0, -5,
	 -5,  0,  0,  0,  0,  0,  0, -5,
	 -5,  0,  0,  0,  0,  0,  0, -5,
	 -5,  0,  0,  0,  0,  0,  0, -5,
	 -5,  0,  0,  0,  0,  0,  0, -5,
	  0,  0,  0,  5,  5,  0,  0,  0
}

eg_rook_tbl: [64]int = {
	  0,  0,  0,  0,  0,  0,  0,  0,
	  5, 10, 10, 10, 10, 10, 10,  5,
	 -5,  0,  0,  0,  0,  0,  0, -5,
	 -5,  0,  0,  0,  0,  0,  0, -5,
	 -5,  0,  0,  0,  0,  0,  0, -5,
	 -5,  0,  0,  0,  0,  0,  0, -5,
	 -5,  0,  0,  0,  0,  0,  0, -5,
	  0,  0,  0,  5,  5,  0,  0,  0
}

mg_queen_tbl: [64]int = {
	-20,-10,-10, -5, -5,-10,-10,-20,
	-10,  0,  0,  0,  0,  0,  0,-10,
	-10,  0,  5,  5,  5,  5,  0,-10,
	 -5,  0,  5,  5,  5,  5,  0, -5,
	  0,  0,  5,  5,  5,  5,  0, -5,
	-10,  5,  5,  5,  5,  5,  0,-10,
	-10,  0,  5,  0,  0,  0,  0,-10,
	-20,-10,-10, -5, -5,-10,-10,-20
}

eg_queen_tbl: [64]int = {
	-20,-10,-10, -5, -5,-10,-10,-20,
	-10,  0,  0,  0,  0,  0,  0,-10,
	-10,  0,  5,  5,  5,  5,  0,-10,
	 -5,  0,  5,  5,  5,  5,  0, -5,
	  0,  0,  5,  5,  5,  5,  0, -5,
	-10,  5,  5,  5,  5,  5,  0,-10,
	-10,  0,  5,  0,  0,  0,  0,-10,
	-20,-10,-10, -5, -5,-10,-10,-20
}

mg_king_tbl: [64]int = {
	-30,-40,-40,-50,-50,-40,-40,-30,
	-30,-40,-40,-50,-50,-40,-40,-30,
	-30,-40,-40,-50,-50,-40,-40,-30,
	-30,-40,-40,-50,-50,-40,-40,-30,
	-20,-30,-30,-40,-40,-30,-30,-20,
	-10,-20,-20,-20,-20,-20,-20,-10,
	 20, 20,  0,  0,  0,  0, 20, 20,
	 20, 30, 10,  0,  0, 10, 30, 20
}

eg_king_tbl: [64]int = {
	-50,-40,-30,-30,-30,-30,-40,-50,
	-40,-20,  0,  0,  0,  0,-20,-40,
	-30,  0, 10, 15, 15, 10,  0,-30,
	-30,  5, 15, 20, 20, 15,  5,-30,
	-30,  0, 15, 20, 20, 15,  0,-30,
	-30,  5, 10, 15, 15, 10,  5,-30,
	-40,-20,  0,  5,  5,  0,-20,-40,
	-50,-40,-30,-30,-30,-30,-40,-50,
}
