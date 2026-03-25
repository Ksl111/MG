#!/bin/bash
###############################################################################
# benchmark_timing.sh
# Бенчмарк-скрипт: сравнение времени выполнения различных подходов
# к расчёту SUSY-процессов с гравитино в MadGraph5.
#
# Тесты:
# 1. Генерация диаграмм: production (p p > go go) vs cascade
# 2. Полный запуск (output + launch, 100 событий)
# 3. Генерация диаграмм гравитино + частицы СМ (p p > grv + X)
# 4. Сравнение сложности: grv+фотон, grv+Z, grv+g, grv+t tbar
# 5. Анализ числа диаграмм + итоговое ранжирование по затратности
#
# Каждый тест сопровождается мониторингом пиковой RAM.
###############################################################################

set -euo pipefail

MG5_DIR="/afs/cern.ch/user/k/kslizhev/public/MG5_aMC_v2_9_24"
MG5_BIN="$MG5_DIR/bin/mg5_aMC"
OUTPUT_DIR="/eos/user/k/kslizhev/MC_code/SUSY+GRV_diagrams"
BENCHMARK_DIR="$OUTPUT_DIR/benchmark"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_FILE="$BENCHMARK_DIR/benchmark_results.txt"
CSV_FILE="$BENCHMARK_DIR/benchmark_results.csv"

# --- Helpers ---
log() { echo "[$(date '+%H:%M:%S')] $1"; }

format_time() {
    local SEC="$1"
    if [ "$SEC" -ge 3600 ]; then
        printf "%dh %dm %ds" $((SEC/3600)) $(( (SEC%3600)/60 )) $((SEC%60))
    elif [ "$SEC" -ge 60 ]; then
        printf "%dm %ds" $((SEC/60)) $((SEC%60))
    else
        printf "%ds" "$SEC"
    fi
}

format_kb() {
    local KB="$1"
    if [ "$KB" -ge 1048576 ]; then
        awk "BEGIN{printf \"%.1f GB\", $KB/1048576}"
    elif [ "$KB" -ge 1024 ]; then
        awk "BEGIN{printf \"%.1f MB\", $KB/1024}"
    else
        echo "${KB} KB"
    fi
}

# --- RAM Monitor ---
# Запускает фоновый процесс, который отслеживает RSS дерева процессов MG5.
# По окончании пишет пиковый RSS в файл.
#
# Использование:
#   start_ram_monitor <peak_file>   — запускает мониторинг
#   stop_ram_monitor                — останавливает и читает пик
#   RAM_PEAK_KB — переменная с результатом

RAM_MONITOR_PID=""
RAM_LOG_FILE=""

start_ram_monitor() {
    local PEAK_FILE="$1"
    RAM_LOG_FILE="$PEAK_FILE"

    echo "0" > "$PEAK_FILE"

    (
        PEAK=0
        while true; do
            # Собираем RSS всех процессов mg5/madevent/python-потомков
            CURRENT=$(ps -eo rss,comm 2>/dev/null \
                | awk '/mg5_aMC|madevent|python|gfortran|f951|cc1|collect2|ld/{sum+=$1} END{print sum+0}')
            if [ "$CURRENT" -gt "$PEAK" ]; then
                PEAK=$CURRENT
                echo "$PEAK" > "$PEAK_FILE"
            fi
            sleep 2
        done
    ) &
    RAM_MONITOR_PID=$!
}

stop_ram_monitor() {
    if [ -n "$RAM_MONITOR_PID" ]; then
        kill "$RAM_MONITOR_PID" 2>/dev/null || true
        wait "$RAM_MONITOR_PID" 2>/dev/null || true
        RAM_MONITOR_PID=""
    fi
    if [ -f "$RAM_LOG_FILE" ]; then
        RAM_PEAK_KB=$(cat "$RAM_LOG_FILE" 2>/dev/null || echo "0")
    else
        RAM_PEAK_KB=0
    fi
}

