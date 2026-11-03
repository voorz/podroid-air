#!/bin/sh
set -eu
ROOTFS=/work/rootfs

# ── Post-debootstrap configuration for the Debian rootfs ──────────────────
# debootstrap already installed the base system + the --include packages;
# this script applies all Podroid-specific customization: passwords,
# services, configs, scripts, and the squashfs-ready file layout.

# ── File capabilities ────────────────────────────────────────────────────
# Ensure newuidmap/newgidmap have the correct security.capability xattr.
# dpkg usually sets these, but on overlay-mounted build hosts it can fail
# silently. setcap is available via libcap2-bin in the builder stage.
if command -v setcap >/dev/null 2>&1; then
    setcap cap_setuid+ep "$ROOTFS/usr/bin/newuidmap" 2>/dev/null || true
    setcap cap_setgid+ep "$ROOTFS/usr/bin/newgidmap" 2>/dev/null || true
fi

# ── sudo configuration ───────────────────────────────────────────────────
# members of the `sudo` group can become root after entering their password.
mkdir -p "$ROOTFS/etc/sudoers.d"
echo "%sudo ALL=(ALL) ALL" > "$ROOTFS/etc/sudoers.d/podroid"
chmod 0440 "$ROOTFS/etc/sudoers.d/podroid"

# ── Root password ────────────────────────────────────────────────────────
# Set root password to "root" (pre-hashed with openssl).
# We write the SHA-512 hash directly into /etc/shadow.
ROOT_HASH=$(openssl passwd -6 root)
sed -i "s|^root:[^:]*:|root:${ROOT_HASH}:|" "$ROOTFS/etc/shadow"

# ── Strip docs/man/locale to shrink squashfs ─────────────────────────────
rm -rf "$ROOTFS/usr/share/man" "$ROOTFS/usr/share/doc" \
       "$ROOTFS/usr/share/info" "$ROOTFS/usr/share/lintian"

# ── Pre-create podman storage dirs (saves first-boot mkdir) ──────────────
mkdir -p "$ROOTFS/var/lib/containers/storage" \
         "$ROOTFS/run/containers/storage" \
         "$ROOTFS/run/libpod" \
         "$ROOTFS/run/crun"

# ── Copy systemd unit files into the rootfs ──────────────────────────────
# These are the systemd service units for the Podroid guest services.
mkdir -p "$ROOTFS/etc/systemd/system"
cp /work/files/etc/systemd/system/podroid-bootstrap.service  "$ROOTFS/etc/systemd/system/"
cp /work/files/etc/systemd/system/podroid-network.service    "$ROOTFS/etc/systemd/system/"
cp /work/files/etc/systemd/system/podroid-resize.service     "$ROOTFS/etc/systemd/system/"
cp /work/files/etc/systemd/system/podroid-ready.service      "$ROOTFS/etc/systemd/system/"
cp /work/files/etc/systemd/system/podroid-x11.service        "$ROOTFS/etc/systemd/system/"
cp /work/files/etc/systemd/system/podroid-vsock.service      "$ROOTFS/etc/systemd/system/"
cp /work/files/etc/systemd/system/podroid-hostd.service      "$ROOTFS/etc/systemd/system/"
cp /work/files/etc/systemd/system/podroid-downloads.service  "$ROOTFS/etc/systemd/system/"
cp /work/files/etc/systemd/system/podroid-migrate.service    "$ROOTFS/etc/systemd/system/"

# ── Enable services via symlinks (no chroot needed) ──────────────────────
# systemd reads /etc/systemd/system/<target>.wants/<svc> symlinks.
mkdir -p "$ROOTFS/etc/systemd/system/multi-user.target.wants"
mkdir -p "$ROOTFS/etc/systemd/system/sysinit.target.wants"
for svc in podroid-migrate podroid-bootstrap podroid-network podroid-resize \
           podroid-x11 podroid-vsock podroid-downloads podroid-hostd \
           podroid-ready; do
    ln -sf "/etc/systemd/system/${svc}" \
        "$ROOTFS/etc/systemd/system/multi-user.target.wants/${svc}"
done

# Enable openssh-server (unit shipped at /lib/systemd/system/ssh.service)
ln -sf /lib/systemd/system/ssh.service \
    "$ROOTFS/etc/systemd/system/multi-user.target.wants/ssh.service"

