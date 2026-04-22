package blunderbuss

import "core:math"
import "core:testing"
import "core:log"
import "core:fmt"

TRACING :: #config(TRACING, false)

Trace :: struct {
	turn: Colour,
	phase: int,
	pieces: [64]Piece,
	isolated_pawns: [Colour]int,
	backward_pawns: [Colour]int,
	connected_pawns: [Colour]int,
	doubled_pawns: [Colour][8]int,
	isolated_doubled: [Colour]int,
	passed_pawns: [Colour][8]int,
	connected_passed: [Colour][8]int,
	bishop_pair: [Colour]bool,
	rook_open: [Colour]int,
	rook_semi_open: [Colour]int,
	knight_mobility: [Colour][len(KNIGHT_MOBILITY)]int,
	bishop_mobility: [Colour][len(BISHOP_MOBILITY)]int,
	rook_mobility: [Colour][len(ROOK_MOBILITY)]int,
	queen_mobility: [Colour][len(QUEEN_MOBILITY)]int,
	attack_units: [Colour]int,
	zone_attack_density: [Colour]int,
}

when TRACING {
	trace: Trace
}

Score :: distinct i32 // packed data: upper 16 bits = eg, lower 16 bits = mg

S :: #force_inline proc "contextless" (mg, eg: i16) -> Score {
	return Score(i32(eg) << 16 + i32(mg))
}

score_mg :: #force_inline proc(s: Score) -> i16 {
	return i16(s)
}

// negative middlegame values borrow LSB from endgame value.
// Adding 0x8000 to mg value with leading 1 (negative) carries to the endgame
// value restoring it from the borrow
score_eg :: #force_inline proc(s: Score) -> i16 {
	return i16((s + 0x8000) >> 16)
}

pawn_tbl: [64]Score = {
	S(  0,  0), S(  0,  0), S(  0,  0), S(  0,  0), S(  0,  0), S(  0,  0), S(  0,  0), S(  0,  0),
	S( 50, 50), S( 50, 50), S( 50, 50), S( 50, 50), S( 50, 50), S( 50, 50), S( 50, 50), S( 50, 50),
	S( 10, 10), S( 10, 10), S( 20, 20), S( 30, 30), S( 30, 30), S( 20, 20), S( 10, 10), S( 10, 10),
	S(  5,  5), S(  5,  5), S( 10, 10), S( 25, 25), S( 25, 25), S( 10, 10), S(  5,  5), S(  5,  5),
	S(  0,  0), S(  0,  0), S(  0,  0), S( 20, 20), S( 20, 20), S(  0,  0), S(  0,  0), S(  0,  0),
	S(  5,  5), S( -5, -5), S(-10,-10), S(  0,  0), S(  0,  0), S(-10,-10), S( -5, -5), S(  5,  5),
	S(  5,  5), S( 10, 10), S( 10, 10), S(-20,-20), S(-20,-20), S( 10, 10), S( 10, 10), S(  5,  5),
	S(  0,  0), S(  0,  0), S(  0,  0), S(  0,  0), S(  0,  0), S(  0,  0), S(  0,  0), S(  0,  0),
}

knight_tbl: [64]Score = {
	S(-50,-50), S(-40,-40), S(-30,-30), S(-30,-30), S(-30,-30), S(-30,-30), S(-40,-40), S(-50,-50),
	S(-40,-40), S(-20,-20), S(  0,  0), S(  0,  0), S(  0,  0), S(  0,  0), S(-20,-20), S(-40,-40),
	S(-30,-30), S(  0,  0), S( 10, 10), S( 15, 15), S( 15, 15), S( 10, 10), S(  0,  0), S(-30,-30),
	S(-30,-30), S(  5,  5), S( 15, 15), S( 20, 20), S( 20, 20), S( 15, 15), S(  5,  5), S(-30,-30),
	S(-30,-30), S(  0,  0), S( 15, 15), S( 20, 20), S( 20, 20), S( 15, 15), S(  0,  0), S(-30,-30),
	S(-30,-30), S(  5,  5), S( 10, 10), S( 15, 15), S( 15, 15), S( 10, 10), S(  5,  5), S(-30,-30),
	S(-40,-40), S(-20,-20), S(  0,  0), S(  5,  5), S(  5,  5), S(  0,  0), S(-20,-20), S(-40,-40),
	S(-50,-50), S(-40,-40), S(-30,-30), S(-30,-30), S(-30,-30), S(-30,-30), S(-40,-40), S(-50,-50),
}

