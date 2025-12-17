package blunderbuss

import "base:builtin"

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

TOTAL_PHASE :: 24
SCALED_PHASE :: 256
MG_THRESHOLD :: 128

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

KNIGHT_TROPISM_D :: 4
BISHOP_TROPISM_D :: 6
ROOK_TROPISM_D :: 7
QUEEN_TROPISM_D :: 8
KNIGHT_TROPISM_W :: 2
BISHOP_TROPISM_W :: 2
ROOK_TROPISM_W :: 3
QUEEN_TROPISM_W :: 5

ZONE_ATTACK_WEIGHT: [7]int = {0, 50, 75, 88, 94, 97, 99}

ZONE_WEIGHT_QUEEN :: 80
ZONE_WEIGHT_ROOK :: 40
ZONE_WEIGHT_BISHOP :: 20
ZONE_WEIGHT_KNIGHT :: 20

EXPOSURE_WEIGHT :: 2
SHIELD_WEIGHT :: 2
DANGER_WEIGHT_DIVISOR :: 8

eval :: proc(position: ^Position) -> int {
	mg_material: [Colour]int
	eg_material: [Colour]int
	mg_pawn: [Colour]int
	eg_pawn: [Colour]int
	king_danger: [Colour]int
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
	if phase > TOTAL_PHASE {
		phase = TOTAL_PHASE
	}

	// rescale the game phase for finer resolution
	phase = (phase * SCALED_PHASE + (TOTAL_PHASE / 2)) / TOTAL_PHASE

	// compare material
	mg_eval := mg_material[us] - mg_material[them]
	eg_eval := eg_material[us] - eg_material[them]

	for us in Colour {
		them := toggle(us)

		// compare pawn structure considering passed, isolated, doubled and
		// backwards pawns
		pawns_us := position.pieces[us][.Pawn]
		pawns_them := position.pieces[them][.Pawn]
		mg, eg := pawn_structure(us, pawns_us, pawns_them)
		mg_pawn[us] += mg
		eg_pawn[us] += eg

		king_sq := lsb(position.pieces[us][.King])
		knight_bb := position.pieces[them][.Knight]
		bishop_bb := position.pieces[them][.Bishop]
		rook_bb := position.pieces[them][.Rook]
		queen_bb := position.pieces[them][.Queen]

		// we likely aren't in danger if theres no queen
		if queen_bb == 0 || phase < MG_THRESHOLD {
			continue
		}

		king_danger[us] += tropism(king_sq, knight_bb, KNIGHT_TROPISM_D, KNIGHT_TROPISM_W)
		king_danger[us] += tropism(king_sq, bishop_bb, BISHOP_TROPISM_D, BISHOP_TROPISM_W)
		king_danger[us] += tropism(king_sq, rook_bb, ROOK_TROPISM_D, ROOK_TROPISM_W)
		king_danger[us] += tropism(king_sq, queen_bb, QUEEN_TROPISM_D, QUEEN_TROPISM_W)

		// piece attacks one squares that can be reached by king in 2 moves
		// weighted on piece value and number of attackers
		king_danger[us] += king_zone_attacks(them, position, king_sq)

		// queen mobility from king_sq reveals exposed lines of attacks
		exposure_bb := queen_moves(king_sq, pawns_us | pawns_them)
		king_danger[us] += count_bits(exposure_bb) * EXPOSURE_WEIGHT

		// pawn shielding
		shield: int

		king_file := SQ_MASKS[king_sq].file_mask
		left_file := (king_file << 1) &~ H_FILE
		right_file := (king_file >> 1) &~ A_FILE
		files: [3]u64 = {king_file, left_file, right_file}
		
		for file in files {
			protectors := file & pawns_us
			if protectors == 0 {
				shield -= 4
			} else {
				pawn_sq := lsb(protectors) if us == .White else msb(protectors)
				pushed := 3 - pawn_sq / 8
				shield += builtin.max(pushed, 0)
			}

			// semi-open or open_file for opponent
			if pawns_them & file == 0 {
				shield -= 2
			}
		}

		// shielding mitigates danger. prevent passivity by clamping at 0
		king_danger[us] -= shield * SHIELD_WEIGHT
		if king_danger[us] < 0 {
			king_danger[us] = 0
		}

		// Danger to king scales nonlinearly
		king_danger[us] = king_danger[us] * king_danger[us] / DANGER_WEIGHT_DIVISOR
	}

	mg_eval += mg_pawn[us] - mg_pawn[them]
	eg_eval += eg_pawn[us] - eg_pawn[them]

	// the side with tempo is under less (inflicting more) danger
	mg_eval += king_danger[them] * 105/100 - king_danger[us]

	if bishop_count[us] >= 2 {
		mg_eval += MG_BISHOP_PAIR_WEIGHT
		eg_eval += EG_BISHOP_PAIR_WEIGHT
	}
	if bishop_count[them] >= 2 {
		mg_eval -= MG_BISHOP_PAIR_WEIGHT
		eg_eval -= EG_BISHOP_PAIR_WEIGHT
	}

	return (mg_eval * phase + eg_eval * (SCALED_PHASE - phase)) / SCALED_PHASE
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
		
		file := SQ_MASKS[sq].file_mask
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
			sentry_mask = to_bitboard(sq + 17) | to_bitboard(sq + 15)
		} else {
			pushed_distance = 7 - rank_idx
			ahead_mask >>= uint(8 * pushed_distance + 8)
			behind_mask >>= uint(8 * rank_idx)
			sentry_mask = to_bitboard(sq - 17) | to_bitboard(sq - 15)
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

// Tropism: simple metric of king safety that looks at distance between
// attackers and the king. doesn't consider any blocking pieces in between
tropism :: proc(king_sq: int, bb: u64, cutoff, weight: int) -> (tropism: int) {
	bb := bb

	for bb > 0 {
		sq := pop_lsb(&bb)
		d := manhatten_distance(king_sq, sq)
		
		if d <= cutoff {
			tropism += weight * (cutoff - d)
		}
	}
	
	return
}

king_zone_attacks :: proc(
	them: Colour,
	position: ^Position,
	king_sq: int
) -> (attack_val: int) {
	king_zone := SQ_MASKS[king_sq].king_zone
	piece_bitboard := position.pieces[them]
	occ := occupied(position)
	attackers_in_zone: int

	for &bb, piece in piece_bitboard {
		move_proc: proc(sq: int, occ: u64) -> u64
		piece_weight: int

		switch piece {
			case .Pawn:
				continue
			case .Knight:
				move_proc = knight_moves_sq
				piece_weight = ZONE_WEIGHT_KNIGHT
			case .Bishop:
				move_proc = bishop_moves
				piece_weight = ZONE_WEIGHT_BISHOP
			case .Rook:
				move_proc = rook_moves
				piece_weight = ZONE_WEIGHT_ROOK
			case .Queen:
				move_proc = queen_moves
				piece_weight = ZONE_WEIGHT_QUEEN
			case .King:
				continue
		}

		for bb > 0 {
			from := pop_lsb(&bb)
			to := move_proc(from, occ)
			zone_attacks := to & king_zone

			if zone_attacks != 0 {
				attackers_in_zone += 1
				attack_val += count_bits(zone_attacks) * piece_weight
			}
		}
	}

	if attackers_in_zone > 0 {
		attackers_in_zone = builtin.max(attackers_in_zone, len(ZONE_ATTACK_WEIGHT))
		attack_val *= ZONE_ATTACK_WEIGHT[attackers_in_zone - 1] / 100
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
