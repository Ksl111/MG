#!/bin/bash
###############################################################################
# benchmark_cascade.sh
#
# Расширенный бенчмарк каскадного расчёта:
#   p p > go go, go > t t~ grv a  (full matrix element)
#
# Этапы:
#   1. Output (generate + compile) — один раз
#   2. Launch при 10, 50, 100, 500, 1000, 5000, 10000 событиях
#      с извлечением сечения и погрешности
#
# Мониторинг: CPU% + RAM (RSS) каждые 2 секунды с привязкой к этапу.
# Выходные CSV содержат полный временной ряд ресурсов.
###############################################################################

set -euo pipefail

# =========================== Конфигурация ===================================
MG5_DIR="/afs/cern.ch/user/k/kslizhev/public/MG5_aMC_v2_9_24"
MG5_BIN="$MG5_DIR/bin/mg5_aMC"
OUTPUT_DIR="/eos/user/k/kslizhev/MC_code/SUSY+GRV_diagrams"
BENCHMARK_DIR="$OUTPUT_DIR/benchmark_cascade"

RESULTS_FILE="$BENCHMARK_DIR/cascade_results.txt"
CSV_TIMING="$BENCHMARK_DIR/cascade_timing.csv"
CSV_XSEC="$BENCHMARK_DIR/cascade_xsections.csv"
RESOURCE_LOG="$BENCHMARK_DIR/cascade_resource_trace.csv"

NEVENTS_LIST=(10 50 100 500 1000 5000 10000)

# =========================== Утилиты ========================================
log() { echo "[$(date '+%H:%M:%S')] $1"; }

format_time() {
    local s="$1"
    if [ "$s" -ge 3600 ]; then printf "%dh %dm %ds" $((s/3600)) $(((s%3600)/60)) $((s%60))
    elif [ "$s" -ge 60 ]; then printf "%dm %ds" $((s/60)) $((s%60))
    else printf "%ds" "$s"; fi
}

format_kb() {
    local k="$1"
    if [ "$k" -ge 1048576 ]; then awk "BEGIN{printf \"%.1f GB\",$k/1048576}"
    elif [ "$k" -ge 1024 ]; then awk "BEGIN{printf \"%.1f MB\",$k/1024}"
    else echo "${k} KB"; fi
}

# =========================== Монитор ресурсов ===============================
MONITOR_PID=""
STAGE_FILE=""

start_resource_monitor() {
    STAGE_FILE="$BENCHMARK_DIR/.current_stage"
    echo "init" > "$STAGE_FILE"

    (
        while true; do
            STAGE=$(cat "$STAGE_FILE" 2>/dev/null || echo "unknown")
            TS=$(date '+%Y-%m-%d %H:%M:%S')

            DATA=$(ps -eo pcpu,rss,comm 2>/dev/null \
                | awk '/mg5_aMC|madevent|python|gfortran|f951|cc1|collect2|ld|Survey|Refine|combine|gensym|check/{
                    cpu+=$1; rss+=$2
                } END{printf "%.1f %d", cpu, rss}')
            CPU_PCT=$(echo "$DATA" | awk '{print $1}')
            RSS_KB=$(echo "$DATA" | awk '{print $2}')

            echo "${TS},${STAGE},${CPU_PCT},${RSS_KB}" >> "$RESOURCE_LOG"
            sleep 2
        done
    ) &
    MONITOR_PID=$!
}

stop_resource_monitor() {
    if [ -n "$MONITOR_PID" ]; then
        kill "$MONITOR_PID" 2>/dev/null || true
        wait "$MONITOR_PID" 2>/dev/null || true
        MONITOR_PID=""
    fi
    rm -f "$STAGE_FILE" 2>/dev/null || true
}

set_stage() {
    echo "$1" > "$STAGE_FILE" 2>/dev/null || true
    log "  >> Stage: $1"
}

# avg_cpu peak_cpu avg_ram_kb peak_ram_kb sample_count
stage_resource_summary() {
    local STAGE="$1"
    awk -F',' -v st="$STAGE" '
        $2 == st { cpu+=$3; rss+=$4; n++;
                   if($3>pcpu) pcpu=$3;
                   if($4>prss) prss=$4 }
        END {
            if(n>0) printf "%.1f %.1f %d %d %d", cpu/n, pcpu, rss/n, prss, n;
            else    printf "0 0 0 0 0"
        }' "$RESOURCE_LOG"
}

