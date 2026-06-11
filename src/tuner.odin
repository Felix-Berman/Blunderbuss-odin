package blunderbuss

import "core:os"
import "core:strings"
import "core:math"
import "core:fmt"
import "core:reflect"
import "core:thread"
import "core:math/rand"
import "core:time"
import "core:time/timezone"
import "core:testing"

TUNING :: #config(TUNING, false)

EVAL_WEIGHTS_PATH :: "src/eval_weights.odin"
TUNING_DATASET :: "training_sets/quiet-labeled.epd"

N_THREADS :: 8
K_PRECISION :: 10
BATCH_SIZE :: 16384
MAX_EPOCHS :: 100_000
LR_RATE :: 1
LR_MIN :: 0.1
LR_STEP_RATE :: 250
LR_DROP_RATE :: 1.1
REPORTING_RATE :: 20

TunerTuple :: struct { idx, w_coeff, b_coeff: int }

TunerEntry :: struct {
	static_eval: int,
	normal: Score,
	result: f32,
	mg_factor: f32,
	eg_factor: f32,
	tuples: []TunerTuple,
}

WorkerData :: struct {
	entries: []TunerEntry,
	params: [][Phase]f32,
	K: f32,
	gradient: [][Phase]f32,
	error: f32,
}

delete_entries :: proc(entries: []TunerEntry) {
	for &entry in entries {
		delete(entry.tuples)
	}
}

run_tuner :: proc() {
	params := make([][Phase]f32, N_EVAL_TERMS); defer delete(params)
	adagrad := make([][Phase]f32, N_EVAL_TERMS); defer delete(adagrad)
	c_params := make([][Phase]f32, N_EVAL_TERMS); defer delete(c_params)
	init_base_params(c_params)
	error: f32
	rate: f32 = LR_RATE

	entries_dyn := init_entries()
	defer delete_entries(entries_dyn[:])
	defer delete(entries_dyn)
	entries := entries_dyn[:]
	K := compute_optimal_K(&entries)

	n_batches := (len(entries) + BATCH_SIZE - 1) / BATCH_SIZE

	now := time.now()
	utc_offset := 10 * 60 * 60 // default to AEST
	if tz, tz_ok := timezone.region_load("local"); tz_ok {
		utc_offset = int(tz.rrule.std_offset)
	}
	local_now := time.time_add(now, time.Duration(utc_offset) * time.Second)

	date_buf: [time.MIN_YYYY_DATE_LEN]u8
	date := time.to_string_yyyy_mm_dd(local_now, date_buf[:])
	hour, minute, _ := time.clock(local_now)
	timestamp := fmt.tprintf("{}_{}-{}", date, hour, minute)
	os.make_directory("tuner_log")
	log_path	 := fmt.tprintf("tuner_log/{}_tuner.log", timestamp)
	weights_path := fmt.tprintf("tuner_log/{}_weights.txt", timestamp)

	log_file, log_err := os.create(log_path)
	if log_err != nil {
		fmt.eprintfln("Failed to create log file {}: {}", log_path, log_err)
		return
	}
	defer os.close(log_file)

	header := fmt.tprintfln(
		"K={:.4f}  positions={}  batch_size={}	n_batches={}  epochs={}",
		K, len(entries), BATCH_SIZE, n_batches, MAX_EPOCHS,
	)
	fmt.print(header)
	if _, werr := os.write_string(log_file, header); werr != nil {
		fmt.eprintfln("warning: failed to write to log: {}", werr)
	}

	// prevent overfitting to batch order
	rand.shuffle(entries[:])

	fmt.println("Starting tuning...")
	for epoch in 0..<MAX_EPOCHS {
		for batch in 0..<n_batches {
			gradient := make([][Phase]f32, N_EVAL_TERMS)
			defer delete(gradient)

			batch_start := batch * BATCH_SIZE
			batch_end := min(batch_start + BATCH_SIZE, len(entries))
			compute_gradient(entries[batch_start:batch_end], &gradient, params, K)
			batch_size_f := f32(batch_end - batch_start)

			for i in 0..<N_EVAL_TERMS {
				adagrad[i][.MG] += math.pow((K / 200) * gradient[i][.MG] / batch_size_f, 2)
				adagrad[i][.EG] += math.pow((K / 200) * gradient[i][.EG] / batch_size_f, 2)

				params[i][.MG] += (K / 200) * (gradient[i][.MG] / batch_size_f) *
					(rate / math.sqrt(1e-8 + adagrad[i][.MG]))
				params[i][.EG] += (K / 200) * (gradient[i][.EG] / batch_size_f) *
					(rate / math.sqrt(1e-8 + adagrad[i][.EG]))
			}

			enforce_parameter_constraints(params, c_params)
		}

		error = tuned_evaluation_errors(entries, params, K)

		lr_dropped := epoch != 0 && epoch % LR_STEP_RATE == 0
		if lr_dropped do rate /= LR_DROP_RATE

		rate = max(rate, LR_MIN)

		line := fmt.tprintfln(
			"epoch {:4d} | error {:.6f} | rate {:.4f}{}",
			epoch, error, rate,
			" [lr drop]" if lr_dropped else "",
		)
		fmt.print(line)
		if _, werr := os.write_string(log_file, line); werr != nil {
			fmt.eprintfln("warning: failed to write to log: {}", werr)
		}

		if epoch % REPORTING_RATE == 0 {
			enforce_parameter_constraints(params, c_params)
			print_params(params, c_params, weights_path, timestamp)
		}

		rand.shuffle(entries[:])
	}

	enforce_parameter_constraints(params, c_params)
	print_params(params, c_params, weights_path, timestamp)
	print_params(params, c_params, EVAL_WEIGHTS_PATH, timestamp)
}

