FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      tini curl git ca-certificates sudo \
      build-essential autoconf libncurses-dev libssl-dev \
      iproute2 procps && \
    rm -rf /var/lib/apt/lists/*

RUN useradd -m -s /bin/bash runtime && \
    echo "runtime ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers.d/runtime && \
    chmod 755 /home/runtime

USER runtime

# Install mise (project-agnostic tool manager)
RUN curl https://mise.run | sh
ENV PATH="/home/runtime/.local/share/mise/shims:/home/runtime/.local/bin:${PATH}"

# Install pitchfork (process manager) via mise
RUN /home/runtime/.local/bin/mise use -g pitchfork

USER root

VOLUME /workspace
WORKDIR /workspace

# tini as PID 1 for proper signal handling and zombie reaping
ENTRYPOINT ["tini", "--"]
CMD ["sleep", "infinity"]
