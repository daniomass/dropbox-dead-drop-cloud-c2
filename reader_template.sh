#!/bin/bash

################################################################################

# SCRIPT: reader.sh
# DESCRIZIONE: Controller-side - Scarica e decifra output dall'agent

# WORKFLOW:
# 1. DOWNLOAD OUTPUT
#    - Scarica /Machine1/output.txt da Dropbox
#    - Formato: [RSA_ENCRYPTED_AES_KEY]:[AES_ENCRYPTED_OUTPUT]

# 2. DECIFRATURA IBRIDA (RSA+AES)
#    - Splitta formato in 2 parti (separator: ':')
#    - Decifra chiave AES con RSA private key
#    - Decifra output con chiave AES ottenuta

# 3. VISUALIZZAZIONE
#    - Mostra output in chiaro dell'agent

# 4. AUTO-REFRESH TOKEN
#    - Se access token scaduto → refresh automatico
#    - Retry download con nuovo token

# === CRITTOGRAFIA ===

# Agent ha cifrato output con RSA public key del controller
# Solo controller (con private key) può decifrare
# Protegge confidenzialità output su Dropbox

# === CONFIGURAZIONE ===

# - private_key.pem: Chiave RSA privata 4096-bit
# - .dropbox_refresh_token: Credenziali OAuth2
# - /Machine1/output.txt: File Dropbox per output

# === DIPENDENZE ===

# - openssl: Decifratura RSA/AES
# - curl: Download Dropbox API
# - base64: Decoding binario

# === USO ===

# ./reader.sh           # Normale
# ./reader.sh -q        # Quiet mode (solo output agent)

################################################################################

# === MODALITÀ QUIET ===
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
    echo "[TOKEN]: [X] File $REFRESH_TOKEN_FILE non trovato!" >&2
    exit 1
fi

refresh_access_token() {
    log "[TOKEN]: Refresh access token..."
    
    response=$(curl -s -X POST https://api.dropboxapi.com/oauth2/token \
        -d refresh_token=$REFRESH_TOKEN \
        -d grant_type=refresh_token \
        -d client_id=$APP_KEY \
        -d client_secret=$APP_SECRET)
    
    new_token=$(echo "$response" | sed -n 's/.*"access_token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    
    if [ -n "$new_token" ]; then
        ACCESS_TOKEN="$new_token"
        echo "$new_token" > "$TOKEN_CACHE_FILE"
        log "[TOKEN]: [OK] Nuovo token salvato"
        return 0
    else
        echo "[TOKEN]: [X] ERRORE parsing token" >&2
        exit 1
    fi
}

if [ -f "$TOKEN_CACHE_FILE" ]; then
    ACCESS_TOKEN=$(cat "$TOKEN_CACHE_FILE")
else
    refresh_access_token
fi

log "[OUTPUT]: Download output cifrato da Dropbox..."

encrypted_output=$(curl -s -X POST https://content.dropboxapi.com/2/files/download \
    --header "Authorization: Bearer $ACCESS_TOKEN" \
    --header "Dropbox-API-Arg: {\"path\":\"$OUTPUT_PATH\"}")

if echo "$encrypted_output" | grep -q "expired_access_token\|invalid_access_token"; then
    log "[TOKEN]: [!] Token non valido, refresh e retry..."
    refresh_access_token || exit 1
    
    encrypted_output=$(curl -s -X POST https://content.dropboxapi.com/2/files/download \
        --header "Authorization: Bearer $ACCESS_TOKEN" \
        --header "Dropbox-API-Arg: {\"path\":\"$OUTPUT_PATH\"}")
fi

log "[OUTPUT]: [OK] Output scaricato (${#encrypted_output} bytes)"

encrypted_aes_key=$(echo "$encrypted_output" | cut -d':' -f1)
encrypted_data=$(echo "$encrypted_output" | cut -d':' -f2-)

if [ -z "$encrypted_aes_key" ] || [ -z "$encrypted_data" ]; then
    echo "[OUTPUT]: [X] ERRORE: formato output non valido" >&2
    exit 1
fi

log "[OUTPUT]: Decifratura chiave AES con RSA privata..."

aes_credentials=$(echo "$encrypted_aes_key" | base64 -d 2>/dev/null | \
    openssl rsautl -decrypt -inkey "$PRIVATE_KEY_FILE" 2>/dev/null)

if [ -z "$aes_credentials" ]; then
    echo "[OUTPUT]: [X] ERRORE decifratura chiave AES" >&2
    exit 1
fi

aes_key=$(echo "$aes_credentials" | cut -d':' -f1)
aes_iv=$(echo "$aes_credentials" | cut -d':' -f2)

decrypted_output=$(echo "$encrypted_data" | base64 -d 2>/dev/null | \
    openssl enc -aes-256-cbc -d -K "$aes_key" -iv "$aes_iv" 2>/dev/null)

if [ -z "$decrypted_output" ]; then
    echo "[OUTPUT]: [X] ERRORE decifratura output" >&2
    exit 1
fi

log "[OUTPUT]: [OK] Output decifrato"

if [ $QUIET_MODE -eq 0 ]; then
    echo ""
    echo "========================================="
    echo "=== OUTPUT AGENT ==="
    echo "========================================="
fi

echo "$decrypted_output"

if [ $QUIET_MODE -eq 0 ]; then
    echo "========================================="
fi