# ── Disable services we don't need in the VM ─────────────────────────────
# These are either handled by initramfs or are noise in a VM.
for svc in apt-daily.timer apt-daily-upgrade.timer \
           systemd-timesyncd systemd-resolved; do
    rm -f "$ROOTFS/etc/systemd/system/multi-user.target.wants/${svc}" \
          "$ROOTFS/etc/systemd/system/timers.target.wants/${svc}" 2>/dev/null || true
done
# Mask hardware-specific services that fail in a VM
for svc in systemd-networkd-wait-online NetworkManager-wait-online; do
    ln -sf /dev/null "$ROOTFS/etc/systemd/system/${svc}.service" 2>/dev/null || true
done

# ── getty: enable auto-login on hvc0 ─────────────────────────────────────
# systemd uses logind + agetty; we override the serial-getty@hvc0 instance
# to use our podroid-login wrapper for terminal size restoration.
mkdir -p "$ROOTFS/etc/systemd/system/serial-getty@hvc0.service.d"
cat > "$ROOTFS/etc/systemd/system/serial-getty@hvc0.service.d/override.conf" <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty -o '-p -f -- \\u' --noclear --login-mode auto --autologin root hvc0 115200 xterm-256color
EOF
# Also enable ttyS0 for AVF fallback
mkdir -p "$ROOTFS/etc/systemd/system/serial-getty@ttyS0.service.d"
cat > "$ROOTFS/etc/systemd/system/serial-getty@ttyS0.service.d/override.conf" <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty -o '-p -f -- \\u' --noclear --login-mode auto --autologin root ttyS0 115200 xterm-256color
EOF
# Enable the serial-getty instances
ln -sf /lib/systemd/system/serial-getty@.service \
    "$ROOTFS/etc/systemd/system/getty.target.wants/serial-getty@hvc0.service"
ln -sf /lib/systemd/system/serial-getty@.service \
    "$ROOTFS/etc/systemd/system/getty.target.wants/serial-getty@ttyS0.service"
# Disable the default vt getty (no virtual terminal in the VM)
rm -f "$ROOTFS/etc/systemd/system/getty.target.wants/getty@tty1.service" 2>/dev/null || true

# ── Copy /usr/local/bin scripts ──────────────────────────────────────────
mkdir -p "$ROOTFS/usr/local/bin"
cp /work/files/usr/local/bin/podroid-resize "$ROOTFS/usr/local/bin/"
cp /work/files/usr/local/bin/podroid-login  "$ROOTFS/usr/local/bin/"
cp /work/files/usr/local/bin/podroid-backup "$ROOTFS/usr/local/bin/"
cp /work/files/usr/local/bin/podroid-docs   "$ROOTFS/usr/local/bin/"
# podroid-vsock-agent is COPY'd from the vsock-builder stage; ensure executable.
chmod +x "$ROOTFS/usr/local/bin/podroid-vsock-agent" 2>/dev/null || true
# podroid-hostd is also COPY'd from the vsock-builder stage.
chmod +x "$ROOTFS/usr/local/bin/podroid-hostd" 2>/dev/null || true
# podroid-overlay-normalize is COPY'd from the vsock-builder stage.
chmod +x "$ROOTFS/usr/local/bin/podroid-overlay-normalize" 2>/dev/null || true
# The hostd CLIs are argv[0]-dispatch symlinks onto the one multi-call binary.
ln -sf podroid-hostd "$ROOTFS/usr/local/bin/podroid-notify"
ln -sf podroid-hostd "$ROOTFS/usr/local/bin/podroid-forward"
ln -sf podroid-hostd "$ROOTFS/usr/local/bin/podroid-open"
ln -sf podroid-hostd "$ROOTFS/usr/local/bin/podroid-power"
ln -sf podroid-hostd "$ROOTFS/usr/local/bin/podroid-headless"
ln -sf podroid-hostd "$ROOTFS/usr/local/bin/podroid-server"
ln -sf podroid-hostd "$ROOTFS/usr/local/bin/podroid-phone-ip"
chmod +x "$ROOTFS/usr/local/bin/podroid-"*

# ── vsock agent's initial forward table ──────────────────────────────────
mkdir -p "$ROOTFS/etc/podroid"
cp /work/files/etc/podroid/forwards.conf "$ROOTFS/etc/podroid/forwards.conf"
chmod 0644 "$ROOTFS/etc/podroid/forwards.conf"

