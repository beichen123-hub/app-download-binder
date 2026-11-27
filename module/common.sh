#!/system/bin/sh

# 兼容 KernelSU / KernelSU Next / APatch / Magisk 的工具链 PATH
export PATH="/data/adb/ksu/bin:/data/adb/ap/bin:/data/adb/magisk:/system/bin:/vendor/bin:$PATH"

BASE="/data/media/0"
FUSE_BASE="/storage/emulated/0"

CONF="$MODDIR/rules.conf"
BUILTIN_DB="$MODDIR/builtin_rules.db"
LOG_FILE="$MODDIR/bind.log"
LAST_SCAN_FILE="$MODDIR/last_scan.ts"
MOUNTED_LIST="$MODDIR/mounted_paths.list"
PROP_FILE="$MODDIR/module.prop"

# 默认参数（可在 rules.conf 中覆盖）
# LAYOUT_MODE: 1=Download/<软件名>, 2=Download/应用下载/<软件名>, 3=Download/应用下载/<分类>/<软件名>
LAYOUT_MODE=2
OUT_ROOT="Download/应用下载"
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
    case "$LAYOUT_MODE" in
        1) _MODE_TXT="平铺" ;;
        3) _MODE_TXT="三级分类" ;;
        *) _MODE_TXT="二级收纳" ;;
    esac
    NEW_DESC="[$STATUS_TEXT | ${_MODE_TXT} | $NOW_STR] 目录:/sdcard/$OUT_ROOT/ | 作者:KrisWu & Antigravity"
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
    LAYOUT_MODE=2
    AUTO_SCAN=1
    SCAN_INTERVAL_HOURS=24
    while IFS= read -r RAW_LINE || [ -n "$RAW_LINE" ]; do
        LINE="$(printf '%s' "$RAW_LINE" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        case "$LINE" in
            LAYOUT_MODE=*)
                VAL="${LINE#LAYOUT_MODE=}"
                case "$VAL" in
                    1|2|3) LAYOUT_MODE="$VAL" ;;
                esac
                ;;
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

    if [ "$LAYOUT_MODE" = "1" ]; then
        OUT_ROOT="Download"
    else
        OUT_ROOT="Download/应用下载"
    fi
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

is_junk_path() {
    _LOWER="$(printf '%s' "$1" | tr 'A-Z' 'a-z')"
    case "$_LOWER" in
        *cache*|*log*|*thumb*|*temp*|*/tmp*|*sticker*|*avatar*|*emoji*|*voice*|\
        *update*|*upgrade*|*preprocess*|*/asr*|*taolive*|*theme*|*patch*|*plugin*|*webview*|\
        pictures/camera|dcim/camera|pictures/screenshots|dcim/screenshots|dcim/screenrecorder|\
        pictures/gallery|dcim/restored|dcim/sdp|pictures/wv_save_image)
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

# 大小写不敏感归一化为统一中文软件名，确保一软件一文件夹
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

# 三级分类模式（LAYOUT_MODE=3）下的软件分类
get_app_category() {
    case "$1" in
        微信|QQ|TIM|企业微信|Telegram|Nekogram|NekoX|Telegram-X|钉钉|飞书|微博|小红书|知乎|BOSS直聘|知识星球|BaiduHi)
            echo "社交办公"
            ;;
        百度网盘|百度网盘企业版|阿里云盘|115网盘|PikPak|天翼云盘|移动云盘|腾讯微云|曲奇云盘|文叔叔|MEGA|speedpan)
            echo "网盘传输"
            ;;
        夸克|UC浏览器|QQ浏览器|X浏览器|Via浏览器|360极速浏览器|百度App)
            echo "浏览器"
            ;;
        哔哩哔哩|抖音|快手|皮皮虾|人人视频|网易云音乐|QQ音乐|酷狗音乐|酷我音乐|YMusic|歌词适配|PiliPlus|Muse|影石Insta360|谷歌相机)
            echo "影音图片"
            ;;
        淘宝|京东|拼多多|支付宝|菜鸟)
            echo "购物生活"
            ;;
        迅雷|ADM|IDM|1DM|酷安|腾讯文档|网易邮箱大师|小米互传|小米快传|小米手表|小米运动健康|应用宝|Scene|中国移动|葫芦侠|百度文库|Winrar|AirDroid|Xender|画板)
            echo "下载工具"
            ;;
        *)
            echo "其他应用"
            ;;
    esac
}

