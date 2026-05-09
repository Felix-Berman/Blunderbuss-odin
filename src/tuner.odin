package blunderbuss

import "core:os"
import "core:strings"
import "core:math"
import "core:fmt"
import "core:thread"
import "core:math/rand"
import "core:time"
import "core:time/timezone"
import "core:testing"

TUNING :: #config(TUNING, false)

TUNING_DATASET :: "training_sets/quiet-labeled.epd"
TERM_SIZE :: size_of([Colour]int)
N_EVAL_TERMS :: size_of(Coeffs) / TERM_SIZE
N_THREADS :: 8
K_PRECISION :: 10
BATCH_SIZE :: 16384
MAX_EPOCHS :: 100_000
LR_RATE :: 1
LR_MIN :: 0.1
LR_STEP_RATE :: 250
LR_DROP_RATE :: 1.1
REPORTING_RATE :: 20

TermType :: enum{Normal, Safety, Attack}

TunerTuple :: struct { idx, w_coeff, b_coeff: int }

TunerEntry :: struct {
	static_eval: int,
	phase: int,
	turn: Colour,
	normal: Score,
	safety: [Colour]Score,
	attack: [Colour]Score,
	result: f32,
	mg_factor: f32,
	eg_factor: f32,
	tuples: []TunerTuple,
	n_tuples: int,
}

GradientData :: struct {
	safety: [Colour][Phase]f32,
	units: [Colour][Phase]f32,
}

WorkerData :: struct {
	entries: []TunerEntry,
	params: [][Phase]f32,
	str_params: [][Phase]f32,
	scale_params: [][Phase]f32,
	types: []TermType,
	K: f32,
	gradient: [][Phase]f32,
	str_grad: [][Phase]f32,
	scl_grad: [][Phase]f32,
	error: f32,
}

run_tuner :: proc() {
	params := make([][Phase]f32, N_EVAL_TERMS); defer delete(params)
	adagrad := make([][Phase]f32, N_EVAL_TERMS); defer delete(adagrad)
	c_params := make([][Phase]f32, N_EVAL_TERMS); defer delete(c_params)
	init_base_params(c_params)
	str_params := make([][Phase]f32, len(ATTACK_STRENGTH))
	str_adagrad := make([][Phase]f32, len(ATTACK_STRENGTH))
	scale_params := make([][Phase]f32, len(SHELTER_SCALE))
	scale_adagrad := make([][Phase]f32, len(SHELTER_SCALE))
	defer delete(str_params)
	defer delete(str_adagrad)
	defer delete(scale_params)
	defer delete(scale_adagrad)
	error: f32
	rate: f32 = LR_RATE

	types := build_eval_types()
	entries := init_entries(types)[:]
	K := compute_optimal_K(&entries)

	n_batches := len(entries) / BATCH_SIZE
	batch_size_f := f32(BATCH_SIZE)

	now := time.now()
	utc_offset := 10 * 60 * 60 // default to AEST
	if tz, tz_ok := timezone.region_load("local"); tz_ok {
		utc_offset = int(tz.rrule.std_offset)
	}
	local_now := time.time_add(now, time.Duration(utc_offset) * time.Second)

	date_buf: [time.MIN_YYYY_DATE_LEN]u8
	hms_buf: [time.MIN_HMS_LEN]u8
	date := time.to_string_yyyy_mm_dd(local_now, date_buf[:])
	// hms := time.to_string_hms(local_now, hms_buf[:])
	hour, minute, sec := time.clock(local_now)
	timestamp := fmt.tprintf("{}_{}-{}", date, hour, minute)
	os.make_directory("tuner_log")
	log_path	 := fmt.tprintf("tuner_log/{}_tuner.log", timestamp)
	weights_path := fmt.tprintf("tuner_log/{}_weights.txt", timestamp)

	log_file, log_err := os.create(log_path)
	if log_err != nil {
		fmt.eprintfln("Failed ot create log file {}: {}", log_path, log_err)
		return
	}
	weights_file, weights_err := os.create(weights_path)
	if weights_err != nil {
		fmt.eprintfln("Failed ot create weights file {}: {}", weights_path, weights_err)
		return
	}

	// log_builder: strings.Builder
	// strings.builder_init(&log_builder)
	// defer strings.builder_destroy(&log_builder)

	header := fmt.tprintfln(
		"K={:.4f}  positions={}  batch_size={}	n_batches={}  epochs={}",
		K, len(entries), BATCH_SIZE, n_batches, MAX_EPOCHS,
	)
	fmt.print(header)
	// fmt.sbprint(&log_builder, header)
	// _ = os.write_entire_file(log_path, transmute([]byte)strings.to_string(log_builder))
	if _, werr := os.write_string(log_file, header); werr != nil {
		fmt.eprintfln("warning: failed to write to log: {}", werr)
	}

	// prevent overfitting to batch order
	rand.shuffle(entries[:])

	fmt.println("Starting tuning...")
	for epoch in 0..<MAX_EPOCHS {
		for batch in 0..<n_batches {
			gradient := make([][Phase]f32, N_EVAL_TERMS)
			str_grad := make([][Phase]f32, len(ATTACK_STRENGTH))
			scl_grad := make([][Phase]f32, len(SHELTER_SCALE))
			defer delete(gradient)
			defer delete(str_grad)
			defer delete(scl_grad)

			batch_start := batch * BATCH_SIZE
			batch_end := min(batch_start + BATCH_SIZE, len(entries))
			compute_gradient(entries[batch_start:batch_end], &gradient, &str_grad, &scl_grad,
				params, str_params, scale_params, types[:], K)

			for i in 0..<N_EVAL_TERMS {
				adagrad[i][.MG] += math.pow((K / 200) * gradient[i][.MG] / batch_size_f, 2)
				adagrad[i][.EG] += math.pow((K / 200) * gradient[i][.EG] / batch_size_f, 2)

				params[i][.MG] += (K / 200) * (gradient[i][.MG]  / BATCH_SIZE) *
					(rate / math.sqrt(1e-8 + adagrad[i][.MG]))
				params[i][.EG] += (K / 200) * (gradient[i][.EG]  / BATCH_SIZE) *
					(rate / math.sqrt(1e-8 + adagrad[i][.EG]))
			}

			enforce_parameter_constraints(params, c_params)

			// ATTACK_UNITS: no piece should reduce the attack threat
			au_start := offset_of(Coeffs, attacker_counts) / TERM_SIZE
			for i in au_start..<au_start+len(ATTACK_UNITS)+3 {
				for p in Phase {
					if c_params[i][p] + params[i][p] < 0 do params[i][p] = -c_params[i][p]
				}
			}

			for k in 0..<len(ATTACK_STRENGTH) {
				for p in Phase {
					str_adagrad[k][p] += math.pow((K / 200) * str_grad[k][p] / batch_size_f, 2)
					str_params[k][p]  += (K / 200) * (str_grad[k][p]  / BATCH_SIZE) *
						(rate / math.sqrt(1e-8 + str_adagrad[k][p]))
					// str_params[k][p] = max(0, str_params[k][p])
				}
			}

			// ATTACK_STRENGTH: enforce monotonically non-decreasing
			for k in 1..<len(ATTACK_STRENGTH) {
				for p in Phase {
					prev := f32(score_phase(ATTACK_STRENGTH[k-1], p)) + str_params[k-1][p]
					curr := f32(score_phase(ATTACK_STRENGTH[k], p)) + str_params[k][p]
					if curr < prev {
						str_params[k][p] = prev - f32(score_phase(ATTACK_STRENGTH[k], p))
					}
				}
			}

			for k in 0..<len(SHELTER_SCALE) {
				for p in Phase {
					scale_adagrad[k][p] += math.pow((K / 200) * scl_grad[k][p] / batch_size_f, 2)
					scale_params[k][p]  += (K / 200) * (scl_grad[k][p] / BATCH_SIZE) *
						(rate / math.sqrt(1e-8 + scale_adagrad[k][p]))
				}
				// shelter scale must be monotonic per phase
				if k > 0 {
					for p in Phase {
						prev := f32(score_phase(SHELTER_SCALE[k-1], p)) + scale_params[k-1][p]
						curr := f32(score_phase(SHELTER_SCALE[k], p)) + scale_params[k][p]
						if curr < prev do scale_params[k][p] = prev - f32(score_phase(SHELTER_SCALE[k], p))
					}
				}
			}
		}

		error = tuned_evaluation_errors(entries, params, str_params,
			scale_params, types[:], K)

		lr_dropped := epoch != 0 && epoch % LR_STEP_RATE == 0
		if lr_dropped do rate /= LR_DROP_RATE

		rate = max(rate, LR_MIN)

		line := fmt.tprintfln(
			"epoch {:4d} | error {:.6f} | rate {:.4f}{}",
			epoch, error, rate,
			" [lr drop]" if lr_dropped else "",
		)
		fmt.print(line)
		// fmt.sbprint(&log_builder, line)
		// _ = os.write_entire_file(log_path, transmute([]byte)strings.to_string(log_builder))
		if _, werr := os.write_string(log_file, line); werr != nil {
			fmt.eprintfln("warning: failed to write to log: {}", werr)
		}

		if epoch % REPORTING_RATE == 0 {
			enforce_parameter_constraints(params, c_params)
			print_params(params, c_params, str_params, scale_params,
				weights_path, timestamp)
		}

		rand.shuffle(entries[:])
	}

	enforce_parameter_constraints(params, c_params)
	print_params(params, c_params, str_params, scale_params, weights_path, timestamp)
}