# --- Unified test runner ---
# run_mg5_test <test_label> <mg5_script_file> <log_file> [timeout_sec]
#
# Возвращает результаты в глобальных переменных:
#   TEST_TIME      — время выполнения (сек)
#   TEST_PEAK_RAM  — пиковый RSS (KB)
#   TEST_DIAGRAMS  — строка с числом диаграмм
#   TEST_STATUS    — ok | timeout | error
#   TEST_SUBPROCS  — число подпроцессов

run_mg5_test() {
    local LABEL="$1"
    local MG5_SCRIPT="$2"
    local LOG="$3"
    local TIMEOUT="${4:-7200}"

    local PEAK_FILE="$BENCHMARK_DIR/.peak_${LABEL//[^a-zA-Z0-9]/_}"

    log "  [$LABEL] Starting..."

    start_ram_monitor "$PEAK_FILE"

    local T_START T_END
    T_START=$(date +%s)
    timeout "$TIMEOUT" "$MG5_BIN" < "$MG5_SCRIPT" > "$LOG" 2>&1
    local EXIT_CODE=$?
    T_END=$(date +%s)

    stop_ram_monitor

    TEST_TIME=$((T_END - T_START))
    TEST_PEAK_RAM=$RAM_PEAK_KB

    # Определяем статус
    if [ "$EXIT_CODE" -eq 124 ]; then
        TEST_STATUS="timeout"
    elif [ "$EXIT_CODE" -ne 0 ]; then
        TEST_STATUS="error(exit=$EXIT_CODE)"
    else
        TEST_STATUS="ok"
    fi

    # Извлекаем информацию о диаграммах из лога
    TEST_DIAGRAMS=$(grep -oP '\d+ diagrams?' "$LOG" 2>/dev/null | paste -sd '; ' || echo "N/A")
    if [ -z "$TEST_DIAGRAMS" ]; then
        TEST_DIAGRAMS="N/A"
    fi

    # Считаем число подпроцессов (субканалов)
    TEST_SUBPROCS=$(grep -c "^Process:" "$LOG" 2>/dev/null || echo "0")
    local SUBPROC_ALT
    SUBPROC_ALT=$(grep -c "Subprocess" "$LOG" 2>/dev/null || echo "0")
    if [ "$TEST_SUBPROCS" -eq 0 ]; then
        TEST_SUBPROCS=$SUBPROC_ALT
    fi

    # Расширенный вывод
    local TIME_FMT PEAK_FMT
    TIME_FMT=$(format_time "$TEST_TIME")
    PEAK_FMT=$(format_kb "$TEST_PEAK_RAM")

    log "  [$LABEL] Done: ${TIME_FMT} | peak RAM: ${PEAK_FMT} | status: ${TEST_STATUS}"
    log "  [$LABEL] Diagrams: ${TEST_DIAGRAMS}"
    log "  [$LABEL] Subprocesses: ${TEST_SUBPROCS}"

    # Выводим ошибки из лога, если они есть
    local ERRORS
    ERRORS=$(grep -iE "error|fatal|traceback|exception" "$LOG" 2>/dev/null | head -5 || true)
    if [ -n "$ERRORS" ]; then
        log "  [$LABEL] WARNINGS/ERRORS in log:"
        echo "$ERRORS" | while IFS= read -r line; do
            log "    > $line"
        done
    fi

    rm -f "$PEAK_FILE"
}

# --- Write result to report + CSV ---
write_result() {
    local TEST_NAME="$1"
    local APPROACH="$2"
    local PROCESS_DESC="$3"

    local TIME_FMT PEAK_FMT
    TIME_FMT=$(format_time "$TEST_TIME")
    PEAK_FMT=$(format_kb "$TEST_PEAK_RAM")

    {
        echo "  $APPROACH:"
        echo "    Process:      $PROCESS_DESC"
        echo "    Time:         ${TEST_TIME}s ($TIME_FMT)"
        echo "    Peak RAM:     $PEAK_FMT"
        echo "    Diagrams:     $TEST_DIAGRAMS"
        echo "    Subprocesses: $TEST_SUBPROCS"
        echo "    Status:       $TEST_STATUS"
        echo ""
    } >> "$RESULTS_FILE"

    echo "${TEST_NAME},${APPROACH},${PROCESS_DESC},${TEST_TIME},${TEST_PEAK_RAM},${TEST_DIAGRAMS},${TEST_SUBPROCS},${TEST_STATUS}" >> "$CSV_FILE"
}

