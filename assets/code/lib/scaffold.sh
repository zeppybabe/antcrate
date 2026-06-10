#!/usr/bin/env bash
# antcrate :: lib/scaffold.sh — action dispatcher

: "${ANTCRATE_ROOT:=$HOME/projects}"
: "${ANTCRATE_TEMPLATES:=}"  # set by caller; defaults resolved below

ac_scaffold_resolve_templates() {
    # If caller explicitly set a path that has _generic or any domain subdir, honor it.
    if [[ -n "$ANTCRATE_TEMPLATES" && -d "$ANTCRATE_TEMPLATES/_generic" ]]; then return; fi
    local candidates=(
        "$HOME/.antcrate/templates"
        "$(dirname "${BASH_SOURCE[0]}")/../templates"
        "$HOME/.local/share/antcrate/templates"
    )
    local c
    for c in "${candidates[@]}"; do
        # require the candidate to actually contain templates (_generic or any domain dir)
        if [[ -d "$c/_generic" ]] || [[ -d "$c/scripts" ]] || [[ -d "$c/webapps" ]] \
           || [[ -d "$c/projects" ]] || [[ -d "$c/notes" ]]; then
            ANTCRATE_TEMPLATES="$c"
            return
        fi
    done
    ac_warn "no populated templates directory found; scaffold will create empty project dirs"
}

ac_scaffold_remote_for() {
    # ac_scaffold_remote_for <name>  — derive default remote from config
    local name="$1"
    local prefix=""
    if [[ -f "$HOME/.antcrate/config" ]]; then
        # shellcheck disable=SC1091  # user config path resolved at runtime; not statically followable
        . "$HOME/.antcrate/config"
        prefix="${ANTCRATE_GIT_REMOTE_PREFIX:-}"
    fi
    [[ -n "$prefix" ]] && printf '%s%s.git' "$prefix" "$name" || printf ''
}

ac_scaffold_apply_template() {
    # ac_scaffold_apply_template <domain> <project_dir> <name> <meta_csv...>
    local domain="$1" target="$2" name="$3"; shift 3
    local meta=("$@")

    ac_scaffold_resolve_templates
    local tdir=""
    if [[ -n "$ANTCRATE_TEMPLATES" ]]; then
        if [[ -d "$ANTCRATE_TEMPLATES/$domain" ]]; then
            tdir="$ANTCRATE_TEMPLATES/$domain"
        elif [[ -d "$ANTCRATE_TEMPLATES/_generic" ]]; then
            tdir="$ANTCRATE_TEMPLATES/_generic"
        fi
    fi

    if [[ -n "$tdir" ]]; then
        cp -rT "$tdir" "$target"
        # token substitution: __NAME__ → name, __DOMAIN__ → domain, __DATE__ → today
        local today; today=$(date +%Y-%m-%d)
        local f
        while IFS= read -r -d '' f; do
            sed -i "s|__NAME__|${name}|g; s|__DOMAIN__|${domain}|g; s|__DATE__|${today}|g" "$f"
        done < <(find "$target" -type f -print0)
    else
        mkdir -p "$target"
    fi

    # honor meta hints for webapps (html/css/js stub creation)
    if [[ "$domain" == "webapps" ]]; then
        local m
        for m in "${meta[@]}"; do
            case "${m,,}" in
                html) [[ -e "$target/index.html" ]] || cat > "$target/index.html" <<HTML
<!doctype html>
<meta charset="utf-8">
<title>${name}</title>
<link rel="stylesheet" href="style.css">
<h1>${name}</h1>
<script src="app.js"></script>
HTML
                    ;;
                css)  [[ -e "$target/style.css" ]] || printf '/* %s */\nbody{font-family:sans-serif}\n' "$name" > "$target/style.css" ;;
                js)   [[ -e "$target/app.js"   ]] || printf '// %s\nconsole.log("%s ready");\n' "$name" "$name" > "$target/app.js" ;;
            esac
        done
    fi
}

# ac_action_start <name> <domain> <meta_csv...>
ac_action_start() {
    local name="$1" domain="$2"; shift 2
    local meta=("$@")

    if ac_registry_has "$name"; then
        ac_warn "start: project '$name' already in registry — no-op"
        return 0
    fi

    local target="$ANTCRATE_ROOT/$domain/$name"
    if [[ -e "$target" ]]; then
        ac_warn "start: target exists on disk: $target — registering without scaffold"
    else
        mkdir -p "$target"
        ac_scaffold_apply_template "$domain" "$target" "$name" "${meta[@]}"
    fi

    # git init
    if command -v git >/dev/null 2>&1; then
        ( cd "$target" && git init -q && {
            [[ -e .gitignore ]] || printf '*.log\n.env*\n' > .gitignore
            git add -A
            git commit -qm "antcrate: initial commit ($name)" || true
        } )
    fi

    local remote; remote=$(ac_scaffold_remote_for "$name")
    ac_registry_upsert "$name" "$target" "$domain" "$remote"
    ac_info "start: $name → $target (remote=${remote:-none})"
}