gradient_worker :: proc(t: ^thread.Thread) {
	data := (^WorkerData)(t.data)

	for i in 0..<len(data.entries) {
		update_single_gradient(
			&data.entries[i],
			&data.gradient,
			&data.str_grad,
			&data.scl_grad,
			data.params,
			data.str_params,
			data.scale_params,
			data.types,
			data.K,
		)
	}
}

error_worker :: proc(t: ^thread.Thread) {
	data := (^WorkerData)(t.data)
	data.error = 0

	dummy: GradientData
	for i in 0..<len(data.entries) {
		E := linear_evaluation(
			&data.entries[i],
			data.params,
			data.str_params,
			data.scale_params,
			data.types,
			&dummy,
		)
		diff := data.entries[i].result - sigmoid(data.K, E)
		data.error += diff * diff
	}
}

static_error_worker :: proc(t: ^thread.Thread) {
	data := (^WorkerData)(t.data)
	data.error = 0

	dummy: GradientData
	for i in 0..<len(data.entries) {
		entry := data.entries[i]
		diff := entry.result - sigmoid(data.K, f32(entry.static_eval))
		data.error += diff * diff
	}
}

build_eval_types :: proc() -> (types: [N_EVAL_TERMS]TermType) {
	safety_start := offset_of(Coeffs, pawn_shield) / TERM_SIZE
	attack_start := offset_of(Coeffs, attacker_counts) / TERM_SIZE

	for i in 0 ..< safety_start do types[i] = .Normal
	for i in safety_start ..< attack_start do types[i] = .Safety
	for i in attack_start ..< N_EVAL_TERMS do types[i] = .Attack

	return
}

enforce_parameter_constraints :: proc(params, c_params: [][Phase]f32) {
	material_start := int(offset_of(Coeffs, material_count) / TERM_SIZE)
	psqt_start := int(offset_of(Coeffs, piece_sq_tbls) / TERM_SIZE)
	pawn_material_idx := material_start + int(PieceType.Pawn)

	// maintain centipawn relative eval
	params[pawn_material_idx][.MG] = 0
	params[pawn_material_idx][.EG] = 0

	for piece in PieceType {
		table_start := psqt_start + int(piece) * 64
		material_idx := material_start + int(piece)

		for p in Phase {
			mean: f32
			for sq in 0..<64 {
				idx := table_start + sq
				mean += c_params[idx][p] + params[idx][p]
			}
			mean /= 64

			for sq in 0..<64 {
				params[table_start + sq][p] -= mean
			}

			// Keep non-pawn material values equal to the average piece value.
			// Pawn material is the fixed centipawn anchor; king material cancels.
			if piece != .Pawn && piece != .King {
				params[material_idx][p] += mean
			}
		}
	}

	params[pawn_material_idx][.MG] = 0
	params[pawn_material_idx][.EG] = 0
}

@(test)
tuner_parameter_constraints :: proc(t: ^testing.T) {
	params := make([][Phase]f32, N_EVAL_TERMS)
	c_params := make([][Phase]f32, N_EVAL_TERMS)
	defer delete(params)
	defer delete(c_params)

	init_base_params(c_params)

	material_start := int(offset_of(Coeffs, material_count) / TERM_SIZE)
	psqt_start := int(offset_of(Coeffs, piece_sq_tbls) / TERM_SIZE)
	pawn_material_idx := material_start + int(PieceType.Pawn)

	params[pawn_material_idx][.MG] = 42
	params[pawn_material_idx][.EG] = -17

	enforce_parameter_constraints(params, c_params)

	if !testing.expect_value(t, c_params[pawn_material_idx][.MG] + params[pawn_material_idx][.MG], f32(100)) do return
	if !testing.expect_value(t, c_params[pawn_material_idx][.EG] + params[pawn_material_idx][.EG], f32(100)) do return

	for piece in PieceType {
		table_start := psqt_start + int(piece) * 64
		for p in Phase {
			sum: f32
			for sq in 0..<64 {
				sum += c_params[table_start + sq][p] + params[table_start + sq][p]
			}

			if !testing.expect(
				t,
				abs(sum) < 0.01,
				fmt.tprintf("{} {} PSQT mean is not zero: {}", piece, p, sum / 64),
			) {
				return
			}
		}
	}
}

