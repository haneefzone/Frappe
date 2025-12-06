#!/bin/bash
set -e

#############################################
# Frappe Only Auto Installer (Docker-friendly)
# For: ubuntu:resolute-20251130 container
#
# - Installs MariaDB, Redis, Node 18 (via nvm), yarn
# - Installs python3.13-venv, cron, nano
# - Configures timezone non-interactively
# - Creates user "frappe"
# - Installs bench & creates a Frappe-only site
# - Enables DNS multi-tenant (host-based)
# - Creates helper script to add more multi-tenant sites
#
# NOTE: wkhtmltopdf is NOT installed (PDF export will not work yet)
#############################################

if [[ $EUID -ne 0 ]]; then
  echo "Run this script as root inside the container."
  exit 1
fi

echo "=== Frappe Only Auto Installer (Docker, Multitenant) ==="

###########################################################
#  Timezone (non-interactive tzdata)
###########################################################

# Default timezone; override by running: TZ=Asia/Colombo ./install_frappe_multitenant.sh
TZ_DEFAULT="Asia/Dubai"

if [ -z "${TZ}" ]; then
  export TZ="${TZ_DEFAULT}"
fi

echo "Using timezone: ${TZ}"

export DEBIAN_FRONTEND=noninteractive

ln -snf "/usr/share/zoneinfo/${TZ}" /etc/localtime || true
echo "${TZ}" > /etc/timezone 2>/dev/null || true

###########################################################
#  Passwords & site names
###########################################################

SITENAME="frappe.localhost"

# Strong, fixed passwords (different for DB vs Frappe admin)
MYSQL_ROOT_PASSWORD="A7d9#KD82&kL!!ss"
FRAPPE_ADMIN_PASSWORD="N4#s92K!9s@Ld03"

echo "Using secure passwords:"
echo "  MariaDB root:       ${MYSQL_ROOT_PASSWORD}"
echo "  Frappe Administrator: ${FRAPPE_ADMIN_PASSWORD}"
echo

###########################################################
#  Base system packages
###########################################################

echo "Installing base packages ..."

apt-get update -y
apt-get install -y \
  git \
  python-is-python3 \
  python3-dev \
  python3-pip \
  python3.13-venv \
  redis-server \
  libmariadb-dev \
  mariadb-server \
  mariadb-client \
  pkg-config \
  xvfb \
  libfontconfig1 \
  curl \
  wget \
  sudo \
  jq \
  ca-certificates \
  fontconfig \
  nano \
  cron

echo
echo "⚠ wkhtmltopdf is NOT installed by this script."
echo "  You can still use Frappe; only PDF export will not work."
echo

###########################################################
#  Start Redis & MariaDB
###########################################################

echo "Starting Redis and MariaDB ..."

service redis-server start || true
service mariadb start || service mysql start || true
sleep 4

###########################################################
#  MariaDB charset & root password
###########################################################

echo "Configuring MariaDB charset ..."

mkdir -p /etc/mysql/conf.d

cat >/etc/mysql/conf.d/frappe.cnf <<'EOF'
[mysqld]
character-set-client-handshake = FALSE
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci

[mysql]
default-character-set = utf8mb4
EOF

service mariadb restart || true
sleep 4

echo "Setting MariaDB root password ..."

if ! mysql -u root <<EOF
ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}';
DELETE FROM mysql.user WHERE User='';
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
EOF
then
  echo "MariaDB root configuration failed. This should NOT happen on a fresh container."
  exit 1
fi

echo "MariaDB root secured."
echo

###########################################################
#  Create user frappe
###########################################################

if id "frappe" >/dev/null 2>&1; then
  echo "User 'frappe' already exists."
else
  echo "Creating user 'frappe' ..."
  adduser --disabled-password --gecos "" frappe
fi

usermod -aG sudo frappe

run_as_frappe() {
  su -s /bin/bash - frappe -c "$1"
}

###########################################################
#  Install nvm + Node 18 + yarn
###########################################################

echo "Installing nvm + Node 18 + yarn as user 'frappe' ..."

run_as_frappe '
  set -e
  export NVM_DIR="$HOME/.nvm"
  if [ ! -d "$NVM_DIR" ]; then
    curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash
  fi
  . "$HOME/.nvm/nvm.sh"
  nvm install 18
  nvm use 18
  npm install -g yarn
'

###########################################################
#  Install bench
###########################################################

echo "Installing bench (frappe-bench) ..."

run_as_frappe '
  set -e
  pip3 install --user frappe-bench --break-system-packages
'

###########################################################
#  Init bench & create default site (multitenant-ready)
###########################################################

echo "Initializing bench and creating default Frappe site ..."

