#!/bin/sh
set -u

LOG_DIR=/var/log
LOG_FILE="$LOG_DIR/provisioning.log"
APT_LOG="$LOG_DIR/apt-debug.log"
mkdir -p "$LOG_DIR"
touch "$LOG_FILE" "$APT_LOG"

exec >>"$LOG_FILE" 2>&1

export DEBIAN_FRONTEND=noninteractive
export DEBCONF_NOWARNINGS=yes

if command -v stdbuf >/dev/null 2>&1; then
    UNBUFFER="stdbuf -oL -eL"
else
    UNBUFFER=""
fi

log() {
    msg="[INFO] $(date '+%F %T') $*"
    printf '%s\n' "$msg"
    printf '%s\n' "$msg" >/dev/console 2>/dev/null || true
    sync
}

run_step() {
    desc=$1
    shift
    log "Starting: $desc"
    if [ -n "$UNBUFFER" ]; then
        cmd=$1
        if type "$cmd" >/dev/null 2>&1 && type "$cmd" 2>/dev/null | grep -q "function"; then
            "$@"
        else
            $UNBUFFER "$@"
        fi
    else
        "$@"
    fi
    rc=$?
    if [ "$rc" -ne 0 ]; then
        log "FAILED: $desc (exit $rc)"
        exit "$rc"
    fi
    log "Success: $desc"
    sync
}

apt_capture() {
    action=$1
    shift
    log "Running apt: $action"
    timeout 90 $UNBUFFER apt-get -o Debug::pkgAcquire::Worker=true "$@" 2>&1 | tee -a "$APT_LOG"
    rc=${PIPESTATUS:-${?}}
    log "apt finished: $action (exit $rc)"
    return "$rc"
}

cleanup_success() {
    log "Provisioning script finished"
}

trap cleanup_success EXIT

log "Provisioning started on $(hostname 2>/dev/null || echo unknown) using $(readlink /proc/$$/exe 2>/dev/null || echo "$0")"

log "Configuring DNS resolver"
cat <<'EOF' >/etc/resolv.conf
nameserver 169.254.169.254
nameserver 8.8.8.8
options single-request
options timeout:2
options attempts:2
EOF

if grep -q " /proc " /proc/mounts; then
    log "/proc already mounted"
else
    run_step "Mounting /proc" mount -t proc proc /proc
fi

if grep -q " /sys " /proc/mounts; then
    log "/sys already mounted"
else
    run_step "Mounting /sys" mount -t sysfs sys /sys
fi

if grep -q " /dev " /proc/mounts; then
    log "/dev already mounted"
else
    run_step "Mounting /dev" mount -t devtmpfs devtmpfs /dev
fi

log "Current mounts"
mount

if command -v nslookup >/dev/null 2>&1; then
    run_step "Testing DNS" $UNBUFFER nslookup archive.ubuntu.com
else
    log "Skipping DNS test: nslookup not available"
fi

if command -v ping >/dev/null 2>&1; then
    run_step "Testing ICMP" $UNBUFFER ping -c2 -W3 8.8.8.8
else
    log "Skipping ICMP test: ping not available"
fi

if command -v wget >/dev/null 2>&1; then
    run_step "Testing HTTP" $UNBUFFER wget --tries=1 -T5 -q -O- http://detectportal.firefox.com/success.txt
elif command -v curl >/dev/null 2>&1; then
    run_step "Testing HTTP" $UNBUFFER curl -fsSL --max-time 5 http://detectportal.firefox.com/success.txt
else
    log "Skipping HTTP test: neither wget nor curl available"
fi

log "Validating helper binaries"
for bin in /sbin/start-stop-daemon /usr/bin/pidof; do
    if [ ! -x "$bin" ]; then
        log "WARN: $bin missing"
    fi
done

run_step "Updating package lists" apt_capture update update -y
run_step "Upgrading base packages" apt_capture upgrade upgrade -y
run_step "Installing e2fsprogs" apt_capture install-e2fs install -y e2fsprogs

