#!/usr/bin/env bash
set -euo pipefail

# ── Configuration ──────────────────────────────────────────
MEDIA_BASE="/media/ubuntu"
DRIVE_UUID="ABCD-1234" # ← Your drive's UUID
DRIVE_MOUNT="${MEDIA_BASE}/${DRIVE_UUID}"

WHISPER_CACHE="${HOME}/.cache/whisper"
MEDIA_INBOUND="${HOME}/.openclaw/media/inbound"
LLAMA_CPP="${HOME}/llama.cpp/models"
LXC_ROOT="/var/lib/lxc"
BASHRC_FILE="${HOME}/.bashrc"

# Offload target dirs on the big drive
OFFLOAD_WHISPER="${DRIVE_MOUNT}/whisper-cache"
OFFLOAD_MEDIA="${DRIVE_MOUNT}/openclaw-media-inbound"
OFFLOAD_LLAMA="${DRIVE_MOUNT}/llama.cpp/models"
OFFLOAD_LXC="${DRIVE_MOUNT}/lxc"
OFFLOAD_TMP="${DRIVE_MOUNT}/tmp"

# ── Helper: Find device by UUID ────────────────────────────────
find_device_by_uuid() {
local target_uuid="$1"
blkid | grep "UUID=\"${target_uuid}\"" | awk -F: '{print $1}' | head -1
}

# ── Safety checks ──────────────────────────────────────────
# Check if already mounted elsewhere

if mountpoint -q "${DRIVE_MOUNT}"; then
echo "Already mounted at ${DRIVE_MOUNT}"
elif grep -q "${DRIVE_UUID}" /etc/fstab; then
echo "UUID ${DRIVE_UUID} found in fstab - will mount automatically"
else
# Try to find and mount the device
DEVICE=$(find_device_by_uuid "${DRIVE_UUID}")
if [[ -z "${DEVICE}" ]]; then
echo "ERROR: Could not find device with UUID ${DRIVE_UUID}"
echo "Run 'blkid' to find your drive UUID"
exit 1
fi
echo "Found device: ${DEVICE}"

# Mount it
sudo mkdir -p "${DRIVE_MOUNT}"
sudo mount -o nofail "${DEVICE}" "${DRIVE_MOUNT}"
echo "Mounted ${DEVICE} at ${DRIVE_MOUNT}"
fi
# Check filesystem
fs_type=$(lsblk -no FSTYPE "$(find_device_by_uuid "${DRIVE_UUID}")" 2>/dev/null || echo "unknown")
if [[ "${fs_type}" == "vfat" ]]; then
echo "WARNING: FAT filesystem detected. No file permissions, 4GB file limit!"
fi

echo ""
echo "Using big drive: ${DRIVE_MOUNT} (${fs_type})"
echo ""

# ── Step 1: Get actual UUID ─────────────────────────────────
ACTUAL_UUID=$(lsblk -no UUID "${DRIVE_MOUNT}" 2>/dev/null || echo "${DRIVE_UUID}")
LABEL=$(lsblk -no LABEL "${DRIVE_MOUNT}" 2>/dev/null || echo "(none)")
echo "Drive UUID: ${ACTUAL_UUID}"
echo "Drive label: ${LABEL}"
echo ""

# ── Step 2: Create directory structure ─────────────────────
echo "=== Step 2: Creating directories on big drive ==="
mkdir -p "${OFFLOAD_WHISPER}"
mkdir -p "${OFFLOAD_MEDIA}"
mkdir -p "${OFFLOAD_LLAMA}"
mkdir -p "${OFFLOAD_LXC}"
mkdir -p "${OFFLOAD_TMP}"
echo " ${OFFLOAD_WHISPER}"
echo " ${OFFLOAD_MEDIA}"
echo " ${OFFLOAD_LLAMA}"
echo " ${OFFLOAD_LXC}"
echo " ${OFFLOAD_TMP}"
echo ""

