#!/bin/bash
set -e

# ============================================================
# RUNPOD OLLAMA MANAGER
# ============================================================

# -----------------------------
# Colors
# -----------------------------
RESET='\033[0m'
CYAN='\033[1;36m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
WHITE='\033[1;37m'
GRAY='\033[0;37m'

# -----------------------------
# Configuration
# -----------------------------
OLLAMA_HOST="0.0.0.0:11434"
OLLAMA_API="http://127.0.0.1:11434"
OLLAMA_MODELS="/home/ubuntu/Models"

MANAGER_CONFIG_DIR="$HOME/.config/runpod-ollama-manager"
RECENT_HF_FILE="$MANAGER_CONFIG_DIR/recent_hf_models.json"

OLLAMA_INSTALLED=false
OLLAMA_VERSION=""
MODEL_COUNT=0
MODEL_BULLETIN=""
RECENT_HF_BULLETIN=""

# ============================================================
# Basic helpers
# ============================================================

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

pause() {
    echo
    read -r -p "Press Enter to continue..." < /dev/tty
}

header() {
    clear
    printf "${CYAN}"
    printf '╔══════════════════════════════════════════════════════════╗\n'
    printf '║                 RUNPOD OLLAMA MANAGER                  ║\n'
    printf '╚══════════════════════════════════════════════════════════╝\n'
    printf "${RESET}\n"
}

# ============================================================
# Persistent manager state
# ============================================================

initialize_manager_state() {
    mkdir -p "$MANAGER_CONFIG_DIR"

    if [ ! -f "$RECENT_HF_FILE" ]; then
        cat > "$RECENT_HF_FILE" <<'EOF'
{
  "version": 1,
  "max_entries": 15,
  "description": "Persistent recent Hugging Face repository query history for RunPod Ollama Manager.",
  "repositories": []
}
EOF
    fi

    # The state file is read-only whenever the manager is not
    # actively running.
    chmod 444 "$RECENT_HF_FILE"
}

prepare_manager_state() {
    # Temporarily make the state file writable for this runtime.
    chmod 600 "$RECENT_HF_FILE"
}

restore_manager_state_permissions() {
    if [ -f "$RECENT_HF_FILE" ]; then
        chmod 444 "$RECENT_HF_FILE"
    fi
}

trap restore_manager_state_permissions EXIT INT TERM

# ============================================================
# Ollama detection / runtime
# ============================================================

check_ollama_installed() {
    OLLAMA_INSTALLED=false
    OLLAMA_VERSION=""

    if command_exists ollama; then
        OLLAMA_INSTALLED=true
        OLLAMA_VERSION="$(NO_COLOR=1 ollama --version 2>/dev/null || true)"
        OLLAMA_VERSION="${OLLAMA_VERSION#ollama version }"
    fi
}

is_systemd() {
    [ "$(ps -p 1 -o comm= 2>/dev/null)" = "systemd" ]
}

ollama_running() {
    curl -fsS --max-time 2 "$OLLAMA_API/api/tags" >/dev/null 2>&1
}

# ============================================================
# Dependencies / directories
# ============================================================

configure_models_directory() {
    mkdir -p "$OLLAMA_MODELS"

    if id ollama >/dev/null 2>&1; then
        chown -R ollama:ollama "$OLLAMA_MODELS"
    elif id ubuntu >/dev/null 2>&1; then
        chown -R ubuntu:ubuntu "$OLLAMA_MODELS"
    fi

    chmod 755 "$OLLAMA_MODELS"
}

check_dependencies() {
    local missing=()

    command_exists curl || missing+=("curl")
    command_exists jq || missing+=("jq")
    command_exists zstd || missing+=("zstd")

    if [ "${#missing[@]}" -gt 0 ]; then
        echo -e "${YELLOW}Installing missing dependencies:${RESET} ${missing[*]}"
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
    fi
}

# ============================================================
# Local model bulletin
# ============================================================