bishop_tbl: [64]Score = {
	S(-20,-20), S(-10,-10), S(-10,-10), S(-10,-10), S(-10,-10), S(-10,-10), S(-10,-10), S(-20,-20),
	S(-10,-10), S(  0,  0), S(  0,  0), S(  0,  0), S(  0,  0), S(  0,  0), S(  0,  0), S(-10,-10),
	S(-10,-10), S(  0,  0), S(  5,  5), S( 10, 10), S( 10, 10), S(  5,  5), S(  0,  0), S(-10,-10),
	S(-10,-10), S(  5,  5), S(  5,  5), S( 10, 10), S( 10, 10), S(  5,  5), S(  5,  5), S(-10,-10),
	S(-10,-10), S(  0,  0), S( 10, 10), S( 10, 10), S( 10, 10), S( 10, 10), S(  0,  0), S(-10,-10),
	S(-10,-10), S( 10, 10), S( 10, 10), S( 10, 10), S( 10, 10), S( 10, 10), S( 10, 10), S(-10,-10),
	S(-10,-10), S(  5,  5), S(  0,  0), S(  0,  0), S(  0,  0), S(  0,  0), S(  5,  5), S(-10,-10),
	S(-20,-20), S(-10,-10), S(-10,-10), S(-10,-10), S(-10,-10), S(-10,-10), S(-10,-10), S(-20,-20),
}

rook_tbl: [64]Score = {
	S(  0,  0), S(  0,  0), S(  0,  0), S(  0,  0), S(  0,  0), S(  0,  0), S(  0,  0), S(  0,  0),
	S(  5,  5), S( 10, 10), S( 10, 10), S( 10, 10), S( 10, 10), S( 10, 10), S( 10, 10), S(  5,  5),
	S( -5, -5), S(  0,  0), S(  0,  0), S(  0,  0), S(  0,  0), S(  0,  0), S(  0,  0), S( -5, -5),
	S( -5, -5), S(  0,  0), S(  0,  0), S(  0,  0), S(  0,  0), S(  0,  0), S(  0,  0), S( -5, -5),
	S( -5, -5), S(  0,  0), S(  0,  0), S(  0,  0), S(  0,  0), S(  0,  0), S(  0,  0), S( -5, -5),
	S( -5, -5), S(  0,  0), S(  0,  0), S(  0,  0), S(  0,  0), S(  0,  0), S(  0,  0), S( -5, -5),
	S( -5, -5), S(  0,  0), S(  0,  0), S(  0,  0), S(  0,  0), S(  0,  0), S(  0,  0), S( -5, -5),
	S(  0,  0), S(  0,  0), S(  0,  0), S(  5,  5), S(  5,  5), S(  0,  0), S(  0,  0), S(  0,  0),
}

queen_tbl: [64]Score = {
	S(-20,-20), S(-10,-10), S(-10,-10), S( -5, -5), S( -5, -5), S(-10,-10), S(-10,-10), S(-20,-20),
	S(-10,-10), S(  0,  0), S(  0,  0), S(  0,  0), S(  0,  0), S(  0,  0), S(  0,  0), S(-10,-10),
	S(-10,-10), S(  0,  0), S(  5,  5), S(  5,  5), S(  5,  5), S(  5,  5), S(  0,  0), S(-10,-10),
	S( -5, -5), S(  0,  0), S(  5,  5), S(  5,  5), S(  5,  5), S(  5,  5), S(  0,  0), S( -5, -5),
	S(  0,  0), S(  0,  0), S(  5,  5), S(  5,  5), S(  5,  5), S(  5,  5), S(  0,  0), S( -5, -5),
	S(-10,-10), S(  5,  5), S(  5,  5), S(  5,  5), S(  5,  5), S(  5,  5), S(  0,  0), S(-10,-10),
	S(-10,-10), S(  0,  0), S(  5,  5), S(  0,  0), S(  0,  0), S(  0,  0), S(  0,  0), S(-10,-10),
	S(-20,-20), S(-10,-10), S(-10,-10), S( -5, -5), S( -5, -5), S(-10,-10), S(-10,-10), S(-20,-20),
}