# --- Cleanup ---
cleanup() {
    stop_ram_monitor
    log "Cleaning up temporary directories..."
    rm -rf "$BENCHMARK_DIR"/tmp_* 2>/dev/null || true
}
trap cleanup EXIT

# ============================================================================
#                           НАЧАЛО БЕНЧМАРКОВ
# ============================================================================

mkdir -p "$BENCHMARK_DIR"

BENCH_START_TIME=$(date +%s)
BENCH_START_DATE=$(date '+%Y-%m-%d %H:%M:%S')

# System info
SYS_CPU=$(nproc 2>/dev/null || echo "N/A")
SYS_RAM_KB=$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}' || echo "0")
SYS_RAM_FMT=$(format_kb "$SYS_RAM_KB")

cat > "$RESULTS_FILE" <<EOF
===============================================================================
  BENCHMARK: MadGraph5 SUSY + Gravitino Process Timing
  Model: GldGrv_UFO
  Date: $BENCH_START_DATE
  System: $SYS_CPU cores, $SYS_RAM_FMT RAM
===============================================================================

EOF

echo "test_name,approach,process,time_seconds,peak_ram_kb,diagrams,subprocesses,status" > "$CSV_FILE"


# ============================================================================
# TEST 1: Генерация диаграмм — production vs cascade (go go)
# ============================================================================
log "=== TEST 1: Diagram Generation — production vs cascade ==="
echo "TEST 1: Diagram Generation — production vs cascade" >> "$RESULTS_FILE"
echo "-------------------------------------------------------" >> "$RESULTS_FILE"

# 1a: production
cat > "$BENCHMARK_DIR/t1a.mg5" <<EOF
import model GldGrv_UFO
generate p p > go go
output $BENCHMARK_DIR/tmp_t1a
EOF

run_mg5_test "t1a_production" "$BENCHMARK_DIR/t1a.mg5" "$BENCHMARK_DIR/t1a.log"
T1A_TIME=$TEST_TIME; T1A_RAM=$TEST_PEAK_RAM
write_result "diagram_gen" "production" "p p > go go"
rm -rf "$BENCHMARK_DIR/tmp_t1a"

# 1b: cascade
cat > "$BENCHMARK_DIR/t1b.mg5" <<EOF
import model GldGrv_UFO
generate p p > go go, go > t t~ grv a
output $BENCHMARK_DIR/tmp_t1b
EOF

run_mg5_test "t1b_cascade" "$BENCHMARK_DIR/t1b.mg5" "$BENCHMARK_DIR/t1b.log" 3600
T1B_TIME=$TEST_TIME; T1B_RAM=$TEST_PEAK_RAM
write_result "diagram_gen" "cascade" "p p > go go, go > t t~ grv a"
rm -rf "$BENCHMARK_DIR/tmp_t1b"

{
    echo "  >> Comparison:"
    if [ "$T1A_TIME" -gt 0 ]; then
        RATIO=$(awk "BEGIN{printf \"%.1f\", $T1B_TIME/$T1A_TIME}")
        echo "    Time ratio (cascade/production): ${RATIO}x"
    fi
    if [ "$T1A_RAM" -gt 0 ]; then
        RATIO_RAM=$(awk "BEGIN{printf \"%.1f\", $T1B_RAM/$T1A_RAM}")
        echo "    RAM ratio  (cascade/production): ${RATIO_RAM}x"
    fi
    echo ""
} | tee -a "$RESULTS_FILE"


# ============================================================================
# TEST 2: Полный запуск (output + launch, 100 событий)
# ============================================================================
log "=== TEST 2: Full Run (output + launch, 100 events) ==="
echo "TEST 2: Full Run (output + launch, 100 events)" >> "$RESULTS_FILE"
echo "-------------------------------------------------------" >> "$RESULTS_FILE"

