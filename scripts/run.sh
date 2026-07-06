#!/usr/bin/env bash
# run.sh - start the coding-seal Codex container with flexible options
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
CONFIG_SRC="${REPO_DIR}/config/codex-config.toml"

GPU_FLAGS=()
PROJECT_MOUNTS=()
PROJECT_SHORT_MOUNTS=()
MODE="local"
IMAGE="${CODEX_IMAGE:-localhost/coding-seal:latest}"
CONTAINER_NAME="${CONTAINER_NAME:-coding-seal}"
CODEX_AUTH_DIR="${CODEX_AUTH_DIR:-${HOME}/.codingseal/codex-auth}"
SSH_PORT="${SSH_PORT:-2222}"

want_auth=0
want_ssh=0

usage() {
    cat <<'EOF'
Usage: scripts/run.sh [OPTIONS] [-- CODEX_ARGS...]

Options:
  --auth                One-time login: runs `codex login --device-auth` and
                        saves credentials to the Codex auth dir
  --gpu-nvidia          Pass through NVIDIA GPU(s) via Podman CDI
  --gpu-nvidia-devices  Pass through raw /dev/nvidia* devices only
  --gpu-amd             Pass through AMD GPU via /dev/kfd and /dev/dri
  --no-gpu              Run without GPU (default)
  -p, --project PATH    Bind-mount a project directory (repeatable)
  --ssh                 Headless: container stays running for SSH / VS Code Remote-SSH
  --port PORT           SSH port on localhost, used by --ssh (default: 2222)
  --name NAME           Container name (default: coding-seal)
  --image IMAGE         Image to use (default: localhost/coding-seal:latest)
  -h, --help            Show this help

Authentication:
  Log in once with `scripts/run.sh --auth`. The login and Codex config are saved
  in CODEX_AUTH_DIR and reused on every run. Codex supports ChatGPT login and
  API-key login; device auth is the most reliable browser flow from a container.

Environment variables:
  SSH_PUBLIC_KEY            Public key injected into authorized_keys for --ssh
  CODEX_AUTH_DIR            Host dir for persistent Codex state
                            (default: ~/.codingseal/codex-auth)
  SSH_PORT, CONTAINER_NAME, CODEX_IMAGE
                            Override defaults

Examples:
  scripts/run.sh --auth
  scripts/run.sh -p ~/projects/myapp
  scripts/run.sh -p ~/projects/myapp -- "fix the failing tests"
  scripts/run.sh --ssh -p ~/projects/myapp
  scripts/run.sh --gpu-nvidia -p ~/projects/ml
EOF
    exit 0
}

CODEX_ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --)
            shift
            CODEX_ARGS=("$@")
            break ;;
        --gpu-nvidia)
            GPU_FLAGS=("--device" "nvidia.com/gpu=all")
            shift ;;
        --gpu-nvidia-devices)
            GPU_FLAGS=(
                "--device" "/dev/nvidia0"
                "--device" "/dev/nvidiactl"
                "--device" "/dev/nvidia-uvm"
                "--device" "/dev/nvidia-modeset"
                "--device" "/dev/nvidia-uvm-tools"
            )
            shift ;;
        --gpu-amd)
            GPU_FLAGS=(
                "--device" "/dev/kfd"
                "--device" "/dev/dri"
                "--group-add" "keep-groups"
            )
            shift ;;
        --no-gpu)
            GPU_FLAGS=()
            shift ;;
        -p|--project)
            [[ -z "${2:-}" ]] && { echo "Error: -p requires a path" >&2; exit 1; }
            ABSPATH="$(realpath "$2")"
            PROJECT_NAME="$(basename -- "${ABSPATH}")"
            PROJECT_MOUNTS+=("--volume" "${ABSPATH}:${ABSPATH}:Z")
            PROJECT_SHORT_MOUNTS+=("--volume" "${ABSPATH}:/home/coder/projects/${PROJECT_NAME}:Z")
            [[ -z "${FIRST_PROJECT:-}" ]] && FIRST_PROJECT="${ABSPATH}"
            [[ -z "${FIRST_PROJECT_NAME:-}" ]] && FIRST_PROJECT_NAME="${PROJECT_NAME}"
            shift 2 ;;
        --auth)
            want_auth=1
            shift ;;
        --ssh)
            want_ssh=1
            shift ;;
        --port)
            [[ -z "${2:-}" ]] && { echo "Error: --port requires a value" >&2; exit 1; }
            SSH_PORT="$2"
            shift 2 ;;
        --name)
            [[ -z "${2:-}" ]] && { echo "Error: --name requires a value" >&2; exit 1; }
            CONTAINER_NAME="$2"
            shift 2 ;;
        --image)
            [[ -z "${2:-}" ]] && { echo "Error: --image requires a value" >&2; exit 1; }
            IMAGE="$2"
            shift 2 ;;
        -h|--help) usage ;;
        *) echo "Unknown option: $1" >&2; usage ;;
    esac
