package blunderbuss

import "base:intrinsics"

piece_scores :[PieceType]int = {.Pawn = 100,
	.Knight = 300,
	.Bishop = 350,
	.Rook = 500,
	.Queen = 900,
	.King = 0
}

eval :: proc(position: ^Position) -> int {
	scores: [Colour]int
	us := position.turn

	for bbs, side in position.pieces {
		for bb, piece in bbs {
			scores[side] += piece_scores[piece] * int(intrinsics.count_ones(bb))
		}
	}

	return scores[us] - scores[toggle(us)]
}
