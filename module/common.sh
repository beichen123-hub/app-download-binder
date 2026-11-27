#!/system/bin/sh

# 兼容 KernelSU / KernelSU Next / APatch / Magisk 的工具链 PATH
export PATH="/data/adb/ksu/bin:/data/adb/ap/bin:/data/adb/magisk:/system/bin:/vendor/bin:$PATH"

BASE="/data/media/0"
FUSE_BASE="/storage/emulated/0"
OUT_ROOT="Download/应用下载"

CONF="$MODDIR/rules.conf"
BUILTIN_DB="$MODDIR/builtin_rules.db"
LOG_FILE="$MODDIR/bind.log"
LAST_SCAN_FILE="$MODDIR/last_scan.ts"
PROP_FILE="$MODDIR/module.prop"

AUTO_SCAN=1
SCAN_INTERVAL_HOURS=24

run_global() {
    if command -v nsenter >/dev/null 2>&1; then
        nsenter -t 1 -m -- "$@"
    else
        "$@"
    fi
}

log_msg() {
    TS="$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo 'boot')"
    echo "[$TS] $1" >> "$LOG_FILE"
}

trim_log() {
    if [ -f "$LOG_FILE" ]; then
        LINES="$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)"
        if [ "$LINES" -gt 500 ]; then
            tail -n 300 "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
        fi
    fi
}

update_module_desc() {
    STATUS_TEXT="$1"
    [ ! -f "$PROP_FILE" ] && return
    NOW_STR="$(date '+%m-%d %H:%M' 2>/dev/null || echo 'ok')"
    DB_CNT="$(grep -cv '^[[:space:]]*\(#\|$\)' "$BUILTIN_DB" 2>/dev/null || echo 0)"
    NEW_DESC="[$STATUS_TEXT | 规则库:${DB_CNT}条 | $NOW_STR] 目录:/sdcard/$OUT_ROOT/ | 作者:KrisWu & Antigravity"
    sed "s|^description=.*|description=$NEW_DESC|" "$PROP_FILE" > "${PROP_FILE}.tmp" 2>/dev/null && mv "${PROP_FILE}.tmp" "$PROP_FILE"
}

is_fuse_storage() {
    run_global grep -Eq ' /storage/emulated(/0)? fuse ' /proc/mounts 2>/dev/null
}

ensure_conf() {
    if [ ! -s "$CONF" ]; then
        cp -f "$MODDIR/default_rules.conf" "$CONF"
        chmod 644 "$CONF" 2>/dev/null
    fi
}

load_settings() {
    ensure_conf
    AUTO_SCAN=1
    SCAN_INTERVAL_HOURS=24
    while IFS= read -r RAW_LINE || [ -n "$RAW_LINE" ]; do
        LINE="$(printf '%s' "$RAW_LINE" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        case "$LINE" in
            AUTO_SCAN=*)
                VAL="${LINE#AUTO_SCAN=}"
                [ "$VAL" = "0" ] && AUTO_SCAN=0 || AUTO_SCAN=1
                ;;
            SCAN_INTERVAL_HOURS=*)
                VAL="${LINE#SCAN_INTERVAL_HOURS=}"
                case "$VAL" in
                    ''|*[!0-9]*) ;;
                    *) [ "$VAL" -ge 1 ] && SCAN_INTERVAL_HOURS="$VAL" ;;
                esac
                ;;
        esac
    done < "$CONF"
}

is_mounted() {
    TARGET_ESC="$(printf '%s' "$1" | sed 's/ /\\040/g')"
    run_global grep -Fq " $TARGET_ESC " /proc/mounts 2>/dev/null
}

