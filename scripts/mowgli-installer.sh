#!/bin/bash
[ -n "$BASH_VERSION" ] || { echo "❌ Lance avec bash: bash $0"; exit 1; }
# Vérification : ne pas exécuter ce script avec sudo
if [ "$EUID" -eq 0 ]; then
  echo "Ce script ne doit pas être exécuté avec sudo."
  echo "→ Lance-le avec : ./install-mowgli.sh"
  echo "   (Le script utilisera sudo uniquement quand c'est nécessaire)"
  exit 1
fi

set -e
set -o pipefail
trap 'echo "❌ Erreur à la ligne $LINENO. Abandon." >&2' ERR

# Affichage en-tête à chaque étape
HOSTNAME=$(hostname)
IP=$(hostname -I | awk '{print $1}')
IFACE=$(ip route | awk '/default/ {print $5; exit}')
MAC=$(ip link show "$IFACE" 2>/dev/null | awk '/ether/ {print $2}' || echo "n/a")
SSID=$(iwgetid -r 2>/dev/null || echo "non connecté")
UPTIME=$(uptime -p)
TEMP=$(vcgencmd measure_temp 2>/dev/null | cut -d= -f2 || echo "n/a")
LOAD=$(cat /proc/loadavg | awk '{print $1, $2, $3}')
MEM=$(free -m | awk '/Mem/ {printf "%d MiB / %d MiB", $3, $2}')
DISK=$(df -h / | awk 'END {print $4 " libres sur " $2}')
ROS_IP=$(grep -m1 '^ROS_IP=' "$HOME/mowgli-docker/.env" 2>/dev/null | cut -d= -f2- || true)
MOWER_IP=$(grep -m1 '^MOWER_IP=' "$HOME/mowgli-docker/.env" 2>/dev/null | cut -d= -f2- || true)
DOCKER_STATUS=$(command -v docker >/dev/null 2>&1 && docker ps -q 2>/dev/null | wc -l || echo "n/a")

clear