king_tbl: [64]Score = {
	S(-30,-50), S(-40,-40), S(-40,-30), S(-50,-30), S(-50,-30), S(-40,-30), S(-40,-40), S(-30,-50),
	S(-30,-40), S(-40,-20), S(-40,  0), S(-50,  0), S(-50,  0), S(-40,  0), S(-40,-20), S(-30,-40),
	S(-30,-30), S(-40,  0), S(-40, 10), S(-50, 15), S(-50, 15), S(-40, 10), S(-40,  0), S(-30,-30),
	S(-30,-30), S(-40,  5), S(-40, 15), S(-50, 20), S(-50, 20), S(-40, 15), S(-40,  5), S(-30,-30),
	S(-20,-30), S(-30,  0), S(-30, 15), S(-40, 20), S(-40, 20), S(-30, 15), S(-30,  0), S(-20,-30),
	S(-10,-30), S(-20,  5), S(-20, 10), S(-20, 15), S(-20, 15), S(-20, 10), S(-20,  5), S(-10,-30),
	S( 20,-40), S( 20,-20), S(  0,  0), S(  0,  5), S(  0,  5), S(  0,  0), S( 20,-20), S( 20,-40),
	S( 20,-50), S( 30,-40), S( 10,-30), S(  0,-30), S(  0,-30), S( 10,-30), S( 30,-40), S( 20,-50),
}

piece_sq_tbl: [PieceType][64]Score = {
	.Pawn   = pawn_tbl,
	.Knight = knight_tbl,
	.Bishop = bishop_tbl,
	.Rook   = rook_tbl,
	.Queen  = queen_tbl,
	.King   = king_tbl,
}

piece_score: [PieceType]Score = {
	.Pawn = S(100, 100),
	.Knight = S(300, 300),
	.Bishop = S(350, 350),
	.Rook = S(500, 500),
	.Queen = S(900, 900),
	.King = S(0, 0),
}

piece_phase: [PieceType]int = {
	.Pawn = 0,
	.Knight = 1,
	.Bishop = 1,
	.Rook = 2,
	.Queen = 4,
	.King = 0,
}

DOUBLED_PAWN_PENALTY: [5]Score = { 0, 0, S(15, 30), S(35, 70), S(60, 120) }
ISOLATED_PAWN_PENALTY := S(15, 30)
ISOLATED_DOUBLED_PENALTY := S(10, 20)
BACKWARD_PAWN_PENALTY := S(5, 10)
CONNECTED_PAWN := S(5, 10)

PASSED_PAWN := [8]Score{
	S(0, 0), S(2, 4), S(7, 11), S(14, 23),
	S(26, 44), S(45, 80), S(75, 143), S(0, 0)
}
CONNECTED_PASSED_PAWN := [8]Score{
	S(0, 0), S(0, 1), S(1, 2), S(3, 5),
	S(6, 11), S(11, 20), S(18, 35), S(0, 0)
}

BISHOP_PAIR_WEIGHT := S(10, 50)
ROOK_OPEN_FILE := S(20, 0)
ROOK_SEMI_OPEN_FILE := S(10, 0)
TEMPO_BONUS := S(10, 10)

// logarithmic weights
KNIGHT_MOBILITY := [9]Score{
     S(-15,-12), S( -1,  0), S(  6,  7), S( 12, 12), S( 17, 16),
     S( 20, 20), S( 23, 23), S( 26, 25), S( 28, 27),
}