count_user_files() {
    [ ! -d "$1" ] && echo 0 && return
    _CNT=0
    for _F in "$1"/*; do
        [ ! -e "$_F" ] && continue
        _NAME="$(basename "$_F")"
        case "$_NAME" in
            .*|*.log|*.LOG|*.tmp|*.TMP|*.temp|*.TEMP|*.bak|*.cache|*.thumb|*.thumbs|*.db|*.db-*|*.journal|*.lock|cache|Cache|CACHE|log|logs|Log|Logs|LOG|tmp|temp|Temp|TMP|thumb|thumbs|thumbnail|thumbnails|Thumbnails)
                continue
                ;;
        esac
        _CNT=$((_CNT + 1))
    done
    echo "$_CNT"
}

dir_has_user_files() {
    [ "$(count_user_files "$1")" -gt 0 ]
}

# 判断是否属于缓存、日志、缩略图、更新包、系统相册等非用户下载路径
is_junk_path() {
    _LOWER="$(printf '%s' "$1" | tr 'A-Z' 'a-z')"
    case "$_LOWER" in
        *cache*|*log*|*thumb*|*temp*|*/tmp*|*sticker*|*avatar*|*emoji*|*voice*|\
        *update*|*upgrade*|*preprocess*|*/asr*|*taolive*|*theme*|*patch*|*plugin*|*webview*|\
        pictures/camera|dcim/camera|pictures/screenshots|dcim/screenshots|dcim/screenrecorder|\
        pictures/gallery|dcim/restored|dcim/sdp|pictures/wv_save_image)
            # 唯一例外：企业微信的文件存放在 files/filecache/<纯数字ID>
            case "$_LOWER" in
                android/data/com.tencent.wework/files/filecache/*) return 1 ;;
            esac
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# 判断名称是否为原始安卓包名（如 com.xxx.yyy / cn.xxx.yyy），防止出现在文件夹中
is_raw_pkg_name() {
    _LOWER="$(printf '%s' "$1" | tr 'A-Z' 'a-z')"
    case "$_LOWER" in
        com.*.*|cn.*.*|org.*.*|net.*.*|tv.*.*|me.*.*|io.*.*|app.*.*|jp.*.*|tw.*.*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# 大小写不敏感地把常见英文目录名或包名归一化为统一中文软件名，确保一软件一文件夹
normalize_app_name() {
    _LOW="$(printf '%s' "$1" | tr 'A-Z' 'a-z')"
    case "$_LOW" in
        weixin|wechat|com.tencent.mm|微信|微信保存|微信图片视频|微信-隔离) echo "微信" ;;
        qq|com.tencent.mobileqq|com.tencent.qqlite|qqlite|qqkddi|tencent|qq保存|qq-隔离) echo "QQ" ;;
        tim|com.tencent.tim|tim-隔离) echo "TIM" ;;
        weixinwork|wecom|com.tencent.wework|企业微信|企业微信保存) echo "企业微信" ;;
        telegram|org.telegram.messenger|org.telegram.messenger.web|telegram文档|telegram-web|telegram-web文档|telegram保存) echo "Telegram" ;;
        nekogram|tw.nekomimi.nekogram|nekogram文档) echo "Nekogram" ;;
        nekox|nekox.messenger) echo "NekoX" ;;
        dingtalk|com.alibaba.android.rimet|钉钉) echo "钉钉" ;;
        lark|com.ss.android.lark|飞书) echo "飞书" ;;
        quark|com.quark.browser|夸克) echo "夸克" ;;
        baidunetdisk|bdy_download|com.baidu.netdisk|百度网盘) echo "百度网盘" ;;
        aliyundrive|aliyunpan|com.alicloud.databox|阿里云盘) echo "阿里云盘" ;;
        thunder|com.xunlei.downloadprovider|迅雷) echo "迅雷" ;;
        115|115download|com.ylmf.androidclient|115网盘) echo "115网盘" ;;
        weiyun|com.qq.qcloud|腾讯微云) echo "腾讯微云" ;;
        tencentdocs|com.tencent.docs|腾讯文档) echo "腾讯文档" ;;
        qqbrowser|com.tencent.mtt|qq浏览器) echo "QQ浏览器" ;;
        ucdownloads|ucmobile|com.ucmobile|com.ucmobile.lite|uc浏览器) echo "UC浏览器" ;;
        coolmarket|com.coolapk.market|酷安) echo "酷安" ;;
        tv.danmaku.bili|bilibili|哔哩哔哩) echo "哔哩哔哩" ;;
        com.xingin.xhs|xhs|小红书) echo "小红书" ;;
        douyin|抖音图片|com.ss.android.ugc.aweme|抖音) echo "抖音" ;;
        kuaishou|com.smile.gifmaker|快手) echo "快手" ;;
        zhihu|com.zhihu.android|知乎) echo "知乎" ;;
        weibo|com.sina.weibo|微博) echo "微博" ;;
        alipay|com.eg.android.alipaygphone|支付宝) echo "支付宝" ;;
        jdimage|com.jingdong.app.mall|京东) echo "京东" ;;
        pindd|com.xunmeng.pinduoduo|拼多多) echo "拼多多" ;;
        taobao|com.taobao.taobao|淘宝) echo "淘宝" ;;
        bosszhipin|com.hpbr.bosszhipin|boss直聘) echo "BOSS直聘" ;;
        mishare|小米互传) echo "小米互传" ;;
        insta360download|insta360|影石*) echo "影石Insta360" ;;
        miwatch|小米手表) echo "小米手表" ;;
        gcam|agc.*|谷歌相机) echo "谷歌相机" ;;
        myapp|com.tencent.android.qqdownloader|应用宝) echo "应用宝" ;;
        paintpad|画板) echo "画板" ;;
        com.greenpoint.android.mc10086.activity|中国移动) echo "中国移动" ;;
        com.cainiao.wireless|菜鸟) echo "菜鸟" ;;
        com.mi.health|小米运动健康) echo "小米运动健康" ;;
        com.omarea.vtools|scene) echo "Scene" ;;
        com.sup.android.superb|pipixia|皮皮虾) echo "皮皮虾" ;;
        neteasedj|com.netease.cloudmusic|网易云音乐) echo "网易云音乐" ;;
        qqmusic|com.tencent.qqmusic|qq音乐) echo "QQ音乐" ;;
        com.kugou.android|酷狗音乐) echo "酷狗音乐" ;;
        kuwo|cn.kuwo.player|酷我音乐) echo "酷我音乐" ;;
        *) echo "$1" ;;
    esac
}

extract_pkg_root() {
    REL="$1"
    _LOW="$(printf '%s' "$REL" | tr 'A-Z' 'a-z')"
    case "$_LOW" in
        android/data/*)
            REST="${REL#Android/data/}"
            PKG="${REST%%/*}"
            [ -n "$PKG" ] && echo "$BASE/Android/data/$PKG"
            ;;
        android/media/*)
            REST="${REL#Android/media/}"
            PKG="${REST%%/*}"
            [ -n "$PKG" ] && echo "$BASE/Android/media/$PKG"
            ;;
        android/obb/*)
            REST="${REL#Android/obb/}"
            PKG="${REST%%/*}"
            [ -n "$PKG" ] && echo "$BASE/Android/obb/$PKG"
            ;;
        download/weixin|pictures/weixin)
            echo "$BASE/Android/data/com.tencent.mm"
            ;;
        download/qq)
            echo "$BASE/Android/data/com.tencent.mobileqq"
            ;;
        download/wecom|dcim/weixinwork)
            echo "$BASE/Android/data/com.tencent.wework"
            ;;
        download/telegram)
            if [ -d "$BASE/Android/data/org.telegram.messenger" ]; then
                echo "$BASE/Android/data/org.telegram.messenger"
            else
                echo "$BASE/Android/data/org.telegram.messenger.web"
            fi
            ;;
        *)
            echo ""
            ;;
    esac
}

make_sub_label() {
    _ORIG="$1"
    _LOW="$(printf '%s' "$_ORIG" | tr 'A-Z' 'a-z')"
    case "$_LOW" in
        pictures/*|dcim/*) echo "图片视频" ;;
        download/*) echo "保存" ;;
        *micromsg/download) echo "文件" ;;
        *qqfile_recv|*timfile_recv) echo "文件" ;;
        *wework/files/filecache*) echo "文件" ;;
        *telegram\ files) echo "文件" ;;
        *telegram\ documents) echo "文档" ;;
        */sdcard/*) echo "隔离目录" ;;
        *)
            _BN="$(basename "$_ORIG")"
            [ -n "$_BN" ] && echo "$_BN" || echo "下载"
            ;;
    esac
}

# 大小写不敏感检查规则是否已存在于配置文件（修复 DCIM/WeiXinWork 与 DCIM/WeixinWork 重复问题）
rule_exists_in_conf() {
    DST_CHECK="$1"
    tr -d '\r' < "$CONF" | grep -Fiq "|$DST_CHECK"
}

append_auto_rule() {
    PUB_REL="$1"
    ORIG_REL="$2"
    VERBOSE="$3"

    if rule_exists_in_conf "$ORIG_REL"; then
        return 1
    fi

    printf '%s|%s\n' "$PUB_REL" "$ORIG_REL" >> "$CONF"
    chmod 644 "$CONF" 2>/dev/null

    log_msg "[自动发现] 新增规则: $PUB_REL <- $ORIG_REL"
    [ "$VERBOSE" = "1" ] && echo "[自动发现] + $PUB_REL <- $ORIG_REL"
    return 0
}

is_ignored_pkg() {
    case "$1" in
        android|com.android.*|com.google.android.*|com.miui.*|com.xiaomi.*|com.oplus.*|com.coloros.*|com.oppo.*|com.vivo.*|com.bbk.*|com.huawei.*|com.hihonor.*|com.samsung.*|com.sec.*|com.qualcomm.*|com.mediatek.*|org.lineageos.*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

scan_new_apps() {
    VERBOSE="$1"
    load_settings

    if [ "$AUTO_SCAN" != "1" ]; then
        log_msg "[自动检测] 已关闭 (AUTO_SCAN=0)"
        [ "$VERBOSE" = "1" ] && echo "[自动检测] 已在配置中关闭 (AUTO_SCAN=0)"
        return
    fi

    DB_CNT="$(grep -cv '^[[:space:]]*\(#\|$\)' "$BUILTIN_DB" 2>/dev/null || echo 0)"
    log_msg "[自动检测] 开始扫描（内置规则库 ${DB_CNT} 条）..."
    [ "$VERBOSE" = "1" ] && echo "[自动检测] 正在匹配内置规则库 (${DB_CNT} 条) 与本机应用..."

    if [ -f "$BUILTIN_DB" ]; then
        while IFS= read -r RAW_ENTRY || [ -n "$RAW_ENTRY" ]; do
            ENTRY="$(printf '%s' "$RAW_ENTRY" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
            [ -z "$ENTRY" ] && continue
            case "$ENTRY" in
                \#*) continue ;;
            esac
            APP_NAME="$(normalize_app_name "${ENTRY%%|*}")"
            ORIG_REL="${ENTRY#*|}"
            [ -z "$APP_NAME" ] || [ -z "$ORIG_REL" ] && continue
            is_raw_pkg_name "$APP_NAME" && continue

            ORIG_FULL="$BASE/$ORIG_REL"
            if [ -d "$ORIG_FULL" ] && dir_has_user_files "$ORIG_FULL"; then
                append_auto_rule "$OUT_ROOT/$APP_NAME" "$ORIG_REL" "$VERBOSE"
            fi
        done < "$BUILTIN_DB"
    fi

    # 企业微信特殊适配：自动识别 files/filecache/<纯数字账号ID>
    WECOM_FC="$BASE/Android/data/com.tencent.wework/files/filecache"
    if [ -d "$WECOM_FC" ]; then
        for _WID in "$WECOM_FC"/*; do
            [ ! -d "$_WID" ] && continue
            _WNAME="$(basename "$_WID")"
            case "$_WNAME" in
                ''|*[!0-9]*) continue ;;
                *)
                    append_auto_rule "$OUT_ROOT/企业微信" "Android/data/com.tencent.wework/files/filecache/$_WNAME" "$VERBOSE"
                    ;;
            esac
        done
    fi

    # 通用启发式扫描：仅自动添加能映射出友好中文名/品牌名的 App，绝不自动生成 com.xxx.xxx 文件夹
    DATA_ROOT="$BASE/Android/data"
    if [ -d "$DATA_ROOT" ]; then
        for PKG_PATH in "$DATA_ROOT"/*; do
            [ ! -d "$PKG_PATH" ] && continue
            PKG="$(basename "$PKG_PATH")"
            is_ignored_pkg "$PKG" && continue
            case "$PKG" in
                org.telegram.*|tw.nekomimi.nekogram|nekox.messenger|org.thunderdog.challegram) continue ;;
            esac

            APP_LABEL="$(normalize_app_name "$PKG")"
            is_raw_pkg_name "$APP_LABEL" && continue

            for CANDIDATE in "files/Download" "files/Downloads" "files/download" "files/downloads" "Download" "Downloads" "download"; do
                CAND_FULL="$PKG_PATH/$CANDIDATE"
                ORIG_REL="Android/data/$PKG/$CANDIDATE"
                is_junk_path "$ORIG_REL" && continue
                if [ -d "$CAND_FULL" ] && dir_has_user_files "$CAND_FULL"; then
                    append_auto_rule "$OUT_ROOT/$APP_LABEL" "$ORIG_REL" "$VERBOSE"
                    break
                fi
            done
        done
    fi

    date +%s > "$LAST_SCAN_FILE" 2>/dev/null
    log_msg "[自动检测] 扫描完成"
    [ "$VERBOSE" = "1" ] && echo "[自动检测] 完成（每 ${SCAN_INTERVAL_HOURS} 小时自动扫描一次）"
}

safe_remove_empty_mountpoint() {
    DIR_PATH="$1"
    if [ -d "$DIR_PATH" ] && ! is_mounted "$DIR_PATH"; then
        rmdir "$DIR_PATH" 2>/dev/null
    fi
}

safe_unmount_and_clean_root() {
    ROOT_REL="$1"
    ROOT_LOWER="$BASE/$ROOT_REL"
    ROOT_FUSE="$FUSE_BASE/$ROOT_REL"

    if [ -d "$ROOT_FUSE" ]; then
        for _FD in "$ROOT_FUSE"/*; do
            [ ! -d "$_FD" ] && continue
            for _FSD in "$_FD"/*; do
                [ ! -d "$_FSD" ] && continue
                is_mounted "$_FSD" && run_global umount -l "$_FSD" 2>/dev/null
            done
            is_mounted "$_FD" && run_global umount -l "$_FD" 2>/dev/null
        done
    fi

    if [ -d "$ROOT_LOWER" ]; then
        for _D in "$ROOT_LOWER"/*; do
            [ ! -d "$_D" ] && continue
            for _SD in "$_D"/*; do
                [ ! -d "$_SD" ] && continue
                is_mounted "$_SD" && run_global umount -l "$_SD" 2>/dev/null
                safe_remove_empty_mountpoint "$_SD"
            done
            is_mounted "$_D" && run_global umount -l "$_D" 2>/dev/null
            safe_remove_empty_mountpoint "$_D"
        done
        rm -f "$ROOT_LOWER/AppBindRules.conf" "$ROOT_LOWER/.nomedia" 2>/dev/null
        safe_remove_empty_mountpoint "$ROOT_LOWER"
    fi
}

mount_single_target() {
    ORIG_LOWER="$1"
    TARGET_REL="$2"
    ORIG_REL="$3"
    VERBOSE="$4"

    TARGET_LOWER="$BASE/$TARGET_REL"
    TARGET_FUSE="$FUSE_BASE/$TARGET_REL"
    F_CNT="$(count_user_files "$ORIG_LOWER")"

    if is_mounted "$TARGET_LOWER"; then
        log_msg "[已挂载] $TARGET_REL <- $ORIG_REL (文件数: $F_CNT)"
        [ "$VERBOSE" = "1" ] && echo "[已生效] $TARGET_REL (文件数: $F_CNT)"
        MOUNTED_COUNT=$((MOUNTED_COUNT + 1))
        return 0
    fi

    mkdir -p "$TARGET_LOWER"
    chown media_rw:media_rw "$TARGET_LOWER" 2>/dev/null
    chmod 770 "$TARGET_LOWER" 2>/dev/null

    ERR_OUT="$(run_global mount --bind "$ORIG_LOWER" "$TARGET_LOWER" 2>&1)"
    if [ $? -eq 0 ]; then
        if [ "$USE_FUSE" = "0" ] && [ -d "$FUSE_BASE" ] && ! is_mounted "$TARGET_FUSE"; then
            mkdir -p "$TARGET_FUSE" 2>/dev/null
            run_global mount --bind "$ORIG_LOWER" "$TARGET_FUSE" 2>/dev/null
        fi
        log_msg "[成功] $TARGET_REL <- $ORIG_REL (文件数: $F_CNT)"
        [ "$VERBOSE" = "1" ] && echo "[成功]   $TARGET_REL <- $ORIG_REL (文件数: $F_CNT)"
        MOUNTED_COUNT=$((MOUNTED_COUNT + 1))
        return 0
    else
        safe_remove_empty_mountpoint "$TARGET_LOWER"
        log_msg "[失败] $TARGET_REL <- $ORIG_REL | 原因: $ERR_OUT"
        [ "$VERBOSE" = "1" ] && echo "[失败]   $TARGET_REL | 原因: $ERR_OUT"
        FAILED_COUNT=$((FAILED_COUNT + 1))
        return 1
    fi
}

apply_bind_rules() {
    VERBOSE="$1"
    load_settings
    trim_log

    USE_FUSE=0
    is_fuse_storage && USE_FUSE=1

    mkdir -p "$BASE/$OUT_ROOT"
    chown media_rw:media_rw "$BASE/$OUT_ROOT" 2>/dev/null
    chmod 770 "$BASE/$OUT_ROOT" 2>/dev/null

    # 在归类总目录放置 .nomedia，防止系统相册把映射目录里的照片/视频重复扫出两份
    # （仅作用于 Download/应用下载，不影响原 Pictures/DCIM 在相册正常显示，也不影响文件管理器访问）
    NOMEDIA_NEW=0
    if [ ! -f "$BASE/$OUT_ROOT/.nomedia" ]; then
        touch "$BASE/$OUT_ROOT/.nomedia" 2>/dev/null
        chown media_rw:media_rw "$BASE/$OUT_ROOT/.nomedia" 2>/dev/null
        chmod 660 "$BASE/$OUT_ROOT/.nomedia" 2>/dev/null
        NOMEDIA_NEW=1
    fi

    log_msg "开始应用规则 (FUSE=$USE_FUSE, OUT_ROOT=$OUT_ROOT)"

    MOUNTED_COUNT=0
    SKIPPED_COUNT=0
    FAILED_COUNT=0

    ACTIVE_LIST="$MODDIR/.active_rules.tmp"
    SEEN_ORIG_LOW="$MODDIR/.seen_orig.tmp"
    : > "$ACTIVE_LIST"
    : > "$SEEN_ORIG_LOW"

    while IFS= read -r RAW_LINE || [ -n "$RAW_LINE" ]; do
        LINE="$(printf '%s' "$RAW_LINE" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        [ -z "$LINE" ] && continue
        case "$LINE" in
            \#*|AUTO_SCAN=*|SCAN_INTERVAL_HOURS=*|SKIP_EMPTY=*) continue ;;
        esac

        PUB_REL="${LINE%%|*}"
        ORIG_REL="${LINE#*|}"

        if [ "$PUB_REL" = "$LINE" ] || [ -z "$PUB_REL" ] || [ -z "$ORIG_REL" ]; then
            SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
            continue
        fi

        PUB_REL="$(printf '%s' "$PUB_REL" | sed 's|^/*||;s|/*$||')"
        ORIG_REL="$(printf '%s' "$ORIG_REL" | sed 's|^/*||;s|/*$||')"

        # 归一化软件名，并拦截原始 com.xxx.xxx 包名文件夹
        case "$PUB_REL" in
            "$OUT_ROOT"/*)
                _RAW_APP="${PUB_REL#$OUT_ROOT/}"
                _RAW_APP="${_RAW_APP%%/*}"
                _NORM_APP="$(normalize_app_name "$_RAW_APP")"
                if is_raw_pkg_name "$_NORM_APP"; then
                    log_msg "[跳过] 已拦截原始包名目录: $_NORM_APP ($ORIG_REL)"
                    SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
                    continue
                fi
                PUB_REL="$OUT_ROOT/$_NORM_APP"
                ;;
        esac

        PUB_LOWER="$BASE/$PUB_REL"
        ORIG_LOWER="$BASE/$ORIG_REL"

        case "$PUB_LOWER/" in
            "$ORIG_LOWER/"*)
                SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
                continue
                ;;
        esac
        case "$ORIG_LOWER/" in
            "$PUB_LOWER/"*)
                SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
                continue
                ;;
        esac

        if [ ! -d "$ORIG_LOWER" ]; then
            PKG_ROOT="$(extract_pkg_root "$ORIG_REL")"
            if [ -n "$PKG_ROOT" ] && [ -d "$PKG_ROOT" ]; then
                mkdir -p "$ORIG_LOWER" 2>/dev/null
                chown media_rw:media_rw "$ORIG_LOWER" 2>/dev/null
                chmod 770 "$ORIG_LOWER" 2>/dev/null
            else
                SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
                continue
            fi
        fi

        # 按源路径大小写不敏感去重，彻底杜绝 DCIM/WeiXinWork 与 DCIM/WeixinWork 重复挂载
        _ORIG_KEY="$(printf '%s' "$ORIG_REL" | tr 'A-Z' 'a-z')"
        if ! grep -Fqx "$_ORIG_KEY" "$SEEN_ORIG_LOW" 2>/dev/null; then
            printf '%s\n' "$_ORIG_KEY" >> "$SEEN_ORIG_LOW"
            printf '%s|%s\n' "$PUB_REL" "$ORIG_REL" >> "$ACTIVE_LIST"
        fi
    done < "$CONF"

    USED_TARGETS="$MODDIR/.used_targets.tmp"
    : > "$USED_TARGETS"

    while IFS= read -r ENTRY || [ -n "$ENTRY" ]; do
        [ -z "$ENTRY" ] && continue
        PUB_REL="${ENTRY%%|*}"
        ORIG_REL="${ENTRY#*|}"
        ORIG_LOWER="$BASE/$ORIG_REL"

        GROUP_CNT="$(grep -Fc "${PUB_REL}|" "$ACTIVE_LIST" 2>/dev/null || echo 1)"

        if [ "$GROUP_CNT" -le 1 ]; then
            mount_single_target "$ORIG_LOWER" "$PUB_REL" "$ORIG_REL" "$VERBOSE"
        else
            if is_mounted "$BASE/$PUB_REL"; then
                run_global umount -l "$BASE/$PUB_REL" 2>/dev/null
            fi
            mkdir -p "$BASE/$PUB_REL"
            chown media_rw:media_rw "$BASE/$PUB_REL" 2>/dev/null
            chmod 770 "$BASE/$PUB_REL" 2>/dev/null

            SUB_NAME="$(make_sub_label "$ORIG_REL")"
            CAND_TARGET="$PUB_REL/$SUB_NAME"
            IDX=2
            while grep -Fqx "$CAND_TARGET" "$USED_TARGETS" 2>/dev/null; do
                CAND_TARGET="$PUB_REL/${SUB_NAME}${IDX}"
                IDX=$((IDX + 1))
            done
            printf '%s\n' "$CAND_TARGET" >> "$USED_TARGETS"

            mount_single_target "$ORIG_LOWER" "$CAND_TARGET" "$ORIG_REL" "$VERBOSE"
        fi
    done < "$ACTIVE_LIST"

    rm -f "$ACTIVE_LIST" "$USED_TARGETS" "$SEEN_ORIG_LOW"

    # 若刚新建 .nomedia，通知媒体库刷新该目录以清除相册中已缓存的重复项
    if [ "$NOMEDIA_NEW" = "1" ] && command -v am >/dev/null 2>&1; then
        am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d "file:///storage/emulated/0/$OUT_ROOT" >/dev/null 2>&1
    fi

    SUMMARY="生效 ${MOUNTED_COUNT} | 跳过 ${SKIPPED_COUNT} | 失败 ${FAILED_COUNT}"
    log_msg "执行汇总: $SUMMARY"
    update_module_desc "$SUMMARY"

    if [ "$VERBOSE" = "1" ]; then
        echo "-----------------------------------------"
        echo "执行汇总: $SUMMARY"
        echo "当前 /sdcard/$OUT_ROOT/ 目录列表:"
        if [ -d "$BASE/$OUT_ROOT" ]; then
            for _D in "$BASE/$OUT_ROOT"/*; do
                [ ! -e "$_D" ] && continue
                _DN="$(basename "$_D")"
                if is_mounted "$_D"; then
                    echo "  [已挂载] $_DN ($(count_user_files "$_D") 项)"
                else
                    echo "  [汇总目录] $_DN/"
                    for _SD in "$_D"/*; do
                        [ ! -e "$_SD" ] && continue
                        _SDN="$(basename "$_SD")"
                        if is_mounted "$_SD"; then
                            echo "      └─ $_SDN ($(count_user_files "$_SD") 项)"
                        fi
                    done
                fi
            done
        fi
        echo "-----------------------------------------"
        echo "提示: 手动新增 App 请编辑 $CONF"
        echo "格式: Download/应用下载/软件名|App原目录相对路径"
    fi
}

unmount_bind_rules() {
    safe_unmount_and_clean_root "$OUT_ROOT"
    safe_unmount_and_clean_root "Download/app"
    safe_unmount_and_clean_root "Download/App"
}
