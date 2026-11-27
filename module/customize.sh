#!/system/bin/sh

ui_print "========================================="
ui_print "  App Download Binder v3.2.0"
ui_print "  作者: KrisWu & Antigravity"
ui_print "  适配: KernelSU / APatch / Magisk"
ui_print "========================================="
ui_print "  规则库引用:"
ui_print "  - Kindness-Net/storage-redirection-x-rules"
ui_print "  - RikkaApps/StorageRedirect-assets"
ui_print "  参考思路:"
ui_print "  - Kindness-Kismet/storage-redirection-x"
ui_print "  - Third_Party_Redirect"
ui_print "========================================="

wait_volume_key() {
    if ! command -v getevent >/dev/null 2>&1; then
        ui_print "- 未检测到 getevent，默认选择【音量上键 (+)】..."
        return 0
    fi
    while true; do
        KEY_EVT="$(getevent -lqc 1 2>/dev/null | grep -E 'KEY_VOLUMEUP|KEY_VOLUMEDOWN' | grep 'DOWN')"
        case "$KEY_EVT" in
            *KEY_VOLUMEUP*) return 0 ;;
            *KEY_VOLUMEDOWN*) return 1 ;;
        esac
    done
}

# 第一步：风险警告确认
ui_print ""
ui_print "【步骤 1/2：重要警告 / 安装前请确认】"
ui_print "1. 本模块使用 mount --bind 底层映射，不复制、不双倍占空间。"
ui_print "2. 映射目录与原目录指向同一份文件：在 /sdcard/Download/应用下载/"
ui_print "   中删除文件会同步删除 App 原目录里的文件，请谨慎操作！"
ui_print "3. 覆盖更新或卸载时会自动安全解除挂载并清理映射目录，绝不误删原文件。"
ui_print ""
ui_print ">>> 按【音量上键 (+)】确认继续安装"
ui_print ">>> 按【音量下键 (-)】取消安装"

if wait_volume_key; then
    ui_print "- 已确认继续安装。"
else
    ui_print "- 用户已取消安装。"
    abort "! 安装已取消"
fi

# 第二步：选择运行模式
ui_print ""
ui_print "【步骤 2/2：请选择初始规则模式】"
ui_print ">>> 按【音量上键 (+)】全自动模式（扫描本机已知中文名 App 真实目录并加入规则）"
ui_print ">>> 按【音量下键 (-)】标准模式（仅启用默认 + 内置 235 条开源规则库，最清爽）"

FULL_SCAN_ON_INSTALL=0
if wait_volume_key; then
    FULL_SCAN_ON_INSTALL=1
    ui_print "- 已选择：【全自动扫描模式】"
else
    FULL_SCAN_ON_INSTALL=0
    ui_print "- 已选择：【标准规则库模式】"
fi

ui_print ""
ui_print "- 正在安全清理旧版本残留的映射目录（绝不删原文件）..."
MODDIR="$MODPATH"
. "$MODPATH/common.sh"

safe_unmount_and_clean_root "Download/app"
safe_unmount_and_clean_root "Download/App"
safe_unmount_and_clean_root "Download/应用下载"

for _OLD_NAME in "微信" "QQ" "企业微信" "Telegram"; do
    _OLD_D="$BASE/Download/$_OLD_NAME"
    if [ -d "$_OLD_D" ] && is_mounted "$_OLD_D"; then
        run_global umount -l "$_OLD_D" 2>/dev/null
        safe_remove_empty_mountpoint "$_OLD_D"
    fi
done
rm -f "$BASE/Download/AppBindRules.conf" 2>/dev/null

# 升级清洗：自动清理旧配置里误扫的 com.xxx.xxx 包名、系统相册、更新包及大小写重复项
OLD_CONF="/data/adb/modules/app_download_binder/rules.conf"
if [ -s "$OLD_CONF" ]; then
    cp -f "$MODPATH/default_rules.conf" "$MODPATH/rules.conf"
    while IFS= read -r _RAW || [ -n "$_RAW" ]; do
        _L="$(printf '%s' "$_RAW" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        [ -z "$_L" ] && continue
        case "$_L" in
            \#*|AUTO_SCAN=*|SCAN_INTERVAL_HOURS=*|SKIP_EMPTY=*) continue ;;
        esac
        _P="${_L%%|*}"
        _O="${_L#*|}"
        [ "$_P" = "$_L" ] || [ -z "$_P" ] || [ -z "$_O" ] && continue

        # 过滤旧版误扫的垃圾目录（更新包/系统相机/录屏等）
        is_junk_path "$_O" && continue

        # 统一规范为 Download/应用下载/<中文名>
        _APP="${_P##*/}"
        _APP="$(normalize_app_name "$_APP")"
        # 丢弃未识别的原始 com.xxx.xxx 包名目录
        is_raw_pkg_name "$_APP" && continue

        append_auto_rule "$OUT_ROOT/$_APP" "$_O" 0
    done < "$OLD_CONF"
    ui_print "- 已清洗并迁移旧配置（移除误扫的包名与系统垃圾目录，统一转为中文名）"
else
    cp -f "$MODPATH/default_rules.conf" "$MODPATH/rules.conf"
    ui_print "- 已生成默认配置: /data/adb/modules/app_download_binder/rules.conf"
fi

if [ ! -s "$MODPATH/rules.conf" ]; then
    cp -f "$MODPATH/default_rules.conf" "$MODPATH/rules.conf"
fi

set_perm "$MODPATH/rules.conf" 0 0 0644
set_perm "$MODPATH/builtin_rules.db" 0 0 0644
set_perm "$MODPATH/common.sh" 0 0 0755
set_perm "$MODPATH/scan_report.sh" 0 0 0755
set_perm "$MODPATH/一键扫描并重载挂载.sh" 0 0 0755
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/action.sh" 0 0 0755
set_perm "$MODPATH/uninstall.sh" 0 0 0755

if [ "$FULL_SCAN_ON_INSTALL" = "1" ]; then
    ui_print "- 正在执行首次全机扫描并写入 rules.conf..."
    sh "$MODPATH/scan_report.sh" --scan-only-apply 2>&1 | while IFS= read -r _L; do
        ui_print "  $_L"
    done
fi

DB_CNT="$(grep -cv '^[[:space:]]*\(#\|$\)' "$MODPATH/builtin_rules.db" 2>/dev/null || echo 0)"
ui_print ""
ui_print "- 内置规则库: ${DB_CNT} 条（一软件一中文文件夹，绝不生成 com.xxx 包名）"
ui_print "- 归类总目录: /sdcard/Download/应用下载/<软件名>"
ui_print "- 重启手机并在解锁桌面后约 3 秒即会自动生成全部文件夹！"