# =========================== Запуск MG5 теста ===============================
# run_test <label> <mg5_script> <log_file> <stage_prefix> [timeout]
#
# Результат:  TEST_TIME  TEST_STATUS  TEST_DIAGRAMS  TEST_XSEC  TEST_XSEC_ERR
run_test() {
    local LABEL="$1" SCRIPT="$2" LOGF="$3" STAGE_PFX="$4"
    local TIMEOUT="${5:-7200}"

    set_stage "${STAGE_PFX}"
    log "  [$LABEL] Starting..."

    local T0 T1
    T0=$(date +%s)
    timeout "$TIMEOUT" "$MG5_BIN" < "$SCRIPT" > "$LOGF" 2>&1
    local RC=$?
    T1=$(date +%s)
    TEST_TIME=$((T1 - T0))

    if   [ "$RC" -eq 124 ]; then TEST_STATUS="timeout"
    elif [ "$RC" -ne 0 ];   then TEST_STATUS="error(rc=$RC)"
    else                         TEST_STATUS="ok"; fi

    # Диаграммы
    TEST_DIAGRAMS=$(grep -oP '\d+ diagrams?' "$LOGF" 2>/dev/null | paste -sd '; ' || echo "N/A")
    [ -z "$TEST_DIAGRAMS" ] && TEST_DIAGRAMS="N/A"

    # Сечение: ищем "Cross-section :" в логе
    TEST_XSEC=$(grep -oP 'Cross-section\s*:\s*\K[0-9.eE+\-]+' "$LOGF" 2>/dev/null | tail -1 || echo "N/A")
    [ -z "$TEST_XSEC" ] && TEST_XSEC="N/A"

    # Погрешность: ищем "+- X" после сечения
    TEST_XSEC_ERR=$(grep -oP 'Cross-section\s*:.*\+-\s*\K[0-9.eE+\-]+' "$LOGF" 2>/dev/null | tail -1 || echo "N/A")
    [ -z "$TEST_XSEC_ERR" ] && TEST_XSEC_ERR="N/A"

    # Ресурсы за этот stage
    local RES
    RES=$(stage_resource_summary "${STAGE_PFX}")
    local AVG_CPU PEAK_CPU AVG_RAM PEAK_RAM SAMPLES
    read -r AVG_CPU PEAK_CPU AVG_RAM PEAK_RAM SAMPLES <<< "$RES"

    local TIME_FMT PEAK_RAM_FMT AVG_RAM_FMT
    TIME_FMT=$(format_time "$TEST_TIME")
    PEAK_RAM_FMT=$(format_kb "$PEAK_RAM")
    AVG_RAM_FMT=$(format_kb "$AVG_RAM")

    log "  [$LABEL] Done: ${TIME_FMT} | status: ${TEST_STATUS}"
    log "  [$LABEL] CPU: avg=${AVG_CPU}% peak=${PEAK_CPU}% | RAM: avg=${AVG_RAM_FMT} peak=${PEAK_RAM_FMT} (${SAMPLES} samples)"
    [ "$TEST_DIAGRAMS" != "N/A" ] && log "  [$LABEL] Diagrams: ${TEST_DIAGRAMS}"
    [ "$TEST_XSEC" != "N/A" ] && log "  [$LABEL] Cross-section: ${TEST_XSEC} +- ${TEST_XSEC_ERR} pb"

    # Ошибки
    local ERRS
    ERRS=$(grep -iE "error|fatal|traceback|exception" "$LOGF" 2>/dev/null | grep -iv "no error" | head -5 || true)
    if [ -n "$ERRS" ]; then
        log "  [$LABEL] ERRORS in log:"
        echo "$ERRS" | while IFS= read -r line; do log "    > $line"; done
    fi

    # Записываем в текстовый отчёт
    {
        echo "  [$LABEL]"
        echo "    Time:           ${TEST_TIME}s ($TIME_FMT)"
        echo "    Status:         $TEST_STATUS"
        echo "    CPU avg/peak:   ${AVG_CPU}% / ${PEAK_CPU}%"
        echo "    RAM avg/peak:   ${AVG_RAM_FMT} / ${PEAK_RAM_FMT}"
        [ "$TEST_DIAGRAMS" != "N/A" ] && echo "    Diagrams:       $TEST_DIAGRAMS"
        [ "$TEST_XSEC" != "N/A" ] && echo "    Cross-section:  ${TEST_XSEC} +- ${TEST_XSEC_ERR} pb"
        echo ""
    } >> "$RESULTS_FILE"

    # CSV timing
    echo "${LABEL},${STAGE_PFX},${TEST_TIME},${AVG_CPU},${PEAK_CPU},${AVG_RAM},${PEAK_RAM},${TEST_STATUS}" >> "$CSV_TIMING"
}

# =========================== Cleanup ========================================
cleanup() {
    stop_resource_monitor
    log "Cleaning up tmp directories..."
    rm -rf "$BENCHMARK_DIR"/tmp_* 2>/dev/null || true
}
trap cleanup EXIT

# ============================================================================
#                         НАЧАЛО БЕНЧМАРКА
# ============================================================================

mkdir -p "$BENCHMARK_DIR"