BISHOP_MOBILITY := [14]Score{
     S(-20,-16), S( -2,  0), S(  7,  8), S( 14, 14), S( 20, 19),
     S( 24, 23), S( 28, 26), S( 31, 29), S( 34, 32), S( 37, 34),
     S( 39, 36), S( 42, 38), S( 44, 40), S( 45, 42),
}

ROOK_MOBILITY := [15]Score{
     S(-25,-30), S(  2,  8), S( 18, 30), S( 30, 46), S( 39, 58),
     S( 46, 68), S( 52, 77), S( 58, 84), S( 62, 90), S( 67, 96),
     S( 70,101), S( 74,106), S( 77,111), S( 80,115), S( 83,118),
}

QUEEN_MOBILITY := [28]Score{
     S(-15,-12), S(  5, 12), S( 17, 26), S( 26, 36), S( 33, 44),
     S( 38, 50), S( 43, 56), S( 47, 60), S( 50, 64), S( 54, 68),
     S( 56, 71), S( 59, 74), S( 61, 77), S( 64, 80), S( 66, 82),
     S( 68, 85), S( 69, 87), S( 71, 89), S( 73, 91), S( 74, 92),
     S( 76, 94), S( 77, 96), S( 79, 97), S( 80, 99), S( 81,100),
     S( 82,102), S( 83,103), S( 84,104),
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
	return 1 / (1 + math.pow(10, -f64(eval)/400))
}

evaluate :: proc(position: ^Position) -> int {
	when TRACING {
		trace = Trace{}
		trace.turn = position.turn
	}

	scores: [Colour]Score
	us := position.turn
	them := toggle(us)
	occ := occupied(position)
	phase: int
	king_danger: [Colour]int

	for us in Colour {
		them := toggle(us)
		pawns_us := position.pieces[us][.Pawn]
		pawns_them := position.pieces[them][.Pawn]
		pawn_controlled := pawn_attacks(them, pawns_them)
		bishop_pair: bit_set[Colour]

		king_sq_them := lsb(position.pieces[them][.King])
		king_zone := get_king_zone(king_sq_them, them)
		zone_attack_units, zone_attack_density: int

		for bb, piece in position.pieces[us] {
			from_bb := bb
			for from_bb > 0 {
				from := pop_lsb(&from_bb)
				when TRACING do trace.pieces[from] = make_piece(us, piece)

				// count material
				lookup_sq := from
				if us == .White {
					lookup_sq ~= 56 // PSQT defined from black perspective
				}

				scores[us] += piece_score[piece] + piece_sq_tbl[piece][lookup_sq]
				phase += piece_phase[piece]

				to_bb: u64
				switch piece {
				case .Pawn:
					to_bb = pawn_attacks(us, bitboard(from))
				case .Knight:
					to_bb = KNIGHT_TABLE[from]
					mobility := pop_count(to_bb)
					scores[us] += KNIGHT_MOBILITY[mobility]
					when TRACING do trace.knight_mobility[us][mobility] += 1
				case .Bishop:
					to_bb = magic_bishop_moves(from, occ)
					mobility := pop_count(to_bb)
					scores[us] += BISHOP_MOBILITY[mobility]
					when TRACING do trace.bishop_mobility[us][mobility] += 1

					bishop_pair += {square_colour(from)}
				case .Rook:
					to_bb = magic_rook_moves(from, occ)
					mobility := pop_count(to_bb)
					scores[us] += ROOK_MOBILITY[mobility]
					when TRACING do trace.rook_mobility[us][mobility] += 1

					file := SQ_MASKS[from].file
					if pawns_us & file == 0 {
						if pawns_them & file == 0 {
							scores[us] += ROOK_OPEN_FILE
							when TRACING do trace.rook_open[us] += 1
						} else {
							scores[us] += ROOK_SEMI_OPEN_FILE
							when TRACING do trace.rook_semi_open[us] += 1
						}
					}
				case .Queen:
					to_bb = magic_queen_moves(from, occ)
					mobility := pop_count(to_bb)
					scores[us] += QUEEN_MOBILITY[mobility]
					when TRACING do trace.queen_mobility[us][mobility] += 1
				case .King:
					to_bb = KING_TABLE[from]
				}

				zone_attacks := to_bb & king_zone
				if zone_attacks != 0 && piece != .King {
					zone_attack_units += ZONE_ATTACK_UNITS[piece]
					zone_attack_density += pop_count(zone_attacks)
				}
			}
		}

		if bishop_pair == {.White, .Black} {
			scores[us] += BISHOP_PAIR_WEIGHT
			when TRACING do trace.bishop_pair[us] = true
		}

		scores[us] += eval_pawn_structure(position, us)

		// king danger from perspective of "us" attack strength
		zone_attack_units = min(zone_attack_units, len(ZONE_ATTACK_WEIGHT) - 1)
		zone_attackers := ZONE_ATTACK_WEIGHT[zone_attack_units]
		king_danger[us] += zone_attackers * zone_attack_density / 5

		when TRACING {
			trace.attack_units[us] = zone_attack_units
			trace.zone_attack_density[us] = zone_attack_density
		}
	}

	scores[us] += TEMPO_BONUS

	// phase clamping
	phase = min(phase, 24)
	phase = max(phase, 0)

	when TRACING {
		trace.phase = phase
	}

	eval := scores[us] - scores[them]
	mg_eval := int(score_mg(eval)) + king_danger[us] - king_danger[them]
	eg_eval := int(score_eg(eval))
	return (mg_eval * phase + eg_eval * (24 - phase)) / 24
}

