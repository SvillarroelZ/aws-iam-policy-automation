#!/usr/bin/env bash
#
# download_policy.sh
#
# Interactive script to download IAM policy documents from AWS.
# Validates credentials, discovers user policies, and downloads selected policy as JSON.
#
# Usage:
#   ./download_policy.sh [policy-name] [output-dir]
#
# Interactive mode (recommended):
#   ./download_policy.sh
#
# Direct mode:
#   ./download_policy.sh lab_policy
#   ./download_policy.sh lab_policy policies
#
# Environment variables:
#   AWS_PROFILE=name    Use specific AWS profile
#   AWS_CMD=/path/aws   Use custom AWS CLI binary
#
# Exit codes:
#   0 - Success
#   1 - AWS CLI not found
#   2 - Invalid or expired credentials
#   3 - jq not found
#   4 - Policy not found
#   5 - Failed to retrieve policy version
#   6 - Failed to download policy

set -euo pipefail

# Constants
readonly POLICY_NAME="${1:-}"
readonly OUTPUT_DIR="${2:-policies}"
readonly AWS_CMD="${AWS_CMD:-aws}"

# Log message to stderr with timestamp
log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
}

# Log error message and exit with specified code
error_exit() {
  local exit_code="${1:-1}"
  shift
  log "ERROR: $*"
  exit "$exit_code"
}

# Prompt user for yes/no confirmation
prompt_yes_no() {
  local prompt="$1"
  local response
  while true; do
    read -r -p "$prompt (y/n): " response
    case "$response" in
      [Yy]|[Yy][Ee][Ss]) return 0 ;;
      [Nn]|[Nn][Oo]) return 1 ;;
      *) log "Please answer y or n." ;;
    esac
  done
}

# Validate required dependencies
check_dependencies() {
  if ! command -v "$AWS_CMD" >/dev/null 2>&1; then
    error_exit 1 "AWS CLI not found in PATH. Install AWS CLI v2 from https://aws.amazon.com/cli/"
  fi
  
  if ! command -v jq >/dev/null 2>&1; then
    error_exit 3 "jq not found in PATH. Install jq: sudo apt-get install jq (or brew install jq)"
  fi
}

# Validate AWS credentials and retrieve caller identity
validate_credentials() {
  log "Validating AWS credentials..."
  
  local caller_identity
  if ! caller_identity="$("$AWS_CMD" sts get-caller-identity --output json 2>&1)"; then
    error_exit 2 "Invalid or expired AWS credentials. Run 'aws configure' to set up credentials."
  fi
  
  # Validate JSON response
  if ! echo "$caller_identity" | jq -e . >/dev/null 2>&1; then
    error_exit 2 "Invalid JSON response from AWS STS. Check your AWS CLI configuration."
  fi
  
  echo "$caller_identity"
}

# Extract user information from caller identity
get_user_info() {
  local caller_identity="$1"
  
  local user_arn account_id user_name
  user_arn=$(echo "$caller_identity" | jq -r '.Arn // empty')
  account_id=$(echo "$caller_identity" | jq -r '.Account // empty')
  
  if [[ -z "$user_arn" || -z "$account_id" ]]; then
    error_exit 2 "Failed to extract user information from AWS STS response."
  fi
  
  user_name=$(echo "$user_arn" | awk -F'/' '{print $NF}')
  
  log "Credentials are valid."
  log "Account: $account_id"
  log "User ARN: $user_arn"
  echo ""
  
  echo "$user_name"
}

# Fetch policies attached to the specified user
get_attached_policies() {
  local user_name="$1"
  
  log "Fetching policies attached to user '$user_name'..."
  
  local attached_policies
  attached_policies="$("$AWS_CMD" iam list-attached-user-policies \
    --user-name "$user_name" \
    --query 'AttachedPolicies[].PolicyName' \
    --output json 2>/dev/null || echo '[]')"
  
  if ! echo "$attached_policies" | jq -e . >/dev/null 2>&1; then
    log "Warning: Failed to parse attached policies JSON. Returning empty list."
    echo '[]'
    return
  fi
  
  echo "$attached_policies"
}

# Fetch all customer-managed policies in the account
get_customer_policies() {
  log "Fetching customer-managed policies..."
  
  local customer_policies
  if ! customer_policies="$("$AWS_CMD" iam list-policies \
    --scope Local \
    --query 'Policies[].PolicyName' \
    --output json 2>&1)"; then
    error_exit 4 "Failed to list customer-managed policies. Check IAM permissions."
  fi
  
  if ! echo "$customer_policies" | jq -e . >/dev/null 2>&1; then
    error_exit 4 "Invalid JSON response from IAM list-policies."
  fi
  
  echo "$customer_policies"
}

