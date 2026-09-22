#!/bin/bash
set -e

# ─────────────────────────────────────────────────────────────
# Colors
# ─────────────────────────────────────────────────────────────

BOLD=$'\033[1m'
DIM=$'\033[2m'
RESET=$'\033[0m'

CYAN=$'\033[36m'
GREEN=$'\033[32m'
YELLOW=$'\033[33m'
RED=$'\033[31m'
WHITE=$'\033[97m'

# ─────────────────────────────────────────────────────────────
# Configuration
# ─────────────────────────────────────────────────────────────

OLLAMA_HOST="${OLLAMA_HOST:-0.0.0.0:11434}"
OLLAMA_API="http://127.0.0.1:11434"

# All Ollama models will be stored here.
OLLAMA_MODELS="/home/ubuntu/Models"

# ─────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────

pause() {
    echo
    read -r -p "Press Enter to continue..." < /dev/tty
}

header() {
    clear
    echo
    printf '%s\n' "${CYAN}${BOLD}╔══════════════════════════════════════════════════════════╗${RESET}"
    printf '%s\n' "${CYAN}${BOLD}║${WHITE}                 RUNPOD OLLAMA MANAGER                  ${CYAN}║${RESET}"
    printf '%s\n' "${CYAN}${BOLD}╚══════════════════════════════════════════════════════════╝${RESET}"
    echo
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

check_dependencies() {
    local missing=()

    command_exists curl || missing+=("curl")
    command_exists jq || missing+=("jq")

    if [ "${#missing[@]}" -gt 0 ]; then

        printf '%s\n' "${YELLOW}→${RESET} Installing missing dependencies: ${missing[*]}"

        apt-get update

        DEBIAN_FRONTEND=noninteractive \
            apt-get install -y "${missing[@]}"
    fi
}

# ─────────────────────────────────────────────────────────────
# Configure Ollama Model Directory
# ─────────────────────────────────────────────────────────────

configure_models_directory() {

    mkdir -p "$OLLAMA_MODELS"

    # The official Ollama Linux service runs as the ollama user.
    # Give it ownership of the model directory when that user exists.
    if id ollama >/dev/null 2>&1; then
        chown -R ollama:ollama "$OLLAMA_MODELS"
    elif id ubuntu >/dev/null 2>&1; then
        chown -R ubuntu:ubuntu "$OLLAMA_MODELS"
    fi

    chmod 755 "$OLLAMA_MODELS"

    export OLLAMA_MODELS="$OLLAMA_MODELS"
}

# ─────────────────────────────────────────────────────────────
# Configure Systemd Ollama Service
# ─────────────────────────────────────────────────────────────

configure_ollama_service() {

    if ! command_exists systemctl; then
        return 0
    fi

    if [ ! -f /etc/systemd/system/ollama.service ]; then
        return 0
    fi

    mkdir -p /etc/systemd/system/ollama.service.d

    cat > /etc/systemd/system/ollama.service.d/override.conf <<EOF
[Service]
Environment="OLLAMA_HOST=${OLLAMA_HOST}"
Environment="OLLAMA_MODELS=${OLLAMA_MODELS}"
EOF

    systemctl daemon-reload
}

# ─────────────────────────────────────────────────────────────
# Check Ollama
# ─────────────────────────────────────────────────────────────

ollama_running() {
    curl -fsS "${OLLAMA_API}/api/version" >/dev/null 2>&1
}

# ─────────────────────────────────────────────────────────────
# Install / Update Ollama
# ─────────────────────────────────────────────────────────────

install_ollama() {
    header

    printf '%s\n' "${BOLD}Install / Update Ollama${RESET}"
    echo

    printf '%s\n' "${YELLOW}→${RESET} Installing/updating Ollama..."
    echo

    curl -fsSL https://ollama.com/install.sh | sh

    echo

    if command_exists ollama; then

        printf '%s\n' "${GREEN}✓${RESET} Ollama installed."
        echo

        ollama --version

        echo

        configure_models_directory
        configure_ollama_service

        printf '%s\n' "${GREEN}✓${RESET} Model directory configured:"
        printf '%s\n' "  ${OLLAMA_MODELS}"

    else

        printf '%s\n' "${RED}✗ Ollama installation failed.${RESET}"

    fi

    echo

    pause
}

# ─────────────────────────────────────────────────────────────
# Start Ollama
# ─────────────────────────────────────────────────────────────

start_ollama() {
    header

    printf '%s\n' "${BOLD}Start Ollama${RESET}"
    echo

    configure_models_directory
    configure_ollama_service

    if ollama_running; then

        printf '%s\n' "${GREEN}✓${RESET} Ollama is already running."

        echo

        printf '%s\n' "  Host   : ${OLLAMA_HOST}"
        printf '%s\n' "  API    : ${OLLAMA_API}"
        printf '%s\n' "  Models : ${OLLAMA_MODELS}"

        echo

        pause
        return
    fi

    if ! command_exists ollama; then

        printf '%s\n' "${RED}✗ Ollama is not installed.${RESET}"

        echo

        pause
        return
    fi

    printf '%s\n' "${YELLOW}→${RESET} Starting Ollama..."
    echo

    export OLLAMA_HOST="$OLLAMA_HOST"
    export OLLAMA_MODELS="$OLLAMA_MODELS"

    if command_exists systemctl &&
       [ -f /etc/systemd/system/ollama.service ]; then

        systemctl restart ollama

    else

        nohup env \
            OLLAMA_HOST="$OLLAMA_HOST" \
            OLLAMA_MODELS="$OLLAMA_MODELS" \
            ollama serve \
            > /var/log/ollama-runpod.log 2>&1 &

    fi

    sleep 3

    if ollama_running; then

        printf '%s\n' "${GREEN}✓${RESET} Ollama started."

        echo

        printf '%s\n' "  Host   : ${OLLAMA_HOST}"
        printf '%s\n' "  API    : ${OLLAMA_API}"
        printf '%s\n' "  Models : ${OLLAMA_MODELS}"

    else

        printf '%s\n' "${RED}✗ Ollama failed to start.${RESET}"

        echo

        printf '%s\n' "${DIM}Check /var/log/ollama-runpod.log${RESET}"

    fi

    echo

    pause
}

# ─────────────────────────────────────────────────────────────
# Stop Ollama
# ─────────────────────────────────────────────────────────────

stop_ollama() {
    header

    printf '%s\n' "${BOLD}Stop Ollama${RESET}"
    echo

    if command_exists systemctl &&
       [ -f /etc/systemd/system/ollama.service ]; then

        printf '%s\n' "${YELLOW}→${RESET} Stopping Ollama service..."

        systemctl stop ollama

    elif pgrep -x ollama >/dev/null 2>&1; then

        printf '%s\n' "${YELLOW}→${RESET} Stopping Ollama..."

        pkill -x ollama 2>/dev/null || true

    else

        printf '%s\n' "${DIM}Ollama is not running.${RESET}"

    fi

    sleep 2

    if ollama_running; then

        printf '%s\n' "${RED}✗ Ollama is still running.${RESET}"

    else

        printf '%s\n' "${GREEN}✓${RESET} Ollama stopped."

    fi

    echo

    pause
}

# ─────────────────────────────────────────────────────────────
# Ollama Status
# ─────────────────────────────────────────────────────────────

ollama_status() {
    header

    printf '%s\n' "${BOLD}Ollama Status${RESET}"
    echo

    if ! command_exists ollama; then

        printf '%s\n' "${RED}✗ Ollama is not installed.${RESET}"

        echo

        pause
        return
    fi

    printf '%s\n' "  Version : $(ollama --version)"

    if ollama_running; then

        printf '%s\n' "  Status  : ${GREEN}RUNNING${RESET}"

    else

        printf '%s\n' "  Status  : ${RED}STOPPED${RESET}"

    fi

    echo

    printf '%s\n' "  Host    : ${OLLAMA_HOST}"
    printf '%s\n' "  API     : ${OLLAMA_API}"
    printf '%s\n' "  Models  : ${OLLAMA_MODELS}"

    echo

    if [ -d "$OLLAMA_MODELS" ]; then

        printf '%s\n' "${BOLD}Model directory:${RESET}"
        printf '%s\n' "  ${OLLAMA_MODELS}"

        echo

        printf '%s\n' "  Disk usage: $(du -sh "$OLLAMA_MODELS" 2>/dev/null | awk '{print $1}')"

    fi

    echo

    pause
}

# ─────────────────────────────────────────────────────────────
# List Installed Models
# ─────────────────────────────────────────────────────────────

list_models() {
    header

    printf '%s\n' "${BOLD}Installed Ollama Models${RESET}"
    echo

    if ! ollama_running; then

        printf '%s\n' "${RED}✗ Ollama is not running.${RESET}"

        echo

        pause
        return
    fi

    ollama list

    echo

    printf '%s\n' "${DIM}Models are stored in:${RESET}"
    printf '%s\n' "${OLLAMA_MODELS}"

    echo

    pause
}

# ─────────────────────────────────────────────────────────────
# Pull Ollama Registry Model
# ─────────────────────────────────────────────────────────────

pull_ollama_model() {
    header

    printf '%s\n' "${BOLD}Pull Ollama Registry Model${RESET}"
    echo

    printf '%s\n' "${DIM}Examples: qwen3:8b, qwen3-coder:30b, gpt-oss:20b${RESET}"
    echo

    printf '%s' "Model name: "
    read -r MODEL < /dev/tty

    if [ -z "$MODEL" ]; then

        printf '%s\n' "${RED}✗ No model specified.${RESET}"

        pause
        return
    fi

    echo

    printf '%s\n' "${YELLOW}→${RESET} Pulling ${MODEL}..."
    echo

    ollama pull "$MODEL"

    echo

    printf '%s\n' "${GREEN}✓${RESET} Pull complete."

    echo

    pause
}

# ─────────────────────────────────────────────────────────────
# Parse Hugging Face Repository
# ─────────────────────────────────────────────────────────────

parse_hf_repo() {

    local INPUT="$1"

    INPUT="${INPUT%/}"

    INPUT="${INPUT#https://}"
    INPUT="${INPUT#http://}"

    INPUT="${INPUT#huggingface.co/}"
    INPUT="${INPUT#hf.co/}"

    INPUT="${INPUT%%/tree/*}"
    INPUT="${INPUT%%/blob/*}"

    echo "$INPUT"
}

# ─────────────────────────────────────────────────────────────
# Query Hugging Face Repository
# ─────────────────────────────────────────────────────────────

query_hf_repo() {
    header

    printf '%s\n' "${BOLD}Query Hugging Face Repository${RESET}"
    echo

    printf '%s\n' "${DIM}Paste a Hugging Face model repository URL.${RESET}"
    printf '%s\n' "${DIM}Example: https://huggingface.co/ggml-org/Qwen3-32B-GGUF${RESET}"
    echo

    printf '%s' "Repository URL: "
    read -r HF_URL < /dev/tty

    if [ -z "$HF_URL" ]; then

        printf '%s\n' "${RED}✗ No repository supplied.${RESET}"

        pause
        return
    fi

    REPO=$(parse_hf_repo "$HF_URL")

    if [[ ! "$REPO" =~ ^[^/]+/[^/]+$ ]]; then

        printf '%s\n' "${RED}✗ Invalid Hugging Face repository format.${RESET}"
        printf '%s\n' "${DIM}Expected: username/repository${RESET}"

        pause
        return
    fi

    echo

    printf '%s\n' "${YELLOW}→${RESET} Querying Hugging Face..."
    echo

    API_URL="https://huggingface.co/api/models/${REPO}"

    RESPONSE=$(curl -fsSL "$API_URL") || {

        printf '%s\n' "${RED}✗ Unable to query repository.${RESET}"

        pause
        return
    }

    printf '%s\n' "${BOLD}Repository${RESET}"

    printf '%s\n' "  Name       : $(echo "$RESPONSE" | jq -r '.id // "unknown"')"
    printf '%s\n' "  Author     : $(echo "$RESPONSE" | jq -r '.author // "unknown"')"
    printf '%s\n' "  Downloads  : $(echo "$RESPONSE" | jq -r '.downloads // 0')"
    printf '%s\n' "  Likes      : $(echo "$RESPONSE" | jq -r '.likes // 0')"
    printf '%s\n' "  Pipeline   : $(echo "$RESPONSE" | jq -r '.pipeline_tag // "unknown"')"
    printf '%s\n' "  Library    : $(echo "$RESPONSE" | jq -r '.library_name // "unknown"')"

    echo

    printf '%s\n' "${BOLD}GGUF Files${RESET}"
    echo

    echo "$RESPONSE" |
        jq -r '
            .siblings[]?.rfilename
            | select(test("\\.gguf$"; "i"))
        ' |
        sort

    echo

    pause
}

# ─────────────────────────────────────────────────────────────
# Pull Hugging Face GGUF
# ─────────────────────────────────────────────────────────────

pull_hf_model() {
    header

    printf '%s\n' "${BOLD}Pull Hugging Face GGUF Model${RESET}"
    echo

    printf '%s\n' "${DIM}Paste the Hugging Face repository URL.${RESET}"
    printf '%s\n' "${DIM}Example: https://huggingface.co/ggml-org/Qwen3-32B-GGUF${RESET}"
    echo

    printf '%s' "Repository URL: "
    read -r HF_URL < /dev/tty

    if [ -z "$HF_URL" ]; then

        printf '%s\n' "${RED}✗ No repository supplied.${RESET}"

        pause
        return
    fi

    REPO=$(parse_hf_repo "$HF_URL")

    if [[ ! "$REPO" =~ ^[^/]+/[^/]+$ ]]; then

        printf '%s\n' "${RED}✗ Invalid Hugging Face repository format.${RESET}"

        pause
        return
    fi

    echo

    printf '%s\n' "${YELLOW}→${RESET} Querying available GGUF files..."
    echo

    RESPONSE=$(curl -fsSL "https://huggingface.co/api/models/${REPO}") || {

        printf '%s\n' "${RED}✗ Unable to query repository.${RESET}"

        pause
        return
    }

    mapfile -t GGUF_FILES < <(
        echo "$RESPONSE" |
            jq -r '
                .siblings[]?.rfilename
                | select(test("\\.gguf$"; "i"))
            ' |
            sort
    )

    if [ "${#GGUF_FILES[@]}" -eq 0 ]; then

        printf '%s\n' "${RED}✗ No GGUF files found in this repository.${RESET}"

        echo

        printf '%s\n' "${DIM}Ollama direct Hugging Face pulling requires a compatible GGUF repository.${RESET}"

        pause
        return
    fi

    printf '%s\n' "${BOLD}Available GGUF files:${RESET}"
    echo

    local INDEX=1

    for FILE in "${GGUF_FILES[@]}"; do

        printf '%s\n' "  ${CYAN}[${INDEX}]${RESET} ${FILE}"

        INDEX=$((INDEX + 1))
    done

    echo

    printf '%s' "Select GGUF [1-${#GGUF_FILES[@]}]: "
    read -r SELECTION < /dev/tty

    if ! [[ "$SELECTION" =~ ^[0-9]+$ ]] ||
       [ "$SELECTION" -lt 1 ] ||
       [ "$SELECTION" -gt "${#GGUF_FILES[@]}" ]; then

        printf '%s\n' "${RED}✗ Invalid selection.${RESET}"

        pause
        return
    fi

    SELECTED_FILE="${GGUF_FILES[$((SELECTION - 1))]}"

    QUANT=$(echo "$SELECTED_FILE" |
        grep -oEi \
        '(IQ[1-4]_[A-Z_0-9]+|Q[2-8]_[A-Z0-9_]+|Q[2-8]_0|BF16|F16|F32)' |
        tail -1 || true)

    echo

    printf '%s\n' "${BOLD}Selected:${RESET}"
    printf '%s\n' "  Repository : ${REPO}"
    printf '%s\n' "  File       : ${SELECTED_FILE}"
    printf '%s\n' "  Quant      : ${QUANT:-unknown}"

    echo

    if [ -n "$QUANT" ]; then
        MODEL_REF="hf.co/${REPO}:${QUANT}"
    else
        MODEL_REF="hf.co/${REPO}"
    fi

    printf '%s\n' "${BOLD}Ollama reference:${RESET}"
    printf '%s\n' "  ${MODEL_REF}"

    echo

    printf '%s' "Pull this model? [y/N]: "
    read -r CONFIRM < /dev/tty

    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then

        printf '%s\n' "${DIM}Cancelled.${RESET}"

        pause
        return
    fi

    echo

    printf '%s\n' "${YELLOW}→${RESET} Pulling ${MODEL_REF}..."
    echo

    ollama pull "$MODEL_REF"

    echo

    printf '%s\n' "${GREEN}✓${RESET} Hugging Face model pulled successfully."

    echo

    pause
}

# ─────────────────────────────────────────────────────────────
# Show Model Details
# ─────────────────────────────────────────────────────────────

show_model() {
    header

    printf '%s\n' "${BOLD}Show Model Details${RESET}"
    echo

    printf '%s' "Model name: "
    read -r MODEL < /dev/tty

    if [ -z "$MODEL" ]; then

        printf '%s\n' "${RED}✗ No model specified.${RESET}"

        pause
        return
    fi

    echo

    ollama show "$MODEL"

    echo

    pause
}

# ─────────────────────────────────────────────────────────────
# Remove Model
# ─────────────────────────────────────────────────────────────

remove_model() {
    header

    printf '%s\n' "${BOLD}Remove Ollama Model${RESET}"
    echo

    printf '%s' "Model name: "
    read -r MODEL < /dev/tty

    if [ -z "$MODEL" ]; then

        printf '%s\n' "${RED}✗ No model specified.${RESET}"

        pause
        return
    fi

    echo

    printf '%s' "Remove ${MODEL}? [y/N]: "
    read -r CONFIRM < /dev/tty

    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then

        printf '%s\n' "${DIM}Cancelled.${RESET}"

        pause
        return
    fi

    echo

    ollama rm "$MODEL"

    echo

    printf '%s\n' "${GREEN}✓${RESET} Model removed."

    pause
}

# ─────────────────────────────────────────────────────────────
# Run Model
# ─────────────────────────────────────────────────────────────

run_model() {
    header

    printf '%s\n' "${BOLD}Run Ollama Model${RESET}"
    echo

    printf '%s' "Model name: "
    read -r MODEL < /dev/tty

    if [ -z "$MODEL" ]; then

        printf '%s\n' "${RED}✗ No model specified.${RESET}"

        pause
        return
    fi

    echo
    printf '%s\n' "${GREEN}Starting ${MODEL}...${RESET}"
    echo

    ollama run "$MODEL"
}

# ─────────────────────────────────────────────────────────────
# Initial Configuration
# ─────────────────────────────────────────────────────────────

check_dependencies
configure_models_directory

# ─────────────────────────────────────────────────────────────
# Main Menu
# ─────────────────────────────────────────────────────────────

while true; do

    header

    printf '%s\n' "${BOLD}Ollama Configuration${RESET}"
    echo

    printf '%s\n' "  ${CYAN}[1]${RESET}   Install / update Ollama"
    printf '%s\n' "  ${CYAN}[2]${RESET}   Start Ollama"
    printf '%s\n' "  ${CYAN}[3]${RESET}   Stop Ollama"
    printf '%s\n' "  ${CYAN}[4]${RESET}   Ollama status"
    printf '%s\n' "  ${CYAN}[5]${RESET}   List installed models"
    printf '%s\n' "  ${CYAN}[6]${RESET}   Pull Ollama model"
    printf '%s\n' "  ${CYAN}[7]${RESET}   Query Hugging Face repository"
    printf '%s\n' "  ${CYAN}[8]${RESET}   Pull Hugging Face GGUF"
    printf '%s\n' "  ${CYAN}[9]${RESET}   Show model details"
    printf '%s\n' "  ${CYAN}[10]${RESET}  Remove model"
    printf '%s\n' "  ${CYAN}[11]${RESET}  Run model"
    printf '%s\n' "  ${CYAN}[12]${RESET}  Exit"

    echo

    printf '%s\n' "${DIM}────────────────────────────────────────────────────────────${RESET}"

    echo

    printf '%s' "${BOLD}Select an option [1-12]:${RESET} "
    read -r OPTION < /dev/tty

    case "$OPTION" in

        1)
            install_ollama
            ;;

        2)
            start_ollama
            ;;

        3)
            stop_ollama
            ;;

        4)
            ollama_status
            ;;

        5)
            list_models
            ;;

        6)
            pull_ollama_model
            ;;

        7)
            query_hf_repo
            ;;

        8)
            pull_hf_model
            ;;

        9)
            show_model
            ;;

        10)
            remove_model
            ;;

        11)
            run_model
            ;;

        12)
            echo
            printf '%s\n' "${GREEN}Goodbye.${RESET}"
            echo
            exit 0
            ;;

        *)
            echo
            printf '%s\n' "${RED}✗ Invalid option.${RESET}"
            sleep 1
            ;;

    esac

done