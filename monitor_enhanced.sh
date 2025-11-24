#!/bin/bash
# Enhanced script to monitor comprehensive metrics for AI-based autoscaling prediction
# Author: Enhanced monitoring system
# Version: 2.0

# ============================================================================
# CONFIGURATION
# ============================================================================

# Default OpenStack Instance ID (Can be overridden by command-line argument)
DEFAULT_RESOURCE_ID="d27ee539-3d00-4bbe-9b3b-2cbaf5aff071"
RESOURCE_ID="${1:-$DEFAULT_RESOURCE_ID}"
SERVER_NAME="${2:-$RESOURCE_ID}"

# Network Interface ID (auto-detect or use provided)
INTERFACE_ID="${3:-0660c989-ba40-5c9e-950a-7d67bc89f3b2}"

# Granularity for metrics collection (in seconds)
GRANULARITY=60

# Sleep interval between collections (in seconds)
SLEEP_INTERVAL=60

# ============================================================================
# DIRECTORY SETUP
# ============================================================================

# Create directory structure
CURRENT_DATE="$(date +%Y-%m-%d)"
BASE_DIR="./$SERVER_NAME/$CURRENT_DATE"
mkdir -p "$BASE_DIR"/{cpu,memory,network,disk}

echo "=== Monitoring Configuration ==="
echo "Instance ID: $RESOURCE_ID"
echo "Interface ID: $INTERFACE_ID"
echo "Server Name: $SERVER_NAME"
echo "Base Directory: $BASE_DIR"
echo "Granularity: ${GRANULARITY}s"
echo "================================"

# ============================================================================
# METRICS COLLECTION FUNCTIONS
# ============================================================================

# Function to collect CPU metrics
collect_cpu_metrics() {
    local timestamp=$(date +%Y-%m-%d_%H-%M-%S)
    echo "[$(date)] Collecting CPU metrics..."
    
    # CPU usage in nanoseconds
    openstack metric measures show --granularity $GRANULARITY -f csv --utc \
        --resource-id "$RESOURCE_ID" cpu \
        > "$BASE_DIR/cpu/cpu_nanoseconds_${timestamp}.csv"
    
    # CPU utilization percentage
    openstack metric aggregates --granularity $GRANULARITY -f csv --resource-type instance \
        "(* (/ (/ (aggregate rate:mean (metric cpu mean)) 1000000000) 60) 100)" \
        "id=$RESOURCE_ID" \
        > "$BASE_DIR/cpu/cpu_utilization_percent_${timestamp}.csv"
    
    # vCPUs count
    openstack metric measures show --granularity $GRANULARITY -f csv --utc \
        --resource-id "$RESOURCE_ID" vcpus \
        > "$BASE_DIR/cpu/vcpus_${timestamp}.csv"
}

# Function to collect Memory metrics
collect_memory_metrics() {
    local timestamp=$(date +%Y-%m-%d_%H-%M-%S)
    echo "[$(date)] Collecting Memory metrics..."
    
    # Memory usage
    openstack metric measures show --granularity $GRANULARITY -f csv --utc \
        --resource-id "$RESOURCE_ID" memory.usage \
        > "$BASE_DIR/memory/memory_usage_${timestamp}.csv"
    
    # Memory available
    openstack metric measures show --granularity $GRANULARITY -f csv --utc \
        --resource-id "$RESOURCE_ID" memory.available \
        > "$BASE_DIR/memory/memory_available_${timestamp}.csv"
    
    # Memory resident
    openstack metric measures show --granularity $GRANULARITY -f csv --utc \
        --resource-id "$RESOURCE_ID" memory.resident \
        > "$BASE_DIR/memory/memory_resident_${timestamp}.csv"
    
    # Memory total
    openstack metric measures show --granularity $GRANULARITY -f csv --utc \
        --resource-id "$RESOURCE_ID" memory \
        > "$BASE_DIR/memory/memory_total_${timestamp}.csv"
    
    # Swap in
    openstack metric measures show --granularity $GRANULARITY -f csv --utc \
        --resource-id "$RESOURCE_ID" memory.swap.in \
        > "$BASE_DIR/memory/memory_swap_in_${timestamp}.csv" 2>/dev/null
    
    # Swap out
    openstack metric measures show --granularity $GRANULARITY -f csv --utc \
        --resource-id "$RESOURCE_ID" memory.swap.out \
        > "$BASE_DIR/memory/memory_swap_out_${timestamp}.csv" 2>/dev/null
}

