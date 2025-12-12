package blunderbuss

import "core:fmt"
import "core:mem"

DEFAULT_HASH_SIZE_MB :: 32

TTable :: struct {
	entries: [dynamic]TTableEntry,
	hashfull: int,
}

t_table: TTable

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

make_ttable :: proc(hash_size_mb: int = DEFAULT_HASH_SIZE_MB) -> TTable {
	len := get_ttable_len(hash_size_mb)
	entries := make([dynamic]TTableEntry, len)
	reserve(&entries, len)
	return TTable{entries, 0}
}

resize_ttable :: proc(t_table: ^TTable, hash_size_mb: int) {
	len := get_ttable_len(hash_size_mb)
	err := resize(&t_table.entries, len)
	if err != .None {
		fmt.eprintln("Error:", err)
	}
}

// always insert strategy
ttable_insert :: proc(t_table: ^TTable, entry: TTableEntry) {
	idx := uint(entry.hash) % len(t_table.entries)
	if t_table.entries[idx].hash == 0 {
		t_table.hashfull += 1
	}
	t_table.entries[idx] = entry
}

probe_ttable :: proc(t_table: TTable, zobrist_hash: u64) -> TTableEntry {
	return t_table.entries[uint(zobrist_hash) % len(t_table.entries)]
}

clear_ttable :: proc(t_table: ^TTable) {
	mem.zero_slice(t_table.entries[:])
	t_table.hashfull = 0
}

hashfull :: proc(t_table: TTable) -> int {
	return t_table.hashfull * 1000 / len(t_table.entries)
}