gradient_worker :: proc(t: ^thread.Thread) {
	data := (^WorkerData)(t.data)

	for i in 0..<len(data.entries) {
		update_single_gradient(
			&data.entries[i],
			&data.gradient,
			data.params,
			data.K,
		)
	}
}

error_worker :: proc(t: ^thread.Thread) {
	data := (^WorkerData)(t.data)
	data.error = 0

	for i in 0..<len(data.entries) {
		E := linear_evaluation(
			&data.entries[i],
			data.params,
		)
		diff := data.entries[i].result - sigmoid(data.K, E)
		data.error += diff * diff
	}
}

static_error_worker :: proc(t: ^thread.Thread) {
	data := (^WorkerData)(t.data)
	data.error = 0

	for i in 0..<len(data.entries) {
		entry := data.entries[i]
		diff := entry.result - sigmoid(data.K, f32(entry.static_eval))
		data.error += diff * diff
	}
}

enforce_parameter_constraints :: proc(params, c_params: [][Phase]f32) {
	material_start := int(offset_of(Coeffs, material) / TERM_SIZE)
	psqt_start := int(offset_of(Coeffs, piece_sq_tbls) / TERM_SIZE)
	pawn_material_idx := material_start + int(PieceType.Pawn)
	mobility_start := int(offset_of(Coeffs, knight_mobility) / TERM_SIZE)

	// maintain centipawn relative eval
	params[pawn_material_idx][.MG] = 0
	params[pawn_material_idx][.EG] = 0

	for piece in PieceType {
		table_start := psqt_start + int(piece) * 64
		material_idx := material_start + int(piece)

		mobility_len := 0
		#partial switch piece {
			case .Knight: mobility_len = KNIGHT_MOBILITY_COUNT
			case .Bishop: mobility_len = BISHOP_MOBILITY_COUNT
			case .Rook:   mobility_len = ROOK_MOBILITY_COUNT
			case .Queen:  mobility_len = QUEEN_MOBILITY_COUNT
		}

		for p in Phase {
			psqt_mean, mobility_mean: f32

			for sq in 0..<64 {
				if piece == .Pawn && (sq < 8 || sq >= 56) do continue
				idx := table_start + sq
				psqt_mean += c_params[idx][p] + params[idx][p]
			}
			psqt_mean /= 48 if piece == .Pawn else 64

			for sq in 0..<64 {
				if piece == .Pawn && (sq < 8 || sq >= 56) do continue
				params[table_start + sq][p] -= psqt_mean
			}

			for i in 0..<mobility_len {
				idx := mobility_start + i
				mobility_mean += c_params[idx][p] + params[idx][p]
			}
			mobility_mean /= f32(mobility_len)

			for i in 0..<mobility_len {
				idx := mobility_start + i
				params[idx][p] -= mobility_mean
			}

			// Keep non-pawn material values equal to the average piece value.
			// Pawn material is the fixed centipawn anchor; king material cancels.
			if piece != .Pawn && piece != .King {
				params[material_idx][p] += psqt_mean + mobility_mean
			}
		}

		mobility_start += mobility_len
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

	material_start := int(offset_of(Coeffs, material) / TERM_SIZE)
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
				fmt.tprintf("{} {} PSQT mean is not zero: {}", piece, p, sum / 48),
			) {
				return
			}
		}
	}
}

