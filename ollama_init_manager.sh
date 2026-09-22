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

OLLAMA_HOST="0.0.0.0:11434"
OLLAMA_API="http://127.0.0.1:11434"
OLLAMA_MODELS="/home/ubuntu/Models"

OLLAMA_INSTALLED=false
OLLAMA_VERSION=""

MODEL_COUNT=0
MODEL_BULLETIN=""

# ─────────────────────────────────────────────────────────────
# Basic Helpers
# ─────────────────────────────────────────────────────────────

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

pause() {
    echo
    printf '%s' "Press Enter to continue, ESC/Backspace for Main Menu..."
    read -r < /dev/tty
}

header() {
    clear

    echo

    printf '%s\n' "${CYAN}${BOLD}╔══════════════════════════════════════════════════════════╗${RESET}"
    printf '%s\n' "${CYAN}${BOLD}║${WHITE}                 RUNPOD OLLAMA MANAGER                  ${CYAN}║${RESET}"
    printf '%s\n' "${CYAN}${BOLD}╚══════════════════════════════════════════════════════════╝${RESET}"

    echo
}

# ─────────────────────────────────────────────────────────────
# Navigation
#
# Return codes:
#   0 = Enter
#   10 = Back / ESC
#   1 = Other key
# ─────────────────────────────────────────────────────────────

read_navigation_key() {

    local KEY
    local REST

    IFS= read -rsn1 KEY < /dev/tty

    # Enter
    if [ -z "$KEY" ]; then
        return 0
    fi

    # Backspace
    if [ "$KEY" = $'\177' ] || [ "$KEY" = $'\b' ]; then
        return 10
    fi

    # ESC
    if [ "$KEY" = $'\e' ]; then

        # Give terminal escape sequences a short opportunity
        # to complete so arrow/function keys are not mistaken
        # for the Back command.
        if IFS= read -rsn2 -t 0.05 REST < /dev/tty; then
            return 1
        fi

        return 10
    fi

    return 1
}

page_footer() {

    echo

    printf '%s\n' "${DIM}────────────────────────────────────────────────────────────${RESET}"
    printf '%s\n' "${DIM}[ESC] / [Backspace]  Back to Main Menu    [Enter]  Continue${RESET}"

    echo
}

# ─────────────────────────────────────────────────────────────
# Navigation-only Page Pause
# ─────────────────────────────────────────────────────────────

navigation_pause() {

    while true; do

        read_navigation_key
        local RESULT=$?

        case "$RESULT" in

            0)
                return 0
                ;;

            10)
                return 10
                ;;

            *)
                ;;

        esac

    done
}

# ─────────────────────────────────────────────────────────────
# Ollama Detection
# ─────────────────────────────────────────────────────────────

check_ollama_installed() {

    if command_exists ollama; then

        OLLAMA_INSTALLED=true
        OLLAMA_VERSION=$(ollama --version 2>/dev/null || echo "unknown")

    else

        OLLAMA_INSTALLED=false
        OLLAMA_VERSION=""

    fi
}

# ─────────────────────────────────────────────────────────────
# Detect systemd
# ─────────────────────────────────────────────────────────────

is_systemd() {

    [ "$(ps -p 1 -o comm= 2>/dev/null)" = "systemd" ]
}

# ─────────────────────────────────────────────────────────────
# Detect Running Ollama
# ─────────────────────────────────────────────────────────────

ollama_running() {

    curl -fsS \
        --connect-timeout 2 \
        --max-time 3 \
        "${OLLAMA_API}/api/version" \
        >/dev/null 2>&1
}

# ─────────────────────────────────────────────────────────────
# Configure Model Directory
# ─────────────────────────────────────────────────────────────

configure_models_directory() {

    mkdir -p "$OLLAMA_MODELS"

    if id ollama >/dev/null 2>&1; then

        chown -R ollama:ollama "$OLLAMA_MODELS"

    elif id ubuntu >/dev/null 2>&1; then

        chown -R ubuntu:ubuntu "$OLLAMA_MODELS"

    fi

    chmod 755 "$OLLAMA_MODELS"
}

# ─────────────────────────────────────────────────────────────
# Dependencies
# ─────────────────────────────────────────────────────────────