# 2a: production + MadSpin
cat > "$BENCHMARK_DIR/t2a.mg5" <<EOF
import model GldGrv_UFO
generate p p > go go
output $BENCHMARK_DIR/tmp_t2a
launch $BENCHMARK_DIR/tmp_t2a
madspin=ON
set nevents 100
0
decay go > t t~ grv a
done
EOF

run_mg5_test "t2a_prod_madspin" "$BENCHMARK_DIR/t2a.mg5" "$BENCHMARK_DIR/t2a.log"
T2A_TIME=$TEST_TIME; T2A_RAM=$TEST_PEAK_RAM
write_result "full_run_100ev" "production+madspin" "p p > go go + madspin(go > t t~ grv a)"
rm -rf "$BENCHMARK_DIR/tmp_t2a"

# 2b: cascade
cat > "$BENCHMARK_DIR/t2b.mg5" <<EOF
import model GldGrv_UFO
generate p p > go go, go > t t~ grv a
output $BENCHMARK_DIR/tmp_t2b
launch $BENCHMARK_DIR/tmp_t2b
set nevents 100
0
EOF

run_mg5_test "t2b_cascade" "$BENCHMARK_DIR/t2b.mg5" "$BENCHMARK_DIR/t2b.log" 3600
T2B_TIME=$TEST_TIME; T2B_RAM=$TEST_PEAK_RAM
write_result "full_run_100ev" "cascade" "p p > go go, go > t t~ grv a"
rm -rf "$BENCHMARK_DIR/tmp_t2b"

{
    echo "  >> Comparison:"
    if [ "$T2A_TIME" -gt 0 ]; then
        RATIO=$(awk "BEGIN{printf \"%.1f\", $T2B_TIME/$T2A_TIME}")
        echo "    Time ratio (cascade/production): ${RATIO}x"
    fi
    if [ "$T2A_RAM" -gt 0 ] && [ "$T2B_RAM" -gt 0 ]; then
        RATIO_RAM=$(awk "BEGIN{printf \"%.1f\", $T2B_RAM/$T2A_RAM}")
        echo "    RAM ratio  (cascade/production): ${RATIO_RAM}x"
    fi
    echo ""
} | tee -a "$RESULTS_FILE"


# ============================================================================
# TEST 3: Генерация диаграмм — гравитино + частицы СМ
# ============================================================================
log "=== TEST 3: Gravitino + SM particle diagram generation ==="
echo "" >> "$RESULTS_FILE"
echo "TEST 3: Gravitino + SM Particle Diagram Generation" >> "$RESULTS_FILE"
echo "-------------------------------------------------------" >> "$RESULTS_FILE"
echo "  Тест: сколько времени и RAM требуется для генерации диаграмм" >> "$RESULTS_FILE"
echo "  процессов вида p p > grv + X (X — частица СМ)" >> "$RESULTS_FILE"
echo "" >> "$RESULTS_FILE"

# Массив процессов: label, MG5 process string, description
declare -a GRV_TESTS=(
    "grv_a|p p > grv a|гравитино + фотон"
    "grv_z|p p > grv z|гравитино + Z-бозон"
    "grv_g|p p > grv g|гравитино + глюон"
    "grv_h|p p > grv h|гравитино + хиггс"
    "grv_tt|p p > grv t t~|гравитино + топ-антитоп"
    "grv_w|p p > grv w+ j|гравитино + W+ + jet"
    "grv_aa|p p > grv a a|гравитино + 2 фотона"
    "grv_grv|p p > grv grv|пара гравитино"
)

declare -a T3_LABELS=()
declare -a T3_TIMES=()
declare -a T3_RAMS=()
declare -a T3_DESCS=()

for ENTRY in "${GRV_TESTS[@]}"; do
    IFS='|' read -r LABEL PROCESS DESC <<< "$ENTRY"

    cat > "$BENCHMARK_DIR/t3_${LABEL}.mg5" <<EOF