init_base_params :: proc(c_params: [][Phase]f32) {
	base := (cast(^[N_EVAL_TERMS]Score)&eval_weights)^

	for score, idx in base {
		c_params[idx][.MG] = f32(score_mg(score))
		c_params[idx][.EG] = f32(score_eg(score))
	}
}

init_tuples :: proc(
	entry: ^TunerEntry,
	coeffs: [N_EVAL_TERMS][Colour]int,
) {
	length, tuple_idx: int

	for i in 0..< N_EVAL_TERMS {
		if coeffs[i][.White] != coeffs[i][.Black] do length += 1
	}

	entry.tuples = make([]TunerTuple, length)

	for i in 0..< N_EVAL_TERMS {
		w_coeff := coeffs[i][.White]
		b_coeff := coeffs[i][.Black]
		if w_coeff != b_coeff {
			entry.tuples[tuple_idx] = TunerTuple{i, w_coeff, b_coeff}
			tuple_idx += 1
		}
	}
}

init_entry :: proc(
	entry: ^TunerEntry,
	position: ^Position,
) {
	coeffs: [N_EVAL_TERMS][Colour]int

	phase := piece_phase[.Knight] * pop_count(piece_bb(position, .Knight))
	phase += piece_phase[.Bishop] * pop_count(piece_bb(position, .Bishop))
	phase += piece_phase[.Rook] * pop_count(piece_bb(position, .Rook))
	phase += piece_phase[.Queen] * pop_count(piece_bb(position, .Queen))
	phase = clamp(phase, 0, 24)

	entry.mg_factor = f32(phase) / 24
	entry.eg_factor = f32(24 - phase) / 24

	entry.static_eval = evaluate(position)
	if position.turn == .Black { // Tuning is white relative
		entry.static_eval = -entry.static_eval
	}

	coeffs = (cast(^[N_EVAL_TERMS][Colour]int)&trace.coeffs)^
	init_tuples(entry, coeffs)

	entry.normal = trace.normal
}

init_entries :: proc() -> (entries: [dynamic]TunerEntry) {
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
		
		init_entry(&entry, &position)
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

linear_evaluation :: proc(
	entry: ^TunerEntry,
	params: [][Phase]f32,
) -> f32 {
	mixed, midgame, endgame: f32
	mg_delta, eg_delta: f32

	for tuple in entry.tuples {
		i := tuple.idx
		coeff := f32(tuple.w_coeff - tuple.b_coeff)
		mg_delta += coeff * params[i][.MG]
		eg_delta += coeff * params[i][.EG]
	}

	// add delta to normal eval
	midgame = f32(score_mg(entry.normal)) + mg_delta
	endgame = f32(score_eg(entry.normal)) + eg_delta

	mixed = midgame * entry.mg_factor + endgame * entry.eg_factor

	return mixed
}

compute_gradient :: proc(
	batch: []TunerEntry,
	gradient: ^[][Phase]f32,
	params: [][Phase]f32,
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
			K = K,
			gradient = make([][Phase]f32, N_EVAL_TERMS),
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

		delete(worker_data[i].gradient)
	}
}

update_single_gradient :: proc(
	entry: ^TunerEntry,
	gradient: ^[][Phase]f32,
	params: [][Phase]f32,
	K: f32,
) {

	E := linear_evaluation(entry, params)
	S := sigmoid(K, E)
	X := (entry.result - S) * S * (1 - S)

	mg_base := X * entry.mg_factor
	eg_base := X * entry.eg_factor

	for tuple in entry.tuples {
		i := tuple.idx
		coeff := f32(tuple.w_coeff - tuple.b_coeff)

		gradient[i][.MG] += mg_base * coeff
		gradient[i][.EG] += eg_base * coeff
	}
}

