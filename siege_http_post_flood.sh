#!/bin/bash

# =================================================================
# SIEGE HTTP GET FLOOD SIMULATOR WITH TC QDISC CONTROL
# =================================================================
# Architecture: Siege runs at max capacity, TC qdisc throttles bandwidth
# This mimics the hping3 architecture exactly

# Cấu hình mặc định
TARGET_URL="${1:-http://example.com}"
INTERFACE="${2:-eth0}"
DURATION="${3:-300}"
TIME_COMPRESSION="${4:-72}"
LOG_FILE="siege_http_flood_$(date +%Y%m%d_%H%M%S).log"
VERBOSE=true

# Cấu hình TC QDISC
BURST_SIZE="32k"
LATENCY="200ms"
MIN_RATE="1kbit"
MAX_RATE="2mbit"

# Cấu hình Siege
MAX_CONCURRENT=20
SIEGE_RC_FILE="/tmp/siege_custom_$(date +%s).rc"

# PID và flags
SIEGE_PID=""
TC_ACTIVE=false
PYTHON_AVAILABLE=false

# Hàm logging
log() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $message" | tee -a "$LOG_FILE"
}

# Hàm cleanup
cleanup() {
    log "=== CLEANUP STARTED ==="
    
    # Kill Siege
    if [ -n "$SIEGE_PID" ] && kill -0 "$SIEGE_PID" 2>/dev/null; then
        log "Killing siege process (PID: $SIEGE_PID)"
        kill -TERM "$SIEGE_PID" 2>/dev/null
        sleep 2
        if kill -0 "$SIEGE_PID" 2>/dev/null; then
            kill -KILL "$SIEGE_PID" 2>/dev/null
        fi
        wait "$SIEGE_PID" 2>/dev/null
    fi
    
    # Failsafe: kill all siege
    pkill -9 siege 2>/dev/null
    
    # Remove TC qdisc
    if [ "$TC_ACTIVE" = true ]; then
        log "Removing tc qdisc from interface $INTERFACE"
        tc qdisc del dev "$INTERFACE" root 2>/dev/null || true
        TC_ACTIVE=false
    fi
    
    # Cleanup files
    rm -f "$SIEGE_RC_FILE"
    rm -f /tmp/traffic_calculator.py
    
    log "=== CLEANUP COMPLETED ==="
    exit 0
}

trap cleanup EXIT INT TERM

# Kiểm tra Python
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

# Python calculator
create_python_calculator() {
    cat << 'PYTHON_SCRIPT' > /tmp/traffic_calculator.py
#!/usr/bin/env python3
import math
import sys
import os

SCALE_FACTOR = int(os.environ.get('TRAFFIC_SCALE_FACTOR', '10'))

def calculate_hourly_rate(hour, scale_factor=SCALE_FACTOR):
    morning_peak = 25 * math.exp(-((hour - 9) ** 2) / 6.25)
    evening_peak = 45 * math.exp(-((hour - 20) ** 2) / 7.84)
    night_drop = -15 * math.exp(-((hour - 2.5) ** 2) / 3.24)
    daily_cycle = 5 * math.sin(math.pi * hour / 12 - math.pi/2)
    base_level = 20
    
    traffic_factor = base_level + morning_peak + evening_peak + night_drop + daily_cycle
    rps = max(30, traffic_factor * scale_factor)
    
    return int(rps)

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

def calculate_traffic_rate(elapsed_seconds, compression_factor, noise_factor=0.15):
    try:
        hour, day, minute = get_compressed_time(elapsed_seconds, compression_factor)
        hourly_rate = calculate_hourly_rate(hour)
        weekly_multiplier = calculate_weekly_multiplier(day)
        minute_factor = calculate_minute_factor(minute)
        base_rate = hourly_rate * weekly_multiplier * minute_factor
        
        import random
        noise = random.uniform(-noise_factor, noise_factor)
        final_rate = base_rate * (1 + noise)
        
        return max(1, int(final_rate)), hour, day, minute
    except Exception as e:
        print(f"ERROR: {e}", file=sys.stderr)
        sys.exit(1)

def calculate_yoyo_rate(elapsed_seconds, cycle_duration=20, yoyo_type="square"):
    cycle_position = (elapsed_seconds % cycle_duration) / cycle_duration
    
    if yoyo_type == "square":
        return 5000 if cycle_position < 0.5 else 500
    elif yoyo_type == "sawtooth":
        if cycle_position < 0.8:
            return int(1000 + 9000 * cycle_position / 0.8)
        else:
            return 1000
    elif yoyo_type == "burst":
        if cycle_position < 0.1:
            return 10000
        elif cycle_position < 0.2:
            return 5000
        else:
            return 2000
    else:
        return 5000

if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("Usage: python3 traffic_calculator.py <mode> <elapsed_seconds> [compression_factor] [yoyo_type]", file=sys.stderr)
        sys.exit(1)
    
    try:
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
            print(f"ERROR: Unknown mode: {mode}", file=sys.stderr)
            sys.exit(1)
    except Exception as e:
        print(f"ERROR: {e}", file=sys.stderr)
        sys.exit(1)
PYTHON_SCRIPT
    
    chmod +x /tmp/traffic_calculator.py
}

