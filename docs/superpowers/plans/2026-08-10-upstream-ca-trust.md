# Upstream CA Trust Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let sandcat users add CA certificates to mitmproxy's upstream trust store so agents can reach internal HTTPS services (self-signed / corporate-CA) without disabling TLS verification.

**Architecture:** New `upstream_ca_bundles` setting reads absolute host paths from `~/.config/sandcat/settings.json` (user) and `.sandcat/settings.local.json` (project per-machine). `sandcat init` validates paths, renders read-only bind-mounts on the `mitmproxy` service in `compose-proxy.yml`, and patches the entrypoint to run `update-ca-certificates` on those mounted files before dropping privileges. mitmproxy's Python `ssl` module then picks up the extended system trust store automatically. No new dependencies.

**Tech Stack:** bash + yq for CLI, mitmproxy/mitmproxy:latest (Debian 13, has `update-ca-certificates`), bats for CLI tests.

## Global Constraints

- Setting name: `upstream_ca_bundles` (plural, JSON array of strings).
- Accepted sources: `~/.config/sandcat/settings.json` and `.sandcat/settings.local.json`. NOT `.sandcat/settings.json` (that file is team-shared; absolute host paths don't belong there).
- Values: absolute host paths (start with `/`) to files containing at least one PEM certificate.
- In-container mount path: `/upstream-ca/`, read-only.
- In-container installed path: `/usr/local/share/ca-certificates/` (Debian standard for `update-ca-certificates`).
- Mount file naming: `NNN-<basename>.crt` where NNN is a 3-digit index over the merged list, and basename is the source filename stripped of any existing extension.
- Fail-fast validation at `sandcat init`: non-absolute path, missing file, unreadable file, or file without `-----BEGIN CERTIFICATE-----` line → exit non-zero with the offending path in the message.
- Absent / empty setting → zero changes to compose file. Behavior unchanged from today.

---

### Task 1: `read_upstream_ca_bundles` helper

**Files:**
- Modify: `cli/lib/composefile.bash` (append)
- Test: `cli/test/init/settings.bats` (append)

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `read_upstream_ca_bundles()` — prints newline-separated absolute paths, one per bundle entry, in the order user-then-project-local, deduplicating exact-string duplicates. Returns 0 always; empty output when nothing configured.

- [ ] **Step 1: Write the failing test**

```bash
@test "read_upstream_ca_bundles returns empty when no settings configured" {
	HOME="$BATS_TEST_TMPDIR/home" run read_upstream_ca_bundles "$BATS_TEST_TMPDIR/proj"
	assert_success
	assert_output ""
}

@test "read_upstream_ca_bundles reads user settings" {
	mkdir -p "$BATS_TEST_TMPDIR/home/.config/sandcat"
	cat > "$BATS_TEST_TMPDIR/home/.config/sandcat/settings.json" <<'EOF'
{ "upstream_ca_bundles": ["/etc/ssl/company.pem", "/opt/ca/gitlab.crt"] }
EOF
	HOME="$BATS_TEST_TMPDIR/home" run read_upstream_ca_bundles "$BATS_TEST_TMPDIR/proj"
	assert_success
	assert_line --index 0 "/etc/ssl/company.pem"
	assert_line --index 1 "/opt/ca/gitlab.crt"
}

@test "read_upstream_ca_bundles reads project settings.local.json" {
	mkdir -p "$BATS_TEST_TMPDIR/proj/.sandcat"
	cat > "$BATS_TEST_TMPDIR/proj/.sandcat/settings.local.json" <<'EOF'
{ "upstream_ca_bundles": ["/etc/ssl/proj.pem"] }
EOF
	HOME="$BATS_TEST_TMPDIR/home" run read_upstream_ca_bundles "$BATS_TEST_TMPDIR/proj"
	assert_success
	assert_output "/etc/ssl/proj.pem"
}

@test "read_upstream_ca_bundles concatenates user then project" {
	mkdir -p "$BATS_TEST_TMPDIR/home/.config/sandcat"
	mkdir -p "$BATS_TEST_TMPDIR/proj/.sandcat"
	cat > "$BATS_TEST_TMPDIR/home/.config/sandcat/settings.json" <<'EOF'
{ "upstream_ca_bundles": ["/a.pem"] }
EOF
	cat > "$BATS_TEST_TMPDIR/proj/.sandcat/settings.local.json" <<'EOF'
{ "upstream_ca_bundles": ["/b.pem"] }
EOF
	HOME="$BATS_TEST_TMPDIR/home" run read_upstream_ca_bundles "$BATS_TEST_TMPDIR/proj"
	assert_success
	assert_line --index 0 "/a.pem"
	assert_line --index 1 "/b.pem"
}

@test "read_upstream_ca_bundles ignores missing key gracefully" {
	mkdir -p "$BATS_TEST_TMPDIR/home/.config/sandcat"
	echo '{ "network": [] }' > "$BATS_TEST_TMPDIR/home/.config/sandcat/settings.json"
	HOME="$BATS_TEST_TMPDIR/home" run read_upstream_ca_bundles "$BATS_TEST_TMPDIR/proj"
	assert_success
	assert_output ""
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats cli/test/init/settings.bats -f "read_upstream_ca_bundles"`
Expected: FAIL with "command not found" or similar.

- [ ] **Step 3: Implement in `cli/lib/composefile.bash`**

Append:

```bash
# Reads the merged `upstream_ca_bundles` list from user settings
# (~/.config/sandcat/settings.json) and project settings.local.json,
# printing absolute paths one per line. Empty output if unconfigured.
# Args:
#   $1 - Project directory (contains .sandcat/settings.local.json if used)
read_upstream_ca_bundles() {
	require yq
	local project_dir=$1

	local user_settings="${HOME}/.config/sandcat/settings.json"
	local project_local="${project_dir}/.sandcat/settings.local.json"

	local out=""
	local f
	for f in "$user_settings" "$project_local"; do
		[[ -f "$f" ]] || continue
		# Extract the array; treat missing key as empty. yq prints "null"
		# for missing keys with `.foo // []`, so guard by branching on type.
		local piece
		piece=$(yq -r '(.upstream_ca_bundles // []) | .[]' "$f" 2>/dev/null || true)
		[[ -n "$piece" ]] && out+="${piece}"$'\n'
	done
	# Strip trailing newline; leave inner newlines as separators.
	printf '%s' "${out%$'\n'}"
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats cli/test/init/settings.bats -f "read_upstream_ca_bundles"`
Expected: PASS (5/5).

- [ ] **Step 5: Commit**

```bash
git add cli/lib/composefile.bash cli/test/init/settings.bats
git commit -m "feat(cli): read_upstream_ca_bundles reads user + project.local settings"
```

---

### Task 2: `validate_upstream_ca_bundle` helper

**Files:**
- Modify: `cli/lib/composefile.bash` (append)
- Test: `cli/test/init/settings.bats` (append)

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `validate_upstream_ca_bundle <path>` — validates one path. Returns 0 with no output on success; returns 1 with an error message on stderr for invalid inputs.

- [ ] **Step 1: Write the failing tests**

```bash
@test "validate_upstream_ca_bundle accepts absolute path with PEM" {
	local f="$BATS_TEST_TMPDIR/ca.pem"
	printf -- '-----BEGIN CERTIFICATE-----\nABC\n-----END CERTIFICATE-----\n' > "$f"
	run validate_upstream_ca_bundle "$f"
	assert_success
	assert_output ""
}

@test "validate_upstream_ca_bundle rejects relative path" {
	run validate_upstream_ca_bundle "relative/path.pem"
	assert_failure
	assert_output --partial "expected absolute path"
	assert_output --partial "relative/path.pem"
}

@test "validate_upstream_ca_bundle rejects missing file" {
	run validate_upstream_ca_bundle "/nonexistent/ca.pem"
	assert_failure
	assert_output --partial "file not found"
	assert_output --partial "/nonexistent/ca.pem"
}

@test "validate_upstream_ca_bundle rejects unreadable file" {
	local f="$BATS_TEST_TMPDIR/unreadable.pem"
	printf -- '-----BEGIN CERTIFICATE-----\n' > "$f"
	chmod 000 "$f"
	run validate_upstream_ca_bundle "$f"
	assert_failure
	assert_output --partial "not readable"
	chmod 644 "$f"
}

@test "validate_upstream_ca_bundle rejects non-PEM content" {
	local f="$BATS_TEST_TMPDIR/notpem.crt"
	printf 'this is not a certificate\n' > "$f"
	run validate_upstream_ca_bundle "$f"
	assert_failure
	assert_output --partial "no PEM certificate block"
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats cli/test/init/settings.bats -f "validate_upstream_ca_bundle"`
Expected: FAIL.

- [ ] **Step 3: Implement in `cli/lib/composefile.bash`**

Append:

```bash
# Validates a single upstream CA bundle path. Prints an error to stderr and
# returns 1 on failure; returns 0 silently on success.
# Args:
#   $1 - Path to check
validate_upstream_ca_bundle() {
	local path=$1
	if [[ "$path" != /* ]]; then
		echo "upstream_ca_bundles: expected absolute path, got '$path'" >&2
		return 1
	fi
	if [[ ! -e "$path" ]]; then
		echo "upstream_ca_bundles: file not found: $path" >&2
		return 1
	fi
	if [[ ! -r "$path" ]]; then
		echo "upstream_ca_bundles: file not readable: $path" >&2
		return 1
	fi
	if ! grep -q -- '-----BEGIN CERTIFICATE-----' "$path"; then
		echo "upstream_ca_bundles: no PEM certificate block in $path" >&2
		return 1
	fi
	return 0
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats cli/test/init/settings.bats -f "validate_upstream_ca_bundle"`
Expected: PASS (5/5).

- [ ] **Step 5: Commit**

```bash
git add cli/lib/composefile.bash cli/test/init/settings.bats
git commit -m "feat(cli): validate_upstream_ca_bundle rejects non-absolute / missing / non-PEM"
```

---

### Task 3: `apply_upstream_ca_bundles` compose renderer

**Files:**
- Modify: `cli/lib/composefile.bash` (append)
- Test: `cli/test/init/extensions.bats` (append — new section)

**Interfaces:**
- Consumes: `read_upstream_ca_bundles`, `validate_upstream_ca_bundle`.
- Produces:
  - `apply_upstream_ca_bundles <compose_proxy_file> <project_dir>` — reads bundles for `project_dir`, validates each, adds `<host>:/upstream-ca/NNN-<basename>.crt:ro` mounts to `.services.mitmproxy.volumes`, and rewrites the entrypoint to prepend the CA-install shell snippet. No-op (does not touch compose file at all) when no bundles are configured. On any validation failure, prints error to stderr and returns 1 without partial writes.

- [ ] **Step 1: Write the failing tests**

```bash
# --------------------------------------------------- upstream CA bundles

@test "apply_upstream_ca_bundles is a no-op with no settings" {
	local before
	before=$(cat "$BATS_TEST_TMPDIR/sandcat/compose-proxy.yml")

	HOME="$BATS_TEST_TMPDIR/home" run apply_upstream_ca_bundles \
		"$BATS_TEST_TMPDIR/sandcat/compose-proxy.yml" "$BATS_TEST_TMPDIR/proj"
	assert_success

	local after
	after=$(cat "$BATS_TEST_TMPDIR/sandcat/compose-proxy.yml")
	[ "$before" = "$after" ]
}

@test "apply_upstream_ca_bundles adds mounts for configured bundles" {
	mkdir -p "$BATS_TEST_TMPDIR/home/.config/sandcat"
	local ca="$BATS_TEST_TMPDIR/company-ca.pem"
	printf -- '-----BEGIN CERTIFICATE-----\nABC\n-----END CERTIFICATE-----\n' > "$ca"
	cat > "$BATS_TEST_TMPDIR/home/.config/sandcat/settings.json" <<EOF
{ "upstream_ca_bundles": ["$ca"] }
EOF

	HOME="$BATS_TEST_TMPDIR/home" apply_upstream_ca_bundles \
		"$BATS_TEST_TMPDIR/sandcat/compose-proxy.yml" "$BATS_TEST_TMPDIR/proj"

	yq -e ".services.mitmproxy.volumes[] | select(. == \"${ca}:/upstream-ca/000-company-ca.crt:ro\")" \
		"$BATS_TEST_TMPDIR/sandcat/compose-proxy.yml"
}

@test "apply_upstream_ca_bundles numbers multiple bundles" {
	mkdir -p "$BATS_TEST_TMPDIR/home/.config/sandcat"
	local a="$BATS_TEST_TMPDIR/a.pem" b="$BATS_TEST_TMPDIR/b.pem"
	printf -- '-----BEGIN CERTIFICATE-----\nA\n-----END CERTIFICATE-----\n' > "$a"
	printf -- '-----BEGIN CERTIFICATE-----\nB\n-----END CERTIFICATE-----\n' > "$b"
	cat > "$BATS_TEST_TMPDIR/home/.config/sandcat/settings.json" <<EOF
{ "upstream_ca_bundles": ["$a", "$b"] }
EOF

	HOME="$BATS_TEST_TMPDIR/home" apply_upstream_ca_bundles \
		"$BATS_TEST_TMPDIR/sandcat/compose-proxy.yml" "$BATS_TEST_TMPDIR/proj"

	yq -e ".services.mitmproxy.volumes[] | select(. == \"${a}:/upstream-ca/000-a.crt:ro\")" \
		"$BATS_TEST_TMPDIR/sandcat/compose-proxy.yml"
	yq -e ".services.mitmproxy.volumes[] | select(. == \"${b}:/upstream-ca/001-b.crt:ro\")" \
		"$BATS_TEST_TMPDIR/sandcat/compose-proxy.yml"
}

@test "apply_upstream_ca_bundles rewrites entrypoint to install CAs" {
	mkdir -p "$BATS_TEST_TMPDIR/home/.config/sandcat"
	local ca="$BATS_TEST_TMPDIR/ca.pem"
	printf -- '-----BEGIN CERTIFICATE-----\nX\n-----END CERTIFICATE-----\n' > "$ca"
	cat > "$BATS_TEST_TMPDIR/home/.config/sandcat/settings.json" <<EOF
{ "upstream_ca_bundles": ["$ca"] }
EOF

	HOME="$BATS_TEST_TMPDIR/home" apply_upstream_ca_bundles \
		"$BATS_TEST_TMPDIR/sandcat/compose-proxy.yml" "$BATS_TEST_TMPDIR/proj"

	# The rewritten entrypoint must reference the install step and still run
	# the original dns.conf cleanup + docker-entrypoint.sh chain.
	local ep
	ep=$(yq -r '.services.mitmproxy.entrypoint | join(" ")' \
		"$BATS_TEST_TMPDIR/sandcat/compose-proxy.yml")
	[[ "$ep" == *"update-ca-certificates"* ]]
	[[ "$ep" == *"/upstream-ca"* ]]
	[[ "$ep" == *"rm -f /home/mitmproxy/.mitmproxy/dns.conf"* ]]
	[[ "$ep" == *"exec docker-entrypoint.sh"* ]]
}

@test "apply_upstream_ca_bundles fails and does not modify compose on invalid path" {
	mkdir -p "$BATS_TEST_TMPDIR/home/.config/sandcat"
	cat > "$BATS_TEST_TMPDIR/home/.config/sandcat/settings.json" <<'EOF'
{ "upstream_ca_bundles": ["/nonexistent/ca.pem"] }
EOF

	local before
	before=$(cat "$BATS_TEST_TMPDIR/sandcat/compose-proxy.yml")

	HOME="$BATS_TEST_TMPDIR/home" run apply_upstream_ca_bundles \
		"$BATS_TEST_TMPDIR/sandcat/compose-proxy.yml" "$BATS_TEST_TMPDIR/proj"
	assert_failure
	assert_output --partial "file not found"
	assert_output --partial "/nonexistent/ca.pem"

	local after
	after=$(cat "$BATS_TEST_TMPDIR/sandcat/compose-proxy.yml")
	[ "$before" = "$after" ]
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats cli/test/init/extensions.bats -f "upstream_ca_bundles"`
Expected: FAIL — function not defined.

- [ ] **Step 3: Implement in `cli/lib/composefile.bash`**

Append:

```bash
# Adds the user's upstream CA bundles as read-only bind-mounts on the
# mitmproxy service and rewrites the entrypoint to install them into the
# container's system trust store before docker-entrypoint.sh drops
# privileges. No-op when no bundles are configured. Validates each path
# before touching the compose file — on any failure, the compose file is
# left unchanged.
# Args:
#   $1 - Path to compose-proxy.yml
#   $2 - Project directory
apply_upstream_ca_bundles() {
	require yq
	local compose_file=$1
	local project_dir=$2

	local bundles=()
	local line
	while IFS= read -r line; do
		[[ -n "$line" ]] || continue
		bundles+=("$line")
	done < <(read_upstream_ca_bundles "$project_dir")

	[[ ${#bundles[@]} -eq 0 ]] && return 0

	# Fail fast if any bundle is invalid — do not touch compose file.
	local b
	for b in "${bundles[@]}"; do
		validate_upstream_ca_bundle "$b" || return 1
	done

	# Build the list of new volume entries. Naming: NNN-<basename>.crt.
	local yq_array="" idx=0 host basename mount
	for b in "${bundles[@]}"; do
		host="$b"
		basename=$(basename "$host")
		basename="${basename%.*}"
		mount=$(printf '%s:/upstream-ca/%03d-%s.crt:ro' "$host" "$idx" "$basename")
		# JSON-string escape backslashes and quotes.
		local escaped="${mount//\\/\\\\}"
		escaped="${escaped//\"/\\\"}"
		yq_array+="\"${escaped}\","
		idx=$((idx + 1))
	done
	yq_array="[${yq_array%,}]"

	yq -i ".services.mitmproxy.volumes = ((.services.mitmproxy.volumes // []) + ${yq_array})" "$compose_file"

	# Rewrite entrypoint to prepend CA installation. Preserve the existing
	# dns.conf cleanup and exec docker-entrypoint.sh chain — see design doc.
	local new_entrypoint='if [ -d /upstream-ca ] && ls /upstream-ca/*.crt >/dev/null 2>&1; then cp /upstream-ca/*.crt /usr/local/share/ca-certificates/ && update-ca-certificates >/dev/null; fi && rm -f /home/mitmproxy/.mitmproxy/dns.conf && exec docker-entrypoint.sh "$@"'
	new_entrypoint="$new_entrypoint" yq -i \
		'.services.mitmproxy.entrypoint = ["/bin/sh", "-c", strenv(new_entrypoint), "sh"]' \
		"$compose_file"
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats cli/test/init/extensions.bats -f "upstream_ca_bundles"`
Expected: PASS (5/5).

- [ ] **Step 5: Commit**

```bash
git add cli/lib/composefile.bash cli/test/init/extensions.bats
git commit -m "feat(cli): apply_upstream_ca_bundles renders mitmproxy volumes + entrypoint"
```

---

### Task 4: Wire `apply_upstream_ca_bundles` into `sandcat init`

**Files:**
- Modify: `cli/libexec/init/devcontainer`
- Test: `cli/test/init/devcontainer.bats` (append)

**Interfaces:**
- Consumes: `apply_upstream_ca_bundles`.
- Produces: `sandcat init` now processes `upstream_ca_bundles` at the same point in the flow as `apply_secret_provider` (compose-proxy customization).

- [ ] **Step 1: Write the failing test**

```bash
@test "sandcat init installs upstream_ca_bundles mount" {
	mkdir -p "$BATS_TEST_TMPDIR/home/.config/sandcat"
	local ca="$BATS_TEST_TMPDIR/company.pem"
	printf -- '-----BEGIN CERTIFICATE-----\nABC\n-----END CERTIFICATE-----\n' > "$ca"
	cat > "$BATS_TEST_TMPDIR/home/.config/sandcat/settings.json" <<EOF
{ "upstream_ca_bundles": ["$ca"] }
EOF

	local proj="$BATS_TEST_TMPDIR/proj"
	mkdir -p "$proj"
	( cd "$proj" && git init -q )

	HOME="$BATS_TEST_TMPDIR/home" run sandcat init \
		--agent claude --ide none --name testproj --path "$proj" \
		--stacks "" --secret-provider none --features "no-rtk,no-gitignore" --proxy web
	assert_success

	yq -e ".services.mitmproxy.volumes[] | select(. == \"${ca}:/upstream-ca/000-company.crt:ro\")" \
		"$proj/.devcontainer/sandcat/compose-proxy.yml"
}

@test "sandcat init fails fast when upstream_ca_bundles path is bad" {
	mkdir -p "$BATS_TEST_TMPDIR/home/.config/sandcat"
	cat > "$BATS_TEST_TMPDIR/home/.config/sandcat/settings.json" <<'EOF'
{ "upstream_ca_bundles": ["/no/such/file.pem"] }
EOF
	local proj="$BATS_TEST_TMPDIR/proj"
	mkdir -p "$proj"
	( cd "$proj" && git init -q )

	HOME="$BATS_TEST_TMPDIR/home" run sandcat init \
		--agent claude --ide none --name testproj --path "$proj" \
		--stacks "" --secret-provider none --features "no-rtk,no-gitignore" --proxy web
	assert_failure
	assert_output --partial "file not found"
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats cli/test/init/devcontainer.bats -f "upstream_ca_bundles"`
Expected: FAIL — no mount rendered.

- [ ] **Step 3: Wire into init**

In `cli/libexec/init/devcontainer`, between `apply_secret_provider` and `customize_compose_file`:

```bash
apply_secret_provider "$devcontainer_dir/sandcat/compose-proxy.yml" "$secret_provider"

apply_upstream_ca_bundles "$devcontainer_dir/sandcat/compose-proxy.yml" "$project_path"

customize_compose_file "$rel_settings_file" "$compose_file" "$agent" "$ide" "$project_name" "$stacks"
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats cli/test/init/devcontainer.bats`
Expected: PASS (all tests, including new ones).

- [ ] **Step 5: Commit**

```bash
git add cli/libexec/init/devcontainer cli/test/init/devcontainer.bats
git commit -m "feat(cli): wire apply_upstream_ca_bundles into sandcat init"
```

---

### Task 5: README documentation

**Files:**
- Modify: `README.md` (append section under the existing TLS/CA discussion)

**Interfaces:**
- Consumes: nothing.
- Produces: user-facing docs.

- [ ] **Step 1: Read current TLS/CA section**

Run: `grep -n "TLS\|trust store\|CA store" README.md | head`. Note the exact anchor line.

- [ ] **Step 2: Insert new subsection**

Under the existing "trust store" discussion (near where Python/uv was documented in PR #91), append:

```markdown
### Trusting internal CAs upstream

If your organization runs internal HTTPS services (e.g. an on-prem Nexus,
GitLab, Artifactory) signed by an internal CA or with a self-signed
certificate, sandcat's mitmproxy will fail to validate those upstreams by
default — the `mitmproxy/mitmproxy:latest` image ships a stock Debian
public-CA bundle and does not know about your internal CA.

Add the CA(s) to `upstream_ca_bundles` in
`~/.config/sandcat/settings.json` (per-user) and/or
`.sandcat/settings.local.json` (per-project, per-machine — file is
git-ignored by default):

    {
      "upstream_ca_bundles": [
        "/etc/ssl/company-ca.pem"
      ]
    }

Values are absolute paths on the host. Files are bind-mounted read-only
into mitmproxy at `/upstream-ca/` and installed into its system trust
store via `update-ca-certificates` at container start. mitmproxy's
Python `ssl` module then trusts them for upstream TLS validation
automatically. Public CAs are **extended, not replaced** — public HTTPS
services keep working.

Re-run `sandcat init` after adding, removing, or changing paths in this
setting (bind-mounts are set at compose-render time). Changing only the
contents of an already-mounted CA file requires just
`docker compose restart mitmproxy`.

Security note: a CA you add here is trusted by mitmproxy for every
upstream that CA signs — the same risk model as installing a CA in your
OS. Add only CAs you or your organization control.
```

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: document upstream_ca_bundles setting"
```

---

### Task 6: Hands-on integration verification

**Files:**
- No files modified. Produces evidence for the PR body.

**Interfaces:**
- Consumes: everything above.
- Produces: PASS/FAIL log covering the real user scenario.

- [ ] **Step 1: Prepare a self-signed upstream**

Generate a self-signed CA + server cert, run a minimal HTTPS server on the host bound to some port (or use a local docker container in the same test project). Record the CA path (`/tmp/pr-ca-trust/ca.pem`).

- [ ] **Step 2: Scratch project WITHOUT bundle — confirm failure**

    mkdir -p /tmp/pr-ca-trust/proj && cd /tmp/pr-ca-trust/proj && git init -q
    sandcat init --agent claude --ide none --name ca-trust --path . \
      --stacks "" --secret-provider none --features "no-rtk,no-gitignore" --proxy web
    docker compose -f .devcontainer/compose-all.yml up -d --build
    # Also configure extra_hosts in ~/.config/sandcat/settings.json to
    # point the internal FQDN at the test server's IP.
    docker compose -f .devcontainer/compose-all.yml exec -T -u vscode agent bash -lc \
      "curl -sS https://internal.test.local/ 2>&1 | tail -5"
    # Expect: TLS handshake failure / bad cert (upstream not trusted)

- [ ] **Step 3: Add bundle, re-init, retry**

Add to `~/.config/sandcat/settings.json`:

    { "upstream_ca_bundles": ["/tmp/pr-ca-trust/ca.pem"] }

Then:

    sandcat init --agent claude --ide none --name ca-trust --path . --stacks "" \
      --secret-provider none --features "no-rtk,no-gitignore" --proxy web
    docker compose -f .devcontainer/compose-all.yml up -d --force-recreate mitmproxy
    docker compose -f .devcontainer/compose-all.yml exec -T -u vscode agent bash -lc \
      "curl -sS https://internal.test.local/ | head -3"
    # Expect: succeeds; response body returned

- [ ] **Step 4: Confirm public HTTPS still works**

    docker compose -f .devcontainer/compose-all.yml exec -T -u vscode agent bash -lc \
      "curl -sSI https://github.com/ | head -1"
    # Expect: HTTP/2 200 (or similar) — public CA validation not broken

- [ ] **Step 5: Confirm the CA appears in mitmproxy's system store**

    docker compose -f .devcontainer/compose-all.yml exec -T mitmproxy \
      grep -c "$(openssl x509 -in /tmp/pr-ca-trust/ca.pem -fingerprint -noout | \
                 sed 's/.*=//' | tr -d ':' | cut -c1-16)" /etc/ssl/certs/ca-certificates.crt
    # Expect: >= 1 (or use a subject-CN grep — the point is: our CA is present)

- [ ] **Step 6: Teardown, log the scenarios in the PR body**

Log each of Steps 2, 3, 4, 5 with a one-line PASS/FAIL summary for the PR description.

---

## Out of scope for this plan

- Per-host trust granularity (only-trust-this-CA-for-this-hostname). Complex mitmproxy config plumbing; only add if a user asks.
- Automatic CA rotation / fetch. Users manage cert files on their host.
- Pasting PEM content directly in settings.json. Ugly, no benefit over a file path.
- Support for `.sandcat/settings.json` (team-shared project settings). Absolute host paths don't belong there; deliberately excluded.
