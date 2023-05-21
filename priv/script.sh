#!/bin/sh
set -e

SELF=$(readlink "$0" || true)
if [ -z "$SELF" ]; then SELF="$0"; fi
ROOT_DIR="$(CDPATH='' cd "$(dirname "$SELF")/.." && pwd -P)"

NAME=$(basename "$SELF")
CTRL="$ROOT_DIR/bin/.$NAME"

VSN="$(cut -d' ' -f2 "$ROOT_DIR/releases/start_erl.data")"
VSN_DIR="$ROOT_DIR/releases/$VSN"

print_help() {
    echo "
The 'release' commands manage releases, including upgrades and downgrades.
Packaged releases of the form $NAME-<VSN>.tar.gz should be copied to
the 'releases' subdirectory prior to unpacking. These commands are:

    releases       Lists the releases currently known to the system, and their status
    unpack \"VSN\"   Unpacks $NAME-<VSN>.tar.gz
    install \"VSN\"  Installs $NAME-<VSN> and makes it the current version. The version
                   should be committed before the next restart
    commit \"VSN\"   Commits $NAME-<VSN> so it becomes the version that runs on restart
    remove \"VSN\"   Uninstalls $NAME-<VSN> from the system. Must be an old version i.e.
                   neither the current version or the permanent one.

All the release command require that the target system is already running.
" >&2
}

case $1 in
    start|start_iex|daemon|daemon_iex)
        cp $VSN_DIR/build.config $VSN_DIR/sys.config && \
        RELEASE_DISTRIBUTION=none REL_BOOT_SCRIPT=preboot $CTRL eval "Castle.generate(~s($VSN));Castle.make_releases()"
        exec $CTRL "$@"
        ;;
    unpack)
        REL_BOOT_SCRIPT=start_clean $CTRL rpc "Castle.$1(~s($NAME-$2))"
        ;;
    install|commit|remove)
        REL_BOOT_SCRIPT=start_clean $CTRL rpc "Castle.$1(~s($2))"
        ;;
    releases)
        REL_BOOT_SCRIPT=start_clean $CTRL rpc "Castle.$1()"
        ;;
    *)
        $CTRL "$@"
        if [ $# -eq 0 ]; then print_help; fi
        ;;
esac
