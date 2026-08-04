#!/usr/bin/env bash
# gpu-health.sh — Uptime-Kuma push monitor: prove Jellyfin can still ENCODE on the GPU.
#
# Why this exists
#   2026-08-01: the jellyfin container lost its cgroup device access to the GTX 1060
#   while still running. Every transcode died instantly at
#       cu->cuInit(0) failed -> CUDA_ERROR_NO_DEVICE
#   (ffmpeg exit 187, retried dozens of times per playback attempt). On the TV this
#   surfaced as "media is not supported by this client", which reads as a codec fault.
#
#   It ran for ~21 hours undetected. Nothing was down: Jellyfin answered on :8096,
#   the Kuma HTTP monitor stayed green, and Beszel's GPU panel showed a perfectly
#   healthy card — because Beszel watches the GPU from the HOST, where it was fine.
#   Nothing watched whether the *container* could still reach it. Direct Play kept
#   working throughout, so most playback was normal and hid the fault.
#
#   Same shape as the 2026-07-27 media-mount blind spot (see media-mount-health.sh):
#   liveness cannot see a capability that has silently gone missing.
#
# What it asserts, and why nvidia-smi is not enough
#   `nvidia-smi` succeeding proves NVML is reachable. It does NOT prove the ENCODER
#   is usable — under the legacy runtime path a container with
#   NVIDIA_DRIVER_CAPABILITIES missing `video` runs nvidia-smi happily while NVENC
#   is invisible. So the load-bearing check is a real one-second NVENC encode using
#   Jellyfin's own ffmpeg, inside the container. That is the actual invariant:
#   "Jellyfin can encode on the GPU", not "a GPU exists somewhere nearby".
#
# Two severities, deliberately
#   HARD (push down immediately) — things that must never be true:
#     1. the jellyfin container is not running
#     2. nvidia-smi fails inside jellyfin          → lost device access (the 08-01 fault)
#     3. h264_nvenc missing from jellyfin's ffmpeg → the capabilities trap above
#     4. the test encode fails with the GPU IDLE   → a real fault, nothing to blame
#     5. ollama is running but nvidia-smi fails inside it → the other GPU consumer
#                                                   lost access; same fault class
#
#   SOFT (push up, message says degraded; escalates to down after $MAX_STRIKES
#   consecutive runs) — the one condition that self-heals:
#     6. the test encode fails while >= $VRAM_CONTENTION_MIB of VRAM is in use
#        → attributable to a resident Ollama model on the shared 6 GB card.
#          OLLAMA_KEEP_ALIVE=10m frees it, so a transient failure here is expected
#          and paging on it would be noise. A model that never unloads, or a wedged
#          GPU, still escalates.
#
#   That soft/hard split is the same distinction documented in the jellyfin README
#   ("Is it the daemon-reload, or VRAM contention with ollama?"): contention fails
#   AFTER CUDA initialises and only while something is loaded; lost device access
#   fails before any allocation, with the card completely idle.
#
# Behaviour
#   Healthy    → push status=up   → Kuma heartbeat green
#   Degraded   → push status=up with a "degraded:" message → green, reason visible in
#                Kuma's heartbeat log; exits 0
#   Hard fail  → push status=down with the reason → Kuma red → ntfy, and exit 1 so
#                `systemctl --failed` shows it on ciri too
#   Script/timer dead → no heartbeat → Kuma reddens on its own (the backstop)
#
# Usage
#   gpu-health.sh                # no arguments; run from a systemd timer on ciri
#
# Deploy (on ciri) — see scripts/monitoring/README.md for the unit + timer
#   sudo install -m 0755 gpu-health.sh /usr/local/bin/
#   printf '%s\n' '<KUMA_PUSH_URL>' | sudo tee /etc/kuma-push.gpu-health >/dev/null
#   sudo chmod 600 /etc/kuma-push.gpu-health
#
# Requires: curl, docker, nvidia-smi on the host. The push URL carries a token, so it
#           lives ONLY in that 0600 file and in secrets.local.yaml — never here.
# Env overrides: JELLYFIN_CONTAINER, OLLAMA_CONTAINER, KUMA_URL_FILE, MAX_STRIKES,
#                VRAM_CONTENTION_MIB, FFMPEG_BIN, EXEC_TIMEOUT, STATE_DIR
# Test hook:     FORCE_ENCODE_FAIL=1 (see the note by its declaration below)

set -euo pipefail