refresh_model_bulletin() {
    MODEL_BULLETIN=""
    MODEL_COUNT=0

    if ! command_exists ollama; then
        MODEL_BULLETIN="No Ollama installation detected."
        return
    fi

    local json
    json="$(curl -fsS --max-time 5 "$OLLAMA_API/api/tags" 2>/dev/null || true)"

    if [ -z "$json" ]; then
        MODEL_BULLETIN="Ollama is installed but the API is not currently reachable."
        return
    fi

    MODEL_COUNT="$(echo "$json" | jq '.models | length' 2>/dev/null || echo 0)"

    if [ "$MODEL_COUNT" -eq 0 ]; then
        MODEL_BULLETIN="No local Ollama models found."
        return
    fi

    MODEL_BULLETIN="$(
        echo "$json" | jq -r '
            .models[] |
            "• \(.name)\n    \(.details.parameter_size // "N/A")  |  \(.details.quantization_level // "N/A")  |  \(
                if .size >= 1073741824 then
                    ((.size / 1073741824 * 10 | round) / 10 | tostring) + " GB"
                elif .size >= 1048576 then
                    ((.size / 1048576 * 10 | round) / 10 | tostring) + " MB"
                else
                    (.size | tostring) + " B"
                end
            )"
        ' 2>/dev/null || true
    )"

    [ -n "$MODEL_BULLETIN" ] || MODEL_BULLETIN="Unable to read local model information."
}

# ============================================================
# Recent Hugging Face repository bulletin
# ============================================================

refresh_recent_hf_bulletin() {
    RECENT_HF_BULLETIN=""

    if [ ! -f "$RECENT_HF_FILE" ]; then
        RECENT_HF_BULLETIN="No repositories queried yet."
        return
    fi

    local count
    count="$(jq '.repositories | length' "$RECENT_HF_FILE" 2>/dev/null || echo 0)"

    if [ "$count" -eq 0 ]; then
        RECENT_HF_BULLETIN="No repositories queried yet."
        return
    fi

    RECENT_HF_BULLETIN="$(
        jq -r '
            .repositories
            | to_entries[]
            | "\(.key + 1). \(.value.name)"
        ' "$RECENT_HF_FILE" 2>/dev/null || true
    )"

    [ -n "$RECENT_HF_BULLETIN" ] || RECENT_HF_BULLETIN="No repositories queried yet."
}

show_model_bulletin() {
    refresh_model_bulletin
    refresh_recent_hf_bulletin

    echo -e "${WHITE}LOCAL MODELS${RESET}"
    echo "──────────────────────────────────────────────────────────"

    if [ -n "$MODEL_BULLETIN" ]; then
        printf '%s\n' "$MODEL_BULLETIN"
    fi

    echo "──────────────────────────────────────────────────────────"
    echo

    echo -e "${WHITE}RECENTLY QUERIED HUGGING FACE MODELS${RESET}"
    echo "──────────────────────────────────────────────────────────"

    printf '%s\n' "$RECENT_HF_BULLETIN"

    echo "──────────────────────────────────────────────────────────"
    echo
}

