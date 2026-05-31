package blunderbuss

import "core:math"
import "core:testing"
import "core:log"
import "base:intrinsics"

TRACING :: #config(TRACING, false) || #config(TUNING, false)

TAPER_SCALE :: 256 // represent fractional values 0.0 -> 0, 1.0 -> 256

Coeffs :: struct #packed {
	// normal
	tempo: [Colour]int,
	material_count: [PieceType][Colour]int,
	piece_sq_tbls: [PieceType][64][Colour]int,
	isolated_pawns: [Colour]int,
	backward_pawns: [Colour]int,
	connected_pawns: [Colour]int,
	doubled_pawns: [5][Colour]int,
	isolated_doubled: [Colour]int,
	passed_pawns: [8][Colour]int,
	connected_passed: [8][Colour]int,
	bishop_pair: [Colour]int,
	rook_open: [Colour]int,
	rook_semi_open: [Colour]int,
	knight_mobility: [len(KNIGHT_MOBILITY)][Colour]int,
	bishop_mobility: [len(BISHOP_MOBILITY)][Colour]int,
	rook_mobility: [len(ROOK_MOBILITY)][Colour]int,
	queen_mobility: [len(QUEEN_MOBILITY)][Colour]int,
	king_shelter: [8][Colour]int,
	pawn_storm: [8][Colour]int,
}

Trace :: struct {
	coeffs: Coeffs,
	normal: Score,
	turn: Colour
}

trace: Trace

Score :: distinct i32 // packed data: upper 16 bits = eg, lower 16 bits = mg
Phase :: enum{MG, EG}

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

score_phase :: proc(s: Score, p: Phase) -> (val: i16) {
	switch p {
	case .MG:
		val = score_mg(s)
	case .EG:
		val = score_eg(s)
	}

	return
}

piece_sq_tbl: [PieceType]^[64]Score = {
	.Pawn	= &pawn_tbl,
	.Knight = &knight_tbl,
	.Bishop = &bishop_tbl,
	.Rook	= &rook_tbl,
	.Queen	= &queen_tbl,
	.King	= &king_tbl,
}

piece_phase: [PieceType]int = {
	.Pawn = 0,
	.Knight = 1,
	.Bishop = 1,
	.Rook = 2,
	.Queen = 4,
	.King = 0,
}

wdl :: proc(eval: int, phase: int) -> f64 {
	scale := 400 * (24 - phase)/24
	return 1 / (1 + math.pow(10, -f64(eval)/400))
}