done

if (( want_auth && want_ssh )); then
    echo "Error: choose only one of --auth or --ssh." >&2
    exit 1
fi
(( want_auth )) && MODE="auth"
(( want_ssh )) && MODE="ssh"

if [[ "${MODE}" == "ssh" && -z "${SSH_PUBLIC_KEY:-}" ]]; then
    echo "Error: --ssh needs SSH_PUBLIC_KEY set to your public key contents." >&2
    echo "  Example: export SSH_PUBLIC_KEY=\"\$(cat ~/.ssh/id_ed25519.pub)\"" >&2
    exit 1
fi

mkdir -p "${CODEX_AUTH_DIR}"
[[ -f "${CONFIG_SRC}" ]] || { echo "Error: missing ${CONFIG_SRC}" >&2; exit 1; }
cp "${CONFIG_SRC}" "${CODEX_AUTH_DIR}/config.toml"

# Register built-in MCP servers in Codex's user config. This is intentionally
# host-side so a bind-mounted CODEX_HOME always has the latest default config.
if command -v python3 >/dev/null 2>&1; then
    CONTEXT7_API_KEY="${CONTEXT7_API_KEY:-}" \
    GITHUB_PERSONAL_ACCESS_TOKEN="${GITHUB_PERSONAL_ACCESS_TOKEN:-}" \
    python3 - "${CODEX_AUTH_DIR}/config.toml" <<'PY'
import json
import os
import pathlib

path = pathlib.Path(os.environ.get("CODEX_CONFIG_PATH", "") or __import__("sys").argv[1])
text = path.read_text()

def strip_table(text: str, table: str) -> str:
    lines = text.splitlines()
    out: list[str] = []
    skipping = False
    for line in lines:
        if line.startswith("[") and line.endswith("]"):
            skipping = line == table
            if skipping:
                continue
        if not skipping:
            out.append(line)
    return "\n".join(out).rstrip() + "\n"

for table in (
    "[mcp_servers.context7]",
    "[mcp_servers.sequential-thinking]",
    "[mcp_servers.github]",
):
    text = strip_table(text, table)

ctx_key = os.environ.get("CONTEXT7_API_KEY", "").strip()
gh_pat = os.environ.get("GITHUB_PERSONAL_ACCESS_TOKEN", "").strip()

blocks = [
    '[mcp_servers.context7]\ncommand = "npx"\nargs = ["-y", "@upstash/context7-mcp"]',
    '[mcp_servers.sequential-thinking]\ncommand = "npx"\nargs = ["-y", "@modelcontextprotocol/server-sequential-thinking"]',
]
if ctx_key:
    blocks[0] += f"\nenv = {{ CONTEXT7_API_KEY = {json.dumps(ctx_key)} }}"
