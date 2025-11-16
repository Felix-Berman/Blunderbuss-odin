import sys
import subprocess

depth = 0
fen = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
moves = ""

if len(sys.argv) > 1:
    depth = sys.argv[1]
if len(sys.argv) > 2:
    fen = sys.argv[2]
if len(sys.argv) > 3:
    moves = ' '.join(sys.argv[3:])

process = subprocess.Popen(
    ["blunderbuss.exe"],
    stdin = subprocess.PIPE,
    stdout = None,
    stderr = None,
)

process.stdin.write(f'position fen "{fen}" moves {moves}\n'.encode())
process.stdin.flush()
process.stdin.write(f"perft {depth}\n".encode())
process.stdin.flush()
process.stdin.write("quit\n".encode())
process.stdin.flush()
process.stdin.close()

process.wait()
