#!/system/bin/sh
MODDIR="$(cd "$(dirname "$0")" && pwd)"

echo "========================================="
echo "  App Download Binder v3.3.0"
echo "  作者: KrisWu & Antigravity"
echo "========================================="

. "$MODDIR/common.sh"
scan_new_apps 1
echo "-----------------------------------------"
apply_bind_rules 1

echo "========================================="
echo "当前模式: LAYOUT_MODE=$LAYOUT_MODE (/sdcard/$OUT_ROOT/)"
echo "配置文件: $MODDIR/rules.conf"
echo "一键脚本: $MODDIR/一键扫描并重载挂载.sh"
echo "运行日志: $MODDIR/bind.log"
