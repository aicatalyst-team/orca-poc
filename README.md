# Orca server in an OpenShell sandbox

Runs `orca serve` (Orca's headless runtime server) inside an OpenShell sandbox,
with the desktop app connecting as a paired client through a local port
forward. Agents run inside the sandbox under OpenShell's kernel-enforced
filesystem and network policy.

## Files

- `Dockerfile` — Debian 13 + git + Node/Codex + the checksum-pinned
  [`orca-server-linux-x64`][bundle] release bundle. The bundle ships its own
  Node (glibc-only deps, no GUI stack), so no Electron libraries are needed.
- `build.sh` — builds the base image, applies `openshell-build-image` on top,
  optionally pushes to a registry.
- `server.sh` — sandbox lifecycle: `up`, `link`, `stop`, `start`, `destroy`.
- `policy.yaml` — base sandbox policy adding the bundled Orca node to the
  `api.openai.com` and `github.com` network rules (see the Codex gotcha below).
  Pass with `ORCA_SERVER_POLICY=policy.yaml` on `up`.

[bundle]: https://github.com/stablyai/orca/releases/latest

## Usage

```sh
./build.sh quay.io/aicatalyst/orca-server:latest   # build + push
ORCA_SERVER_IMAGE=quay.io/aicatalyst/orca-server:latest ./server.sh up
./server.sh link    # print the desktop pairing link (asks the running serve)
```

Then in Orca desktop: New Workspace → Add host → server panel → paste the
access link. Pairing state (E2EE keypair, device tokens) lives under `/sandbox`
and is destroyed with the sandbox; recreating means re-pairing.

## Prerequisites and gotchas

- **The gateway must be able to pull the image.** Your gateway runs remote
  Kubernetes, so the image has to be in a reachable registry — a local podman
  tag is invisible to it. A private registry needs pull credentials on the
  cluster; a public repo works (the image itself contains no secrets).
- **Attach your credential providers and network policy.** Pass provider names
  via `ORCA_SERVER_PROVIDERS="my-codex-provider"`, and/or a policy file via
  `ORCA_SERVER_POLICY=path/to/policy.yaml` — `sandbox create` applies both at
  creation. Allow at least `api.openai.com` (Codex) and `github.com` (clones,
  pushes). The serve port itself is reached through the forward, not the
  network policy.
- **The desktop connects via `localhost:6769`** (the `forward service` tunnel;
  `ORCA_SERVER_FORWARD_PORT` to change). The local forward port must differ
  from Orca's default 6768 because the local Orca desktop's own runtime
  listens there — with both on 6768, the pairing link literally points back
  at the desktop's local runtime and adding the server fails with "This link
  points back to this device". Even on 6769 the desktop warns about
  localhost links; enable the SSH-tunnel option in the Add Server dialog
  (the forward is a tunnel, same situation). If pairing is ever refused as a
  public client, add `--allow-public` to `serve_cmd` in `server.sh` — the
  forward relay should make this unnecessary.
- **The forward is supervised because it dies on its own.** `forward service`
  does not renew its gateway token while running, and the OIDC access token
  from the hypershell Keycloak is short-lived (~5 minutes), so an unattended
  forward eventually dies with `invalid token: ExpiredSignature`. `server.sh`
  runs it under a restart loop: each restart re-authenticates with the stored
  refresh token, so the tunnel comes back within ~5 seconds. `stop`/`destroy`
  tear the supervisor down. When the refresh token itself expires (Keycloak
  SSO session limits), re-authenticate once with
  `openshell gateway login` and restart with `./server.sh start`.
- **`TMPDIR=/tmp` is set in the image — do not remove it.** With `TMPDIR`
  unset, SQLite (node:sqlite inside orcad) resolves its temp directory to
  `/var/tmp`, which the sandbox fs policy denies while its usability probe
  still passes. Any SQLite query that spills a sorter or temp file to disk
  (the chat journal's ordered writes do) then fails with `SQLITE_CANTOPEN
  (14)`, surfacing in the desktop as "Orca couldn't save this to the chat's
  history. Your message was not sent." `/tmp` is writable in the sandbox.
- **Install under `/usr/local`, not `/opt`.** OpenShell's default sandbox
  policy denies all access (read/list/exec) to `/opt/**`. With the bundle in
  `/opt`, the canonical `orca serve` command fails to exec and provisioning
  times out with a misleading `DependenciesNotReady: sandbox-runtime
  enforcement dependencies are not ready` error. Exec from `/usr/local/**`
  (and standard system paths) is allowed. The sandbox filesystem is otherwise
  read-only, so the install path must be baked into the image.
- **Agent binaries need per-binary network rules.** Even after exec works, the
  sandbox's network policy gates egress per binary: the bundled orca node
  (`/usr/local/orca-server/runtimes/node-*/bin/node`) was initially denied
  `github.com:443` because the provider policy only allowed git/gh. Denied
  connections generate a policy proposal draft on the gateway; approve it
  (e.g. in the OpenShell TUI draft inbox) to merge the rule. Alternatively
  ship a policy YAML via `ORCA_SERVER_POLICY` (see `server.sh`).
- **"Codex unconfigured" despite OPENAI_API_KEY is the same per-binary rule,
  not a credentials problem.** Orca picks the key up fine: the attached
  OpenAI provider injects `OPENAI_API_KEY` into the sandbox, and orcad's
  identity resolution falls back to API-key auth when `~/.codex/auth.json`
  is absent. But the desktop's *configured* status comes from a probe that
  orcad's own node process sends to `api.openai.com` — and the bundled orca
  node is not in the provider rule's binary list, so the probe is denied and
  Codex shows as unconfigured. Diagnose with
  `grep codex /sandbox/.config/orca/logs/orcad.trace.ndjson` (look for
  `agentModelCatalog.discovery` failing with `ECONNRESET`/`EACCES`). Fix on a
  live sandbox with
  `openshell policy update orca-server --add-endpoint api.openai.com:443:read-write:rest --binary '/usr/local/orca-server/runtimes/node-*/bin/node' --wait`,
  or bake it in at creation with `ORCA_SERVER_POLICY=policy.yaml`.
- **Getting the access link with `--detach`:** detached serve output isn't in
  `openshell logs`. `./server.sh link` handles it: it runs
  `orca pair --address localhost` inside the sandbox (the CLI lives at
  `/sandbox/.config/orca/cli/bin/orca`). `--address localhost:6769` matters —
  the default advertises the sandbox's internal IP, which the desktop can't
  reach; it must dial the local forward port through the tunnel.
- **Pin the release.** `ORCA_VERSION` (build arg / env, default `v1.4.273`) and
  the matching `ORCA_SERVER_SHA256` in the Dockerfile move together; take the
  checksum from the release's `orca-server-sha256sums.txt`.
- **openshell-build-image is optional.** `sandbox create --from` accepts the
  plain base image; the tool adds OpenShell-specific image preparation. Audit
  what it baked in with the `--copy-containerfile` output (see `build.sh`).
- **Stopping vs destroying.** `stop` preserves the `/sandbox` workspace and
  pairing; `destroy` deletes it. `--restart-policy always` brings serve back
  if it exits (Orca's serve handles SIGTERM and cleans up descendants).
- **What's not in the image:** no Claude CLI, no python (the Orca bundle's
  computer-use feature needs it — add `python3` if you use that), no FUSE (not
  needed; the server bundle is a plain tarball, not an AppImage).
