#!/bin/bash

# Advanced script to create and deploy a Salesforce package using sfdx force:source:deploy between two commit IDs
# Authenticates using JWT token, enhanced test class detection, supports dry-run, retries, and validation
# Prerequisites: Salesforce CLI (sfdx), git, jq must be installed
# Usage: ./deploy_salesforce_source_jwt_full.sh <start_commit_id> <end_commit_id> [--config <config_file>] [--dry-run] [--log-level <info|debug>]

set -e

# Default configuration
CONFIG_FILE="deploy_config.json"
LOG_LEVEL="info"
DRY_RUN=false
MAX_RETRIES=3
RETRY_DELAY=30
PARALLEL_TEST_BATCHES=10

# Temporary directories and files
PACKAGE_DIR="delta_package_$(date +%s)"
DESTRUCTIVE_DIR="destructive_changes_$(date +%s)"
TEST_CLASSES_FILE="test_classes_$(date +%s).txt"
LOG_FILE="deploy_$(date +%Y%m%d_%H%M%S).log"
ORG_ALIAS="temp_deploy_org_$(date +%s)"

# Default test class patterns
TEST_CLASS_PATTERNS=("Test\.cls$" "_Test\.cls$" "^Test_.*\.cls$")

# Function to log messages
log() {
    local level="$1"
    local message="$2"
    if [ "$level" = "debug" ] && [ "$LOG_LEVEL" != "debug" ]; then
        return
    fi
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $message" | tee -a "$LOG_FILE"
}

# Function to exit with error
error_exit() {
    log "error" "$1"
    exit 1
}

# Function to clean up
cleanup() {
    log "info" "Cleaning up temporary files and org alias..."
    rm -rf "$PACKAGE_DIR" "$DESTRUCTIVE_DIR" "$TEST_CLASSES_FILE"
    sfdx force:auth:logout --targetusername "$ORG_ALIAS" --noprompt || true
}

# Function to check if file is a valid test class
is_test_class() {
    local file="$1"
    local class_name=$(basename "$file" .cls)
    local reason=""

    # Check if file is empty or invalid
    if [ ! -s "$file" ]; then
        log "debug" "Skipping $file: Empty or invalid file"
        return 1
    fi

    # Check for @isTest annotation (ignore comments and strings)
    if grep -E '^[[:space:]]*@isTest([[:space:]]|\()' "$file" >/dev/null; then
        reason="Contains @isTest annotation"
        log "debug" "Identified $class_name as test class: $reason"
        echo "$class_name" >> "$TEST_CLASSES_FILE"
        return 0
    fi

    # Check filename against patterns
    for pattern in "${TEST_CLASS_PATTERNS[@]}"; do
        if [[ "$file" =~ $pattern ]]; then
            reason="Matches pattern $pattern"
            log "debug" "Identified $class_name as test class: $reason"
            echo "$class_name" >> "$TEST_CLASSES_FILE"
            return 0
        fi
    done

    log "debug" "File $file is not a test class"
    return 1
}

# Parse arguments
while [ $# -gt 0 ]; do
    case "$1" in
        --config) CONFIG_FILE="$2"; shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        --log-level) LOG_LEVEL="$2"; shift 2 ;;
        *) break ;;
    esac
done

