#!/usr/bin/env bash
set -euo pipefail

OUTDIR="$(realpath "${OUTDIR:-./out}")"
BIN="${BIN:-tailscale.combined}"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

mkdir -p "$OUTDIR"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

require_cmd git
require_cmd go
require_cmd ssh
require_cmd ssh-keygen
require_cmd sftp

SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
SSH_PUB="${SSH_KEY}.pub"
SSH_OPTS=(
  -o StrictHostKeyChecking=accept-new
  -o PreferredAuthentications=publickey
  -o PubkeyAuthentication=yes
  -i "$SSH_KEY"
)

choose_ref() {
  local choice
  local -a refs
  local i

  echo "Choose what to build:"
  select choice in "Latest tag" "Tag" "Branch"; do
    case "${REPLY:-}" in
      1)
        SELECTED_REF="$(
          git ls-remote --refs --tags https://github.com/tailscale/tailscale.git 'v*' \
            | awk '{print $2}' \
            | sed 's#refs/tags/##' \
            | sort -V \
            | tail -n1
        )"
        return 0
        ;;
      2)
        mapfile -t refs < <(
          git ls-remote --refs --tags https://github.com/tailscale/tailscale.git 'v*' \
            | awk '{print $2}' \
            | sed 's#refs/tags/##' \
            | sort -V
        )
        echo
        echo "Available tags:"
        for i in "${!refs[@]}"; do
          printf "%3d) %s\n" "$((i+1))" "${refs[$i]}"
        done
        echo
        read -r -p "Enter tag number or exact tag name: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#refs[@]} )); then
          SELECTED_REF="${refs[$((choice-1))]}"
          return 0
        elif printf '%s\n' "${refs[@]}" | grep -Fxq "$choice"; then
          SELECTED_REF="$choice"
          return 0
        else
          echo "Invalid tag selection" >&2
          exit 1
        fi
        ;;
      3)
        mapfile -t refs < <(
          git ls-remote --refs --heads https://github.com/tailscale/tailscale.git \
            | awk '{print $2}' \
            | sed 's#refs/heads/##' \
            | sort
        )
        echo
        echo "Available branches:"
        for i in "${!refs[@]}"; do
          printf "%3d) %s\n" "$((i+1))" "${refs[$i]}"
        done
        echo
        read -r -p "Enter branch number or exact branch name: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#refs[@]} )); then
          SELECTED_REF="${refs[$((choice-1))]}"
          return 0
        elif printf '%s\n' "${refs[@]}" | grep -Fxq "$choice"; then
          SELECTED_REF="$choice"
          return 0
        else
          echo "Invalid branch selection" >&2
          exit 1
        fi
        ;;
      *)
        echo "Invalid selection"
        ;;
    esac
  done
}

build_binary() {
  cd "$WORKDIR"

  git clone --depth=1 --branch "$SELECTED_REF" https://github.com/tailscale/tailscale.git src
  cd src

  TAGS='ts_include_cli,ts_omit_aws,ts_omit_bakedroots,ts_omit_bird,ts_omit_c2n,ts_omit_cachenetmap,ts_omit_captiveportal,ts_omit_capture,ts_omit_cliconndiag,ts_omit_clientmetrics,ts_omit_clientupdate,ts_omit_cloud,ts_omit_colorable,ts_omit_completion,ts_omit_completion_scripts,ts_omit_conn25,ts_omit_dbus,ts_omit_debug,ts_omit_debugeventbus,ts_omit_debugportmapper,ts_omit_desktop_sessions,ts_omit_doctor,ts_omit_drive,ts_omit_gro,ts_omit_health,ts_omit_hujsonconf,ts_omit_identityfederation,ts_omit_kube,ts_omit_lazywg,ts_omit_linkspeed,ts_omit_linuxdnsfight,ts_omit_listenrawdisco,ts_omit_logtail,ts_omit_netlog,ts_omit_netstack,ts_omit_networkmanager,ts_omit_oauthkey,ts_omit_outboundproxy,ts_omit_peerapiserver,ts_omit_portlist,ts_omit_posture,ts_omit_qrcodes,ts_omit_relayserver,ts_omit_resolved,ts_omit_sdnotify,ts_omit_serve,ts_omit_ssh,ts_omit_synology,ts_omit_syspolicy,ts_omit_systray,ts_omit_taildrop,ts_omit_tailnetlock,ts_omit_tap,ts_omit_tpm,ts_omit_unixsocketidentity,ts_omit_useproxy,ts_omit_usermetrics,ts_omit_wakeonlan,ts_omit_webbrowser,ts_omit_webclient'

  CGO_ENABLED=0 \
  GOOS=linux \
  GOARCH=arm64 \
  go build \
    -trimpath \
    -tags "$TAGS" \
    -ldflags "-s -w" \
    -o "$OUTDIR/$BIN" \
    ./cmd/tailscaled
}

ensure_local_ssh_key() {
  if [[ ! -f "$SSH_KEY" || ! -f "$SSH_PUB" ]]; then
    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"
    ssh-keygen -t ed25519 -N "" -f "$SSH_KEY"
  fi
}

can_login_with_key() {
  local host="$1"
  ssh "${SSH_OPTS[@]}" \
    -o BatchMode=yes \
    -o ConnectTimeout=5 \
    root@"$host" "true" >/dev/null 2>&1
}

install_key_on_router() {
  local host="$1"
  local pubkey
  pubkey="$(cat "$SSH_PUB")"

  echo "No working SSH key login found."
  echo "A one-time password login is needed to install your public key on the router."

  if command -v ssh-copy-id >/dev/null 2>&1; then
    ssh-copy-id -i "$SSH_PUB" -o StrictHostKeyChecking=accept-new root@"$host"
    return 0
  fi
}

deploy_router() {
  local router_host
  read -r -p "Router IP/hostname: " router_host

  ensure_local_ssh_key

  if ! can_login_with_key "$router_host"; then
    install_key_on_router "$router_host"
  fi

  if ! can_login_with_key "$router_host"; then
    echo "SSH key login still failed after key installation." >&2
    exit 1
  fi

  ssh "${SSH_OPTS[@]}" -C root@"$router_host" '
    set -e
    rm -f \
      /usr/sbin/tailscale \
      /usr/sbin/tailscaled \
      /usr/sbin/tailscale.combined \
      /overlay/usr/sbin/tailscale \
      /overlay/usr/sbin/tailscaled \
      /overlay/usr/sbin/tailscale.combined \
      /tmp/tailscaled.tmp
  '

  cat "$OUTDIR/$BIN" | ssh "${SSH_OPTS[@]}" -C root@"$router_host" \
    "cat > /tmp/tailscaled.tmp"

  ssh "${SSH_OPTS[@]}" -C root@"$router_host" '
    set -e
    mv /tmp/tailscaled.tmp /usr/sbin/tailscaled
    chmod 755 /usr/sbin/tailscaled
    rm -f /tmp/tailscaled.tmp
    ln -sfn tailscaled /usr/sbin/tailscale
  '

  echo "Deployed to root@$router_host:/usr/sbin/tailscaled"
}

main() {
  choose_ref
  echo "Selected ref: $SELECTED_REF"
  build_binary
  echo "Built: $OUTDIR/$BIN"

  read -r -p "Deploy to router now? [y/N]: " deploy_now
  case "${deploy_now:-N}" in
    y|Y|yes|YES)
      deploy_router
      ;;
  esac
}

main "$@"