evaluate :: proc(position: ^Position) -> int {
	us := position.turn
	them := toggle(us)

	when TRACING {
		trace = Trace{}
		trace.coeffs.tempo[position.turn] = 1
		trace.turn = us
	}

	scores: [Colour]Score
	attack_units: [Colour]Score
	pieces := position.pieces
	occ := occupied(position)
	phase: int


	for us in Colour {
		them := toggle(us)
		occ_us := position.occupancy[us]
		pawns_us := pieces[us][.Pawn]
		pawns_them := pieces[them][.Pawn]
		pawn_controlled := pawn_attacks(them, pawns_them)
		bishop_pair: bit_set[Colour]

		king_them := lsb(pieces[them][.King])
		king_zone := king_zone(them, king_them)

		for bb, piece in pieces[us] {
			from_bb := bb
			for from_bb > 0 {
				from := pop_lsb(&from_bb)

				// count material
				lookup_sq := from
				if us == .White {
					lookup_sq ~= 56 // PSQT defined from black perspective
				}

				scores[us] += piece_score[piece] + piece_sq_tbl[piece][lookup_sq]
				phase += piece_phase[piece]

				when TRACING {
					trace.coeffs.material_count[piece][us] += 1
					trace.coeffs.piece_sq_tbls[piece][lookup_sq][us] = 1
				}

				to_bb: u64
				switch piece {
				case .Pawn:
					to_bb = pawn_attacks(us, bitboard(from))
				case .Knight:
					to_bb = KNIGHT_TABLE[from]
					mobility := pop_count(to_bb &~ occ_us &~ pawn_controlled)
					scores[us] += KNIGHT_MOBILITY[mobility]
					when TRACING do trace.coeffs.knight_mobility[mobility][us] += 1
				case .Bishop:
					to_bb = magic_bishop_moves(from, occ)
					mobility := pop_count(to_bb &~ occ_us &~ pawn_controlled)
					scores[us] += BISHOP_MOBILITY[mobility]
					when TRACING do trace.coeffs.bishop_mobility[mobility][us] += 1

					bishop_pair += {square_colour(from)}
				case .Rook:
					to_bb = magic_rook_moves(from, occ)
					mobility := pop_count(to_bb &~ occ_us &~ pawn_controlled)
					scores[us] += ROOK_MOBILITY[mobility]
					when TRACING do trace.coeffs.rook_mobility[mobility][us] += 1

					file := SQ_MASKS[from].file
					if pawns_us & file == 0 {
						if pawns_them & file == 0 {
							scores[us] += ROOK_OPEN_FILE
							when TRACING do trace.coeffs.rook_open[us] += 1
						} else {
							scores[us] += ROOK_SEMI_OPEN_FILE
							when TRACING do trace.coeffs.rook_semi_open[us] += 1
						}
					}
				case .Queen:
					to_bb = magic_queen_moves(from, occ)
					mobility := pop_count(to_bb &~ occ_us &~ pawn_controlled)
					scores[us] += QUEEN_MOBILITY[mobility]
					when TRACING do trace.coeffs.queen_mobility[mobility][us] += 1

				case .King:
					to_bb = KING_TABLE[from]
				}
			}
		}


		if bishop_pair == {.White, .Black} {
			scores[us] += BISHOP_PAIR
			when TRACING do trace.coeffs.bishop_pair[us] = 1
		}

		scores[us] += pawn_structure(position, us)
		scores[us] += king_shelter(position, us)
	}

	scores[us] += TEMPO_BONUS

	when TRACING do trace.normal = scores[.White] - scores[.Black]

	phase = clamp(phase, 0, 24)
	phase = (TAPER_SCALE * phase + 12) / 24

	eval := scores[us] - scores[them]
	mg_eval := int(score_mg(eval))
	eg_eval := int(score_eg(eval))
	return (mg_eval * phase + eg_eval * (TAPER_SCALE - phase)) / TAPER_SCALE
}

king_zone :: proc(side: Colour, king_sq: int) -> u64 {
	zone := KING_TABLE[king_sq]
	zone |= zone << 8 if side == .White else zone >> 8
	return zone
}

king_shelter :: proc(position: ^Position, us: Colour) -> (score: Score) {
	them := toggle(us)
	king_us := position.pieces[us][.King]
	king_sq := lsb(king_us)
	king_rank := king_sq / 8
	king_file := king_sq % 8

	shelter_mask := ranks_ahead(us, king_rank)
	pawns_us := position.pieces[us][.Pawn] & shelter_mask
	pawns_them := position.pieces[them][.Pawn] & shelter_mask

	for offset in -1..=1 {
		file := clamp(king_file, 1, 6) + offset
		file_bb := H_FILE << uint(file)
		
		shield_file := pawns_us & file_bb
		storm_file := pawns_them & file_bb

		shield_distance, storm_distance: int
		if us == .White {
			shield_distance = lsb(shield_file) / 8
			storm_distance = lsb(storm_file) / 8
		} else {
			shield_distance = int(intrinsics.count_leading_zeros(shield_file) / 8)
			storm_distance = int(intrinsics.count_leading_zeros(storm_file) / 8)
		}

		// open files at index 0
		shield_distance %= 8
		storm_distance %= 8

		score += KING_SHELTER[shield_distance]
		when TRACING do trace.coeffs.king_shelter[shield_distance][us] += 1

		score += PAWN_STORM[storm_distance]
		when TRACING do trace.coeffs.pawn_storm[storm_distance][us] += 1
	}

	return
}