record_recent_hf_repo() {
    local repo="$1"
    local url="$2"
    local tmp_file

    [ -n "$repo" ] || return 0
    [ -n "$url" ] || return 0

    # The state file is expected to be writable during manager
    # runtime. Re-assert this before modifying it.
    chmod 600 "$RECENT_HF_FILE"

    tmp_file="$(mktemp "${RECENT_HF_FILE}.XXXXXX")"

    if jq \
        --arg name "$repo" \
        --arg url "$url" \
        '
        .repositories =
            (
                [
                    {
                        "name": $name,
                        "url": $url
                    }
                ]
                +
                [
                    .repositories[]?
                    | select(.url != $url)
                ]
            )
            | .repositories = .repositories[:(.max_entries // 15)]
        ' "$RECENT_HF_FILE" > "$tmp_file"; then

        mv "$tmp_file" "$RECENT_HF_FILE"
        chmod 600 "$RECENT_HF_FILE"
    else
        rm -f "$tmp_file"
        echo -e "${YELLOW}Warning: could not update recent Hugging Face history.${RESET}"
    fi

    refresh_recent_hf_bulletin
}

# ============================================================
# Start Ollama
# ============================================================

start_ollama_container() {
    mkdir -p /var/log

    nohup env \
        OLLAMA_HOST="$OLLAMA_HOST" \
        OLLAMA_MODELS="$OLLAMA_MODELS" \
        NO_COLOR=1 \
        ollama serve \
        > /var/log/ollama-runpod.log 2>&1 &

    sleep 3
}

# ============================================================
# Install / update Ollama
# ============================================================

install_or_update_ollama() {
    header
    check_ollama_installed
    show_model_bulletin

    echo -e "${WHITE}INSTALL / UPDATE OLLAMA${RESET}"
    echo "──────────────────────────────────────────────────────────"

    if [ "$OLLAMA_INSTALLED" = true ]; then
        echo -e "Current version : ${GREEN}${OLLAMA_VERSION}${RESET}"
        echo "Action          : Update Ollama"
    else
        echo "Action          : Install Ollama"
    fi

    echo "Model directory : $OLLAMA_MODELS"
    echo

    check_dependencies
    configure_models_directory

    echo -e "${CYAN}→ Running official Ollama installer...${RESET}"
    curl -fsSL https://ollama.com/install.sh | sh

    check_ollama_installed

    if [ "$OLLAMA_INSTALLED" != true ]; then
        echo -e "${RED}Ollama installation failed or ollama was not found in PATH.${RESET}"
        pause
        return
    fi

    configure_models_directory

    echo
    echo -e "${GREEN}Ollama installed/updated successfully.${RESET}"
    echo "Version         : $OLLAMA_VERSION"
    echo "Model directory : $OLLAMA_MODELS"

    if is_systemd; then
        mkdir -p /etc/systemd/system/ollama.service.d

        cat > /etc/systemd/system/ollama.service.d/override.conf <<EOF
[Service]
Environment="OLLAMA_HOST=${OLLAMA_HOST}"
Environment="OLLAMA_MODELS=${OLLAMA_MODELS}"
EOF

        systemctl daemon-reload

        echo
        echo -e "${CYAN}→ Restarting Ollama service...${RESET}"
        systemctl restart ollama
    else
        echo
        echo -e "${YELLOW}RunPod container detected: systemd is not running.${RESET}"
        echo "Starting Ollama directly with ollama serve..."

        pkill -f "ollama serve" 2>/dev/null || true
        start_ollama_container
    fi

    sleep 2

    if ollama_running; then
        echo -e "${GREEN}Ollama API is running.${RESET}"
        echo "API             : $OLLAMA_API"
        echo "Models          : $OLLAMA_MODELS"
    else
        echo -e "${RED}Ollama API did not become available.${RESET}"
        echo "Log             : /var/log/ollama-runpod.log"
    fi

    refresh_model_bulletin
    refresh_recent_hf_bulletin
    pause
}

# ============================================================
# Start / restart
# ============================================================

start_ollama() {
    header
    check_ollama_installed
    show_model_bulletin

    echo -e "${WHITE}START / RESTART OLLAMA${RESET}"
    echo "──────────────────────────────────────────────────────────"

    if [ "$OLLAMA_INSTALLED" != true ]; then
        echo -e "${RED}Ollama is not installed.${RESET}"
        echo "Use option 1 first."
        pause
        return
    fi

    configure_models_directory

    if is_systemd; then
        echo -e "${CYAN}→ Restarting Ollama service...${RESET}"
        systemctl restart ollama
    else
        echo -e "${CYAN}→ Restarting Ollama container process...${RESET}"
        pkill -f "ollama serve" 2>/dev/null || true
        start_ollama_container
    fi

    sleep 2

    if ollama_running; then
        echo -e "${GREEN}Ollama API is running.${RESET}"
    else
        echo -e "${RED}Ollama API is not responding.${RESET}"
        echo "Log: /var/log/ollama-runpod.log"
    fi

    refresh_model_bulletin
    pause
}

# ============================================================
# Stop
# ============================================================

stop_ollama() {
    header
    check_ollama_installed
    show_model_bulletin

    echo -e "${WHITE}STOP OLLAMA${RESET}"
    echo "──────────────────────────────────────────────────────────"

    if [ "$OLLAMA_INSTALLED" != true ]; then
        echo -e "${YELLOW}Ollama is not installed.${RESET}"
        pause
        return
    fi

    if is_systemd; then
        systemctl stop ollama
    else
        pkill -f "ollama serve" 2>/dev/null || true
    fi

    sleep 1

    if ollama_running; then
        echo -e "${RED}Ollama API is still responding.${RESET}"
    else
        echo -e "${GREEN}Ollama stopped.${RESET}"
    fi

    refresh_model_bulletin
    pause
}

# ============================================================
# Status
# ============================================================

ollama_status() {
    header
    check_ollama_installed
    show_model_bulletin

    echo -e "${WHITE}OLLAMA STATUS${RESET}"
    echo "──────────────────────────────────────────────────────────"

    if [ "$OLLAMA_INSTALLED" = true ]; then
        echo "Installed       : YES"
        echo "Version         : $OLLAMA_VERSION"
    else
        echo "Installed       : NO"
    fi

    echo "Host            : $OLLAMA_HOST"
    echo "API             : $OLLAMA_API"
    echo "Models          : $OLLAMA_MODELS"

    if ollama_running; then
        echo -e "API status      : ${GREEN}RUNNING${RESET}"
    else
        echo -e "API status      : ${YELLOW}STOPPED / UNREACHABLE${RESET}"
    fi

    if [ -d "$OLLAMA_MODELS" ]; then
        echo "Disk usage      : $(du -sh "$OLLAMA_MODELS" 2>/dev/null | awk '{print $1}')"
    fi

    echo
    pause
}

# ============================================================
# List local models
# ============================================================

list_models() {
    header
    check_ollama_installed
    show_model_bulletin

    echo -e "${WHITE}INSTALLED OLLAMA MODELS${RESET}"
    echo "──────────────────────────────────────────────────────────"

    if [ "$OLLAMA_INSTALLED" != true ]; then
        echo -e "${RED}Ollama is not installed.${RESET}"
        pause
        return
    fi

    NO_COLOR=1 ollama list || true

    echo
    echo "Model directory: $OLLAMA_MODELS"
    pause
}

# ============================================================
# Refresh local models
# ============================================================

refresh_models_page() {
    header
    check_ollama_installed

    echo -e "${WHITE}REFRESH LOCAL MODELS${RESET}"
    echo "──────────────────────────────────────────────────────────"

    refresh_model_bulletin
    refresh_recent_hf_bulletin

    echo -e "${GREEN}Local model bulletin refreshed.${RESET}"
    echo
    show_model_bulletin

    pause
}

# ============================================================
# Pull Ollama model
# ============================================================

pull_ollama_model() {
    header
    check_ollama_installed
    show_model_bulletin

    echo -e "${WHITE}PULL OLLAMA MODEL${RESET}"
    echo "──────────────────────────────────────────────────────────"

    if [ "$OLLAMA_INSTALLED" != true ]; then
        echo -e "${RED}Ollama is not installed.${RESET}"
        pause
        return
    fi

    printf "Ollama model name: "
    read -r MODEL < /dev/tty

    if [ -z "$MODEL" ]; then
        echo -e "${YELLOW}No model specified.${RESET}"
        pause
        return
    fi

    echo
    echo -e "${CYAN}→ Pulling ${MODEL}...${RESET}"
    NO_COLOR=1 ollama pull "$MODEL"

    refresh_model_bulletin

    echo
    echo -e "${GREEN}Local model bulletin updated.${RESET}"
    show_model_bulletin

    pause
}

# ============================================================
# Hugging Face helpers
# ============================================================

parse_hf_repo() {
    local input="$1"

    input="${input#https://huggingface.co/}"
    input="${input#http://huggingface.co/}"
    input="${input#huggingface.co/}"
    input="${input%%\?*}"
    input="${input%%#*}"
    input="${input%/}"

    printf '%s' "$input"
}

query_hf_api() {
    local repo="$1"
    curl -fsSL "https://huggingface.co/api/models/${repo}"
}

# ============================================================
# Query Hugging Face repository
# ============================================================

query_hf_repo() {
    header
    check_ollama_installed
    show_model_bulletin

    echo -e "${WHITE}QUERY HUGGING FACE REPOSITORY${RESET}"
    echo "──────────────────────────────────────────────────────────"
    echo
    echo "Paste a Hugging Face model repository URL."
    echo "Example: https://huggingface.co/ggml-org/Qwen3-32B-GGUF"
    echo

    printf "Repository URL: "
    read -r HF_URL < /dev/tty

    if [ -z "$HF_URL" ]; then
        echo -e "${YELLOW}No repository URL specified.${RESET}"
        pause
        return
    fi

    HF_REPO="$(parse_hf_repo "$HF_URL")"

    if [ -z "$HF_REPO" ] || [[ "$HF_REPO" != */* ]]; then
        echo -e "${RED}Invalid Hugging Face repository URL.${RESET}"
        pause
        return
    fi

    echo
    echo -e "${CYAN}→ Querying Hugging Face...${RESET}"

    HF_JSON="$(query_hf_api "$HF_REPO" 2>/dev/null || true)"

    if [ -z "$HF_JSON" ]; then
        echo -e "${RED}Failed to query Hugging Face repository.${RESET}"
        pause
        return
    fi

    if echo "$HF_JSON" | jq -e '.error' >/dev/null 2>&1; then
        echo -e "${RED}Hugging Face returned an error:${RESET}"
        echo "$HF_JSON" | jq -r '.error'
        pause
        return
    fi

    # Record only a successful repository query.
    record_recent_hf_repo \
        "$HF_REPO" \
        "https://huggingface.co/${HF_REPO}"

    echo
    echo -e "${WHITE}Repository${RESET}"
    echo "  Name        : $(echo "$HF_JSON" | jq -r '.id // .modelId // "N/A"')"
    echo "  Author      : $(echo "$HF_JSON" | jq -r '.author // "N/A"')"
    echo "  Downloads   : $(echo "$HF_JSON" | jq -r '.downloads // 0')"
    echo "  Likes       : $(echo "$HF_JSON" | jq -r '.likes // 0')"
    echo "  Pipeline    : $(echo "$HF_JSON" | jq -r '.pipeline_tag // "N/A"')"
    echo "  Library     : $(echo "$HF_JSON" | jq -r '(.library_name // ((.tags // []) | map(select(startswith("library:"))) | .[0] // "N/A"))')"

    echo
    echo -e "${WHITE}GGUF Files${RESET}"

    GGUF_FILES="$(
        echo "$HF_JSON" |
        jq -r '
            .siblings[]?.rfilename
            | select(test("\\.gguf$"; "i"))
        ' 2>/dev/null || true
    )"

    if [ -z "$GGUF_FILES" ]; then
        echo "No GGUF files found."
    else
        printf '%s\n' "$GGUF_FILES"
    fi

    echo
    echo -e "${WHITE}RECENTLY QUERIED HUGGING FACE MODELS${RESET}"
    echo "──────────────────────────────────────────────────────────"
    printf '%s\n' "$RECENT_HF_BULLETIN"
    echo "──────────────────────────────────────────────────────────"

    pause
}

# ============================================================
# Pull Hugging Face GGUF
# ============================================================

pull_hf_model() {
    header
    check_ollama_installed
    show_model_bulletin

    echo -e "${WHITE}PULL HUGGING FACE GGUF${RESET}"
    echo "──────────────────────────────────────────────────────────"

    if [ "$OLLAMA_INSTALLED" != true ]; then
        echo -e "${RED}Ollama is not installed.${RESET}"
        pause
        return
    fi

    printf "Hugging Face repository URL: "
    read -r HF_URL < /dev/tty

    if [ -z "$HF_URL" ]; then
        echo -e "${YELLOW}No repository URL specified.${RESET}"
        pause
        return
    fi

    HF_REPO="$(parse_hf_repo "$HF_URL")"

    if [ -z "$HF_REPO" ] || [[ "$HF_REPO" != */* ]]; then
        echo -e "${RED}Invalid Hugging Face repository URL.${RESET}"
        pause
        return
    fi

    echo
    echo -e "${CYAN}→ Querying Hugging Face repository...${RESET}"

    HF_JSON="$(query_hf_api "$HF_REPO" 2>/dev/null || true)"

    if [ -z "$HF_JSON" ]; then
        echo -e "${RED}Failed to query Hugging Face repository.${RESET}"
        pause
        return
    fi

    if echo "$HF_JSON" | jq -e '.error' >/dev/null 2>&1; then
        echo -e "${RED}Hugging Face returned an error:${RESET}"
        echo "$HF_JSON" | jq -r '.error'
        pause
        return
    fi

    # Successful query: update history even if the user later
    # chooses not to pull a GGUF.
    record_recent_hf_repo \
        "$HF_REPO" \
        "https://huggingface.co/${HF_REPO}"

    mapfile -t GGUF_ARRAY < <(
        echo "$HF_JSON" |
        jq -r '
            .siblings[]?.rfilename
            | select(test("\\.gguf$"; "i"))
        '
    )

    if [ "${#GGUF_ARRAY[@]}" -eq 0 ]; then
        echo -e "${YELLOW}No GGUF files found in this repository.${RESET}"
        pause
        return
    fi

    echo
    echo -e "${WHITE}GGUF Files${RESET}"
    echo "──────────────────────────────────────────────────────────"

    local i
    for i in "${!GGUF_ARRAY[@]}"; do
        printf "[%d] %s\n" "$((i + 1))" "${GGUF_ARRAY[$i]}"
    done

    echo
    printf "Select GGUF file [1-%d]: " "${#GGUF_ARRAY[@]}"
    read -r GGUF_SELECTION < /dev/tty

    if ! [[ "$GGUF_SELECTION" =~ ^[0-9]+$ ]] ||
       [ "$GGUF_SELECTION" -lt 1 ] ||
       [ "$GGUF_SELECTION" -gt "${#GGUF_ARRAY[@]}" ]; then
        echo -e "${RED}Invalid selection.${RESET}"
        pause
        return
    fi

    SELECTED_FILE="${GGUF_ARRAY[$((GGUF_SELECTION - 1))]}"

    # Infer the quantization tag from the selected filename.
    QUANT_TAG="$(
        printf '%s\n' "$SELECTED_FILE" |
        grep -oEi \
        'IQ[1-9](_[A-Z0-9]+)*|Q[1-9]_[A-Z0-9]+|BF16|F16|F32' |
        head -n 1 || true
    )"

    if [ -z "$QUANT_TAG" ]; then
        echo -e "${YELLOW}Could not infer a quantization tag from the filename.${RESET}"
        echo "Selected file: $SELECTED_FILE"
        pause
        return
    fi

    OLLAMA_HF_REF="hf.co/${HF_REPO}:${QUANT_TAG}"

    echo
    echo "Selected file : $SELECTED_FILE"
    echo "Quantization  : $QUANT_TAG"
    echo "Ollama ref    : $OLLAMA_HF_REF"
    echo

    printf "Pull this model? [y/N]: "
    read -r CONFIRM < /dev/tty

    case "$CONFIRM" in
        y|Y|yes|YES)
            ;;
        *)
            echo "Cancelled."
            pause
            return
            ;;
    esac

    echo
    echo -e "${CYAN}→ Pulling ${OLLAMA_HF_REF}...${RESET}"
    NO_COLOR=1 ollama pull "$OLLAMA_HF_REF"

    refresh_model_bulletin

    echo
    echo -e "${GREEN}Local model bulletin updated.${RESET}"
    show_model_bulletin

    pause
}

