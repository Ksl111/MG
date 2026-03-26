#!/bin/bash
###############################################################################
# benchmark_timing.sh
#
# Бенчмарк MadGraph5: сравнение MadSpin vs каскадного расчёта
# для процесса p p > go go, go > t t~ grv a
#
# Тесты:
#   1. Генерация диаграмм: MadSpin (p p > go go) vs cascade (полный)
#   2. Launch при 10 / 100 / 10000 событиях — время + сечение (MadSpin)
#   3. Launch при 10 / 100 / 10000 событиях — время + сечение (cascade)
#   4. Процессы с go в конечном состоянии: p p > go go, go go g, go go j, go go a
#
# Мониторинг: CPU% + RAM (RSS) каждые 2 секунды с привязкой к этапу.
###############################################################################

set -euo pipefail

# =========================== Конфигурация ===================================
MG5_DIR="/afs/cern.ch/user/k/kslizhev/public/MG5_aMC_v2_9_24"
MG5_BIN="$MG5_DIR/bin/mg5_aMC"
OUTPUT_DIR="/eos/user/k/kslizhev/MC_code/SUSY+GRV_diagrams"
BENCHMARK_DIR="$OUTPUT_DIR/benchmark"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RESULTS_FILE="$BENCHMARK_DIR/benchmark_results.txt"
CSV_TIMING="$BENCHMARK_DIR/timing.csv"
CSV_XSEC="$BENCHMARK_DIR/cross_sections.csv"
RESOURCE_LOG="$BENCHMARK_DIR/resource_trace.csv"

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
# Пишет в RESOURCE_LOG каждые 2с: timestamp, stage, cpu%, rss_kb
# Глобальные переменные:
#   MONITOR_PID   — PID фонового процесса
#   CURRENT_STAGE — текущий этап (atomic-safe запись через файл)
MONITOR_PID=""
STAGE_FILE=""