init_base_params :: proc(c_params: [][Phase]f32) {
	idx := 0

	set :: proc(c: [][Phase]f32, idx: ^int, s: Score) {
		c[idx^][.MG] = f32(score_mg(s))
		c[idx^][.EG] = f32(score_eg(s))
		idx^ += 1
	}

	set(c_params, &idx, TEMPO_BONUS)

	for piece in PieceType {
		set(c_params, &idx, piece_score[piece])
	}

	pst := [PieceType]^[64]Score{
		.Pawn	= &pawn_tbl,
		.Knight = &knight_tbl,
		.Bishop = &bishop_tbl,
		.Rook	= &rook_tbl,
		.Queen	= &queen_tbl,
		.King	= &king_tbl,
	}
	for piece in PieceType {
		for sq in 0..<64 {
			set(c_params, &idx, pst[piece][sq])
		}
	}

	set(c_params, &idx, ISOLATED_PAWN)
	set(c_params, &idx, BACKWARD_PAWN)
	set(c_params, &idx, CONNECTED_PAWN)

	for i in 0..<len(STACKED_PAWN) {
		set(c_params, &idx, STACKED_PAWN[i])
	}

	set(c_params, &idx, ISOLATED_DOUBLED)

	for i in 0..<len(PASSED_PAWN) {
		set(c_params, &idx, PASSED_PAWN[i])
	}
	for i in 0..<len(CONNECTED_PASSED_PAWN) {
		set(c_params, &idx, CONNECTED_PASSED_PAWN[i])
	}

	set(c_params, &idx, BISHOP_PAIR)
	set(c_params, &idx, ROOK_OPEN_FILE)
	set(c_params, &idx, ROOK_SEMI_OPEN_FILE)

	for i in 0..<len(KNIGHT_MOBILITY) do set(c_params, &idx, KNIGHT_MOBILITY[i])
	for i in 0..<len(BISHOP_MOBILITY) do set(c_params, &idx, BISHOP_MOBILITY[i])
	for i in 0..<len(ROOK_MOBILITY)  do set(c_params, &idx, ROOK_MOBILITY[i])
	for i in 0..<len(QUEEN_MOBILITY) do set(c_params, &idx, QUEEN_MOBILITY[i])

	for f in 0..<2 { for r in 0..<6 { for file in 0..<8 {
		set(c_params, &idx, PAWN_SHIELD[f][r][file])
	}}}
	for f in 0..<2 { for r in 0..<6 { for file in 0..<8 {
		set(c_params, &idx, PAWN_STORM[f][r][file])
	}}}
	for i in 0..<2 { for j in 0..<2 {
		set(c_params, &idx, SHIELD_GAP[i][j])
	}}
	for i in 0..<len(DEFENDERS) {
		set(c_params, &idx, DEFENDERS[i])
	}

	for piece in PieceType {
		c_params[idx][.MG] = f32(score_mg(ATTACK_UNITS[piece]))
		c_params[idx][.EG] = f32(score_eg(ATTACK_UNITS[piece]))
		idx += 1
	}
	c_params[idx][.MG] = f32(score_mg(BISHOP_BATTERY_UNITS)); c_params[idx][.EG] = f32(score_eg(BISHOP_BATTERY_UNITS)); idx += 1
	c_params[idx][.MG] = f32(score_mg(ROOK_BATTERY_UNITS));   c_params[idx][.EG] = f32(score_eg(ROOK_BATTERY_UNITS));   idx += 1
	c_params[idx][.MG] = f32(score_mg(QUEEN_BATTERY_UNITS));  c_params[idx][.EG] = f32(score_eg(QUEEN_BATTERY_UNITS));  idx += 1
}

init_tuples :: proc(
	entry: ^TunerEntry,
	coeffs: [N_EVAL_TERMS][Colour]int,
	types: [N_EVAL_TERMS]TermType
) {
	length, tuple_idx: int

	for i in 0..< N_EVAL_TERMS {
		if types[i] == .Normal {
			if coeffs[i][.White] - coeffs[i][.Black] != 0 do length += 1
		} else {
			if coeffs[i][.White] != 0 || coeffs[i][.Black] != 0 do length += 1
		}
	}

	entry.n_tuples = length
	entry.tuples = make([]TunerTuple, length)

	for i in 0..< N_EVAL_TERMS {
		tuple := TunerTuple{i, coeffs[i][.White], coeffs[i][.Black]}

		if types[i] == .Normal {
			if coeffs[i][.White] - coeffs[i][.Black] != 0 {
				entry.tuples[tuple_idx] = tuple
				tuple_idx += 1
			}
		} else { // non-linear terms
			if coeffs[i][.White] != 0 || coeffs[i][.Black] != 0 {
				entry.tuples[tuple_idx] = tuple
				tuple_idx += 1
			}
		}
	}
}

init_entry :: proc(
	entry: ^TunerEntry,
	position: ^Position,
	types: [N_EVAL_TERMS]TermType,
) {
	coeffs: [N_EVAL_TERMS][Colour]int

	phase := piece_phase[.Knight] * pop_count(piece_bb(position, .Knight))
	phase += piece_phase[.Bishop] * pop_count(piece_bb(position, .Bishop))
	phase += piece_phase[.Rook] * pop_count(piece_bb(position, .Rook))
	phase += piece_phase[.Queen] * pop_count(piece_bb(position, .Queen))
	phase = clamp(phase, 0, 24)

	entry.mg_factor = f32(phase) / 24
	entry.eg_factor = f32(24 - phase) / 24
	entry.phase = (phase * 256 + 12) / 24

	entry.static_eval = evaluate(position)
	if position.turn == .Black { // Tuning is white relative
		entry.static_eval = -entry.static_eval
	}

	coeffs = (cast(^[N_EVAL_TERMS][Colour]int)&trace)^
	init_tuples(entry, coeffs, types)

	entry.turn = position.turn

	entry.normal = trace.normal
	entry.safety = trace.safety
	entry.attack = trace.attack
}

init_entries :: proc(
	types: [N_EVAL_TERMS]TermType,
) -> (entries: [dynamic]TunerEntry) {
	file_data, err := os.read_entire_file(TUNING_DATASET, context.allocator)
	defer delete(file_data)

	if err != nil {
		fmt.eprintln(err)
		return
	}

	iterator := string(file_data)
	for line in strings.split_lines_iterator(&iterator) {
		entry: TunerEntry
		if strings.contains(line, "1-0") do entry.result = 1
		else if strings.contains(line, "1/2-1/2") do entry.result = 0.5
		else if strings.contains(line, "0-1") do entry.result = 0

		position, ok := parse_fen(line)
		defer delete(position.history)

		if !ok {
			fmt.eprintfln("Failed to read fen: {}", line)
		}
		
		init_entry(&entry, &position, types)
		append(&entries, entry)
	}

	return
}

