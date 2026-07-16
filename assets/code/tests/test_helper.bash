# antcrate :: tests/test_helper.bash — portable shims for the bats suite.
#
# Loaded via `load test_helper` by any test that previously shelled GNU-only
# tools directly (stat -c, sha256sum, sed -i, date +%s%3N). The t_* helpers
# delegate to lib/compat.sh so tests exercise the exact same probe logic the
# production code uses, on both GNU (Linux CI) and BSD (macOS) userlands.

# shellcheck disable=SC1091
. "$BATS_TEST_DIRNAME/../lib/compat.sh"

t_mtime()  { ac_stat_mtime "$@"; }

# t_touch_age_days <days> <file...> — set mtime N days in the past
# (replaces GNU-only `touch -d "N days ago"`; touch -t is POSIX)
t_touch_age_days() {
    local days="$1"; shift
    local stamp
    stamp=$(ac_date_from_epoch "$(( $(date +%s) - days * 86400 ))" +%Y%m%d%H%M.%S)
    touch -t "$stamp" "$@"
}
t_inode()  { ac_stat_inode "$@"; }
t_sha256() { ac_sha256 "$@"; }
t_now_ms() { ac_now_ms; }
t_sed_i()  { ac_sed_i "$@"; }
