#!/usr/bin/env bash
# vm150-require-virtiofs.sh — Proxmox hookscript for VM 150 (ciri).
#
# Purpose
#   Refuse to start ciri when a REQUIRED virtiofs-shared host directory is not
#   the real backing filesystem; warn (but start anyway) for ADVISORY ones.
#
#   virtiofsd resolves --shared-dir ONCE, at VM start, and pins that inode for
#   the life of the process. If the host mount lands even a second later, the
#   guest is served the empty pre-mount directory (on pve-root) for as long as
#   the VM runs — a guest-side remount cannot fix it, only a cold VM restart.
#
#   This bit the lab on 2026-07-27: geralt rebooted, virtiofsd started 15:22:17,
#   mnt-media.mount completed 15:22:19. ciri then saw a 68 GB empty /mnt/media
#   (geralt's boot disk) instead of the 916 GB media disk. Jellyfin refused to
#   start (its create_host_path:false guard fired), but qBittorrent and the *arr
#   ran against the boot disk and marked all 20 torrents missingFiles.
#
# Why the two tiers are NOT symmetric (deliberate, 2026-07-28)
#   /steel/photos  = REQUIRED. Internal SATA disk, always present, and it holds
#                    the one irreplaceable dataset in the lab (Immich originals).
#                    If it is not mounted, something is badly wrong and starting
#                    ciri onto an empty share risks Immich acting on a void.
#                    Blocking is correct: the disk is never legitimately absent.
#   /mnt/media     = ADVISORY. External USB disk, explicitly disposable, and it
#                    DOES go away (bus resets, unplugs — see the jellyfin README).
#                    ciri also runs Immich, Paperless, memos, sure and
#                    nebula-sync, none of which touch media. Holding all of them
#                    hostage to a USB disk is the wrong trade. The VM starts;
#                    the media containers are held back instead, by
#                    create_host_path:false guards on their binds
#                    (configs/ciri/{jellyfin,servarr}/compose.yaml).
#                    (Historical since proposal 005 — media is NFS now and no
#                    longer passes through this hook at all.)
#
#   Boot ordering for /mnt/media USED to be handled in geralt's /etc/fstab with
#     x-systemd.before=pve-guests.service,x-systemd.device-timeout=30
#   Dropped with proposal 005 (2026-08-23): that ordering existed only because
#   virtiofsd had to resolve --shared-dir before ciri started. NFS has no
#   start-time inode to pin, so guest start no longer needs to wait on a flaky
#   USB disk at all — the export's `mountpoint` guard owns correctness, and
#   media-autoheal.sh owns recovery.
#
# Usage (on geralt, as root)
#   install -m 0755 vm150-require-virtiofs.sh /var/lib/vz/snippets/
#   qm set 150 --hookscript local:snippets/vm150-require-virtiofs.sh
#
#   Proxmox invokes it as: <script> <vmid> <phase>
#   phase ∈ pre-start | post-start | pre-stop | post-stop
#   A non-zero exit during pre-start aborts the start.
#
# Requires: findmnt (util-linux, present on PVE). No env vars, no other args.

set -euo pipefail

readonly VMID_EXPECTED=150

# One entry per virtiofs mapping on VM 150:
#   "<host dir>:<expected fstype>:<child that exists only on the real fs>:<required|advisory>"
# The sentinel child is what separates "mounted" from "mounted but empty" and
# from "an empty stand-in directory on the root filesystem".
readonly SHARES=(
  "/steel/photos:zfs:library:required"   # virtiofs0 — Immich originals (irreplaceable)
  # /mnt/media left this list with proposal 005 (2026-08-23): the media disk is
  # served to ciri over NFS now, not virtiofs, so there is no start-time inode
  # pin to guard. Its availability is autoheal's + the export `mountpoint`
  # guard's problem; the media containers still have their own bind guards.
)

main() {
  local vmid phase
  vmid=${1:?usage: $0 <vmid> <phase>}
  phase=${2:?usage: $0 <vmid> <phase>}

  [[ "$phase" == "pre-start" ]] || exit 0
  [[ "$vmid" == "$VMID_EXPECTED" ]] || exit 0

  local blocked=0 share dir fstype sentinel tier actual problem
  for share in "${SHARES[@]}"; do
    IFS=: read -r dir fstype sentinel tier <<<"$share"
    problem=""

    # --mountpoint matches EXACTLY: unlike --target it will not silently fall
    # back to the parent mount, which is what makes an unmounted /mnt/media look
    # like a perfectly healthy ext4 filesystem (it reports pve-root).
    if ! actual=$(findmnt --noheadings --first-only --output FSTYPE \
                          --mountpoint "$dir" 2>/dev/null); then
      problem="not a mount point (virtiofsd would share the empty directory underneath it)"
    elif [[ "$actual" != "$fstype" ]]; then
      problem="mounted as '$actual', expected '$fstype'"
    elif [[ ! -d "$dir/$sentinel" ]]; then
      problem="mounted ($fstype) but '$dir/$sentinel' is missing — wrong or empty filesystem"
    fi

    if [[ -z "$problem" ]]; then
      echo "$0: '$dir' ok ($fstype, '$sentinel' present)."
      continue
    fi

    if [[ "$tier" == "required" ]]; then
      echo "$0: REQUIRED share '$dir': $problem. Refusing to start VM $vmid." >&2
      blocked=1
    else
      echo "$0: advisory share '$dir': $problem. Starting VM $vmid anyway —" \
           "media containers will be held back by their own bind guards." >&2
    fi
  done

  if (( blocked )); then
    echo "$0: fix the host mount(s), then 'qm start $vmid'." >&2
    exit 1
  fi
}

main "$@"