sigmoid :: proc(K, eval: f32) -> f32 {
	return 1 / (1 + math.exp(-K * eval / 400.0))
}

static_evaluation_errors :: proc(entries: ^[]TunerEntry, K: f32) -> f32 {
	n := len(entries)
	chunk := n / N_THREADS

	worker_data := make([]WorkerData, N_THREADS)
	defer delete(worker_data)
	threads: [N_THREADS]^thread.Thread

	for i in 0..<N_THREADS {
		start := i * chunk
		end := start + chunk if i < N_THREADS - 1 else n

		worker_data[i] = WorkerData{
			entries = entries[start:end],
			K = K,
		}

		threads[i] = thread.create(static_error_worker)
		threads[i].data = &worker_data[i]
		thread.start(threads[i])
	}

	total: f32
	for i in 0..<N_THREADS {
		thread.join(threads[i])
		thread.destroy(threads[i])
		total += worker_data[i].error
	}

	return total / f32(n)
}

compute_optimal_K :: proc(entries: ^[]TunerEntry) -> f32 {
	start: f64
	end: f64 = 10.0
	step: f64 = 1.0

	curr, error: f64
	best := f64(static_evaluation_errors(entries, 0))

	for i in 0..<K_PRECISION {
		fmt.printfln(
			"Searching K in [{:.6f}, {:.6f}] with step {:.6f} | best error {:.6f}",
			start, end, step, best
		)
		curr = start - step
		for curr < end {
			curr += step
			error = f64(static_evaluation_errors(entries, f32(curr)))
			if error <= best {
				best = error
				start = curr
			}
		}

		end = start + step
		start -= step
		step /= 10
	}

	return f32(start)
}

attack_strength :: proc(u: int, params: [][Phase]f32, p: Phase) -> f32 {
	return f32(score_phase(ATTACK_STRENGTH[u], p)) + params[u][p]
}

shield_scale :: proc(u: int, params: [][Phase]f32, p: Phase) -> f32 {
	return f32(score_phase(SHELTER_SCALE[u], p)) + params[u][p]
}

linear_evaluation :: proc(
	entry: ^TunerEntry,
	params: [][Phase]f32,
	str_params: [][Phase]f32,
	scale_params: [][Phase]f32,
	types: []TermType,
	data: ^GradientData,
) -> f32 {
	mixed, midgame, endgame: f32
	w_safety, b_safety: [Phase]f32
	mg, eg: [TermType][Colour]f32

	for n in 0..<entry.n_tuples {
		tuple := entry.tuples[n]
		i := tuple.idx
		mg[types[i]][.White] += f32(tuple.w_coeff) * params[i][.MG]
		mg[types[i]][.Black] += f32(tuple.b_coeff) * params[i][.MG]
		eg[types[i]][.White] += f32(tuple.w_coeff) * params[i][.EG]
		eg[types[i]][.Black] += f32(tuple.b_coeff) * params[i][.EG]
	}

	// add delta to normal eval
	normal_mg := f32(score_mg(entry.normal)) + mg[.Normal][.White] - mg[.Normal][.Black]
	normal_eg := f32(score_eg(entry.normal)) + eg[.Normal][.White] - eg[.Normal][.Black]

	// add delta to attack units and clamp to valid range of shelter scale
	shelter_len := f32(len(SHELTER_SCALE)-1)
	w_mg_units := clamp(f32(score_mg(entry.attack[.White])) + mg[.Attack][.White], 0, shelter_len)
	w_eg_units := clamp(f32(score_eg(entry.attack[.White])) + eg[.Attack][.White], 0, shelter_len)
	b_mg_units := clamp(f32(score_mg(entry.attack[.Black])) + mg[.Attack][.Black], 0, shelter_len)
	b_eg_units := clamp(f32(score_eg(entry.attack[.Black])) + eg[.Attack][.Black], 0, shelter_len)

	// obtain integer and fractional parts of attack units for interpolation of shelter scale
	w_mg_lo := int(w_mg_units); w_mg_frac := w_mg_units - f32(w_mg_lo)
	w_eg_lo := int(w_eg_units); w_eg_frac := w_eg_units - f32(w_eg_lo)
	b_mg_lo := int(b_mg_units); b_mg_frac := b_mg_units - f32(b_mg_lo)
	b_eg_lo := int(b_eg_units); b_eg_frac := b_eg_units - f32(b_eg_lo)
	w_mg_hi := min(w_mg_lo+1, int(shelter_len))
	w_eg_hi := min(w_eg_lo+1, int(shelter_len))
	b_mg_hi := min(b_mg_lo+1, int(shelter_len))
	b_eg_hi := min(b_eg_lo+1, int(shelter_len))

	// White's shelter scale uses Black's attack units; Black's shelter scale uses White's attack units
	w_scale_mg := ((1-b_mg_frac)*shield_scale(b_mg_lo, scale_params, .MG) +
		b_mg_frac*shield_scale(b_mg_hi, scale_params, .MG)) / f32(TAPER_SCALE)
	w_scale_eg := ((1-b_eg_frac)*shield_scale(b_eg_lo, scale_params, .EG) + 
		b_eg_frac*shield_scale(b_eg_hi, scale_params, .EG)) / f32(TAPER_SCALE)
	b_scale_mg := ((1-w_mg_frac)*shield_scale(w_mg_lo, scale_params, .MG) + 
		w_mg_frac*shield_scale(w_mg_hi, scale_params, .MG)) / f32(TAPER_SCALE)
	b_scale_eg := ((1-w_eg_frac)*shield_scale(w_eg_lo, scale_params, .EG) + 
		w_eg_frac*shield_scale(w_eg_hi, scale_params, .EG)) / f32(TAPER_SCALE)

	// add delta to shelter scores
	w_safety[.MG] = f32(score_mg(entry.safety[.White])) + mg[.Safety][.White]
	w_safety[.EG] = f32(score_eg(entry.safety[.White])) + eg[.Safety][.White]
	b_safety[.MG] = f32(score_mg(entry.safety[.Black])) + mg[.Safety][.Black]
	b_safety[.EG] = f32(score_eg(entry.safety[.Black])) + eg[.Safety][.Black]

	safety_mg := w_safety[.MG]*w_scale_mg - b_safety[.MG]*b_scale_mg
	safety_eg := w_safety[.EG]*w_scale_eg - b_safety[.EG]*b_scale_eg

	// interpolate attack strength with separate mg/eg indices
	attack_mg := (1-w_mg_frac)*attack_strength(w_mg_lo, str_params, .MG) + w_mg_frac*attack_strength(w_mg_hi, str_params, .MG)
	attack_mg -= (1-b_mg_frac)*attack_strength(b_mg_lo, str_params, .MG) + b_mg_frac*attack_strength(b_mg_hi, str_params, .MG)
	attack_eg := (1-w_eg_frac)*attack_strength(w_eg_lo, str_params, .EG) + w_eg_frac*attack_strength(w_eg_hi, str_params, .EG)
	attack_eg -= (1-b_eg_frac)*attack_strength(b_eg_lo, str_params, .EG) + b_eg_frac*attack_strength(b_eg_hi, str_params, .EG)

	midgame = normal_mg + safety_mg + attack_mg
	endgame = normal_eg + safety_eg + attack_eg

	mixed = midgame * entry.mg_factor + endgame * entry.eg_factor

	data^ = GradientData{
		safety = {.White = w_safety, .Black = b_safety},
		units  = {
			.White = {.MG = w_mg_units, .EG = w_eg_units},
			.Black = {.MG = b_mg_units, .EG = b_eg_units},
		},
	}

	return mixed
}

