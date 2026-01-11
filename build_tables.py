#!/usr/bin/env python3

DIRS = ("N", "S", "E", "W", "NW", "NE", "SW", "SE")
STEPS = {
    "N":  +8, "S": -8,
    "E":  -1, "W": +1,
    "NW": +9, "NE": +7,
    "SW": -7, "SE": -9,
}

U64_MASK       = (1 << 64) - 1
RANK_1         = 0x00000000000000FF
H_FILE         = 0x0101010101010101
MAIN_DIAGONAL  = 0x8040201008040201
MAIN_ANTIDIAG  = 0x0102040810204080

def bit(sq): return 1 << sq
def rank(sq): return sq // 8
def file(sq): return sq % 8

def step(sq, d):
    dr = [1,-1,0,0,1,1,-1,-1][DIRS.index(d)]
    df = [0,0,-1,1,1,-1,1,-1][DIRS.index(d)]
    r, f = rank(sq) + dr, file(sq) + df
    if 0 <= r < 8 and 0 <= f < 8:
        return True, r*8 + f
    return False, -1

def gen_sq_masks():
    masks = [
        {"rank_mask": 0, "file_mask": 0, "diagonal_mask": 0, "antidiag_mask": 0}
        for _ in range(64)
    ]
    for rank in range(8):
        for file in range(8):
            sq = 8 * rank + file

            masks[sq]["rank_mask"] = RANK_1 << (8 * rank)
            masks[sq]["file_mask"] = H_FILE << file

            if rank >= file:
                masks[sq]["diagonal_mask"] = MAIN_DIAGONAL << ((rank - file) * 8)
            else:
                masks[sq]["diagonal_mask"] = MAIN_DIAGONAL >> ((file - rank) * 8)

            if rank + file >= 7:
                masks[sq]["antidiag_mask"] = MAIN_ANTIDIAG << ((rank + file - 7) * 8)
            else:
                masks[sq]["antidiag_mask"] = MAIN_ANTIDIAG >> ((7 - rank - file) * 8)

    return masks

def gen_rays():
    rays = [[0]*len(DIRS) for _ in range(64)]
    for sq in range(64):
        for i, d in enumerate(DIRS):
            b, cur = 0, sq
            while True:
                ok, nxt = step(cur, d)
                if not ok: break
                b |= bit(nxt)
                cur = nxt
            rays[sq][i] = b
    return rays

def gen_between():
    between = [[0]*64 for _ in range(64)]
    for frm in range(64):
        for d in DIRS:
            bb, cur = 0, frm
            while True:
                ok, nxt = step(cur, d)
                if not ok: break
                between[frm][nxt] = bb
                bb |= bit(nxt)
                cur = nxt
    return between

def emit_odin(rays, between, sq_masks):
    out = []
    out.append("package blunderbuss\n\n")

    out.append("RAYS := [64][Direction]u64{\n")
    for sq in range(64):
        row = ",\n".join(
            f"        .{d} = 0x{rays[sq][i]:016x}" for i, d in enumerate(DIRS)
        )
        out.append(f"    {{\n{row}\n    }},\n")
    out.append("}\n\n")

    out.append("BETWEEN := [64][64]u64{\n")
    for frm in range(64):
        row = ",\n".join(f"        0x{between[frm][to]:016x}" for to in range(64))
        out.append(f"    {{\n{row}\n    }},\n")
    out.append("}\n\n")

    out.append("SQ_MASKS := [64]SqMasks{\n")
    for sq in range(64):
        m = sq_masks[sq]
        rank_hex    = f"0x{m['rank_mask'] & U64_MASK:016x}"
        file_hex    = f"0x{m['file_mask'] & U64_MASK:016x}"
        diag_hex    = f"0x{m['diagonal_mask'] & U64_MASK:016x}"
        antidiag_hex= f"0x{m['antidiag_mask'] & U64_MASK:016x}"
        out.append(
            f"    SqMasks{{ {rank_hex}, {file_hex}, {diag_hex}, {antidiag_hex} }},\n"
        )
    out.append("}\n")


    return "".join(out)

if __name__ == "__main__":
    rays = gen_rays()
    between = gen_between()
    sq_masks = gen_sq_masks()

    with open("src/tables.odin", "w") as f:
        f.write(emit_odin(rays, between, sq_masks))

    print("Generated tables")