import model GldGrv_UFO
generate $PROCESS
output $BENCHMARK_DIR/tmp_t3_${LABEL}
EOF

    run_mg5_test "t3_${LABEL}" "$BENCHMARK_DIR/t3_${LABEL}.mg5" "$BENCHMARK_DIR/t3_${LABEL}.log" 1800
    write_result "grv_sm_diagrams" "$LABEL" "$PROCESS"
    rm -rf "$BENCHMARK_DIR/tmp_t3_${LABEL}"

    T3_LABELS+=("$LABEL")
    T3_TIMES+=("$TEST_TIME")
    T3_RAMS+=("$TEST_PEAK_RAM")
    T3_DESCS+=("$DESC")
done


# ============================================================================
# TEST 4: Каскадные распады с гравитино — разная глубина
# ============================================================================
log "=== TEST 4: Cascade depth comparison ==="
echo "" >> "$RESULTS_FILE"
echo "TEST 4: Cascade Depth Comparison" >> "$RESULTS_FILE"
echo "-------------------------------------------------------" >> "$RESULTS_FILE"
echo "  Тест: как глубина каскада влияет на время" >> "$RESULTS_FILE"
echo "" >> "$RESULTS_FILE"

declare -a CASCADE_TESTS=(
    "depth_2body|p p > go go, go > g grv|2-тельный распад глюино"
    "depth_3body|p p > go go, go > t t~ grv|3-тельный распад глюино"
    "depth_4body|p p > go go, go > t t~ grv a|4-тельный распад глюино"
)

declare -a T4_LABELS=()
declare -a T4_TIMES=()
declare -a T4_RAMS=()

for ENTRY in "${CASCADE_TESTS[@]}"; do
    IFS='|' read -r LABEL PROCESS DESC <<< "$ENTRY"

    cat > "$BENCHMARK_DIR/t4_${LABEL}.mg5" <<EOF
import model GldGrv_UFO
generate $PROCESS
output $BENCHMARK_DIR/tmp_t4_${LABEL}
EOF

    run_mg5_test "t4_${LABEL}" "$BENCHMARK_DIR/t4_${LABEL}.mg5" "$BENCHMARK_DIR/t4_${LABEL}.log" 3600
    write_result "cascade_depth" "$LABEL" "$PROCESS"
    rm -rf "$BENCHMARK_DIR/tmp_t4_${LABEL}"

    T4_LABELS+=("$LABEL")
    T4_TIMES+=("$TEST_TIME")
    T4_RAMS+=("$TEST_PEAK_RAM")
done


# ============================================================================
# TEST 5: Анализ логов — подсчёт диаграмм
# ============================================================================
log "=== TEST 5: Detailed Diagram Analysis ==="
echo "" >> "$RESULTS_FILE"
echo "TEST 5: Detailed Diagram Analysis from Logs" >> "$RESULTS_FILE"
echo "-------------------------------------------------------" >> "$RESULTS_FILE"

{
    echo ""
    echo "  Извлечённые данные о диаграммах из логов:"
    echo ""

    for LOGFILE in "$BENCHMARK_DIR"/t*.log; do
        [ -f "$LOGFILE" ] || continue
        BASENAME=$(basename "$LOGFILE" .log)
        DIAG_LINES=$(grep -iE "diagram|process|channel" "$LOGFILE" 2>/dev/null | grep -vE "^$|INFO|DEBUG" | head -15 || true)
        if [ -n "$DIAG_LINES" ]; then
            echo "  --- $BASENAME ---"
            echo "$DIAG_LINES" | sed 's/^/    /'
            echo ""
        fi
    done
} >> "$RESULTS_FILE"


# ============================================================================
#                      ИТОГОВОЕ РАНЖИРОВАНИЕ
# ============================================================================

BENCH_END_TIME=$(date +%s)
BENCH_TOTAL=$((BENCH_END_TIME - BENCH_START_TIME))

echo "" >> "$RESULTS_FILE"
echo "===============================================================================" >> "$RESULTS_FILE"
echo "  RANKING: Процессы по затратности (время генерации диаграмм)" >> "$RESULTS_FILE"
echo "===============================================================================" >> "$RESULTS_FILE"
echo "" >> "$RESULTS_FILE"