compute_gradient :: proc(
	batch: []TunerEntry,
	gradient: ^[][Phase]f32,
	str_grad: ^[][Phase]f32,
	scl_grad: ^[][Phase]f32,
	params: [][Phase]f32,
	str_params: [][Phase]f32,
	scale_params: [][Phase]f32,
	types: []TermType,
	K: f32,
) {
	batch_n := len(batch)
	chunk := (batch_n + N_THREADS - 1) / N_THREADS

	worker_data := make([]WorkerData, N_THREADS)
	defer delete(worker_data)
	threads: [N_THREADS]^thread.Thread

	for i in 0..<N_THREADS {
		start := min(i * chunk, batch_n)
		end := min(start + chunk, batch_n)

		worker_data[i] = WorkerData{
			entries = batch[start:end],
			params = params,
			str_params = str_params,
			scale_params = scale_params,
			types = types,
			K = K,
			gradient = make([][Phase]f32, N_EVAL_TERMS),
			str_grad = make([][Phase]f32, len(ATTACK_STRENGTH)),
			scl_grad = make([][Phase]f32, len(SHELTER_SCALE)),
		}

		threads[i] = thread.create(gradient_worker)
		threads[i].data = &worker_data[i]
		thread.start(threads[i])
	}

	for i in 0..<N_THREADS {
		thread.join(threads[i])
		thread.destroy(threads[i])

		for j in 0..<N_EVAL_TERMS {
			gradient[j][.MG] += worker_data[i].gradient[j][.MG]
			gradient[j][.EG] += worker_data[i].gradient[j][.EG]
		}
		for k in 0..<len(ATTACK_STRENGTH) {
			str_grad[k][.MG] += worker_data[i].str_grad[k][.MG]
			str_grad[k][.EG] += worker_data[i].str_grad[k][.EG]
		}
		for k in 0..<len(SHELTER_SCALE) {
			scl_grad[k][.MG] += worker_data[i].scl_grad[k][.MG]
			scl_grad[k][.EG] += worker_data[i].scl_grad[k][.EG]
		}

		delete(worker_data[i].gradient)
		delete(worker_data[i].str_grad)
		delete(worker_data[i].scl_grad)
	}
}