# 根据当前 LAYOUT_MODE 生成目标相对路径
resolve_pub_rel() {
    _RAW_LEFT="$1"
    case "$_RAW_LEFT" in
        Download/应用下载/*)
            _NAME="${_RAW_LEFT##*/}"
            ;;
        Download/app/*|Download/App/*)
            _NAME="${_RAW_LEFT##*/}"
            ;;
        Download/*)
            _NAME="${_RAW_LEFT#Download/}"
            _NAME="${_NAME%%/*}"
            ;;
        */*)
            # 用户显式自定义了非 Download 路径（如 我的文件/微信），完全尊重
            echo "$_RAW_LEFT"
            return
            ;;
        *)
            _NAME="$_RAW_LEFT"
            ;;
    esac

    _NAME="$(normalize_app_name "$_NAME")"
    case "$LAYOUT_MODE" in
        1)
            echo "Download/$_NAME"
            ;;
        3)
            _CAT="$(get_app_category "$_NAME")"
            echo "Download/应用下载/$_CAT/$_NAME"
            ;;
        *)
            echo "Download/应用下载/$_NAME"
            ;;
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

rule_exists_in_conf() {
    DST_CHECK="$1"
    tr -d '\r' < "$CONF" | grep -Fiq "|$DST_CHECK"
}

