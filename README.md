[![main](https://github.com/twekkel/unbound_exporter-lite/actions/workflows/ci.yml/badge.svg)](https://github.com/twekkel/unbound_exporter-lite/actions/workflows/ci.yml)

# Unbound Exporter Lite

## Introduction

An ultra‑light Prometheus [unbound_exporter](https://github.com/letsencrypt/unbound_exporter) replacement, written in [Nim](https://nim-lang.org). It compiles into a single static binary with zero external dependencies.

A minimal, high‑performance implementation of the standard `unbound_exporter` metrics with extremely low memory and CPU usage. Ideal for resource‑constrained systems, embedded devices, and environments where a compact, easy‑to‑distribute exporter is required.

---

## Key Features

* **Small Footprint:** Container images and binaries are typically around **400 kB**.
* **Memory (RSS):** Typically **under 1MB** under normal load.
* **CPU Usage:** Negligible (<0.1% on most modern systems).
* **Zero Dependencies:** Statically linked against `musl`; runs on any Linux distro.
* **Modern Nim:** Leverages `ARC` memory management and `LTO` (Link Time Optimization) for maximum speed.
* **Lightweight Drop‑in Replacement:** Compatible with Prometheus’ standard unbound_exporter metrics, making it a seamless, ultra‑small alternative for resource‑constrained systems.

---

## "Official" unbound_exporter vs lite version

| Aspect         | Unbound Exporter               | unbound_exporter-lite     |
| -------------- | ------------------------------ | ------------------------- |
| Language       | Go                             | Nim                       |
| Binary size    | ~11 MB                         | ~500 kB                   |
| Footprint      | ~13 MB                         | < 1 MB                    |
| Resource usage | Higher (depends on collectors) | Low and predictable       |
| Platform       | Many *nix systems              | Linux only                |
| Complexity     | Higher                         | Very low                  |
| Use case       | General-purpose monitoring     | Lightweight               |

The Lite version only supports HTTP, no HTTPS.

## Building

This project uses a multi-stage `Containerfile` to ensure a consistent build environment. You do not need Nim or GCC installed on your host machine.

### Build as a Container Image

To build a runnable container image for Podman or Docker, run:
```
podman build -t unbound_exporter .
```
Once the image is built, start it with:
```
podman run \
  --detach \
  --name unbound_exporter \
  --publish 9167:9167 \
  unbound_exporter
```

### Build a static binary for the host

To produce a fully self‑contained static binary you can run directly on the host, build the image with:
```
podman build --target binary -o ./bin .
```
This places the compiled binary in ./bin.
Run it with:
```
./bin/unbound_exporter
```

## Options

| Flag | Description |
|------|-------------|
| `--web.listen-address=[ADDR]:PORT` | Address and port to listen on (default: `0.0.0.0:9167`) |
| `--unbound.host=unix:///run/unbound.ctl` | Path to the real host root filesystem (default: /var/run/unbound.ctl) |
| `--help` | Show this help message |

### See also

* [unbound_exporter](https://github.com/letsencrypt/unbound_exporter)
* [node_exporter Lite](https://github.com/twekkel/node_exporter-lite)
