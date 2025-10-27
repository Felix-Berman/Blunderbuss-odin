package blunderbuss

import "core:fmt"

// lookup tables
SQ_MASKS: [64]SqMasks

init :: proc() {
    SQ_MASKS = init_sq_masks()
}

main :: proc() {
    init()

    position := new_position()
    fmt.println(display(position))

    moves := gen_pseudo_legal_moves(.Black, &position)
    for move in moves {
        fmt.println(display(move))
    }

    fmt.println(len(moves))
}