run_as_frappe "
  set -e
  export NVM_DIR=\"\$HOME/.nvm\"
  . \"\$NVM_DIR/nvm.sh\"
  export PATH=\"\$HOME/.local/bin:\$PATH\"

  cd ~

  if [ -d frappe-bench ]; then
    echo 'Removing existing ~/frappe-bench to ensure clean init ...'
    rm -rf frappe-bench
  fi

  echo 'Running: bench init frappe-bench --frappe-branch version-15'
  bench init frappe-bench --frappe-branch version-15

  cd ~/frappe-bench

  echo 'Enabling DNS multi-tenant mode (host-based sites) ...'
  bench set-config -g dns_multitenant on

  echo 'Creating default Frappe site: ${SITENAME}'
  bench new-site ${SITENAME} \
    --mariadb-root-password \"${MYSQL_ROOT_PASSWORD}\" \
    --admin-password \"${FRAPPE_ADMIN_PASSWORD}\"
"

###########################################################
#  Create helper script for extra multitenant sites
###########################################################

cat >/create_frappe_site_multitenant.sh <<'EOS'
#!/bin/bash
set -e

# Auto-create a new Frappe site in DNS multitenant mode
# Usage inside container:
#   ./create_frappe_site_multitenant.sh mysite.localhost
#
# If no name is given, defaults to site1.localhost

SITENAME="${1:-site1.localhost}"

# This must match the MariaDB root password used in the main installer
DB_ROOT_PASSWORD="A7d9#KD82&kL!!ss"

# Generate a strong random Admin password for this site
apt-get update -y >/dev/null 2>&1 || true
apt-get install -y openssl >/dev/null 2>&1 || true
ADMIN_PASSWORD="$(openssl rand -hex 16)"

echo "=== Creating Frappe site in DNS multitenant mode ==="
echo "Site name:        ${SITENAME}"
echo

su - frappe -c "
  set -e
  cd ~/frappe-bench

  # Ensure DNS multitenant is ON (idempotent)
  bench set-config -g dns_multitenant on

  if [ -d sites/${SITENAME} ]; then
    echo 'Site ${SITENAME} already exists, skipping creation.'
  else
    bench new-site ${SITENAME} \
      --mariadb-root-password \"${DB_ROOT_PASSWORD}\" \
      --admin-password \"${ADMIN_PASSWORD}\"
  fi
"

echo
echo \"=======================================\"
echo \"Site created:\"
echo \"  Host / site name: ${SITENAME}\"
echo \"  Frappe Admin user: Administrator\"
echo \"  Frappe Admin password: ${ADMIN_PASSWORD}\"
echo
echo \"Remember to add this hostname on your HOST machine (e.g. Windows hosts file):\"
echo
echo \"  127.0.0.1   ${SITENAME}\"
echo
echo \"Then open:  http://${SITENAME}:8000\"
echo \"(All sites share the same port 8000 in multitenant mode.)\"
echo \"=======================================\"
EOS

chmod +x /create_frappe_site_multitenant.sh

###########################################################
#  Save summary for you
###########################################################

SUMMARY_FILE="/root/frappe_install_summary.txt"

cat >"${SUMMARY_FILE}" <<EOF
=== Frappe Installation Summary (Docker, Multitenant) ===

Default site:
  ${SITENAME}

MariaDB Root:
  User: root
  Password: ${MYSQL_ROOT_PASSWORD}

Frappe Administrator (default site):
  User: Administrator
  Password: ${FRAPPE_ADMIN_PASSWORD}

Bench Directory:
  /home/frappe/frappe-bench

Helper script for extra sites:
  /create_frappe_site_multitenant.sh

To add another site (inside this container):
  ./create_frappe_site_multitenant.sh site1.localhost

Start Frappe (inside this container):
  su - frappe
  cd ~/frappe-bench
  bench start

Access Web UI from host (because of -p HOSTPORT:8000):
  http://localhost:8000

NOTE:
  All sites (tenants) use the same port 8000.
  Multitenancy is based on HOSTNAMES, e.g.:
    frappe.localhost, site1.localhost, site2.localhost, ...

  wkhtmltopdf is NOT installed, so PDF export will not work
  until you manually install a compatible version.

EOF

chmod 600 "${SUMMARY_FILE}"

echo "======================================="
echo "Frappe Only installation COMPLETED inside container!"
echo
echo "Summary saved to: ${SUMMARY_FILE}"
echo
echo "DB root password:       ${MYSQL_ROOT_PASSWORD}"
echo "Frappe admin password:  ${FRAPPE_ADMIN_PASSWORD}"
echo "Default site:           ${SITENAME}"
echo
echo "Helper script for more sites:"
echo "  /create_frappe_site_multitenant.sh"
echo
echo "Next steps (inside this container):"
echo "  su - frappe"
echo "  cd ~/frappe-bench"
echo "  bench start"
echo
echo "Then open from host: http://localhost:8000"
echo "======================================="
