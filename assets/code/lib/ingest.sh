#!/usr/bin/env bash
# shellcheck disable=SC2016  # jq filter strings: $-vars are jq, not shell
# antcrate :: lib/ingest.sh — bundle consumer (BUNDLE_SPEC v1.0)
#
# Validate-before-write per BUNDLE_SPEC §4: any failure aborts ingest with
# no on-disk side effects beyond the STATUS file (set to "failed: <reason>").
#
# Public API (callable from the wrapper):
#   ac_ingest <bundle_dir>                              — full orchestrator
#   ac_ingest_validate <bundle_dir>                     — §4 checks, no writes
#   ac_ingest_status_set <bundle_dir> <state> [reason]  — atomic STATUS update
#
# Internal (do not call from outside this file):
#   ac_ingest_load_manifest, ac_ingest_validate_*,
#   ac_ingest_check_git_reachable, ac_ingest_check_archive_reachable,
#   ac_ingest_materialize_source, ac_ingest_source_*,
#   ac_ingest_copy_opaque, ac_ingest_handle_relationships_pre,
#   ac_ingest_status_get
# Reason: validators expect the AC_INGEST_* globals populated by
# ac_ingest_load_manifest; materializers and relationship handlers
# write to disk and bypass the §4 ordering when called directly.
# Always enter through ac_ingest or ac_ingest_validate.
#
# Globals set by ac_ingest_load_manifest (consumed by validators / orchestrator):
#   AC_INGEST_NAME, AC_INGEST_DOMAIN, AC_INGEST_OBJECTIVE, AC_INGEST_SPEC_VERSION,
#   AC_INGEST_SOURCE_TYPE, AC_INGEST_SKILL_NAME,
#   AC_INGEST_RELATIONSHIPS_JSON (raw JSON array, may be "null")

: "${ANTCRATE_HOME:=$HOME/.antcrate}"
: "${ANTCRATE_ROOT:=$HOME/projects}"
: "${ANTCRATE_INGEST_OFFLINE:=0}"        # skip reachability network checks
: "${ANTCRATE_INGEST_SKIP_FETCH:=0}"     # skip actual clone/download (validation-only run)
: "${ANTCRATE_SKILLS_DIR:=$HOME/.claude/skills}"

# Recognized spec major versions (extend on bump)
AC_INGEST_SUPPORTED_MAJORS=(1)

# ---------------------------------------------------------------------------
# Manifest load + validation (§4)
# ---------------------------------------------------------------------------

ac_ingest_load_manifest() {
    # ac_ingest_load_manifest <bundle_dir>
    # Parses manifest.json, populates AC_INGEST_* globals. Returns 0 on success.
    local bundle="$1"
    local mf="$bundle/manifest.json"
    if [[ ! -f "$mf" ]]; then
        ac_error "ingest: manifest.json missing at $mf"
        return 1
    fi
    if ! jq -e . "$mf" >/dev/null 2>&1; then
        ac_error "ingest: manifest.json is not valid JSON"
        return 1
    fi

    AC_INGEST_SPEC_VERSION=$(jq -r '.spec_version // ""' "$mf")
    AC_INGEST_NAME=$(jq -r '.name // ""' "$mf")
    AC_INGEST_DOMAIN=$(jq -r '.domain // ""' "$mf")
    AC_INGEST_OBJECTIVE=$(jq -r '.objective // ""' "$mf")
    AC_INGEST_SOURCE_TYPE=$(jq -r '.source.type // ""' "$mf")
    AC_INGEST_SKILL_NAME=$(jq -r '.claude.skill_name // .name // ""' "$mf")
    AC_INGEST_RELATIONSHIPS_JSON=$(jq -c '.relationships // null' "$mf")
    return 0
}