get_king_zone :: proc(king_sq: int, side: Colour) -> u64 {
	zone := KING_TABLE[king_sq]
	zone |= zone << 16 if side == .White else zone >> 16
	return zone
}

eval_pawn_structure :: proc(position: ^Position, us: Colour) -> (score: Score) {
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
			sentry_mask = bitboard(sq + 17) &~ H_FILE
			sentry_mask |= bitboard(sq + 15) &~ A_FILE
		} else {
			pushed_distance = 7 - rank_idx
			ahead_mask >>= uint(8 * pushed_distance + 8)
			behind_mask <<= uint(8 * rank_idx)
			sentry_mask = bitboard(sq - 17) &~ A_FILE
			sentry_mask |= bitboard(sq - 15) &~ H_FILE
		}

		defenders := pawns_us & pawn_attacks(them, bitboard(sq))
		if defenders != 0 {
			score += CONNECTED_PAWN
			when TRACING do trace.connected_pawns[us] += 1
		}

		if (file_left | file_right) & pawns_us == 0 {
			is_isolated[file_idx] = true
		}

		if ahead_mask & pawns_them == 0 {
			score += PASSED_PAWN[pushed_distance]
			when TRACING do trace.passed_pawns[us][pushed_distance] += 1

			if defenders != 0 {
				score += CONNECTED_PASSED_PAWN[pushed_distance]
				when TRACING do trace.connected_passed[us][pushed_distance] += 1
			}
		}

		if behind_mask & pawns_us == 0 && sentry_mask & pawns_them != 0 {
			score -= BACKWARD_PAWN_PENALTY
			when TRACING do trace.backward_pawns[us] += 1
		}
	}

	for file in 0..<8 {
		count := file_count[file]
		score -= DOUBLED_PAWN_PENALTY[min(count, 4)]
		when TRACING do trace.doubled_pawns[us][file] = min(count, 4)

		if is_isolated[file] {
			score -= ISOLATED_PAWN_PENALTY
			when TRACING do trace.isolated_pawns[us] += 1

			if count > 1 {
				score -= ISOLATED_DOUBLED_PENALTY
				when TRACING do trace.isolated_doubled[us] += 1
			}
		}
	}

	return
}

