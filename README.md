# Minimal Tailscale Build & Deploy Script (GL.iNet / OpenWrt)

This script builds a **minimal, single-binary Tailscale client + daemon** from source and optionally deploys it to a router.

It is designed for **resource-constrained devices** (like GL.iNet routers) where:
- storage space is limited
- you want full control over what gets included
- you don’t want to rely on precompiled binaries

---

## Why this exists

Most existing solutions for running Tailscale on routers rely on:
- precompiled binaries from third-party sources
- unofficial builds of unknown origin
- large, full-featured binaries that waste space

This script takes a different approach:

- Build from source
- Choose exactly what version (tag/branch) to use
- Strip unnecessary features
- Produce a single compact binary
- Avoid trusting external binaries

This requires a working **Go (Golang) environment**, but in exchange you get:
- better security (you control the build)
- smaller binaries
- reproducible results

---

## Target use case

- GL.iNet routers (OpenWrt-based)
- ARM64 / aarch64 devices (e.g. GL-AXT1800)
- Systems where `/overlay` space is limited
- Users who want a minimal Tailscale footprint

---

## What the script does

1. Lets you choose a version interactively:
   - latest tag
   - specific tag
   - branch

2. Clones the official Tailscale repository

3. Builds a single combined binary:
   - tailscaled (daemon)
   - tailscale (CLI)
   → both in one file

4. Uses aggressive feature stripping via build tags

5. Outputs:
   ./out/tailscale.combined

6. Optionally:
   - connects to your router via SSH
   - installs an SSH key if needed
   - removes old Tailscale binaries
   - deploys the new binary
   - creates:
     /usr/sbin/tailscaled
     /usr/sbin/tailscale -> tailscaled

---

## Requirements

**On your build machine:**

- Go (latest recommended)
- git
- ssh
- ssh-keygen
- sftp

Optional:
- ssh-copy-id

**On your router:**
- Stop the tailscale service if you want to deploy via ssh

---

## Usage

chmod +x build.sh
./build.sh

Follow prompts:
- choose version (tag/branch)
- wait for build
- optionally deploy to router

---

## Notes on SSH behavior

- The script first tries existing SSH key login
- If that fails:
  - it generates a key (if needed)
  - installs it on the router (one-time password prompt)
- After that, all operations use key-based SSH

---

## Binary size optimization

The script removes many optional Tailscale features such as:
- AWS / cloud integrations
- desktop features
- debug tooling
- web UI
- file sharing (Taildrop)
- Kubernetes/BGP integrations

But it keeps essential router functionality:
- routing
- DNS
- iptables integration
- exit node / subnet support (if enabled)

---

## Architecture support

Default build target:

GOOS=linux
GOARCH=arm64

This matches most modern GL.iNet routers (aarch64).

---

## Adapting to other architectures

You can easily modify:

GOOS=linux
GOARCH=arm64

Examples:

| Device           | GOARCH |
|------------------|--------|
| x86_64           | amd64  |
| Raspberry Pi 3   | arm    |
| Raspberry Pi 4   | arm64  |

---

## Important notes (OpenWrt / GL.iNet)

- /tmp is RAM → not persistent
- /usr/sbin may be overlay-backed depending on firmware
- persistent storage is usually under /overlay

If needed, adjust install paths accordingly.

---

## Security considerations

This approach is safer than downloading random binaries because:

- you build directly from the official source
- you choose the exact version
- you control included features
- you avoid supply-chain risks from third-party builds

---

## Limitations

- Requires a working Go environment
- Over-aggressive feature stripping may break some functionality if misconfigured

---

## License

Uses upstream Tailscale source code (see their repository for licensing).
