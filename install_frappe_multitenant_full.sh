#!/bin/bash
set -e

#############################################
# Frappe Only Auto Installer (Docker-friendly)
# Tested for: ubuntu:resolute-20251130
#
# Features:
# - Non-interactive tzdata + timezone setup
# - Installs MariaDB + Redis + Node18 (nvm) + yarn + bench
# - Creates bench + default site
# - Enables DNS multitenant
# - Creates helper script to add more tenant sites
# - Adds MariaDB+Redis autostart in /root/.bashrc
# - Creates /start_container.sh to start DB+Redis+Bench
# - Optionally triggers /start_container.sh from /root/.bashrc
#
# NOTE: wkhtmltopdf is NOT installed (PDF export won't work)
#############################################

if [[ $EUID -ne 0 ]]; then
  echo "Run this script as root inside the container."
  exit 1
fi

echo "=== Frappe Only Auto Installer (Full, Multitenant) ==="

###########################################################
#  Timezone (non-interactive tzdata) with auto-detection
###########################################################

TZ_DEFAULT="Asia/Dubai"

detect_tz() {
  if [ -n "$TZ" ]; then
    echo "$TZ"; return
  fi
  if [ -f /etc/timezone ]; then
    cat /etc/timezone; return
  fi
  if [ -L /etc/localtime ]; then
    realpath /etc/localtime | sed 's|^/usr/share/zoneinfo/||'; return
  fi
  echo "$TZ_DEFAULT"
}

TZ_VALUE="$(detect_tz)"
export TZ="$TZ_VALUE"
export DEBIAN_FRONTEND=noninteractive

echo "Using timezone: ${TZ}"
ln -snf "/usr/share/zoneinfo/${TZ}" /etc/localtime || true
echo "${TZ}" > /etc/timezone 2>/dev/null || true

###########################################################
#  Passwords & site names
###########################################################

SITENAME="frappe.localhost"

# Strong fixed passwords (different for DB vs Frappe admin)
# You can change them if you want.
MYSQL_ROOT_PASSWORD="A7d9#KD82&kL!!ss"
FRAPPE_ADMIN_PASSWORD="N4#s92K!9s@Ld03"

echo "Using secure passwords:"
echo "  MariaDB root:         ${MYSQL_ROOT_PASSWORD}"
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
  cron \
  openssl

echo
echo "⚠ wkhtmltopdf is NOT installed by this script."
echo "  You can still use Frappe; only PDF export will not work."
echo

###########################################################
#  Start Redis & MariaDB (container mode)
###########################################################

echo "Starting Redis and MariaDB ..."
service redis-server start >/dev/null 2>&1 || true
service mariadb start >/dev/null 2>&1 || service mysql start >/dev/null 2>&1 || true
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

service mariadb restart >/dev/null 2>&1 || true
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
  echo "MariaDB root configuration failed. Use a fresh container and run once."
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
#  Init bench & create default site (DNS multitenant ON)
###########################################################

echo "Initializing bench and creating default Frappe site ..."

run_as_frappe "
  set -e
  export NVM_DIR=\"\$HOME/.nvm\"
  . \"\$NVM_DIR/nvm.sh\"
  export PATH=\"\$HOME/.local/bin:\$PATH\"

  cd ~

  # Clean init (dev containers)
  if [ -d frappe-bench ]; then
    echo 'Removing existing ~/frappe-bench to ensure clean init ...'
    rm -rf frappe-bench
  fi

  bench init frappe-bench --frappe-branch version-15

  cd ~/frappe-bench

  bench set-config -g dns_multitenant on

  bench new-site ${SITENAME} \
    --mariadb-root-password \"${MYSQL_ROOT_PASSWORD}\" \
    --admin-password \"${FRAPPE_ADMIN_PASSWORD}\"
"

###########################################################
#  Helper script: create additional multitenant sites
###########################################################

cat >/create_frappe_site_multitenant.sh <<'EOS'
#!/bin/bash
set -e

