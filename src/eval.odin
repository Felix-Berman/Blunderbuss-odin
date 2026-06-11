package blunderbuss

import "core:math"
import "core:testing"
import "core:log"
import "base:intrinsics"

TRACING :: #config(TRACING, false) || #config(TUNING, false)

TAPER_SCALE :: 256 // represent fractional values 0.0 -> 0, 1.0 -> 256

KNIGHT_MOBILITY_COUNT :: 9
BISHOP_MOBILITY_COUNT :: 14
ROOK_MOBILITY_COUNT   :: 15
QUEEN_MOBILITY_COUNT  :: 28

EvalTerms :: struct($T: typeid) #packed {
	tempo: T,
	material: [PieceType]T,
	piece_sq_tbls: [PieceType][64]T,
	isolated_pawns: T,
	backward_pawns: T,
	connected_pawns: T,
	doubled_pawns: [5]T,
	isolated_doubled: T,
	passed_pawns: [8]T,
	connected_passed: [8]T,
	bishop_pair: T,
	rook_open: T,
	rook_semi_open: T,
	knight_mobility: [KNIGHT_MOBILITY_COUNT]T,
	bishop_mobility: [BISHOP_MOBILITY_COUNT]T,
	rook_mobility: [ROOK_MOBILITY_COUNT]T,
	queen_mobility: [QUEEN_MOBILITY_COUNT]T,
	missing_shield: [2]T,
	advanced_shield_one: [2]T,
	advanced_shield_two: [2]T,
	pawn_storm: [8]T,
}

EvalWeights :: EvalTerms(Score)
Coeffs :: EvalTerms([Colour]int)
EvalTerm :: distinct i32

TERM_SIZE :: size_of([Colour]int)
N_EVAL_TERMS :: size_of(Coeffs) / TERM_SIZE
#assert(size_of(Coeffs) % TERM_SIZE == 0)
#assert(size_of(EvalWeights) % size_of(Score) == 0)
#assert(size_of(EvalWeights) / size_of(Score) == N_EVAL_TERMS)
#assert(size_of(EvalTerms(EvalTerm)) % size_of(EvalTerm) == 0)
#assert(size_of(EvalTerms(EvalTerm)) / size_of(EvalTerm) == N_EVAL_TERMS)

init_eval_terms :: proc "contextless" () -> (terms: EvalTerms(EvalTerm)) {
	flat := cast(^[N_EVAL_TERMS]EvalTerm)&terms
	for i in 0..<N_EVAL_TERMS {
		flat[i] = EvalTerm(i)
	}
	return
}

eval_terms := init_eval_terms()

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

score_mg :: #force_inline proc "contextless" (s: Score) -> i16 {
	return i16(s)
}

// negative middlegame values borrow LSB from endgame value.
// Adding 0x8000 to mg value with leading 1 (negative) carries to the endgame
// value restoring it from the borrow
score_eg :: #force_inline proc "contextless" (s: Score) -> i16 {
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

eval_term_weight :: #force_inline proc(term: EvalTerm) -> Score {
	weights := cast(^[N_EVAL_TERMS]Score)&eval_weights
	return weights[int(term)]
}

add_eval_term :: #force_inline proc(score: ^Score, side: Colour, term: EvalTerm) {
	when TRACING {
		coeffs := cast(^[N_EVAL_TERMS][Colour]int)&trace.coeffs
		coeffs[int(term)][side] += 1
	}

	score^ += eval_term_weight(term)
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

		attacked_bb: u64

		for bb, piece in pieces[us] {
			from_bb := bb
			for from_bb > 0 {
				from := pop_lsb(&from_bb)

				// count material
				lookup_sq := from
				if us == .White {
					lookup_sq ~= 56 // PSQT defined from black perspective
				}

				add_eval_term(&scores[us], us, eval_terms.material[piece])
				add_eval_term(&scores[us], us, eval_terms.piece_sq_tbls[piece][lookup_sq])
				phase += piece_phase[piece]

				to_bb: u64
				switch piece {
				case .Pawn:
					to_bb = pawn_attacks(us, bitboard(from))
				case .Knight:
					to_bb = KNIGHT_TABLE[from]
					mobility := pop_count(to_bb &~ occ_us &~ pawn_controlled)
					add_eval_term(&scores[us], us, eval_terms.knight_mobility[mobility])
				case .Bishop:
					to_bb = magic_bishop_moves(from, occ)
					mobility := pop_count(to_bb &~ occ_us &~ pawn_controlled)
					add_eval_term(&scores[us], us, eval_terms.bishop_mobility[mobility])

					bishop_pair += {square_colour(from)}
				case .Rook:
					to_bb = magic_rook_moves(from, occ)
					mobility := pop_count(to_bb &~ occ_us &~ pawn_controlled)
					add_eval_term(&scores[us], us, eval_terms.rook_mobility[mobility])

					file := SQ_MASKS[from].file
					if pawns_us & file == 0 {
						if pawns_them & file == 0 {
							add_eval_term(&scores[us], us, eval_terms.rook_open)
						} else {
							add_eval_term(&scores[us], us, eval_terms.rook_semi_open)
						}
					}
				case .Queen:
					to_bb = magic_queen_moves(from, occ)
					mobility := pop_count(to_bb &~ occ_us &~ pawn_controlled)
					add_eval_term(&scores[us], us, eval_terms.queen_mobility[mobility])
				case .King:
					to_bb = KING_TABLE[from]
				}

				attacked_bb |= to_bb
			}
		}


		if bishop_pair == {.White, .Black} {
			add_eval_term(&scores[us], us, eval_terms.bishop_pair)
		}

		scores[us] += pawn_structure(position, us)
		scores[us] += king_shelter(position, us)
	}

	add_eval_term(&scores[us], us, eval_terms.tempo)

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

		on_king := 0
		if file == king_file {
			on_king = 1
		}

		if shield_distance == 0 {
			add_eval_term(&score, us, eval_terms.missing_shield[on_king])
		} else if shield_distance == 1 {
			add_eval_term(&score, us, eval_terms.advanced_shield_one[on_king])
		} else if shield_distance == 2 {
			add_eval_term(&score, us, eval_terms.advanced_shield_two[on_king])
		}

		add_eval_term(&score, us, eval_terms.pawn_storm[storm_distance])
	}

	return
}

