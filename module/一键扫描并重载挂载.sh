#!/system/bin/sh
MODDIR="$(cd "$(dirname "$0")" && pwd)"
exec sh "$MODDIR/scan_report.sh" --apply
