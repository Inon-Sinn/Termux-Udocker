#!/data/data/com.termux/files/usr/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/source.env"
cd "$(dirname "${BASH_SOURCE[0]}")"

# Use latest 10.11.x (or pin to 10.11.3 if you prefer)
# IMAGE_NAME="jellyfin/jellyfin:10.11"
IMAGE_NAME="jellyfin/jellyfin:10.11.3"   # uncomment for exact version

CONTAINER_NAME="jellyfin-server"

# Port handling (default 8096)
case $PORT in
    ''|*[!0-9]*) PORT=8096;;
    *) [ $PORT -gt 1023 ] && [ $PORT -lt 65536 ] || PORT=8096;;
esac

udocker_check
udocker_prune
udocker_create "$CONTAINER_NAME" "$IMAGE_NAME"

DATA_DIR="$(pwd)/data-$CONTAINER_NAME"
mkdir -p "$DATA_DIR"/{config,cache,log}

# Storage permission check + optional media mounts
rm -rf /sdcard/.test_has_read_write_media
MEDIA_DIR_CONFIG=""
if ! touch /sdcard/.test_has_read_write_media &>/dev/null; then
    yes | termux-setup-storage &>/dev/null
    sleep 5
fi
if touch /sdcard/.test_has_read_write_media &>/dev/null; then
    mkdir -p /sdcard/{Download,DCIM,Movies,Music}
    MEDIA_DIR_CONFIG="-v /sdcard/Download:/media/Download -v /sdcard/DCIM:/media/DCIM -v /sdcard/Movies:/media/Movies -v /sdcard/Music:/media/Music"
    echo "Mounting Android media folders inside /media/..."
fi
rm -rf /sdcard/.test_has_read_write_media

# Custom command mode (e.g. ./jellyfin.sh bash)
if [ -n "$1" ]; then
    cmd="$*"
    udocker_run --entrypoint "bash -c" -p "$PORT:8096" \
        -e DOTNET_GCHeapHardLimit="1C0000000" \
        -v "$(proot_write_tmp "$(cat "$(pwd)/libnetstub.sh")"):/.libnetstub/libnetstub.sh" \
        -v "$DATA_DIR/config:/config" -v "$DATA_DIR/cache:/cache" -v "$DATA_DIR/log:/config/log" \
        $MEDIA_DIR_CONFIG "$CONTAINER_NAME" \
        ". /.libnetstub/libnetstub.sh; $cmd"
    exit $?
fi

# === NORMAL STARTUP ===
udocker_run --entrypoint "bash -c" -p "$PORT:8096" \
    -e _PORT="$PORT" \
    -e DOTNET_GCHeapHardLimit="1C0000000" \
    -v "$(proot_write_tmp "$(cat "$(pwd)/libnetstub.sh")"):/.libnetstub/libnetstub.sh" \
    -v "$DATA_DIR/config:/config" \
    -v "$DATA_DIR/cache:/cache" \
    -v "$DATA_DIR/log:/config/log" \
    $MEDIA_DIR_CONFIG "$CONTAINER_NAME" ' \

    # Fix hosts (still required on Android proot)
    echo -e "127.0.0.1 localhost.localdomain localhost\n::1 localhost.localdomain localhost ip6-localhost" > /etc/hosts;

    # Build libnetstub.so on first run (and install missing deps for 10.11/Trixie)
    if [[ ! -f /.libnetstub/libnetstub.so && -f /.libnetstub/libnetstub.sh ]]; then
        export DEBIAN_FRONTEND=noninteractive
        apt update
        apt install -y dialog apt-utils
        apt install -y --no-install-recommends gcc libc6-dev libicu76   # <-- libicu76 is critical
        mkdir -p /.libnetstub
        echo ". /.libnetstub/libnetstub.sh" | tee -a ~/.bashrc ~/.zshrc >/dev/null
        . /.libnetstub/libnetstub.sh   # this compiles libnetstub.so
        apt remove -y gcc libc6-dev && apt autoremove -y && apt clean -y
    fi

    # Load the networking stub
    . /.libnetstub/libnetstub.sh

    # Critical fix: combine BOTH LD_PRELOADs correctly (jemalloc first!)
    if [ -f /usr/lib/jellyfin/libjemalloc.so.2 ]; then
        export LD_PRELOAD="/usr/lib/jellyfin/libjemalloc.so.2:$LD_PRELOAD"
    fi

    # Optional: let Jellyfin generate a clean network.xml on first run
    # (delete old one if you ever get bind errors)
    if [ ! -f /config/config/network.xml ]; then
        mkdir -p /config/config
    fi

    # Start Jellyfin with proper flags (no more --nonetchange!)
    exec /jellyfin/jellyfin \
        --datadir /config \
        --cachedir /cache \
        --logdir /config/log \
        --webdir /jellyfin/jellyfin-web \
        --httpport "$_PORT" \
        --httpsport 8920
'

exit $?