update_single_gradient :: proc(
	entry: ^TunerEntry,
	gradient: ^[][Phase]f32,
	str_grad: ^[][Phase]f32,
	scl_grad: ^[][Phase]f32,
	params: [][Phase]f32,
	str_params: [][Phase]f32,
	scale_params: [][Phase]f32,
	types: []TermType,
	K: f32,
) {
	data: GradientData

	E := linear_evaluation(entry, params, str_params, scale_params, types, &data)
	S := sigmoid(K, E)
	X := (entry.result - S) * S * (1 - S)

	mg_base := X * entry.mg_factor
	eg_base := X * entry.eg_factor

	w_mg_lo := int(data.units[.White][.MG]); w_mg_frac := data.units[.White][.MG] - f32(w_mg_lo)
	w_eg_lo := int(data.units[.White][.EG]); w_eg_frac := data.units[.White][.EG] - f32(w_eg_lo)
	b_mg_lo := int(data.units[.Black][.MG]); b_mg_frac := data.units[.Black][.MG] - f32(b_mg_lo)
	b_eg_lo := int(data.units[.Black][.EG]); b_eg_frac := data.units[.Black][.EG] - f32(b_eg_lo)
	shelter_len := len(SHELTER_SCALE)-1
	w_mg_hi := min(w_mg_lo+1, shelter_len)
	w_eg_hi := min(w_eg_lo+1, shelter_len)
	b_mg_hi := min(b_mg_lo+1, shelter_len)
	b_eg_hi := min(b_eg_lo+1, shelter_len)

	// Attack strength finite differences (chain rule through table index)
	str_diff_w_mg := attack_strength(w_mg_hi, str_params, .MG) - attack_strength(w_mg_lo, str_params, .MG)
	str_diff_b_mg := attack_strength(b_mg_hi, str_params, .MG) - attack_strength(b_mg_lo, str_params, .MG)
	str_diff_w_eg := attack_strength(w_eg_hi, str_params, .EG) - attack_strength(w_eg_lo, str_params, .EG)
	str_diff_b_eg := attack_strength(b_eg_hi, str_params, .EG) - attack_strength(b_eg_lo, str_params, .EG)

	// Shelter scale slopes at each index, per phase
	// "at_w" = slope at the White attack index; "at_b" = slope at the Black attack index
	scl_mg_at_w := (shield_scale(w_mg_hi, scale_params, .MG) - shield_scale(w_mg_lo, scale_params, .MG)) / f32(TAPER_SCALE)
	scl_mg_at_b := (shield_scale(b_mg_hi, scale_params, .MG) - shield_scale(b_mg_lo, scale_params, .MG)) / f32(TAPER_SCALE)
	scl_eg_at_w := (shield_scale(w_eg_hi, scale_params, .EG) - shield_scale(w_eg_lo, scale_params, .EG)) / f32(TAPER_SCALE)
	scl_eg_at_b := (shield_scale(b_eg_hi, scale_params, .EG) - shield_scale(b_eg_lo, scale_params, .EG)) / f32(TAPER_SCALE)

	w_safety_mg := data.safety[.White][.MG]
	b_safety_mg := data.safety[.Black][.MG]
	w_safety_eg := data.safety[.White][.EG]
	b_safety_eg := data.safety[.Black][.EG]

	// Precompute scales for the shelter weight gradient
	w_scale_mg := ((1-b_mg_frac)*shield_scale(b_mg_lo, scale_params, .MG) + b_mg_frac*shield_scale(b_mg_hi, scale_params, .MG)) / f32(TAPER_SCALE)
	b_scale_mg := ((1-w_mg_frac)*shield_scale(w_mg_lo, scale_params, .MG) + w_mg_frac*shield_scale(w_mg_hi, scale_params, .MG)) / f32(TAPER_SCALE)
	w_scale_eg := ((1-b_eg_frac)*shield_scale(b_eg_lo, scale_params, .EG) + b_eg_frac*shield_scale(b_eg_hi, scale_params, .EG)) / f32(TAPER_SCALE)
	b_scale_eg := ((1-w_eg_frac)*shield_scale(w_eg_lo, scale_params, .EG) + w_eg_frac*shield_scale(w_eg_hi, scale_params, .EG)) / f32(TAPER_SCALE)

	for n in 0..<entry.n_tuples {
		i := entry.tuples[n].idx
		cw := f32(entry.tuples[n].w_coeff)
		cb := f32(entry.tuples[n].b_coeff)

		switch types[i] {
		case .Normal:
			gradient[i][.MG] += mg_base * (cw - cb)
			gradient[i][.EG] += eg_base * (cw - cb)
		case .Safety:
			gradient[i][.MG] += mg_base * (cw*w_scale_mg - cb*b_scale_mg)
			gradient[i][.EG] += eg_base * (cw*w_scale_eg - cb*b_scale_eg)
		case .Attack:
			// params[i][.MG] affects mg attack units → chain through mg safety and attack strength
			gradient[i][.MG] += mg_base * (
				cw * (str_diff_w_mg - b_safety_mg*scl_mg_at_w) +
				cb * (-str_diff_b_mg + w_safety_mg*scl_mg_at_b))
			// params[i][.EG] affects eg attack units → chain through eg safety and attack strength
			gradient[i][.EG] += eg_base * (
				cw * (str_diff_w_eg - b_safety_eg*scl_eg_at_w) +
				cb * (-str_diff_b_eg + w_safety_eg*scl_eg_at_b))
		}
	}

	// ATTACK_STRENGTH gradient
	str_grad[w_mg_lo  ][.MG] += mg_base * (1-w_mg_frac)
	str_grad[w_mg_hi  ][.MG] += mg_base * w_mg_frac
	str_grad[b_mg_lo  ][.MG] -= mg_base * (1-b_mg_frac)
	str_grad[b_mg_hi  ][.MG] -= mg_base * b_mg_frac
	str_grad[w_eg_lo  ][.EG] += eg_base * (1-w_eg_frac)
	str_grad[w_eg_hi  ][.EG] += eg_base * w_eg_frac
	str_grad[b_eg_lo  ][.EG] -= eg_base * (1-b_eg_frac)
	str_grad[b_eg_hi  ][.EG] -= eg_base * b_eg_frac

	// SHELTER_SCALE gradient
	// MG: White's shelter MG scale (depends on b_mg_lo); Black's (depends on w_mg_lo)
	scl_grad[b_mg_lo  ][.MG] += mg_base * w_safety_mg * (1-b_mg_frac) / f32(TAPER_SCALE)
	scl_grad[b_mg_hi  ][.MG] += mg_base * w_safety_mg * b_mg_frac     / f32(TAPER_SCALE)
	scl_grad[w_mg_lo  ][.MG] -= mg_base * b_safety_mg * (1-w_mg_frac) / f32(TAPER_SCALE)
	scl_grad[w_mg_hi  ][.MG] -= mg_base * b_safety_mg * w_mg_frac     / f32(TAPER_SCALE)
	// EG: White's shelter EG scale (depends on b_eg_lo); Black's (depends on w_eg_lo)
	scl_grad[b_eg_lo  ][.EG] += eg_base * w_safety_eg * (1-b_eg_frac) / f32(TAPER_SCALE)
	scl_grad[b_eg_hi  ][.EG] += eg_base * w_safety_eg * b_eg_frac     / f32(TAPER_SCALE)
	scl_grad[w_eg_lo  ][.EG] -= eg_base * b_safety_eg * (1-w_eg_frac) / f32(TAPER_SCALE)
	scl_grad[w_eg_hi  ][.EG] -= eg_base * b_safety_eg * w_eg_frac     / f32(TAPER_SCALE)
}

tuned_evaluation_errors :: proc(
	entries: []TunerEntry,
	params: [][Phase]f32,
	str_params: [][Phase]f32,
	scale_params: [][Phase]f32,
	types: []TermType,
	K: f32,
) -> f32 {
	n := len(entries)
	chunk := n / N_THREADS

	worker_data := make([]WorkerData, N_THREADS)
	defer delete(worker_data)
	threads: [N_THREADS]^thread.Thread

	for i in 0..<N_THREADS {
		start := i * chunk
		end := start + chunk if i < N_THREADS - 1 else n

		worker_data[i] = WorkerData{
			entries = entries[start:end],
			params = params,
			str_params = str_params,
			scale_params = scale_params,
			types = types,
			K = K,
		}

		threads[i] = thread.create(error_worker)
		threads[i].data = &worker_data[i]
		thread.start(threads[i])
	}

	total: f32
	for i in 0..<N_THREADS {
		thread.join(threads[i])
		thread.destroy(threads[i])
		total += worker_data[i].error
	}

	return total / f32(n)
}