# ── Step 3: Move Whisper model cache ────────────────────────
echo "=== Step 3: Moving Whisper model cache ==="
if mountpoint -q "${WHISPER_CACHE}"; then
echo "  ${WHISPER_CACHE} already bind-mounted — skipping copy"
elif [[ -d "${WHISPER_CACHE}" ]] && compgen -G "${WHISPER_CACHE}/*" > /dev/null 2>&1; then
cp -a "${WHISPER_CACHE}"/* "${OFFLOAD_WHISPER}/"
echo " Copied to ${OFFLOAD_WHISPER}"

# Verify copy BEFORE deleting
orig_count=$(find "${WHISPER_CACHE}" -maxdepth 1 -type f | wc -l)
copy_count=$(find "${OFFLOAD_WHISPER}" -maxdepth 1 -type f | wc -l)
if [[ "${orig_count}" -eq "${copy_count}" ]] && [[ "${orig_count}" -gt 0 ]]; then
rm -f "${WHISPER_CACHE}"/*.pt
echo " Verified ✓ Removed originals from ${WHISPER_CACHE}"
else
echo "ERROR: Copy verification failed!"
exit 1
fi
else
echo " Whisper cache is empty or missing — skipping copy"
fi

# Bind mount with rollback guard
if mountpoint -q "${WHISPER_CACHE}"; then
echo " ${WHISPER_CACHE} already bind-mounted"
else
if ! sudo mount --bind "${OFFLOAD_WHISPER}" "${WHISPER_CACHE}"; then
echo "ERROR: Bind mount failed! Restoring originals..."
cp -a "${OFFLOAD_WHISPER}"/* "${WHISPER_CACHE}/"
exit 1
fi
echo "  Bind-mounted ${OFFLOAD_WHISPER} → ${WHISPER_CACHE}"
fi
ls -la "${WHISPER_CACHE}/"
echo ""

# ── Step 4: Move OpenClaw inbound media ───────────────────
echo "=== Step 4: Moving OpenClaw inbound media ==="
if mountpoint -q "${MEDIA_INBOUND}"; then
echo "  ${MEDIA_INBOUND} already bind-mounted — skipping copy"
elif compgen -G "${MEDIA_INBOUND}/*" > /dev/null 2>&1; then
cp -a "${MEDIA_INBOUND}"/* "${OFFLOAD_MEDIA}/"
echo " Copied to ${OFFLOAD_MEDIA}"

# Verify copy BEFORE deleting
orig_count=$(find "${MEDIA_INBOUND}" -maxdepth 1 -type f | wc -l)
copy_count=$(find "${OFFLOAD_MEDIA}" -maxdepth 1 -type f | wc -l)
if [[ "${orig_count}" -eq "${copy_count}" ]] && [[ "${orig_count}" -gt 0 ]]; then
rm -f "${MEDIA_INBOUND}"/*
echo " Verified ✓ Removed originals from ${MEDIA_INBOUND}"
else
echo "ERROR: Copy verification failed (${orig_count} vs ${copy_count})!"
exit 1
fi
else
echo " No inbound media files to move"
fi

# Bind mount only if not already mounted
if mountpoint -q "${MEDIA_INBOUND}"; then
echo " ${MEDIA_INBOUND} already bind-mounted"
else
if ! sudo mount --bind "${OFFLOAD_MEDIA}" "${MEDIA_INBOUND}"; then
echo "ERROR: Bind mount failed! Restoring originals..."
cp -a "${OFFLOAD_MEDIA}"/* "${MEDIA_INBOUND}/"
exit 1
fi
echo "  Bind-mounted ${OFFLOAD_MEDIA} → ${MEDIA_INBOUND}"
fi
ls -la "${MEDIA_INBOUND}/"
echo ""


# ── Step 5: Move llama.cpp ────────────────────────────────
echo "=== Step 5: Moving llama.cpp ==="
if mountpoint -q "${LLAMA_CPP}"; then
echo " ${LLAMA_CPP} already bind-mounted — skipping copy"
elif [[ -d "${LLAMA_CPP}" ]] && compgen -G "${LLAMA_CPP}/*" > /dev/null 2>&1; then
cp -a "${LLAMA_CPP}"/* "${OFFLOAD_LLAMA}/"
echo " Copied to ${OFFLOAD_LLAMA}"

# Verify copy BEFORE deleting — check file count and total size
orig_count=$(find "${LLAMA_CPP}" -maxdepth 1 -type f | wc -l)
copy_count=$(find "${OFFLOAD_LLAMA}" -maxdepth 1 -type f | wc -l)
orig_size=$(du -sb "${LLAMA_CPP}" 2>/dev/null | awk '{print $1}')
copy_size=$(du -sb "${OFFLOAD_LLAMA}" 2>/dev/null | awk '{print $1}')
if [[ "${orig_count}" -eq "${copy_count}" ]] && [[ "${orig_size}" -eq "${copy_size}" ]] && [[ "${orig_count}" -gt 0 ]]; then
# Remove originals — use rm -rf since it's a full directory move
rm -rf "${LLAMA_CPP}"/*
echo " Verified ✓ Removed originals from ${LLAMA_CPP}"
else
echo "ERROR: Copy verification failed (count: ${orig_count} vs ${copy_count}, size: ${orig_size} vs ${copy_size})!"
exit 1
fi
else
echo " ${LLAMA_CPP} is empty or missing — skipping copy"
fi

# Bind mount with rollback guard
if mountpoint -q "${LLAMA_CPP}"; then
echo " ${LLAMA_CPP} already bind-mounted"
else
if ! sudo mount --bind "${OFFLOAD_LLAMA}" "${LLAMA_CPP}"; then
echo "ERROR: Bind mount failed! Restoring originals..."
cp -a "${OFFLOAD_LLAMA}"/* "${LLAMA_CPP}/"
exit 1
fi
echo " Bind-mounted ${OFFLOAD_LLAMA} → ${LLAMA_CPP}"
fi
ls -la "${LLAMA_CPP}/"
echo ""

# ── Step 6: Redirect TMPDIR ─────────────────────────────────
echo "=== Step 6: Setting TMPDIR ==="
if ! grep -q "export TMPDIR=${OFFLOAD_TMP}" "${BASHRC_FILE}" 2>/dev/null; then
echo "export TMPDIR=${OFFLOAD_TMP}" >> "${BASHRC_FILE}"
echo " Added TMPDIR to ~/.bashrc"
else
echo " TMPDIR already set in ~/.bashrc"
fi
export TMPDIR="${OFFLOAD_TMP}"
echo " TMPDIR=${TMPDIR}"
echo ""

# Also set at systemd level so the OpenClaw gateway sees it
if sudo systemctl --user set-environment TMPDIR="${OFFLOAD_TMP}" 2>/dev/null; then
echo "  Set TMPDIR in systemd user environment"
echo "  Restarting gateway..."
openclaw gateway restart || echo "  (gateway restart skipped)"
else
echo "  WARNING: Could not set TMPDIR in systemd (no D-Bus session)"
echo "  Run these manually afterward:"
echo "    systemctl --user set-environment TMPDIR=${OFFLOAD_TMP}"
echo "    openclaw gateway restart"
fi
echo ""

# ── Step 6: Update /etc/fstab ────────────────────────────────
echo "=== Step 6: Updating /etc/fstab ==="

# Simply remove all offload comment lines — much safer
sudo sed -i '/# External drive offloads/d' /etc/fstab

# Add new entries
fstab_entries=(
"# External drive offloads (auto-generated)"
"UUID=${ACTUAL_UUID} ${DRIVE_MOUNT} ${fs_type} defaults,nofail 0 0"
"${OFFLOAD_WHISPER} ${WHISPER_CACHE} none bind,nofail,x-systemd.requires=${DRIVE_MOUNT} 0 0"
"${OFFLOAD_MEDIA} ${MEDIA_INBOUND} none bind,nofail,x-systemd.requires=${DRIVE_MOUNT} 0 0"
"${OFFLOAD_LLAMA} ${LLAMA_CPP} none bind,nofail,x-systemd.requires=${DRIVE_MOUNT} 0 0"
)

for entry in "${fstab_entries[@]}"; do
echo "${entry}" | sudo tee -a /etc/fstab > /dev/null
done
echo " Wrote fstab entries"
echo ""

# ── Step 7: Verify ───────────────────────────────────────────
echo "=== Step 7: Verifying ==="
sudo mount -a 2>&1 || echo " (mount -a warnings OK if already mounted)"
echo ""

echo "--- Whisper cache ---"
ls -lh "${WHISPER_CACHE}/" 2>/dev/null || echo " (empty)"
echo ""

echo "--- Inbound media ---"
ls -lh "${MEDIA_INBOUND}/" 2>/dev/null || echo " (empty)"
echo ""

echo "--- llama.cpp ---"
ls -lh "${LLAMA_CPP}/" 2>/dev/null || echo " (empty)"
echo ""

echo "--- Disk usage ---"
df -h / "${DRIVE_MOUNT}"
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Done! Offloaded to ${DRIVE_MOUNT}"
echo "(No swap — safe for USB)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

