#!/bin/bash
###############################################################################
# monitor_resources.sh
# Мониторинг ресурсов, используемых MadGraph5 во время выполнения
#
# Использование:
#   ./monitor_resources.sh <PID|auto> [интервал_сек] [лог_файл]
#
# Примеры:
#   ./monitor_resources.sh auto              # Автоматический поиск MG5 процесса
#   ./monitor_resources.sh 12345 5           # Мониторинг PID 12345 каждые 5 сек
#   ./monitor_resources.sh auto 10 my.log    # Каждые 10 сек, в файл my.log
###############################################################################

set -uo pipefail

MODE="${1:-auto}"
INTERVAL="${2:-5}"
LOG_FILE="${3:-resource_monitor.log}"

# Colours
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m'

find_mg5_pids() {
    # Ищем процессы MadGraph5: python с mg5_aMC, а также порожденные Fortran-процессы
    pgrep -f "mg5_aMC|madevent|Survey|Refine|combine|gensym" 2>/dev/null || true
}

get_tree_pids() {
    local parent="$1"
    local children
    children=$(pgrep -P "$parent" 2>/dev/null || true)
    echo "$parent"
    for child in $children; do
        get_tree_pids "$child"
    done
}

format_kb() {
    local kb="$1"
    if [ "$kb" -ge 1048576 ]; then
        echo "$(awk "BEGIN{printf \"%.1f\", $kb/1048576}") GB"
    elif [ "$kb" -ge 1024 ]; then
        echo "$(awk "BEGIN{printf \"%.1f\", $kb/1024}") MB"
    else
        echo "${kb} KB"
    fi
}

# --- Header ---
echo "============================================="
echo " MadGraph5 Resource Monitor"
echo " Interval: ${INTERVAL}s | Log: ${LOG_FILE}"
echo "============================================="
echo ""

# Write CSV header to log file
echo "timestamp,elapsed_sec,pid_count,total_cpu_pct,total_rss_kb,total_vms_kb,load_avg_1m,load_avg_5m,mem_used_pct,disk_io_read_kb,disk_io_write_kb" > "$LOG_FILE"

START_TIME=$(date +%s)

monitor_iteration() {
    local NOW
    NOW=$(date +%s)
    local ELAPSED=$((NOW - START_TIME))
    local TIMESTAMP
    TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

    # Find target PIDs
    local ALL_PIDS=""
    if [ "$MODE" = "auto" ]; then
        local ROOT_PIDS
        ROOT_PIDS=$(find_mg5_pids)
        if [ -z "$ROOT_PIDS" ]; then
            echo -e "${YELLOW}[${TIMESTAMP}] No MadGraph5 process found. Waiting...${NC}"
            return 1
        fi
        for rpid in $ROOT_PIDS; do
            local tree
            tree=$(get_tree_pids "$rpid")
            ALL_PIDS="$ALL_PIDS $tree"
        done
    else
        ALL_PIDS=$(get_tree_pids "$MODE")
    fi

    # Deduplicate
    ALL_PIDS=$(echo "$ALL_PIDS" | tr ' ' '\n' | sort -u | tr '\n' ' ')
    local PID_COUNT
    PID_COUNT=$(echo "$ALL_PIDS" | wc -w)

    if [ "$PID_COUNT" -eq 0 ]; then
        echo -e "${YELLOW}[${TIMESTAMP}] Process tree empty. Has MadGraph5 finished?${NC}"
        return 1
    fi

    # Aggregate CPU% and memory
    local TOTAL_CPU=0
    local TOTAL_RSS=0
    local TOTAL_VMS=0

    for pid in $ALL_PIDS; do
        if [ -d "/proc/$pid" ]; then
            local CPU_PCT
            CPU_PCT=$(ps -p "$pid" -o %cpu= 2>/dev/null | tr -d ' ' || echo "0")
            local RSS_KB
            RSS_KB=$(ps -p "$pid" -o rss= 2>/dev/null | tr -d ' ' || echo "0")
            local VMS_KB
            VMS_KB=$(ps -p "$pid" -o vsz= 2>/dev/null | tr -d ' ' || echo "0")

            TOTAL_CPU=$(awk "BEGIN{print $TOTAL_CPU + $CPU_PCT}")
            TOTAL_RSS=$((TOTAL_RSS + RSS_KB))
            TOTAL_VMS=$((TOTAL_VMS + VMS_KB))
        fi
    done

    # System-level metrics
    local LOAD_AVG
    LOAD_AVG=$(cat /proc/loadavg 2>/dev/null | awk '{print $1, $2}')
    local LOAD_1M LOAD_5M
    LOAD_1M=$(echo "$LOAD_AVG" | awk '{print $1}')
    LOAD_5M=$(echo "$LOAD_AVG" | awk '{print $2}')

    local MEM_USED_PCT
    MEM_USED_PCT=$(free 2>/dev/null | awk '/Mem:/{printf "%.1f", ($3/$2)*100}')

    # Disk I/O (system-wide, since per-process requires root)
    local DISK_READ=0 DISK_WRITE=0
    if [ -f /proc/diskstats ]; then
        # Sum sectors read/written for all sd/nvme/vd devices
        DISK_READ=$(awk '/sd[a-z] |nvme[0-9]|vd[a-z] /{sum+=$6} END{print sum*512/1024}' /proc/diskstats 2>/dev/null || echo 0)
        DISK_WRITE=$(awk '/sd[a-z] |nvme[0-9]|vd[a-z] /{sum+=$10} END{print sum*512/1024}' /proc/diskstats 2>/dev/null || echo 0)
    fi

    # Log to CSV
    echo "${TIMESTAMP},${ELAPSED},${PID_COUNT},${TOTAL_CPU},${TOTAL_RSS},${TOTAL_VMS},${LOAD_1M},${LOAD_5M},${MEM_USED_PCT},${DISK_READ},${DISK_WRITE}" >> "$LOG_FILE"

    # Print to console
    local RSS_FMT VMS_FMT
    RSS_FMT=$(format_kb "$TOTAL_RSS")
    VMS_FMT=$(format_kb "$TOTAL_VMS")

    printf "${CYAN}[%s]${NC} elapsed=%ds | procs=%d | CPU=%.1f%% | RSS=%s | VMS=%s | load=%s,%s | mem_sys=%s%%\n" \
        "$TIMESTAMP" "$ELAPSED" "$PID_COUNT" "$TOTAL_CPU" "$RSS_FMT" "$VMS_FMT" \
        "$LOAD_1M" "$LOAD_5M" "$MEM_USED_PCT"

    return 0
}

echo "Starting monitoring (Ctrl+C to stop)..."
echo ""

# Trap to print summary on exit
trap 'echo ""; echo "Monitor stopped. Log saved to: $LOG_FILE"; echo "Use analyze_resources.py to generate plots."' EXIT

while true; do
    monitor_iteration || true
    sleep "$INTERVAL"
done
