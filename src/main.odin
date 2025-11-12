package blunderbuss

import "core:fmt"

// lookup tables

SQ_MASKS := init_sq_masks()

main :: proc() {

    position := parse_fen(STARTING_FEN)

    perft_divide(&position, 2)

    delete(position.irreversible_history)
}