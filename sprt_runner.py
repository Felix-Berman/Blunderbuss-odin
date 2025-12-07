import os
import subprocess
import sys
import shutil
import time

FASTCHESS_PATH = "fastchess" # Requires fastchess on path
BUILD_COMMAND = "odin build src -o:speed -out:blunderbuss.exe"
REPO_PATH = os.getcwd()
OPENING_BOOK = "Balsa_v110221.pgn"
BUILT_BIN_PATH = "blunderbuss.exe"
ARTIFACTS_DIR = "versions"
PGN_OUTPUT_DIR = "sprt_log"

TIME_CONTROL = "10+0.1"
CONCURRENCY = 6
ROUNDS = 2000


def log(msg):
    print(f"\033[96m[SPRT MANAGER] {msg}\033[0m")

def error(msg):
    print(f"\033[91m[ERROR] {msg}\033[0m")
    sys.exit(1)

def run_command(cmd, cwd=None, shell=True):
    """Runs a shell command and checks for errors."""
    try:
        subprocess.run(cmd, cwd=cwd, shell=shell, check=True)
    except subprocess.CalledProcessError as e:
        error(f"Command failed: {cmd}\n{e}")

def get_commit_short_hash(repo_path):
    """Gets the short commit hash (e.g., a1b2c3d) for the current HEAD."""
    result = subprocess.run("git rev-parse --short HEAD", cwd=repo_path, shell=True, capture_output=True, text=True)
    if result.returncode != 0:
        error("Failed to get git commit hash. Ensure git is installed and REPO_PATH is correct.")
    return result.stdout.strip()

def git_checkout(branch):
    """Checks out a specific branch in the repo."""
    log(f"Checking out branch: {branch}...")
    run_command(f"git checkout {branch}", cwd=REPO_PATH)

def build_engine(branch_name, commit_hash):
    """Builds the engine and copies the binary to artifacts."""
    log(f"Building {branch_name}...")

    base_name = os.path.basename(BUILT_BIN_PATH)
    name, ext = os.path.splitext(base_name)
    output_name = f"{name}_{branch_name}({commit_hash}){ext}"

    # 1. Build
    run_command(BUILD_COMMAND, cwd=REPO_PATH)

    # 2. Verify binary exists
    full_bin_path = os.path.join(REPO_PATH, BUILT_BIN_PATH)
    if not os.path.exists(full_bin_path):
        error(f"Build successful, but binary not found at: {full_bin_path}")

    # 3. Copy to engine versions folder
    dest_path = os.path.join(ARTIFACTS_DIR, output_name)
    shutil.copy2(full_bin_path, dest_path)

    log(f"Compiled {branch_name} -> {dest_path}")
    return dest_path

def prepare_artifacts():
    if not os.path.exists(ARTIFACTS_DIR):
        os.makedirs(ARTIFACTS_DIR)

def prepare_pgn_dir():
    os.makedirs(PGN_OUTPUT_DIR, exist_ok=True)

def get_current_branch():
    result = subprocess.run("git branch --show-current", cwd=REPO_PATH, shell=True, capture_output=True, text=True)
    return result.stdout.strip()

def run_sprt(base_bin, new_bin, base_name, feature_name, H0 = 0, H1 = 5):
    """Constructs and executes the fastchess command."""
    log("Starting SPRT Test with Fastchess...")

    prepare_pgn_dir()

    timestamp = time.strftime("%Y%m%d_%H%M%S")
    pgn_filename = os.path.join(
            PGN_OUTPUT_DIR,
            f"sprt_{base_name}_vs_{feature_name}_{timestamp}.pgn"
    )
    log_filename = os.path.join(
            PGN_OUTPUT_DIR,
            f"sprt_{base_name}_vs_{feature_name}_{timestamp}.log"
    )

    # Construct command
    # Fastchess is largely compatible with cutechess syntax but robust
    cmd = [
        FASTCHESS_PATH,
        "-engine", f"name={feature_name}", f"cmd={new_bin}",
        "-engine", f"name={base_name}", f"cmd={base_bin}",
        "-each", f"tc={TIME_CONTROL}",
        # f"option.Hash={HASH_SIZE}",
        "-sprt", f"elo0={H0} elo1={H1} alpha=0.05 beta=0.05",
        "-rounds", str(ROUNDS),
        "-games", "2", # Play pairs (white/black)
        "-concurrency", str(CONCURRENCY),
        "-openings", f"file={OPENING_BOOK}", "format=pgn", "order=random",
        "-resign", "movecount=3", "score=400", # Resign if mate is inevitable
        "-draw", "movenumber=40", "movecount=8", "score=10", # Draw adjudication
        "-recover", # Restart engine on crash
        "-pgnout", f"file={pgn_filename}", "notation=lan", "nodes=true",
        "-config", f"outname={PGN_OUTPUT_DIR}/config.json",
        "-log", f"file={log_filename}",
    ]

    cmd_str = " ".join(cmd)
    log(f"Executing: {cmd_str}")

    # We use Popen to stream stdout so we see the match progress in real time
    process = subprocess.Popen(cmd_str, shell=True, stdout=sys.stdout, stderr=sys.stderr)
    process.wait()

def main():
    if len(sys.argv) < 3:
        print("Usage: python sprt_runner.py <main_branch> <feature_branch> [H0] [H1]")
        sys.exit(1)

    base_branch = sys.argv[1]
    feature_branch = sys.argv[2]

    if len(sys.argv) > 3:
        null_hypothesis = int(sys.argv[3])
    else:
        null_hypothesis = 0
    if len(sys.argv) > 4:
        alt_hypothesis = int(sys.argv[4])
    else:
        alt_hypothesis = 5

    original_branch = get_current_branch()

    try:
        prepare_artifacts()

        # 1. Build Base
        git_checkout(base_branch)
        base_hash = get_commit_short_hash(REPO_PATH)
        base_bin = build_engine(base_branch, base_hash)

        # 2. Build Feature
        git_checkout(feature_branch)
        feature_hash = get_commit_short_hash(REPO_PATH)
        new_bin = build_engine(feature_branch, feature_hash)

        # 3. Restore original branch (politeness)
        git_checkout(original_branch)

        # 4. Run Match
        # We use absolute paths for fastchess to be safe
        run_sprt(os.path.abspath(base_bin), os.path.abspath(new_bin),
                 f"{base_branch}_({base_hash})",
                 f"{feature_branch}_({feature_hash})",
                 null_hypothesis, alt_hypothesis)

    except KeyboardInterrupt:
        log("Interrupted by user. Cleaning up...")
        git_checkout(original_branch)
        sys.exit(0)
    except Exception as e:
        error(f"Unexpected error: {e}")

if __name__ == "__main__":
    main()
