# Lab container: QEMU with KVM, UEFI firmware, a software TPM and the lab control daemon.
FROM ubuntu:26.04

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        ovmf \
        python3 \
        qemu-system-x86 \
        qemu-utils \
        swtpm \
        swtpm-tools \
        xorriso \
    && rm -rf /var/lib/apt/lists/*

# Disk images, overlays, TPM state and per-machine logs live on a volume mounted here.
VOLUME /var/lib/kitku-lab

# Control daemon. The compose file runs the copy from the mounted workspace instead, so
# that changes to it need a restart of this container and no rebuild.
COPY labd.py /usr/local/lib/kitku-lab/labd.py
EXPOSE 7780
CMD ["python3", "/usr/local/lib/kitku-lab/labd.py"]