if gh_pat:
    blocks.append(
        '[mcp_servers.github]\n'
        'url = "https://api.githubcopilot.com/mcp/"\n'
        'bearer_token_env_var = "GITHUB_PERSONAL_ACCESS_TOKEN"'
    )

path.write_text(text.rstrip() + "\n\n" + "\n\n".join(blocks) + "\n")
PY
else
    echo "Warning: python3 not found on host; skipping MCP config seeding." >&2
fi

PODMAN_FLAGS=(
    "--name" "${CONTAINER_NAME}"
    "--rm"
    "--userns=keep-id"
    "--volume" "${CODEX_AUTH_DIR}:/home/coder/.codex:Z"
)

if [[ -n "${GITHUB_PERSONAL_ACCESS_TOKEN:-}" ]]; then
    PODMAN_FLAGS+=("--env" "GITHUB_PERSONAL_ACCESS_TOKEN=${GITHUB_PERSONAL_ACCESS_TOKEN}")
fi

if [[ ${#GPU_FLAGS[@]} -gt 0 ]]; then
    PODMAN_FLAGS+=("${GPU_FLAGS[@]}")
fi

if [[ ${#PROJECT_MOUNTS[@]} -gt 0 ]]; then
    PODMAN_FLAGS+=("${PROJECT_MOUNTS[@]}")
fi

if [[ ${#PROJECT_SHORT_MOUNTS[@]} -gt 0 ]]; then
    PODMAN_FLAGS+=("${PROJECT_SHORT_MOUNTS[@]}")
fi

if [[ -n "${FIRST_PROJECT:-}" ]]; then
    PODMAN_FLAGS+=("--volume" "${FIRST_PROJECT}:/home/coder/project:Z")
    PODMAN_FLAGS+=("--workdir" "${FIRST_PROJECT}")
fi

if [[ "${MODE}" == "local" ]]; then
    PODMAN_FLAGS+=("--tty" "--interactive")
    CMD=("codex" "--yolo" "${CODEX_ARGS[@]}")
elif [[ "${MODE}" == "auth" ]]; then
    PODMAN_FLAGS+=("--tty" "--interactive")
    CMD=("codex" "login" "--device-auth")
else
    SSH_KEY_FILE="$(dirname -- "${CODEX_AUTH_DIR}")/authorized_keys"
    printf '%s\n' "${SSH_PUBLIC_KEY}" > "${SSH_KEY_FILE}"
    chmod 600 "${SSH_KEY_FILE}"
    PODMAN_FLAGS+=(
        "--user" "0"
        "--detach"
        "--publish" "127.0.0.1:${SSH_PORT}:2222"
        "--volume" "${SSH_KEY_FILE}:/home/coder/.ssh/authorized_keys:ro,Z"
    )
    CMD=("/usr/sbin/sshd" "-D" "-e")
fi

echo "Starting container '${CONTAINER_NAME}' from image '${IMAGE}'..."
if [[ "${MODE}" == "auth" ]]; then
    echo ""
    echo "  Complete the Codex device login flow in this terminal/browser."
    echo "  Codex state will be saved to: ${CODEX_AUTH_DIR}"
    echo ""
fi
if [[ "${MODE}" == "ssh" ]]; then
    echo ""
    echo "  SSH into the container:"
    echo "    ssh -p ${SSH_PORT} -i ~/.ssh/id_ed25519 coder@localhost"
    echo ""
    if [[ -n "${FIRST_PROJECT:-}" ]]; then
        echo "  First project:"
        echo "    /home/coder/project"
        echo ""
        echo "  All projects:"
        echo "    /home/coder/projects/"
        echo ""
    fi
    echo "  Then start Codex:"
    echo "    codex --yolo"
    echo ""
    echo "  Stop the container:"
    echo "    podman stop ${CONTAINER_NAME}"
    echo ""
fi

exec podman run "${PODMAN_FLAGS[@]}" "${IMAGE}" "${CMD[@]}"
