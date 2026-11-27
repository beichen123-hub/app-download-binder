#!/system/bin/sh

ui_print "========================================="
ui_print "  App Download Binder v3.3.0"
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
        KEY_EVT="$(getevent -lqc 1 2>/dev/null)"
        if printf '%s\n' "$KEY_EVT" | grep -Eq 'KEY_VOLUMEUP[[:space:]]+DOWN'; then
            sleep 0.4 2>/dev/null || sleep 1
            return 0
        elif printf '%s\n' "$KEY_EVT" | grep -Eq 'KEY_VOLUMEDOWN[[:space:]]+DOWN'; then
            sleep 0.4 2>/dev/null || sleep 1
            return 1
        fi
    done
}

# 步骤 1/3：风险警告确认
ui_print ""
ui_print "【步骤 1/3：重要警告 / 安装前请确认】"
ui_print "1. 本模块使用 mount --bind 底层映射，不复制、不双倍占空间。"
ui_print "2. 映射目录与原目录指向同一份文件：在映射文件夹中删除文件"
ui_print "   会同步删除 App 原目录里的文件，请谨慎操作！"
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

# 步骤 2/3：选择目录层级结构（1级平铺 / 2级收纳 / 3级分类）
ui_print ""
ui_print "【步骤 2/3：请选择文件夹层级结构】"
ui_print ">>> 按【音量上键 (+)】分级收纳在 Download/应用下载/ 下（推荐，防相册重复更彻底）"
ui_print ">>> 按【音量下键 (-)】一级平铺：直接映射在 Download/<软件名>/ 下"

CHOSEN_LAYOUT=2
if wait_volume_key; then
    ui_print ""
    ui_print "【步骤 2b：选择收纳层级】"
    ui_print ">>> 按【音量上键 (+)】二级收纳：Download/应用下载/<软件名>/（简洁推荐）"
    ui_print ">>> 按【音量下键 (-)】三级分类：Download/应用下载/<分类>/<软件名>/（社交/网盘/浏览器/影音...）"
    if wait_volume_key; then
        CHOSEN_LAYOUT=2
        ui_print "- 已选择：【二级收纳】/sdcard/Download/应用下载/<软件名>/"
    else
        CHOSEN_LAYOUT=3
        ui_print "- 已选择：【三级分类】/sdcard/Download/应用下载/<分类>/<软件名>/"
    fi
else
    CHOSEN_LAYOUT=1
    ui_print "- 已选择：【一级平铺】/sdcard/Download/<软件名>/"
fi

# 步骤 3/3：选择初始规则扫描模式
ui_print ""
ui_print "【步骤 3/3：请选择初始规则模式】"
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

# 先用旧模块的 mounted_paths.list 精准清理旧挂载点（兼容从一级/二级/三级任意模式切换）
OLD_MLIST="/data/adb/modules/app_download_binder/mounted_paths.list"
if [ -f "$OLD_MLIST" ]; then
    MOUNTED_LIST="$OLD_MLIST"
    unmount_recorded_paths
    MOUNTED_LIST="$MODDIR/mounted_paths.list"
fi
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

# 写入配置并应用本次选择的 LAYOUT_MODE
sed "s|^LAYOUT_MODE=.*|LAYOUT_MODE=$CHOSEN_LAYOUT|" "$MODPATH/default_rules.conf" > "$MODPATH/rules.conf"

OLD_CONF="/data/adb/modules/app_download_binder/rules.conf"
if [ -s "$OLD_CONF" ]; then
    while IFS= read -r _RAW || [ -n "$_RAW" ]; do
        _L="$(printf '%s' "$_RAW" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        [ -z "$_L" ] && continue
        case "$_L" in
            \#*|LAYOUT_MODE=*|AUTO_SCAN=*|SCAN_INTERVAL_HOURS=*|SKIP_EMPTY=*) continue ;;
        esac
        _P="${_L%%|*}"
        _O="${_L#*|}"
        [ "$_P" = "$_L" ] || [ -z "$_P" ] || [ -z "$_O" ] && continue

        is_junk_path "$_O" && continue
        _APP="$(normalize_app_name "${_P##*/}")"
        is_raw_pkg_name "$_APP" && continue

        append_auto_rule "$_APP" "$_O" 0
    done < "$OLD_CONF"
    ui_print "- 已清洗并迁移原有自定义规则至新层级模式 (LAYOUT_MODE=$CHOSEN_LAYOUT)"
else
    ui_print "- 已生成默认配置: /data/adb/modules/app_download_binder/rules.conf"
fi

if [ ! -s "$MODPATH/rules.conf" ]; then
    sed "s|^LAYOUT_MODE=.*|LAYOUT_MODE=$CHOSEN_LAYOUT|" "$MODPATH/default_rules.conf" > "$MODPATH/rules.conf"
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
case "$CHOSEN_LAYOUT" in
    1) ui_print "- 当前模式: 一级平铺 -> /sdcard/Download/<软件名>/" ;;
    3) ui_print "- 当前模式: 三级分类 -> /sdcard/Download/应用下载/<分类>/<软件名>/" ;;
    *) ui_print "- 当前模式: 二级收纳 -> /sdcard/Download/应用下载/<软件名>/" ;;
esac
ui_print "- 重启手机并在解锁桌面后约 3 秒即会自动生成全部文件夹！"