# Function to collect Network metrics
collect_network_metrics() {
    local timestamp=$(date +%Y-%m-%d_%H-%M-%S)
    echo "[$(date)] Collecting Network metrics..."
    
    # Incoming bytes
    openstack metric measures show --granularity $GRANULARITY -f csv --utc \
        --resource-id "$INTERFACE_ID" network.incoming.bytes \
        > "$BASE_DIR/network/network_incoming_bytes_${timestamp}.csv" 2>/dev/null
    
    # Outgoing bytes
    openstack metric measures show --granularity $GRANULARITY -f csv --utc \
        --resource-id "$INTERFACE_ID" network.outgoing.bytes \
        > "$BASE_DIR/network/network_outgoing_bytes_${timestamp}.csv" 2>/dev/null
    
    # Incoming packets
    openstack metric measures show --granularity $GRANULARITY -f csv --utc \
        --resource-id "$INTERFACE_ID" network.incoming.packets \
        > "$BASE_DIR/network/network_incoming_packets_${timestamp}.csv" 2>/dev/null
    
    # Outgoing packets
    openstack metric measures show --granularity $GRANULARITY -f csv --utc \
        --resource-id "$INTERFACE_ID" network.outgoing.packets \
        > "$BASE_DIR/network/network_outgoing_packets_${timestamp}.csv" 2>/dev/null
    
    # Incoming packets dropped
    openstack metric measures show --granularity $GRANULARITY -f csv --utc \
        --resource-id "$INTERFACE_ID" network.incoming.packets.drop \
        > "$BASE_DIR/network/network_incoming_packets_drop_${timestamp}.csv" 2>/dev/null
    
    # Outgoing packets dropped
    openstack metric measures show --granularity $GRANULARITY -f csv --utc \
        --resource-id "$INTERFACE_ID" network.outgoing.packets.drop \
        > "$BASE_DIR/network/network_outgoing_packets_drop_${timestamp}.csv" 2>/dev/null
    
    # Incoming packets errors
    openstack metric measures show --granularity $GRANULARITY -f csv --utc \
        --resource-id "$INTERFACE_ID" network.incoming.packets.error \
        > "$BASE_DIR/network/network_incoming_packets_error_${timestamp}.csv" 2>/dev/null
    
    # Outgoing packets errors
    openstack metric measures show --granularity $GRANULARITY -f csv --utc \
        --resource-id "$INTERFACE_ID" network.outgoing.packets.error \
        > "$BASE_DIR/network/network_outgoing_packets_error_${timestamp}.csv" 2>/dev/null
}