readonly JELLYFIN_CONTAINER="${JELLYFIN_CONTAINER:-jellyfin}"
readonly OLLAMA_CONTAINER="${OLLAMA_CONTAINER:-ollama}"
readonly FFMPEG_BIN="${FFMPEG_BIN:-/usr/lib/jellyfin-ffmpeg/ffmpeg}"
readonly KUMA_URL_FILE="${KUMA_URL_FILE:-/etc/kuma-push.gpu-health}"
# Every docker exec is wrapped: a wedged container must not hang the unit forever.
# Belt and braces with the TimeoutStartSec drop-in (see README) — this one gives a
# labelled failure instead of a timeout kill.
readonly EXEC_TIMEOUT="${EXEC_TIMEOUT:-30}"
# 3000 MiB: comfortably above an idle card (0 MiB) plus a transcode session (~115 MiB
# measured 2026-08-02), and below the smallest resident model (~4.3 G for the 30B's
# offloaded layers, ~5 G for qwen3:8b). Only used to ATTRIBUTE an encode failure —
# it never causes one.
readonly VRAM_CONTENTION_MIB="${VRAM_CONTENTION_MIB:-3000}"
readonly MAX_STRIKES="${MAX_STRIKES:-6}"
# Test hook: force the encode probe to fail without touching the GPU or the
# container. Needed because the obvious trick — pointing FFMPEG_BIN at /bin/false —
# trips the EARLIER `-encoders` check and lands on the hard path instead, so it
# cannot reach the soft path at all. Pair with VRAM_CONTENTION_MIB=0 to exercise
# contention handling. See scripts/monitoring/README.md.
readonly FORCE_ENCODE_FAIL="${FORCE_ENCODE_FAIL:-}"
# Outside /tmp on purpose: a reboot must not reset a genuinely stuck GPU to zero
# strikes. Same reasoning as servarr-vpn-health.sh.
readonly STATE_DIR="${STATE_DIR:-/var/lib/gpu-health}"
readonly STRIKE_FILE="$STATE_DIR/degraded.strikes"

# Push a heartbeat to Kuma. A push failure is reported but must NOT change the
# verdict: "Kuma is unreachable" is a different fault from "the GPU is gone".
push() {
  local status=$1 msg=$2 url
  if [[ ! -r "$KUMA_URL_FILE" ]]; then
    echo "gpu-health: cannot read $KUMA_URL_FILE — not pushing" >&2
    return 0
  fi
  url=$(< "$KUMA_URL_FILE")
  url=${url//[$'\t\r\n ']/}
  [[ -n "$url" ]] || { echo "gpu-health: $KUMA_URL_FILE is empty" >&2; return 0; }

  # --retry: one dropped push is one missed heartbeat, and Kuma cannot tell that
  # apart from the GPU being gone. Observed for real on the media-mount monitor.
  if ! curl -fsS --max-time 10 --retry 2 --retry-delay 3 --retry-connrefused --get \
        --data-urlencode "status=$status" \
        --data-urlencode "msg=$msg" \
        "$url" >/dev/null; then
    echo "gpu-health: push to Uptime-Kuma failed (check itself said: $status/$msg)" >&2
  fi
}

read_strikes() {
  local n
  if [[ -r "$STRIKE_FILE" ]] && n=$(< "$STRIKE_FILE") && [[ "$n" =~ ^[0-9]+$ ]]; then
    echo "$n"
  else
    echo 0
  fi
}

write_strikes() {
  mkdir -p "$STATE_DIR" 2>/dev/null || true
  echo "$1" > "$STRIKE_FILE" 2>/dev/null || true
}

container_running() {
  local name=$1 state
  state=$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null) || return 1
  [[ "$state" == "true" ]]
}

# VRAM in use on the card, in MiB. Read from the HOST — this is about the physical
# card, not any one container. Echoes -1 if it cannot be determined, which callers
# must treat as "cannot attribute" rather than "idle".
vram_used_mib() {
  local out
  if ! out=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null); then
    echo -1; return 0
  fi
  out=${out//[$'\t\r\n ']/}
  [[ "$out" =~ ^[0-9]+$ ]] && echo "$out" || echo -1
}

# The load-bearing check: a real NVENC encode with Jellyfin's own ffmpeg, inside the
# container. Exercises CUDA init, NVENC session allocation and an actual encode —
# every step a transcode needs. Output goes to the null muxer; nothing is written.
nvenc_encode_works() {
  [[ -z "$FORCE_ENCODE_FAIL" ]] || return 1
  timeout "$EXEC_TIMEOUT" docker exec "$JELLYFIN_CONTAINER" \
    "$FFMPEG_BIN" -hide_banner -loglevel error \
    -f lavfi -i testsrc=duration=1:size=256x256:rate=5 \
    -c:v h264_nvenc -f null - >/dev/null 2>&1
}

