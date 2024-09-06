#!/bin/bash

# Usage: ./script.sh EVENTS_CSV_FILE OUTPUT_FILE
if [ $# -eq 0 ]; then
  echo "Usage: $0 EVENTS_CSV_FILE OUTPUT_FILE"
  echo "Example Usage: $0 ACME_PhishingA_Events.csv ACME_ClickedLink"
  exit 1
fi

# Check if ipcalc is installed, and install it if not
if ! command -v ipcalc &> /dev/null; then
  echo "[*] ipcalc is not installed. Installing ipcalc..."
  
  # Detect package manager and install ipcalc
  if [[ "$(uname)" == "Linux" ]]; then
    if command -v apt-get &> /dev/null; then
      sudo apt-get update
      sudo apt-get install -y ipcalc
    elif command -v yum &> /dev/null; then
      sudo yum install -y ipcalc
    elif command -v dnf &> /dev/null; then
      sudo dnf install -y ipcalc
    else
      echo "[-] Package manager not found. Please install ipcalc manually."
      exit 1
    fi
  elif [[ "$(uname)" == "Darwin" ]]; then
    if command -v brew &> /dev/null; then
      brew install ipcalc
    else
      echo "[-] Homebrew not found. Please install ipcalc using Homebrew or manually."
      exit 1
    fi
  else
    echo "[-] Unsupported OS. Please install ipcalc manually."
    exit 1
  fi
else
  echo "[*] ipcalc is already installed."
fi

events_csv_file=$1
file_name=$2

exclude_file="exclude_me.txt"
clicked_file="clicked_link.txt"
cidr_file="cidr_blocks.txt"
rate_limit_pause=30
ip_cache="ip_cache.txt"

# Ensure that the cidr_blocks.txt file exists
if [ ! -f "$cidr_file" ]; then
  touch "$cidr_file"
  echo "[*] Created cidr_blocks.txt file."
fi

# Extract the IP list
ip_list=$(awk -F ',' '/Clicked Link/ {print $6}' "${events_csv_file}" | awk -F ':' '{print $3}' | tr -d '"' | sort | uniq)

echo "[*] CSV: ${events_csv_file}"
echo "[!] $0 currently checks for machine clicks from:"
echo "- Amazon"
echo "- Microsoft"
echo "- Google"
echo "- Proofpoint"
echo "- Cloudflare"
echo ""

# Function to log messages with colors
log() {
  local level="$1"
  local message="$2"
  local color="$3"
  echo -e "${color}[$level] ${message}\033[0m"
}

# Color definitions
RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[0;33m"

# Function to check if IP is part of any CIDR block
is_ip_in_cidr() {
  local ip="$1"
  while read -r cidr_block; do
    if ipcalc -nb "$cidr_block" | grep -qw "$ip"; then
      echo "$cidr_block"
      return 0
    fi
  done < "$cidr_file"
  return 1
}

# Function to check if IP is cached
is_ip_cached() {
  local ip="$1"
  grep -q "^${ip}:" "$ip_cache" 2>/dev/null
}

# Function to get cached IP status
get_ip_status() {
  local ip="$1"
  grep "^${ip}:" "$ip_cache" | cut -d':' -f2
}

# Function to cache IP status
cache_ip_status() {
  local ip="$1"
  local status="$2"
  echo "${ip}:${status}" >> "$ip_cache"
}

# Function to query IP information
query_ip_info() {
  local ip="$1"
  curl -s -H "Accept: application/json" "https://ifconfig.co/?ip=${ip}"
}

# Function to process each IP
process_ip() {
  local ip="$1"

  # Check if the IP is already cached
  if is_ip_cached "$ip"; then
    local status
    status=$(get_ip_status "$ip")
    if [[ "$status" == "machine" ]]; then
      log "INFO" "IP $ip is a machine click (cached)." "$YELLOW"
      echo "$ip" >> "$exclude_file"
    else
      log "INFO" "IP $ip is a human click (cached)." "$GREEN"
      echo "$ip" >> "$clicked_file"
    fi
    return
  fi

  # Check if IP is in the exclude list
  if grep -qw "$ip" "$exclude_file"; then
    log "INFO" "IP $ip is already in the exclusions list." "$YELLOW"
    cache_ip_status "$ip" "machine"
    return
  fi

  # Check if IP is part of any CIDR block
  local cidr
  cidr=$(is_ip_in_cidr "$ip") || true
  if [[ -n "$cidr" ]]; then
    log "INFO" "IP $ip is part of CIDR block: $cidr" "$YELLOW"
    echo "$ip" >> "$exclude_file"
    cache_ip_status "$ip" "machine"
    return
  fi

  # Query IP information from external service
  log "INFO" "Checking IP: $ip..." "$GREEN"
  local response
  response=$(query_ip_info "$ip")

  # Handle rate limiting
  while echo "$response" | grep -iq 'too many requests'; do
    log "WARN" "Rate limited by API. Pausing for $rate_limit_pause seconds..." "$YELLOW"
    sleep "$rate_limit_pause"
    response=$(query_ip_info "$ip")
  done

  # Check for 'amazon' and other ASNs but distinguish 'ec2'
  if echo "$response" | grep -iq '"asn_org":.*\(amazon\|microsoft\|google-proxy\|proofpoint\|cloudflare\|rate-limited-proxy\)'; then
    # Check if hostname contains 'ec2' (likely human VPN click)
    if echo "$response" | grep -iq '"hostname":.*ec2'; then
      log "INFO" "IP $ip is from EC2, likely a human VPN click." "$GREEN"
      echo "$ip" >> "$clicked_file"
      cache_ip_status "$ip" "human"
    else
      log "WARN" "IP $ip is a machine click based on ASN organization." "$YELLOW"
      echo "$ip" >> "$exclude_file"
      cache_ip_status "$ip" "machine"

      # Extract CIDR block using whois and add to cidr_file
      local cidr_block
      cidr_block=$(whois "$ip" | grep -i "CIDR" | awk '{print $2}' | tr -d ',')
      if [[ -n "$cidr_block" ]]; then
        if ! grep -qw "$cidr_block" "$cidr_file"; then
          echo "$cidr_block" >> "$cidr_file"
          log "INFO" "CIDR block $cidr_block added to $cidr_file." "$GREEN"
        else
          log "INFO" "CIDR block already in $cidr_file." "$GREEN"
        fi
      fi
    fi
  else
    # Check if the user agent suggests a machine (e.g., curl, python-requests, etc.)
    if echo "$response" | grep -iq '"user_agent":.*\(curl\|python-requests\|Wget\|PostmanRuntime\)'; then
      log "WARN" "IP $ip is a machine click (based on user agent)." "$RED"
      echo "$ip" >> "$exclude_file"
      cache_ip_status "$ip" "machine"
    else
      log "INFO" "IP $ip is a human click." "$GREEN"
      echo "$ip" >> "$clicked_file"
      cache_ip_status "$ip" "human"
    fi
  fi
}

# Process each IP in the list
while read -r ip; do
  process_ip "$ip"
done <<< "$ip_list"

# Generate the clicked list from the processed IPs
grep -i "Clicked Link" "$events_csv_file" | grep -i -v -f "$exclude_file" | awk -F ',' '{print $2}' | sort | uniq > "${file_name}.txt"

count_clicked=$(wc -l < "${file_name}.txt")
log "INFO" "${count_clicked} recipients clicked on the link (saved in ${file_name}.txt):" "$GREEN"
cat "${file_name}.txt"
