#!/bin/bash

sudo dnf clean all
sudo dnf update
sudo dnf install epel-release osbuild-composer composer-cli cockpit cockpit-composer bash-completion
sudo usermod -a -G weldr $USER && newgrp weldr
sudo systemctl enable --now osbuild-composer.socket
sudo rm -rf /var/cache/osbuild-composer/*
sudo systemctl restart osbuild-composer

# Nom du blueprint
BLUEPRINT_NAME="system_replica_$(date +%Y%m%d)"

# Fichier de sortie pour le blueprint
OUTPUT_FILE="${BLUEPRINT_NAME}.toml"

# Fonction pour obtenir la liste des packages installés
get_installed_packages() {
    rpm -qa --qf "%{NAME}\n" | sort | uniq
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

# Création du blueprint
cat << EOF > "$OUTPUT_FILE"
name = "${BLUEPRINT_NAME}"
description = "Blueprint généré automatiquement pour répliquer le système existant"
version = "0.0.1"

[customizations]
hostname = "$(hostname)"

[customizations.timezone]
timezone = "$(timedatectl show --property=Timezone --value)"
ntpservers = ["0.pool.ntp.org", "1.pool.ntp.org", "2.pool.ntp.org"]

[customizations.locale]
languages = ["$(localectl status | grep "System Locale" | sed 's/^.*LANG=\([^ ]*\).*$/\1/')"]

[customizations.kernel]
append = "$(cat /proc/cmdline | sed 's/BOOT_IMAGE=[^ ]* //')"

EOF

# Ajout des informations sur le système de fichiers
get_filesystem_info >> "$OUTPUT_FILE"

# Ajout des packages installés
echo "# Packages installed on the system" >> "$OUTPUT_FILE"
get_installed_packages | while read package; do
    echo "[[packages]]" >> "$OUTPUT_FILE"
    echo "name = \"$package\"" >> "$OUTPUT_FILE"
done

# Ajout des services activés
echo "[customizations.services]" >> "$OUTPUT_FILE"
echo "enabled = [" >> "$OUTPUT_FILE"
get_enabled_services | sed 's/^/    "/' | sed 's/$/",/' >> "$OUTPUT_FILE"
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
    groups $username | cut -d: -f2 | tr ' ' '\n' | sed 's/^/    "/' | sed 's/$/",/' >> "$OUTPUT_FILE"
    echo "]" >> "$OUTPUT_FILE"
done

# Ajout des groupes locaux
get_local_groups | while IFS=: read groupname gid; do
    echo "[[customizations.group]]" >> "$OUTPUT_FILE"
    echo "name = \"$groupname\"" >> "$OUTPUT_FILE"
    echo "gid = $gid" >> "$OUTPUT_FILE"
done

# Utilisation de composer-cli pour créer le blueprint
composer-cli blueprints push "$OUTPUT_FILE"

echo "Blueprint créé et poussé vers Image Builder : $BLUEPRINT_NAME"

# Fonction pour vérifier si une commande s'est exécutée avec succès
check_command() {
    if [ $? -ne 0 ]; then
        echo "Erreur : $1"
        exit 1
    fi
}

# Tests de validation du blueprint
echo "Validation du blueprint..."

# Vérifier que le blueprint existe
composer-cli blueprints list | grep -q "$BLUEPRINT_NAME"
check_command "Le blueprint $BLUEPRINT_NAME n'a pas été créé correctement"

# Vérifier la syntaxe du blueprint
composer-cli blueprints show "$BLUEPRINT_NAME" > /dev/null 2>&1
check_command "Le blueprint $BLUEPRINT_NAME contient des erreurs de syntaxe"

# Vérifier la résolution des dépendances
composer-cli blueprints depsolve "$BLUEPRINT_NAME" > /dev/null 2>&1
check_command "Le blueprint $BLUEPRINT_NAME a des problèmes de dépendances"

# Vérifier que le blueprint contient des paquets
PACKAGE_COUNT=$(composer-cli blueprints show "$BLUEPRINT_NAME" | grep -c '^\[\[packages\]\]')
if [ "$PACKAGE_COUNT" -eq 0 ]; then
    echo "Erreur : Aucun paquet n'a été ajouté au blueprint"
    exit 1
fi

# Vérifier que le blueprint contient des informations de système de fichiers
FS_COUNT=$(composer-cli blueprints show "$BLUEPRINT_NAME" | grep -c '^\[\[customizations.filesystem\]\]')
if [ "$FS_COUNT" -eq 0 ]; then
    echo "Erreur : Aucune information de système de fichiers n'a été ajoutée au blueprint"
    exit 1
fi

# Vérifier que le blueprint contient des utilisateurs
USER_COUNT=$(composer-cli blueprints show "$BLUEPRINT_NAME" | grep -c '^\[\[customizations.user\]\]')
if [ "$USER_COUNT" -eq 0 ]; then
    echo "Erreur : Aucun utilisateur n'a été ajouté au blueprint"
    exit 1
fi

# Vérifier que le blueprint contient des groupes
GROUP_COUNT=$(composer-cli blueprints show "$BLUEPRINT_NAME" | grep -c '^\[\[customizations.group\]\]')
if [ "$GROUP_COUNT" -eq 0 ]; then
    echo "Erreur : Aucun groupe n'a été ajouté au blueprint"
    exit 1
fi

# Vérifier que le blueprint peut être utilisé pour créer une image ISO
composer-cli compose types | grep -q "^iso$"
check_command "Le type d'image 'iso' n'est pas disponible"

composer-cli compose start "$BLUEPRINT_NAME" iso
check_command "Impossible de démarrer la composition de l'image ISO"

echo "Le blueprint $BLUEPRINT_NAME a été validé avec succès et peut être utilisé pour créer une image ISO."

# Vérifier que le service cockpit est actif
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
xdg-open http://localhost:9090/composer > /dev/null 2>&1

if [ $? -ne 0 ]; then
    echo "Erreur : Impossible d'ouvrir le navigateur."
    exit 1
fi

echo "Interface web ouverte avec succès à l'adresse http://localhost:9090/composer."

