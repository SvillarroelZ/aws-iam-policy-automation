#!/usr/bin/env bash
#
# download_policy.sh
# Interactive script to download IAM policy documents from AWS
#
# Usage:
#   ./download_policy.sh [policy-name] [output-dir]
#
# Exit codes: 0=success, 1=AWS CLI missing, 2=invalid credentials, 3=jq missing,
#             4=policy not found, 5=version retrieval failed, 6=download failed

# Strict error handling: exit on error, undefined variables, and pipe failures
set -euo pipefail

# Global variable to track temporary file for cleanup
TEMP_OUTPUT_FILE=""

# Cleanup function for trap - removes partial downloads on interruption
cleanup() {
  local exit_code=$?
  if [[ -n "$TEMP_OUTPUT_FILE" && -f "$TEMP_OUTPUT_FILE" ]]; then
    log "Cleaning up partial download: $TEMP_OUTPUT_FILE"
    rm -f "$TEMP_OUTPUT_FILE"
  fi
  exit $exit_code
}

# Set trap for cleanup on exit, interrupt (Ctrl+C), and termination
trap cleanup EXIT INT TERM

# Command line arguments with defaults using ${var:-default} syntax
readonly POLICY_NAME="${1:-}"        # First arg: policy name (optional)
readonly OUTPUT_DIR="${2:-policies}" # Second arg: output directory
readonly AWS_CMD="${AWS_CMD:-aws}"   # Allow custom AWS CLI path via env var

# Log message to stderr with timestamp
# Uses stderr (>&2) to avoid interfering with stdout JSON output
log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2  # >&2 redirects to stderr
}

# Log error and exit with specified code (default 1)
# First arg is exit code, remaining args are error message
error_exit() {
  local exit_code="${1:-1}"  # Default exit code is 1
  shift                       # Remove first arg, rest is error message
  log "ERROR: $*"
  exit "$exit_code"
}

# Prompt user for yes/no confirmation
# Returns 0 for yes, 1 for no. Loops until valid answer.
prompt_yes_no() {
  local prompt="$1"
  local response
  while true; do
    read -r -p "$prompt (y/n): " response || {
      # read returns non-zero on EOF (stdin closed)
      log "EOF detected - cannot prompt for user input."
      return 1  # Default to 'no' on EOF
    }
    case "$response" in                    # Case-insensitive pattern matching
      [Yy]|[Yy][Ee][Ss]) return 0 ;;       # Yes: return success (0)
      [Nn]|[Nn][Oo]) return 1 ;;           # No: return failure (1)
      *) log "Please answer y or n." ;;    # Invalid: loop again
    esac
  done
}

# Validate required dependencies (AWS CLI and jq)
# Exits immediately if any tool is missing
check_dependencies() {
  # command -v checks if command exists; ! inverts the result
  if ! command -v "$AWS_CMD" >/dev/null 2>&1; then
    error_exit 1 "AWS CLI not found in PATH. Install AWS CLI v2 from https://aws.amazon.com/cli/"
  fi
  
  if ! command -v jq >/dev/null 2>&1; then
    error_exit 3 "jq not found in PATH. Install jq: sudo apt-get install jq (or brew install jq)"
  fi
}

# Validate AWS credentials using STS GetCallerIdentity
# Returns JSON with user info if valid, exits on error
validate_credentials() {
  log "Validating AWS credentials..."
  
  local caller_identity
  # Call AWS STS to verify credentials; capture both stdout and stderr
  if ! caller_identity="$("$AWS_CMD" sts get-caller-identity --output json 2>&1)"; then
    error_exit 2 "Invalid or expired AWS credentials. Run 'aws configure' to set up credentials."
  fi
  
  # Validate JSON structure using jq -e (exits with error if invalid)
  if ! echo "$caller_identity" | jq -e . >/dev/null 2>&1; then
    error_exit 2 "Invalid JSON response from AWS STS. Check your AWS CLI configuration."
  fi
  
  echo "$caller_identity"
}

# Extract username from STS caller identity JSON
# Example: arn:aws:iam::123:user/alice → alice
get_user_info() {
  local caller_identity="$1"
  
  local user_arn account_id user_name
  user_arn=$(echo "$caller_identity" | jq -r '.Arn // empty')       # Extract ARN with fallback
  account_id=$(echo "$caller_identity" | jq -r '.Account // empty') # Extract account ID
  
  if [[ -z "$user_arn" || -z "$account_id" ]]; then
    error_exit 2 "Failed to extract user information from AWS STS response."
  fi
  
  user_name=$(echo "$user_arn" | awk -F'/' '{print $NF}')  # Get last field after splitting by /
  
  log "Credentials are valid."
  log "Account: $account_id"
  log "User ARN: $user_arn"
  echo "" >&2
  
  echo "$user_name"
}