attack_strength :: proc(position: ^Position, us: Colour) -> (score: Score) {
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
			add_eval_term(&score, us, eval_terms.connected_pawns)
		}

		if (file_left | file_right) & pawns_us == 0 {
			is_isolated[file_idx] = true
		}

		if ahead_mask & pawns_them == 0 {
			add_eval_term(&score, us, eval_terms.passed_pawns[pushed_distance])

			if defenders != 0 {
				add_eval_term(&score, us, eval_terms.connected_passed[pushed_distance])
			}
		}

		if behind_mask & pawns_us == 0 && sentry_mask & pawns_them != 0 {
			add_eval_term(&score, us, eval_terms.backward_pawns)
		}
	}

	for file in 0..<8 {
		count := file_count[file]
		doubled_idx := min(count, 4)
		add_eval_term(&score, us, eval_terms.doubled_pawns[doubled_idx])

		if is_isolated[file] {
			add_eval_term(&score, us, eval_terms.isolated_pawns)

			if count > 1 {
				add_eval_term(&score, us, eval_terms.isolated_doubled)
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
	if !check(t, eval_weights.knight_mobility[0], eval_weights.knight_mobility[KNIGHT_MOBILITY_COUNT-1]) do return
	if !check(t, eval_weights.rook_mobility[ROOK_MOBILITY_COUNT-1], eval_weights.rook_mobility[0])		  do return
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
	add(&acc, &ref_mg, &ref_eg, eval_weights.material[.Pawn]   + tbl_max(eval_weights.piece_sq_tbls[.Pawn]), 8)
	add(&acc, &ref_mg, &ref_eg, eval_weights.material[.Knight] + tbl_max(eval_weights.piece_sq_tbls[.Knight]), 2)
	add(&acc, &ref_mg, &ref_eg, eval_weights.material[.Bishop] + tbl_max(eval_weights.piece_sq_tbls[.Bishop]), 2)
	add(&acc, &ref_mg, &ref_eg, eval_weights.material[.Rook]   + tbl_max(eval_weights.piece_sq_tbls[.Rook]), 2)
	add(&acc, &ref_mg, &ref_eg, eval_weights.material[.Queen]  + tbl_max(eval_weights.piece_sq_tbls[.Queen]), 1)
	add(&acc, &ref_mg, &ref_eg, eval_weights.material[.King]   + tbl_max(eval_weights.piece_sq_tbls[.King]), 1)

	// Max mobility for each piece type
	add(&acc, &ref_mg, &ref_eg, eval_weights.knight_mobility[KNIGHT_MOBILITY_COUNT-1], 2)
	add(&acc, &ref_mg, &ref_eg, eval_weights.bishop_mobility[BISHOP_MOBILITY_COUNT-1], 2)
	add(&acc, &ref_mg, &ref_eg, eval_weights.rook_mobility[ROOK_MOBILITY_COUNT-1],	 2)
	add(&acc, &ref_mg, &ref_eg, eval_weights.queen_mobility[QUEEN_MOBILITY_COUNT-1],	 9)

	// All structural bonuses active
	add(&acc, &ref_mg, &ref_eg, eval_weights.bishop_pair)
	add(&acc, &ref_mg, &ref_eg, eval_weights.rook_open,			  2)
	add(&acc, &ref_mg, &ref_eg, eval_weights.passed_pawns[6],	  8)
	add(&acc, &ref_mg, &ref_eg, eval_weights.connected_passed[6], 8)
	add(&acc, &ref_mg, &ref_eg, eval_weights.connected_pawns,	  8)
	add(&acc, &ref_mg, &ref_eg, eval_weights.tempo)

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