# ac_action_register <name> <existing-path> [<domain>]
# Adds a registry entry pointing at an existing tree. No scaffold, no template.
# The path must already exist on disk. Domain defaults to the parent dir name
# of <existing-path>.
ac_action_register() {
    local name="$1" existing="$2" domain="${3:-}"
    [[ -z "$name" || -z "$existing" ]] && { ac_error "register: requires <name> <path>"; return 2; }
    [[ -d "$existing" ]] || { ac_error "register: path missing or not a directory: $existing"; return 1; }
    if ac_registry_has "$name"; then
        ac_error "register: '$name' already registered (use --rename to relabel, or pick a different name)"
        return 1
    fi
    local abs; abs=$(realpath -m "$existing")
    [[ -z "$domain" ]] && domain=$(basename "$(dirname "$abs")")
    local remote; remote=$(ac_scaffold_remote_for "$name")
    ac_registry_upsert "$name" "$abs" "$domain" "$remote"
    ac_info "register: $name → $abs (domain=$domain, remote=${remote:-none})"
}

# ac_action_branch <name> <domain> <meta_csv...>
# Treats meta as ["from=<base>"] when first value contains '='; else copies directory tree.
ac_action_branch() {
    local name="$1" domain="$2"; shift 2
    local meta=("$@")

    local base=""
    local m
    for m in "${meta[@]}"; do
        case "$m" in from=*) base="${m#from=}";; esac
    done

    if ac_registry_has "$name"; then
        ac_warn "branch: '$name' already exists — no-op"; return 0
    fi

    local target="$ANTCRATE_ROOT/$domain/$name"
    if [[ -n "$base" ]] && ac_registry_has "$base"; then
        local base_path; base_path=$(ac_registry_get "$base" path)
        cp -r "$base_path" "$target"
        ( cd "$target" && rm -rf .git && git init -q && git add -A
          git commit -qm "antcrate: branch from $base" || true )
    else
        mkdir -p "$target"
        ac_scaffold_apply_template "$domain" "$target" "$name" "${meta[@]}"
        ( cd "$target" && git init -q && git add -A
          git commit -qm "antcrate: branch $name" || true )
    fi

    local remote; remote=$(ac_scaffold_remote_for "$name")
    ac_registry_upsert "$name" "$target" "$domain" "$remote"
    [[ -n "$base" ]] && ac_registry_link "$name" "$base"
    ac_info "branch: $name → $target (base=${base:-none})"
}

# ac_action_link <a> <_ignored_domain> <meta>  — link two existing projects
# meta must contain rel=<other> or to=<other>
ac_action_link() {
    local a="$1"; shift 2
    local meta=("$@")
    local other=""
    local m
    for m in "${meta[@]}"; do
        case "$m" in rel=*|to=*) other="${m#*=}";; esac
    done
    if [[ -z "$other" ]]; then
        ac_error "link: meta must specify rel=<other> or to=<other>"; return 1
    fi
    if ! ac_registry_has "$a" || ! ac_registry_has "$other"; then
        ac_error "link: both projects must exist ($a, $other)"; return 1
    fi
    ac_registry_link "$a" "$other"
    ac_info "link: $a <-> $other"
}

# ac_action_rel <a> <_> <meta>  — convenience alias for link
ac_action_rel() { ac_action_link "$@"; }

# Top-level dispatcher: ac_scaffold_dispatch (uses AC_NAME/AC_DOMAIN/AC_ACTION/AC_META_VALUES from schema.sh)
ac_scaffold_dispatch() {
    case "$AC_ACTION" in
        start)  ac_action_start  "$AC_NAME" "$AC_DOMAIN" "${AC_META_VALUES[@]}" ;;
        branch) ac_action_branch "$AC_NAME" "$AC_DOMAIN" "${AC_META_VALUES[@]}" ;;
        link)   ac_action_link   "$AC_NAME" "$AC_DOMAIN" "${AC_META_VALUES[@]:-}" ;;
        rel)    ac_action_rel    "$AC_NAME" "$AC_DOMAIN" "${AC_META_VALUES[@]:-}" ;;
        *) ac_error "dispatch: unknown action '$AC_ACTION'"; return 1 ;;
    esac
}
