#!/usr/bin/env bash
# antcrate :: lib/rag.sh — deterministic retrieval pipeline (Plan 4, 2026-07-10)
#
# sqlite FTS5/BM25 over project text — NOT vectors: zero keys, zero models,
# reproducible ranking. "Bash owns retrieval, Claude owns judgment." For Claude
# Code the Bash tool IS the integration: agents call `antcrate rag q <p> "<q>"`
# instead of grepping cold. A vector layer (sqlite-vec + embedder via nix) can
# stack on this schema later without breaking the CLI contract.
#
# Public API:
#   ac_rag_init  <project>                — create <rag-dir>/<project>.db
#   ac_rag_index <project>                — incremental index (mtime-driven)
#   ac_rag_query <project> <query> [n]    — BM25 top-n: path:line + snippet
#                                           self-healing: inits/reindexes first
#                                           if the db is missing or stale
#
# Layout: $ANTCRATE_RAG_DIR (default $ANTCRATE_DATA_HOME/rag, fallback
# $ANTCRATE_HOME/rag). Chunks: 60 lines, step 50 (10-line overlap). Files:
# text-only (grep -Iq), 1MB cap, noise dirs pruned (same set as the address
# layer). Sourced by wrapper. Depends on registry.sh, log.sh; requires the
# sqlite3 CLI with FTS5 (checked at runtime, not source time).

_ac_rag_dir() {
    printf '%s\n' "${ANTCRATE_RAG_DIR:-${ANTCRATE_DATA_HOME:-${ANTCRATE_HOME:-$HOME/.antcrate}}/rag}"
}

_ac_rag_db() { printf '%s/%s.db\n' "$(_ac_rag_dir)" "$1"; }

_ac_rag_require_sqlite() {
    command -v sqlite3 >/dev/null 2>&1 && return 0
    ac_error "rag: sqlite3 not found (install via your distro or nix)"
    return 1
}

_ac_rag_project_path() {
    local project="$1"
    if ! ac_registry_has "$project"; then
        ac_error "rag: unknown project '$project'"; return 1
    fi
    local p; p=$(ac_registry_get "$project" path)
    [[ -d "$p" ]] || { ac_error "rag: path missing: $p"; return 1; }
    printf '%s\n' "$p"
}

# shared file walk: prune noise dirs, cap 1MB; extra find predicates via "$@"
_ac_rag_find() {
    local root="$1"; shift
    find "$root" \
        \( -name .git -o -name node_modules -o -name target -o -name dist \
           -o -name build -o -name __pycache__ -o -name .next -o -name .cache \
           -o -name .svelte-kit -o -name dev \) -prune \
        -o -type f -size -1048576c "$@" 2>/dev/null
}

# stale = any file OR dir newer than the db (dir mtime catches deletes/renames)
_ac_rag_stale() {
    local root="$1" db="$2"
    [[ -n "$(find "$root" \
        \( -name .git -o -name node_modules -o -name target -o -name dist \
           -o -name build -o -name __pycache__ -o -name .next -o -name .cache \
           -o -name .svelte-kit -o -name dev \) -prune \
        -o \( -type f -size -1048576c -o -type d \) -newer "$db" -print -quit \
        2>/dev/null)" ]]
}

ac_rag_init() {
    local project="$1"
    _ac_rag_require_sqlite || return 1
    _ac_rag_project_path "$project" >/dev/null || return 1
    local db; db=$(_ac_rag_db "$project")
    mkdir -p "$(_ac_rag_dir)"
    sqlite3 "$db" <<'SQL'
CREATE TABLE IF NOT EXISTS files(path TEXT PRIMARY KEY, mtime INTEGER);
CREATE VIRTUAL TABLE IF NOT EXISTS chunks USING fts5(path, start, content);
SQL
    ac_info "rag: initialized $db"
    printf '%s\n' "$db"
}

