#!/bin/bash
###############################################################################
# run_madgraph.sh
# Основной скрипт запуска MadGraph5 для расчета SUSY+GRV процессов
#
# Использование:
#   ./run_madgraph.sh [production|cascade|both] [--monitor] [--dry-run]
#
# Примеры:
#   ./run_madgraph.sh production              # Только раздельный расчет
#   ./run_madgraph.sh cascade --monitor       # Каскадный с мониторингом
#   ./run_madgraph.sh both --monitor          # Оба с мониторингом
#   ./run_madgraph.sh production --dry-run    # Проверка без запуска
###############################################################################

set -euo pipefail

# --- Конфигурация ---
MG5_DIR="/afs/cern.ch/user/k/kslizhev/public/MG5_aMC_v2_9_24"
MG5_BIN="$MG5_DIR/bin/mg5_aMC"
OUTPUT_DIR="/eos/user/k/kslizhev/MC_code/SUSY+GRV_diagrams"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MODE="${1:-production}"
MONITOR=false
DRY_RUN=false

# Parse flags
shift || true
for arg in "$@"; do
    case "$arg" in
        --monitor) MONITOR=true ;;
        --dry-run) DRY_RUN=true ;;
        *) echo "Unknown option: $arg"; exit 1 ;;
    esac
done

# --- Functions ---
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"; }

run_mg5() {
    local SCRIPT_FILE="$1"
    local LABEL="$2"
    local LOG_DIR="$OUTPUT_DIR/logs"
    mkdir -p "$LOG_DIR"

    local MG5_LOG="$LOG_DIR/${LABEL}_$(date '+%Y%m%d_%H%M%S').log"
    local MONITOR_PID=""

    log "Starting MadGraph5: $LABEL"
    log "  Command file: $SCRIPT_FILE"
    log "  MG5 log: $MG5_LOG"

    if [ "$DRY_RUN" = true ]; then
        log "[DRY-RUN] Would execute: $MG5_BIN < $SCRIPT_FILE"
        return 0
    fi

    # Start resource monitor if requested
    if [ "$MONITOR" = true ]; then
        local MONITOR_LOG="$LOG_DIR/${LABEL}_resources_$(date '+%Y%m%d_%H%M%S').csv"
        log "  Resource monitor log: $MONITOR_LOG"
        bash "$SCRIPT_DIR/monitor_resources.sh" auto 10 "$MONITOR_LOG" &
        MONITOR_PID=$!
        log "  Monitor PID: $MONITOR_PID"
    fi

    # Record start time
    local START_TIME
    START_TIME=$(date +%s)

    # Run MadGraph5
    "$MG5_BIN" < "$SCRIPT_FILE" 2>&1 | tee "$MG5_LOG"
    local MG5_EXIT=${PIPESTATUS[0]}

    # Record end time
    local END_TIME
    END_TIME=$(date +%s)
    local DURATION=$((END_TIME - START_TIME))

    # Stop monitor
    if [ -n "$MONITOR_PID" ]; then
        kill "$MONITOR_PID" 2>/dev/null || true
        wait "$MONITOR_PID" 2>/dev/null || true
    fi

    # Report
    local HOURS=$((DURATION / 3600))
    local MINS=$(( (DURATION % 3600) / 60 ))
    local SECS=$((DURATION % 60))

    log "Completed: $LABEL"
    log "  Exit code: $MG5_EXIT"
    log "  Duration: ${HOURS}h ${MINS}m ${SECS}s (${DURATION} seconds total)"

    # Save timing info
    echo "${LABEL},${DURATION},${MG5_EXIT}" >> "$LOG_DIR/timing_results.csv"

    return $MG5_EXIT
}

# --- Pre-flight checks ---
log "=== Pre-flight checks ==="

# Run dependency check
if ! bash "$SCRIPT_DIR/check_dependencies.sh"; then
    log "ERROR: Dependency check failed. Aborting."
    exit 1
fi

# Create output directory
mkdir -p "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR/logs"

log ""
log "=== Configuration ==="
log "  Mode: $MODE"
log "  MG5 dir: $MG5_DIR"
log "  Output: $OUTPUT_DIR"
log "  Monitor: $MONITOR"
log "  Dry run: $DRY_RUN"
log ""

# --- Execute ---
case "$MODE" in
    production)
        log "=== Running: Production + Decay (factorized via MadSpin) ==="
        run_mg5 "$SCRIPT_DIR/run_production_decay.mg5" "production_decay"
        ;;
    cascade)
        log "=== Running: Cascade (full matrix element) ==="
        run_mg5 "$SCRIPT_DIR/run_cascade.mg5" "cascade"
        ;;
    both)
        log "=== Running both modes for comparison ==="
        log ""
        log "--- Phase 1: Production + Decay (factorized) ---"
        run_mg5 "$SCRIPT_DIR/run_production_decay.mg5" "production_decay"
        log ""
        log "--- Phase 2: Cascade (full ME) ---"
        run_mg5 "$SCRIPT_DIR/run_cascade.mg5" "cascade"
        log ""
        log "=== Both runs complete. See $OUTPUT_DIR/logs/timing_results.csv ==="
        ;;
    *)
        echo "Usage: $0 [production|cascade|both] [--monitor] [--dry-run]"
        exit 1
        ;;
esac

log "Done."