# ── Migration scripts ────────────────────────────────────────────────────
mkdir -p "$ROOTFS/etc/podroid/migrations"
cp /work/files/etc/podroid/migrations/README "$ROOTFS/etc/podroid/migrations/README"
for f in /work/files/etc/podroid/migrations/*.sh; do
    [ -f "$f" ] || continue
    cp "$f" "$ROOTFS/etc/podroid/migrations/"
    chmod 0755 "$ROOTFS/etc/podroid/migrations/$(basename "$f")"
done

# ── System-version stamp ─────────────────────────────────────────────────
# The migration anchor. Baked from the app versionCode at build time;
# compared against /mnt/persist/.podroid/applied-version at boot.
printf '%s\n' "${SYSTEM_VERSION:-0}" > "$ROOTFS/etc/podroid/system-version"
chmod 0644 "$ROOTFS/etc/podroid/system-version"

# ── /etc/profile.d/*.sh — sourced by Debian's /etc/profile in login shells ─
mkdir -p "$ROOTFS/etc/profile.d"
cp /work/files/etc/profile.d/podroid-color.sh "$ROOTFS/etc/profile.d/"
cp /work/files/etc/profile.d/podroid-x11.sh   "$ROOTFS/etc/profile.d/"
chmod 0644 "$ROOTFS/etc/profile.d/podroid-color.sh" "$ROOTFS/etc/profile.d/podroid-x11.sh"

# ── /etc/containers/storage.conf — pin Podman to the in-kernel overlay ───
mkdir -p "$ROOTFS/etc/containers"
cp /work/files/etc/containers/storage.conf "$ROOTFS/etc/containers/storage.conf"
chmod 0644 "$ROOTFS/etc/containers/storage.conf"

# ── Offline docs copy ────────────────────────────────────────────────────
mkdir -p "$ROOTFS/usr/share/doc/podroid"
cp /work/docs-guide/*.html /work/docs-guide/style.css "$ROOTFS/usr/share/doc/podroid/"
chmod 0644 "$ROOTFS/usr/share/doc/podroid/"*

# ── Hostname and hosts ───────────────────────────────────────────────────
echo "podroid" > "$ROOTFS/etc/hostname"
cat > "$ROOTFS/etc/hosts" <<'EOF'
127.0.0.1 localhost podroid
::1 localhost ip6-localhost
EOF

# ── Machine ID ───────────────────────────────────────────────────────────
# systemd needs /etc/machine-id to exist (even if empty, it will generate
# one at boot). Without it, systemd may fail to start certain services.
# debootstrap in Docker may skip the dbus postinst that normally creates this.
if [ ! -f "$ROOTFS/etc/machine-id" ] || [ ! -s "$ROOTFS/etc/machine-id" ]; then
    # Write a deterministic machine-id from /etc/hostname so it's stable across
    # builds but unique per device (systemd will regenerate on first boot if
    # this is empty — but an empty file in a read-only squashfs can't be written
    # to, so we pre-populate it).
    if command -v systemd-machine-id-setup >/dev/null 2>&1; then
        systemd-machine-id-setup --root="$ROOTFS" 2>/dev/null || true
    fi
    if [ ! -s "$ROOTFS/etc/machine-id" ]; then
        # Fall back: generate a random 32-char hex string (systemd format)
        printf '%s\n' "$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')" \
            > "$ROOTFS/etc/machine-id" 2>/dev/null || true
    fi
fi

# ── Default target ────────────────────────────────────────────────────────
# Ensure multi-user.target is the default boot target (not graphical.target).
ln -sf /lib/systemd/system/multi-user.target \
    "$ROOTFS/etc/systemd/system/default.target"

# ── Login banner ─────────────────────────────────────────────────────────
cat > "$ROOTFS/etc/issue" <<'EOF'
Welcome to Podroid (Debian 12 Bookworm)
Kernel \r on \m (\l)

  Default login:  root  /  root
  Change root password:    passwd
  Create a regular user:   adduser <name>
                           (add to sudo group for sudo access)

EOF

# ── fstab: minimal (initramfs handles the root mount) ────────────────────
cat > "$ROOTFS/etc/fstab" <<'EOF'
# Root filesystem is mounted by initramfs (overlayfs on squashfs + ext4).
# No entries needed here — persistent storage is bind-mounted by podroid-bootstrap.
EOF

# ── Clean apt cache ──────────────────────────────────────────────────────
rm -rf "$ROOTFS/var/cache/apt" "$ROOTFS/var/lib/apt/lists" \
       "$ROOTFS/var/cache/debconf"

# ── Remove systemd's default network config that conflicts with ours ─────
# podroid-network handles eth0 configuration; systemd-networkd must not race.
rm -f "$ROOTFS/etc/systemd/network/"*.network 2>/dev/null || true
