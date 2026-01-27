import subprocess
import argparse
import os
import sys
import time
import atexit
from pathlib import Path

CWD = Path(os.getcwd())
BUILD_CMD = "odin build src -o:speed -define:PEXT=true"
ENGINE_DIR = CWD / 'versions'
LOG_DIR = CWD / 'sprt_log'
FASTCHESS_CMD = "fastchess" # adjust if not on PATH
OPENING_BOOK = "openings-16ply-100k.pgn"
HASH = 512 #MB

description = "SPRT test automation for the Blunderbuss engine using fastchess.\
    By default it will compare the current worktree to the HEAD of main."

def main():
    timestamp = time.strftime("%Y%m%d_%H")

    os.makedirs(ENGINE_DIR, exist_ok=True)
    os.makedirs(LOG_DIR, exist_ok=True)

    feature_name = args.test_name
    feature_id = timestamp
    feature_worktree = CWD
    if args.feature != None:
        feature_worktree = CWD / "../blunderbuss_temp_feature"
        run_command(f'git worktree add {feature_worktree} {args.feature}')
        feature_id = run_command(f'git rev-parse --short {args.feature}',
                                 cwd=feature_worktree)
        feature_name = args.feature

    log(f'Building {feature_name}_{feature_id} from {feature_worktree}')
    path_feature = ENGINE_DIR / f'{feature_name}_{feature_id}.exe'
    run_command(f'{BUILD_CMD} -out:{path_feature}',
                cwd=feature_worktree)

    base_worktree = CWD / "../blunderbuss_temp_base"
    run_command(f'git worktree add {base_worktree} {args.base}')
    base_hash = run_command(f'git rev-parse --short {args.base}',
                            cwd=base_worktree, shell=False)

    base_name = f'{args.base}_{base_hash}'
    log(f'Building {base_name} from {base_worktree}')
    path_base = ENGINE_DIR / f'{base_name}.exe'
    run_command(f'{BUILD_CMD} -out:{path_base}', cwd=base_worktree)

    log("Starting SPRT Test with Fastchess...")

    pgn_file = LOG_DIR / f"{args.test_name}_{timestamp}.pgn"
    log_file = LOG_DIR / f"{args.test_name}_{timestamp}.log"

    base_name = f'{args.base}({base_hash})'

    fastchess_cmd = [
        FASTCHESS_CMD,
        "-engine", f"name={feature_name}", f"cmd={path_feature}",
        "-engine", f"name={base_name}", f"cmd={path_base}",
        "-each", f"tc=10+0.1", f"option.Hash={HASH}",
        "-sprt", f"elo0=0 elo1=10 alpha=0.05 beta=0.05",
        "-rounds", "4000",
        "-games", "2", # Play pairs (white/black)
        "-concurrency", "8",
        "-openings", f"file={OPENING_BOOK}", "format=pgn", "order=random",
        # "-resign", "movecount=3", "score=400", # Resign if mate is inevitable
        "-draw", "movenumber=40", "movecount=8", "score=10", # Draw adjudication
        "-recover", # Restart engine on crash
        "-pgnout", f"file={pgn_file}", "notation=lan",
        "-event", args.test_name,
        "-config", f"outname={LOG_DIR}/config.json",
        "-log", f"file={log_file}", "level=warn",
        "-use-affinity", "0,2,4,6,8,10,12,14", # P cores on an 8P, 4E core intel cpu
    ]

    cmd_str = " ".join(fastchess_cmd + fastchess_args)

    log(f"Executing: {cmd_str}")

    subprocess.run(cmd_str, cwd=CWD, shell=True, check=True)


def cleanup():
    run_command("git worktree remove ../blunderbuss_temp_base")
    if args.feature:
        run_command("git worktree remove ../blunderbuss_temp_feature")

atexit.register(cleanup)

def run_command(cmd, cwd=CWD, shell=True):
    """Runs a shell command and checks for errors."""
    result = subprocess.run(cmd, cwd=cwd, shell=shell, check=True,
                          capture_output=True, text=True)
    return result.stdout.strip()

def log(msg):
    print(f"\033[96m[SPRT MANAGER] {msg}\033[0m")

def error(msg):
    print(f"\033[91m[ERROR] {msg}\033[0m")
    sys.exit(1)

if __name__ == '__main__':
    try:
        parser = argparse.ArgumentParser(description=description)
        parser.add_argument('test_name', help='short name describing the test')
        parser.add_argument('--base', '-b', default='main',
                            help='commit-ish reference (hash, tag, branch)')
        parser.add_argument('--feature', '-f',
                            help='commit-ish reference (hash, tag, branch)')

        args, fastchess_args = parser.parse_known_args()
        main()
    except KeyboardInterrupt:
        log("Interrupted by user. Cleaning up...")
        sys.exit(0)
    except Exception as e:
        error(f"Error: {e}")