# Fetch policies attached to IAM user
# Returns JSON array of policy names or empty array [] on failure
get_attached_policies() {
  local user_name="$1"
  
  log "Fetching policies attached to user '$user_name'..."
  
  local attached_policies
  # Query IAM; return [] if fails (graceful degradation)
  attached_policies="$("$AWS_CMD" iam list-attached-user-policies \
    --user-name "$user_name" \
    --query 'AttachedPolicies[].PolicyName' \
    --output json 2>/dev/null || echo '[]')"
  
  # Validate JSON structure
  if ! echo "$attached_policies" | jq -e . >/dev/null 2>&1; then
    log "Warning: Failed to parse attached policies JSON. Returning empty list."
    echo '[]'
    return
  fi
  
  echo "$attached_policies"
}

# Fetch all customer-managed policies in the account
# Excludes AWS-managed policies (--scope Local)
get_customer_policies() {
  log "Fetching customer-managed policies..."
  
  local customer_policies
  # List only customer-created policies, not AWS-managed ones
  if ! customer_policies="$("$AWS_CMD" iam list-policies \
    --scope Local \
    --query 'Policies[].PolicyName' \
    --output json 2>&1)"; then
    error_exit 4 "Failed to list customer-managed policies. Check IAM permissions."
  fi
  
  # Validate JSON structure
  if ! echo "$customer_policies" | jq -e . >/dev/null 2>&1; then
    error_exit 4 "Invalid JSON response from IAM list-policies."
  fi
  
  echo "$customer_policies"
}

