#!/system/bin/sh
MODDIR="$(cd "$(dirname "$0")" && pwd)"
PID_FILE="$MODDIR/daemon.pid"

export PATH="/data/adb/ksu/bin:/data/adb/ap/bin:/data/adb/magisk:/system/bin:/vendor/bin:$PATH"

# 1. 等待系统启动完成
while [ "$(getprop sys.boot_completed)" != "1" ]; do
    sleep 2
done

# 2. 等待用户解锁屏幕且 /storage/emulated/0 (FUSE) 真正可读写（避免提前挂载失效）
TEST_FILE="/storage/emulated/0/Android/.adb_binder_rw_test"
while true; do
    if [ -d "/data/media/0/Download" ] && [ -d "/storage/emulated/0/Android" ]; then
        if touch "$TEST_FILE" 2>/dev/null; then
            rm -f "$TEST_FILE" 2>/dev/null
            break
        fi
    fi
    sleep 2
done

# 再稍等 3 秒确保 MediaProvider / FUSE 完全稳定
sleep 3

. "$MODDIR/common.sh"

log_msg "[BOOT] 存储已解锁并可读写，开始开机自动挂载..."
scan_new_apps 0
apply_bind_rules 0
log_msg "[BOOT] 开机自动挂载流程结束"

# 若已有旧守护进程，先清理防止重复
if [ -f "$PID_FILE" ]; then
    OLD_PID="$(cat "$PID_FILE" 2>/dev/null)"
    if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
        kill "$OLD_PID" 2>/dev/null
    fi
fi

# 后台轻量定时检测循环（每小时醒来比对时间戳，满设定小时数自动扫描并挂载）
(
    while true; do
        sleep 3600
        load_settings
        if [ "$AUTO_SCAN" = "1" ]; then
            INTERVAL_SEC=$((SCAN_INTERVAL_HOURS * 3600))
            NOW="$(date +%s 2>/dev/null || echo 0)"
            LAST="$(cat "$LAST_SCAN_FILE" 2>/dev/null || echo 0)"
            if [ "$NOW" -gt 0 ] && [ $((NOW - LAST)) -ge "$INTERVAL_SEC" ]; then
                scan_new_apps 0
                apply_bind_rules 0
            fi
        fi
    done
) >/dev/null 2>&1 &

echo "$!" > "$PID_FILE"