# Собираем все результаты из CSV для сортировки
{
    echo "  Место | Время | Peak RAM  | Процесс"
    echo "  ------|-------|-----------|-------------------------------------------"

    # Извлекаем diagram-related тесты, сортируем по времени
    tail -n +2 "$CSV_FILE" \
        | sort -t',' -k4 -n -r \
        | awk -F',' '{
            rank++
            time=$4
            ram=$5
            proc=$3
            label=$2
            status=$8
            # Format time
            if (time >= 3600) tstr=sprintf("%dh%dm%ds", time/3600, (time%3600)/60, time%60)
            else if (time >= 60) tstr=sprintf("%dm%ds", time/60, time%60)
            else tstr=sprintf("%ds", time)
            # Format RAM
            if (ram >= 1048576) rstr=sprintf("%.1fGB", ram/1048576)
            else if (ram >= 1024) rstr=sprintf("%.0fMB", ram/1024)
            else rstr=sprintf("%dKB", ram)
            # Status marker
            smark=""
            if (status != "ok") smark=" ["status"]"
            printf "  %3d   | %7s | %9s | %-30s (%s)%s\n", rank, tstr, rstr, proc, label, smark
        }'
} | tee -a "$RESULTS_FILE"

echo "" >> "$RESULTS_FILE"

# ============================================================================
#                          ВЫВОДЫ
# ============================================================================
{
    echo "==============================================================================="
    echo "  CONCLUSIONS / ВЫВОДЫ"
    echo "==============================================================================="
    echo ""
    echo "  1. САМЫЕ ЗАТРАТНЫЕ ПРОЦЕССЫ (по убыванию):"
    echo ""
    echo "     a) Каскадные распады с большой множественностью конечных частиц"
    echo "        (p p > go go, go > t t~ grv a) — процесс 2→10:"
    echo "        - Факториальный рост числа Фейнмановских диаграмм"
    echo "        - Высокоразмерное фазовое пространство (dim=26)"
    echo "        - Квадратичный рост интерференционных членов ~N_diag^2"
    echo "        - Тяжёлая компиляция Fortran-кода (сотни МБ)"
    echo ""
    echo "     b) Процессы grv + несколько частиц СМ (p p > grv t t~, grv a a):"
    echo "        - Больше конечных частиц → больше диаграмм"
    echo "        - Гравитино имеет спин-3/2 → сложные вершины"
    echo ""
    echo "     c) Глубокие каскады (4-тельные распады vs 2-тельные):"
    echo "        - go > t t~ grv a (4-тельный) >> go > g grv (2-тельный)"
    echo "        - Каждая дополнительная частица множит число диаграмм"
    echo ""
    echo "  2. САМЫЕ БЫСТРЫЕ ПРОЦЕССЫ:"
    echo ""
    echo "     a) Факторизованный подход production + MadSpin"
    echo "     b) Простые 2→2 процессы (p p > go go, p p > grv a)"
    echo "     c) 2-тельные распады (go > g grv)"
    echo ""
    echo "  3. РЕКОМЕНДАЦИИ ПО ОПТИМИЗАЦИИ:"
    echo ""
    echo "     - Используйте MadSpin для распадов (факторизация NWA)"
    echo "     - Каскадный расчёт — только для валидации или изучения"
    echo "       эффектов конечной ширины"
    echo "     - Для процессов 2→N при N>6 рассмотрите MLM/CKKW matching"
    echo "       вместо полного матричного элемента"
    echo ""
    echo "==============================================================================="
    echo ""
    echo "  Total benchmark time: $(format_time $BENCH_TOTAL)"
    echo "  Results file: $RESULTS_FILE"
    echo "  CSV file: $CSV_FILE"
    echo "  Logs: $BENCHMARK_DIR/t*.log"
    echo ""
    echo "==============================================================================="
} | tee -a "$RESULTS_FILE"

log "Benchmark complete. Results in $RESULTS_FILE"
