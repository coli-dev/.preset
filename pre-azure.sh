#!/usr/bin/env bash
set -euo pipefail

# ====== Cấu hình ======
LOCATION="southeastasia"
RG="coli.dev"

VNET="coli-dev-vnet"
SUBNET="default"

NSG="coli-dev-nsg"
PIP="coli-dev-pip"
NIC="coli-dev-nic"

VM="coli.dev"
SIZE="Standard_B2ats_v2"   # tuỳ subscription, nếu không có thì đổi B1s/B2s
ADMIN="coli"

# KHÔNG nên hardcode password. Nếu bạn vẫn muốn thì export từ env:
# export ADMIN_PASS='...'
: "${ADMIN_PASS:?Please export ADMIN_PASS before running.}"

# Ubuntu 22.04 LTS Gen2
IMAGE_URN="Canonical:0001-com-ubuntu-server-jammy:22_04-lts-gen2:latest"

OSDISK_SIZE_GB=64
STORAGE_SKU="Premium_LRS"

DNS_LABEL="coli"   # => coli.southeastasia.cloudapp.azure.com

# ====== Login trước ======
# az login

# ====== Resource Group ======
az group create --name "$RG" --location "$LOCATION"

# ====== NSG ======
az network nsg create -g "$RG" -n "$NSG"

# Chỉ mở SSH (an toàn hơn)
az network nsg rule create \
  -g "$RG" --nsg-name "$NSG" -n allow-ssh \
  --priority 200 \
  --access Allow \
  --direction Inbound \
  --protocol Tcp \
  --source-address-prefixes '*' \
  --source-port-ranges '*' \
  --destination-address-prefixes '*' \
  --destination-port-ranges 22

# (Tuỳ chọn) mở HTTP/HTTPS
# az network nsg rule create \
#   -g "$RG" --nsg-name "$NSG" -n allow-http \
#   --priority 210 --access Allow --direction Inbound --protocol Tcp \
#   --source-address-prefixes '*' --source-port-ranges '*' \
#   --destination-address-prefixes '*' --destination-port-ranges 80
#
# az network nsg rule create \
#   -g "$RG" --nsg-name "$NSG" -n allow-https \
#   --priority 220 --access Allow --direction Inbound --protocol Tcp \
#   --source-address-prefixes '*' --source-port-ranges '*' \
#   --destination-address-prefixes '*' --destination-port-ranges 443

# Nếu bạn cố tình muốn mở tất cả inbound (không khuyến nghị) thì dùng cái này thay allow-ssh:
# az network nsg rule create \
#   -g "$RG" --nsg-name "$NSG" -n allow-all \
#   --priority 200 --access Allow --direction Inbound --protocol '*' \
#   --source-address-prefixes '*' --source-port-ranges '*' \
#   --destination-address-prefixes '*' --destination-port-ranges '*'

# ====== VNet/Subnet ======
az network vnet create \
  -g "$RG" -n "$VNET" \
  --address-prefix 10.0.0.0/16 \
  --subnet-name "$SUBNET" --subnet-prefix 10.0.1.0/24 \
  --network-security-group "$NSG"

# ====== Public IP Basic Dynamic + DNS Label ======
az network public-ip create \
  -g "$RG" -n "$PIP" \
  --sku Basic \
  --allocation-method Dynamic \
  --version IPv4 \
  --dns-name "$DNS_LABEL"

# ====== NIC ======
az network nic create \
  -g "$RG" -n "$NIC" \
  --vnet-name "$VNET" --subnet "$SUBNET" \
  --network-security-group "$NSG" \
  --public-ip-address "$PIP"

# ====== VM Ubuntu 22.04 ======
az vm create \
  -g "$RG" -n "$VM" \
  --image "$IMAGE_URN" \
  --size "$SIZE" \
  --admin-username "$ADMIN" \
  --authentication-type password \
  --admin-password "$ADMIN_PASS" \
  --nics "$NIC" \
  --os-disk-size-gb "$OSDISK_SIZE_GB" \
  --storage-sku "$STORAGE_SKU"

# ====== Xuất IP + Domain ======
PUBLIC_IP="$(az vm show -d -g "$RG" -n "$VM" --query publicIps -o tsv)"
FQDN="$(az network public-ip show -g "$RG" -n "$PIP" --query dnsSettings.fqdn -o tsv)"

echo "✅ Tạo xong VM: $VM"
echo "🌐 IP công khai (dynamic): $PUBLIC_IP"
echo "🌐 Domain: $FQDN"
echo "🔑 SSH: ssh ${ADMIN}@${FQDN}"
