#!/bin/bash

# Cấu hình Google Sheets
GOOGLE_SHEET_URL="https://script.google.com/macros/s/AKfycbwt62a7LgF_U2KXsy2dFCfbGphgIY9YBc3BqB-EaKRMJbD65xu-BfAsAFrib9GK4632/exec"

# Màu sắc cho output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function validate IPv4
validate_ipv4() {
    local ip=$1
    local stat=1
    
    # Kiểm tra format cơ bản
    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        # Tách IP thành array
        OIFS=$IFS
        IFS='.'
        ip=($ip)
        IFS=$OIFS
        
        # Kiểm tra mỗi octet <= 255
        if [[ ${ip[0]} -le 255 && ${ip[1]} -le 255 && ${ip[2]} -le 255 && ${ip[3]} -le 255 ]]; then
            stat=0
        fi
    fi
    
    return $stat
}

echo -e "${GREEN}=== Script tự động đổi mật khẩu root và đồng bộ Google Sheets ===${NC}\n"

# 1. Tạo mật khẩu ngẫu nhiên mạnh
NEW_PASSWORD=$(openssl rand -base64 16 | tr -d "=+/" | cut -c1-16)
echo -e "${YELLOW}Mật khẩu mới được tạo: ${GREEN}${NEW_PASSWORD}${NC}"

# 2. Đổi mật khẩu root
echo -e "\n${YELLOW}Đang đổi mật khẩu root...${NC}"
echo "root:${NEW_PASSWORD}" | chpasswd

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ Đổi mật khẩu root thành công!${NC}"
else
    echo -e "${RED}✗ Đổi mật khẩu root thất bại!${NC}"
    exit 1
fi

# 3. Lấy IPv4 public (không phải IPv6 hay IP nội bộ)
echo -e "\n${YELLOW}Đang lấy địa chỉ IPv4 public...${NC}"

# Thử các service lấy IP, ưu tiên IPv4
PUBLIC_IP=$(curl -4 -s --max-time 5 ifconfig.me 2>/dev/null)
if [ -z "$PUBLIC_IP" ] || ! validate_ipv4 "$PUBLIC_IP"; then
    PUBLIC_IP=$(curl -4 -s --max-time 5 api.ipify.org 2>/dev/null)
fi
if [ -z "$PUBLIC_IP" ] || ! validate_ipv4 "$PUBLIC_IP"; then
    PUBLIC_IP=$(curl -4 -s --max-time 5 icanhazip.com 2>/dev/null)
fi
if [ -z "$PUBLIC_IP" ] || ! validate_ipv4 "$PUBLIC_IP"; then
    PUBLIC_IP=$(curl -4 -s --max-time 5 ipinfo.io/ip 2>/dev/null)
fi

# Validate IPv4 cuối cùng
if validate_ipv4 "$PUBLIC_IP"; then
    echo -e "${GREEN}✓ IPv4 Public: ${PUBLIC_IP}${NC}"
else
    echo -e "${RED}✗ Không lấy được IPv4 public hợp lệ!${NC}"
    PUBLIC_IP="ERROR_NO_IPV4"
fi

# 4. Lấy hostname
HOSTNAME=$(hostname)
echo -e "${GREEN}Hostname: ${HOSTNAME}${NC}"

# 5. Chạy script setup SSH
echo -e "\n${YELLOW}Đang chạy script setup SSH...${NC}"
bash <(curl -fsSL https://raw.githubusercontent.com/Betty-Matthews/-setup_ssh/refs/heads/main/setup_ssh_ubuntu.sh)

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ Setup SSH thành công!${NC}"
else
    echo -e "${RED}✗ Setup SSH có thể thất bại (tiếp tục...)${NC}"
fi

# 6. Đồng bộ lên Google Sheets
echo -e "\n${YELLOW}Đang đồng bộ dữ liệu lên Google Sheets...${NC}"

RESPONSE=$(curl -s -L -X POST "$GOOGLE_SHEET_URL" \
    -d "hostname=${HOSTNAME}" \
    -d "ip=${PUBLIC_IP}" \
    -d "password=${NEW_PASSWORD}" \
    -d "timestamp=$(date '+%Y-%m-%d %H:%M:%S')" \
    -d "update_mode=true" \
    --max-time 10)

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ Đồng bộ lên Google Sheets thành công!${NC}"
    if [[ $RESPONSE == *"success"* ]]; then
        echo -e "${GREEN}Response: ${RESPONSE}${NC}"
    else
        echo -e "${YELLOW}Response: ${RESPONSE}${NC}"
    fi
else
    echo -e "${RED}✗ Đồng bộ lên Google Sheets thất bại!${NC}"
fi

# 7. Tóm tắt thông tin
echo -e "\n${GREEN}=== THÔNG TIN SERVER ===${NC}"
echo -e "${YELLOW}Hostname:${NC} ${HOSTNAME}"
echo -e "${YELLOW}IP Public:${NC} ${PUBLIC_IP}"
echo -e "${YELLOW}Mật khẩu root mới:${NC} ${NEW_PASSWORD}"
echo -e "${YELLOW}Thời gian:${NC} $(date '+%Y-%m-%d %H:%M:%S')"
echo -e "\n${RED}⚠ LƯU Ý: Hãy lưu lại mật khẩu mới này!${NC}\n"

# 8. Lưu thông tin vào file local (backup tạm thời)
BACKUP_FILE="/root/password_backup_$(date '+%Y%m%d_%H%M%S').txt"
cat > "$BACKUP_FILE" << EOF
==========================================
THÔNG TIN SERVER - BACKUP
==========================================
Hostname: ${HOSTNAME}
IP Public: ${PUBLIC_IP}
Root Password: ${NEW_PASSWORD}
Timestamp: $(date '+%Y-%m-%d %H:%M:%S')
==========================================
EOF

chmod 600 "$BACKUP_FILE"
echo -e "${GREEN}✓ Thông tin đã được backup tại: ${BACKUP_FILE}${NC}"
echo -e "${YELLOW}   (File backup sẽ tự động xóa sau 30 giây...)${NC}\n"

# Đợi 30 giây để user có thể đọc/copy thông tin
sleep 30

# 9. Dọn dẹp tự động
echo -e "\n${YELLOW}Đang dọn dẹp file tạm...${NC}"

# Xóa file backup
if [ -f "$BACKUP_FILE" ]; then
    rm -f "$BACKUP_FILE"
    echo -e "${GREEN}✓ Đã xóa: $BACKUP_FILE${NC}"
fi

# Xóa tất cả file backup cũ
rm -f /root/password_backup_*.txt 2>/dev/null
echo -e "${GREEN}✓ Đã xóa tất cả file backup cũ${NC}"

# Xóa script này nếu nó tồn tại
if [ -f "/root/auto_setup.sh" ]; then
    rm -f /root/auto_setup.sh
    echo -e "${GREEN}✓ Đã xóa: /root/auto_setup.sh${NC}"
fi

# Xóa thư mục ssh_backups (nếu muốn)
if [ -d "/root/ssh_backups" ]; then
    rm -rf /root/ssh_backups
    echo -e "${GREEN}✓ Đã xóa: /root/ssh_backups${NC}"
fi

echo -e "${GREEN}✓ VPS đã sạch sẽ!${NC}\n"
echo -e "${YELLOW}⚠ Lưu ý: Thông tin mật khẩu đã được lưu an toàn trên Google Sheets${NC}\n"
