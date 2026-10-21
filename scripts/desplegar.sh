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

# --- Preparación de la versión ----------------------------------------------

if [ "$RELEASES" != "$HOME/releases" ]; then
    echo "RELEASES apunta a $RELEASES: solo se permite con --solo-descarga." >&2
    exit 1
fi

DIR="$RELEASES/$VER"

if [ "$SOLO" != "front" ]; then
    mkdir -p "$DIR/qhcube-back"
    cp "$DESCARGAS/back/qhcube-back-$VER.jar" "$DIR/qhcube-back/"
fi
if [ "$SOLO" != "back" ]; then
    mkdir -p "$DIR/qhcube-front"
    tar xzf "$DESCARGAS/front/qhcube-front-$VER.tar.gz" -C "$DIR/qhcube-front"
    grep -rqF "versionFront:\`$VER\`" "$DIR/qhcube-front/assets" \
        || { echo "El frontend descomprimido no es la versión $VER." >&2; exit 1; }
fi

# --- Copia de seguridad de la base de datos ---------------------------------

BACKUP="$HOME/backups/$(date +%F)/qhcube_db-$(date +%H%M%S).sql"
mkdir -p "$(dirname "$BACKUP")"
echo "Copia de seguridad en $BACKUP..."
docker exec mysql-prod sh -c 'exec mysqldump -uroot -p"$MYSQL_ROOT_PASSWORD" --single-transaction --routines qhcube_db' > "$BACKUP"
[ -s "$BACKUP" ] || { echo "La copia de seguridad está vacía." >&2; exit 1; }

# --- Confirmación -----------------------------------------------------------

ANTES_BACK="$(readlink "$HOME/qhcube-back")"
ANTES_FRONT="$(readlink "$HOME/qhcube-front")"
echo
echo "Ahora:   back → $ANTES_BACK"
echo "         front → $ANTES_FRONT"
echo "Nueva versión: $VER ${SOLO:+(solo $SOLO)}"
read -r -p "¿Activar? Escribe 'si' para continuar: " RESPUESTA
[ "$RESPUESTA" = "si" ] || { echo "Cancelado. No se ha cambiado nada."; exit 1; }

# --- Activación -------------------------------------------------------------

cd "$HOME"
[ "$SOLO" != "front" ] && ln -sfn "releases/$VER/qhcube-back"  qhcube-back
[ "$SOLO" != "back" ]  && ln -sfn "releases/$VER/qhcube-front" qhcube-front

cd "$HOME/qhcube-deploy"
if [ "$SOLO" = "back" ]; then
    docker compose up -d --force-recreate spring-prod
else
    docker compose up -d --force-recreate
fi

# --- Verificación -----------------------------------------------------------

URL="https://qhcube.etsisi.upm.es"
OK=true

if [ "$SOLO" != "front" ]; then
    echo -n "Esperando al backend"
    VERSION_BACK=""
    for _ in $(seq 1 30); do
        VERSION_BACK="$(curl -fsS "$URL/free/version-back" 2>/dev/null | jq -r .version 2>/dev/null || true)"
        [ "$VERSION_BACK" = "$VER" ] && break
        echo -n "."; sleep 2
    done
    echo
    if [ "$VERSION_BACK" = "$VER" ]; then echo "✔ Backend $VERSION_BACK"; else echo "✘ Backend responde '$VERSION_BACK'"; OK=false; fi
fi
if [ "$SOLO" != "back" ]; then
    if [ "$(curl -fsS "$URL/" | sha256sum)" = "$(sha256sum < "$DIR/qhcube-front/index.html")" ]; then
        echo "✔ Frontend $VER"
    else
        echo "✘ El frontend servido no es el de la versión $VER"; OK=false
    fi
fi

if $OK; then
    echo "Versión $VER desplegada."
else
    echo
    echo "ALGO HA FALLADO. Para volver a la versión anterior:" >&2
    echo "  cd ~ && ln -sfn $ANTES_BACK qhcube-back && ln -sfn $ANTES_FRONT qhcube-front" >&2
    echo "  cd ~/qhcube-deploy && docker compose up -d --force-recreate" >&2
    exit 1
fi
