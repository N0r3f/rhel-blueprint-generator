#!/bin/bash

# Création du répertoire pour le first boot script
mkdir -p /etc/systemd/system

# Création du first boot script
cat << EOF > /etc/systemd/system/firstboot.service
[Unit]
Description=First Boot Configuration
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/firstboot.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# Création du script firstboot.sh
cat << EOF > /usr/local/bin/firstboot.sh
#!/bin/bash

# Copie des fichiers de configuration essentiels
cp /etc/fstab /etc/fstab.new
cp /etc/passwd /etc/passwd.new
cp /etc/group /etc/group.new
cp /etc/shadow /etc/shadow.new
cp /root/.bashrc /root/.bashrc.new

# Configuration supplémentaire ici
# ...

# Désactivation du service après la première exécution
systemctl disable firstboot.service

EOF

# Rendre le script exécutable
chmod +x /usr/local/bin/firstboot.sh

# Activation du service firstboot
systemctl enable firstboot.service

echo "First boot script créé et activé."