# Interactive menu for policy selection
# Shows attached policies first, then all customer policies if user presses Enter
select_policy_interactive() {
  local user_name="$1"
  local selected_policy=""
  
  local attached_policies
  attached_policies=$(get_attached_policies "$user_name")
  
  local policy_count
  policy_count=$(echo "$attached_policies" | jq -r 'length')  # Count policies
  
  local policy_list
  if [[ "$policy_count" -eq 0 ]]; then
    # No attached policies, show all customer-managed
    log "No policies directamente attached to user '$user_name'."
    log "Checking for customer-managed policies in the account..."
    customer_policies=$(get_customer_policies)
    customer_count=$(echo "$customer_policies" | jq -r 'length')
    if [[ "$customer_count" -eq 0 ]]; then
      error_exit 4 "No customer-managed policies found in this account."
    fi
    log "Found $customer_count customer-managed policies:"
    policy_list=($(echo "$customer_policies" | jq -r '.[]'))
    for i in "${!policy_list[@]}"; do
      printf "%2d. %s\n" $((i+1)) "${policy_list[$i]}" >&2
    done
    echo "" >&2
    selected_policy=$(select_policy_by_number_or_name policy_list)
  else
    # Show attached policies
    log "Policies attached to user '$user_name':"
    policy_list=($(echo "$attached_policies" | jq -r '.[]'))
    for i in "${!policy_list[@]}"; do
      printf "%2d. %s\n" $((i+1)) "${policy_list[$i]}" >&2
    done
    echo "" >&2
    read -r -p "Enter policy number or name to download (or press Enter to list all customer-managed): " user_input
    if [[ -z "$user_input" ]]; then
      # User pressed Enter: show all customer policies
      customer_policies=$(get_customer_policies)
      log "Customer-managed policies:"
      policy_list=($(echo "$customer_policies" | jq -r '.[]'))
      for i in "${!policy_list[@]}"; do
        printf "%2d. %s\n" $((i+1)) "${policy_list[$i]}" >&2
      done
      echo "" >&2
      selected_policy=$(select_policy_by_number_or_name policy_list)
    else
      # Permitir selección por número o nombre
      if [[ "$user_input" =~ ^[0-9]+$ && "$user_input" -ge 1 && "$user_input" -le ${#policy_list[@]} ]]; then
        selected_policy="${policy_list[$((user_input-1))]}"
      else
        for pol in "${policy_list[@]}"; do
          if [[ "$user_input" == "$pol" ]]; then
            selected_policy="$pol"
            break
          fi
        done
        if [[ -z "$selected_policy" ]]; then
          error_exit 4 "Invalid selection. Enter a valid number or policy name."
        fi
      fi
    fi
  fi
  echo "$selected_policy"
}

# Lookup policy ARN and default version ID by name
# Returns pipe-delimited string: "arn:aws:iam::123:policy/Name|v1"
lookup_policy() {
  local policy_name="$1"

  log "Looking up policy '$policy_name' in customer-managed policies..."

  local policy_arn version_id raw_arn raw_version

  # Search for policy ARN using JMESPath query on customer policies (--scope Local)
  raw_arn="$($AWS_CMD iam list-policies \
    --scope Local \
    --query "Policies[?PolicyName=='${policy_name}'].Arn | [0]" \
    --output text)"

  policy_arn=$(echo "$raw_arn" | xargs)  # Trim whitespace using xargs

  # Validate policy exists
  if [[ -z "$policy_arn" || "$policy_arn" == "None" ]]; then
    log "Policy '$policy_name' not found. Available policies:"
    "$AWS_CMD" iam list-policies --scope Local --query 'Policies[].PolicyName' --output text 2>&1 || true
    error_exit 4 "Policy '$policy_name' was not found in customer-managed policies."
  fi

  # Get default version ID (more reliable than list-policies)
  raw_version="$($AWS_CMD iam get-policy \
    --policy-arn "$policy_arn" \
    --query "Policy.DefaultVersionId" \
    --output text)"

  version_id=$(echo "$raw_version" | xargs)  # Trim whitespace to prevent ValidationError

  if [[ -z "$version_id" || "$version_id" == "None" ]]; then
    error_exit 5 "Could not determine DefaultVersionId for policy '$policy_name'."
  fi

  log "Found policy ARN: $policy_arn"
  log "Default policy version: $version_id"
  echo "" >&2

  echo "${policy_arn}|${version_id}"  # Return both values separated by |
}


# Download policy JSON from IAM to file
# Validates JSON and reports file size
download_policy() {
  local policy_arn="$1"
  local version_id="$2"
  local output_file="$3"

  # Clean inputs to prevent whitespace issues with AWS API
  policy_arn=$(echo "$policy_arn" | xargs)
  version_id=$(echo "$version_id" | xargs)

  # Set global variable for cleanup trap
  TEMP_OUTPUT_FILE="$output_file"

  log "Downloading policy document to: $output_file"

  # Download policy document using IAM GetPolicyVersion
  if ! "$AWS_CMD" iam get-policy-version \
    --policy-arn "$policy_arn" \
    --version-id "$version_id" \
    --query "PolicyVersion.Document" \
    --output json > "$output_file"; then
    # Cleanup handled by trap, but explicit rm for clarity
    rm -f "$output_file"
    TEMP_OUTPUT_FILE=""
    error_exit 6 "Failed to download policy document from AWS IAM."
  fi

  # Validate downloaded JSON structure
  if ! jq -e . "$output_file" >/dev/null 2>&1; then
    # Cleanup handled by trap, but explicit rm for clarity
    rm -f "$output_file"
    TEMP_OUTPUT_FILE=""
    error_exit 6 "Downloaded policy is not valid JSON."
  fi

  # Clear temp file tracking after successful validation
  TEMP_OUTPUT_FILE=""

  # Report success with file size
  file_size=$(du -h "$output_file" | cut -f1)  # Get human-readable size
  echo "" >&2
  log "Policy document saved successfully!"
  log "Location: $output_file"
  log "Size: $file_size"
  echo "" >&2
  log "You can inspect it with: cat '$output_file' | jq ."
}

# Función para selección avanzada por número o nombre
select_policy_by_number_or_name() {
  local -n policy_list=$1
  local selected_policy=""
  read -r -p "Enter policy number or name to download: " user_input
  if [[ -z "$user_input" ]]; then
    error_exit 4 "No selection provided."
  fi
  if [[ "$user_input" =~ ^[0-9]+$ && "$user_input" -ge 1 && "$user_input" -le ${#policy_list[@]} ]]; then
    selected_policy="${policy_list[$((user_input-1))]}"
  else
    # Buscar por nombre exacto (case sensitive)
    for pol in "${policy_list[@]}"; do
      if [[ "$user_input" == "$pol" ]]; then
        selected_policy="$pol"
        break
      fi
    done
    if [[ -z "$selected_policy" ]]; then
      error_exit 4 "Invalid selection. Enter a valid number or policy name."
    fi
  fi
  echo "$selected_policy"
}

# Main execution flow - orchestrates the complete download workflow
# Phases: 1=check deps, 2=validate creds, 3=create dir, 4=select policy,
#         5=lookup ARN/version, 6=check overwrite, 7=download
main() {
  local policy_name="$POLICY_NAME"
  local output_dir="$OUTPUT_DIR"
  
  # Phase 1: Check dependencies (AWS CLI and jq)
  check_dependencies
  
  # Phase 2: Validate AWS credentials
  local caller_identity
  caller_identity=$(validate_credentials)
  
  # Phase 3: Extract username from credentials
  local user_name
  user_name=$(get_user_info "$caller_identity")
  
  # Phase 4: Create output directory
  mkdir -p "$output_dir"  # -p creates parent dirs if needed
  
  # Phase 5: Select policy (interactive if not provided as arg)
  if [[ -z "$policy_name" ]]; then
    policy_name=$(select_policy_interactive "$user_name")
  fi
  
  echo "" >&2
  log "Selected policy: $policy_name"
  
  # Phase 6: Lookup policy ARN and version
  # lookup_policy returns pipe-delimited string: "ARN|version"
  local policy_info policy_arn version_id
  policy_info=$(lookup_policy "$policy_name")
  policy_arn=$(echo "$policy_info" | cut -d'|' -f1)  # Extract ARN
  version_id=$(echo "$policy_info" | cut -d'|' -f2)  # Extract version
  
  # Phase 7: Check if file exists and ask before overwriting
  local output_file="${output_dir}/${policy_name}.json"
  
  if [[ -f "$output_file" ]]; then  # -f checks if regular file exists
    log "File already exists: $output_file"
    
    if ! prompt_yes_no "Do you want to overwrite it?"; then
      log "Download cancelled. Existing file preserved."
      exit 0  # Clean exit, user chose to cancel
    fi
    
    log "Overwriting existing file..."
  fi
  
  # Phase 8: Download policy document
  download_policy "$policy_arn" "$version_id" "$output_file"
}

# Execute main with all command line arguments
main "$@"

