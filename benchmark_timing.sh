#!/bin/bash
###############################################################################
# benchmark_timing.sh
# Бенчмарк-скрипт: сравнение времени выполнения раздельного и каскадного
# подходов в MadGraph5 для процесса pp > go go, go > t t~ grv a
#
# Тесты:
# 1. Время генерации диаграмм (output)
# 2. Время компиляции кода (make)
# 3. Время интеграции/генерации событий (launch)
# 4. Полное время от начала до конца
###############################################################################

set -euo pipefail

MG5_DIR="/afs/cern.ch/user/k/kslizhev/public/MG5_aMC_v2_9_24"
MG5_BIN="$MG5_DIR/bin/mg5_aMC"
OUTPUT_DIR="/eos/user/k/kslizhev/MC_code/SUSY+GRV_diagrams"
BENCHMARK_DIR="$OUTPUT_DIR/benchmark"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_FILE="$BENCHMARK_DIR/benchmark_results.txt"
CSV_FILE="$BENCHMARK_DIR/benchmark_results.csv"

# --- Cleanup function ---
cleanup() {
    log "Cleaning up benchmark temporary directories..."
    rm -rf "$BENCHMARK_DIR/tmp_production" "$BENCHMARK_DIR/tmp_cascade" 2>/dev/null || true
}

log() { echo "[$(date '+%H:%M:%S')] $1"; }

time_command() {
    # Выполняет команду и возвращает время в секундах
    local START END
    START=$(date +%s%N)
    eval "$@"
    local EXIT_CODE=$?
    END=$(date +%s%N)
    local DURATION_NS=$((END - START))
    local DURATION_S=$(awk "BEGIN{printf \"%.2f\", $DURATION_NS/1000000000}")
    echo "$DURATION_S"
    return $EXIT_CODE
}

mkdir -p "$BENCHMARK_DIR"

cat > "$RESULTS_FILE" <<'HEADER'
===============================================================================
     BENCHMARK: Раздельный (production+decay) vs Каскадный расчет
     Процесс: p p > go go, go > t t~ grv a
     Модель: GldGrv_UFO
===============================================================================

HEADER

echo "test_name,approach,time_seconds,status" > "$CSV_FILE"

# ============================================================================
# TEST 1: Время генерации диаграмм (только 'output', без launch)
# ============================================================================
log "=== TEST 1: Diagram Generation Time ==="

# --- Production approach ---
cat > "$BENCHMARK_DIR/test1_prod.mg5" <<EOF
import model GldGrv_UFO
generate p p > go go
output $BENCHMARK_DIR/tmp_production
EOF

log "  Running: production (p p > go go)..."
PROD_GEN_START=$(date +%s)
"$MG5_BIN" < "$BENCHMARK_DIR/test1_prod.mg5" > "$BENCHMARK_DIR/test1_prod.log" 2>&1
PROD_GEN_END=$(date +%s)
PROD_GEN_TIME=$((PROD_GEN_END - PROD_GEN_START))
log "  Production diagram generation: ${PROD_GEN_TIME}s"

# Count diagrams
PROD_DIAGRAMS=$(grep -c "Process.*diagram" "$BENCHMARK_DIR/test1_prod.log" 2>/dev/null || echo "N/A")
PROD_DIAGRAM_COUNT=$(grep -oP '\d+ diagrams' "$BENCHMARK_DIR/test1_prod.log" 2>/dev/null | head -1 || echo "N/A")

rm -rf "$BENCHMARK_DIR/tmp_production"

# --- Cascade approach ---
cat > "$BENCHMARK_DIR/test1_cascade.mg5" <<EOF
import model GldGrv_UFO
generate p p > go go, go > t t~ grv a
output $BENCHMARK_DIR/tmp_cascade
EOF

log "  Running: cascade (p p > go go, go > t t~ grv a)..."
CASC_GEN_START=$(date +%s)
"$MG5_BIN" < "$BENCHMARK_DIR/test1_cascade.mg5" > "$BENCHMARK_DIR/test1_cascade.log" 2>&1
CASC_GEN_END=$(date +%s)
CASC_GEN_TIME=$((CASC_GEN_END - CASC_GEN_START))
log "  Cascade diagram generation: ${CASC_GEN_TIME}s"

CASC_DIAGRAM_COUNT=$(grep -oP '\d+ diagrams' "$BENCHMARK_DIR/test1_cascade.log" 2>/dev/null | head -1 || echo "N/A")

rm -rf "$BENCHMARK_DIR/tmp_cascade"

# Write results
{
    echo "TEST 1: Diagram Generation (output only)"
    echo "  Production (p p > go go):                ${PROD_GEN_TIME} seconds"
    echo "    Diagrams: ${PROD_DIAGRAM_COUNT}"
    echo "  Cascade (p p > go go, go > t t~ grv a):  ${CASC_GEN_TIME} seconds"
    echo "    Diagrams: ${CASC_DIAGRAM_COUNT}"
    if [ "$PROD_GEN_TIME" -gt 0 ]; then
        RATIO=$(awk "BEGIN{printf \"%.1f\", $CASC_GEN_TIME/$PROD_GEN_TIME}")
        echo "  Ratio (cascade/production): ${RATIO}x slower"
    fi
    echo ""
} | tee -a "$RESULTS_FILE"

echo "diagram_generation,production,${PROD_GEN_TIME},ok" >> "$CSV_FILE"
echo "diagram_generation,cascade,${CASC_GEN_TIME},ok" >> "$CSV_FILE"

# ============================================================================
# TEST 2: Полный запуск (output + launch) с минимальным числом событий
# ============================================================================
log "=== TEST 2: Full Run (output + launch, 100 events) ==="

