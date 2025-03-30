#!/bin/bash

# Création des répertoires nécessaires
mkdir -p /tmp/kickstart_files
mkdir -p /tmp/custom_files

# Génération du fichier kickstart
ksfile="/tmp/kickstart_files/ks.cfg"

# Copie de la configuration du système existant
cp /root/anaconda-ks.cfg $ksfile

# Ajout des packages installés
echo "%packages" >> $ksfile
rpm -qa --qf '%{NAME}\n' >> $ksfile
echo "%end" >> $ksfile

# Copie des fichiers de configuration essentiels
cp /etc/fstab /tmp/custom_files/
cp /etc/passwd /tmp/custom_files/
cp /etc/group /tmp/custom_files/
cp /etc/shadow /tmp/custom_files/
cp /root/.bashrc /tmp/custom_files/

# Ajout de la section %post pour copier les fichiers personnalisés
cat << EOF >> $ksfile

%post
# Copie des fichiers personnalisés
cp /run/install/repo/custom_files/* /mnt/sysimage/
%end
EOF

# Création de l'ISO personnalisée
iso_name="custom_rhel_$(date +%Y%m%d).iso"
mkksiso --ks $ksfile --add /tmp/custom_files /home/n0r3f/Téléchargements/rhel-9.5-x86_64-boot.iso $iso_name

echo "ISO personnalisée créée : $iso_name"