ac_ingest_validate_required_fields() {
    # spec_version, name, domain, objective, generated_at, source.type
    local mf="$1/manifest.json"
    local missing=()
    [[ -z "$AC_INGEST_SPEC_VERSION" ]] && missing+=("spec_version")
    [[ -z "$AC_INGEST_NAME" ]]         && missing+=("name")
    [[ -z "$AC_INGEST_DOMAIN" ]]       && missing+=("domain")
    [[ -z "$AC_INGEST_OBJECTIVE" ]]    && missing+=("objective")
    [[ -z "$AC_INGEST_SOURCE_TYPE" ]]  && missing+=("source.type")
    local generated_at; generated_at=$(jq -r '.generated_at // ""' "$mf")
    [[ -z "$generated_at" ]] && missing+=("generated_at")
    if (( ${#missing[@]} > 0 )); then
        ac_error "ingest: missing required field(s): ${missing[*]}"
        return 1
    fi
    return 0
}

ac_ingest_validate_spec_version() {
    # Major must be in AC_INGEST_SUPPORTED_MAJORS; minor ignored (forward-compat)
    local ver="$AC_INGEST_SPEC_VERSION"
    [[ "$ver" =~ ^([0-9]+)\.[0-9]+$ ]] || {
        ac_error "ingest: spec_version '$ver' is not <major>.<minor>"
        return 1
    }
    local major="${BASH_REMATCH[1]}"
    local m
    for m in "${AC_INGEST_SUPPORTED_MAJORS[@]}"; do
        [[ "$m" == "$major" ]] && return 0
    done
    ac_error "ingest: unsupported spec_version major '$major' (supported: ${AC_INGEST_SUPPORTED_MAJORS[*]})"
    return 1
}

ac_ingest_validate_name() {
    local n="$AC_INGEST_NAME"
    if [[ "$n" =~ [[:space:]] ]]; then
        ac_error "ingest: name contains whitespace: '$n'"; return 1
    fi
    case "$n" in
        */*) ac_error "ingest: name contains '/': '$n'"; return 1 ;;
        .*)  ac_error "ingest: name has leading dot or '..': '$n'"; return 1 ;;
    esac
    [[ "$n" == *..* ]] && { ac_error "ingest: name contains '..': '$n'"; return 1; }
    return 0
}

ac_ingest_validate_domain() {
    # Spec §2.1: any value if domain whitelisting is disabled. We do not
    # enforce a whitelist by default; reject only obviously-broken values.
    local d="$AC_INGEST_DOMAIN"
    if [[ "$d" =~ [[:space:]] ]] || [[ "$d" == */* ]]; then
        ac_error "ingest: invalid domain '$d'"; return 1
    fi
    return 0
}

ac_ingest_validate_source_shape() {
    # ac_ingest_validate_source_shape <bundle_dir>
    # Recognized type + required sub-fields per type.
    local mf="$1/manifest.json"
    local t="$AC_INGEST_SOURCE_TYPE"
    case "$t" in
        none) return 0 ;;
        git)
            local url; url=$(jq -r '.source.url // ""' "$mf")
            [[ -z "$url" ]] && { ac_error "ingest: source.type=git requires source.url"; return 1; }
            return 0 ;;
        archive)
            local url; url=$(jq -r '.source.url // ""' "$mf")
            [[ -z "$url" ]] && { ac_error "ingest: source.type=archive requires source.url"; return 1; }
            return 0 ;;
        composite)
            local n; n=$(jq -r '(.source.sources // []) | length' "$mf")
            (( n >= 1 )) || { ac_error "ingest: source.type=composite requires non-empty source.sources[]"; return 1; }
            # validate each sub-source has type + (url for git/archive)
            local i
            for ((i=0; i<n; i++)); do
                local st; st=$(jq -r ".source.sources[$i].type // \"\"" "$mf")
                case "$st" in
                    git|archive)
                        local sub_url; sub_url=$(jq -r ".source.sources[$i].url // \"\"" "$mf")
                        [[ -z "$sub_url" ]] && { ac_error "ingest: composite source[$i] type=$st requires url"; return 1; }
                        ;;
                    none)
                        ac_error "ingest: composite sub-source type=none not permitted"; return 1 ;;
                    *)
                        ac_error "ingest: composite source[$i] has unknown type '$st'"; return 1 ;;
                esac
            done
            return 0 ;;
        *)
            ac_error "ingest: unknown source.type '$t' (expected: git|archive|none|composite)"
            return 1 ;;
    esac
}

