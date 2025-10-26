package blunderbuss

import "core:fmt"

main :: proc() {
    position := new_position()
    print(position)
    print(position.bitboards[.White][.Pawn])
}