# Interactive policy selection workflow
select_policy_interactive() {
  local user_name="$1"
  local selected_policy=""
  
  local attached_policies
  attached_policies=$(get_attached_policies "$user_name")
  
  local policy_count
  policy_count=$(echo "$attached_policies" | jq -r 'length')
  
  if [[ "$policy_count" -eq 0 ]]; then
    log "No policies directly attached to user '$user_name'."
    log "Checking for customer-managed policies in the account..."
    
    local customer_policies
    customer_policies=$(get_customer_policies)
    
    local customer_count
    customer_count=$(echo "$customer_policies" | jq -r 'length')
    
    if [[ "$customer_count" -eq 0 ]]; then
      error_exit 4 "No customer-managed policies found in this account."
    fi
    
    log "Found $customer_count customer-managed policies:"
    echo "$customer_policies" | jq -r '.[]' | nl -w2 -s'. '
    echo ""
    
    read -r -p "Enter policy name to download: " selected_policy
    
    if [[ -z "$selected_policy" ]]; then
      error_exit 4 "No policy name provided."
    fi
  else
    log "Policies attached to user '$user_name':"
    echo "$attached_policies" | jq -r '.[]' | nl -w2 -s'. '
    echo ""
    
    read -r -p "Enter policy name to download (or press Enter to list all customer-managed): " selected_policy
    
    if [[ -z "$selected_policy" ]]; then
      echo ""
      log "Listing all customer-managed policies in the account..."
      
      local customer_policies
      customer_policies=$(get_customer_policies)
      
      log "Customer-managed policies:"
      echo "$customer_policies" | jq -r '.[]' | nl -w2 -s'. '
      echo ""
      
      read -r -p "Enter policy name to download: " selected_policy
      
      if [[ -z "$selected_policy" ]]; then
        error_exit 4 "No policy name provided."
      fi
    fi
  fi
  
  echo "$selected_policy"
}

# Lookup policy ARN and version ID
lookup_policy() {
  local policy_name="$1"
  
  log "Looking up policy '$policy_name' in customer-managed policies..."
  
  local policy_arn version_id raw_arn raw_version
  
  raw_arn="$("$AWS_CMD" iam list-policies \
    --scope Local \
    --query "Policies[?PolicyName=='${policy_name}'].Arn | [0]" \
    --output text)"
  
  # Clean ARN from whitespace
  policy_arn=$(echo "$raw_arn" | xargs)
  
  if [[ -z "$policy_arn" || "$policy_arn" == "None" ]]; then
    log "Policy '$policy_name' not found. Available policies:"
    "$AWS_CMD" iam list-policies --scope Local --query 'Policies[].PolicyName' --output text 2>&1 || true
    error_exit 4 "Policy '$policy_name' was not found in customer-managed policies."
  fi
  
  # Get version ID directly from get-policy (more reliable)
  raw_version="$("$AWS_CMD" iam get-policy \
    --policy-arn "$policy_arn" \
    --query "Policy.DefaultVersionId" \
    --output text)"
  
  # Clean version ID from whitespace
  version_id=$(echo "$raw_version" | xargs)
  
  if [[ -z "$version_id" || "$version_id" == "None" ]]; then
    error_exit 5 "Could not determine DefaultVersionId for policy '$policy_name'."
  fi
  
  log "Found policy ARN: $policy_arn"
  log "Default policy version: $version_id"
  echo ""
  
  echo "${policy_arn}|${version_id}"
}

# Download policy document to file
download_policy() {
  local policy_arn="$1"
  local version_id="$2"
  local output_file="$3"
  
  # Clean inputs from any whitespace
  policy_arn=$(echo "$policy_arn" | xargs)
  version_id=$(echo "$version_id" | xargs)
  
  log "Downloading policy document to: $output_file"
  
  if ! "$AWS_CMD" iam get-policy-version \
    --policy-arn "$policy_arn" \
    --version-id "$version_id" \
    --query "PolicyVersion.Document" \
    --output json > "$output_file"; then
    rm -f "$output_file"
    error_exit 6 "Failed to download policy document from AWS IAM."
  fi
  
  # Validate downloaded JSON
  if ! jq -e . "$output_file" >/dev/null 2>&1; then
    rm -f "$output_file"
    error_exit 6 "Downloaded policy is not valid JSON."
  fi
  
  local file_size
  file_size=$(du -h "$output_file" | cut -f1)
  
  echo ""
  log "Policy document saved successfully!"
  log "Location: $output_file"
  log "Size: $file_size"
  echo ""
  log "You can inspect it with: cat '$output_file' | jq ."
}

# Main execution flow
main() {
  local policy_name="$POLICY_NAME"
  local output_dir="$OUTPUT_DIR"
  
  # Phase 1: Dependency validation
  check_dependencies
  
  # Phase 2: Credential validation
  local caller_identity
  caller_identity=$(validate_credentials)
  
  local user_name
  user_name=$(get_user_info "$caller_identity")
  
  # Phase 3: Output directory preparation (create early to ensure it exists)
  mkdir -p "$output_dir"
  
  # Phase 4: Policy selection
  if [[ -z "$policy_name" ]]; then
    policy_name=$(select_policy_interactive "$user_name")
  fi
  
  echo ""
  log "Selected policy: $policy_name"
  
  # Phase 5: Policy lookup
  local policy_info policy_arn version_id
  policy_info=$(lookup_policy "$policy_name")
  policy_arn=$(echo "$policy_info" | cut -d'|' -f1)
  version_id=$(echo "$policy_info" | cut -d'|' -f2)
  
  # Phase 6: File overwrite confirmation
  local output_file="${output_dir}/${policy_name}.json"
  
  if [[ -f "$output_file" ]]; then
    log "File already exists: $output_file"
    
    if ! prompt_yes_no "Do you want to overwrite it?"; then
      log "Download cancelled. Existing file preserved."
      exit 0
    fi
    
    log "Overwriting existing file..."
  fi
  
  # Phase 6: Policy download
  download_policy "$policy_arn" "$version_id" "$output_file"
}

# Execute main function with all script arguments
main "$@"