pawn_structure :: proc(position: ^Position, us: Colour) -> (score: Score) {
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
			when TRACING do trace.coeffs.connected_pawns[us] += 1
		}

		if (file_left | file_right) & pawns_us == 0 {
			is_isolated[file_idx] = true
		}

		if ahead_mask & pawns_them == 0 {
			score += PASSED_PAWN[pushed_distance]
			when TRACING do trace.coeffs.passed_pawns[pushed_distance][us] += 1

			if defenders != 0 {
				score += CONNECTED_PASSED_PAWN[pushed_distance]
				when TRACING {
					trace.coeffs.connected_passed[pushed_distance][us] += 1
				}
			}
		}

		if behind_mask & pawns_us == 0 && sentry_mask & pawns_them != 0 {
			score += BACKWARD_PAWN
			when TRACING do trace.coeffs.backward_pawns[us] += 1
		}
	}

	for file in 0..<8 {
		count := file_count[file]
		score += STACKED_PAWN[min(count, 4)]
		when TRACING do trace.coeffs.doubled_pawns[min(count, 4)][us] += 1

		if is_isolated[file] {
			score += ISOLATED_PAWN
			when TRACING do trace.coeffs.isolated_pawns[us] += 1

			if count > 1 {
				score += ISOLATED_DOUBLED
				when TRACING do trace.coeffs.isolated_doubled[us] += 1
			}
		}
	}

	return
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
	if !check(t, S(0, 0),	  S(0, 0))	   do return
	if !check(t, S(500, 900), S(-300, 400)) do return
	// Mobility extremes: min and max entries cancel cleanly
	if !check(t, KNIGHT_MOBILITY[0], KNIGHT_MOBILITY[len(KNIGHT_MOBILITY)-1]) do return
	if !check(t, ROOK_MOBILITY[len(ROOK_MOBILITY)-1], ROOK_MOBILITY[0])		  do return
}

// Accumulates a packed Score for a worst-case pile of terms and verifies it
// matches an i32 reference. A mismatch means mg or eg silently overflowed i16.
@(test)
score_accumulation :: proc(t: ^testing.T) {
	acc: Score
	ref_mg, ref_eg: i32

	add :: proc(acc: ^Score, ref_mg, ref_eg: ^i32, s: Score, n: int = 1) {
		for _ in 0..<n {
			acc^	+= s
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
	add(&acc, &ref_mg, &ref_eg, piece_score[.Pawn]	 + tbl_max(pawn_tbl), 8)
	add(&acc, &ref_mg, &ref_eg, piece_score[.Knight] + tbl_max(knight_tbl), 2)
	add(&acc, &ref_mg, &ref_eg, piece_score[.Bishop] + tbl_max(bishop_tbl), 2)
	add(&acc, &ref_mg, &ref_eg, piece_score[.Rook]	 + tbl_max(rook_tbl), 2)
	add(&acc, &ref_mg, &ref_eg, piece_score[.Queen]  + tbl_max(queen_tbl), 1)
	add(&acc, &ref_mg, &ref_eg, piece_score[.King]	 + tbl_max(king_tbl), 1)

	// Max mobility for each piece type
	add(&acc, &ref_mg, &ref_eg, KNIGHT_MOBILITY[len(KNIGHT_MOBILITY)-1], 2)
	add(&acc, &ref_mg, &ref_eg, BISHOP_MOBILITY[len(BISHOP_MOBILITY)-1], 2)
	add(&acc, &ref_mg, &ref_eg, ROOK_MOBILITY[len(ROOK_MOBILITY)-1],	 2)
	add(&acc, &ref_mg, &ref_eg, QUEEN_MOBILITY[len(QUEEN_MOBILITY)-1],	 9)

	// All structural bonuses active
	add(&acc, &ref_mg, &ref_eg, BISHOP_PAIR)
	add(&acc, &ref_mg, &ref_eg, ROOK_OPEN_FILE,			  2)
	add(&acc, &ref_mg, &ref_eg, PASSED_PAWN[6],			  8)
	add(&acc, &ref_mg, &ref_eg, CONNECTED_PASSED_PAWN[6], 8)
	add(&acc, &ref_mg, &ref_eg, CONNECTED_PAWN,			  8)
	add(&acc, &ref_mg, &ref_eg, TEMPO_BONUS)

	// king safety
	// add(&acc, &ref_mg, &ref_eg, ATTACK_STRENGTH[39])

	if !testing.expect(t, ref_mg >= -32768 && ref_mg <= 32767, "mg overflows i16 — weights need adjustment") do return
	if !testing.expect(t, ref_eg >= -32768 && ref_eg <= 32767, "eg overflows i16 — weights need adjustment") do return

	testing.expect_value(t, score_mg(acc), i16(ref_mg))
	testing.expect_value(t, score_eg(acc), i16(ref_eg))
}

when !TUNING {
@(test)
mirror_eval :: proc(t: ^testing.T) {
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
}
