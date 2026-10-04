#!/bin/bash
# Installs, removes or inspects Tern's Claude Code hooks.
#
#   scripts/install-claude-hooks.sh install   [--app PATH] [--settings FILE] [--dry-run] [--allow-dev-path]
#   scripts/install-claude-hooks.sh uninstall [--settings FILE] [--dry-run]
#   scripts/install-claude-hooks.sh status    [--settings FILE]
#
# Hooks point at the helper inside an installed Release Tern.app (/Applications/Tern.app,
# then ~/Applications/Tern.app), never at a build folder that a clean build can empty.
# Run `install` again after upgrading Tern; it replaces Tern's entries in place.
#
# Targets user-level settings (${CLAUDE_CONFIG_DIR:-~/.claude}/settings.json) unless
# --settings is given. Existing hooks are never removed or reordered: Tern's entries are
# recognised by their `tern-hook` command and are the only ones added or deleted.
# A timestamped backup is written next to the settings file before any change.
set -euo pipefail

mode="${1:-}"
[[ -n "$mode" ]] && shift || true
settings="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
app=""
dry_run=0
allow_dev_path=0
release_id="so.plane.tern"

usage() { sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --settings) settings="$2"; shift 2 ;;
        --app) app="$2"; shift 2 ;;
        --dry-run) dry_run=1; shift ;;
        --allow-dev-path) allow_dev_path=1; shift ;;
        -h|--help) usage 0 ;;
        *) echo "Unknown option: $1" >&2; usage 1 ;;
    esac
done

case "$mode" in
    install|uninstall|status) ;;
    -h|--help|"") usage 0 ;;
    *) echo "Unknown command: $mode" >&2; usage 1 ;;
esac

