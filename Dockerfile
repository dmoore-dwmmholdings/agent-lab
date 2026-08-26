ARG UV_VERSION=0.12.6
FROM ghcr.io/astral-sh/uv:${UV_VERSION} AS uvbin

# Shared image for every Agent Lab flavour.
#
# The instructions are ordered so that the expensive base layers are byte
# identical for Codex and Claude and are therefore built once and reused. Only
# the trailing agent-specific layers differ between the two images.
FROM node:22-bookworm-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       bash build-essential ca-certificates curl dbus-x11 ffmpeg fluxbox git gnupg \
       procps xterm \
       fonts-dejavu-core libdbus-1-3 libegl1 libgl1 libglib2.0-0 libgomp1 \
       libopengl0 libx11-dev libxkbcommon0 openssh-client pkg-config ripgrep tar \
       x11-apps x11-utils \
       x11vnc x11-utils x11-xserver-utils xvfb novnc websockify \
    && install -d -m 755 /etc/apt/keyrings \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
       -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
       > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends gh \
    && curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg \
       | gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
       > /etc/apt/sources.list.d/google-cloud-sdk.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends google-cloud-cli \
    && case "$(dpkg --print-architecture)" in \
         amd64) java_arch=x64 ;; \
         arm64) java_arch=aarch64 ;; \
         *) echo "Unsupported Java architecture" >&2; exit 1 ;; \
       esac \
    && mkdir -p /opt/java/openjdk-21 \
    && curl -fsSL "https://api.adoptium.net/v3/binary/latest/21/ga/linux/${java_arch}/jdk/hotspot/normal/eclipse" -o /tmp/openjdk-21.tar.gz \
    && tar -xzf /tmp/openjdk-21.tar.gz --strip-components=1 -C /opt/java/openjdk-21 \
    && rm /tmp/openjdk-21.tar.gz \
    && ln -s /opt/java/openjdk-21/bin/java /usr/local/bin/java \
    && ln -s /opt/java/openjdk-21/bin/javac /usr/local/bin/javac \
    && ln -s /opt/java/openjdk-21/bin/jar /usr/local/bin/jar \
    && rm -rf /var/lib/apt/lists/*

# Shared developer base. Identical for both agents, so this layer is cached once.
RUN npm install --global firebase-tools@15 pnpm

# uv covers the whole Python story on its own: it resolves and installs
# dependencies and will fetch a matching interpreter when a project asks for one
# the image does not have, so no separate pyenv or pip bootstrap is needed.
COPY --from=uvbin /uv /uvx /usr/local/bin/

COPY lab-entrypoint.mjs /usr/local/bin/agent-lab-entrypoint.mjs
COPY agent-lab-guidance.md /opt/agent-lab/guidance.md
COPY gui-entrypoint.sh /usr/local/bin/agent-lab-gui-entrypoint
RUN chmod 755 /usr/local/bin/agent-lab-entrypoint.mjs /usr/local/bin/agent-lab-gui-entrypoint

# Framewatch depends only on the flavour, never on which agent is installed,
# so it is built before the agent layer. That lets the Codex and Claude GUI
# images share one compiled result instead of each paying for the same Rust build.
ARG FRAMEWATCH_VERSION=0.8.5
ARG INSTALL_FRAMEWATCH=0
RUN if [ "$INSTALL_FRAMEWATCH" = 1 ]; then \
      curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal \
       && /root/.cargo/bin/cargo install --locked framewatch --version "$FRAMEWATCH_VERSION" --features linux-x11 \
       && install -m 755 /root/.cargo/bin/framewatch /usr/local/bin/framewatch; \
    fi

# Everything below is agent specific.
ARG AGENT_PACKAGE=@openai/codex
RUN npm install --global "$AGENT_PACKAGE"

ARG LAB_USER=codex
RUN useradd --create-home --shell /bin/bash "$LAB_USER"

# Agents run unprivileged and cannot write to the global npm prefix. Give them a
# writable user-level prefix so `npm install -g` from a setup command works.
ENV NPM_CONFIG_PREFIX=/home/$LAB_USER/.npm-global
ENV PATH=/home/$LAB_USER/.npm-global/bin:$PATH

# Claude Code cannot self-update a root-installed package; the launcher rebuilds
# the image instead. Harmless for agents that ignore the variable.
ARG DISABLE_AUTOUPDATER=0
ENV DISABLE_AUTOUPDATER=$DISABLE_AUTOUPDATER

# uv's cache lives in the agent's home volume while .venv lives on the bind
# mounted project, so they are always on different filesystems and uv's default
# hardlinking cannot work. Copy instead, or every sync warns about it.
ENV UV_LINK_MODE=copy

ENV CLOUDSDK_CONFIG=/gcloud GOOGLE_APPLICATION_CREDENTIALS=/gcloud/application_default_credentials.json
ENV JAVA_HOME=/opt/java/openjdk-21

USER $LAB_USER
WORKDIR /workspace
CMD ["bash"]