start_resource_monitor() {
    STAGE_FILE="$BENCHMARK_DIR/.current_stage"
    echo "init" > "$STAGE_FILE"

    (
        while true; do
            local STAGE
            STAGE=$(cat "$STAGE_FILE" 2>/dev/null || echo "unknown")
            local TS
            TS=$(date '+%Y-%m-%d %H:%M:%S')

            # Суммируем CPU% и RSS по всем процессам MG5-дерева
            local DATA
            DATA=$(ps -eo pcpu,rss,comm 2>/dev/null \
                | awk '/mg5_aMC|madevent|python|gfortran|f951|cc1|collect2|ld|Survey|Refine|combine|gensym|check/{
                    cpu+=$1; rss+=$2
                } END{printf "%.1f %d", cpu, rss}')
            local CPU_PCT RSS_KB
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

# Вычисляет статистику ресурсов для заданного stage из RESOURCE_LOG
# stage_resource_summary <stage_name>
# Выводит: avg_cpu peak_cpu avg_ram_kb peak_ram_kb sample_count
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
# Результат в глобальных переменных:
#   TEST_TIME TEST_STATUS TEST_DIAGRAMS TEST_XSEC
run_test() {
    local LABEL="$1"
    local SCRIPT="$2"
    local LOGF="$3"
    local STAGE_PFX="$4"
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
    else                         TEST_STATUS="ok"
    fi

    # Диаграммы
    TEST_DIAGRAMS=$(grep -oP '\d+ diagrams?' "$LOGF" 2>/dev/null | paste -sd '; ' || echo "N/A")
    [ -z "$TEST_DIAGRAMS" ] && TEST_DIAGRAMS="N/A"

    # Сечение (ищем "Cross-section :" в логе MG5)
    TEST_XSEC=$(grep -oP 'Cross-section\s*:\s*\K[0-9.eE+\-]+' "$LOGF" 2>/dev/null | tail -1 || echo "N/A")
    [ -z "$TEST_XSEC" ] && TEST_XSEC="N/A"

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
    log "  [$LABEL] Diagrams: ${TEST_DIAGRAMS}"
    [ "$TEST_XSEC" != "N/A" ] && log "  [$LABEL] Cross-section: ${TEST_XSEC} pb"

    # Ошибки
    local ERRS
    ERRS=$(grep -iE "error|fatal|traceback|exception" "$LOGF" 2>/dev/null | grep -iv "no error" | head -5 || true)
    if [ -n "$ERRS" ]; then
        log "  [$LABEL] ERRORS in log:"
        echo "$ERRS" | while IFS= read -r line; do log "    > $line"; done
    fi

    # Записываем в отчёт
    {
        echo "  [$LABEL]"
        echo "    Time:         ${TEST_TIME}s ($TIME_FMT)"
        echo "    Status:       $TEST_STATUS"
        echo "    CPU avg/peak: ${AVG_CPU}% / ${PEAK_CPU}%"
        echo "    RAM avg/peak: ${AVG_RAM_FMT} / ${PEAK_RAM_FMT}"
        echo "    Diagrams:     $TEST_DIAGRAMS"
        [ "$TEST_XSEC" != "N/A" ] && echo "    Cross-section: ${TEST_XSEC} pb"
        echo ""
    } >> "$RESULTS_FILE"

    # CSV
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
#                         НАЧАЛО БЕНЧМАРКОВ
# ============================================================================

# --- Удаляем предыдущие результаты ---
log "Cleaning previous benchmark results in $BENCHMARK_DIR ..."
rm -rf "$BENCHMARK_DIR" 2>/dev/null || true
mkdir -p "$BENCHMARK_DIR"

# --- Системная информация ---
SYS_CPU=$(nproc 2>/dev/null || echo "N/A")
SYS_RAM_KB=$(awk '/MemTotal/{print $2}' /proc/meminfo 2>/dev/null || echo "0")
SYS_RAM_FMT=$(format_kb "$SYS_RAM_KB")
BENCH_START=$(date +%s)
BENCH_DATE=$(date '+%Y-%m-%d %H:%M:%S')

cat > "$RESULTS_FILE" <<EOF
===============================================================================
  BENCHMARK: MadGraph5  p p > go go, go > t t~ grv a
  Comparison: MadSpin (factorized)  vs  Cascade (full ME)
  Model: GldGrv_UFO
  Date: $BENCH_DATE
  System: $SYS_CPU CPU cores, $SYS_RAM_FMT RAM
===============================================================================

EOF

# CSV заголовки
echo "label,stage,time_sec,avg_cpu_pct,peak_cpu_pct,avg_ram_kb,peak_ram_kb,status" > "$CSV_TIMING"
echo "label,approach,nevents,time_sec,cross_section_pb,status" > "$CSV_XSEC"

# Стартуем непрерывный монитор ресурсов
echo "timestamp,stage,cpu_pct,rss_kb" > "$RESOURCE_LOG"
start_resource_monitor

# ============================================================================
# TEST 1: Генерация диаграмм — MadSpin vs Cascade
# ============================================================================
log "========== TEST 1: Diagram Generation =========="
{
    echo "TEST 1: Diagram Generation (output only, no launch)"
    echo "  MadSpin approach:  generate p p > go go"
    echo "  Cascade approach:  generate p p > go go, go > t t~ grv a"
    echo "-----------------------------------------------------------"
} >> "$RESULTS_FILE"

# 1a: MadSpin (только production)
cat > "$BENCHMARK_DIR/t1a.mg5" <<EOF
import model GldGrv_UFO
generate p p > go go
output $BENCHMARK_DIR/tmp_t1a
EOF
run_test "t1a_madspin_diagrams" "$BENCHMARK_DIR/t1a.mg5" "$BENCHMARK_DIR/t1a.log" "t1a_diag_madspin"
T1A_TIME=$TEST_TIME
rm -rf "$BENCHMARK_DIR/tmp_t1a"

# 1b: Cascade
cat > "$BENCHMARK_DIR/t1b.mg5" <<EOF
import model GldGrv_UFO
generate p p > go go, go > t t~ grv a
output $BENCHMARK_DIR/tmp_t1b
EOF
run_test "t1b_cascade_diagrams" "$BENCHMARK_DIR/t1b.mg5" "$BENCHMARK_DIR/t1b.log" "t1b_diag_cascade" 3600
T1B_TIME=$TEST_TIME
rm -rf "$BENCHMARK_DIR/tmp_t1b"

{
    echo "  >> Comparison (diagram generation):"
    if [ "$T1A_TIME" -gt 0 ]; then
        RATIO=$(awk "BEGIN{printf \"%.1f\", $T1B_TIME/$T1A_TIME}")
        echo "     Cascade is ${RATIO}x slower than MadSpin diagram gen"
    fi
    echo ""
} | tee -a "$RESULTS_FILE"

# ============================================================================
# TEST 2: Launch MadSpin при разном числе событий (10, 100, 10000)
#         output один раз, затем только launch с разным nevents
# ============================================================================
log "========== TEST 2: MadSpin launch scaling (nevents) =========="
{
    echo "TEST 2: MadSpin Launch — nevents scaling + cross-section"
    echo "  Process: p p > go go, decay via MadSpin: go > t t~ grv a"
    echo "  Strategy: output ONCE, then launch N times with different nevents"
    echo "-----------------------------------------------------------"
} >> "$RESULTS_FILE"

# 2a: output один раз
MADSPIN_OUTPUT_DIR="$BENCHMARK_DIR/tmp_t2_madspin"
cat > "$BENCHMARK_DIR/t2_output.mg5" <<EOF
import model GldGrv_UFO
generate p p > go go
output $MADSPIN_OUTPUT_DIR
EOF
run_test "t2_madspin_output" "$BENCHMARK_DIR/t2_output.mg5" "$BENCHMARK_DIR/t2_output.log" "t2_madspin_output"
T2_OUTPUT_TIME=$TEST_TIME

# 2b: launch с разным числом событий (каждый раз из готового output)
for NEV in 10 100 10000; do
    LABEL="t2_madspin_${NEV}ev"

    # MG5 позволяет launch из уже существующей директории
    cat > "$BENCHMARK_DIR/${LABEL}.mg5" <<EOF
launch $MADSPIN_OUTPUT_DIR
madspin=ON
set nevents $NEV
0
decay go > t t~ grv a
done
EOF
    run_test "$LABEL" "$BENCHMARK_DIR/${LABEL}.mg5" "$BENCHMARK_DIR/${LABEL}.log" "${LABEL}" 7200
    echo "${LABEL},madspin,${NEV},${TEST_TIME},${TEST_XSEC},${TEST_STATUS}" >> "$CSV_XSEC"
done

rm -rf "$MADSPIN_OUTPUT_DIR"
echo "" >> "$RESULTS_FILE"

# ============================================================================
# TEST 3: Launch Cascade при разном числе событий (10, 100, 10000)
#         output один раз, затем только launch с разным nevents
# ============================================================================
log "========== TEST 3: Cascade launch scaling (nevents) =========="
{
    echo "TEST 3: Cascade Launch — nevents scaling + cross-section"
    echo "  Process: p p > go go, go > t t~ grv a (full ME)"
    echo "  Strategy: output ONCE, then launch N times with different nevents"
    echo "-----------------------------------------------------------"
} >> "$RESULTS_FILE"

# 3a: output один раз (каскадный — это тяжёлая часть)
CASCADE_OUTPUT_DIR="$BENCHMARK_DIR/tmp_t3_cascade"
cat > "$BENCHMARK_DIR/t3_output.mg5" <<EOF
import model GldGrv_UFO
generate p p > go go, go > t t~ grv a
output $CASCADE_OUTPUT_DIR
EOF
run_test "t3_cascade_output" "$BENCHMARK_DIR/t3_output.mg5" "$BENCHMARK_DIR/t3_output.log" "t3_cascade_output" 3600
T3_OUTPUT_TIME=$TEST_TIME

# 3b: launch с разным числом событий (каждый раз из готового output)
for NEV in 10 100 10000; do
    LABEL="t3_cascade_${NEV}ev"

    cat > "$BENCHMARK_DIR/${LABEL}.mg5" <<EOF
launch $CASCADE_OUTPUT_DIR
set nevents $NEV
0
EOF
    run_test "$LABEL" "$BENCHMARK_DIR/${LABEL}.mg5" "$BENCHMARK_DIR/${LABEL}.log" "${LABEL}" 7200
    echo "${LABEL},cascade,${NEV},${TEST_TIME},${TEST_XSEC},${TEST_STATUS}" >> "$CSV_XSEC"
done

rm -rf "$CASCADE_OUTPUT_DIR"
echo "" >> "$RESULTS_FILE"

# Сравнение output-фазы
{
    echo "  >> Output phase comparison:"
    echo "     MadSpin output (p p > go go):             ${T2_OUTPUT_TIME}s ($(format_time $T2_OUTPUT_TIME))"
    echo "     Cascade output (p p > go go, go > ...):   ${T3_OUTPUT_TIME}s ($(format_time $T3_OUTPUT_TIME))"
    if [ "$T2_OUTPUT_TIME" -gt 0 ]; then
        RATIO=$(awk "BEGIN{printf \"%.1f\", $T3_OUTPUT_TIME/$T2_OUTPUT_TIME}")
        echo "     Cascade output is ${RATIO}x slower"
    fi
    echo ""
} | tee -a "$RESULTS_FILE"

# ============================================================================
# TEST 4: Процессы с go в конечном состоянии
# ============================================================================
log "========== TEST 4: Processes with go in final state =========="
{
    echo "TEST 4: Diagram generation — processes with gluino in final state"
    echo "  Теоретически возможные процессы в GldGrv_UFO (QCD production):"
    echo "-----------------------------------------------------------"
} >> "$RESULTS_FILE"

# Процессы с глюино, которые гарантированно имеют диаграммы:
#   p p > go go         — парное рождение (QCD, s/t/u + contact)
#   p p > go go g       — парное + ISR/FSR глюон
#   p p > go go j       — парное + лёгкий jet (g/q)
#   p p > go go a       — парное + фотон (QCD×QED)
declare -a GO_TESTS=(
    "go_go|p p > go go|парное рождение глюино (2->2)"
    "go_go_g|p p > go go g|глюино пара + глюон (2->3)"
    "go_go_j|p p > go go j|глюино пара + jet (2->3)"
    "go_go_a|p p > go go a|глюино пара + фотон (2->3, QCD x QED)"
)

for ENTRY in "${GO_TESTS[@]}"; do
    IFS='|' read -r LABEL PROCESS DESC <<< "$ENTRY"
    cat > "$BENCHMARK_DIR/t4_${LABEL}.mg5" <<EOF
import model GldGrv_UFO
generate $PROCESS
output $BENCHMARK_DIR/tmp_t4_${LABEL}
EOF
    run_test "t4_${LABEL}" "$BENCHMARK_DIR/t4_${LABEL}.mg5" "$BENCHMARK_DIR/t4_${LABEL}.log" "t4_${LABEL}" 1800
    rm -rf "$BENCHMARK_DIR/tmp_t4_${LABEL}"
done

echo "" >> "$RESULTS_FILE"

# ============================================================================
# Останавливаем монитор и строим отчёт по ресурсам
# ============================================================================
set_stage "analysis"
stop_resource_monitor

BENCH_END=$(date +%s)
BENCH_TOTAL=$((BENCH_END - BENCH_START))

# ============================================================================
# Ресурсный профиль по этапам
# ============================================================================
{
    echo "==============================================================================="
    echo "  RESOURCE PROFILE BY STAGE"
    echo "==============================================================================="
    echo ""
    printf "  %-30s | %7s | %7s | %10s | %10s | %5s\n" \
           "Stage" "avgCPU%" "peakCPU%" "avgRAM" "peakRAM" "N"
    printf "  %-30s-|-%7s-|-%7s-|-%10s-|-%10s-|-%5s\n" \
           "------------------------------" "-------" "-------" "----------" "----------" "-----"

    # Извлекаем уникальные этапы из resource_trace.csv
    tail -n +2 "$RESOURCE_LOG" | awk -F',' '{print $2}' | sort -u | while read -r STAGE; do
        RES=$(stage_resource_summary "$STAGE")
        read -r AC PC AR PR N <<< "$RES"
        AR_FMT=$(format_kb "$AR")
        PR_FMT=$(format_kb "$PR")
        printf "  %-30s | %6s%% | %6s%% | %10s | %10s | %5s\n" \
               "$STAGE" "$AC" "$PC" "$AR_FMT" "$PR_FMT" "$N"
    done
    echo ""
} | tee -a "$RESULTS_FILE"

# ============================================================================
# Таблица сечений при разном числе событий
# ============================================================================
{
    echo "==============================================================================="
    echo "  CROSS-SECTION vs NEVENTS"
    echo "==============================================================================="
    echo ""
    printf "  %-10s | %-10s | %10s | %15s | %s\n" \
           "Approach" "Nevents" "Time" "Cross-section" "Status"
    printf "  %-10s-|%10s--|-%10s-|-%15s-|-%s\n" \
           "----------" "----------" "----------" "---------------" "--------"

    tail -n +2 "$CSV_XSEC" | while IFS=',' read -r LBL APPROACH NEV TIME XSEC STATUS; do
        TIME_FMT=$(format_time "$TIME")
        if [ "$XSEC" = "N/A" ]; then
            XSEC_FMT="N/A"
        else
            XSEC_FMT="${XSEC} pb"
        fi
        printf "  %-10s | %10s | %10s | %15s | %s\n" \
               "$APPROACH" "$NEV" "$TIME_FMT" "$XSEC_FMT" "$STATUS"
    done
    echo ""
    echo "  Примечание: сечение (cross-section) не должно существенно"
    echo "  зависеть от числа событий — оно определяется интеграцией."
    echo "  Небольшие вариации отражают статистическую погрешность MC."
    echo "  Большие расхождения MadSpin vs Cascade указывают на эффекты"
    echo "  конечной ширины или off-shell contributions."
    echo ""
} | tee -a "$RESULTS_FILE"

# ============================================================================
# Итоговое ранжирование всех тестов по времени
# ============================================================================
{
    echo "==============================================================================="
    echo "  RANKING: All tests by time (descending)"
    echo "==============================================================================="
    echo ""
    printf "  %3s | %10s | %7s | %10s | %-40s | %s\n" \
           "#" "Time" "peakCPU" "peakRAM" "Label" "Status"
    printf "  %3s-|-%10s-|-%7s-|-%10s-|%-40s-|-%s\n" \
           "---" "----------" "-------" "----------" "----------------------------------------" "--------"

    tail -n +2 "$CSV_TIMING" | sort -t',' -k3 -n -r | awk -F',' '{
        rank++
        t=$3; pc=$5; pr=$7; lab=$1; st=$8
        if(t>=3600)      tf=sprintf("%dh%dm%ds",t/3600,(t%3600)/60,t%60)
        else if(t>=60)   tf=sprintf("%dm%ds",t/60,t%60)
        else             tf=sprintf("%ds",t)
        if(pr>=1048576)  rf=sprintf("%.1fGB",pr/1048576)
        else if(pr>=1024)rf=sprintf("%.0fMB",pr/1024)
        else             rf=sprintf("%dKB",pr)
        printf "  %3d | %10s | %6.1f%% | %10s | %-40s | %s\n", rank, tf, pc, rf, lab, st
    }'
    echo ""
} | tee -a "$RESULTS_FILE"

# ============================================================================
# Выводы
# ============================================================================
{
    echo "==============================================================================="
    echo "  CONCLUSIONS / ВЫВОДЫ"
    echo "==============================================================================="
    echo ""
    echo "  Total benchmark time: $(format_time $BENCH_TOTAL)"
    echo ""
    echo "  Output files:"
    echo "    Report:          $RESULTS_FILE"
    echo "    Timing CSV:      $CSV_TIMING"
    echo "    Cross-sect CSV:  $CSV_XSEC"
    echo "    Resource trace:  $RESOURCE_LOG  (timestamp, stage, cpu%, rss_kb)"
    echo "    MG5 logs:        $BENCHMARK_DIR/t*.log"
    echo ""
    echo "==============================================================================="
} | tee -a "$RESULTS_FILE"

log "Benchmark complete. Results: $RESULTS_FILE"
