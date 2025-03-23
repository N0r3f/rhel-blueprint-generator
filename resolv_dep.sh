#!/bin/bash

# Fonction pour installer un paquet
install_package() {
    sudo dnf install -y "$1"
}

# Fonction pour activer un dépôt
enable_repo() {
    sudo dnf config-manager --set-enabled "$1"
}

# Fonction pour nettoyer le cache DNF
clean_cache() {
    sudo dnf clean all
}

# Fonction pour reconstruire le cache DNF
make_cache() {
    sudo dnf makecache
}

# Fonction pour mettre à jour le système
update_system() {
    sudo dnf update -y
}

# Fonction pour vérifier l'intégrité des paquets installés
verify_installed_packages() {
    echo "Vérification de l'intégrité des paquets installés..."
    rpm -Va | grep -v "^..5" || echo "Aucun problème détecté avec les paquets installés."
}

# Fonction pour vérifier les dépendances brisées et les paquets dupliqués
check_dnf_problems() {
    echo "Vérification des problèmes liés aux dépendances et aux paquets dupliqués..."
    sudo dnf check || echo "Aucun problème détecté avec les dépendances ou les paquets."
}

# Fonction pour vérifier la disponibilité des dépôts configurés
check_repos() {
    echo "Vérification de la disponibilité des dépôts configurés..."
    sudo dnf repolist all || echo "Problème avec certains dépôts configurés."
}

# Fonction pour vérifier les signatures GPG des paquets installés
verify_gpg_signatures() {
    echo "Vérification des signatures GPG des paquets installés..."
    for pkg in $(rpm -qa); do
        rpmkeys -K "$pkg" | grep -q "pgp" || echo "Problème de signature GPG détecté pour le paquet : $pkg"
    done
}

# Nettoyage et reconstruction du cache DNF si nécessaire
clean_and_rebuild_cache() {
    echo "Nettoyage et reconstruction du cache DNF..."
    clean_cache
    make_cache
}

# Récupérer la liste des erreurs de dépôts
repo_errors=$(sudo dnf repolist all 2>&1 | grep -E "Error:|Failed:")

# Traiter chaque erreur liée aux dépôts
while IFS= read -r error; do
    if [[ $error == *"Error: Failed to download metadata"* ]]; then
        repo=$(echo "$error" | grep -oP "for repository '\K[^']+")
        echo "Tentative d'activation du dépôt $repo"
        enable_repo "$repo"
    elif [[ $error == *"Failed to synchronize cache"* ]]; then
        echo "Nettoyage et reconstruction du cache DNF"
        clean_and_rebuild_cache
    fi
done <<< "$repo_errors"

# Vérifier l'intégrité des paquets installés
verify_installed_packages

# Vérifier les dépendances brisées et les paquets dupliqués
check_dnf_problems

# Vérifier la disponibilité des dépôts configurés
check_repos

# Vérifier les signatures GPG des paquets installés
verify_gpg_signatures

# Mettre à jour le système après avoir nettoyé et reconstruit le cache DNF
echo "Mise à jour du système..."
update_system

# Vérifier s'il reste des erreurs après la mise à jour et tenter de résoudre les problèmes restants
remaining_errors=$(sudo dnf repolist all 2>&1 | grep -E "Error:|Failed:")
if [ -n "$remaining_errors" ]; then
    echo "Des erreurs persistent. Tentative d'installation des paquets manquants..."
    while IFS= read -r error; do
        package=$(echo "$error" | grep -oP "package \K[^ ]+")
        if [ -n "$package" ]; then
            echo "Tentative d'installation du paquet $package"
            install_package "$package"
        fi
    done <<< "$remaining_errors"
fi

echo "Opérations terminées. Veuillez vérifier manuellement s'il reste des problèmes."