ac_ingest_validate_collision() {
    # ac_ingest_validate_collision — refuse if name registered, unless
    # relationships declares supersedes/extends naming the same name.
    local n="$AC_INGEST_NAME"
    ac_registry_has "$n" || return 0   # no collision

    # collision; check relationships
    local rels="$AC_INGEST_RELATIONSHIPS_JSON"
    if [[ -z "$rels" || "$rels" == "null" ]]; then
        ac_error "ingest: project '$n' already registered; declare supersedes/extends in relationships to overwrite/merge"
        return 1
    fi
    local match
    match=$(jq -r --arg n "$n" '
        map(select((.kind == "supersedes" or .kind == "extends") and .bundle == $n)) | length
    ' <<< "$rels")
    if (( match >= 1 )); then
        return 0
    fi
    ac_error "ingest: project '$n' already registered; relationships does not declare supersedes/extends for it"
    return 1
}

ac_ingest_validate_reachability() {
    # ac_ingest_validate_reachability <bundle_dir>
    # Per source.type. Skipped entirely when ANTCRATE_INGEST_OFFLINE=1.
    local mf="$1/manifest.json"
    [[ "$ANTCRATE_INGEST_OFFLINE" == "1" ]] && {
        ac_warn "ingest: reachability skipped (ANTCRATE_INGEST_OFFLINE=1)"
        return 0
    }
    local t="$AC_INGEST_SOURCE_TYPE"
    case "$t" in
        none) return 0 ;;
        git)
            local url; url=$(jq -r '.source.url' "$mf")
            ac_ingest_check_git_reachable "$url" || return 1 ;;
        archive)
            local url; url=$(jq -r '.source.url' "$mf")
            ac_ingest_check_archive_reachable "$url" || return 1 ;;
        composite)
            local n; n=$(jq -r '.source.sources | length' "$mf")
            local i
            for ((i=0; i<n; i++)); do
                local st url
                st=$(jq -r ".source.sources[$i].type" "$mf")
                url=$(jq -r ".source.sources[$i].url" "$mf")
                case "$st" in
                    git)     ac_ingest_check_git_reachable "$url" || return 1 ;;
                    archive) ac_ingest_check_archive_reachable "$url" || return 1 ;;
                esac
            done ;;
    esac
    return 0
}