# Returns 0 healthy, 1 hard fail, 2 soft/degraded. Detail on stdout.
check() {
  local vram

  if ! container_running "$JELLYFIN_CONTAINER"; then
    echo "container '$JELLYFIN_CONTAINER' is not running"
    return 1
  fi

  # 1. NVML reachable inside the container — catches the 2026-08-01 fault directly.
  if ! timeout "$EXEC_TIMEOUT" docker exec "$JELLYFIN_CONTAINER" \
        nvidia-smi >/dev/null 2>&1; then
    echo "nvidia-smi FAILED inside '$JELLYFIN_CONTAINER' — container has lost GPU access (host card may be fine)"
    return 1
  fi

  # 2. Encoder present. Distinct from step 1 on purpose: NVML and NVENC can and do
  #    disagree, which is exactly what NVIDIA_DRIVER_CAPABILITIES used to guard.
  #
  #    Capture the listing and match in-shell rather than piping to `grep -q`.
  #    Under `set -o pipefail` that pipeline reports 141: grep -q exits at the
  #    first match and closes the pipe, ffmpeg takes SIGPIPE with ~200 lines still
  #    to write, and pipefail surfaces the signal as the pipeline's status. The
  #    first version of this script did exactly that and reported the encoder
  #    missing while it was demonstrably present (caught on first deploy,
  #    2026-08-05). Capturing also separates "ffmpeg would not run" from
  #    "the encoder is absent", which are different faults.
  local encoders
  if ! encoders=$(timeout "$EXEC_TIMEOUT" docker exec "$JELLYFIN_CONTAINER" \
                    "$FFMPEG_BIN" -hide_banner -encoders 2>/dev/null); then
    echo "could not list encoders in '$JELLYFIN_CONTAINER' — ffmpeg failed to run ($FFMPEG_BIN)"
    return 1
  fi
  if [[ "$encoders" != *h264_nvenc* ]]; then
    echo "h264_nvenc missing from ffmpeg in '$JELLYFIN_CONTAINER' — NVML works but the encoder is not exposed"
    return 1
  fi

  # 3. The other GPU consumer. Only checked when it is running, so a deliberately
  #    stopped ai stack is not an alert.
  if container_running "$OLLAMA_CONTAINER"; then
    if ! timeout "$EXEC_TIMEOUT" docker exec "$OLLAMA_CONTAINER" \
          nvidia-smi >/dev/null 2>&1; then
      echo "nvidia-smi FAILED inside '$OLLAMA_CONTAINER' — that container has lost GPU access"
      return 1
    fi
  fi

  # 4. Prove it can actually encode.
  vram=$(vram_used_mib)
  if ! nvenc_encode_works; then
    if (( vram >= VRAM_CONTENTION_MIB )); then
      echo "degraded: NVENC test encode failed with ${vram}MiB VRAM in use — likely a resident Ollama model on the shared card"
      return 2
    fi
    if (( vram < 0 )); then
      # Cannot attribute. Fail closed: an unreadable nvidia-smi is not evidence of
      # innocence, and this path means the encode already failed.
      echo "NVENC test encode FAILED and VRAM usage could not be read — cannot attribute, treating as a fault"
      return 1
    fi
    echo "NVENC test encode FAILED with the GPU essentially idle (${vram}MiB used) — not contention, the encoder is broken"
    return 1
  fi

  echo "ok: '$JELLYFIN_CONTAINER' encoded on the GPU (h264_nvenc), ${vram}MiB VRAM in use"
  return 0
}

main() {
  local detail rc strikes

  set +e
  detail=$(check)
  rc=$?
  set -e

  case $rc in
    0)
      write_strikes 0
      push "up" "$detail"
      echo "gpu-health: $detail"
      ;;
    2)
      strikes=$(( $(read_strikes) + 1 ))
      write_strikes "$strikes"
      if (( strikes >= MAX_STRIKES )); then
        push "down" "$detail (persisted $strikes runs — escalated)"
        echo "gpu-health: FAIL — $detail (strike $strikes/$MAX_STRIKES, escalated)" >&2
        exit 1
      fi
      push "up" "$detail (strike $strikes/$MAX_STRIKES)"
      echo "gpu-health: $detail (strike $strikes/$MAX_STRIKES)"
      ;;
    *)
      write_strikes 0
      push "down" "$detail"
      echo "gpu-health: FAIL — $detail" >&2
      exit 1
      ;;
  esac
}

main "$@"
