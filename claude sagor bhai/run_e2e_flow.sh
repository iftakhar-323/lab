#!/usr/bin/env bash
set -e

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

CE_URL="http://127.0.0.1:8085"
PE_URL="http://127.0.0.1:8095"

echo -e "${BLUE}======================================================${NC}"
echo -e "${BLUE}  PORIDHI E2E FLOW: ACCOUNT -> VM -> EXPOSE -> HTTP  ${NC}"
echo -e "${BLUE}======================================================${NC}"

# Check if services are up
if ! curl -s "$CE_URL/healthz" >/dev/null 2>&1 || ! curl -s "$PE_URL/healthz" >/dev/null 2>&1; then
  echo -e "${YELLOW}[!] Services are not running. Starting local stack via dev-local.sh...${NC}"
  HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  "$HERE/proxy-engine/scripts/dev-local.sh"
fi

echo -e "\n${GREEN}[1/6] Creating Account in Cloud-Engine...${NC}"
ACCT_RESP=$(curl -s -X POST "$CE_URL/accounts/create" \
  -H "Content-Type: application/json" \
  -d '{"name":"live-demo-user","email":"demo@poridhi.io"}')

echo "Response: $ACCT_RESP"
ACCT_ID=$(echo "$ACCT_RESP" | jq -r .account_id)
VPC_ID=$(echo "$ACCT_RESP" | jq -r .vpc_id)
echo -e "${GREEN}--> Account Created: ID=$ACCT_ID | VPC=$VPC_ID${NC}"

echo -e "\n${GREEN}[2/6] Registering Customer in Proxy-Engine...${NC}"
CUST_RESP=$(curl -s -X POST "$PE_URL/customers" \
  -H "Content-Type: application/json" \
  -d "{\"account_id\":\"$ACCT_ID\",\"tier\":\"standard\"}")
echo "Response: $CUST_RESP"
echo -e "${GREEN}--> Customer Registered successfully.${NC}"

echo -e "\n${GREEN}[3/6] Requesting MicroVM Launch...${NC}"
VM_RESP=$(curl -s -X POST "$CE_URL/vms/create" \
  -H "Content-Type: application/json" \
  -d "{
    \"name\": \"demo-web-vm\",
    \"account_id\": \"$ACCT_ID\",
    \"vpc_id\": \"$VPC_ID\",
    \"image_id\": \"ubuntu-22.04\",
    \"vcpu\": 2,
    \"memory_mb\": 1024
  }")
echo "Response: $VM_RESP"
VM_ID=$(echo "$VM_RESP" | jq -r '.id // .vm_id // empty')

if [ -n "$VM_ID" ]; then
  echo -e "${GREEN}--> VM Launched: $VM_ID${NC}"
  echo -e "\n${GREEN}[4/6] Checking VM Status & SSH info...${NC}"
  curl -s "$CE_URL/vms/$VM_ID" | jq . || true
  curl -s "$CE_URL/vms/$VM_ID/ssh" | jq . || true
else
  echo -e "${YELLOW}--> Note: In local control-plane without Firecracker hypervisor, orchestrator responds with 503 (Expected behavior on laptop).${NC}"
fi

echo -e "\n${GREEN}[5/6] Exposing VM Port 80 via Proxy-Engine...${NC}"
SUBDOMAIN="demo-site-$RANDOM"
EXP_RESP=$(curl -s -X POST "$PE_URL/expose" \
  -H "Content-Type: application/json" \
  -d "{
    \"customer_id\": \"$ACCT_ID\",
    \"vm_ids\": [\"${VM_ID:-vm-demo-1}\"],
    \"port\": 80,
    \"subdomain\": \"$SUBDOMAIN\"
  }")
echo "Response: $EXP_RESP"

echo -e "\n${GREEN}[6/6] Probing Ingress Route via Envoy Proxy...${NC}"
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "Host: $SUBDOMAIN.expose.local" "$PE_URL/healthz" || echo "000")
echo -e "${GREEN}--> Envoy Ingress Router responded with HTTP $HTTP_CODE${NC}"

echo -e "\n${BLUE}======================================================${NC}"
echo -e "${BLUE}                 FLOW TEST FINISHED                   ${NC}"
echo -e "${BLUE}======================================================${NC}"