when TUNING {
@(test)
tuner_trace_equivalence :: proc(t: ^testing.T) {
	types := build_eval_types()
	base_params := make([][Phase]f32, N_EVAL_TERMS)
	params := make([][Phase]f32, N_EVAL_TERMS)
	str_params := make([][Phase]f32, len(ATTACK_STRENGTH))
	scale_params := make([][Phase]f32, len(SHELTER_SCALE))
	defer delete(base_params)
	defer delete(params)
	defer delete(str_params)
	defer delete(scale_params)

	init_base_params(base_params)

	expect_score :: proc(
		t: ^testing.T,
		name: string,
		got: [Phase]f32,
		want: Score,
		fen: string,
	) -> bool {
		got_mg := int(math.round(f64(got[.MG])))
		got_eg := int(math.round(f64(got[.EG])))
		want_mg := int(score_mg(want))
		want_eg := int(score_eg(want))

		if got_mg == want_mg && got_eg == want_eg {
			return true
		}

		return testing.expect(
			t,
			false,
			fmt.tprintf(
				"{} trace mismatch: got S({},{}) want S({},{}) for {}",
				name,
				got_mg,
				got_eg,
				want_mg,
				want_eg,
				fen,
			),
		)
	}

	for fen in BENCH_FENS {
		position, ok := parse_fen(fen)
		if !testing.expect(t, ok, fmt.tprintf("failed to parse FEN: {}", fen)) {
			return
		}

		entry: TunerEntry
		init_entry(&entry, &position, types)

		normal: [Phase]f32
		safety_by_colour: [Colour][Phase]f32
		attack_by_colour: [Colour][Phase]f32
		defer delete(entry.tuples)
		defer delete(position.history)

		for n in 0..<entry.n_tuples {
			tuple := entry.tuples[n]
			i := tuple.idx
			cw := f32(tuple.w_coeff)
			cb := f32(tuple.b_coeff)

			switch types[i] {
			case .Normal:
				normal[.MG] += (cw - cb) * base_params[i][.MG]
				normal[.EG] += (cw - cb) * base_params[i][.EG]
			case .Safety:
				safety_by_colour[.White][.MG] += cw * base_params[i][.MG]
				safety_by_colour[.White][.EG] += cw * base_params[i][.EG]
				safety_by_colour[.Black][.MG] += cb * base_params[i][.MG]
				safety_by_colour[.Black][.EG] += cb * base_params[i][.EG]
			case .Attack:
				attack_by_colour[.White][.MG] += cw * base_params[i][.MG]
				attack_by_colour[.White][.EG] += cw * base_params[i][.EG]
				attack_by_colour[.Black][.MG] += cb * base_params[i][.MG]
				attack_by_colour[.Black][.EG] += cb * base_params[i][.EG]
			}
		}

		if !expect_score(t, "normal", normal, entry.normal, fen) do return
		if !expect_score(t, "white safety", safety_by_colour[.White], entry.safety[.White], fen) do return
		if !expect_score(t, "black safety", safety_by_colour[.Black], entry.safety[.Black], fen) do return
		if !expect_score(t, "white attack", attack_by_colour[.White], entry.attack[.White], fen) do return
		if !expect_score(t, "black attack", attack_by_colour[.Black], entry.attack[.Black], fen) do return

		data: GradientData
		reconstructed := linear_evaluation(
			&entry,
			params,
			str_params,
			scale_params,
			types[:],
			&data,
		)
		diff := abs(reconstructed - f32(entry.static_eval))
		if !testing.expect(
			t,
			diff <= 3,
			fmt.tprintf(
				"zero-delta tuner eval mismatch: got {:.2f} want {} diff {:.2f} for {}",
				reconstructed,
				entry.static_eval,
				diff,
				fen,
			),
		) {
			return
		}

	}
}
}


