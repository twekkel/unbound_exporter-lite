FROM docker.io/nimlang/nim:2.2.10 AS builder

RUN apt-get update && apt-get install -y \
    musl \
    musl-dev \
    musl-tools \
    --no-install-recommends

WORKDIR /app
RUN nimble install -y zippy
COPY unbound_exporter.nim .

# Compile binary
RUN nim c -d:release --gcc.exe:musl-gcc --gcc.linkerexe:musl-gcc --mm:arc --opt:speed --define:lto --passC:"-flto -march=native" --passL:"-flto -static -s" unbound_exporter.nim

# Build binary only
FROM scratch AS binary
COPY --from=builder /app/unbound_exporter /unbound_exporter

# Build runnable image
FROM scratch
COPY --from=binary /unbound_exporter /unbound_exporter
ENTRYPOINT ["/unbound_exporter"]
