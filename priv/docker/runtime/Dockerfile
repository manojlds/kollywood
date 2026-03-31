FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      systemd systemd-sysv dbus \
      curl git xz-utils sudo ca-certificates \
      iproute2 procps && \
    rm -rf /var/lib/apt/lists/*

# Strip unnecessary systemd targets so boot is fast
RUN rm -f /lib/systemd/system/multi-user.target.wants/* \
          /etc/systemd/system/*.wants/* \
          /lib/systemd/system/local-fs.target.wants/* \
          /lib/systemd/system/sockets.target.wants/*udev* \
          /lib/systemd/system/sockets.target.wants/*initctl* \
          /lib/systemd/system/basic.target.wants/* \
          /lib/systemd/system/anaconda.target.wants/* \
          /lib/systemd/system/systemd-resolved.service \
          /lib/systemd/system/systemd-networkd.service

RUN useradd -m -s /bin/bash runtime && \
    echo "runtime ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers.d/runtime

# Enable lingering so user services work without a login session
RUN mkdir -p /var/lib/systemd/linger && touch /var/lib/systemd/linger/runtime

# Nix single-user install (avoids needing a daemon inside the container)
RUN mkdir -m 0755 /nix && chown runtime /nix
USER runtime
RUN curl -L https://nixos.org/nix/install | sh -s -- --no-daemon

# Install devenv via nix profile
ENV PATH="/home/runtime/.nix-profile/bin:/nix/var/nix/profiles/default/bin:${PATH}"
RUN . /home/runtime/.nix-profile/etc/profile.d/nix.sh && \
    nix profile install --accept-flake-config "github:cachix/devenv/latest"

USER root

# Workspace mount point — the project repo gets bind-mounted here
VOLUME /workspace
WORKDIR /workspace

# systemd as PID 1; SIGRTMIN+3 is the correct stop signal for systemd
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
