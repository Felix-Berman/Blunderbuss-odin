package blunderbuss

import "core:fmt"

// lookup tables
SQ_MASKS: [64]SqMasks

init :: proc() {
    SQ_MASKS = init_sq_masks()
}

main :: proc() {
    init()

    position := parse_fen(STARTING_FEN)
    fmt.println(display(position))
}