# emit SQL that (re)indexes one file: delete old chunks, insert 60/50 chunks
_ac_rag_file_sql() {
    local rel="$1" abs="$2" mtime="$3"
    local esc="${rel//\'/\'\'}"
    printf "DELETE FROM chunks WHERE path='%s';\n" "$esc"
    printf "INSERT OR REPLACE INTO files(path,mtime) VALUES('%s',%s);\n" "$esc" "$mtime"
    awk -v rel="$esc" '
        { lines[NR] = $0 }
        END {
            step = 50; size = 60
            for (s = 1; s <= NR; s += step) {
                e = s + size - 1; if (e > NR) e = NR
                chunk = ""
                for (i = s; i <= e; i++) chunk = chunk lines[i] "\n"
                gsub(/'\''/, "'\'''\''", chunk)
                printf "INSERT INTO chunks(path,start,content) VALUES('\''%s'\'',%d,'\''%s'\'');\n", rel, s, chunk
                if (e == NR) break
            }
        }' "$abs"
}

ac_rag_index() {
    local project="$1"
    _ac_rag_require_sqlite || return 1
    local p; p=$(_ac_rag_project_path "$project") || return 1
    local db; db=$(_ac_rag_db "$project")
    [[ -f "$db" ]] || { ac_error "rag: no db for '$project' — run: antcrate rag init $project"; return 1; }

    local sql; sql=$(mktemp)
    printf 'BEGIN;\n' > "$sql"
    local indexed=0 f rel mtime known
    while IFS= read -r -d '' f; do
        grep -Iq . "$f" 2>/dev/null || continue          # text files only
        rel="${f#"$p"/}"
        mtime=$(stat -c %Y "$f")
        known=$(sqlite3 "$db" "SELECT mtime FROM files WHERE path='${rel//\'/\'\'}';") || known=""
        [[ "$known" == "$mtime" ]] && continue
        _ac_rag_file_sql "$rel" "$f" "$mtime" >> "$sql"
        indexed=$((indexed + 1))
    done < <(_ac_rag_find "$p" -print0)

    # drop records for files that vanished
    local gone
    while IFS= read -r gone; do
        printf "DELETE FROM chunks WHERE path='%s';\nDELETE FROM files WHERE path='%s';\n" \
            "${gone//\'/\'\'}" "${gone//\'/\'\'}" >> "$sql"
    done < <(sqlite3 "$db" "SELECT path FROM files;" | while IFS= read -r rp; do
        [[ -f "$p/$rp" ]] || printf '%s\n' "$rp"
    done)

    printf 'COMMIT;\n' >> "$sql"
    sqlite3 "$db" < "$sql" || { rm -f "$sql"; ac_error "rag: index failed"; return 1; }
    rm -f "$sql"
    local total; total=$(sqlite3 "$db" "SELECT count(*) FROM files;")
    ac_info "rag: $project — $indexed file(s) (re)indexed, $total tracked"
    printf 'rag: %s file(s) (re)indexed, %s tracked\n' "$indexed" "$total"
}

ac_rag_query() {
    local project="$1" query="$2" limit="${3:-8}"
    _ac_rag_require_sqlite || return 1
    [[ -n "$query" ]] || { ac_error "rag: empty query"; return 2; }
    local db; db=$(_ac_rag_db "$project")

    # self-healing: no db -> init+index; stale db -> reindex. The query is the
    # only command an agent needs — freshness is never its job.
    local p; p=$(_ac_rag_project_path "$project") || return 1
    if [[ ! -f "$db" ]]; then
        ac_rag_init "$project" >/dev/null || return 1
        ac_rag_index "$project" >/dev/null || return 1
    elif _ac_rag_stale "$p" "$db"; then
        ac_rag_index "$project" >/dev/null || return 1
    fi

    # sanitize into FTS5 phrase terms: strip quotes, quote each word
    local match="" w
    for w in $query; do
        w="${w//\"/}"; w="${w//\'/}"
        [[ -n "$w" ]] && match+="\"$w\" "
    done
    [[ -n "$match" ]] || { ac_error "rag: query reduced to nothing"; return 2; }

    sqlite3 -separator ' | ' "$db" \
        "SELECT path || ':' || start, snippet(chunks, 2, '>>', '<<', '…', 16)
         FROM chunks WHERE chunks MATCH '${match//\'/\'\'}'
         ORDER BY bm25(chunks) LIMIT ${limit};" \
        | sed 's/\n/ /g'
}
