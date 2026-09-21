# Everything that measures the ISA against something outside zig: the corpus build, the oracle
# scripts and the bench. `zig build test` needs none of this.
FROM debian:trixie-slim@sha256:a99cfc517144bc59b1978475ec53b46ecabec7e43635402ee5b77cc54cd1b20a
ARG TARGETARCH
RUN sed -i 's|^URIs: http://deb.debian.org/debian$|URIs: http://snapshot.debian.org/archive/debian/20260920T000000Z|; \
            s|^URIs: http://deb.debian.org/debian-security$|URIs: http://snapshot.debian.org/archive/debian-security/20260920T000000Z|' \
        /etc/apt/sources.list.d/debian.sources \
    && echo 'Acquire::Check-Valid-Until "false";' > /etc/apt/apt.conf.d/snapshot \
    && apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl xz-utils perl python3 \
        llvm-19=1:19.1.7-3+b1 qemu-system-arm=1:10.0.13+ds-0+deb13u1 \
    && rm -rf /var/lib/apt/lists/*

RUN case "$TARGETARCH" in \
        amd64) arch=x86_64;  sum=70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00 ;; \
        arm64) arch=aarch64; sum=ea4b09bfb22ec6f6c6ceac57ab63efb6b46e17ab08d21f69f3a48b38e1534f17 ;; \
    esac \
    && curl -sSL -o /tmp/zig.tar.xz "https://ziglang.org/download/0.16.0/zig-$arch-linux-0.16.0.tar.xz" \
    && echo "$sum  /tmp/zig.tar.xz" | sha256sum -c \
    && tar -C /opt -xJf /tmp/zig.tar.xz && rm /tmp/zig.tar.xz \
    && ln -s "/opt/zig-$arch-linux-0.16.0/zig" /usr/local/bin/zig

RUN case "$TARGETARCH" in amd64) arch=x86_64 ;; arm64) arch=aarch64 ;; esac \
    && curl -sSL -o /tmp/sail.tar.gz "https://github.com/riscv/sail-riscv/releases/download/0.14/sail-riscv-Linux-$arch.tar.gz" \
    && tar -C /opt -xzf /tmp/sail.tar.gz && rm /tmp/sail.tar.gz \
    && ln -s "/opt/sail-riscv-Linux-$arch/bin/sail_riscv_sim" /usr/local/bin/sail_riscv_sim

WORKDIR /isa
COPY build.zig build.zig.zon ./
COPY src/ src/
COPY spec/ spec/
COPY examples/ examples/
COPY bench/ bench/
COPY corpus/ corpus/
COPY oracle/ oracle/
RUN oracle/mkref.py --check && oracle/mktrace.py --check && corpus/build.sh && bench/loops/build.sh

# Regenerate the pinned oracle text with `oracle/mkref.py` and `oracle/mktrace.py` instead.
CMD ["sh", "-ec", "zig build harness && zig build metrics"]