check_dependencies() {

    local missing=()

    command_exists curl || missing+=("curl")
    command_exists jq || missing+=("jq")
    command_exists zstd || missing+=("zstd")

    if [ "${#missing[@]}" -eq 0 ]; then
        return 0
    fi

    printf '%s\n' "${YELLOW}→${RESET} Installing missing dependencies: ${missing[*]}"
    echo

    apt-get update

    DEBIAN_FRONTEND=noninteractive \
        apt-get install -y "${missing[@]}"

    echo

    printf '%s\n' "${GREEN}✓${RESET} Dependencies installed."
}

# ─────────────────────────────────────────────────────────────
# Local Model Bulletin
# ─────────────────────────────────────────────────────────────

refresh_model_bulletin() {

    MODEL_COUNT=0
    MODEL_BULLETIN=""

    if ! command_exists ollama; then

        MODEL_BULLETIN="  Ollama is not installed."
        return 0
    fi

    if ! ollama_running; then

        MODEL_BULLETIN="  Ollama is not currently running."
        return 0
    fi

    local RESPONSE

    RESPONSE=$(curl -fsS \
        --connect-timeout 2 \
        --max-time 5 \
        "${OLLAMA_API}/api/tags" 2>/dev/null) || {

        MODEL_BULLETIN="  Unable to query local models."
        return 0
    }

    MODEL_COUNT=$(echo "$RESPONSE" |
        jq '.models | length' 2>/dev/null || echo 0)

    if [ "$MODEL_COUNT" -eq 0 ]; then

        MODEL_BULLETIN="  No models installed."
        return 0
    fi

    MODEL_BULLETIN=$(
        echo "$RESPONSE" |
        jq -r '
            .models[]
            | "  • \(.name)\n" +
              "      " +
              (.details.parameter_size // "?") +
              "  |  " +
              (.details.quantization_level // "?") +
              "  |  " +
              (
                if .size >= 1099511627776
                then ((.size / 1099511627776 * 10 | floor) / 10 | tostring) + " TB"
                elif .size >= 1073741824
                then ((.size / 1073741824 * 10 | floor) / 10 | tostring) + " GB"
                elif .size >= 1048576
                then ((.size / 1048576 * 10 | floor) / 10 | tostring) + " MB"
                else
                  ((.size / 1024 * 10 | floor) / 10 | tostring) + " KB"
                end
              ) +
              "\n"
        '
    )
}

show_model_bulletin() {

    printf '%s\n' "${DIM}────────────────────────────────────────────────────────────${RESET}"
    printf '%s\n' "${BOLD}LOCAL MODELS${RESET}"
    printf '%s\n' "${DIM}────────────────────────────────────────────────────────────${RESET}"

    echo

    printf '%s\n' "$MODEL_BULLETIN"

    printf '%s\n' "${DIM}────────────────────────────────────────────────────────────${RESET}"

    echo
}

# ─────────────────────────────────────────────────────────────
# Start Ollama - Container Mode
# ─────────────────────────────────────────────────────────────

start_ollama_container() {

    export OLLAMA_HOST="$OLLAMA_HOST"
    export OLLAMA_MODELS="$OLLAMA_MODELS"

    nohup env \
        OLLAMA_HOST="$OLLAMA_HOST" \
        OLLAMA_MODELS="$OLLAMA_MODELS" \
        NO_COLOR=1 \
        ollama serve \
        > /var/log/ollama-runpod.log 2>&1 &

    sleep 3
}

# ─────────────────────────────────────────────────────────────
# Install / Update Ollama
# ─────────────────────────────────────────────────────────────

install_or_update_ollama() {

    header

    check_ollama_installed
    refresh_model_bulletin

    if [ "$OLLAMA_INSTALLED" = true ]; then
        printf '%s\n' "${BOLD}Update Ollama${RESET}"
    else
        printf '%s\n' "${BOLD}Install Ollama${RESET}"
    fi

    echo

    show_model_bulletin

    if ! command_exists zstd; then

        printf '%s\n' "${YELLOW}→${RESET} zstd is required by the Ollama installer."
        printf '%s\n' "${YELLOW}→${RESET} Installing zstd..."
        echo

        apt-get update

        DEBIAN_FRONTEND=noninteractive \
            apt-get install -y zstd

        echo

        printf '%s\n' "${GREEN}✓${RESET} zstd installed."
        echo
    fi

    configure_models_directory

    if [ "$OLLAMA_INSTALLED" = true ]; then
        printf '%s\n' "  Current version : ${OLLAMA_VERSION}"
    fi

    printf '%s\n' "  Model directory : ${OLLAMA_MODELS}"

    echo

    printf '%s\n' "${YELLOW}→${RESET} Installing/updating Ollama..."
    echo

    curl -fsSL https://ollama.com/install.sh | sh

    echo

    check_ollama_installed

    if [ "$OLLAMA_INSTALLED" != true ]; then

        printf '%s\n' "${RED}✗ Ollama installation failed.${RESET}"

        page_footer

        navigation_pause >/dev/null || true
        return
    fi

    printf '%s\n' "${GREEN}✓${RESET} Ollama ${OLLAMA_VERSION}"
    echo

    configure_models_directory

    if is_systemd; then

        mkdir -p /etc/systemd/system/ollama.service.d

        cat > /etc/systemd/system/ollama.service.d/override.conf <<EOF
[Service]
Environment="OLLAMA_HOST=${OLLAMA_HOST}"
Environment="OLLAMA_MODELS=${OLLAMA_MODELS}"
EOF

        systemctl daemon-reload

        printf '%s\n' "${GREEN}✓${RESET} Ollama systemd configuration updated."

    else

        printf '%s\n' "${DIM}RunPod container detected; systemd is not running.${RESET}"
        printf '%s\n' "${GREEN}✓${RESET} Ollama will run directly with ollama serve."

    fi

    echo

    if ollama_running; then

        printf '%s\n' "${YELLOW}→${RESET} Ollama is already running."
        printf '%s\n' "${YELLOW}→${RESET} Restarting with configured model directory..."

        if is_systemd; then

            systemctl restart ollama

        else

            pkill -x ollama 2>/dev/null || true

            sleep 2

            start_ollama_container

        fi

    else

        printf '%s\n' "${YELLOW}→${RESET} Starting Ollama..."

        if is_systemd; then

            systemctl enable ollama >/dev/null 2>&1 || true
            systemctl restart ollama

        else

            start_ollama_container

        fi
    fi

    sleep 3

    echo

    if ollama_running; then

        printf '%s\n' "${GREEN}✓${RESET} Ollama is running."
        printf '%s\n' "  Version : ${OLLAMA_VERSION}"
        printf '%s\n' "  API     : ${OLLAMA_API}"
        printf '%s\n' "  Models  : ${OLLAMA_MODELS}"

    else

        printf '%s\n' "${RED}✗ Ollama did not start.${RESET}"
        printf '%s\n' "${DIM}Check /var/log/ollama-runpod.log${RESET}"

    fi

    echo

    page_footer

    navigation_pause >/dev/null || true
}

# ─────────────────────────────────────────────────────────────
# Start / Restart Ollama
# ─────────────────────────────────────────────────────────────

start_ollama() {

    header

    check_ollama_installed
    refresh_model_bulletin

    printf '%s\n' "${BOLD}Start / Restart Ollama${RESET}"
    echo

    show_model_bulletin

    if ! command_exists ollama; then

        printf '%s\n' "${RED}✗ Ollama is not installed.${RESET}"
        printf '%s\n' "${DIM}Use option [1] to install Ollama.${RESET}"

        page_footer

        if navigation_pause; then
            return
        else
            return
        fi
    fi

    configure_models_directory

    printf '%s\n' "  Host   : ${OLLAMA_HOST}"
    printf '%s\n' "  Models : ${OLLAMA_MODELS}"

    echo

    if ollama_running; then

        printf '%s\n' "${YELLOW}→${RESET} Existing Ollama instance detected."
        printf '%s\n' "${YELLOW}→${RESET} Restarting..."

        if is_systemd; then
            systemctl restart ollama
        else
            pkill -x ollama 2>/dev/null || true
            sleep 2
            start_ollama_container
        fi

    else

        printf '%s\n' "${YELLOW}→${RESET} Starting Ollama..."

        if is_systemd; then
            systemctl restart ollama
        else
            start_ollama_container
        fi

    fi

    sleep 2

    echo

    if ollama_running; then
        printf '%s\n' "${GREEN}✓${RESET} Ollama is running."
    else
        printf '%s\n' "${RED}✗ Ollama failed to start.${RESET}"
        printf '%s\n' "${DIM}Check /var/log/ollama-runpod.log${RESET}"
    fi

    echo

    page_footer
    navigation_pause >/dev/null || true
}

# ─────────────────────────────────────────────────────────────
# Stop Ollama
# ─────────────────────────────────────────────────────────────

stop_ollama() {

    header

    check_ollama_installed
    refresh_model_bulletin

    printf '%s\n' "${BOLD}Stop Ollama${RESET}"
    echo

    show_model_bulletin

    if ! ollama_running; then

        printf '%s\n' "${DIM}Ollama is not running.${RESET}"

        page_footer
        navigation_pause >/dev/null || true
        return
    fi

    printf '%s\n' "${YELLOW}→${RESET} Stopping Ollama..."

    if is_systemd; then
        systemctl stop ollama
    else
        pkill -x ollama 2>/dev/null || true
    fi

    sleep 2

    echo

    if ollama_running; then
        printf '%s\n' "${RED}✗ Ollama is still running.${RESET}"
    else
        printf '%s\n' "${GREEN}✓${RESET} Ollama stopped."
    fi

    echo

    page_footer
    navigation_pause >/dev/null || true
}

# ─────────────────────────────────────────────────────────────
# Ollama Status
# ─────────────────────────────────────────────────────────────

ollama_status() {

    header

    check_ollama_installed
    refresh_model_bulletin

    printf '%s\n' "${BOLD}Ollama Status${RESET}"
    echo

    show_model_bulletin

    if [ "$OLLAMA_INSTALLED" = true ]; then

        printf '%s\n' "  Installed : ${GREEN}YES${RESET}"
        printf '%s\n' "  Version   : ${OLLAMA_VERSION}"

    else

        printf '%s\n' "  Installed : ${RED}NO${RESET}"

        page_footer
        navigation_pause >/dev/null || true
        return
    fi

    if ollama_running; then
        printf '%s\n' "  Status    : ${GREEN}RUNNING${RESET}"
    else
        printf '%s\n' "  Status    : ${RED}STOPPED${RESET}"
    fi

    echo

    printf '%s\n' "  Host      : ${OLLAMA_HOST}"
    printf '%s\n' "  API       : ${OLLAMA_API}"
    printf '%s\n' "  Models    : ${OLLAMA_MODELS}"

    echo

    if [ -d "$OLLAMA_MODELS" ]; then

        printf '%s\n' "${BOLD}Model directory${RESET}"
        printf '%s\n' "  ${OLLAMA_MODELS}"
        printf '%s\n' "  Disk usage : $(du -sh "$OLLAMA_MODELS" 2>/dev/null | awk '{print $1}')"

    fi

    page_footer
    navigation_pause >/dev/null || true
}

# ─────────────────────────────────────────────────────────────
# List Installed Models
# ─────────────────────────────────────────────────────────────

list_models() {

    header

    check_ollama_installed
    refresh_model_bulletin

    printf '%s\n' "${BOLD}Installed Ollama Models${RESET}"
    echo

    show_model_bulletin

    if ! command_exists ollama; then

        printf '%s\n' "${RED}✗ Ollama is not installed.${RESET}"

        page_footer
        navigation_pause >/dev/null || true
        return
    fi

    if ! ollama_running; then

        printf '%s\n' "${RED}✗ Ollama is not running.${RESET}"

        page_footer
        navigation_pause >/dev/null || true
        return
    fi

    NO_COLOR=1 ollama list

    echo

    printf '%s\n' "${DIM}Model directory:${RESET}"
    printf '%s\n' "${OLLAMA_MODELS}"

    page_footer
    navigation_pause >/dev/null || true
}

# ─────────────────────────────────────────────────────────────
# Refresh Local Models
# ─────────────────────────────────────────────────────────────

refresh_models_page() {

    header

    check_ollama_installed
    refresh_model_bulletin

    printf '%s\n' "${BOLD}Refresh Local Models${RESET}"
    echo

    show_model_bulletin

    printf '%s\n' "${GREEN}✓${RESET} Local model bulletin refreshed."

    page_footer
    navigation_pause >/dev/null || true
}

# ─────────────────────────────────────────────────────────────
# Pull Ollama Registry Model
# ─────────────────────────────────────────────────────────────

pull_ollama_model() {

    header

    check_ollama_installed
    refresh_model_bulletin

    printf '%s\n' "${BOLD}Pull Ollama Registry Model${RESET}"
    echo

    show_model_bulletin

    if ! command_exists ollama; then

        printf '%s\n' "${RED}✗ Ollama is not installed.${RESET}"

        page_footer
        navigation_pause >/dev/null || true
        return
    fi

    if ! ollama_running; then

        printf '%s\n' "${RED}✗ Ollama is not running.${RESET}"

        page_footer
        navigation_pause >/dev/null || true
        return
    fi

    printf '%s\n' "${DIM}Examples: qwen3:8b, qwen3-coder:30b, gpt-oss:20b${RESET}"
    echo

    printf '%s' "Model name: "
    read -r MODEL < /dev/tty

    if [ -z "$MODEL" ]; then

        printf '%s\n' "${RED}✗ No model specified.${RESET}"

        page_footer
        navigation_pause >/dev/null || true
        return
    fi

    echo

    printf '%s\n' "${YELLOW}→${RESET} Pulling ${MODEL}..."
    echo

    NO_COLOR=1 ollama pull "$MODEL"

    echo

    printf '%s\n' "${GREEN}✓${RESET} Pull complete."

    echo

    refresh_model_bulletin

    printf '%s\n' "${BOLD}Updated Local Models${RESET}"
    echo

    show_model_bulletin

    page_footer
    navigation_pause >/dev/null || true
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

    check_ollama_installed
    refresh_model_bulletin

    printf '%s\n' "${BOLD}Query Hugging Face Repository${RESET}"
    echo

    show_model_bulletin

    printf '%s\n' "${DIM}Paste a Hugging Face model repository URL.${RESET}"
    printf '%s\n' "${DIM}Example: https://huggingface.co/ggml-org/Qwen3-32B-GGUF${RESET}"

    echo

    printf '%s' "Repository URL: "
    read -r HF_URL < /dev/tty

    if [ -z "$HF_URL" ]; then

        printf '%s\n' "${RED}✗ No repository supplied.${RESET}"

        page_footer
        navigation_pause >/dev/null || true
        return
    fi

    REPO=$(parse_hf_repo "$HF_URL")

    if [[ ! "$REPO" =~ ^[^/]+/[^/]+$ ]]; then

        printf '%s\n' "${RED}✗ Invalid Hugging Face repository format.${RESET}"
        printf '%s\n' "${DIM}Expected: username/repository${RESET}"

        page_footer
        navigation_pause >/dev/null || true
        return
    fi

    echo

    printf '%s\n' "${YELLOW}→${RESET} Querying Hugging Face..."
    echo

    API_URL="https://huggingface.co/api/models/${REPO}"

    RESPONSE=$(curl -fsSL "$API_URL") || {

        printf '%s\n' "${RED}✗ Unable to query repository.${RESET}"

        page_footer
        navigation_pause >/dev/null || true
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

    page_footer
    navigation_pause >/dev/null || true
}

# ─────────────────────────────────────────────────────────────
# Pull Hugging Face GGUF
# ─────────────────────────────────────────────────────────────

pull_hf_model() {

    header

    check_ollama_installed
    refresh_model_bulletin

    printf '%s\n' "${BOLD}Pull Hugging Face GGUF Model${RESET}"
    echo

    show_model_bulletin

    if ! command_exists ollama; then

        printf '%s\n' "${RED}✗ Ollama is not installed.${RESET}"

        page_footer
        navigation_pause >/dev/null || true
        return
    fi

    if ! ollama_running; then

        printf '%s\n' "${RED}✗ Ollama is not running.${RESET}"

        page_footer
        navigation_pause >/dev/null || true
        return
    fi

    printf '%s\n' "${DIM}Paste the Hugging Face repository URL.${RESET}"
    printf '%s\n' "${DIM}Example: https://huggingface.co/ggml-org/Qwen3-32B-GGUF${RESET}"

    echo

    printf '%s' "Repository URL: "
    read -r HF_URL < /dev/tty

    if [ -z "$HF_URL" ]; then

        printf '%s\n' "${RED}✗ No repository supplied.${RESET}"

        page_footer
        navigation_pause >/dev/null || true
        return
    fi

    REPO=$(parse_hf_repo "$HF_URL")

    if [[ ! "$REPO" =~ ^[^/]+/[^/]+$ ]]; then

        printf '%s\n' "${RED}✗ Invalid Hugging Face repository format.${RESET}"

        page_footer
        navigation_pause >/dev/null || true
        return
    fi

    echo

    printf '%s\n' "${YELLOW}→${RESET} Querying available GGUF files..."
    echo

    RESPONSE=$(curl -fsSL "https://huggingface.co/api/models/${REPO}") || {

        printf '%s\n' "${RED}✗ Unable to query repository.${RESET}"

        page_footer
        navigation_pause >/dev/null || true
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

        page_footer
        navigation_pause >/dev/null || true
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

        page_footer
        navigation_pause >/dev/null || true
        return
    fi

    SELECTED_FILE="${GGUF_FILES[$((SELECTION - 1))]}"

    QUANT=$(echo "$SELECTED_FILE" |
        grep -oEi \
        '(IQ[1-4]_[A-Z_0-9]+|Q[2-8]_[A-Z0-9_]+|Q[2-8]_0|BF16|F16|F32)' |
        tail -1 || true)

    echo

    printf '%s\n' "${BOLD}Selected${RESET}"
    printf '%s\n' "  Repository : ${REPO}"
    printf '%s\n' "  File       : ${SELECTED_FILE}"
    printf '%s\n' "  Quant      : ${QUANT:-unknown}"

    echo

    if [ -n "$QUANT" ]; then
        MODEL_REF="hf.co/${REPO}:${QUANT}"
    else
        MODEL_REF="hf.co/${REPO}"
    fi

    printf '%s\n' "${BOLD}Ollama reference${RESET}"
    printf '%s\n' "  ${MODEL_REF}"

    echo

    printf '%s' "Pull this model? [y/N]: "
    read -r CONFIRM < /dev/tty

    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then

        printf '%s\n' "${DIM}Cancelled.${RESET}"

        page_footer
        navigation_pause >/dev/null || true
        return
    fi

    echo

    printf '%s\n' "${YELLOW}→${RESET} Pulling ${MODEL_REF}..."
    echo

    NO_COLOR=1 ollama pull "$MODEL_REF"

    echo

    printf '%s\n' "${GREEN}✓${RESET} Hugging Face model pulled successfully."

    echo

    refresh_model_bulletin

    printf '%s\n' "${BOLD}Updated Local Models${RESET}"
    echo

    show_model_bulletin

    page_footer
    navigation_pause >/dev/null || true
}

# ─────────────────────────────────────────────────────────────
# Show Model Details
# ─────────────────────────────────────────────────────────────

show_model() {

    header

    check_ollama_installed
    refresh_model_bulletin

    printf '%s\n' "${BOLD}Show Model Details${RESET}"
    echo

    show_model_bulletin

    if ! ollama_running; then

        printf '%s\n' "${RED}✗ Ollama is not running.${RESET}"

        page_footer
        navigation_pause >/dev/null || true
        return
    fi

    printf '%s' "Model name: "
    read -r MODEL < /dev/tty

    if [ -z "$MODEL" ]; then

        printf '%s\n' "${RED}✗ No model specified.${RESET}"

        page_footer
        navigation_pause >/dev/null || true
        return
    fi

    echo

    NO_COLOR=1 ollama show "$MODEL"

    echo

    page_footer
    navigation_pause >/dev/null || true
}

# ─────────────────────────────────────────────────────────────
# Remove Model
# ─────────────────────────────────────────────────────────────

remove_model() {

    header

    check_ollama_installed
    refresh_model_bulletin

    printf '%s\n' "${BOLD}Remove Ollama Model${RESET}"
    echo

    show_model_bulletin

    if ! ollama_running; then

        printf '%s\n' "${RED}✗ Ollama is not running.${RESET}"

        page_footer
        navigation_pause >/dev/null || true
        return
    fi

    printf '%s' "Model name: "
    read -r MODEL < /dev/tty

    if [ -z "$MODEL" ]; then

        printf '%s\n' "${RED}✗ No model specified.${RESET}"

        page_footer
        navigation_pause >/dev/null || true
        return
    fi

    echo

    printf '%s' "Remove ${MODEL}? [y/N]: "
    read -r CONFIRM < /dev/tty

    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then

        printf '%s\n' "${DIM}Cancelled.${RESET}"

        page_footer
        navigation_pause >/dev/null || true
        return
    fi

    echo

    NO_COLOR=1 ollama rm "$MODEL"

    echo

    printf '%s\n' "${GREEN}✓${RESET} Model removed."

    echo

    refresh_model_bulletin

    printf '%s\n' "${BOLD}Updated Local Models${RESET}"
    echo

    show_model_bulletin

    page_footer
    navigation_pause >/dev/null || true
}

# ─────────────────────────────────────────────────────────────
# Run Model
# ─────────────────────────────────────────────────────────────

run_model() {

    header

    check_ollama_installed
    refresh_model_bulletin

    printf '%s\n' "${BOLD}Run Ollama Model${RESET}"
    echo

    show_model_bulletin

    if ! ollama_running; then

        printf '%s\n' "${RED}✗ Ollama is not running.${RESET}"

        page_footer
        navigation_pause >/dev/null || true
        return
    fi

    printf '%s' "Model name: "
    read -r MODEL < /dev/tty

    if [ -z "$MODEL" ]; then

        printf '%s\n' "${RED}✗ No model specified.${RESET}"

        page_footer
        navigation_pause >/dev/null || true
        return
    fi

    echo

    printf '%s\n' "${GREEN}Starting ${MODEL}...${RESET}"
    echo

    NO_COLOR=1 ollama run "$MODEL"
}

# ─────────────────────────────────────────────────────────────
# Initial Setup
# ─────────────────────────────────────────────────────────────

check_dependencies
configure_models_directory

# Quiet initial Ollama detection.
check_ollama_installed

# ─────────────────────────────────────────────────────────────
# Main Menu
# ─────────────────────────────────────────────────────────────

while true; do

    header

    check_ollama_installed

    # Fresh model query every time the main menu is displayed.
    refresh_model_bulletin

    printf '%s\n' "${BOLD}Ollama Configuration${RESET}"
    echo

    if [ "$OLLAMA_INSTALLED" = true ]; then

        printf '%s\n' "  Ollama : ${GREEN}INSTALLED${RESET} ${OLLAMA_VERSION}"

    else

        printf '%s\n' "  Ollama : ${RED}NOT INSTALLED${RESET}"

    fi

    printf '%s\n' "  Models : ${OLLAMA_MODELS}"

    echo

    show_model_bulletin

    if [ "$OLLAMA_INSTALLED" = true ]; then

        printf '%s\n' "  ${CYAN}[1]${RESET}   Update Ollama"

    else

        printf '%s\n' "  ${CYAN}[1]${RESET}   Install Ollama"

    fi

    printf '%s\n' "  ${CYAN}[2]${RESET}   Start / restart Ollama"
    printf '%s\n' "  ${CYAN}[3]${RESET}   Stop Ollama"
    printf '%s\n' "  ${CYAN}[4]${RESET}   Ollama status"
    printf '%s\n' "  ${CYAN}[5]${RESET}   Refresh local models"
    printf '%s\n' "  ${CYAN}[6]${RESET}   List installed models"
    printf '%s\n' "  ${CYAN}[7]${RESET}   Pull Ollama model"
    printf '%s\n' "  ${CYAN}[8]${RESET}   Query Hugging Face repository"
    printf '%s\n' "  ${CYAN}[9]${RESET}   Pull Hugging Face GGUF"
    printf '%s\n' "  ${CYAN}[10]${RESET}  Show model details"
    printf '%s\n' "  ${CYAN}[11]${RESET}  Remove model"
    printf '%s\n' "  ${CYAN}[12]${RESET}  Run model"
    printf '%s\n' "  ${CYAN}[13]${RESET}  Exit"

    echo

    printf '%s\n' "${DIM}────────────────────────────────────────────────────────────${RESET}"

    echo

    printf '%s' "${BOLD}Select an option [1-13]:${RESET} "
    read -r OPTION < /dev/tty

    case "$OPTION" in

        1)
            install_or_update_ollama
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
            refresh_models_page
            ;;

        6)
            list_models
            ;;

        7)
            pull_ollama_model
            ;;

        8)
            query_hf_repo
            ;;

        9)
            pull_hf_model
            ;;

        10)
            show_model
            ;;

        11)
            remove_model
            ;;

        12)
            run_model
            ;;

        13)
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