ac_ingest_check_git_reachable() {
    # Local paths and file:// always considered reachable if they exist
    local url="$1"
    case "$url" in
        file://*)
            local p="${url#file://}"
            [[ -e "$p" ]] && return 0
            ac_error "ingest: git source unreachable (file path missing): $url"; return 1 ;;
        /*|./*)
            [[ -e "$url" ]] && return 0
            ac_error "ingest: git source unreachable (local path missing): $url"; return 1 ;;
    esac
    if git ls-remote "$url" >/dev/null 2>&1; then
        return 0
    fi
    ac_error "ingest: git ls-remote failed for $url"
    return 1
}

ac_ingest_check_archive_reachable() {
    local url="$1"
    case "$url" in
        file://*)
            local p="${url#file://}"
            [[ -f "$p" ]] && return 0
            ac_error "ingest: archive unreachable (file path missing): $url"; return 1 ;;
        /*|./*)
            [[ -f "$url" ]] && return 0
            ac_error "ingest: archive unreachable (local path missing): $url"; return 1 ;;
    esac
    if command -v curl >/dev/null 2>&1; then
        if curl -fsSL --max-time 15 -I -o /dev/null "$url"; then return 0; fi
    elif command -v wget >/dev/null 2>&1; then
        if wget -q --spider --timeout=15 "$url"; then return 0; fi
    else
        ac_warn "ingest: neither curl nor wget available — assuming archive reachable"
        return 0
    fi
    ac_error "ingest: archive HEAD failed for $url"
    return 1
}

ac_ingest_validate() {
    # Top-level validator: orchestrates §4 checks in order.
    local bundle="$1"
    [[ -d "$bundle" ]] || { ac_error "ingest: bundle dir missing: $bundle"; return 1; }
    ac_ingest_load_manifest "$bundle"             || return 1
    ac_ingest_validate_required_fields "$bundle"  || return 1
    ac_ingest_validate_spec_version               || return 1
    ac_ingest_validate_name                       || return 1
    ac_ingest_validate_domain                     || return 1
    ac_ingest_validate_source_shape "$bundle"     || return 1
    ac_ingest_validate_collision                  || return 1
    ac_ingest_validate_reachability "$bundle"     || return 1
    return 0
}

# ---------------------------------------------------------------------------
# Source materialization
# ---------------------------------------------------------------------------

ac_ingest_materialize_source() {
    # ac_ingest_materialize_source <bundle_dir> <target_dir>
    # Dispatches by AC_INGEST_SOURCE_TYPE. Target must not exist or be empty.
    local bundle="$1" target="$2"
    local mf="$bundle/manifest.json"
    [[ "$ANTCRATE_INGEST_SKIP_FETCH" == "1" ]] && {
        ac_warn "ingest: source fetch skipped (ANTCRATE_INGEST_SKIP_FETCH=1)"
        mkdir -p "$target"
        return 0
    }
    case "$AC_INGEST_SOURCE_TYPE" in
        none)
            ac_ingest_source_none "$target" ;;
        git)
            local url commit branch
            url=$(jq -r '.source.url' "$mf")
            commit=$(jq -r '.source.commit // ""' "$mf")
            branch=$(jq -r '.source.branch // ""' "$mf")
            ac_ingest_source_git "$url" "$commit" "$branch" "$target" ;;
        archive)
            local url sha
            url=$(jq -r '.source.url' "$mf")
            sha=$(jq -r '.source.sha256 // ""' "$mf")
            ac_ingest_source_archive "$url" "$sha" "$target" ;;
        composite)
            ac_ingest_source_composite "$bundle" "$target" ;;
        *)
            ac_error "ingest: source type '$AC_INGEST_SOURCE_TYPE' not implemented"
            return 1 ;;
    esac
}

ac_ingest_source_none() {
    local target="$1"
    mkdir -p "$target"
    ac_info "ingest: source=none (empty scaffold at $target)"
}

ac_ingest_source_git() {
    local url="$1" commit="$2" branch="$3" target="$4"
    mkdir -p "$(dirname "$target")"
    local clone_args=(-q)
    [[ -n "$branch" ]] && clone_args+=(--branch "$branch")
    if ! git clone "${clone_args[@]}" "$url" "$target" 2>&1; then
        ac_error "ingest: git clone failed: $url"
        return 1
    fi
    if [[ -n "$commit" ]]; then
        if ! ( cd "$target" && git checkout -q "$commit" ) 2>&1; then
            ac_error "ingest: git checkout $commit failed in $target"
            return 1
        fi
        ac_info "ingest: pinned to commit $commit"
    fi
    ac_info "ingest: source=git $url → $target"
}

ac_ingest_source_archive() {
    local url="$1" sha="$2" target="$3"
    mkdir -p "$target"
    local tmp; tmp=$(mktemp -d)
    local archive="$tmp/archive"
    case "$url" in
        file://*) cp -f "${url#file://}" "$archive" ;;
        /*|./*)   cp -f "$url" "$archive" ;;
        *)
            if command -v curl >/dev/null 2>&1; then
                curl -fsSL --max-time 60 "$url" -o "$archive" \
                    || { ac_error "ingest: download failed: $url"; rm -rf "$tmp"; return 1; }
            elif command -v wget >/dev/null 2>&1; then
                wget -q --timeout=60 "$url" -O "$archive" \
                    || { ac_error "ingest: download failed: $url"; rm -rf "$tmp"; return 1; }
            else
                ac_error "ingest: no curl/wget available for archive download"
                rm -rf "$tmp"; return 1
            fi ;;
    esac
    if [[ -n "$sha" ]]; then
        local actual; actual=$(sha256sum "$archive" 2>/dev/null | awk '{print $1}')
        if [[ "$actual" != "$sha" ]]; then
            ac_error "ingest: sha256 mismatch (expected $sha, got $actual)"
            rm -rf "$tmp"
            return 1
        fi
        ac_info "ingest: sha256 verified ($sha)"
    fi
    # extract — try tar.gz, then zip
    if tar -tzf "$archive" >/dev/null 2>&1; then
        tar -C "$target" --strip-components=1 -xzf "$archive" 2>/dev/null \
            || tar -C "$target" -xzf "$archive"
    elif command -v unzip >/dev/null 2>&1 && unzip -tq "$archive" >/dev/null 2>&1; then
        unzip -q "$archive" -d "$target"
    else
        ac_error "ingest: archive format not recognized (tarball or zip expected)"
        rm -rf "$tmp"; return 1
    fi
    rm -rf "$tmp"
    ac_info "ingest: source=archive $url → $target"
}

ac_ingest_source_composite() {
    # Materializes each sub-source into a tmp staging dir, then merges with
    # cp -rn (no-clobber) in declaration order: first source wins on conflicts.
    local bundle="$1" target="$2"
    local mf="$bundle/manifest.json"
    mkdir -p "$target"
    local n; n=$(jq -r '.source.sources | length' "$mf")
    local i
    for ((i=0; i<n; i++)); do
        local st url commit branch sha
        st=$(jq -r ".source.sources[$i].type" "$mf")
        url=$(jq -r ".source.sources[$i].url" "$mf")
        commit=$(jq -r ".source.sources[$i].commit // \"\"" "$mf")
        branch=$(jq -r ".source.sources[$i].branch // \"\"" "$mf")
        sha=$(jq -r ".source.sources[$i].sha256 // \"\"" "$mf")
        local stage; stage=$(mktemp -d)
        local sub="$stage/sub"
        case "$st" in
            git)     ac_ingest_source_git "$url" "$commit" "$branch" "$sub" \
                         || { rm -rf "$stage"; return 1; } ;;
            archive) ac_ingest_source_archive "$url" "$sha" "$sub" \
                         || { rm -rf "$stage"; return 1; } ;;
        esac
        # merge into target — first source wins (no-clobber)
        ( cd "$sub" && find . -mindepth 1 -maxdepth 1 -print0 \
            | xargs -0 -I{} cp -rn {} "$target/" )
        rm -rf "$stage"
        ac_info "ingest: composite[$i] $st $url merged"
    done
}

# ---------------------------------------------------------------------------
# Opaque file copy
# ---------------------------------------------------------------------------

ac_ingest_copy_opaque() {
    # ac_ingest_copy_opaque <bundle_dir> <project_dir>
    # research.md → docs/research.md
    # claude.md   → CLAUDE.md
    # skill/      → ~/.claude/skills/<skill_name>/
    # diagrams/*  → docs/diagrams/
    # attachments/* → docs/attachments/
    local bundle="$1" project="$2"
    mkdir -p "$project/docs"
    [[ -f "$bundle/research.md" ]] && cp -f "$bundle/research.md" "$project/docs/research.md"
    [[ -f "$bundle/claude.md"   ]] && cp -f "$bundle/claude.md"   "$project/CLAUDE.md"
    if [[ -d "$bundle/skill" ]]; then
        local skill_dir="$ANTCRATE_SKILLS_DIR/$AC_INGEST_SKILL_NAME"
        mkdir -p "$skill_dir"
        cp -rT "$bundle/skill" "$skill_dir"
        ac_info "ingest: skill copied → $skill_dir"
    fi
    if [[ -d "$bundle/diagrams" ]]; then
        mkdir -p "$project/docs/diagrams"
        ( cd "$bundle/diagrams" && find . -mindepth 1 -maxdepth 1 -print0 \
            | xargs -0 -I{} cp -r {} "$project/docs/diagrams/" )
    fi
    if [[ -d "$bundle/attachments" ]]; then
        mkdir -p "$project/docs/attachments"
        ( cd "$bundle/attachments" && find . -mindepth 1 -maxdepth 1 -print0 \
            | xargs -0 -I{} cp -r {} "$project/docs/attachments/" )
    fi
}

# ---------------------------------------------------------------------------
# Relationships
# ---------------------------------------------------------------------------

ac_ingest_handle_relationships_pre() {
    # ac_ingest_handle_relationships_pre <bundle_dir>
    # Runs BEFORE materialization. Handles supersedes (backup + remove
    # existing) and depends_on (warn if missing). Sets AC_INGEST_MODE to
    # one of: fresh | supersedes | extends.
    AC_INGEST_MODE="fresh"
    local rels="$AC_INGEST_RELATIONSHIPS_JSON"
    [[ -z "$rels" || "$rels" == "null" ]] && return 0

    # depends_on warnings
    local deps; deps=$(jq -r 'map(select(.kind=="depends_on")) | .[] | .bundle' <<< "$rels")
    local d
    while IFS= read -r d; do
        [[ -z "$d" ]] && continue
        if ! ac_registry_has "$d"; then
            ac_warn "ingest: depends_on '$d' not registered (informational)"
        fi
    done <<< "$deps"

    # duplicate_of warnings
    local dups; dups=$(jq -r 'map(select(.kind=="duplicate_of")) | .[] | .bundle' <<< "$rels")
    while IFS= read -r d; do
        [[ -z "$d" ]] && continue
        ac_warn "ingest: bundle declares duplicate_of '$d' (informational)"
    done <<< "$dups"

    # extends takes precedence over supersedes if both somehow present
    local ext_target
    ext_target=$(jq -r --arg n "$AC_INGEST_NAME" \
        'map(select(.kind=="extends" and .bundle==$n)) | .[0].bundle // ""' <<< "$rels")
    if [[ -n "$ext_target" ]]; then
        if ! ac_registry_has "$ext_target"; then
            ac_error "ingest: extends '$ext_target' but it is not registered"
            return 1
        fi
        AC_INGEST_MODE="extends"
        ac_info "ingest: mode=extends (target=$ext_target)"
        return 0
    fi

    local sup_target
    sup_target=$(jq -r --arg n "$AC_INGEST_NAME" \
        'map(select(.kind=="supersedes" and .bundle==$n)) | .[0].bundle // ""' <<< "$rels")
    if [[ -n "$sup_target" ]]; then
        if ! ac_registry_has "$sup_target"; then
            ac_warn "ingest: supersedes '$sup_target' but it is not registered (treating as fresh)"
            AC_INGEST_MODE="fresh"
            return 0
        fi
        # Backup existing project + skill, then remove from disk so materialize
        # can write a clean tree under the same name.
        local existing_path; existing_path=$(ac_registry_get "$sup_target" path)
        if [[ -d "$existing_path" ]]; then
            if ! ac_safety_guard_destructive "$sup_target" "supersedes-overwrite" "$existing_path"; then
                ac_error "ingest: supersedes refused (backup+approval gate failed)"
                return 1
            fi
            _ac_quarantine_capture "$sup_target" "$existing_path" ingest-supersedes "$sup_target"
            ac_info "ingest: superseded project tree quarantined (backup at $AC_LAST_BACKUP_PATH)"
        fi
        # also back up the existing per-project skill, if present
        local existing_skill="$ANTCRATE_SKILLS_DIR/$AC_INGEST_SKILL_NAME"
        if [[ -d "$existing_skill" ]]; then
            local sb; sb=$(ac_backup_create "${AC_INGEST_SKILL_NAME}-skill" "$existing_skill") || true
            _ac_quarantine_capture "${AC_INGEST_SKILL_NAME}-skill" "$existing_skill" ingest-supersedes-skill "$AC_INGEST_SKILL_NAME"
            ac_info "ingest: superseded skill quarantined (backup at ${sb:-none})"
        fi
        AC_INGEST_MODE="supersedes"
        return 0
    fi
    return 0
}

# ---------------------------------------------------------------------------
# STATUS lifecycle
# ---------------------------------------------------------------------------

ac_ingest_status_set() {
    # ac_ingest_status_set <bundle_dir> <state> [reason]
    # Atomic write to <bundle>/STATUS.
    local bundle="$1" state="$2" reason="${3:-}"
    [[ -d "$bundle" ]] || return 1
    local line="$state"
    [[ -n "$reason" ]] && line="$state: $reason"
    local tmp; tmp=$(mktemp "$bundle/STATUS.XXXXXX")
    printf '%s\n' "$line" > "$tmp"
    mv "$tmp" "$bundle/STATUS"
}

ac_ingest_status_get() {
    local bundle="$1"
    [[ -f "$bundle/STATUS" ]] || { printf 'unknown\n'; return; }
    head -n1 "$bundle/STATUS"
}

# ---------------------------------------------------------------------------
# Top-level orchestrator
# ---------------------------------------------------------------------------

ac_ingest() {
    # ac_ingest <bundle_dir>
    # Validate → claim → materialize → opaque copy → register → ingested.
    # On any failure: STATUS=failed: <reason>, no partial registry state.
    local bundle="$1"
    bundle=$(realpath -m "$bundle")
    [[ -d "$bundle" ]] || { ac_error "ingest: bundle dir missing: $bundle"; return 1; }

    if ! ac_ingest_validate "$bundle"; then
        ac_ingest_status_set "$bundle" "failed" "validation"
        return 1
    fi

    ac_ingest_status_set "$bundle" "claimed"

    # Resolve relationships (may backup+remove existing tree for supersedes,
    # or set AC_INGEST_MODE=extends to redirect into the existing project).
    if ! ac_ingest_handle_relationships_pre "$bundle"; then
        ac_ingest_status_set "$bundle" "failed" "relationship handling"
        return 1
    fi

    local target
    case "$AC_INGEST_MODE" in
        extends)
            target=$(ac_registry_get "$AC_INGEST_NAME" path)
            ;;
        *)
            target="$ANTCRATE_ROOT/$AC_INGEST_DOMAIN/$AC_INGEST_NAME"
            if [[ -e "$target" && -n "$(ls -A "$target" 2>/dev/null)" ]]; then
                ac_error "ingest: target $target exists and is non-empty"
                ac_ingest_status_set "$bundle" "failed" "target not empty"
                return 1
            fi
            if ! ac_ingest_materialize_source "$bundle" "$target"; then
                ac_ingest_status_set "$bundle" "failed" "source materialization"
                return 1
            fi
            ;;
    esac

    if ! ac_ingest_copy_opaque "$bundle" "$target"; then
        ac_ingest_status_set "$bundle" "failed" "opaque copy"
        return 1
    fi

    if [[ "$AC_INGEST_MODE" != "extends" ]]; then
        ac_registry_upsert "$AC_INGEST_NAME" "$target" "$AC_INGEST_DOMAIN" ""
    fi
    ac_registry_apply --arg n "$AC_INGEST_NAME" --arg o "$AC_INGEST_OBJECTIVE" \
        '.projects[$n].objective = $o'

    ac_ingest_status_set "$bundle" "ingested"
    ac_info "ingest: $AC_INGEST_NAME → $target (mode=$AC_INGEST_MODE)"
    # auto-regen runs inside the lock so AC_INGEST_NAME is in scope
    if declare -f ac_diagrams_auto_regen >/dev/null 2>&1; then
        ac_diagrams_auto_regen "$AC_INGEST_NAME" >/dev/null 2>&1 || true
    fi
    printf '%s\n' "$target"
}