SYS_CPU=$(nproc 2>/dev/null || echo "N/A")
SYS_RAM_KB=$(awk '/MemTotal/{print $2}' /proc/meminfo 2>/dev/null || echo "0")
SYS_RAM_FMT=$(format_kb "$SYS_RAM_KB")
BENCH_START=$(date +%s)
BENCH_DATE=$(date '+%Y-%m-%d %H:%M:%S')

cat > "$RESULTS_FILE" <<EOF
===============================================================================
  CASCADE BENCHMARK:  p p > go go, go > t t~ grv a  (full ME)
  Model: GldGrv_UFO
  Date:  $BENCH_DATE
  System: $SYS_CPU CPU cores, $SYS_RAM_FMT RAM
  Nevents: ${NEVENTS_LIST[*]}
===============================================================================

EOF

echo "label,stage,time_sec,avg_cpu_pct,peak_cpu_pct,avg_ram_kb,peak_ram_kb,status" > "$CSV_TIMING"
echo "nevents,time_sec,cross_section_pb,xsec_error_pb,status" > "$CSV_XSEC"
echo "timestamp,stage,cpu_pct,rss_kb" > "$RESOURCE_LOG"

start_resource_monitor

# ============================================================================
# PHASE 1: Output (generate + compile) — один раз
# ============================================================================
log "========== PHASE 1: Output (diagram generation + compilation) =========="
{
    echo "PHASE 1: Output (generate + compile)"
    echo "  Process: p p > go go, go > t t~ grv a"
    echo "-----------------------------------------------------------"
} >> "$RESULTS_FILE"

CASCADE_DIR="$BENCHMARK_DIR/tmp_cascade_output"
cat > "$BENCHMARK_DIR/phase1_output.mg5" <<EOF
import model GldGrv_UFO
generate p p > go go, go > t t~ grv a
output $CASCADE_DIR
EOF

run_test "cascade_output" "$BENCHMARK_DIR/phase1_output.mg5" "$BENCHMARK_DIR/phase1_output.log" "phase1_output" 7200
OUTPUT_TIME=$TEST_TIME

# Резолвим путь (EOS FUSE: /eos/user/k/... -> /eos/home-k/...)
CASCADE_DIR=$(realpath "$CASCADE_DIR")
log "  Resolved output dir: $CASCADE_DIR"

# Проверяем что output успешен
if [ ! -f "$CASCADE_DIR/SubProcesses/procdef_mg5.dat" ]; then
    log "FATAL: Output failed — procdef_mg5.dat not found at $CASCADE_DIR/SubProcesses/"
    log "Cannot proceed with launch tests."
    exit 1
fi

log "  Output verified: procdef_mg5.dat exists"

# ============================================================================
# PHASE 2: Launch при разном числе событий
# ============================================================================
log "========== PHASE 2: Launch scaling (${NEVENTS_LIST[*]}) =========="
{
    echo ""
    echo "PHASE 2: Launch with varying nevents"
    echo "  Output directory (reused): $CASCADE_DIR"
    echo "-----------------------------------------------------------"
} >> "$RESULTS_FILE"

for NEV in "${NEVENTS_LIST[@]}"; do
    LABEL="launch_${NEV}ev"

    cat > "$BENCHMARK_DIR/${LABEL}.mg5" <<EOF
launch $CASCADE_DIR
set nevents $NEV
0
EOF

    run_test "$LABEL" "$BENCHMARK_DIR/${LABEL}.mg5" "$BENCHMARK_DIR/${LABEL}.log" "${LABEL}" 14400

    echo "${NEV},${TEST_TIME},${TEST_XSEC},${TEST_XSEC_ERR},${TEST_STATUS}" >> "$CSV_XSEC"

    # Прерываем если timeout — дальше будет ещё дольше
    if [ "$TEST_STATUS" = "timeout" ]; then
        log "  WARNING: Timeout at nevents=$NEV. Skipping larger runs."
        # Записываем оставшиеся как skipped
        SKIP=false
        for REMAINING_NEV in "${NEVENTS_LIST[@]}"; do
            if [ "$SKIP" = true ]; then
                echo "${REMAINING_NEV},0,N/A,N/A,skipped(prev_timeout)" >> "$CSV_XSEC"
                {
                    echo "  [launch_${REMAINING_NEV}ev]"
                    echo "    Status: skipped (previous nevents=$NEV timed out)"
                    echo ""
                } >> "$RESULTS_FILE"
            fi
            [ "$REMAINING_NEV" -eq "$NEV" ] && SKIP=true
        done
        break
    fi
done

# Cleanup output directory
rm -rf "$CASCADE_DIR"

# ============================================================================
# Останавливаем монитор
# ============================================================================
set_stage "analysis"
stop_resource_monitor