evaluate_trace :: proc(t: Trace) -> int {
	scores: [Colour]Score
	us := t.turn
	them := toggle(us)

	for piece, sq in t.pieces {
		if piece == NIL_PIECE do continue
		
		scores[piece.colour] += piece_score[piece.type]
		scores[piece.colour] += piece_sq_tbl[piece.type][sq ~ 56]
	}

	for c in Colour {
		for n, i in t.knight_mobility[c] do scores[c] += Score(n) * KNIGHT_MOBILITY[i]
		for n, i in t.bishop_mobility[c] do scores[c] += Score(n) * BISHOP_MOBILITY[i]
		for n, i in t.rook_mobility[c]   do scores[c] += Score(n) * ROOK_MOBILITY[i]
		for n, i in t.queen_mobility[c]  do scores[c] += Score(n) * QUEEN_MOBILITY[i]

		scores[c] += Score(t.rook_open[c])      * ROOK_OPEN_FILE
		scores[c] += Score(t.rook_semi_open[c]) * ROOK_SEMI_OPEN_FILE
		if t.bishop_pair[c] do scores[c] += BISHOP_PAIR_WEIGHT

		scores[c] -= Score(t.isolated_pawns[c])   * ISOLATED_PAWN_PENALTY
		scores[c] -= Score(t.isolated_doubled[c]) * ISOLATED_DOUBLED_PENALTY
		scores[c] -= Score(t.backward_pawns[c])   * BACKWARD_PAWN_PENALTY
		scores[c] += Score(t.connected_pawns[c])  * CONNECTED_PAWN

		for rank in 0..<8 {
			scores[c] += Score(t.passed_pawns[c][rank])    * PASSED_PAWN[rank]
			scores[c] += Score(t.connected_passed[c][rank]) * CONNECTED_PASSED_PAWN[rank]
		}
		for file in 0..<8 {
			scores[c] -= DOUBLED_PAWN_PENALTY[t.doubled_pawns[c][file]]
		}
	}

	scores[us] += TEMPO_BONUS

	eval := scores[us] - scores[them]

	attack_us   := min(t.attack_units[us],   len(ZONE_ATTACK_WEIGHT) - 1)
	attack_them := min(t.attack_units[them],  len(ZONE_ATTACK_WEIGHT) - 1)
	king_danger_us   := ZONE_ATTACK_WEIGHT[attack_us]   * t.zone_attack_density[us]   / 5
	king_danger_them := ZONE_ATTACK_WEIGHT[attack_them] * t.zone_attack_density[them] / 5

	mg_eval := int(score_mg(eval)) + king_danger_us - king_danger_them
	eg_eval := int(score_eg(eval))

	return (mg_eval * t.phase + eg_eval * (24 - t.phase)) / 24
}

// Verifies the packed Score round-trip and that addition/subtraction of packed
// scores matches the same operations done independently on mg and eg.
@(test)
score_packing :: proc(t: ^testing.T) {
	cases := [][2]i16{
		{0, 0}, {1, 1}, {-1, -1},
		{100, 200}, {-100, 200}, {100, -200}, {-100, -200},
		{-1, 32767}, {32767, -1},
	}
	for c in cases {
		mg, eg := c[0], c[1]
		s := S(mg, eg)
		if !testing.expect_value(t, score_mg(s), mg) do return
		if !testing.expect_value(t, score_eg(s), eg) do return
	}

	// Arithmetic: packed add/subtract must match independent mg/eg operations.
	check :: proc(t: ^testing.T, a, b: Score) -> bool {
		sum := a + b
		if !testing.expect_value(t, score_mg(sum), score_mg(a) + score_mg(b)) do return false
		if !testing.expect_value(t, score_eg(sum), score_eg(a) + score_eg(b)) do return false
		diff := a - b
		if !testing.expect_value(t, score_mg(diff), score_mg(a) - score_mg(b)) do return false
		if !testing.expect_value(t, score_eg(diff), score_eg(a) - score_eg(b)) do return false
		return true
	}
	if !check(t, S(100, 200), S(50, 30))   do return
	if !check(t, S(-50, 100), S(75, -20))  do return
	if !check(t, S(0, 0),     S(0, 0))     do return
	if !check(t, S(500, 900), S(-300, 400)) do return
	// Mobility extremes: min and max entries cancel cleanly
	if !check(t, KNIGHT_MOBILITY[0], KNIGHT_MOBILITY[len(KNIGHT_MOBILITY)-1]) do return
	if !check(t, ROOK_MOBILITY[len(ROOK_MOBILITY)-1], ROOK_MOBILITY[0])       do return
}

