package blunderbuss

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
OPEN_FILE_PENALTY :: 100

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

ZONE_ATTACK_UNITS: [PieceType]int = {
	.Pawn = 0,
	.Knight = 2,
	.Bishop = 2,
	.Rook = 3,
	.Queen = 5,
	.King = 0,
}

// quadratic weight
ZONE_ATTACK_WEIGHT: [40]int = {
	0, 0, 1, 4, 9, 16, 25, 36, 49, 64, 81,
	100, 121, 144, 169, 196, 225, 256, 289, 324, 361,
	400, 441, 484, 529, 576, 625, 676, 729, 784, 841,
	900, 961, 1024, 1089, 1156, 1225, 1296, 1369, 1444
}

wdl :: proc(eval: int, phase: int) -> f64 {
	scale := 400 * (24 - phase)/24
	return 1 / (1 + math.pow(10, -f64(eval/400)))
}

evaluate :: proc(position: ^Position) -> int {
	mg: [Colour]int
	eg: [Colour]int
	us := position.turn
	them := toggle(us)
	occ := occupied(position)
	phase := 0

	for us in Colour {
		them := toggle(us)
		enemy_pawns := position.pieces[them][.Pawn]
		pawn_controlled := pawn_attacks(them, enemy_pawns)
		bishop_pair: bit_set[Colour]

		king_sq_them := lsb(position.pieces[them][.King])
		king_zone := get_king_zone(king_sq_them, them)
		zone_attack_units, zone_attack_density: int

		for bb, piece in position.pieces[us] {
			from_bb := bb
			for from_bb > 0 {
				from := pop_lsb(&from_bb)

				// count material
				lookup_sq := from
				if us == .White {
					lookup_sq ~= 56 // PSQT defined from black perspective
				}

				mg[us] += piece_value[piece] + mg_piece_sq_tbl[piece][lookup_sq]
				eg[us] += piece_value[piece] + eg_piece_sq_tbl[piece][lookup_sq]
				phase += piece_phase[piece]

				to_bb: u64
				switch piece {
				case .Pawn:
					continue
				case .Knight:
					to_bb = KNIGHT_TABLE[from]
				case .Bishop:
					to_bb = magic_bishop_moves(from, occ)
					bishop_pair += {square_colour(from)}
				case .Rook:
					to_bb = magic_rook_moves(from, occ)
				case .Queen:
					to_bb = magic_queen_moves(from, occ)
				case .King:
					to_bb = KING_TABLE[from]
				}

				zone_attacks := to_bb & king_zone
				if zone_attacks != 0 && piece != .King {
					zone_attack_units += ZONE_ATTACK_UNITS[piece]
					zone_attack_density += pop_count(zone_attacks)
				}

				// count mobility
				to_bb &~= position.occupancy[us] | pawn_controlled
				mobility := pop_count(to_bb)

				mg[us] += MG_MOBILITY_WEIGHT[piece] * mobility
				eg[us] += EG_MOBILITY_WEIGHT[piece] * mobility
			}
		}

		if bishop_pair == {.White, .Black} {
			mg[us] += MG_BISHOP_PAIR_WEIGHT
			eg[us] += EG_BISHOP_PAIR_WEIGHT
		}

		eval_pawn_structure(position, us, &mg, &eg)

		// king danger from perspective of "us" attack strength
		zone_attack_units = min(zone_attack_units, len(ZONE_ATTACK_WEIGHT - 1))
		king_danger := ZONE_ATTACK_WEIGHT[zone_attack_units]
		king_danger *= zone_attack_density / 5
		mg[us] += king_danger
	}

	// in case of promotion
	if phase > 24 {
		phase = 24
	}

	mg_eval := mg[us] - mg[them]
	eg_eval := eg[us] - eg[them]

	return (mg_eval * phase + eg_eval * (24 - phase)) / 24
}

get_king_zone :: proc(king_sq: int, side: Colour) -> u64 {
	zone := KING_TABLE[king_sq]
	zone |= zone << 16 if side == .White else zone >> 16
	return zone
}

eval_pawn_structure :: proc(position: ^Position, us: Colour, mg, eg: ^[Colour]int) {
	them := toggle(us)
	pawns_us := position.pieces[us][.Pawn]
	pawns_them := position.pieces[them][.Pawn]
	file_count: [8]int
	is_isolated: [8]bool

	for pawn_iter := pawns_us; pawn_iter > 0; {
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
			mg[us] += pushed_distance * MG_PASSED_PAWN_WEIGHT
			eg[us] += pushed_distance * EG_PASSED_PAWN_WEIGHT
		}

		if behind_mask & pawns_us == 0 && sentry_mask & pawns_them != 0 {
			mg[us] -= MG_BACKWARD_PAWN_PENALTY
			eg[us] -= EG_BACKWARD_PAWN_PENALTY
		}
	}

	for file in 0..<8 {
		if is_isolated[file] {
			mg[us] -= MG_ISOLATED_PAWN_PENALTY
			eg[us] -= EG_ISOLATED_PAWN_PENALTY
		}

		count := file_count[file]
		if count <= 1 do continue

		mg[us] -= (count - 1) * MG_DOUBLED_PAWN_WEIGHT
		eg[us] -= (count - 1) * EG_DOUBLED_PAWN_WEIGHT
		if count >= 3 {
			mg[us] -= MG_TRIPLED_PAWN_PENALTY
			eg[us] -= EG_TRIPLED_PAWN_PENALTY
		}
	}
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