# ============================================================
# Show model details
# ============================================================

show_model() {
    header
    check_ollama_installed
    show_model_bulletin

    echo -e "${WHITE}MODEL DETAILS${RESET}"
    echo "──────────────────────────────────────────────────────────"

    if [ "$OLLAMA_INSTALLED" != true ]; then
        echo -e "${RED}Ollama is not installed.${RESET}"
        pause
        return
    fi

    printf "Model name: "
    read -r MODEL < /dev/tty

    if [ -z "$MODEL" ]; then
        echo -e "${YELLOW}No model specified.${RESET}"
        pause
        return
    fi

    NO_COLOR=1 ollama show "$MODEL"

    pause
}

# ============================================================
# Remove model
# ============================================================

remove_model() {
    header
    check_ollama_installed
    show_model_bulletin

    echo -e "${WHITE}REMOVE MODEL${RESET}"
    echo "──────────────────────────────────────────────────────────"

    if [ "$OLLAMA_INSTALLED" != true ]; then
        echo -e "${RED}Ollama is not installed.${RESET}"
        pause
        return
    fi

    printf "Model name: "
    read -r MODEL < /dev/tty

    if [ -z "$MODEL" ]; then
        echo -e "${YELLOW}No model specified.${RESET}"
        pause
        return
    fi

    echo
    printf "Remove %s? [y/N]: " "$MODEL"
    read -r CONFIRM < /dev/tty

    case "$CONFIRM" in
        y|Y|yes|YES)
            ;;
        *)
            echo "Cancelled."
            pause
            return
            ;;
    esac

    echo
    echo -e "${CYAN}→ Removing ${MODEL}...${RESET}"
    NO_COLOR=1 ollama rm "$MODEL"

    refresh_model_bulletin

    echo
    echo -e "${GREEN}Local model bulletin updated.${RESET}"
    show_model_bulletin

    pause
}

