# Rootless Deploy Image Design

## Context

The stable upstream image uses s6-overlay as PID 1. Its bootstrap starts with
root privileges, prepares `/run`, changes the built-in `hermes` UID and GID,
repairs bind-mount ownership, and then drops privileges for application
processes. This conflicts with deployments that require all containers to
start as an arbitrary non-root UID, use a read-only root filesystem, drop all
capabilities, and set `no-new-privileges`.

The fork deploys one `hermes gateway run` process per Swarm service. Swarm
already provides restart policy and service lifecycle management, so the
multi-service s6 supervisor is not required for this deployment.

## Architecture

Keep the upstream Dockerfile and its default image behavior intact. Name its
runtime stage and add a final `deploy-rootless` target that inherits the
already-built application. The target removes s6-overlay runtime files,
removes setuid and setgid permission bits, selects a non-setuid `tini` as PID
1, and uses a fork-owned rootless entrypoint.

The image declares the upstream `hermes` user as a safe default, but operators
may override it with any numeric `user: "UID:GID"` without rebuilding. The
entrypoint never calls `chown`, `usermod`, `groupmod`, `sudo`, or an s6 helper.
It requires `/opt/data` and the selected working directory to be writable by
the configured runtime identity. It may write only to mounted state paths and
`/tmp`; `/opt/hermes` remains immutable.

The rootless bootstrap creates the Hermes state directories, seeds missing
configuration files without replacing existing files, runs the existing
configuration migration and bundled-skill synchronization as the current
user, and then executes the requested Hermes command. `tini` forwards signals
and reaps orphaned children without gaining additional privileges.

## Deployment Contract

Production services use:

- an arbitrary numeric `user: "UID:GID"`;
- `read_only: true`;
- `cap_drop: [ALL]`;
- `security_opt: [no-new-privileges:true]`;
- writable bind mounts at `/opt/data` and the configured workspace;
- a writable, `noexec`, `nosuid` tmpfs at `/tmp`;
- no `/run` mount and no UID/GID remapping environment variables.

The host or storage provisioner owns directory preparation. Startup fails with
an actionable error if `/opt/data` is not writable by the configured identity.

## Verification

The fork workflow builds only the `deploy-rootless` target. Before publishing,
it starts the image as a non-existent numeric UID/GID with a read-only rootfs,
all capabilities dropped, and privilege escalation disabled. The check
asserts the runtime identity, immutable application tree, writable mounted
paths, absence of `/init`, and successful Hermes CLI startup.
