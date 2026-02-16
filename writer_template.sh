#!/bin/bash

################################################################################

# SCRIPT: writer.sh
# DESCRIZIONE: Controller-side - Cifra comandi e li invia all'agent via Dropbox

# WORKFLOW:
# 1. INPUT COMANDO
#    - Riceve comando da tastiera o argomento CLI
#    - Esempio: ./writer.sh "ls -la /tmp"

# 2. CIFRATURA IBRIDA (RSA+AES)
#    - Genera chiave AES-256 random + IV random
#    - Cifra comando con AES-256-CBC (veloce, simmetrica)
#    - Firma chiave AES con RSA private key (prova autenticità)
#    - Formato: [RSA_SIGNED_AES_KEY]:[AES_ENCRYPTED_COMMAND]

# 3. UPLOAD SU DROPBOX
#    - Carica comando cifrato su /Machine1/input.txt
#    - Agent scaricherà e verificherà firma RSA

# 4. AUTO-REFRESH TOKEN
#    - Se access token scaduto → refresh automatico
#    - Retry upload con nuovo token

# === CRITTOGRAFIA ===

# INPUT (Controller → Agent):
# - Controller firma AES key con RSA private → Agent verifica con public
# - Garantisce che solo controller legittimo può inviare comandi
# - Agent rifiuta comandi non firmati correttamente

# OUTPUT (Agent → Controller):
# - Agent cifra AES key con RSA public → Controller decifra con private
# - Garantisce che solo controller può leggere output

# === SICUREZZA ===

# - Solo chi possiede private_key.pem può firmare comandi validi
# - Agent verifica firma con public_key.pem embedded
# - Protegge contro command injection da terzi su Dropbox
# - Forward secrecy: chiave AES diversa per ogni comando

# === CONFIGURAZIONE ===

# - private_key.pem: Chiave RSA privata 4096-bit
# - .dropbox_refresh_token: Credenziali OAuth2 (APP_KEY, APP_SECRET, REFRESH_TOKEN)
# - /Machine1/input.txt: File Dropbox per comandi

# === DIPENDENZE ===

# - openssl: Cifratura RSA/AES
# - curl: Upload Dropbox API
# - base64: Encoding binario

# === USO ===

# ./writer.sh "comando"           # Normale
# ./writer.sh -q "comando"        # Quiet mode (no output)

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
INPUT_PATH="/Machine1/input.txt"
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

if [ -z "$1" ]; then
    echo "Inserisci comando da inviare:"
    read -r COMMAND
else
    COMMAND="$*"
fi

log "[INPUT]: Comando da cifrare: '$COMMAND'"
log "[INPUT]: Cifratura ibrida (RSA+AES)..."

aes_key=$(openssl rand -hex 32)
aes_iv=$(openssl rand -hex 16)

encrypted_command=$(echo -n "$COMMAND" | \
    openssl enc -aes-256-cbc -K "$aes_key" -iv "$aes_iv" 2>/dev/null | base64 -w 0)

aes_credentials="${aes_key}:${aes_iv}"
encrypted_aes=$(echo -n "$aes_credentials" | \
    openssl rsautl -sign -inkey "$PRIVATE_KEY_FILE" 2>/dev/null | base64 -w 0)

if [ -n "$encrypted_command" ] && [ -n "$encrypted_aes" ]; then
    encrypted_input="${encrypted_aes}:${encrypted_command}"
    log "[INPUT]: [OK] Comando cifrato"
else
    echo "[INPUT]: [X] ERRORE cifratura" >&2
    exit 1
fi

log "[INPUT]: Upload su Dropbox..."

response=$(echo -n "$encrypted_input" | curl -s -X POST https://content.dropboxapi.com/2/files/upload \
    --header "Authorization: Bearer $ACCESS_TOKEN" \
    --header "Dropbox-API-Arg: {\"path\":\"$INPUT_PATH\",\"mode\":\"overwrite\",\"autorename\":false}" \
    --header "Content-Type: application/octet-stream" \
    --data-binary @-)

if echo "$response" | grep -q "expired_access_token\|invalid_access_token"; then
    log "[TOKEN]: [!] Token non valido, refresh e retry..."
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

log "[INPUT]: [OK] File aggiornato"