# fix: dpkg-statoverride: warning: --update given but /var/log/chrony does not exist
mkdir -p /var/log/chrony

log "Making configuration immutable"
chattr +i /etc/resolv.conf

# Install required packages if not already installed
PACKAGES="systemd systemd-sysv openssh-server sudo chrony linuxptp"
log "Checking presence of required packages: $PACKAGES"

MISSING_PACKAGES=""
for pkg in $PACKAGES; do
    if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed"; then
        log "Package $pkg is missing"
        MISSING_PACKAGES="$MISSING_PACKAGES $pkg"
    fi
done

if [ -n "$MISSING_PACKAGES" ]; then
    log "Missing packages detected:$(printf ' %s' $MISSING_PACKAGES)"
    run_step "Updating package lists (missing packages)" apt_capture update-missing update -y
    log "df -h before install"
    df -h
    # shellcheck disable=SC2086
    run_step "Installing missing packages" apt_capture install-missing install -y --no-install-recommends $MISSING_PACKAGES
else
    log "All required packages are already installed"
fi

log "Setting up shell"
echo "export SHELL='/bin/bash'" >/etc/profile.d/shell.sh
echo "export PS1='\w \$ '" >/etc/profile.d/prompt.sh
echo "export PS1='\w \$ '" >>"/etc/profile"
echo "export PS1='\w \$ '" >>"/root/.bashrc"

log "Configure .bashrc and .profile sourcing"
echo "if [ -f ~/.bashrc ]; then source ~/.bashrc; fi; if [ -f ~/.profile ]; then source ~/.profile; fi" >>/etc/profile

log "Remove root password"
passwd -d root

# Set up chrony.
setup_chrony(){
    log "Setting up chrony"
    mkdir -p /etc/chrony
    cat <<EOF >/etc/chrony/chrony.conf
refclock PHC /dev/ptp0 poll -1 dpoll -1 offset 0 trust prefer
makestep 1 -1
EOF

    # Add a proxy config, as some environments expects it there (e.g. timemaster in Node Dockerimage)
    echo "include /etc/chrony/chrony.conf" >/etc/chrony.conf

    mkdir -p /etc/systemd/system/chrony.service.d
    # The ExecStart= should be emptying the ExecStart= line in config.
    cat <<EOF >/etc/systemd/system/chrony.service.d/override.conf
[Service]
ExecStart=
ExecStart=/usr/sbin/chronyd
User=root
Group=root
EOF
}

setup_chrony

log "Configuring persistent journald"
mkdir -p /var/log/journal
mkdir -p /etc/systemd/journald.conf.d
cat <<'EOF' >/etc/systemd/journald.conf.d/persistent.conf
[Journal]
Storage=persistent
SystemMaxUse=16M
EOF

log "Setting up SSH"
mkdir -p /etc/ssh
cat <<EOF >>/etc/ssh/sshd_config
PermitRootLogin yes
PermitEmptyPasswords yes
PasswordAuthentication yes
EOF

configure_swap() {
    log "Configuring swap to ${1} MiB"
    mkdir /swap
    fallocate -l "${1}"M /swap/swapfile
    chmod 600 /swap/swapfile
    mkswap /swap/swapfile
}

configure_swap 128

log "Mask serial-getty@ttyS0.service"
# This is required when the Firecracker kernel args has specified console=ttyS0
systemctl mask serial-getty@ttyS0.service

log "Disable systemd-networkd-wait-online.service"
systemctl mask systemd-networkd-wait-online.service

# Clean machine-id from Docker
rm -rf /etc/machine-id

log "Linking systemd to init"
ln -sf /lib/systemd/systemd /usr/sbin/init

log "Unlocking immutable configuration"
chattr -i /etc/resolv.conf

log "df -h after install"
df -h

log "Finished provisioning script"

# Delete itself
rm -rf /etc/init.d/rcS
rm -rf /usr/local/bin/provision.sh

# Report successful provisioning
echo -n "0" > "{{ .ResultPath }}"