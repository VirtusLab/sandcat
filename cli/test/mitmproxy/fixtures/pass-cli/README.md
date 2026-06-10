# pass-cli `info` golden samples

These files capture the `pass-cli info` output contract that the mitmproxy
addon's PAT-detection heuristic depends on
(`_pass_cli_session_is_pat` in `mitmproxy_addon_common.py`, which regex for the
`Personal Access Token` label).

| File                     | Session type                                 | Regex must    |
| ------------------------ | -------------------------------------------- | ------------- |
| `info_pat.txt`           | Logged in with a scoped PAT                  | **match**     |
| `info_full_account.txt`  | Logged in with full account creds            | **not** match |
| `VERSION`                | pass-cli version these were verified against | —             |

## Why this exists

`pass-cli` is pinned by version **and** per-arch sha256 in
[`images/mitmproxy-pass/pass-cli.env`](../../../../../images/mitmproxy-pass/pass-cli.env),
so the binary cannot change under us on a weekly image rebuild. The only way the
`info` output contract can change is a deliberate version bump. The contract
test ties these goldens to `PASS_CLI_VERSION`: bumping the pin without
re-capturing the goldens turns CI red, forcing re-verification at exactly the
moment the risk is introduced.

## Source of the current samples

- `info_pat.txt` — a real `pass-cli info` capture of a PAT session: a PAT
  session prints only `Release track` and `Personal Access Token` (no
  `ID` / `Username` / `Email`).
- `info_full_account.txt` — taken from the Proton Pass CLI docs
  (<https://protonpass.github.io/pass-cli/commands/info/>), which show
  `Release track / ID / Username / Email` for a full account.

> The full-account sample is still doc-derived. When you next have a throwaway
> full account to hand, replace it with a verbatim capture (see below) so the
> negative case reflects the literal binary output.

## How to re-capture when bumping pass-cli

Do this **locally** — never put a full-account credential in CI.

```bash
# Use the version you just pinned in images/mitmproxy-pass/pass-cli.env
cd cli/test/mitmproxy/fixtures/pass-cli

# 1. PAT session (scoped token — safe)
PROTON_PASS_PERSONAL_ACCESS_TOKEN='pst_...' pass-cli login
pass-cli info > info_pat.txt
pass-cli logout

# 2. Full-account session (do this in a throwaway/empty account)
pass-cli login --interactive you@proton.me
pass-cli info > info_full_account.txt
pass-cli logout

# 3. Record the version you captured against
pass-cli --version  # confirm it matches PASS_CLI_VERSION
echo '<new-version>' > VERSION
```

Then run the contract test:

```bash
pytest cli/test/mitmproxy/test_mitmproxy_addon.py -k PassCliPatContract -v
```

If `info_pat.txt` no longer matches or `info_full_account.txt` now matches, the
upstream wording changed — update `_PAT_SESSION_MARKER` in
`mitmproxy_addon_common.py` accordingly before merging the bump.
