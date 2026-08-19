# Use shlex.quote for sandcat.env generation (issue #19) — Design

## Goal

Replace the hand-rolled `_shell_escape` in `mitmproxy_addon_common.py` with stdlib `shlex.quote` when generating `sandcat.env`, fixing a real value-corruption bug (embedded newlines), closing an interactive-shell edge (`!` history expansion), and eliminating a hand-maintained escaping table.

## Motivation

`_write_placeholders_env` emits `export NAME="<escaped>"` lines consumed by shell `source` in `app-init.sh` (and via the `/etc/profile.d/sandcat-env.sh` copy). Values flow from the user's settings.json AND from secret vaults (1Password `op read`, ProtonPass) — semi-external input, so robust quoting is defense-in-depth.

Defects in the current `_shell_escape`:

1. **Newline corruption**: `\n` → `\\n`, but inside double quotes the shell does NOT interpret `\n` — a value containing a real newline is silently corrupted into a literal backslash-n. The unit test `test_newlines_escaped` locks in this wrong behavior.
2. **`!` unhandled**: harmless in non-interactive sourcing, but a user manually sourcing `sandcat.env` in an interactive bash gets history expansion on values containing `!`.
3. **Maintenance anti-pattern**: hand-rolled escape tables are what `shlex.quote` exists to replace.

No live injection hole today — `\`, `"`, `$`, `` ` `` are covered — this is robustness hardening, not an active-exploit fix.

## Design

In `_write_placeholders_env`:

```python
import shlex  # module-level import

lines.append(f"export {name}={shlex.quote(value)}")            # env vars
lines.append(f"export {name}={shlex.quote(entry['placeholder'])}")  # placeholders
```

- Delete `_shell_escape` entirely (no other callers — verified).
- Keep `_validate_env_name` unchanged (names still regex-validated; quoting applies to values only).
- `shlex.quote` semantics: safe charset (`[\w@%+=:,./-]`) → returned bare (e.g. `export X=SANDCAT_PLACEHOLDER_X`); anything else → single-quoted with the `'"'"'` dance for embedded single quotes. Both forms source identically.
- Multi-line values now produce multi-line quoted exports — valid shell, value preserved bit-perfect.

## Consumers audit (verified)

- `app-init.sh`: `cp` to profile.d + `. sandcat.env` (shell source) — quoting-agnostic. ✓
- `su - vscode -c '. /mitmproxy-config/sandcat.env; ...'` — shell source. ✓
- No non-shell parser of sandcat.env exists (compose does not env_file it; no grep-based consumers in scripts).
- Only shell-construction site in the addons — no `shell=True` subprocess anywhere.

## Testing

- **Unit (pytest)**: update ~10 assertions locking the `export X="..."` format to the shlex format; replace `TestShellEscapingStaticHelpers` with tests asserting: safe values bare, spaces single-quoted, `$(cmd)`/backtick/quote/backslash values round-trip through `shlex.split` back to the original, newline preserved literally, `!` quoted. The existing injection test (`$(rm -rf /)` + backtick) is updated to assert the single-quoted form.
- **Round-trip property**: the strongest unit assertion is `shlex.split(line)` recovering `NAME=<original value>` — tests the actual contract (what a shell sees), not the escape spelling.
- **Integration (real container)**: settings.json `env` with a hostile value — spaces, `"`, `'`, `$(reboot)`, backtick, `$HOME`, `!`, literal newline — then inside the agent container `printf '%s' "$X" | od -c` (or compare via `python3 -c`) proves bit-perfect delivery. Also confirm placeholders still substitute end-to-end (curl through proxy with a secret).

## Global Constraints

- `shlex.quote` from stdlib; no new dependencies.
- `_shell_escape` removed, not deprecated.
- `sandcat.env` line format: `export NAME=<shlex.quote(value)>` — no double-quote wrapper.
- `_validate_env_name` untouched.
- All existing pytest + bats suites green; format-locking assertions updated, not weakened (injection test keeps asserting hostile input is neutralized).
