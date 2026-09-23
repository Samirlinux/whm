#!/bin/bash
###############################################################################
# WHM / cPanel Server Setup & Hardening Script
# - Disable WHM Terminal
# - Enable backups (Daily / Weekly / Monthly - 1 copy each)
# - Install & enable CSF (ConfigServer Security & Firewall)
# - Install all available PHP versions (EasyApache4) + common extensions
# - Disable dangerous PHP functions in EVERY installed PHP version
# - Run /scripts/securetmp
# - Append the custom security banner to /root/.bash_profile
#
# Run as root on a cPanel/WHM server:
#   bash whm_setup.sh
###############################################################################

set -uo pipefail
LOG="/root/whm_setup_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1

echo "=================================================================="
echo " WHM Setup Script - started $(date)"
echo " Log file: $LOG"
echo "=================================================================="

# ---------------------------------------------------------------------------
# 0) Sanity checks
# ---------------------------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
    echo "[ERROR] Must be run as root." >&2
    exit 1
fi

if [ ! -x /usr/local/cpanel/cpanel ] && [ ! -x /usr/sbin/whmapi1 ] && ! command -v whmapi1 >/dev/null 2>&1; then
    echo "[ERROR] This does not look like a cPanel/WHM server (whmapi1 not found)." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 1) Disable WHM Terminal
# ---------------------------------------------------------------------------
echo
echo "== [1/6] Disabling WHM Terminal =="
touch /var/cpanel/disable_whm_terminal_ui
echo "Done: /var/cpanel/disable_whm_terminal_ui created."

# ---------------------------------------------------------------------------
# 2) Enable Backups: Daily / Weekly / Monthly, 1 copy each
# ---------------------------------------------------------------------------
echo
echo "== [2/6] Configuring cPanel Backups =="
whmapi1 backup_config_set \
    backupenable=1 \
    backuptype=compressed \
    backupfiles=1 \
    backupmysql=1 \
    backupaccts=1 \
    backup_daily_enable=1 \
    backup_daily_retention=1 \
    backupdays="1,2,3,4,5,6,0" \
    backup_weekly_enable=1 \
    backup_weekly_day=6 \
    backup_weekly_retention=1 \
    backup_monthly_enable=1 \
    backup_monthly_dates=1 \
    backup_monthly_retention=1

echo "Backups configured: Daily/Weekly/Monthly enabled, retention = 1 copy each."
echo "NOTE: verify the backup destination/directory from WHM >> Backup Configuration"
echo "      (BACKUPDIR) - this script does not change the storage destination."

# ---------------------------------------------------------------------------
# 3) Install & enable CSF (ConfigServer Security & Firewall)
# ---------------------------------------------------------------------------
echo
echo "== [3/6] Installing CSF =="
if [ -d /etc/csf ]; then
    echo "CSF already installed, skipping install, will just re-enable it."
else
    cd /usr/src || exit 1
    rm -rf csf csf.tgz
    wget -q https://download.configserver.com/csf.tgz
    if [ ! -f csf.tgz ]; then
        echo "[ERROR] Failed to download csf.tgz - check network/firewall." >&2
    else
        tar -xzf csf.tgz
        cd csf || exit 1
        sh install.sh
    fi
fi

if [ -f /etc/csf/csf.conf ]; then
    # Turn off TESTING mode so the firewall actually enforces rules
    sed -i 's/^TESTING = "1"/TESTING = "0"/' /etc/csf/csf.conf
    # Make sure csf & lfd are enabled to start on boot and start now
    systemctl enable csf lfd 2>/dev/null
    systemctl restart lfd 2>/dev/null
    csf -r
    echo "CSF installed, TESTING mode disabled, csf/lfd enabled and restarted."
else
    echo "[WARN] CSF config not found - check the install log above."
fi

# ---------------------------------------------------------------------------
# 4) Install every available PHP version (EasyApache4) + common extensions
# ---------------------------------------------------------------------------
echo
echo "== [4/6] Installing all EasyApache4 PHP versions =="

PHP_VERSIONS=$(repoquery --repoid=EA4 --queryformat="%{name}" 2>/dev/null | grep -Eoh "ea-php[0-9]{2}" | sort -u)

if [ -z "$PHP_VERSIONS" ]; then
    echo "[WARN] Could not list PHP versions via repoquery, falling back to yum list."
    PHP_VERSIONS=$(yum list available 2>/dev/null | grep -Eoh "^ea-php[0-9]{2}\." | sed 's/\.$//' | sort -u)
fi

echo "PHP versions found: $PHP_VERSIONS"

EXT_LIST="php-cli php-common php-mysqlnd php-mbstring php-xml php-curl php-gd php-zip php-opcache php-intl php-soap php-bcmath php-imap php-fileinfo php-sockets php-pdo"

for ver in $PHP_VERSIONS; do
    echo "--- Installing $ver + extensions ---"
    pkgs="$ver"
    for ext in $EXT_LIST; do
        pkgs="$pkgs ${ver}-${ext}"
    done
    yum install -y $pkgs
done

# Register/activate installed versions with cPanel's MultiPHP system
/usr/local/cpanel/scripts/build_local_repo_conf 2>/dev/null
whmapi1 php_get_installable_versions >/dev/null 2>&1

echo "PHP installation step complete."