# Fallback math
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

# RPS to bandwidth 
rps_to_bandwidth() {
    local rps=$1
    # HTTP request trung bình 200 - 2000B trich tu  RFC 7230 (HTTP/1.1)
    local avg_request_bytes=500      # Request headers + body
    local avg_response_bytes=0    # Response (2KB)
    local bytes_per_transaction=$((avg_request_bytes + avg_response_bytes))
    local bps=$(echo "scale=0; $rps * $bytes_per_transaction * 8" | bc -l)	#convert bytes sang bits
    
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

# TC qdisc init 
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

# TC qdisc update 
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

# Create Siege RC
create_siege_rc() {
    cat > "$SIEGE_RC_FILE" << EOF
verbose = false
color = off
quiet = true
show-logfile = false
logging = false
protocol = HTTP/1.1
chunked = true
cache = false
connection = close
concurrent = $MAX_CONCURRENT
delay = 0.5
timeout = 30
failures = 1024
benchmark = true
user-agent = Mozilla/5.0 (compatible; SiegeLoadTester/1.0)
accept-encoding = gzip, deflate
EOF

    log "Custom Siege RC created: $SIEGE_RC_FILE"
}

# Start Siege - CHẠY Ở MAX CAPACITY 
start_siege_flood() {
    log "Starting Siege HTTP flood to $TARGET_URL"
    log "Max concurrent users: $MAX_CONCURRENT"
    log "Mode: Benchmark (no delays, maximum speed)"
    
    siege \
        -R "$SIEGE_RC_FILE" \
        -c "$MAX_CONCURRENT" \
        -t "${DURATION}s" \
        "$TARGET_URL POST name=test&email=test@example.com" \
        >> "$LOG_FILE" 2>&1 &
    
    SIEGE_PID=$!
    
    if [ -n "$SIEGE_PID" ] && kill -0 "$SIEGE_PID" 2>/dev/null; then
        log "Siege started successfully (PID: $SIEGE_PID)"
        log "Siege is running at MAXIMUM CAPACITY"
        log "TC qdisc will control actual traffic rate"
        return 0
    else
        log "ERROR: Failed to start Siege"
        return 1
    fi
}

generate_compressed_pattern_python() {
    local duration_seconds=$1
    
    log "=== SIEGE + TC QDISC SIMULATION (IDENTICAL TO HPING3 ARCHITECTURE) ==="
    log "Math Engine: Python3 with accurate mathematical functions"
    log "Compression factor: ${TIME_COMPRESSION}x"
    log "Real duration: ${duration_seconds}s = Virtual: $(python3 -c "print(f'{$duration_seconds * $TIME_COMPRESSION / 3600:.1f}')" 2>/dev/null || echo "N/A")h"
    log "Target URL: $TARGET_URL"
    log ""
    log "Architecture:"
    log "  1. Siege runs at MAX capacity (${MAX_CONCURRENT} concurrent)"
    log "  2. TC qdisc throttles bandwidth according to pattern"
    log "  3. Result: Traffic follows mathematical curves"
    
    # Init TC qdisc
    if ! init_tc_qdisc; then
        log "ERROR: Cannot initialize TC qdisc"
        return 1
    fi
    
    # Start Siege at max
    if ! start_siege_flood; then
        log "ERROR: Cannot start Siege flood"
        return 1
    fi
    
    local update_interval=1
    local current_time=0
    local last_rate=""
    
    while [ $current_time -lt $duration_seconds ]; do
        local python_output
        if python_output=$(python3 /tmp/traffic_calculator.py compressed $current_time $TIME_COMPRESSION 2>/dev/null); then
            local final_rps=$(echo "$python_output" | awk '{print $1}')
            local virtual_hour=$(echo "$python_output" | awk '{print $2}')
            local virtual_day=$(echo "$python_output" | awk '{print $3}')
            local virtual_minute=$(echo "$python_output" | awk '{print $4}')
            
            local bandwidth=$(rps_to_bandwidth "$final_rps")
            
            if [ "$bandwidth" != "$last_rate" ]; then
                if update_tc_rate "$bandwidth"; then
                    log "T+${current_time}s | Virtual: Day${virtual_day} ${virtual_hour}:$(printf "%02d" $virtual_minute) | RPS: ${final_rps} | BW: ${bandwidth} [PYTHON]"
                    last_rate="$bandwidth"
                else
                    log "T+${current_time}s | ERROR: Failed to update TC rate to $bandwidth"
                fi
            elif [ "$VERBOSE" = true ]; then
                log "T+${current_time}s | Virtual: Day${virtual_day} ${virtual_hour}:$(printf "%02d" $virtual_minute) | RPS: ${final_rps} | BW: ${bandwidth} [unchanged]"
            fi
        else
            log "T+${current_time}s | ERROR: Python calculation failed, using fallback"
            local hour=$(echo "scale=0; ($current_time * $TIME_COMPRESSION / 3600) % 24" | bc -l)
            local day=$(echo "scale=0; ($current_time * $TIME_COMPRESSION / 86400) % 7 + 1" | bc -l)
            local minute=$(echo "scale=0; ($current_time * $TIME_COMPRESSION % 3600) / 60" | bc -l)
            
            local simple_rate=$(calculate_simple_rate $hour $day $minute)
            local bandwidth=$(rps_to_bandwidth "$simple_rate")
            
            update_tc_rate "$bandwidth"
            log "T+${current_time}s | Virtual: Day${day} ${hour}:$(printf "%02d" $minute) | RPS: ${simple_rate} | BW: ${bandwidth} [FALLBACK]"
        fi
        
        sleep $update_interval
        current_time=$((current_time + update_interval))
    done
}

# Yo-yo pattern
generate_yoyo_pattern_python() {
    local duration_seconds=$1
    local yoyo_type="${2:-square}"
    
    log "=== SIEGE + TC QDISC YO-YO PATTERN ==="
    log "Type: $yoyo_type | Duration: ${duration_seconds}s"
    log "Target URL: $TARGET_URL"
    
    if ! init_tc_qdisc; then
        log "ERROR: Cannot initialize TC qdisc"
        return 1
    fi
    
    if ! start_siege_flood; then
        log "ERROR: Cannot start Siege flood"
        return 1
    fi
    
    local update_interval=5
    local current_time=0
    
    while [ $current_time -lt $duration_seconds ]; do
        local python_output
        if python_output=$(python3 /tmp/traffic_calculator.py yoyo $current_time $yoyo_type 2>/dev/null); then
            local rps=$(echo "$python_output" | awk '{print $1}')
            local cycle_pos=$(echo "$python_output" | awk '{print $2}')
            
            local bandwidth=$(rps_to_bandwidth "$rps")
            
            if update_tc_rate "$bandwidth"; then
                log "T+${current_time}s | Cycle: ${cycle_pos} | RPS: ${rps} | BW: ${bandwidth} [$yoyo_type-PYTHON]"
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

# Dependencies check
check_dependencies() {
    local missing_deps=()
    
    if ! command -v siege &> /dev/null; then
        missing_deps+=("siege")
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

# Validate URL
validate_url() {
    local url=$1
    if [[ ! "$url" =~ ^https?:// ]]; then
        log "ERROR: Invalid URL. Must start with http:// or https://"
        exit 1
    fi
}

show_usage() {
    cat << EOF
╔══════════════════════════════════════════════════════════════════════════════╗
║              SIEGE HTTP POST FLOOD WITH TC QDISC CONTROL                     ║
╚══════════════════════════════════════════════════════════════════════════════╝

DESCRIPTION:
   1. Siege runs at MAXIMUM capacity (benchmark mode, ${MAX_CONCURRENT} concurrent)
   2. TC qdisc throttles bandwidth according to mathematical patterns
   3. Result: HTTP traffic follows realistic daily/weekly curves

USAGE:
   $0 [TARGET_URL] [INTERFACE] [DURATION] [COMPRESSION] [MODE] [YOYO_TYPE]

PARAMETERS:
   TARGET_URL    : Target URL (must include http:// or https://)
                   Default: http://192.168.1.120/
                   Note: POST data automatically appended (name=test&email=test@example.com)
   INTERFACE     : Network interface to control bandwidth
                   Default: eth0
   DURATION      : Test duration in seconds
                   Default: 300 (5 minutes)
   COMPRESSION   : Time compression factor (1-1000)
                   Default: 72 (1 second real = 72 seconds virtual)
   MODE          : Simulation mode
                   • python-compressed : Daily/weekly traffic patterns
                   • python-yoyo       : Oscillating load patterns
                   Default: python-compressed
   YOYO_TYPE     : Type of yo-yo pattern (only for python-yoyo mode)
                   • square    : Sharp on/off cycles (5000↔500 RPS)
                   • sawtooth  : Gradual ramp up, sharp drop
                   • burst     : Short intense bursts with quiet periods
                   Default: square

EXAMPLES:
   # Basic usage - compressed time with defaults
   $0 http://192.168.1.100
   
   # Full parameters - compressed time simulation
   $0 http://192.168.1.100 eth0 300 72 python-compressed
   
   # Yo-yo square wave pattern
   $0 http://example.com eth0 180 1 python-yoyo square
   
   # Sawtooth pattern for 10 minutes
   $0 http://api.test.local eth0 600 1 python-yoyo sawtooth
   
   # Long simulation - 1 hour real = 6 days virtual
   $0 https://api.example.com eth0 3600 144 python-compressed
   
   # Quick test with minimal compression
   $0 http://192.168.1.100 wlan0 60 10 python-compressed

TRAFFIC PATTERNS:

   Compressed Mode (Daily/Weekly Cycles):
   • Morning peak: 08:00-10:00 (higher traffic)
   • Evening peak: 19:00-21:00 (highest traffic)
   • Night drop:   01:00-05:00 (lowest traffic)
   • Weekend spike: Saturday-Sunday (+30%)
   • Minute-level variations (±30%)
   
   Yo-Yo Mode (20-second cycles):
   • Square:   5000 RPS ↔ 500 RPS (instant switch every 10s)
   • Sawtooth: 1000→10000 RPS (gradual 16s), then drop (4s)
   • Burst:    10000→5000→2000 RPS (spike 2s + decay 2s + sustain 16s)
   
FEATURE:
   ✓ TC qdisc bandwidth control architecture
   ✓ Python mathematical pattern calculations
   ✓ Compressed time simulation (72x default)
   ✓ Gaussian curves for peak modeling
   ✓ Weekly/daily/hourly cycles
   ✓ Yo-yo oscillating patterns
   ✓ 1-second update intervals
   ✓ Detailed logging format

BANDWIDTH CALCULATION:
   • Average HTTP POST request:  500 bytes (headers + POST body)
   • Average HTTP POST response: 0 bytes (minimal/ignored for flood)
   • Total per transaction: 500 bytes = 4000 bits
   • Example: 5000 RPS = 5000 × 500 × 8 = 20 Mbps bandwidth
   
   The script calculates bandwidth as:
   BW (bps) = RPS × avg_bytes_per_transaction × 8
   
   Note: Response size set to 0 because in flood mode we don't wait for responses.

POST DATA STRUCTURE:
   Automatically appended to each request:
   • Content-Type: application/x-www-form-urlencoded
   • POST Body: name=test&email=test@example.com
   • Total POST payload: ~40 bytes
   • Total request size: ~500 bytes (headers + body)

TC QDISC SETTINGS:
   • Algorithm: Token Bucket Filter (TBF)
   • Burst size: ${BURST_SIZE}
   • Latency: ${LATENCY}
   • Rate range: ${MIN_RATE} - ${MAX_RATE}
   • Update interval: 1 second (compressed) / 5 seconds (yoyo)

SIEGE CONFIGURATION:
   • Protocol: HTTP/1.1
   • Connection: close (new connection per request)
   • Chunked encoding: enabled
   • Cache: disabled
   • Concurrent users: ${MAX_CONCURRENT}
   • Benchmark mode: enabled (maximum speed)
   • Delay between requests: 0.5s per user
   • Timeout: 30s
   • Max failures: 1024

SYSTEM REQUIREMENTS:
   Required:
   • Root/sudo privileges (for TC qdisc manipulation)
   • siege (HTTP load testing tool)
   • bc (basic calculator for math operations)
   • tc from iproute2 package (traffic control)
   • Valid network interface with outbound connectivity
   
   Recommended:
   • Python3 with math module (for accurate calculations)
   • Sufficient bandwidth on interface
   • Target system authorization

OUTPUT FORMAT:
   Real-time console logging with timestamps:
   [YYYY-MM-DD HH:MM:SS] T+Xs | Virtual: DayN HH:MM | RPS: X | BW: Xmbit [PYTHON]
   
   Log file: siege_http_flood_YYYYMMDD_HHMMSS.log
   Contains:
   • All console output
   • Siege internal logs
   • Error messages
   • Cleanup activities

SAFETY FEATURES:
   • Automatic cleanup on exit (Ctrl+C, SIGTERM)
   • TC qdisc removal on termination
   • Siege process cleanup (SIGTERM → SIGKILL after 2s)
   • Failsafe: pkill -9 siege as last resort
   • Temporary file removal (\$SIEGE_RC_FILE, traffic_calculator.py)
   • Graceful shutdown handling via trap

MONITORING:
   During execution, you can monitor:
   • Real-time bandwidth: tc -s qdisc show dev $INTERFACE
   • Siege processes: ps aux | grep siege
   • Network traffic: iftop -i $INTERFACE
   • Connections: netstat -an | grep <TARGET_IP>

TROUBLESHOOTING:
   If Siege fails to start:
   • Check if siege is installed: which siege
   • Verify URL is reachable: curl -I <TARGET_URL>
   • Check interface exists: ip link show $INTERFACE
   
   If TC qdisc fails:
   • Ensure root privileges: sudo -v
   • Check kernel modules: lsmod | grep sch_tbf
   • Verify interface is up: ip link show $INTERFACE

WARNING:
   ⚠️  This script generates SIGNIFICANT HTTP POST traffic that can:
      • Saturate network bandwidth (up to 2 Mbps per default settings)
      • Overload target web servers with form submissions
      • Fill server logs rapidly
      • Trigger DDoS protection systems (Cloudflare, AWS Shield, etc.)
      • Violate terms of service
      • Cause data corruption if POST endpoints have side effects
      
   ✓ Use ONLY on systems you own or have explicit written authorization to test
   ✓ Ensure target can handle the load or risk service disruption
   ✓ Start with short duration (60s) and low compression (10x) first
   ✓ Monitor target system resources during testing
   ✓ Have a rollback plan if target becomes unresponsive

LEGAL NOTICE:
   Unauthorized load testing, stress testing, or DoS attacks are ILLEGAL in most
   jurisdictions and may result in:
   • Criminal prosecution under Computer Fraud and Abuse Act (CFAA) in the US
   • Civil liability for damages caused
   • Permanent ban from target services
   • Termination of your hosting/ISP services
   
   Always obtain explicit written permission before testing production systems.
   This tool is intended for authorized penetration testing and capacity planning ONLY.
EOF
}

# Main
main() {
    local mode="${5:-python-compressed}"
    local yoyo_type="${6:-square}"
    
    log "=== SIEGE HTTP FLOOD SIMULATOR ==="
    log "Target URL: $TARGET_URL"
    log "Interface: $INTERFACE"
    log "Duration: ${DURATION}s"
    log "Compression: ${TIME_COMPRESSION}x"
    log "Mode: $mode"
    log "Max Concurrent: $MAX_CONCURRENT users"
    
    validate_url "$TARGET_URL"
    check_dependencies
    check_python
    
    create_siege_rc
    
    if [ "$PYTHON_AVAILABLE" = true ]; then
        create_python_calculator
        log "Python math calculator created successfully"
    else
        log "Using simplified math fallback"
    fi
    
    if ! ping -c 1 -W 2 "$(echo $TARGET_URL | sed -e 's|^http://||' -e 's|^https://||' -e 's|/.*||')" &>/dev/null; then
        log "WARNING: Target may not be reachable"
    fi
    
    case "$mode" in
        "python-compressed")
            if [ "$PYTHON_AVAILABLE" = true ]; then
                generate_compressed_pattern_python "$DURATION"
            else
                log "Python not available, cannot run compressed mode"
                exit 1
            fi
            ;;
        "python-yoyo")
            if [ "$PYTHON_AVAILABLE" = true ]; then
                generate_yoyo_pattern_python "$DURATION" "$yoyo_type"
            else
                log "Python not available, cannot run yoyo mode"
                exit 1
            fi
            ;;
        *)
            log "ERROR: Unknown mode: $mode"
            show_usage
            exit 1
            ;;
    esac
    
    log "=== SIMULATION COMPLETED ==="
    log "Log file: $LOG_FILE"
}

if [[ "$1" == "-h" || "$1" == "--help" || "$1" == "help" ]]; then
    show_usage
    exit 0
fi

main "$@"
