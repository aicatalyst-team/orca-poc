# Orca server runtime for OpenShell sandboxes.
# Built from the official orca-server-linux-x64 tarball, which bundles its own
# Node (no GUI libs needed: ldd on the bundled node shows glibc-only deps).
FROM debian:13-slim

ARG ORCA_VERSION=v1.4.273
ARG ORCA_SERVER_SHA256=be4e205696d0387677a17629f9c20ae1f432206eb1c4e2864d216e9cc3331d35

ENV DEBIAN_FRONTEND=noninteractive
# SQLite (node:sqlite inside orcad) resolves its temp directory to /var/tmp
# when TMPDIR is unset, and /var/tmp is denied by the OpenShell sandbox fs
# policy. Any query that spills a sorter/temp file to disk then fails with
# SQLITE_CANTOPEN (14) — seen as "Orca couldn't save this to the chat's
# history". /tmp is writable in the sandbox; point everything at it.
ENV TMPDIR=/tmp

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    bash \
    ca-certificates \
    curl \
    git \
    procps \
    util-linux \
  && rm -rf /var/lib/apt/lists/*

# Node for the Codex agent CLI. The Orca server bundles its own separate Node.
COPY --from=node:22-bookworm-slim /usr/local/ /usr/local/
RUN npm install -g @openai/codex && npm cache clean --force

# Orca server bundle, checksum-pinned to the release. Installed under
# /usr/local, NOT /opt: OpenShell's default sandbox policy denies all access
# (read/exec) to /opt/**, which made the canonical `orca serve` command fail
# to exec and provisioning time out with a misleading
# "DependenciesNotReady: sandbox-runtime enforcement dependencies" error.
RUN curl -fsSL -o /tmp/orca-server.tar.gz \
    "https://github.com/stablyai/orca/releases/download/${ORCA_VERSION}/orca-server-linux-x64.tar.gz" \
  && echo "${ORCA_SERVER_SHA256}  /tmp/orca-server.tar.gz" | sha256sum -c - \
  && tar -xzf /tmp/orca-server.tar.gz -C /usr/local \
  && mv /usr/local/orca-server-*-linux-x64 /usr/local/orca-server \
  && ln -s /usr/local/orca-server/bin/orca-ide /usr/local/bin/orca \
  && rm /tmp/orca-server.tar.gz

# OpenShell mounts the persistent workspace here; HOME is set by the sandbox.
RUN mkdir -p /sandbox
