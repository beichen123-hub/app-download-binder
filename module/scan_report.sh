#!/system/bin/sh
MODDIR="$(cd "$(dirname "$0")" && pwd)"
. "$MODDIR/common.sh"

REPORT_FILE="$MODDIR/scan_report.txt"
AUTO_APPLY=0
APPLY_MOUNT=0
case "$1" in
    --apply)
        AUTO_APPLY=1
        APPLY_MOUNT=1
        ;;
    --scan-only-apply)
        AUTO_APPLY=1
        APPLY_MOUNT=0
        ;;
esac

echo "========================================="
echo "  全机 App 真实存储路径扫描器 (v3.3.0)"
echo "  作者: KrisWu & Antigravity"
echo "========================================="
echo "[1/3] 正在扫描 Android/data 第三方应用..."

TMP_HITS="$MODDIR/.scan_hits.tmp"
: > "$TMP_HITS"

DATA_ROOT="$BASE/Android/data"
SCANNED_PKGS=0

if [ -d "$DATA_ROOT" ]; then
    for PKG_PATH in "$DATA_ROOT"/*; do
        [ ! -d "$PKG_PATH" ] && continue
        PKG="${PKG_PATH##*/}"
        is_ignored_pkg "$PKG" && continue

        SCANNED_PKGS=$((SCANNED_PKGS + 1))

        case "$PKG" in
            com.tencent.mm)
                if [ -d "$PKG_PATH/MicroMsg/Download" ]; then
                    CNT="$(count_user_files "$PKG_PATH/MicroMsg/Download")"
                    [ "$CNT" -gt 0 ] && printf '%s|%s|%s|%s\n' "$CNT" "微信" "Android/data/com.tencent.mm/MicroMsg/Download" "$(ls "$PKG_PATH/MicroMsg/Download" 2>/dev/null | head -n 1)" >> "$TMP_HITS"
                fi
                continue
                ;;
            com.tencent.wework)
                if [ -d "$PKG_PATH/files/download" ]; then
                    CNT="$(count_user_files "$PKG_PATH/files/download")"
                    [ "$CNT" -gt 0 ] && printf '%s|%s|%s|%s\n' "$CNT" "企业微信" "Android/data/com.tencent.wework/files/download" "$(ls "$PKG_PATH/files/download" 2>/dev/null | head -n 1)" >> "$TMP_HITS"
                fi
                if [ -d "$PKG_PATH/files/filecache" ]; then
                    for _WID in "$PKG_PATH/files/filecache"/*; do
                        [ ! -d "$_WID" ] && continue
                        _WNAME="${_WID##*/}"
                        case "$_WNAME" in
                            ''|*[!0-9]*) continue ;;
                            *)
                                CNT="$(count_user_files "$_WID")"
                                [ "$CNT" -gt 0 ] && printf '%s|%s|%s|%s\n' "$CNT" "企业微信" "Android/data/com.tencent.wework/files/filecache/$_WNAME" "$(ls "$_WID" 2>/dev/null | head -n 1)" >> "$TMP_HITS"
                                ;;
                        esac
                    done
                fi
                continue
                ;;
            org.telegram.messenger|org.telegram.messenger.web|tw.nekomimi.nekogram)
                for _SUB in "files/Telegram/Telegram Files" "files/Telegram/Telegram Documents"; do
                    if [ -d "$PKG_PATH/$_SUB" ]; then
                        CNT="$(count_user_files "$PKG_PATH/$_SUB")"
                        [ "$CNT" -gt 0 ] && printf '%s|%s|%s|%s\n' "$CNT" "$(normalize_app_name "$PKG")" "Android/data/$PKG/$_SUB" "$(ls "$PKG_PATH/$_SUB" 2>/dev/null | head -n 1)" >> "$TMP_HITS"
                    fi
                done
                continue
                ;;
        esac

        # 严格排除缓存、日志、缩略图、更新包、主题、语音缓存等非下载目录
        HITS="$(find "$PKG_PATH" -maxdepth 3 \
            -type d \( -iname '*cache*' -o -iname '*thumb*' -o -iname '*log*' -o -iname '*tmp*' -o -iname '*temp*' -o -iname '*crash*' -o -iname '*avatar*' -o -iname '*sticker*' -o -iname '*emoji*' -o -iname '*image*' -o -iname '*voice*' -o -iname '*sns*' -o -iname '*webview*' -o -iname '*tbs*' -o -iname '*x5*' -o -iname '*appbrand*' -o -iname '*tinker*' -o -iname '*update*' -o -iname '*upgrade*' -o -iname '*theme*' -o -iname '*preprocess*' -o -iname '*asr*' -o -iname '*taolive*' -o -iname '*patch*' -o -iname '*plugin*' -o -iname '.*' \) -prune \
            -o -type f \( -iname '*.pdf' -o -iname '*.doc' -o -iname '*.docx' -o -iname '*.xls' -o -iname '*.xlsx' -o -iname '*.ppt' -o -iname '*.pptx' -o -iname '*.epub' -o -iname '*.zip' -o -iname '*.rar' -o -iname '*.7z' -o -iname '*.apk' -o -iname '*.mp4' -o -iname '*.mkv' -o -iname '*.mp3' -o -iname '*.flac' \) -print 2>/dev/null)"

        if [ -n "$HITS" ]; then
            APP_LABEL="$(normalize_app_name "$PKG")"
            TMP_DIRS="$MODDIR/.scan_pkg_dirs.tmp"
            : > "$TMP_DIRS"
            printf '%s\n' "$HITS" | while IFS= read -r _HP; do
                [ -z "$_HP" ] && continue
                _REL="${_HP#$BASE/}"
                _DIR="${_REL%/*}"
                [ -z "$_DIR" ] && continue
                # 不抓包根目录本身（如 Android/data/com.xxx），只抓子目录，且必须是下载/文档/保存类目录
                [ "$_DIR" = "Android/data/$PKG" ] && continue
                is_junk_path "$_DIR" && continue
                _DIR_LOW="$(printf '%s' "$_DIR" | tr 'A-Z' 'a-z')"
                case "$_DIR_LOW" in
                    *download*|*recv*|*doc*|*file*|*book*|*pan*|*netdisk*|*save*|*export*) ;;
                    *) continue ;;
                esac
                if ! grep -Fqx "$_DIR" "$TMP_DIRS" 2>/dev/null; then
                    printf '%s\n' "$_DIR" >> "$TMP_DIRS"
                    _FN="${_REL##*/}"
                    _CNT="$(count_user_files "$BASE/$_DIR")"
                    [ "$_CNT" -lt 1 ] && _CNT=1
                    printf '%s|%s|%s|%s\n' "$_CNT" "$APP_LABEL" "$_DIR" "$_FN" >> "$TMP_HITS"
                fi
            done
            rm -f "$TMP_DIRS"
        fi
    done
