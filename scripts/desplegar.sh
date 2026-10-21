#!/usr/bin/env bash
# Despliega una versión de QHCube a partir de sus GitHub Releases.
#   Uso: desplegar.sh <versión> [--solo back|front] [--solo-descarga]

set -euo pipefail

ORG=qhcube
TOKEN_FILE="$HOME/.config/qhcube/github-token"
RELEASES="${RELEASES:-$HOME/releases}"

# --- Argumentos -------------------------------------------------------------

VER="${1:?Uso: desplegar.sh <versión> [--solo back|front] [--solo-descarga]}"
shift
SOLO=""
SOLO_DESCARGA=false
while [ $# -gt 0 ]; do
    case "$1" in
        --solo)          SOLO="${2:-}"; shift 2 || shift ;;
        --solo-descarga) SOLO_DESCARGA=true; shift ;;
        *) echo "Opción desconocida: $1" >&2; exit 1 ;;
    esac
done

case "$SOLO" in
    ""|back|front) ;;
    *) echo "--solo debe ser 'back' o 'front', no '$SOLO'" >&2; exit 1 ;;
esac

TOKEN="$(cat "$TOKEN_FILE")"

# --- Funciones --------------------------------------------------------------

descargar() {   # descargar <repo> <carpeta destino>
    local repo="$1" destino="$2"
    local api="https://api.github.com/repos/$ORG/$repo/releases"
    local release
    echo "Descargando $repo v$VER..."
    release="$(curl -fsSL -H "Authorization: Bearer $TOKEN" "$api/tags/v$VER")"
    mkdir -p "$destino"
    jq -r '.assets[] | "\(.id) \(.name)"' <<< "$release" \
        | while read -r id nombre; do
              curl -fsSL -H "Authorization: Bearer $TOKEN" -H "Accept: application/octet-stream" \
                  -o "$destino/$nombre" "$api/assets/$id"
              echo "  $nombre"
          done
}

comprobar() {   # comprobar <carpeta>
    echo "Comprobando sumas en $1..."
    ( cd "$1" && awk '{ n = $2; sub(".*/", "", n); print $1 "  " n }' SHA256SUMS \
        | sha256sum -c --ignore-missing - )
}

# --- Descarga y comprobación ------------------------------------------------

DESCARGAS="$RELEASES/$VER/descargas"

if [ "$SOLO" != "front" ]; then
    descargar qhcube-back "$DESCARGAS/back"
    comprobar "$DESCARGAS/back"
fi
if [ "$SOLO" != "back" ]; then
    descargar qhcube-front "$DESCARGAS/front"
    comprobar "$DESCARGAS/front"
fi

if $SOLO_DESCARGA; then
    echo "Descarga comprobada en $DESCARGAS (--solo-descarga: no se ha tocado nada más)."
    exit 0
fi