tuned_evaluation_errors :: proc(
	entries: []TunerEntry,
	params: [][Phase]f32,
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

write_indent :: proc(b: ^strings.Builder, indent: int) {
	for _ in 0..<indent {
		fmt.sbprint(b, "\t")
	}
}

enum_name_for_value :: proc(info: ^reflect.Type_Info, value: int) -> string {
	if info == nil do return ""

	base := reflect.type_info_base(info)
	if e, ok := base.variant.(reflect.Type_Info_Enum); ok {
		for enum_value, i in e.values {
			if int(enum_value) == value {
				return e.names[i]
			}
		}
	}

	return ""
}

write_tuned_score :: proc(b: ^strings.Builder, values: [][Phase]int, idx: ^int) {
	fmt.sbprintf(b, "S(%d,%d)", values[idx^][.MG], values[idx^][.EG])
	idx^ += 1
}

write_eval_weight_array :: proc(
	b: ^strings.Builder,
	elem: ^reflect.Type_Info,
	count: int,
	values: [][Phase]int,
	idx: ^int,
	indent: int,
	enum_info: ^reflect.Type_Info = nil,
	min_value: int = 0,
) {
	fmt.sbprintln(b, "{")

	if elem.id == typeid_of(Score) {
		if enum_info != nil {
			for i in 0..<count {
				write_indent(b, indent + 1)
				name := enum_name_for_value(enum_info, min_value + i)
				if name != "" do fmt.sbprintf(b, ".{} = ", name)

				write_tuned_score(b, values, idx)
				fmt.sbprintln(b, ",")
			}
		} else {
			for i in 0..<count {
				if i % 8 == 0 do write_indent(b, indent + 1)

				write_tuned_score(b, values, idx)
				fmt.sbprint(b, ",")
				if (i + 1) % 8 == 0 || i == count - 1 {
					fmt.sbprintln(b)
				} else {
					fmt.sbprint(b, " ")
				}
			}
		}
	} else {
		for i in 0..<count {
			write_indent(b, indent + 1)
			if enum_info != nil {
				name := enum_name_for_value(enum_info, min_value + i)
				if name != "" do fmt.sbprintf(b, ".{} = ", name)
			}

			write_eval_weight_value(b, elem, values, idx, indent + 1)
			fmt.sbprintln(b, ",")
		}
	}

	write_indent(b, indent)
	fmt.sbprint(b, "}")
}

write_eval_weight_value :: proc(
	b: ^strings.Builder,
	info: ^reflect.Type_Info,
	values: [][Phase]int,
	idx: ^int,
	indent: int,
) {
	if info.id == typeid_of(Score) {
		write_tuned_score(b, values, idx)
		return
	}

	base := reflect.type_info_base(info)
	#partial switch v in base.variant {
	case reflect.Type_Info_Struct:
		fmt.sbprintln(b, "{")
		for i in 0..<int(v.field_count) {
			write_indent(b, indent + 1)
			fmt.sbprintf(b, "{} = ", v.names[i])
			write_eval_weight_value(b, v.types[i], values, idx, indent + 1)
			fmt.sbprintln(b, ",")
		}
		write_indent(b, indent)
		fmt.sbprint(b, "}")

	case reflect.Type_Info_Array:
		write_eval_weight_array(b, v.elem, v.count, values, idx, indent)

	case reflect.Type_Info_Enumerated_Array:
		write_eval_weight_array(
			b,
			v.elem,
			v.count,
			values,
			idx,
			indent,
			v.index,
			int(v.min_value),
		)

	case:
		panic("unsupported eval weight type")
	}
}

@(test)
eval_weight_writer_covers_all_terms :: proc(t: ^testing.T) {
	values: [N_EVAL_TERMS][Phase]int
	idx := 0

	b: strings.Builder
	strings.builder_init(&b)
	defer strings.builder_destroy(&b)

	write_eval_weight_value(&b, type_info_of(EvalWeights), values[:], &idx, 0)
	testing.expect_value(t, idx, N_EVAL_TERMS)
}

print_params :: proc(
	params: [][Phase]f32,
	c_params: [][Phase]f32,
	path: string,
	timestamp: string,
) {
	b: strings.Builder
	strings.builder_init(&b)
	defer strings.builder_destroy(&b)

	values: [N_EVAL_TERMS][Phase]int
	for i in 0..<N_EVAL_TERMS {
		values[i][.MG] = int(math.round(f64(c_params[i][.MG] + params[i][.MG])))
		values[i][.EG] = int(math.round(f64(c_params[i][.EG] + params[i][.EG])))
	}

	idx := 0
	fmt.sbprintln(&b, "package blunderbuss")
	fmt.sbprintln(&b)
	fmt.sbprintfln(&b, "// Generated on {}", timestamp)
	fmt.sbprintln(&b)
	fmt.sbprint(&b, "eval_weights: EvalWeights = ")
	write_eval_weight_value(&b, type_info_of(EvalWeights), values[:], &idx, 0)
	fmt.sbprintln(&b)

	assert(idx == N_EVAL_TERMS)
	if werr := os.write_entire_file(path, strings.to_string(b)); werr != nil {
		fmt.println("warning: could not write weights: {}", werr)
	}
}