// Accumulates a packed Score for a worst-case pile of terms and verifies it
// matches an i32 reference. A mismatch means mg or eg silently overflowed i16.
@(test)
score_accumulation :: proc(t: ^testing.T) {
	acc: Score
	ref_mg, ref_eg: i32

	add :: proc(acc: ^Score, ref_mg, ref_eg: ^i32, s: Score, n: int = 1) {
		for _ in 0..<n {
			acc^    += s
			ref_mg^ += i32(score_mg(s))
			ref_eg^ += i32(score_eg(s))
		}
	}

	tbl_max :: proc(tbl: [64]Score) -> (max_s: Score) {
		for s in tbl {
			max_s = max(max_s, s)
		}

		return
	}

	// Starting material on highest value PSQT squares
	add(&acc, &ref_mg, &ref_eg, piece_score[.Pawn]   + tbl_max(pawn_tbl), 8)
	add(&acc, &ref_mg, &ref_eg, piece_score[.Knight] + tbl_max(knight_tbl), 2)
	add(&acc, &ref_mg, &ref_eg, piece_score[.Bishop] + tbl_max(bishop_tbl), 2)
	add(&acc, &ref_mg, &ref_eg, piece_score[.Rook]   + tbl_max(rook_tbl), 2)
	add(&acc, &ref_mg, &ref_eg, piece_score[.Queen]  + tbl_max(queen_tbl), 1)
	add(&acc, &ref_mg, &ref_eg, piece_score[.King]   + tbl_max(king_tbl), 1)

	// Max mobility for each piece type
	add(&acc, &ref_mg, &ref_eg, KNIGHT_MOBILITY[len(KNIGHT_MOBILITY)-1], 2)
	add(&acc, &ref_mg, &ref_eg, BISHOP_MOBILITY[len(BISHOP_MOBILITY)-1], 2)
	add(&acc, &ref_mg, &ref_eg, ROOK_MOBILITY[len(ROOK_MOBILITY)-1],     2)
	add(&acc, &ref_mg, &ref_eg, QUEEN_MOBILITY[len(QUEEN_MOBILITY)-1],   9)

	// All structural bonuses active
	add(&acc, &ref_mg, &ref_eg, BISHOP_PAIR_WEIGHT)
	add(&acc, &ref_mg, &ref_eg, ROOK_OPEN_FILE,           2)
	add(&acc, &ref_mg, &ref_eg, PASSED_PAWN[6],           8)
	add(&acc, &ref_mg, &ref_eg, CONNECTED_PASSED_PAWN[6], 8)
	add(&acc, &ref_mg, &ref_eg, CONNECTED_PAWN,           8)
	add(&acc, &ref_mg, &ref_eg, TEMPO_BONUS)

	// king danger
	king_danger := ZONE_ATTACK_WEIGHT[len(ZONE_ATTACK_WEIGHT)-1] * 200 / 5
	add(&acc, &ref_mg, &ref_eg, S(i16(king_danger), 0))

	if !testing.expect(t, ref_mg >= -32768 && ref_mg <= 32767, "mg overflows i16 — weights need adjustment") do return
	if !testing.expect(t, ref_eg >= -32768 && ref_eg <= 32767, "eg overflows i16 — weights need adjustment") do return

	testing.expect_value(t, score_mg(acc), i16(ref_mg))
	testing.expect_value(t, score_eg(acc), i16(ref_eg))
}

// Verifies that the evaluation function is symmetric with respect to colour by mirroring the position
@(test)
mirror_eval :: proc(t: ^testing.T) {
	init_piece_tables()

	for fen, i in BENCH_FENS {
		position, ok := parse_fen(fen)
		if !ok do continue

		eval1 := evaluate(&position)
		mirrored_pos := mirror_colour(position)
		eval2 := evaluate(&mirrored_pos)

		if !testing.expect_value(t, eval2, eval1) {
			log.infof("Asymmetrically evaluated {}", fen)

			return
		}
	}
}