hook_path=""
if [[ "$mode" == "install" ]]; then
    if [[ -z "$app" ]]; then
        for candidate in "/Applications/Tern.app" "$HOME/Applications/Tern.app"; do
            [[ -d "$candidate" ]] && app="$candidate" && break
        done
        [[ -z "$app" ]] && {
            echo "Tern isn't installed in /Applications or ~/Applications." >&2
            echo "Install it with scripts/install-tern.sh, or pass --app /path/to/Tern.app." >&2
            exit 1
        }
    fi
    app="${app%/}"
    [[ -d "$app" ]] || { echo "No app at $app." >&2; exit 1; }
    if [[ $allow_dev_path -eq 0 && "$app" == */DerivedData/* ]]; then
        echo "$app is a build output; a clean build would break the hooks." >&2
        echo "Install Tern with scripts/install-tern.sh, or pass --allow-dev-path." >&2
        exit 1
    fi
    bundle_id="$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$app/Contents/Info.plist" 2>/dev/null || true)"
    if [[ "$bundle_id" != "$release_id" ]]; then
        echo "$app is ${bundle_id:-not a Tern app}, not the Release build ($release_id)." >&2
        echo "Debug builds use their own URL scheme and must not receive real hooks." >&2
        exit 1
    fi
    hook_path="$app/Contents/Helpers/tern-hook"
    [[ -x "$hook_path" ]] || { echo "No helper at $hook_path. Reinstall Tern." >&2; exit 1; }
    "$hook_path" --version >/dev/null || { echo "Helper at $hook_path doesn't run." >&2; exit 1; }
fi

mkdir -p "$(dirname "$settings")"

osascript -l JavaScript - "$mode" "$settings" "$hook_path" "$dry_run" "$(date +%Y%m%d-%H%M%S)" <<'JS'
ObjC.import('Foundation');

// Hooks Tern needs. Mid-turn hooks run async so Claude never waits on Tern. Hooks that end
// a turn or session run synchronously (~0.1s): background hooks are killed when Claude
// exits, which would drop the final event of a `claude -p` run or a quick quit.
const SPEC = [
    { event: 'SessionStart' },
    { event: 'UserPromptSubmit' },
    { event: 'Notification', matcher: 'permission_prompt|elicitation_dialog|elicitation_url_dialog|agent_needs_input|elicitation_complete|elicitation_response' },
    { event: 'PostToolUse', matcher: '*' },
    { event: 'Stop', sync: true },
    { event: 'StopFailure', sync: true },
    { event: 'SessionEnd', sync: true },
];
const isTern = (hook) => typeof hook.command === 'string' && hook.command.includes('tern-hook');

function read(path) {
    const fm = $.NSFileManager.defaultManager;
    if (!fm.fileExistsAtPath(path)) return { exists: false, text: '' };
    const text = $.NSString.stringWithContentsOfFileEncodingError(path, $.NSUTF8StringEncoding, null);
    if (text.isNil()) throw new Error(`Can't read ${path}`);
    return { exists: true, text: text.js };
}

function removeTern(settings, log) {
    const hooks = settings.hooks;
    if (!hooks || typeof hooks !== 'object') return;
    for (const event of Object.keys(hooks)) {
        const groups = Array.isArray(hooks[event]) ? hooks[event] : [];
        const kept = [];
        for (const group of groups) {
            const before = Array.isArray(group.hooks) ? group.hooks.length : 0;
            const remaining = (group.hooks || []).filter((h) => !isTern(h));
            if (remaining.length < before) log.push(`  - removed Tern hook from ${event}`);
            if (remaining.length > 0 || before === 0) kept.push(Object.assign({}, group, { hooks: remaining }));
        }
        if (kept.length > 0) hooks[event] = kept; else delete hooks[event];
    }
    if (Object.keys(hooks).length === 0) delete settings.hooks;
}

function addTern(settings, hookPath, log) {
    settings.hooks = settings.hooks || {};
    const quoted = `'${hookPath.replace(/'/g, `'\\''`)}'`;
    for (const spec of SPEC) {
        const hook = { type: 'command', command: quoted };
        if (spec.sync) hook.timeout = 5; else hook.async = true;
        const group = spec.matcher ? { matcher: spec.matcher, hooks: [hook] } : { hooks: [hook] };
        settings.hooks[spec.event] = (settings.hooks[spec.event] || []).concat([group]);
        log.push(`  + ${spec.event}${spec.matcher ? ` (${spec.matcher === '*' ? 'all tools' : 'input requests'})` : ''}`);
    }
}

function ternCommands(settings) {
    const hooks = settings.hooks || {};
    const commands = new Set();
    for (const event of Object.keys(hooks)) {
        for (const group of hooks[event] || []) {
            for (const hook of group.hooks || []) if (isTern(hook)) commands.add(hook.command);
        }
    }
    return [...commands];
}

function ternEvents(settings) {
    const hooks = settings.hooks || {};
    return Object.keys(hooks).filter((e) => (hooks[e] || []).some((g) => (g.hooks || []).some(isTern)));
}

function run(argv) {
    const [mode, path, hookPath, dryRun, stamp] = argv;
    const file = read(path);
    let settings = {};
    if (file.exists && file.text.trim() !== '') {
        try { settings = JSON.parse(file.text); } catch (e) { throw new Error(`${path} is not valid JSON; nothing changed.`); }
    }
    if (typeof settings !== 'object' || Array.isArray(settings)) throw new Error(`${path} is not a JSON object; nothing changed.`);

    if (mode === 'status') {
        const events = ternEvents(settings);
        if (!events.length) return `No Tern hooks in ${path}.`;
        const helpers = ternCommands(settings).map((command) => {
            const helper = command.replace(/^'(.*)'$/, '$1').replace(/'\\''/g, "'");
            const ok = $.NSFileManager.defaultManager.isExecutableFileAtPath(helper);
            return `  ${helper} ${ok ? '(ok)' : '(missing: reinstall Tern, then run install again)'}`;
        });
        return `Tern hooks installed in ${path}:\n  ${events.join(', ')}\nHelper:\n${helpers.join('\n')}`;
    }

    const original = JSON.stringify(settings);
    const log = [];
    removeTern(settings, log);
    const removed = log.length;
    if (mode === 'install') addTern(settings, hookPath, log);
    const updated = JSON.stringify(settings);

    if (updated === original) {
        return mode === 'install' ? `Tern hooks already up to date in ${path}.` : `No Tern hooks in ${path}; nothing to remove.`;
    }
    const summary = mode === 'install'
        ? `${removed ? 'Reinstalled' : 'Installed'} Tern hooks in ${path} → ${hookPath}`
        : `Removed Tern hooks from ${path}`;
    const details = mode === 'install' ? log.slice(removed) : log;

    if (dryRun === '1') return `[dry run] ${summary}\n${details.join('\n')}`;

    let backup = '';
    if (file.exists) {
        backup = `${path}.tern-backup-${stamp}`;
        for (let n = 2; $.NSFileManager.defaultManager.fileExistsAtPath(backup); n++) backup = `${path}.tern-backup-${stamp}-${n}`;
        const ok = $(file.text).writeToFileAtomicallyEncodingError(backup, true, $.NSUTF8StringEncoding, null);
        if (!ok) throw new Error(`Couldn't write backup ${backup}; nothing changed.`);
    }
    const ok = $(JSON.stringify(settings, null, 2) + '\n').writeToFileAtomicallyEncodingError(path, true, $.NSUTF8StringEncoding, null);
    if (!ok) throw new Error(`Couldn't write ${path}.`);
    return `${summary}\n${details.join('\n')}${backup ? `\nBackup: ${backup}` : ''}`;
}
JS
