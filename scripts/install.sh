#!/usr/bin/env bash
set -euo pipefail

repo="harbefas/gambito"
case "$(uname -m)" in
  x86_64) asset="gambito-linux-x86_64.tar.gz" ;;
  *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

api="https://api.github.com/repos/${repo}/releases/latest"
release="$(curl --fail --silent --show-error --location "${api}")"
url="$(printf '%s' "${release}" | sed -n 's/.*"browser_download_url": "\([^"]*'"${asset}"'\)".*/\1/p' | head -1)"
checksum_url="$(printf '%s' "${release}" | sed -n 's/.*"browser_download_url": "\([^"]*'"${asset}.sha256"'\)".*/\1/p' | head -1)"
if [[ -z "${url}" || -z "${checksum_url}" ]]; then
  echo "No release asset found for $(uname -m)." >&2
  exit 1
fi

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
curl --fail --silent --show-error --location "${url}" -o "${tmp}/${asset}"
curl --fail --silent --show-error --location "${checksum_url}" -o "${tmp}/${asset}.sha256"
(
  cd "${tmp}"
  sha256sum --check "${asset}.sha256"
)
tar -xzf "${tmp}/${asset}" -C "${tmp}"

install -Dm755 "${tmp}/gambito" "${HOME}/.local/bin/gambito"
install -d "${HOME}/.local/share/gambito/ui"
install -Dm644 "${tmp}/ui/"*.qml -t "${HOME}/.local/share/gambito/ui"
if [[ -f packaging/gambito.service ]]; then
  install -Dm644 packaging/gambito.service "${HOME}/.config/systemd/user/gambito.service"
  systemctl --user daemon-reload
  systemctl --user enable --now gambito.service
fi
printf 'Installed Gambito from the latest release. Run: gambito open\n'
