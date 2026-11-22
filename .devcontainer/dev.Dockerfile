# Development container: the tools to work on KitkuProtector and to drive the lab.
#
# The user, the home directory and the workspace path are the same as on the host
# (see initialize.sh). Claude Code and the PRP tools key their state by absolute path,
# so identical paths keep that state usable inside the container.
FROM ubuntu:26.04

ARG USERNAME=dev
ARG USER_UID=1000
ARG USER_GID=1000
ARG USER_HOME=/home/dev
ARG WORKSPACE_DIR=/workspace

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        less \
        openssh-client \
        python3 \
        python3-pip \
        python3-pytest \
        python3-qemu-qmp \
        python3-venv \
        sudo \
    && rm -rf /var/lib/apt/lists/*

# The base image ships a default user with UID 1000; remove it so the host IDs are free.
RUN if id ubuntu >/dev/null 2>&1; then userdel --remove ubuntu; fi \
    && if ! getent group "$USER_GID" >/dev/null; then groupadd --gid "$USER_GID" "$USERNAME"; fi \
    && useradd --uid "$USER_UID" --gid "$USER_GID" --home-dir "$USER_HOME" --create-home --shell /bin/bash "$USERNAME" \
    && echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/$USERNAME" \
    && chmod 0440 "/etc/sudoers.d/$USERNAME" \
    && mkdir -p "$WORKSPACE_DIR" \
    && chown -R "$USER_UID:$USER_GID" "$USER_HOME" \
    && (chown "$USER_UID:$USER_GID" "$WORKSPACE_DIR" "$(dirname "$WORKSPACE_DIR")" || true)

USER $USERNAME
ENV PATH="$USER_HOME/.local/bin:$PATH"

# Mount points that Docker would otherwise create as root.
RUN mkdir -p "$USER_HOME/.claude" "$USER_HOME/.prp"

# Claude Code, so that work can continue inside the container.
RUN curl -fsSL https://claude.ai/install.sh | bash

WORKDIR $WORKSPACE_DIR
CMD ["sleep", "infinity"]