# ---------------------------------------------------------------------------
# 5) Disable dangerous PHP functions in EVERY installed PHP version
# ---------------------------------------------------------------------------
echo
echo "== [5/6] Disabling risky PHP functions in all installed versions =="

DISABLE_FUNCS="dl,exec,system,shell_exec,passthru,popen,proc_open,proc_close,proc_terminate,proc_nice,pcntl_exec,pcntl_fork,pcntl_signal,pcntl_waitpid,escapeshellcmd,escapeshellarg,posix_kill,posix_setuid,posix_setgid,posix_setsid,posix_setpgid,posix_mknod,posix_seteuid,posix_setegid,apache_child_terminate,apache_setenv,apache_note,ini_restore,define_syslog_variables,openlog,syslog,closelog,leak,listen,virtual,show_source"

for ini in /opt/cpanel/ea-php*/root/etc/php.ini; do
    [ -f "$ini" ] || continue
    echo "--- Updating $ini ---"
    cp -a "$ini" "${ini}.bak_$(date +%Y%m%d%H%M%S)"
    if grep -q '^disable_functions' "$ini"; then
        sed -i "s/^disable_functions.*/disable_functions = ${DISABLE_FUNCS}/" "$ini"
    else
        echo "disable_functions = ${DISABLE_FUNCS}" >> "$ini"
    fi
done

# Restart PHP-FPM / Apache so changes take effect
/usr/local/cpanel/scripts/restartsrv_apache_php_fpm 2>/dev/null
/usr/local/cpanel/scripts/restartsrv_httpd 2>/dev/null

echo "disable_functions applied to all php.ini files found under /opt/cpanel/."

# ---------------------------------------------------------------------------
# 6) Run /scripts/securetmp
# ---------------------------------------------------------------------------
echo
echo "== [6/6] Running /scripts/securetmp =="
if [ -x /scripts/securetmp ]; then
    /scripts/securetmp
else
    echo "[WARN] /scripts/securetmp not found or not executable."
fi

###############################################################################
# 7) Append custom banner/security code to /root/.bash_profile
###############################################################################
echo
echo "== Updating /root/.bash_profile =="

BASH_PROFILE="/root/.bash_profile"
if [ -f "$BASH_PROFILE" ]; then
    cp -a "$BASH_PROFILE" "${BASH_PROFILE}.bak_$(date +%Y%m%d%H%M%S)"
fi

if grep -q "GlobalIws.com Security Aria" "$BASH_PROFILE" 2>/dev/null; then
    echo "Banner already present in $BASH_PROFILE - skipping append."
else
cat >> "$BASH_PROFILE" << 'EOF'

# .bash_profile

# Get the aliases and functions
if [ -f ~/.bashrc ]; then
        . ~/.bashrc
fi

# User specific environment and startup programs

PATH=$PATH:$HOME/bin
export PATH

#############################################################################

 eval "`dircolors`"

 #############################################################################

 alias ls='ls $LS_OPTIONS'
 alias ll='ls $LS_OPTIONS -l'
 alias l='ls $LS_OPTIONS -lA'
 alias ..='cd ..'
 alias ...='cd ../..'
 alias s='ssh -l root'

 #############################################################################

 export EDITOR="nano"

export HISTFILESIZE=99999999
 export HISTSIZE=99999999
 export HISTCONTROL="ignoreboth"

 export LS_OPTIONS='--color=auto -h'

 #############################################################################

# trap  SIGINT
 function ask()
 {
# clear
 GREEN='\033[01;32m'
 DGREEN='\033[01;32m'
 DYELLOW='\033[01;33m'
 echo -e "$DYELLOW Welcome to GlobalIws.com Security Aria "
 echo "Have A Nice Day."
 echo "Please Be careful to use this server "
 echo -e "$DYELLOW SSH Access is Not Available for non- staff "
 echo -e "$GREEN Enter Security Key to Continue: "
 stty -echo
 read ans
 stty echo
 if [ ! "$ans" = "GlobalIws.comGIT" ] ; then
 exit
 else
 clear
 echo ""
 echo "========================================="
 echo "GlobalIWS Network 2027 $(cat /etc/redhat-release)"
 echo "========================================="
 echo ""
 echo "kernel : `uname -r`"
 echo "hostname  : `hostname`"
 echo "Server IP : `hostname -i`"
 echo ""
 fi
 }
 ask

 export PS1='\[\033[01;31m\]\u\[\033[01;33m\]@\[\033[01;36m\]\H \[\033[01;33m\]\w \[\033[01;35m\]GlobalIWS-2027# \[\033[00m\]'
 export HISTTIMEFORMAT="%h/%d - %H:%M:%S "

echo 'ALERT - Root Shell Access (server.globaliws.com) on:' `date` `who` | mail -s "Alert: Root Access from `who | cut -d"(" -f2 | cut -d")" -f1`" linux.system25@gmail.com
EOF
    echo "Banner appended to $BASH_PROFILE (backup saved)."
fi

echo
echo "=================================================================="
echo " Finished $(date)"
echo " Full log saved at: $LOG"
echo "=================================================================="
echo "Reminders:"
echo " - Review the CSF install output above; you may want to whitelist your own IP in /etc/csf/csf.allow before restarting csf again."
echo " - Verify backup destination (BACKUPDIR) in WHM >> Backup Configuration."
echo " - Confirm mail delivery to linux.system25@gmail.com works (mail/sendmail must be configured) for the root-login alert to fire."