print_params :: proc(
	params: [][Phase]f32,
	c_params: [][Phase]f32,
	str_params: [][Phase]f32,
	scale_params: [][Phase]f32,
	path: string,
	timestamp: string,
) {
	b: strings.Builder
	strings.builder_init(&b)
	defer strings.builder_destroy(&b)

	val :: proc(params, c_params: [][Phase]f32, i: int, p: Phase) -> int {
		return int(math.round(f64(c_params[i][p] + params[i][p])))
	}

	s :: proc(b: ^strings.Builder, mg, eg: int) {
		fmt.sbprintf(b, "S(%d,%d)", mg, eg)
	}

	print_scalar :: proc(b: ^strings.Builder, name: string, params, c_params: [][Phase]f32, idx: ^int) {
		mg := int(math.round(f64(c_params[idx^][.MG] + params[idx^][.MG])))
		eg := int(math.round(f64(c_params[idx^][.EG] + params[idx^][.EG])))
		fmt.sbprintfln(b, "{} := S(%d,%d)", name, mg, eg)
		idx^ += 1
	}

	print_mobility :: proc(b: ^strings.Builder, name: string, n: int, params, c_params: [][Phase]f32, idx: ^int) {
		fmt.sbprintfln(b, "\n{} := [{}]Score{{", name, n)
		fmt.sbprint(b, "	")
		for i in 0..<n {
			mg := int(math.round(f64(c_params[idx^][.MG] + params[idx^][.MG])))
			eg := int(math.round(f64(c_params[idx^][.EG] + params[idx^][.EG])))
			fmt.sbprintf(b, "S(%d,%d),", mg, eg)
			if (i + 1) % 5 == 0 && i < n-1 do fmt.sbprint(b, "\n	")
			idx^ += 1
		}
		fmt.sbprintln(b, "\n}")
	}

	idx := 0

	fmt.sbprintfln(&b, "// Generated on {}", timestamp)

	mg := val(params, c_params, idx, .MG)
	eg := val(params, c_params, idx, .EG)
	fmt.sbprintfln(&b, "\nTEMPO_BONUS := S(%d,%d)", mg, eg)
	idx += size_of(type_of(Coeffs{}.tempo)) / TERM_SIZE

	fmt.sbprintln(&b, "\npiece_score: [PieceType]Score = {")
	for piece in PieceType {
		mg := val(params, c_params, idx, .MG)
		eg := val(params, c_params, idx, .EG)
		fmt.sbprintf(&b, "	  .{} = ", piece)
		s(&b, mg, eg)
		fmt.sbprintln(&b, ",")
		idx += 1
	}
	fmt.sbprintln(&b, "}")

	piece_names := [PieceType]string{
		.Pawn="pawn_tbl", .Knight="knight_tbl", .Bishop="bishop_tbl",
		.Rook="rook_tbl", .Queen="queen_tbl", .King="king_tbl",
	}
	for piece in PieceType {
		fmt.sbprintfln(&b, "\n{}: [64]Score = {{", piece_names[piece])
		for sq in 0..<64 {
			if sq % 8 == 0 do fmt.sbprint(&b, "    ")
			mg := val(params, c_params, idx, .MG)
			eg := val(params, c_params, idx, .EG)
			s(&b, mg, eg)
			fmt.sbprint(&b, ", " if sq % 8 < 7 else ",\n")
			idx += 1
		}
		fmt.sbprintln(&b, "}")
	}

	fmt.sbprintln(&b)
	print_scalar(&b, "ISOLATED_PAWN", params, c_params, &idx)
	print_scalar(&b, "BACKWARD_PAWN", params, c_params, &idx)
	print_scalar(&b, "CONNECTED_PAWN", params, c_params, &idx)

	fmt.sbprint(&b, "\nSTACKED_PAWN: [5]Score = {")
	for _ in 0..<5 {
		mg := val(params, c_params, idx, .MG)
		eg := val(params, c_params, idx, .EG)
		s(&b, mg, eg); fmt.sbprint(&b, ", ")
		idx += 1
	}
	fmt.sbprintln(&b, "}")

	print_scalar(&b, "ISOLATED_DOUBLED", params, c_params, &idx)

	fmt.sbprint(&b, "\nPASSED_PAWN := [8]Score{")
	for _ in 0..<8 {
		mg := val(params, c_params, idx, .MG)
		eg := val(params, c_params, idx, .EG)
		s(&b, mg, eg); fmt.sbprint(&b, ", ")
		idx += 1
	}
	fmt.sbprintln(&b, "}")

	fmt.sbprint(&b, "\nCONNECTED_PASSED_PAWN := [8]Score{")
	for _ in 0..<8 {
		mg := val(params, c_params, idx, .MG)
		eg := val(params, c_params, idx, .EG)
		s(&b, mg, eg); fmt.sbprint(&b, ", ")
		idx += 1
	}
	fmt.sbprintln(&b, "}")

	print_scalar(&b, "BISHOP_PAIR",			 params, c_params, &idx)
	print_scalar(&b, "ROOK_OPEN_FILE",		 params, c_params, &idx)
	print_scalar(&b, "ROOK_SEMI_OPEN_FILE",  params, c_params, &idx)

	print_mobility(&b, "KNIGHT_MOBILITY", len(KNIGHT_MOBILITY), params, c_params, &idx)
	print_mobility(&b, "BISHOP_MOBILITY", len(BISHOP_MOBILITY), params, c_params, &idx)
	print_mobility(&b, "ROOK_MOBILITY",   len(ROOK_MOBILITY),	params, c_params, &idx)
	print_mobility(&b, "QUEEN_MOBILITY",  len(QUEEN_MOBILITY),	params, c_params, &idx)

	fmt.sbprintln(&b, "\nPAWN_SHIELD := [2][6][8]Score{")
	for _ in 0..<2 {
		fmt.sbprintln(&b, "    {")
		for _ in 0..<6 {
			fmt.sbprint(&b, "		 { ")
			for _ in 0..<8 {
				mg := val(params, c_params, idx, .MG)
				eg := val(params, c_params, idx, .EG)
				s(&b, mg, eg); fmt.sbprint(&b, ", ")
				idx += 1
			}
			fmt.sbprintln(&b, "},")
		}
		fmt.sbprintln(&b, "    },")
	}
	fmt.sbprintln(&b, "}")

	fmt.sbprintln(&b, "\nPAWN_STORM := [2][6][8]Score{")
	for _ in 0..<2 {
		fmt.sbprintln(&b, "    {")
		for _ in 0..<6 {
			fmt.sbprint(&b, "		 { ")
			for _ in 0..<8 {
				mg := val(params, c_params, idx, .MG)
				eg := val(params, c_params, idx, .EG)
				s(&b, mg, eg); fmt.sbprint(&b, ", ")
				idx += 1
			}
			fmt.sbprintln(&b, "},")
		}
		fmt.sbprintln(&b, "    },")
	}
	fmt.sbprintln(&b, "}")

	fmt.sbprintln(&b, "\nSHIELD_GAP := [2][2]Score{")
	for _ in 0..<2 {
		fmt.sbprint(&b, "	 { ")
		for _ in 0..<2 {
			mg := val(params, c_params, idx, .MG)
			eg := val(params, c_params, idx, .EG)
			s(&b, mg, eg); fmt.sbprint(&b, ", ")
			idx += 1
		}
		fmt.sbprintln(&b, "},")
	}
	fmt.sbprintln(&b, "}")

	fmt.sbprint(&b, "\nDEFENDERS: [12]Score = {\n")
	for i in 0..<12 {
		if i % 6 == 0 do fmt.sbprint(&b, "	  ")
		mg := val(params, c_params, idx, .MG)
		eg := val(params, c_params, idx, .EG)
		s(&b, mg, eg); fmt.sbprint(&b, ", ")
		if (i + 1) % 6 == 0 do fmt.sbprintln(&b)
		idx += 1
	}
	fmt.sbprintln(&b, "}")

	fmt.sbprintln(&b, "\nATTACK_UNITS: [PieceType]Score = {")
	for piece in PieceType {
		mg := int(math.round(f64(c_params[idx][.MG] + params[idx][.MG])))
		eg := int(math.round(f64(c_params[idx][.EG] + params[idx][.EG])))
		fmt.sbprintf(&b, "    .{} = ", piece)
		s(&b, mg, eg)
		fmt.sbprintln(&b, ",")
		idx += 1
	}
	fmt.sbprintln(&b, "}")

	{
		mg := int(math.round(f64(c_params[idx][.MG] + params[idx][.MG])))
		eg := int(math.round(f64(c_params[idx][.EG] + params[idx][.EG])))
		fmt.sbprintf(&b, "\nBISHOP_BATTERY_UNITS := "); s(&b, mg, eg); fmt.sbprintln(&b); idx += 1
	}
	{
		mg := int(math.round(f64(c_params[idx][.MG] + params[idx][.MG])))
		eg := int(math.round(f64(c_params[idx][.EG] + params[idx][.EG])))
		fmt.sbprintf(&b, "ROOK_BATTERY_UNITS   := "); s(&b, mg, eg); fmt.sbprintln(&b); idx += 1
	}
	{
		mg := int(math.round(f64(c_params[idx][.MG] + params[idx][.MG])))
		eg := int(math.round(f64(c_params[idx][.EG] + params[idx][.EG])))
		fmt.sbprintf(&b, "QUEEN_BATTERY_UNITS  := "); s(&b, mg, eg); fmt.sbprintln(&b); idx += 1
	}

	fmt.sbprintfln(&b, "\nATTACK_STRENGTH: [{}]Score = {{", len(ATTACK_STRENGTH))
	for k in 0..<len(ATTACK_STRENGTH) {
		if k % 8 == 0 do fmt.sbprint(&b, "	  ")
		mg := int(math.round(f64(score_mg(ATTACK_STRENGTH[k])) + f64(str_params[k][.MG])))
		eg := int(math.round(f64(score_eg(ATTACK_STRENGTH[k])) + f64(str_params[k][.EG])))
		s(&b, mg, eg); fmt.sbprint(&b, ", ")
		if (k + 1) % 8 == 0 do fmt.sbprintln(&b)
	}
	fmt.sbprintln(&b, "}")

	fmt.sbprintfln(&b, "\nSHELTER_SCALE: [{}]Score = {{", len(SHELTER_SCALE))
	for k in 0..<len(SHELTER_SCALE) {
		if k % 8 == 0 do fmt.sbprint(&b, "	  ")
		mg := int(math.round(f64(score_mg(SHELTER_SCALE[k])) + f64(scale_params[k][.MG])))
		eg := int(math.round(f64(score_eg(SHELTER_SCALE[k])) + f64(scale_params[k][.EG])))
		s(&b, mg, eg); fmt.sbprint(&b, ", ")
		if (k + 1) % 8 == 0 do fmt.sbprintln(&b)
	}
	fmt.sbprintln(&b, "}")

	if werr := os.write_entire_file(path, strings.to_string(b)); werr != nil {
		fmt.println("warning: could not write weights: {}", werr)
	}
}