BENCH_END=$(date +%s)
BENCH_TOTAL=$((BENCH_END - BENCH_START))

# ============================================================================
# Ресурсный профиль по этапам
# ============================================================================
{
    echo ""
    echo "==============================================================================="
    echo "  RESOURCE PROFILE BY STAGE"
    echo "==============================================================================="
    echo ""
    printf "  %-25s | %7s | %7s | %10s | %10s | %5s\n" \
           "Stage" "avgCPU%" "peakCPU%" "avgRAM" "peakRAM" "N"
    printf "  %-25s-|-%7s-|-%7s-|-%10s-|-%10s-|-%5s\n" \
           "-------------------------" "-------" "-------" "----------" "----------" "-----"

    tail -n +2 "$RESOURCE_LOG" | awk -F',' '{print $2}' | sort -u | while read -r STAGE; do
        [ "$STAGE" = "init" ] && continue
        [ "$STAGE" = "analysis" ] && continue
        RES=$(stage_resource_summary "$STAGE")
        read -r AC PC AR PR N <<< "$RES"
        AR_FMT=$(format_kb "$AR")
        PR_FMT=$(format_kb "$PR")
        printf "  %-25s | %6s%% | %6s%% | %10s | %10s | %5s\n" \
               "$STAGE" "$AC" "$PC" "$AR_FMT" "$PR_FMT" "$N"
    done
    echo ""
} | tee -a "$RESULTS_FILE"

# ============================================================================
# Таблица: сечение vs число событий
# ============================================================================
{
    echo "==============================================================================="
    echo "  CROSS-SECTION vs NEVENTS  (cascade: p p > go go, go > t t~ grv a)"
    echo "==============================================================================="
    echo ""
    printf "  %8s | %12s | %18s | %18s | %s\n" \
           "Nevents" "Time" "Cross-section [pb]" "Error [pb]" "Status"
    printf "  %8s-|-%12s-|-%18s-|-%18s-|-%s\n" \
           "--------" "------------" "------------------" "------------------" "--------"

    tail -n +2 "$CSV_XSEC" | while IFS=',' read -r NEV TIME XSEC XERR STATUS; do
        if [ "$TIME" -gt 0 ] 2>/dev/null; then
            TIME_FMT=$(format_time "$TIME")
        else
            TIME_FMT="—"
        fi
        [ "$XSEC" = "N/A" ] && XSEC="—"
        [ "$XERR" = "N/A" ] && XERR="—"
        printf "  %8s | %12s | %18s | %18s | %s\n" \
               "$NEV" "$TIME_FMT" "$XSEC" "$XERR" "$STATUS"
    done
    echo ""
    echo "  Ожидание: сечение не зависит от nevents (определяется интеграцией)."
    echo "  Вариации — статистическая погрешность Monte Carlo."
    echo "  Время launch растёт с nevents (больше точек фазового пространства)."
    echo ""
} | tee -a "$RESULTS_FILE"

# ============================================================================
# Итоговое ранжирование
# ============================================================================
{
    echo "==============================================================================="
    echo "  TIMING SUMMARY"
    echo "==============================================================================="
    echo ""
    printf "  %-25s | %12s | %7s | %10s | %s\n" \
           "Stage" "Time" "peakCPU" "peakRAM" "Status"
    printf "  %-25s-|-%12s-|-%7s-|-%10s-|-%s\n" \
           "-------------------------" "------------" "-------" "----------" "--------"

    tail -n +2 "$CSV_TIMING" | sort -t',' -k3 -n -r | while IFS=',' read -r LAB STG TM AC PC AR PR ST; do
        TM_FMT=$(format_time "$TM")
        PR_FMT=$(format_kb "$PR")
        printf "  %-25s | %12s | %6s%% | %10s | %s\n" \
               "$LAB" "$TM_FMT" "$PC" "$PR_FMT" "$ST"
    done
    echo ""
} | tee -a "$RESULTS_FILE"

# ============================================================================
# Итого
# ============================================================================
{
    echo "==============================================================================="
    echo "  SUMMARY"
    echo "==============================================================================="
    echo ""
    echo "  Output phase (generate + compile): ${OUTPUT_TIME}s ($(format_time $OUTPUT_TIME))"
    echo "  Total benchmark time: $(format_time $BENCH_TOTAL)"
    echo ""
    echo "  Output files:"
    echo "    Report:          $RESULTS_FILE"
    echo "    Timing CSV:      $CSV_TIMING"
    echo "    Cross-sect CSV:  $CSV_XSEC"
    echo "    Resource trace:  $RESOURCE_LOG"
    echo "    MG5 logs:        $BENCHMARK_DIR/*.log"
    echo ""
    echo "==============================================================================="
} | tee -a "$RESULTS_FILE"

log "Cascade benchmark complete. Results: $RESULTS_FILE"