cat <<EOBANNER

    __  ___                    ___
   /  |/  /___ _      ______ _/ (_)
  / /|_/ / __ \ | /| / / __ \`/ / /
 / /  / / /_/ / |/ |/ / /_/ / / /
/_/  /_/\____/|__/|__/\__, /_/_/
                     /____/

Hostname     : $HOSTNAME
IP locale    : $IP
Adresse MAC  : $MAC
Wi-Fi (SSID) : $SSID
Uptime       : $UPTIME
Température  : $TEMP
Charge CPU   : $LOAD
RAM utilisée : $MEM
Disque libre : $DISK

Docker       : $DOCKER_STATUS conteneur(s) actif(s)
ROS_IP       : ${ROS_IP:-non défini}
MOWER_IP     : ${MOWER_IP:-non défini}
EOBANNER

command -v sudo >/dev/null 2>&1 || { echo "❌ sudo introuvable"; exit 1; }

CURRENT_CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"
CURRENT_PRETTY="$(. /etc/os-release && echo "$PRETTY_NAME")"

if grep -RhiqE 'trixie|testing|stable' /etc/apt/sources.list /etc/apt/sources.list.d/*.list 2>/dev/null; then
  echo "⚠️ Attention : des dépôts potentiellement non figés sur ${CURRENT_CODENAME} ont été détectés."
  echo "   Vérifie tes sources APT avant de faire un upgrade."
fi

if ! command -v curl >/dev/null 2>&1; then
  sudo apt update
  sudo apt install -y curl
fi

echo "=== Étape 1 : Mise à jour du système ==="
echo "Système détecté : $CURRENT_PRETTY"
echo

echo "→ Mise à jour de l'index des paquets"
sudo apt update || { echo "❌ apt update a échoué"; exit 1; }

echo
read -rp "Voulez-vous bloquer APT sur la release actuelle (${CURRENT_CODENAME}) pour éviter un passage vers une version suivante ? [o/N] " REP_PIN
case "$REP_PIN" in
  [oO]|[oO][uU][iI]|[yY]|[yY][eE][sS])
    sudo mkdir -p /etc/apt/apt.conf.d
    echo "APT::Default-Release \"${CURRENT_CODENAME}\";" | sudo tee /etc/apt/apt.conf.d/99defaultrelease >/dev/null
    echo "✅ Blocage APT activé sur : ${CURRENT_CODENAME}"
    ;;
  *)
    echo "⏭️ Aucun blocage de release ajouté."
    ;;
esac

echo
read -rp "Voulez-vous lancer apt upgrade -y maintenant ? [o/N] " REP_UPGRADE
case "$REP_UPGRADE" in
  [oO]|[oO][uU][iI]|[yY]|[yY][eE][sS])
    sudo apt upgrade -y || { echo "❌ apt upgrade a échoué"; exit 1; }
    ;;
  *)
    echo "⏭️ Upgrade ignoré."
    ;;
esac

clear

banner_gps() {
  clear
  cat <<'EOF'

   _______  ____   _____ 
  / ____/ |/ /  | / ___/
 / / __ |   / /| | \__ \ 
/ /_/ / /   / ___ |___/ / 
\____/_/|_/_/  |_|/____/  

EOF
  echo "=== Étape 3 : Configuration GPS (UDEV + symlink /dev/gps) ==="
  echo
  echo "⚠️  Important : branche ton GPS maintenant si possible (USB) ou vérifie le câblage (UART)."
  echo
}

banner_gps

### UART CONFIGURATION ###
echo "=== Étape 2 : Activation des UART 2/3/4/5 dans /boot/firmware/config.txt ==="
CONFIG_FILE="/boot/firmware/config.txt"
[ -f "$CONFIG_FILE" ] || CONFIG_FILE="/boot/config.txt"
[ -f "${CONFIG_FILE}.bak" ] || sudo cp "$CONFIG_FILE" "${CONFIG_FILE}.bak" 2>/dev/null || true
for uart in uart2 uart3 uart4 uart5; do
  if ! grep -q "dtoverlay=${uart}" "$CONFIG_FILE"; then
    echo "dtoverlay=${uart}" | sudo tee -a "$CONFIG_FILE" >/dev/null
  fi
done


### UDEV GPS CONFIG ###
echo "=== Étape 3 : Configuration des règles UDEV ==="
UDEV_FILE="/etc/udev/rules.d/50-mowgli.rules"
BASE_RULE='SUBSYSTEM=="tty", ATTRS{product}=="Mowgli", SYMLINK+="mowgli"'
sudo touch "$UDEV_FILE"
grep -Fxq "$BASE_RULE" "$UDEV_FILE" || echo "$BASE_RULE" | sudo tee -a "$UDEV_FILE" >/dev/null

read -p $'\nQuel type de GPS veux-tu configurer ?\n1) USB - simpleRTK2B (u-blox)\n2) USB - RTK1010Board (ESP32 USB CDC)\n3) USB - UM982 (CH340)\n4) UART - connecté sur ttyAMA4\nFais ton choix (1-4) : ' gps_choice

case $gps_choice in
  1)
    RULE='SUBSYSTEM=="tty", ATTRS{idVendor}=="1546", ATTRS{idProduct}=="01a9", SYMLINK+="gps"'
    ;;
  2)
    RULE='SUBSYSTEM=="tty", ATTRS{idVendor}=="303a", ATTRS{idProduct}=="4001", SYMLINK+="gps"'
    ;;
  3)
    RULE='SUBSYSTEM=="tty", ATTRS{idVendor}=="1a86", ATTRS{idProduct}=="7523", SYMLINK+="gps"'
    ;;
  4)
    RULE='KERNEL=="ttyAMA4", SYMLINK+="gps"'
    ;;
  *)
    RULE=""
    echo "Choix invalide. Aucun GPS configuré."
    ;;
esac

if [ ! -z "$RULE" ] && ! grep -Fxq "$RULE" "$UDEV_FILE"; then
  echo "$RULE" | sudo tee -a "$UDEV_FILE" >/dev/null
fi

sudo udevadm control --reload-rules && sudo udevadm trigger


### RC.LOCAL CONFIG ###
echo "→ Création de rc.local protégée (sauvegarde si existant personnalisé)"
RCLOCAL="/etc/rc.local"
if [ -f "$RCLOCAL" ] && ! grep -q "ttyAMA2" "$RCLOCAL"; then
  sudo cp "$RCLOCAL" "${RCLOCAL}.bak"
  echo "Sauvegarde de l'ancien rc.local → rc.local.bak"
fi
sudo tee "$RCLOCAL" > /dev/null <<'EOF'
#!/bin/bash
[ -e /dev/ttyAMA2 ] && stty -F /dev/ttyAMA2 115200 raw -echo -echoe -echok
[ -e /dev/ttyAMA3 ] && stty -F /dev/ttyAMA3 115200 raw -echo -echoe -echok
[ -e /dev/ttyAMA4 ] && stty -F /dev/ttyAMA4 460800 raw -echo -echoe -echok
[ -e /dev/ttyAMA5 ] && stty -F /dev/ttyAMA5 115200 raw -echo -echoe -echok
exit 0
EOF
sudo chmod +x "$RCLOCAL"
sudo tee /etc/systemd/system/rc-local.service > /dev/null <<'EOF'
[Unit]
Description=/etc/rc.local Compatibility
ConditionPathExists=/etc/rc.local
After=network.target

[Service]
Type=forking
ExecStart=/etc/rc.local
TimeoutSec=0
StandardOutput=tty
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now rc-local.service

banner_docker() {
  clear
  cat <<'EOF'

   ____             __           
  / __ \____  _____/ /_____  _____
 / / / / __ \/ ___/ //_/ _ \/ ___/
/ /_/ / /_/ / /__/ ,< /  __/ /    
\____/\____/\___/_/|_|\___/_/     

EOF
  echo "=== Installation Docker & Compose ==="
  echo
  echo "🐳 Préparation de l’environnement conteneurisé Mowgli"
  echo
}

banner_docker

### DOCKER INSTALLATION ###
echo "=== Vérification de Docker ==="

if command -v docker >/dev/null 2>&1; then
  echo "✅ Docker est déjà installé."
else
  echo "→ Docker non détecté. Installation en cours..."
  curl -fsSL https://get.docker.com | sudo sh
fi

# Vérifie que le service tourne
if ! systemctl is-active --quiet docker; then
  echo "→ Activation du service Docker..."
  sudo systemctl enable --now docker
fi

# Vérifie Docker Compose plugin
if docker compose version >/dev/null 2>&1; then
  echo "✅ Docker Compose plugin détecté."
else
  echo "→ Installation du plugin Docker Compose..."
  sudo apt install -y docker-compose-plugin || {
    echo "Plugin officiel non trouvé, installation manuelle..."
    mkdir -p ~/.docker/cli-plugins
    curl -SL https://github.com/docker/compose/releases/latest/download/docker-compose-linux-aarch64 \
      -o ~/.docker/cli-plugins/docker-compose
    chmod +x ~/.docker/cli-plugins/docker-compose
  }
fi


echo "=== Étape 5 : Ajout de l'utilisateur courant au groupe docker ==="
sudo systemctl enable --now docker
sudo usermod -aG docker $USER



banner_mowgli() {
  clear
  cat <<'EOF'

    __  ___                    ___
   /  |/  /___ _      ______ _/ (_)
  / /|_/ / __ \ | /| / / __ \`/ / / 
 / /  / / /_/ / |/ |/ / /_/ / / /  
/_/  /_/\____/|__/|__/\__, /_/_/   
                     /____/        

EOF
  echo "=== Étape 6 : Clonage ou mise à jour du dépôt mowgli-docker ==="
}

sudo apt install -y git
cd ~

echo "Choisis le dépôt à utiliser :"
echo "  1) Dépôt original (cedbossneo/mowgli-docker) — branche cedbossneo"
echo "  2) Dépôt MowgliFrenchTouch — branche Test"
echo "  3) Dépôt original (cedbossneo/mowgli-docker) — branche cedbossneo"
echo "  4) Dépôt personnalisé (URL + branche au choix)"
read -p "→ Ton choix (1/2/3/4) [1] : " repo_choice
repo_choice="${repo_choice:-1}"

case "$repo_choice" in
  1)
    GIT_REPO="https://github.com/cedbossneo/mowgli-docker"
    GIT_BRANCH="cedbossneo"
    ;;
  2)
    GIT_REPO="https://github.com/Mowglifrenchtouch/mowgli-docker"
    GIT_BRANCH="Test"
    ;;
  3)
    GIT_REPO="https://github.com/cedbossneo/mowgli-docker"
    GIT_BRANCH="v2"
    ;;
  4)
    read -p "→ Entre l'URL complète de ton dépôt Git : " GIT_REPO
    read -p "→ Entre la branche à utiliser (ex: main, master, dev, test) : " GIT_BRANCH
    if [[ -z "$GIT_REPO" || -z "$GIT_BRANCH" ]]; then
      echo "❌ URL ou branche vide. Abandon."
      exit 1
    fi
    ;;
  *)
    echo "❌ Choix invalide. Abandon."
    exit 1
    ;;
esac

echo "→ Repo : $GIT_REPO"
echo "→ Branche : $GIT_BRANCH"

if [ -d "$HOME/mowgli-docker/.git" ]; then
  echo "→ Le dossier mowgli-docker existe déjà, mise à jour..."
  cd "$HOME/mowgli-docker"

  # S'assure que l'origin pointe vers le bon dépôt
  git remote set-url origin "$GIT_REPO"

  # Récupère les branches/tags
  git fetch --all --prune

  # Checkout la branche demandée (et la crée si nécessaire)
  if git show-ref --verify --quiet "refs/heads/$GIT_BRANCH"; then
    git checkout "$GIT_BRANCH"
  else
    git checkout -b "$GIT_BRANCH" "origin/$GIT_BRANCH" 2>/dev/null || git checkout "$GIT_BRANCH"
  fi

  # Met à jour au dernier commit de la branche distante
  git pull --ff-only origin "$GIT_BRANCH" || git pull origin "$GIT_BRANCH"
else
  echo "→ Clonage du dépôt : $GIT_REPO"
  git clone --branch "$GIT_BRANCH" --single-branch "$GIT_REPO" mowgli-docker
  cd "$HOME/mowgli-docker"
fi



echo "=== Étape 7 : Création interactive du fichier .env avec sauvegarde ==="

# Sécurité : vérifier que le dossier mowgli-docker existe
if [ ! -d "$HOME/mowgli-docker" ]; then
  echo "❌ Dossier $HOME/mowgli-docker introuvable. Abandon."
  exit 1
fi

cd "$HOME/mowgli-docker" || exit 1

ENV_FILE=".env"
CURRENT_IP=$(hostname -I | awk '{print $1}')

read -p "Adresse IP actuelle détectée : $CURRENT_IP. Appuie sur Entrée pour l’utiliser ou entre une autre IP : " ROS_IP
ROS_IP=${ROS_IP:-$CURRENT_IP}

read -p "Adresse IP de la tondeuse (laisser vide si identique) : " MOWER_IP
MOWER_IP=${MOWER_IP:-$ROS_IP}

DEFAULT_IMAGE="ghcr.io/cedbossneo/mowgli-docker:cedbossneo"
FRENCHTOUCH_IMAGE="ghcr.io/mowglifrenchtouch/open_mower_jeremy:latest"

case "$repo_choice" in
  1) SUGGESTED_IMAGE="$DEFAULT_IMAGE" ;;
  2) SUGGESTED_IMAGE="$FRENCHTOUCH_IMAGE" ;;
  3) SUGGESTED_IMAGE="" ;;
esac

if [ -z "$SUGGESTED_IMAGE" ]; then
  # Dépôt personnalisé → image obligatoire
  while true; do
    read -p "→ Entre l'image Docker complète (ex: ghcr.io/utilisateur/mon-image:tag) : " IMAGE
    [ -n "$IMAGE" ] && break
    echo "❌ L'image ne peut pas être vide."
  done
else
  read -p "Image Docker à utiliser [${SUGGESTED_IMAGE}] : " IMAGE
  IMAGE=${IMAGE:-$SUGGESTED_IMAGE}
fi

TMPENV=$(mktemp)

cat <<EOF > "$TMPENV"
# Adresse IP de la machine exécutant le conteneur Docker
ROS_IP=$ROS_IP

# Adresse IP de la tondeuse
MOWER_IP=$MOWER_IP

# Image Docker à utiliser
IMAGE=$IMAGE

# Dépôt Git utilisé
GIT_REPO=$GIT_REPO
GIT_BRANCH=$GIT_BRANCH
EOF

if [ -f "$ENV_FILE" ] && ! cmp -s "$TMPENV" "$ENV_FILE"; then
  cp "$ENV_FILE" "${ENV_FILE}.bak"
  echo "→ Sauvegarde de l'ancien fichier .env → .env.bak"
fi

mv "$TMPENV" "$ENV_FILE"

echo "=== Fichier .env généré ==="
cat "$ENV_FILE"
echo "==========================="

banner_tools() {
  clear
  cat <<'EOF'

  ______            __     
 /_  __/___  ____  / /____ 
  / / / __ \/ __ \/ / ___/ 
 / / / /_/ / /_/ / (__  )  
/_/  \____/\____/_/____/   

EOF
  echo "=== Installation des outils système & debug ==="
  echo
  echo "🛠️  Préparation de l’environnement utilisateur"
  echo
}

banner_tools
### OUTILS DIVERS ###
echo "=== Étape 8 : Installation d'un gestionnaire Docker en ligne de commande ==="
    echo "1) Oui, installer lazydocker (recommandé)"
    echo "2) Oui, installer ctop (alternatif)"
    echo "3) Non"
    read -p "Ton choix (1-3) : " docker_cli
    docker_cli=${docker_cli:-3}

    case $docker_cli in
      1)
        echo "→ Installation de lazydocker..."
        curl https://raw.githubusercontent.com/jesseduffield/lazydocker/master/scripts/install_update_linux.sh | bash
        echo "→ Création de la commande simplifiée : dockermgr"
        sudo tee /usr/local/bin/dockermgr > /dev/null <<EOL
#!/bin/bash
exec lazydocker
EOL
        sudo chmod +x /usr/local/bin/dockermgr
        ;;
      2)
        echo "→ Installation de ctop..."
        sudo apt install -y ctop
        echo "→ Création de la commande simplifiée : dockermgr"
        sudo tee /usr/local/bin/dockermgr > /dev/null <<EOL
#!/bin/bash
exec ctop
EOL
        sudo chmod +x /usr/local/bin/dockermgr
        ;;
      3)
        echo "→ Aucun gestionnaire CLI Docker installé."
        ;;
      *)
        echo "Choix invalide. Aucun outil installé."
        ;;
    esac
 banner_tools
echo "=== Étape 9 : Installation d'un gestionnaire de fichiers en ligne de commande ==="
echo "1) Oui, installer Midnight Commander (mc)"
echo "2) Oui, installer ranger"
echo "3) Non"
read -p "Ton choix (1-3) : " fileman_choice
fileman_choice=${fileman_choice:-3}

case $fileman_choice in
1)
echo "→ Installation de Midnight Commander..."
sudo apt install -y mc
echo "→ Commande disponible : mc"
;;
2)
echo "→ Installation de ranger..."
sudo apt install -y ranger
echo "→ Commande disponible : ranger"
;;
3)
echo "→ Aucun gestionnaire de fichiers installé."
;;
*)
echo "Choix invalide. Aucun outil installé."
;;
esac

banner_tools

echo "=== Étape 10 : Installation d'outils pour le développement et le debug ==="
echo "Souhaites-tu installer des outils de développement et de debug ?"
echo "1) Tous les outils (recommandé)"
echo "2) Outils essentiels seulement"
echo "3) Aucun outil"
read -p "Ton choix (1-3) : " debug_tools
debug_tools=${debug_tools:-2}

case $debug_tools in
1)
echo "→ Installation de tous les outils :"
echo " - htop, ncdu, lsof, strace, gdb, minicom"
echo " - tmux, bat, fd-find, ripgrep"
echo " - nmap, iptraf-ng"
sudo apt install -y htop ncdu lsof strace gdb minicom \
                        tmux bat fd-find ripgrep \
                        nmap iptraf-ng
;;
2)
echo "→ Installation des outils essentiels :"
echo " - htop, ncdu, git, tmux, minicom"
sudo apt install -y htop ncdu git tmux minicom
;;
3)
echo "→ Aucun outil de debug/dev installé."
;;
*)
echo "Choix invalide. Aucun outil installé."
;;
esac

echo "→ Ajout du motd dynamique"
sudo tee /etc/profile.d/mowgli-motd.sh > /dev/null <<'EOF'
#!/bin/bash

# MOWGLI in orange (ANSI 256)
echo -e "\e[38;5;208m"
cat << "BANNER"
███╗   ███╗ ██████╗ ██╗    ██╗ ██████╗ ██╗     ██╗
████╗ ████║██╔═══██╗██║    ██║██╔════╝ ██║     ██║
██╔████╔██║██║   ██║██║ █╗ ██║██║  ███║██║     ██║
██║╚██╔╝██║██║   ██║██║███╗██║██║   ██║██║     ██║
██║ ╚═╝ ██║╚██████╔╝╚███╔███╔╝╚██████╔╝███████╗██║
╚═╝     ╚═╝ ╚═════╝  ╚══╝╚══╝  ╚═════╝ ╚══════╝╚═╝
BANNER

echo -e "\e[0m\n\e[1;37mFOR\e[0m"

# OpenMower in green
echo -e "\e[1;42m"
cat << "OM"
   ██████╗ ██████╗ ███████╗███╗   ██╗███╗   ███╗ ██████╗ ██╗    ██╗███████╗██████╗ 
  ██╔═══██╗███╔═██╗██╔════╝████╗  ██║████╗ ████║██╔═══██╗██║    ██║██╔════╝██╔══██╗
  ██║   ██║██████╔╝█████╗  ██╔██╗ ██║██╔████╔██║██║   ██║██║ █╗ ██║█████╗  ██████╔╝
  ██║   ██║██╔═══╝ ██╔══╝  ██║╚██╗██║██║╚██╔╝██║██║   ██║██║███╗██║██╔══╝  ██╔══██╗
  ╚██████╔╝██║     ███████╗██║ ╚████║██║ ╚═╝ ██║╚██████╔╝╚███╔███╔╝███████╗██║  ██║
   ╚═════╝ ╚═╝     ╚══════╝╚═╝  ╚═══╝╚═╝     ╚═╝ ╚═════╝  ╚══╝╚══╝ ╚══════╝╚═╝  ╚═╝
OM

echo -e "\e[0m"

# Infos système
HOSTNAME=$(hostname)
IP=$(hostname -I | awk '{print $1}')
IFACE=$(ip route | awk '/default/ {print $5; exit}')
MAC=$(ip link show "$IFACE" 2>/dev/null | awk '/ether/ {print $2}' || echo "n/a")
SSID=$(iwgetid -r 2>/dev/null || echo "non connecté")
UPTIME=$(uptime -p)
TEMP=$(vcgencmd measure_temp 2>/dev/null | cut -d= -f2 || echo "n/a")
LOAD=$(cat /proc/loadavg | awk '{print $1, $2, $3}')
MEM=$(free -m | awk '/Mem/ {printf "%d MiB / %d MiB", $3, $2}')
DISK=$(df -h / | awk 'END {print $4 " libres sur " $2}')
ROS_IP=$(grep ROS_IP ~/mowgli-docker/.env 2>/dev/null | cut -d= -f2)
MOWER_IP=$(grep MOWER_IP ~/mowgli-docker/.env 2>/dev/null | cut -d= -f2)
DOCKER_STATUS=$(command -v docker >/dev/null 2>&1 && docker ps -q 2>/dev/null | wc -l || echo "n/a")

echo "Hostname     : $HOSTNAME"
echo "IP locale    : $IP"
echo "Adresse MAC  : $MAC"
echo "Wi-Fi (SSID) : $SSID"
echo "Uptime       : $UPTIME"
echo "Température  : $TEMP"
echo "Charge CPU   : $LOAD"
echo "RAM utilisée : $MEM"
echo "Disque libre : $DISK"
echo ""
echo "Docker       : $DOCKER_STATUS conteneur(s) actif(s)"
echo "ROS_IP       : ${ROS_IP:-non défini}"
echo "MOWER_IP     : ${MOWER_IP:-non défini}"
EOF

clear

### DEPLOIEMENT ###
echo "=== Étape 11 : Choix du mode de déploiement Docker ==="
echo "1) Local : ROS et Mowgli sur la même machine (default)"
echo "2) ROS distant + ser2net"
echo "3) ROS distant (remote.pi)"
read -p "Choix (1-3) : " docker_mode
docker_mode=${docker_mode:-1}

case $docker_mode in
  1)
    sudo docker compose up -d
    ;;
  2)
    sudo docker compose -f docker-compose.ser2net.yaml up -d
    ;;
  3)
    sudo docker compose -f docker-compose.remote.pi.yaml up -d
    ;;
  *)
    echo "Choix invalide. Aucun conteneur lancé."
    ;;
esac


sudo chmod +x /etc/profile.d/mowgli-motd.sh
clear

echo
echo "============================================"
echo "✅ Installation terminée avec succès !"
echo "============================================"
echo

echo "→ Dossier: $HOME/mowgli-docker"
echo "→ Repo   : $GIT_REPO ($GIT_BRANCH)"
echo "→ Image  : $IMAGE"
echo "→ Web UI : http://$ROS_IP:4005"
echo

if [ -x /etc/profile.d/mowgli-motd.sh ]; then
  echo "=== Aperçu de l'environnement ==="
  echo
  /etc/profile.d/mowgli-motd.sh
fi

read -p $'\nRedémarrer maintenant ? (o/N) : ' reboot_now
[[ "$reboot_now" =~ ^[Oo]$ ]] && sudo reboot