# --- Production + MadSpin ---
cat > "$BENCHMARK_DIR/test2_prod.mg5" <<EOF
import model GldGrv_UFO
generate p p > go go
output $BENCHMARK_DIR/tmp_production
launch $BENCHMARK_DIR/tmp_production
madspin=ON
0
# MadSpin будет выполнен автоматически
decay go > t t~ grv a
done
EOF

# Reduce events to 100 for benchmarking
# We'll modify the run_card after output
cat > "$BENCHMARK_DIR/test2_prod_launch.mg5" <<EOF
import model GldGrv_UFO
generate p p > go go
output $BENCHMARK_DIR/tmp_production
launch $BENCHMARK_DIR/tmp_production
madspin=ON
set nevents 100
0
decay go > t t~ grv a
done
EOF

log "  Running: production + MadSpin (100 events)..."
PROD_FULL_START=$(date +%s)
"$MG5_BIN" < "$BENCHMARK_DIR/test2_prod_launch.mg5" > "$BENCHMARK_DIR/test2_prod.log" 2>&1 || true
PROD_FULL_END=$(date +%s)
PROD_FULL_TIME=$((PROD_FULL_END - PROD_FULL_START))
log "  Production full run: ${PROD_FULL_TIME}s"

rm -rf "$BENCHMARK_DIR/tmp_production"

# --- Cascade ---
cat > "$BENCHMARK_DIR/test2_cascade_launch.mg5" <<EOF
import model GldGrv_UFO
generate p p > go go, go > t t~ grv a
output $BENCHMARK_DIR/tmp_cascade
launch $BENCHMARK_DIR/tmp_cascade
set nevents 100
0
EOF

log "  Running: cascade (100 events)..."
CASC_FULL_START=$(date +%s)
timeout 3600 "$MG5_BIN" < "$BENCHMARK_DIR/test2_cascade_launch.mg5" > "$BENCHMARK_DIR/test2_cascade.log" 2>&1 || true
CASC_FULL_END=$(date +%s)
CASC_FULL_TIME=$((CASC_FULL_END - CASC_FULL_START))
log "  Cascade full run: ${CASC_FULL_TIME}s"

# Check if cascade timed out
CASC_STATUS="ok"
if [ "$CASC_FULL_TIME" -ge 3600 ]; then
    CASC_STATUS="timeout_1h"
    log "  WARNING: Cascade timed out after 1 hour!"
fi

rm -rf "$BENCHMARK_DIR/tmp_cascade"

# Write results
{
    echo "TEST 2: Full Run (output + launch, 100 events)"
    echo "  Production + MadSpin:  ${PROD_FULL_TIME} seconds"
    echo "  Cascade (full ME):     ${CASC_FULL_TIME} seconds (status: ${CASC_STATUS})"
    if [ "$PROD_FULL_TIME" -gt 0 ]; then
        RATIO=$(awk "BEGIN{printf \"%.1f\", $CASC_FULL_TIME/$PROD_FULL_TIME}")
        echo "  Ratio (cascade/production): ${RATIO}x"
    fi
    echo ""
} | tee -a "$RESULTS_FILE"

echo "full_run_100ev,production,${PROD_FULL_TIME},ok" >> "$CSV_FILE"
echo "full_run_100ev,cascade,${CASC_FULL_TIME},${CASC_STATUS}" >> "$CSV_FILE"

# ============================================================================
# TEST 3: Подсчет числа диаграмм (аналитический)
# ============================================================================
log "=== TEST 3: Diagram Count Analysis ==="

{
    echo "TEST 3: Theoretical Diagram Count Analysis"
    echo ""
    echo "  Production: p p > go go"
    echo "    - Начальные: q qbar > go go (s-канал глюон)"
    echo "    - Начальные: g g > go go (s,t,u каналы + контактное)"
    echo "    - Типичное число: O(10) диаграмм"
    echo ""
    echo "  Cascade: p p > go go, go > t t~ grv a"
    echo "    - Каждый go распадается в 4-частичное состояние: t t~ grv a"
    echo "    - Число промежуточных диаграмм в одном распаде: O(10-100)"
    echo "    - Полное число диаграмм = (production) x (decay1) x (decay2)"
    echo "    - При каскадном расчете все интерференции учитываются"
    echo "    - Фазовое пространство: 2->2 vs 2->10 (2 + 4 + 4 конечных частиц)"
    echo "    - Типичное число: O(1000-10000+) диаграмм"
    echo ""
    echo "  Log files from TEST 1 contain exact diagram counts."
    echo ""
    echo "  Production log diagrams:"
    grep -i "diagram" "$BENCHMARK_DIR/test1_prod.log" 2>/dev/null | head -10 || echo "  (see test1_prod.log)"
    echo ""
    echo "  Cascade log diagrams:"
    grep -i "diagram" "$BENCHMARK_DIR/test1_cascade.log" 2>/dev/null | head -10 || echo "  (see test1_cascade.log)"
    echo ""
} | tee -a "$RESULTS_FILE"

# ============================================================================
# Summary
# ============================================================================
{
    echo "==============================================================================="
    echo "SUMMARY"
    echo "==============================================================================="
    echo ""
    echo "  Diagram generation:  production=${PROD_GEN_TIME}s  cascade=${CASC_GEN_TIME}s"
    echo "  Full run (100 ev):   production=${PROD_FULL_TIME}s  cascade=${CASC_FULL_TIME}s"
    echo ""
    echo "  CSV results: $CSV_FILE"
    echo "  Detailed logs: $BENCHMARK_DIR/test[12]_*.log"
    echo "==============================================================================="
} | tee -a "$RESULTS_FILE"

log "Benchmark complete. Results in $RESULTS_FILE"