# Function to collect Disk metrics
collect_disk_metrics() {
    local timestamp=$(date +%Y-%m-%d_%H-%M-%S)
    echo "[$(date)] Collecting Disk metrics..."
    
    # Get all disk device IDs for this instance
    DISK_IDS=$(openstack metric resource list --type disk -f value -c id | head -n 5)
    
    for DISK_ID in $DISK_IDS; do
        # Create subdirectory for each disk
        DISK_DIR="$BASE_DIR/disk/${DISK_ID}"
        mkdir -p "$DISK_DIR"
        
        # Read bytes
        openstack metric measures show --granularity $GRANULARITY -f csv --utc \
            --resource-id "$DISK_ID" disk.device.read.bytes \
            > "$DISK_DIR/disk_read_bytes_${timestamp}.csv" 2>/dev/null
        
        # Write bytes
        openstack metric measures show --granularity $GRANULARITY -f csv --utc \
            --resource-id "$DISK_ID" disk.device.write.bytes \
            > "$DISK_DIR/disk_write_bytes_${timestamp}.csv" 2>/dev/null
        
        # Read requests (IOPS)
        openstack metric measures show --granularity $GRANULARITY -f csv --utc \
            --resource-id "$DISK_ID" disk.device.read.requests \
            > "$DISK_DIR/disk_read_requests_${timestamp}.csv" 2>/dev/null
        
        # Write requests (IOPS)
        openstack metric measures show --granularity $GRANULARITY -f csv --utc \
            --resource-id "$DISK_ID" disk.device.write.requests \
            > "$DISK_DIR/disk_write_requests_${timestamp}.csv" 2>/dev/null
        
        # Read latency
        openstack metric measures show --granularity $GRANULARITY -f csv --utc \
            --resource-id "$DISK_ID" disk.device.read.latency \
            > "$DISK_DIR/disk_read_latency_${timestamp}.csv" 2>/dev/null
        
        # Write latency
        openstack metric measures show --granularity $GRANULARITY -f csv --utc \
            --resource-id "$DISK_ID" disk.device.write.latency \
            > "$DISK_DIR/disk_write_latency_${timestamp}.csv" 2>/dev/null
        
        # Disk usage
        openstack metric measures show --granularity $GRANULARITY -f csv --utc \
            --resource-id "$DISK_ID" disk.device.usage \
            > "$DISK_DIR/disk_usage_${timestamp}.csv" 2>/dev/null
        
        # Disk capacity
        openstack metric measures show --granularity $GRANULARITY -f csv --utc \
            --resource-id "$DISK_ID" disk.device.capacity \
            > "$DISK_DIR/disk_capacity_${timestamp}.csv" 2>/dev/null
    done
    
    # Instance-level disk metrics
    # Root disk size
    openstack metric measures show --granularity $GRANULARITY -f csv --utc \
        --resource-id "$RESOURCE_ID" disk.root.size \
        > "$BASE_DIR/disk/disk_root_size_${timestamp}.csv" 2>/dev/null
    
    # Ephemeral disk size
    openstack metric measures show --granularity $GRANULARITY -f csv --utc \
        --resource-id "$RESOURCE_ID" disk.ephemeral.size \
        > "$BASE_DIR/disk/disk_ephemeral_size_${timestamp}.csv" 2>/dev/null
}

# Function to create consolidated CSV with all metrics
create_consolidated_csv() {
    local timestamp=$(date +%Y-%m-%d_%H-%M-%S)
    echo "[$(date)] Creating consolidated metrics file..."
    
    # This will be implemented in Python for better data processing
    # For now, we keep separate CSV files
    echo "Timestamp,Metric_Type,Metric_Name,Value,Unit" > "$BASE_DIR/consolidated_metrics_${timestamp}.csv"
}

# Function to cleanup old data (keep last 7 days)
cleanup_old_data() {
    echo "[$(date)] Cleaning up old data..."
    find "./$SERVER_NAME" -type d -mtime +7 -exec rm -rf {} + 2>/dev/null
}

# Function to log collection statistics
log_statistics() {
    local timestamp=$(date +%Y-%m-%d_%H-%M-%S)
    echo "[$(date)] Metrics collection cycle completed" >> "$BASE_DIR/collection.log"
    echo "Files created: $(find $BASE_DIR -name "*.csv" | wc -l)" >> "$BASE_DIR/collection.log"
    echo "Total size: $(du -sh $BASE_DIR | cut -f1)" >> "$BASE_DIR/collection.log"
    echo "---" >> "$BASE_DIR/collection.log"
}

# ============================================================================
# MAIN COLLECTION LOOP
# ============================================================================

echo "Starting metrics collection..."
echo "Press Ctrl+C to stop"

# Trap for cleanup on exit
trap 'echo "Stopping metrics collection..."; exit 0' INT TERM

while true; do
    echo ""
    echo "=========================================="
    echo "Collection Cycle: $(date)"
    echo "=========================================="
    
    # Collect all metrics
    collect_cpu_metrics
    collect_memory_metrics
    collect_network_metrics
    collect_disk_metrics
    
    # Log statistics
    log_statistics
    
    # Cleanup old data (run once per day)
    if [ $(date +%H:%M) == "00:00" ]; then
        cleanup_old_data
    fi
    
    echo ""
    echo "Metrics collection completed. Next collection in ${SLEEP_INTERVAL}s..."
    echo "Data stored in: $BASE_DIR"
    
    sleep $SLEEP_INTERVAL
done
