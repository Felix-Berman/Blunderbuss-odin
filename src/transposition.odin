package blunderbuss

DEFAULT_HASH_SIZE_MB :: 32

t_table: [dynamic]TTableEntry

EvalType :: enum{Exact, UpperBound, LowerBound}

TTableEntry :: struct {
	hash: u64,
	depth: int,
	eval: int,
	eval_type: EvalType,
	best_move: Move,
}

get_ttable_len :: proc(hash_size_mb: int) -> int {
	return hash_size_mb * 1e6 / size_of(TTableEntry)
}

make_ttable :: proc(hash_size_mb: int = DEFAULT_HASH_SIZE_MB) -> [dynamic]TTableEntry {
	len := get_ttable_len(hash_size_mb)
	return make([dynamic]TTableEntry, len)
}

// always insert strategy
ttable_insert :: proc(t_table: [dynamic]TTableEntry, entry: TTableEntry) {
	t_table[uint(entry.hash) % len(t_table)] = entry
}

probe_ttable :: proc(t_table: [dynamic]TTableEntry, zobrist_hash: u64) -> TTableEntry {
	return t_table[uint(zobrist_hash) % len(t_table)]
}