# ============================================================
# Run model
# ============================================================

run_model() {
    header
    check_ollama_installed
    show_model_bulletin

    echo -e "${WHITE}RUN MODEL${RESET}"
    echo "──────────────────────────────────────────────────────────"

    if [ "$OLLAMA_INSTALLED" != true ]; then
        echo -e "${RED}Ollama is not installed.${RESET}"
        pause
        return
    fi

    printf "Model name: "
    read -r MODEL < /dev/tty

    if [ -z "$MODEL" ]; then
        echo -e "${YELLOW}No model specified.${RESET}"
        pause
        return
    fi

    echo
    echo -e "${CYAN}→ Starting ${MODEL}...${RESET}"
    echo

    NO_COLOR=1 ollama run "$MODEL"
}

# ============================================================
# Main menu
# ============================================================

main_menu() {
    while true; do
        header

        check_ollama_installed
        refresh_model_bulletin
        refresh_recent_hf_bulletin

        echo -e "${WHITE}Ollama Configuration${RESET}"
        echo

        if [ "$OLLAMA_INSTALLED" = true ]; then
            echo -e "Ollama : ${GREEN}INSTALLED${RESET} ${OLLAMA_VERSION}"
        else
            echo -e "Ollama : ${YELLOW}NOT INSTALLED${RESET}"
        fi

        echo "Models : $OLLAMA_MODELS"
        echo

        show_model_bulletin

        echo -e "${WHITE}MENU${RESET}"
        echo "──────────────────────────────────────────────────────────"

        if [ "$OLLAMA_INSTALLED" = true ]; then
            echo "[1] Update Ollama"
        else
            echo "[1] Install Ollama"
        fi

        echo "[2] Start / restart Ollama"
        echo "[3] Stop Ollama"
        echo "[4] Ollama status"
        echo "[5] Refresh local models"
        echo "[6] List installed models"
        echo "[7] Pull Ollama model"
        echo "[8] Query Hugging Face repository"
        echo "[9] Pull Hugging Face GGUF"
        echo "[10] Show model details"
        echo "[11] Remove model"
        echo "[12] Run model"
        echo "[13] Exit"

        echo
        printf "Select an option: "
        read -r OPTION < /dev/tty

        case "$OPTION" in
            1) install_or_update_ollama ;;
            2) start_ollama ;;
            3) stop_ollama ;;
            4) ollama_status ;;
            5) refresh_models_page ;;
            6) list_models ;;
            7) pull_ollama_model ;;
            8) query_hf_repo ;;
            9) pull_hf_model ;;
            10) show_model ;;
            11) remove_model ;;
            12) run_model ;;
            13)
                echo
                echo "Exiting RunPod Ollama Manager."
                return 0
                ;;
            *)
                echo
                echo -e "${YELLOW}Invalid option.${RESET}"
                sleep 1
                ;;
        esac
    done
}

# ============================================================
# Initial setup
# ============================================================

check_dependencies
initialize_manager_state
prepare_manager_state

# Main manager
main_menu
