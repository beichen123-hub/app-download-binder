#!/system/bin/sh
MODDIR="$(cd "$(dirname "$0")" && pwd)"
PID_FILE="$MODDIR/daemon.pid"

if [ -f "$PID_FILE" ]; then
    OLD_PID="$(cat "$PID_FILE" 2>/dev/null)"
    if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
        kill "$OLD_PID" 2>/dev/null
    fi
    rm -f "$PID_FILE"
fi

. "$MODDIR/common.sh"

# 安全解除所有挂载，并彻底删除模块创建的 /sdcard/Download/应用下载（及旧版残留空目录）
unmount_bind_rules
