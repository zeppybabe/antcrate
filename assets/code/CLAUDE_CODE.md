# Using AntCrate with Claude Code

AntCrate ships a skill bundle (`antcrate.skill`, a zip) that Claude Code can load directly.

## Install the skill into Claude Code

```bash
# extract the skill bundle into Claude Code's skill directory
mkdir -p ~/.claude/skills
unzip /path/to/antcrate.skill -d ~/.claude/skills/
# verify
ls ~/.claude/skills/antcrate/SKILL.md
```

Restart Claude Code (or open a new session in the project directory). Mention "AntCrate" in any prompt and the skill activates — Claude Code will read `state.md`, the top of `ledger.md`, and `AGENTS.md` automatically.

## Install the AntCrate runtime

```bash
cd ~/.claude/skills/antcrate/assets/code
./install.sh
antcrate --init
```

This puts `antcrate` and `antcrated` in `~/.local/bin`, libraries in `~/.local/share/antcrate/lib`, and creates `~/.antcrate/` for state.

Edit `~/.antcrate/config`:

```bash
ANTCRATE_EMAIL="you@example.com"
ANTCRATE_GIT_REMOTE_PREFIX="https://github.com/youruser/"
ANTCRATE_LOG_LEVEL="info"
```

Optional: enable the daemon

```bash
systemctl --user enable --now antcrated
antcrate --status
```

## Safety guarantees for Claude Code

Claude Code reads `assets/code/AGENTS.md` automatically when the skill is active. The agent rules enforce:

- **No destructive ops outside `~/projects/`** without per-command user approval (rule #1)
- **No deletion of `registry.json` or `/tmp/antcrate_conflict.log`** (rules #2, #3)
- **No `git push --force`** without explicit approval (rule #4)
- **No `sudo`** ever (rule #5)
- **No edits to shell rc files, `/etc/`, or anywhere outside the AntCrate write zones** (rule #6)
- **No network calls** other than `git`, `gh`, and `mailx` (rule #7)
- **No reading secrets into chat** — `.env*` is gitignored and off-limits (rule #8)

The runtime also enforces these at the Bash level via `lib/safety.sh`:

- `ac_safety_guard` aborts any path-mutating call whose target is outside `$ANTCRATE_ROOT` or `$ANTCRATE_HOME`
- Override exists but requires explicit `ANTCRATE_ALLOW_OUTSIDE_ROOT=1` in the environment — Claude Code will not set this without asking you

So even if an agent ignores `AGENTS.md`, the runtime refuses.

## GitHub via HTTPS (no PAT in plaintext)

AntCrate uses the official `gh` CLI, which stores credentials in your system keychain. Setup:

```bash
# 1. Install gh CLI:  https://cli.github.com/
# 2. Authenticate over HTTPS:
gh auth login -h github.com -p https
#    (choose: Login with a web browser)
# 3. Verify:
gh auth status
```

Then for any AntCrate project:

```bash
antcrate --start myproj --domain webapps --meta "html,css,js"
antcrate --gh-init myproj                 # private repo, push initial commit
antcrate --gh-init myproj --public        # or public
```

What `--gh-init` does:

1. Verifies `gh` is installed and authenticated
2. Looks up your GitHub username via `gh api user`
3. Creates the repo at `https://github.com/<you>/<project>.git`
4. Wires `origin` to the HTTPS URL
5. Pushes the initial commit
6. Updates the AntCrate registry with the new remote URL

If the repo already exists, `--gh-init` skips creation and just wires the remote and pushes.

After that, `antcrate --pp myproj` does ordinary auto-commit + push, with the conflict triage flow engaged on rejection.

## Asking Claude Code to use AntCrate

Once installed, you can prompt Claude Code naturally:

> _"Spin up a new webapp called `widget-shop` with html/css/js, push it to GitHub as private, and start the daemon."_

Claude Code will (per `AGENTS.md`):

```bash
antcrate --start widget-shop --domain webapps --meta "html,css,js"
antcrate --gh-init widget-shop
systemctl --user start antcrated
antcrate --status
```

If any step would touch a path outside `~/projects/` or `~/.antcrate/`, Claude Code will pause and ask before proceeding.

## Recovery

See `AGENTS.md` § "Recovery checklist" for stuck-daemon, corrupt-registry, and stale-PID procedures.