# Check required arguments
if [ $# -ne 2 ]; then
    error_exit "Usage: $0 <start_commit_id> <end_commit_id> [--config <config_file>] [--dry-run] [--log-level <info|debug>]"
fi

START_COMMIT="$1"
END_COMMIT="$2"

# Load configuration from file or environment
load_config() {
    log "info" "Loading configuration from $CONFIG_FILE or environment..."
    if [ -f "$CONFIG_FILE" ]; then
        USERNAME=$(jq -r '.username // ""' "$CONFIG_FILE")
        CLIENT_ID=$(jq -r '.client_id // ""' "$CONFIG_FILE")
        JWT_KEY_FILE=$(jq -r '.jwt_key_file // ""' "$CONFIG_FILE")
        INSTANCE_URL=$(jq -r '.instance_url // ""' "$CONFIG_FILE")
        # Load custom test class patterns if provided
        CUSTOM_PATTERNS=$(jq -r '.test_class_patterns // [] | join(",")' "$CONFIG_FILE")
        if [ -n "$CUSTOM_PATTERNS" ]; then
            IFS=',' read -r -a TEST_CLASS_PATTERNS <<< "$CUSTOM_PATTERNS"
            log "info" "Loaded custom test class patterns: ${TEST_CLASS_PATTERNS[*]}"
        fi
    fi
    # Override with environment variables if set
    USERNAME="${SF_USERNAME:-$USERNAME}"
    CLIENT_ID="${SF_CLIENT_ID:-$CLIENT_ID}"
    JWT_KEY_FILE="${SF_JWT_KEY_FILE:-$JWT_KEY_FILE}"
    INSTANCE_URL="${SF_INSTANCE_URL:-$INSTANCE_URL}"
    
    # Validate configuration
    [ -z "$USERNAME" ] && error_exit "Username not provided in config or SF_USERNAME"
    [ -z "$CLIENT_ID" ] && error_exit "Client ID not provided in config or SF_CLIENT_ID"
    [ -z "$JWT_KEY_FILE" ] && error_exit "JWT key file not provided in config or SF_JWT_KEY_FILE"
    [ -z "$INSTANCE_URL" ] && error_exit "Instance URL not provided in config or SF_INSTANCE_URL"
    [ ! -f "$JWT_KEY_FILE" ] && error_exit "JWT key file not found at $JWT_KEY_FILE"
}

# Initialize directories
init_dirs() {
    log "debug" "Initializing directories: $PACKAGE_DIR, $DESTRUCTIVE_DIR"
    mkdir -p "$PACKAGE_DIR" "$DESTRUCTIVE_DIR"
    > "$TEST_CLASSES_FILE"
}

# Validate git commits
validate_commits() {
    log "info" "Validating commit IDs..."
    if ! git rev-parse "$START_COMMIT" >/dev/null 2>&1 || ! git rev-parse "$END_COMMIT" >/dev/null 2>&1; then
        error_exit "Invalid commit ID(s)"
    fi
}

# Authenticate using JWT
authenticate() {
    log "info" "Authenticating to Salesforce using JWT..."
    for ((i=1; i<=MAX_RETRIES; i++)); do
        if sfdx force:auth:jwt:grant \
            --clientid "$CLIENT_ID" \
            --jwtkeyfile "$JWT_KEY_FILE" \
            --username "$USERNAME" \
            --instanceurl "$INSTANCE_URL" \
            --setalias "$ORG_ALIAS" \
            --json > auth_result.json 2>> "$LOG_FILE"; then
            log "info" "Authentication successful"
            rm -f auth_result.json
            return
        else
            log "error" "Authentication attempt $i failed"
            [ $i -lt $MAX_RETRIES ] && log "info" "Retrying in $RETRY_DELAY seconds..."
            sleep $RETRY_DELAY
        fi
    done
    error_exit "Authentication failed after $MAX_RETRIES attempts"
}

# Generate package from changed files
generate_package() {
    log "info" "Generating list of changed files between $START_COMMIT and $END_COMMIT..."
    CHANGED_FILES=$(git diff --name-only "$START_COMMIT" "$END_COMMIT" -- force-app/main/default)
    [ -z "$CHANGED_FILES" ] && error_exit "No changes detected between commits"

    # Initialize package.xml
    cat > "$PACKAGE_DIR/package.xml" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<Package xmlns="http://soap.sforce.com/2006/04/metadata">
    <version>58.0</version>
</Package>
EOF

    # Initialize destructiveChanges.xml
    cat > "$DESTRUCTIVE_DIR/destructiveChanges.xml" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<Package xmlns="http://soap.sforce.com/2006/04/metadata">
</Package>
EOF

    log "info" "Processing changed files and checking for test classes..."
    while IFS= read -r file; do
        if [ -f "$file" ]; then
            log "debug" "Copying $file to package directory"
            mkdir -p "$PACKAGE_DIR/$(dirname "$file")"
            cp "$file" "$PACKAGE_DIR/$file"

            # Check for test classes
            if [[ "$file" =~ \.cls$ ]]; then
                is_test_class "$file"
            fi
        else
            # Handle destructive changes
            metadata_type=$(echo "$file" | grep -oP '(?<=force-app/main/default/)[^/]+')
            file_name=$(basename "$file" | cut -d'.' -f1)
            if [ -n "$metadata_type" ] && [ -n "$file_name" ]; then
                log "info" "Adding $file_name to destructive changes ($metadata_type)"
                if ! grep -q "<types>" "$DESTRUCTIVE_DIR/destructiveChanges.xml"; then
                    sed -i "/<Package/a \    <types>" "$DESTRUCTIVE_DIR/destructiveChanges.xml"
                fi
                sed -i "/<types>/a \        <members>$file_name</members>\n        <name>$metadata_type</name>" "$DESTRUCTIVE_DIR/destructiveChanges.xml"
            fi
        fi
    done <<< "$CHANGED_FILES"

    log "info" "Generating package.xml..."
    sfdx force:source:manifest:create --fromdir "$PACKAGE_DIR/force-app" --manifestname package --outputdir "$PACKAGE_DIR"

    if ! grep -q "<types>" "$PACKAGE_DIR/package.xml"; then
        log "info" "No metadata to deploy"
        exit 0
    fi
    log "debug" "Package.xml content:"
    cat "$PACKAGE_DIR/package.xml" >> "$LOG_FILE"
}

# Validate deployment
validate_deployment() {
    log "info" "Validating deployment..."
    local cmd="sfdx force:source:deploy --sourcepath \"$PACKAGE_DIR/force-app\" --manifest \"$PACKAGE_DIR/package.xml\" --targetusername \"$ORG_ALIAS\" --checkonly --json"
    if [ -s "$TEST_CLASSES_FILE" ]; then
        TEST_CLASSES=$(cat "$TEST_CLASSES_FILE" | tr '\n' ',' | sed 's/,$//')
        cmd="$cmd --testlevel RunSpecifiedTests --runtests \"$TEST_CLASSES\""
    else
        cmd="$cmd --testlevel RunLocalTests"
    fi

    for ((i=1; i<=MAX_RETRIES; i++)); do
        if eval "$cmd" > validate_result.json 2>> "$LOG_FILE"; then
            log "info" "Validation successful"
            rm -f validate_result.json
            return
        else
            log "error" "Validation attempt $i failed"
            [ $i -lt $MAX_RETRIES ] && log "info" "Retrying in $RETRY_DELAY seconds..."
            sleep $RETRY_DELAY
        fi
    done
    error_exit "Validation failed after $MAX_RETRIES attempts"
}

# Deploy package
deploy_package() {
    log "info" "Deploying package to org: $ORG_ALIAS..."
    local cmd="sfdx force:source:deploy --sourcepath \"$PACKAGE_DIR/force-app\" --manifest \"$PACKAGE_DIR/package.xml\" --targetusername \"$ORG_ALIAS\" --json"
    if [ -s "$TEST_CLASSES_FILE" ]; then
        log "info" "Running specific test classes in $PARALLEL_TEST_BATCHES batches: $(cat "$TEST_CLASSES_FILE" | tr '\n' ',')"
        TEST_CLASSES=$(cat "$TEST_CLASSES_FILE" | tr '\n' ',' | sed 's/,$//')
        cmd="$cmd --testlevel RunSpecifiedTests --runtests \"$TEST_CLASSES\""
    else
        log "info" "No specific test classes found. Running local tests..."
        cmd="$cmd --testlevel RunLocalTests"
    fi

    if [ "$DRY_RUN" = true ]; then
        log "info" "Dry-run mode: Skipping actual deployment"
        log "info" "Would have run: $cmd"
        return
    fi

    for ((i=1; i<=MAX_RETRIES; i++)); do
        if eval "$cmd" > deploy_result.json 2>> "$LOG_FILE"; then
            log "info" "Deployment successful"
            rm -f deploy_result.json
            return
        else
            log "error" "Deployment attempt $i failed"
            [ $i -lt $MAX_RETRIES ] && log "info" "Retrying in $RETRY_DELAY seconds..."
            sleep $RETRY_DELAY
        fi
    done
    error_exit "Deployment failed after $MAX_RETRIES attempts"
}

# Deploy destructive changes
deploy_destructive() {
    if ! grep -q "<members>" "$DESTRUCTIVE_DIR/destructiveChanges.xml"; then
        log "info" "No destructive changes to deploy"
        return
    fi

    log "info" "Deploying destructive changes..."
    local cmd="sfdx force:source:deploy --manifest \"$DESTRUCTIVE_DIR/destructiveChanges.xml\" --postdestructivechanges \"$DESTRUCTIVE_DIR/destructiveChanges.xml\" --targetusername \"$ORG_ALIAS\" --json"

    if [ "$DRY_RUN" = true ]; then
        log "info" "Dry-run mode: Skipping destructive deployment"
        log "info" "Would have run: $cmd"
        log "info" "Destructive changes content:"
        cat "$DESTRUCTIVE_DIR/destructiveChanges.xml" >> "$LOG_FILE"
        return
    fi

    for ((i=1; i<=MAX_RETRIES; i++)); do
        if eval "$cmd" > destructive_result.json 2>> "$LOG_FILE"; then
            log "info" "Destructive changes deployed successfully"
            rm -f destructive_result.json
            return
        else
            log "error" "Destructive deployment attempt $i failed"
            [ $i -lt $MAX_RETRIES ] && log "info" "Retrying in $RETRY_DELAY seconds..."
            sleep $RETRY_DELAY
        fi
    done
    error_exit "Destructive deployment failed after $MAX_RETRIES attempts"
}

# Main execution
log "info" "Starting Salesforce deployment script..."
trap cleanup EXIT SIGINT SIGTERM
load_config
init_dirs
validate_commits
authenticate
generate_package
validate_deployment
deploy_package
deploy_destructive
log "info" "Deployment completed successfully!"