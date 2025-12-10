#!/bin/bash
# =============================================================================
# Auto Password Sync & 3x-ui Setup Script
# Version: 2.0.0
# Description: Tự động đổi mật khẩu root, cài đặt 3x-ui và đồng bộ Google Sheets
# Idempotent: Có thể chạy nhiều lần an toàn
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Cấu hình
# -----------------------------------------------------------------------------
readonly GOOGLE_SHEET_URL="https://script.google.com/macros/s/AKfycbwyov7TT3OIykme9mFDUO1LKRvcQrwqnU90XdCLHZcSB6ALqwJJlN5jYjLhq4S86_Pr/exec"
readonly CURL_TIMEOUT=10
readonly BACKUP_WAIT_TIME=30

# Màu sắc cho output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

# -----------------------------------------------------------------------------
# Hàm tiện ích
# -----------------------------------------------------------------------------
log_info() { echo -e "${GREEN}✓ $1${NC}"; }
log_warn() { echo -e "${YELLOW}⚠ $1${NC}"; }
log_error() { echo -e "${RED}✗ $1${NC}"; }
log_step() { echo -e "\n${YELLOW}$1${NC}"; }

# Kiểm tra quyền root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "Script này cần chạy với quyền root!"
        exit 1
    fi
}

# Validate IPv4
validate_ipv4() {
    local ip="$1"
    local IFS='.'
    local -a octets
    read -ra octets <<< "$ip"
    
    [[ ${#octets[@]} -eq 4 ]] || return 1
    
    for octet in "${octets[@]}"; do
        [[ "$octet" =~ ^[0-9]+$ ]] && ((octet >= 0 && octet <= 255)) || return 1
    done
    return 0
}

# Lấy IPv4 public với fallback
get_public_ip() {
    local ip=""
    local services=("ifconfig.me" "api.ipify.org" "icanhazip.com" "ipinfo.io/ip")
    
    for service in "${services[@]}"; do
        ip=$(curl -4 -s --max-time 5 "$service" 2>/dev/null | tr -d '[:space:]')
        if validate_ipv4 "$ip"; then
            echo "$ip"
            return 0
        fi
    done
    
    echo "ERROR_NO_IPV4"
    return 1
}

# Gỡ cài đặt 3x-ui cũ (idempotent)
uninstall_3xui() {
    if command -v x-ui &>/dev/null || [[ -f "/usr/local/x-ui/x-ui" ]] || [[ -f "/etc/systemd/system/x-ui.service" ]]; then
        log_warn "Phát hiện 3x-ui cũ, đang gỡ bỏ..."
        
        systemctl stop x-ui 2>/dev/null || true
        systemctl disable x-ui 2>/dev/null || true
        rm -f /etc/systemd/system/x-ui.service
        systemctl daemon-reload 2>/dev/null || true
        rm -rf /usr/local/x-ui /etc/x-ui
        rm -f /usr/bin/x-ui
        
        log_info "Đã gỡ bỏ 3x-ui cũ"
    fi
}

# Đồng bộ dữ liệu lên Google Sheets
sync_to_sheets() {
    local -a params=("$@")
    local response
    
    response=$(curl -s -L -X POST "$GOOGLE_SHEET_URL" \
        "${params[@]}" \
        --max-time "$CURL_TIMEOUT" 2>/dev/null) || return 1
    
    if [[ "$response" == *"success"* ]]; then
        log_info "Đồng bộ Google Sheets thành công"
        return 0
    else
        log_warn "Response: $response"
        return 1
    fi
}

# Dọn dẹp VPS về trạng thái sạch
cleanup_vps() {
    log_step "Đang dọn dẹp VPS về trạng thái sạch..."
    
    # Xóa file backup và script tạm
    rm -f /root/password_backup_*.txt 2>/dev/null || true
    rm -f /root/{auto_setup,setup_ssh*,install}.sh 2>/dev/null || true
    rm -rf /root/ssh_backups 2>/dev/null || true
    log_info "Đã xóa file backup và script tạm"
    
    # Xóa file log/tmp trong /root
    rm -f /root/*.{log,tmp} /root/nohup.out 2>/dev/null || true
    log_info "Đã xóa file log/tmp"
    
    # Xóa apt cache
    apt-get clean -y 2>/dev/null || true
    rm -rf /var/cache/apt/archives/*.deb 2>/dev/null || true
    log_info "Đã xóa apt cache"
    
    # Xóa file tạm hệ thống
    rm -rf /tmp/* /var/tmp/* 2>/dev/null || true
    log_info "Đã xóa /tmp và /var/tmp"
    
    # Xóa log cũ
    find /var/log -type f \( -name "*.gz" -o -name "*.1" -o -name "*.old" \) -delete 2>/dev/null || true
    journalctl --vacuum-time=1d 2>/dev/null || true
    log_info "Đã xóa log cũ"
    
    # Xóa file ẩn không cần thiết
    rm -f /root/.{wget-hsts,lesshst,viminfo} 2>/dev/null || true
    rm -rf /root/.cache 2>/dev/null || true
    log_info "Đã xóa file ẩn không cần thiết"
    
    # Xóa bash history
    : > ~/.bash_history
    history -c 2>/dev/null || true
    log_info "Đã xóa bash history"
}

# =============================================================================
# MAIN SCRIPT
# =============================================================================
main() {
    echo -e "${GREEN}=== Auto Password Sync & 3x-ui Setup ===${NC}\n"
    
    # Kiểm tra quyền root
    check_root
    
    # 1. Tạo mật khẩu ngẫu nhiên mạnh (20 ký tự)
    log_step "Đang tạo mật khẩu mới..."
    local NEW_PASSWORD
    NEW_PASSWORD=$(openssl rand -base64 24 | tr -d "=+/" | head -c 20)
    log_info "Mật khẩu mới: ${NEW_PASSWORD}"
    
    # 2. Đổi mật khẩu root
    log_step "Đang đổi mật khẩu root..."
    if echo "root:${NEW_PASSWORD}" | chpasswd; then
        log_info "Đổi mật khẩu root thành công"
    else
        log_error "Đổi mật khẩu root thất bại!"
        exit 1
    fi
    
    # 3. Lấy IPv4 public
    log_step "Đang lấy địa chỉ IPv4 public..."
    local PUBLIC_IP
    PUBLIC_IP=$(get_public_ip)
    if validate_ipv4 "$PUBLIC_IP"; then
        log_info "IPv4 Public: ${PUBLIC_IP}"
    else
        log_error "Không lấy được IPv4 public hợp lệ!"
    fi
    
    # 4. Lấy hostname
    local HOSTNAME
    HOSTNAME=$(hostname)
    log_info "Hostname: ${HOSTNAME}"
    
    # 5. Setup SSH
    log_step "Đang chạy script setup SSH..."
    if bash <(curl -fsSL https://raw.githubusercontent.com/Betty-Matthews/-setup_ssh/refs/heads/main/setup_ssh_ubuntu.sh) 2>/dev/null; then
        log_info "Setup SSH thành công"
    else
        log_warn "Setup SSH có thể thất bại (tiếp tục...)"
    fi
    
    # 6. Đồng bộ thông tin cơ bản lên Google Sheets
    log_step "Đang đồng bộ dữ liệu cơ bản lên Google Sheets..."
    local TIMESTAMP
    TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
    
    sync_to_sheets \
        -d "hostname=${HOSTNAME}" \
        -d "ip=${PUBLIC_IP}" \
        -d "password=${NEW_PASSWORD}" \
        -d "timestamp=${TIMESTAMP}" \
        -d "update_mode=true" || log_warn "Đồng bộ cơ bản thất bại"
    
    # 7. Cài đặt 3x-ui
    log_step "Đang cài đặt 3x-ui..."
    uninstall_3xui
    
    local INSTALL_OUTPUT
    INSTALL_OUTPUT=$(yes y | bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh) 2>&1) || true
    
    # Parse kết quả cài đặt (cải tiến regex để parse chính xác hơn)
    local PANEL_USERNAME PANEL_PASSWORD PANEL_PORT PANEL_WEBBASEPATH PANEL_ACCESS_URL
    
    # Lấy Username (dòng chứa "Username:")
    PANEL_USERNAME=$(echo "$INSTALL_OUTPUT" | grep -i "Username:" | tail -1 | sed 's/.*Username:[[:space:]]*//' | tr -d '[:space:]')
    [[ -z "$PANEL_USERNAME" ]] && PANEL_USERNAME="N/A"
    
    # Lấy Password (dòng chứa "Password:" - không phải Root Password)
    PANEL_PASSWORD=$(echo "$INSTALL_OUTPUT" | grep -i "^Password:" | tail -1 | sed 's/.*Password:[[:space:]]*//' | tr -d '[:space:]')
    [[ -z "$PANEL_PASSWORD" ]] && PANEL_PASSWORD="N/A"
    
    # Lấy Port (dòng chứa "Port:")
    PANEL_PORT=$(echo "$INSTALL_OUTPUT" | grep -i "^Port:" | tail -1 | sed 's/.*Port:[[:space:]]*//' | tr -d '[:space:]')
    [[ -z "$PANEL_PORT" || ! "$PANEL_PORT" =~ ^[0-9]+$ ]] && PANEL_PORT="N/A"
    
    # Lấy WebBasePath
    PANEL_WEBBASEPATH=$(echo "$INSTALL_OUTPUT" | grep -i "WebBasePath:" | tail -1 | sed 's/.*WebBasePath:[[:space:]]*//' | tr -d '[:space:]')
    [[ -z "$PANEL_WEBBASEPATH" ]] && PANEL_WEBBASEPATH="N/A"
    
    # Lấy Access URL
    PANEL_ACCESS_URL=$(echo "$INSTALL_OUTPUT" | grep -i "Access URL:" | tail -1 | sed 's/.*Access URL:[[:space:]]*//' | tr -d '[:space:]')
    [[ -z "$PANEL_ACCESS_URL" ]] && PANEL_ACCESS_URL="N/A"
    
    if [[ "$PANEL_USERNAME" != "N/A" && "$PANEL_PASSWORD" != "N/A" ]]; then
        log_info "Cài đặt 3x-ui thành công"
    else
        log_warn "Không thể parse thông tin 3x-ui"
    fi
    
    # 8. Đồng bộ thông tin 3x-ui lên Google Sheets
    log_step "Đang đồng bộ thông tin 3x-ui lên Google Sheets..."
    TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
    
    sync_to_sheets \
        -d "hostname=${HOSTNAME}" \
        -d "ip=${PUBLIC_IP}" \
        -d "password=${NEW_PASSWORD}" \
        -d "timestamp=${TIMESTAMP}" \
        -d "panel_username=${PANEL_USERNAME}" \
        -d "panel_password=${PANEL_PASSWORD}" \
        -d "panel_port=${PANEL_PORT}" \
        -d "panel_webbasepath=${PANEL_WEBBASEPATH}" \
        -d "panel_access_url=${PANEL_ACCESS_URL}" \
        -d "update_mode=true" || log_warn "Đồng bộ 3x-ui thất bại"
    
    # 9. Tóm tắt thông tin
    echo -e "\n${GREEN}=== THÔNG TIN SERVER ===${NC}"
    echo -e "${YELLOW}Hostname:${NC} ${HOSTNAME}"
    echo -e "${YELLOW}IP Public:${NC} ${PUBLIC_IP}"
    echo -e "${YELLOW}Root Password:${NC} ${NEW_PASSWORD}"
    echo -e "${GREEN}=== THÔNG TIN 3X-UI PANEL ===${NC}"
    echo -e "${YELLOW}Username:${NC} ${PANEL_USERNAME}"
    echo -e "${YELLOW}Password:${NC} ${PANEL_PASSWORD}"
    echo -e "${YELLOW}Port:${NC} ${PANEL_PORT}"
    echo -e "${YELLOW}WebBasePath:${NC} ${PANEL_WEBBASEPATH}"
    echo -e "${YELLOW}Access URL:${NC} ${PANEL_ACCESS_URL}"
    echo -e "${YELLOW}Thời gian:${NC} ${TIMESTAMP}"
    
    # 10. Backup tạm thời
    local BACKUP_FILE="/root/password_backup_$(date '+%Y%m%d_%H%M%S').txt"
    cat > "$BACKUP_FILE" << EOF
==========================================
THÔNG TIN SERVER - BACKUP
==========================================
Hostname: ${HOSTNAME}
IP Public: ${PUBLIC_IP}
Root Password: ${NEW_PASSWORD}
==========================================
THÔNG TIN 3X-UI PANEL
==========================================
Username: ${PANEL_USERNAME}
Password: ${PANEL_PASSWORD}
Port: ${PANEL_PORT}
WebBasePath: ${PANEL_WEBBASEPATH}
Access URL: ${PANEL_ACCESS_URL}
Timestamp: ${TIMESTAMP}
==========================================
EOF
    chmod 600 "$BACKUP_FILE"
    
    echo -e "\n${GREEN}✓ Backup tại: ${BACKUP_FILE}${NC}"
    echo -e "${YELLOW}  (Tự động xóa sau ${BACKUP_WAIT_TIME} giây...)${NC}\n"
    
    sleep "$BACKUP_WAIT_TIME"
    
    # 11. Dọn dẹp
    cleanup_vps
    
    echo -e "\n${GREEN}✓ Hoàn tất! VPS đã sạch, thông tin đã lưu trên Google Sheets${NC}\n"
}

# Chạy script
main "$@"