# 写入简写规则：软件名|原相对路径（切换 LAYOUT_MODE 时自动适配层级）
append_auto_rule() {
    APP_OR_PUB="$1"
    ORIG_REL="$2"
    VERBOSE="$3"

    if rule_exists_in_conf "$ORIG_REL"; then
        return 1
    fi

    printf '%s|%s\n' "$APP_OR_PUB" "$ORIG_REL" >> "$CONF"
    chmod 644 "$CONF" 2>/dev/null

    log_msg "[自动发现] 新增规则: $APP_OR_PUB <- $ORIG_REL"
    [ "$VERBOSE" = "1" ] && echo "[自动发现] + $APP_OR_PUB <- $ORIG_REL"
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
                append_auto_rule "$APP_NAME" "$ORIG_REL" "$VERBOSE"
            fi
        done < "$BUILTIN_DB"
    fi

    WECOM_FC="$BASE/Android/data/com.tencent.wework/files/filecache"
    if [ -d "$WECOM_FC" ]; then
        for _WID in "$WECOM_FC"/*; do
            [ ! -d "$_WID" ] && continue
            _WNAME="$(basename "$_WID")"
            case "$_WNAME" in
                ''|*[!0-9]*) continue ;;
                *)
                    append_auto_rule "企业微信" "Android/data/com.tencent.wework/files/filecache/$_WNAME" "$VERBOSE"
                    ;;
            esac
        done
    fi

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
                    append_auto_rule "$APP_LABEL" "$ORIG_REL" "$VERBOSE"
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

# 递归安全卸载并清理指定总目录（支持 2 级与 3 级分类目录，绝不误删原文件）
safe_unmount_and_clean_root() {
    ROOT_REL="$1"
    # 绝对禁止直接清理 Download 根目录本身
    case "$ROOT_REL" in
        Download|download|""|/) return ;;
    esac
    ROOT_LOWER="$BASE/$ROOT_REL"
    ROOT_FUSE="$FUSE_BASE/$ROOT_REL"

    # 先卸载 FUSE 层（若有）
    if [ -d "$ROOT_FUSE" ]; then
        find "$ROOT_FUSE" -depth -type d 2>/dev/null | while IFS= read -r _FD; do
            is_mounted "$_FD" && run_global umount -l "$_FD" 2>/dev/null
        done
    fi

    # 深度优先由内向外安全卸载并仅用 rmdir 清理空壳目录
    if [ -d "$ROOT_LOWER" ]; then
        find "$ROOT_LOWER" -depth -type d 2>/dev/null | while IFS= read -r _D; do
            is_mounted "$_D" && run_global umount -l "$_D" 2>/dev/null
            if [ -d "$_D" ] && ! is_mounted "$_D"; then
                rm -f "$_D/.nomedia" "$_D/AppBindRules.conf" 2>/dev/null
                rmdir "$_D" 2>/dev/null
            fi
        done
    fi
}

# 精准清理 mounted_paths.list 记录的所有挂载点（平铺模式 LAYOUT_MODE=1 安全清理必备）
unmount_recorded_paths() {
    [ ! -f "$MOUNTED_LIST" ] && return
    while IFS= read -r _MREL || [ -n "$_MREL" ]; do
        [ -z "$_MREL" ] && continue
        _ML="$BASE/$_MREL"
        _MF="$FUSE_BASE/$_MREL"
        is_mounted "$_MF" && run_global umount -l "$_MF" 2>/dev/null
        is_mounted "$_ML" && run_global umount -l "$_ML" 2>/dev/null
        safe_remove_empty_mountpoint "$_ML"

        # 顺带清理空的父级汇总目录（但不碰 Download 根目录本身）
        _PARENT="$(dirname "$_MREL")"
        case "$_PARENT" in
            Download|download|"."|"/") ;;
            *)
                _PL="$BASE/$_PARENT"
                if [ -d "$_PL" ] && ! is_mounted "$_PL"; then
                    rm -f "$_PL/.nomedia" 2>/dev/null
                    rmdir "$_PL" 2>/dev/null
                fi
                ;;
        esac
    done < "$MOUNTED_LIST"
    rm -f "$MOUNTED_LIST"
}

record_mounted_path() {
    if ! grep -Fqx "$1" "$MOUNTED_LIST" 2>/dev/null; then
        printf '%s\n' "$1" >> "$MOUNTED_LIST"
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
        record_mounted_path "$TARGET_REL"
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
        record_mounted_path "$TARGET_REL"
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

    # 二级/三级模式下，在总目录 Download/应用下载/.nomedia 放置 .nomedia 防止相册重复
    # （一级平铺模式绝不在 Download 根目录放 .nomedia，改为放在各个未挂载的汇总父目录内）
    NOMEDIA_NEW=0
    if [ "$LAYOUT_MODE" != "1" ] && [ ! -f "$BASE/$OUT_ROOT/.nomedia" ]; then
        touch "$BASE/$OUT_ROOT/.nomedia" 2>/dev/null
        chown media_rw:media_rw "$BASE/$OUT_ROOT/.nomedia" 2>/dev/null
        chmod 660 "$BASE/$OUT_ROOT/.nomedia" 2>/dev/null
        NOMEDIA_NEW=1
    fi

    log_msg "开始应用规则 (LAYOUT_MODE=$LAYOUT_MODE, OUT_ROOT=$OUT_ROOT, FUSE=$USE_FUSE)"

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
            \#*|LAYOUT_MODE=*|AUTO_SCAN=*|SCAN_INTERVAL_HOURS=*|SKIP_EMPTY=*) continue ;;
        esac

        RAW_LEFT="${LINE%%|*}"
        ORIG_REL="${LINE#*|}"

        if [ "$RAW_LEFT" = "$LINE" ] || [ -z "$RAW_LEFT" ] || [ -z "$ORIG_REL" ]; then
            SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
            continue
        fi

        RAW_LEFT="$(printf '%s' "$RAW_LEFT" | sed 's|^/*||;s|/*$||')"
        ORIG_REL="$(printf '%s' "$ORIG_REL" | sed 's|^/*||;s|/*$||')"

        PUB_REL="$(resolve_pub_rel "$RAW_LEFT")"
        _FINAL_APP="${PUB_REL##*/}"
        if is_raw_pkg_name "$_FINAL_APP"; then
            log_msg "[跳过] 已拦截原始包名目录: $_FINAL_APP ($ORIG_REL)"
            SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
            continue
        fi

        PUB_LOWER="$BASE/$PUB_REL"
        ORIG_LOWER="$BASE/$ORIG_REL"

        # 防止同路径自挂或递归套娃挂载（如平铺模式下 Download/QQ <- Download/QQ）
        _PUB_LOW_CI="$(printf '%s' "$PUB_LOWER" | tr 'A-Z' 'a-z')"
        _ORIG_LOW_CI="$(printf '%s' "$ORIG_LOWER" | tr 'A-Z' 'a-z')"
        case "$_PUB_LOW_CI/" in
            "$_ORIG_LOW_CI/"*)
                SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
                continue
                ;;
        esac
        case "$_ORIG_LOW_CI/" in
            "$_PUB_LOW_CI/"*)
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

            # 平铺模式下，在汇总父目录放 .nomedia 防相册重复（不影响原目录与 Download 根目录）
            if [ "$LAYOUT_MODE" = "1" ] && [ ! -f "$BASE/$PUB_REL/.nomedia" ]; then
                touch "$BASE/$PUB_REL/.nomedia" 2>/dev/null
                chown media_rw:media_rw "$BASE/$PUB_REL/.nomedia" 2>/dev/null
                chmod 660 "$BASE/$PUB_REL/.nomedia" 2>/dev/null
            fi

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

    if [ "$NOMEDIA_NEW" = "1" ] && command -v am >/dev/null 2>&1; then
        am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d "file:///storage/emulated/0/$OUT_ROOT" >/dev/null 2>&1
    fi

    SUMMARY="生效 ${MOUNTED_COUNT} | 跳过 ${SKIPPED_COUNT} | 失败 ${FAILED_COUNT}"
    log_msg "执行汇总: $SUMMARY"
    update_module_desc "$SUMMARY"

    if [ "$VERBOSE" = "1" ]; then
        echo "-----------------------------------------"
        echo "执行汇总: $SUMMARY (目录模式: LAYOUT_MODE=$LAYOUT_MODE)"
        echo "生效目录根路径: /sdcard/$OUT_ROOT/"
        echo "提示: 手动新增 App 请编辑 $CONF（格式: 软件名|App原目录相对路径）"
    fi
}

unmount_bind_rules() {
    unmount_recorded_paths
    safe_unmount_and_clean_root "Download/应用下载"
    safe_unmount_and_clean_root "Download/app"
    safe_unmount_and_clean_root "Download/App"
}