# Create a new Frappe tenant site (DNS multitenant mode)
# Usage:
#   /create_frappe_site_multitenant.sh site1.localhost

SITENAME="${1:-site1.localhost}"
DB_ROOT_PASSWORD="A7d9#KD82&kL!!ss"

apt-get update -y >/dev/null 2>&1 || true
apt-get install -y openssl >/dev/null 2>&1 || true
ADMIN_PASSWORD="$(openssl rand -hex 16)"

su - frappe -c "
  set -e
  cd ~/frappe-bench
  export PATH=\"\$HOME/.local/bin:\$PATH\"
  bench set-config -g dns_multitenant on

  if [ -d sites/${SITENAME} ]; then
    echo 'Site ${SITENAME} already exists.'
  else
    bench new-site ${SITENAME} \
      --mariadb-root-password \"${DB_ROOT_PASSWORD}\" \
      --admin-password \"${ADMIN_PASSWORD}\"
  fi
"

echo
echo \"Tenant created:\"
echo \"  Site/Host: ${SITENAME}\"
echo \"  Login: Administrator\"
echo \"  Password: ${ADMIN_PASSWORD}\"
echo
echo \"Add this to Windows hosts file:\"
echo \"  127.0.0.1   ${SITENAME}\"
echo \"Then open: http://${SITENAME}:8000\"
EOS

chmod +x /create_frappe_site_multitenant.sh

###########################################################
#  Start script: start DB + Redis + bench (as frappe)
###########################################################

cat >/start_container.sh <<'EOF'
#!/bin/bash
set -e

# Start services silently
service mariadb start >/dev/null 2>&1 || service mysql start >/dev/null 2>&1 || true
service redis-server start >/dev/null 2>&1 || true

# Start bench only if not already running
if ! pgrep -f "bench serve" >/dev/null 2>&1; then
  su - frappe -c "cd ~/frappe-bench && export PATH=\$HOME/.local/bin:\$PATH && bench start"
else
  echo "Bench already running."
fi
EOF

chmod +x /start_container.sh

###########################################################
#  Auto-start MariaDB + Redis (and optionally bench) when root opens shell
###########################################################

BASHRC="/root/.bashrc"

ROOT_AUTOSTART=$(cat <<'EOF'
# Auto-start MariaDB and Redis for Frappe
service mariadb start >/dev/null 2>&1 || service mysql start >/dev/null 2>&1
service redis-server start >/dev/null 2>&1

# Optional: also start bench automatically when you open a shell
# (bench must run as frappe user; this calls /start_container.sh)
if [ -x /start_container.sh ]; then
  /start_container.sh >/dev/null 2>&1 || true
fi
EOF
)

if grep -q "Auto-start MariaDB and Redis for Frappe" "$BASHRC"; then
  echo "Root autostart already configured in /root/.bashrc"
else
  echo "" >> "$BASHRC"
  echo "$ROOT_AUTOSTART" >> "$BASHRC"
  echo "Added autostart to /root/.bashrc"
fi

###########################################################
#  Save summary
###########################################################

SUMMARY_FILE="/root/frappe_install_summary.txt"

cat >"${SUMMARY_FILE}" <<EOF
=== Frappe Installation Summary (Docker, Multitenant) ===

Timezone:
  ${TZ}

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

Helper script (new tenant sites):
  /create_frappe_site_multitenant.sh

Start everything (after container restart):
  /start_container.sh

Access:
  Add to Windows hosts:
    127.0.0.1  frappe.localhost
  Open:
    http://frappe.localhost:8000

NOTE:
  wkhtmltopdf is NOT installed (PDF export disabled).

EOF

chmod 600 "${SUMMARY_FILE}"

echo
echo "======================================="
echo "✅ Installation completed!"
echo "Summary: ${SUMMARY_FILE}"
echo
echo "After container restart, run:"
echo "  /start_container.sh"
echo
echo "Start bench manually (optional):"
echo "  su - frappe"
echo "  cd ~/frappe-bench"
echo "  bench start"
echo "======================================="
