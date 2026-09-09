# Shared dependency caches

For stacks that download a lot of common dependencies, sandcat mounts a set
of **host-scoped named volumes** so `cats-effect`, `spring-boot`, etc.
downloaded in one project are instantly available in every other project on
the same host. Otherwise each sandbox re-downloads and re-stores the same
JAR trees inside its own `agent-home`, adding several GB per project.

The cache set is picked **per stack** — a project without a matching stack
gets no shared cache mounts at all. Today only the JVM stack (`--stacks java`,
also pulled in by `scala`) contributes cache entries; other language stacks
are not supported now.

Java/Scala cache mounts (all under `/home/vscode/` in the container):

| Path                        | Cache for                                             |
|-----------------------------|-------------------------------------------------------|
| `.m2/repository/`           | Maven local repository                                |
| `.cache/coursier/`          | Coursier — sbt (modern), scala-cli, Metals            |
| `.gradle/caches/`           | Gradle dependency cache                               |
| `.gradle/wrapper/dists/`    | Gradle Wrapper distributions                          |
| `.ivy2/cache/`              | Ivy — legacy sbt (pre-Coursier resolver)              |
| `.sbt/boot/`                | sbt bootstrap (sbt binaries + Scala compiler)         |

Each is a Docker named volume with a stable host-wide name
(`sandcat-cache-maven`, `sandcat-cache-coursier`, …) declared as
`external: true` in the generated `compose-all.yml`. Multiple sandcat compose
projects reference the same physical volume, and `sandcat compose down -v` on
one project will **not** wipe caches other projects rely on. The `sandcat run`
wrapper creates them lazily via `docker volume create` (idempotent), so no
manual setup is required.

Only `/home/vscode/.m2/repository/` is shared, not the whole `.m2/` — user
config like `settings.xml` stays per-project inside `agent-home`. Same pattern
for `.gradle/` (only `caches/` and `wrapper/dists/`, not `daemon/` or
`init.d/`) and `.ivy2/` (only `cache/`, not `local/` where `sbt publishLocal`
outputs live).

**Opt out per project:**

```bash
sandcat init --features no-shared-cache ...      # interactive selection also
                                                  # exposes it in the menu
```

Or set the env var before init (equivalent to the feature flag):

```bash
SANDCAT_MOUNT_SHARED_CACHE=false sandcat init ...
```

With shared cache disabled, the mount lines stay in `compose-all.yml` as
comments — you can flip individual ones back on by uncommenting.

**Trade-offs to be aware of:**

* Shared caches break sandcat's per-project isolation model for those specific
  paths. If one project's build corrupts a JAR (rare — Maven and Coursier both
  do content-hash validation), other projects using shared cache pick up the
  corruption. Disable per project if you need hermetic isolation (regulated
  environments, security-sensitive projects).
* Two parallel builds writing the same artifact rely on the tools' own file
  locking (Maven `.locks/`, Coursier per-artifact `.lock`, Gradle `.lock`).
  This works reliably in practice but is not sandcat-mediated.

**Managing shared caches:**

```bash
# Detailed table — volume name, size, file count, running container users
sandcat cache list
sandcat cache          # same as `list`

# Quick total across all shared-cache volumes
sandcat cache size

# Wipe one (next build re-downloads what the project needs)
sandcat cache rm sandcat-cache-maven

# Wipe them all — resets every shared cache on the host
sandcat cache rm --all
```

`sandcat cache rm` refuses to remove a volume that a running sandbox
still mounts; stop the sandbox first, or pass `--force` to bypass the
check (Docker will then error out if the volume is truly locked).
