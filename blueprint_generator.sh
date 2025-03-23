#!/bin/bash -x

# Fonction pour installer des paquets avec gestion des erreurs
install_packages() {
  sudo dnf install -y --allowerasing --nobest "$@" || {
    echo "Erreur lors de l'installation des paquets : $@"
    return 1
  }
}

# Fonction de vérification des commandes
check_command() {
  if [ $? -ne 0 ]; then
    echo "Erreur : $1"
    exit 1
  fi
}

# Installation des paquets nécessaires, y compris ceux pour l'ISO live
install_packages python3 python3-toml epel-release osbuild-composer composer-cli cockpit cockpit-composer bash-completion dracut-live livecd-tools xorriso anaconda

# Activation des services nécessaires
sudo systemctl enable --now osbuild-composer.socket

# Nettoyage du cache et redémarrage du service
sudo rm -rf /var/cache/osbuild-composer/*
sudo systemctl restart osbuild-composer

# Nom du blueprint
BLUEPRINT_NAME="system_replica_$(date +%Y%m%d)"

# Fichier de sortie pour le blueprint
OUTPUT_FILE="${BLUEPRINT_NAME}.toml"

# Fonction pour obtenir la liste des packages installés (avec version)
get_installed_packages() {
  rpm -qa --qf "%{NAME} %{VERSION}-%{RELEASE}\n" | sort | uniq
}

# Fonction pour obtenir les services activés
get_enabled_services() {
  systemctl list-unit-files --state=enabled --type=service --no-legend | awk '{print $1}' | sed 's/.service$//'
}

# Fonction pour obtenir les utilisateurs locaux
get_local_users() {
  getent passwd | awk -F: '$3 >= 1000 && $3 != 65534 {print $1 ":" $3 ":" $4 ":" $6 ":" $7}'
}

# Fonction pour obtenir les groupes locaux
get_local_groups() {
  getent group | awk -F: '$3 >= 1000 && $3 != 65534 {print $1 ":" $3}'
}

# Fonction pour obtenir les informations sur le système de fichiers
get_filesystem_info() {
  lsblk -nfo NAME,SIZE,FSTYPE,MOUNTPOINT | awk '$3 != "" && $4 != "" && $4 != "/boot/efi" && $4 != "[SWAP]" {
    size_in_bytes = $2;
    if (size_in_bytes ~ /K$/) size_in_bytes = substr(size_in_bytes, 1, length(size_in_bytes)-1) * 1024;
    else if (size_in_bytes ~ /M$/) size_in_bytes = substr(size_in_bytes, 1, length(size_in_bytes)-1) * 1024 * 1024;
    else if (size_in_bytes ~ /G$/) size_in_bytes = substr(size_in_bytes, 1, length(size_in_bytes)-1) * 1024 * 1024 * 1024;
    print "[[customizations.filesystem]]";
    print "device = \"/dev/" $1 "\"";
    print "size = " size_in_bytes;
    print "fstype = \"" $3 "\"";
    print "mountpoint = \"" $4 "\"";
    print "";
  }'
}

# Création du blueprint initial
create_initial_blueprint() {
  cat << EOF > "$OUTPUT_FILE"
name = "${BLUEPRINT_NAME}"
description = "Blueprint généré automatiquement pour répliquer le système existant (ISO Live USB)"
version = "0.0.1"

[[modules]]
name = "org.fedoraproject.Anaconda"
config = {}

[[modules]]
name = "org.fedoraproject.LiveOS"
config = {variant = "default"}

[customizations]
hostname = "$(hostname)"

[customizations.timezone]
timezone = "$(timedatectl show --property=Timezone --value)"
ntpservers = ["0.pool.ntp.org", "1.pool.ntp.org", "2.pool.ntp.org"]

[customizations.locale]
languages = ["$(localectl status | grep "System Locale" | sed 's/^.*LANG=\([^ ]*\).*$/\1/')"]

[customizations.kernel]
append = "$(cat /proc/cmdline | sed 's/BOOT_IMAGE=[^ ]* //') rd.live.image quiet rhgb"

EOF

  # Ajout des informations sur le système de fichiers
  get_filesystem_info >> "$OUTPUT_FILE"

  # Ajout des packages installés
  echo "# Packages installed on the system" >> "$OUTPUT_FILE"
  get_installed_packages | while IFS=' ' read -r package version; do
    echo "[[packages]]" >> "$OUTPUT_FILE"
    echo "name = \"$package\"" >> "$OUTPUT_FILE"
    echo "version = \"=$version\"" >> "$OUTPUT_FILE" # Spécifie la version exacte
  done
}

# Fonction pour valider et corriger la syntaxe TOML avec python3
validate_toml_syntax() {
  local file="$1"
  if python3 -c "import toml; toml.load(open('$file'))" > /dev/null 2>&1; then
    echo "Syntaxe TOML valide dans $file"
    return 0
  else
    echo "Erreur de syntaxe TOML détectée dans $file"
    return 1
  fi
}

# Ajout des services activés, des utilisateurs et des groupes
add_customizations() {
  echo "[customizations.services]" >> "$OUTPUT_FILE"
  echo "enabled = [" >> "$OUTPUT_FILE"
  get_enabled_services | sed 's/^/ "/' | sed 's/$/",/' >> "$OUTPUT_FILE"
  echo "]" >> "$OUTPUT_FILE"

  # Ajout des utilisateurs
  get_local_users | while IFS=: read username uid gid home shell; do
    echo "[[customizations.user]]" >> "$OUTPUT_FILE"
    echo "name = \"$username\"" >> "$OUTPUT_FILE"
    echo "uid = $uid" >> "$OUTPUT_FILE"
    echo "gid = $gid" >> "$OUTPUT_FILE"
    echo "home = \"$home\"" >> "$OUTPUT_FILE"
    echo "shell = \"$shell\"" >> "$OUTPUT_FILE"
    # Ajout des groupes de l'utilisateur
    echo "groups = [" >> "$OUTPUT_FILE"
    groups $username | cut -d: -f2 | tr ' ' '\n' | sed 's/^/ "/' | sed 's/$/",/' >> "$OUTPUT_FILE"
    echo "]" >> "$OUTPUT_FILE"
  done

  # Ajout des groupes locaux
  get_local_groups | while IFS=: read groupname gid; do
    echo "[[customizations.group]]" >> "$OUTPUT_FILE"
    echo "name = \"$groupname\"" >> "$OUTPUT_FILE"
    echo "gid = $gid" >> "$OUTPUT_FILE"
  done
}

# Pousser le blueprint vers le serveur
composer-cli blueprints push "$OUTPUT_FILE"

# Tests de validation du blueprint
validate_blueprint() {
  echo "Validation du blueprint..."

  # Pousser le blueprint vers le serveur
  composer-cli blueprints push "$OUTPUT_FILE"
  
  # Attendre un court instant pour que le serveur traite le blueprint
  sleep 2

  # Vérifier que le blueprint existe
  composer-cli blueprints list | grep -q "$BLUEPRINT_NAME"
  check_command "Le blueprint $BLUEPRINT_NAME n'a pas été créé correctement"
  
  # Vérifier la syntaxe du blueprint
  echo "Vérification de la syntaxe TOML..."
  if ! validate_toml_syntax "$OUTPUT_FILE"; then
    echo "Erreur : Le blueprint $OUTPUT_FILE contient des erreurs de syntaxe TOML."
    return 1
  fi

  composer-cli blueprints show "$BLUEPRINT_NAME" > /dev/null 2>&1
  check_command "Le blueprint $BLUEPRINT_NAME contient des erreurs de syntaxe"

  echo "Le blueprint $BLUEPRINT_NAME a été validé avec succès."
  return 0
}

# Vérifier que le service cockpit est actif
configure_cockpit() {
  echo "Vérification du service cockpit..."
  sudo systemctl start cockpit
  sudo systemctl enable cockpit
  sudo systemctl status cockpit > /dev/null 2>&1
  if [ $? -ne 0 ]; then
    echo "Erreur : Le service cockpit n'a pas pu être démarré."
    exit 1
  fi

  # Ouvrir le port 9090 dans le pare-feu si nécessaire
  echo "Configuration du pare-feu..."
  sudo firewall-cmd --zone=public --add-port=9090/tcp --permanent > /dev/null 2>&1
  sudo firewall-cmd --reload > /dev/null 2>&1

  # Vérifier que le port est ouvert
  sudo firewall-cmd --list-ports | grep -q "9090/tcp"
  if [ $? -ne 0 ]; then
    echo "Erreur : Le port 9090 n'est pas ouvert dans le pare-feu."
    exit 1
  fi

  # Ouvrir l'interface web dans le navigateur par défaut
  echo "Ouverture de l'interface web dans le navigateur..."
  xdg-open http://localhost:9090/ > /dev/null 2>&1
  if [ $? -ne 0 ]; then
    echo "Erreur : Impossible d'ouvrir le navigateur."
    exit 1
  fi
  echo "Interface web ouverte avec succès à l'adresse http://localhost:9090/."
}

# ==================================================
# Exécution du script
# ==================================================

# 1. Créer le blueprint initial
create_initial_blueprint

# 2. Ajouter les personnalisations (services, utilisateurs, groupes)
add_customizations

# 3. Valider le blueprint
if validate_blueprint; then
  echo "Script terminé avec succès. Un blueprint fonctionnel a été créé."
else
  echo "Le blueprint n'est pas valide. Arrêt du script."
  exit 1
fi

# 4. Configurer et lancer Cockpit
configure_cockpit

echo "Script terminé."

