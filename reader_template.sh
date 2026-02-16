#!/bin/bash

################################################################################
# SCRIPT: reader.sh
# DESCRIPTION: Controller-side - Download and decrypt output from agent
################################################################################

# === QUIET MODE ===
QUIET_MODE=0
if [ "$1" = "-q" ]; then
    QUIET_MODE=1
    shift
fi

log() {
    [ $QUIET_MODE -eq 0 ] && echo "$@"
}

PRIVATE_KEY_FILE="private_key.pem"
OUTPUT_PATH="/Machine1/output.txt"
REFRESH_TOKEN_FILE=".dropbox_refresh_token"
TOKEN_CACHE_FILE=".dropbox_access_token"

if [ -f "$REFRESH_TOKEN_FILE" ]; then
    source "$REFRESH_TOKEN_FILE"
else
    echo "[TOKEN]: [X] File $REFRESH_TOKEN_FILE not found!" >&2
    exit 1
fi

refresh_access_token() {
    log "[TOKEN]: Refreshing access token..."
    
    response=$(curl -s -X POST https://api.dropboxapi.com/oauth2/token \
        -d refresh_token=$REFRESH_TOKEN \
        -d grant_type=refresh_token \
        -d client_id=$APP_KEY \
        -d client_secret=$APP_SECRET)
    
    new_token=$(echo "$response" | sed -n 's/.*"access_token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    
    if [ -n "$new_token" ]; then
        ACCESS_TOKEN="$new_token"
        echo "$new_token" > "$TOKEN_CACHE_FILE"
        log "[TOKEN]: [OK] New token saved"
        return 0
    else
        echo "[TOKEN]: [X] ERROR parsing token" >&2
        exit 1
    fi
}

if [ -f "$TOKEN_CACHE_FILE" ]; then
    ACCESS_TOKEN=$(cat "$TOKEN_CACHE_FILE")
else
    refresh_access_token
fi

log "[OUTPUT]: Downloading encrypted output from Dropbox..."

encrypted_output=$(curl -s -X POST https://content.dropboxapi.com/2/files/download \
    --header "Authorization: Bearer $ACCESS_TOKEN" \
    --header "Dropbox-API-Arg: {\"path\":\"$OUTPUT_PATH\"}")

if echo "$encrypted_output" | grep -q "expired_access_token\|invalid_access_token"; then
    log "[TOKEN]: [!] Invalid token, refreshing and retrying..."
    refresh_access_token || exit 1
    
    encrypted_output=$(curl -s -X POST https://content.dropboxapi.com/2/files/download \
        --header "Authorization: Bearer $ACCESS_TOKEN" \
        --header "Dropbox-API-Arg: {\"path\":\"$OUTPUT_PATH\"}")
fi

log "[OUTPUT]: [OK] Output downloaded (${#encrypted_output} bytes)"

encrypted_aes_key=$(echo "$encrypted_output" | cut -d':' -f1)
encrypted_data=$(echo "$encrypted_output" | cut -d':' -f2-)

if [ -z "$encrypted_aes_key" ] || [ -z "$encrypted_data" ]; then
    echo "[OUTPUT]: [X] ERROR: invalid output format" >&2
    exit 1
fi

log "[OUTPUT]: Decrypting AES key with RSA private key..."

aes_credentials=$(echo "$encrypted_aes_key" | base64 -d 2>/dev/null | \
    openssl rsautl -decrypt -inkey "$PRIVATE_KEY_FILE" 2>/dev/null)

if [ -z "$aes_credentials" ]; then
    echo "[OUTPUT]: [X] ERROR decrypting AES key" >&2
    exit 1
fi

aes_key=$(echo "$aes_credentials" | cut -d':' -f1)
aes_iv=$(echo "$aes_credentials" | cut -d':' -f2)

decrypted_output=$(echo "$encrypted_data" | base64 -d 2>/dev/null | \
    openssl enc -aes-256-cbc -d -K "$aes_key" -iv "$aes_iv" 2>/dev/null)

if [ -z "$decrypted_output" ]; then
    echo "[OUTPUT]: [X] ERROR decrypting output" >&2
    exit 1
fi

log "[OUTPUT]: [OK] Output decrypted"

if [ $QUIET_MODE -eq 0 ]; then
    echo ""
    echo "========================================="
    echo "=== AGENT OUTPUT ==="
    echo "========================================="
fi

echo "$decrypted_output"

if [ $QUIET_MODE -eq 0 ]; then
    echo "========================================="
fi