fi
echo "  已扫描 ${SCANNED_PKGS} 个第三方应用。"

echo "[2/3] 正在扫描公共存储目录 (Download / DCIM / Pictures)..."
for PUB_PARENT in "Download" "DCIM" "Pictures"; do
    P_FULL="$BASE/$PUB_PARENT"
    [ ! -d "$P_FULL" ] && continue
    for SUB in "$P_FULL"/*; do
        [ ! -d "$SUB" ] && continue
        SNAME="${SUB##*/}"
        _SUB_REL="$PUB_PARENT/$SNAME"
        case "$_SUB_REL" in
            Download/应用下载|Download/app|Download/App|*/.*) continue ;;
        esac
        is_junk_path "$_SUB_REL" && continue

        CNT="$(count_user_files "$SUB")"
        if [ "$CNT" -gt 0 ]; then
            SAMPLE="$(ls "$SUB" 2>/dev/null | head -n 1)"
            APP_LABEL="$(normalize_app_name "$SNAME")"
            printf '%s|%s|%s|%s\n' "$CNT" "$APP_LABEL" "$_SUB_REL" "$SAMPLE" >> "$TMP_HITS"
        fi
    done
done

echo "[3/3] 正在生成报告..."
{
    echo "# ========================================================="
    echo "# 全机 App 真实存储路径扫描报告 (v3.2.0)"
    echo "# 作者: KrisWu & Antigravity"
    echo "# 扫描时间: $(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)"
    echo "# 说明: 未识别出中文名的包名不会自动挂载，如需使用请手动改为中文名复制到 $CONF"
    echo "# ========================================================="
    echo ""
} > "$REPORT_FILE"

SORTED="$MODDIR/.scan_sorted.tmp"
sort -t'|' -k1,1nr "$TMP_HITS" 2>/dev/null > "$SORTED"

TOTAL_FOUND=0
NEW_UNCONFIGURED=0

echo "-----------------------------------------"
while IFS='|' read -r CNT PKG_OR_NAME REL_DIR SAMPLE_FILE; do
    [ -z "$REL_DIR" ] && continue
    TOTAL_FOUND=$((TOTAL_FOUND + 1))

    if rule_exists_in_conf "$REL_DIR"; then
        STATUS="已配置"
    elif is_raw_pkg_name "$PKG_OR_NAME"; then
        STATUS="未识别包名(跳过自动挂载)"
    else
        STATUS="未配置"
        NEW_UNCONFIGURED=$((NEW_UNCONFIGURED + 1))
    fi

    LINE_RULE="$PKG_OR_NAME|$REL_DIR"
    {
        echo "# [$STATUS] 命中 ${CNT} 个文件 (示例: $SAMPLE_FILE)"
        if [ "$STATUS" = "未配置" ]; then
            echo "$LINE_RULE"
        else
            echo "# $LINE_RULE"
        fi
    } >> "$REPORT_FILE"

    echo "[$STATUS] (${CNT}项) [$PKG_OR_NAME] $REL_DIR"

    if [ "$AUTO_APPLY" = "1" ] && [ "$STATUS" = "未配置" ]; then
        append_auto_rule "$PKG_OR_NAME" "$REL_DIR" 1
    fi
done < "$SORTED"

rm -f "$TMP_HITS" "$SORTED"

echo "-----------------------------------------"
echo "扫描完成：共发现 ${TOTAL_FOUND} 个目录（其中可自动挂载的新目录 ${NEW_UNCONFIGURED} 个）"
echo "完整报告已保存: $REPORT_FILE"
if [ "$APPLY_MOUNT" = "1" ]; then
    echo "正在自动应用并挂载全部规则..."
    apply_bind_rules 1
elif [ "$AUTO_APPLY" = "1" ]; then
    echo "新发现的规则已写入 $CONF，重启解锁手机后将自动挂载生效。"
else
    echo "提示: 如需把上面 [未配置] 全部自动加入并挂载，直接运行 一键扫描并重载挂载.sh"
fi
echo "========================================="
