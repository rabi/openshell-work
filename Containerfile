FROM registry.fedoraproject.org/fedora:45
RUN dnf -y install git gh which tar xz ca-certificates fd-find ripgrep vim-enhanced tmux openssh-clients rsync \
      python3 python3-jinja2 ansible-core \
 && dnf clean all
RUN curl -fsSL https://nodejs.org/dist/v24.15.0/node-v24.15.0-linux-x64.tar.gz -o /tmp/node.tar.gz \
 && tar -C /usr/local --strip-components=1 -xzf /tmp/node.tar.gz && rm /tmp/node.tar.gz

# CACHEBUST changes on every build so the npm layer always pulls the latest
# pi/MCP packages instead of hitting podman's layer cache.
ARG CACHEBUST=1
RUN /usr/local/bin/npm i -g --ignore-scripts \
      @earendil-works/pi-coding-agent \
      @upstash/context7-mcp grep-mcp mcp-jira-cloud

COPY pi-config/ /workspace/.pi/
COPY workspace/ /workspace/

# OpenShell injects the policy-advisor skill at runtime into /etc/openshell when
# agent_policy_proposals_enabled is on; symlink it into pi's user-skills path so
# pi can submit proposals and wait for approval instead of just eating denials.
RUN mkdir -p /workspace/.pi/agent/skills && \
    ln -sfn /etc/openshell/skills/policy-advisor /workspace/.pi/agent/skills/policy-advisor

# Bake the extension packages so startup never needs the npm registry.
# HOME must be /workspace: pi installs packages under $HOME/.pi/agent.
ENV HOME=/workspace
ENV PATH=/workspace/.pi/agent/bin:/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin
RUN set -eu; for p in $(node -e 'const s=require("/workspace/.pi/agent/settings.json");for(const p of s.packages||[])console.log(p)'); do \
      echo "installing $p"; /usr/local/bin/pi install "$p"; \
    done

RUN groupadd -g 1000 sandbox && useradd -u 1000 -g sandbox -m -d /home/sandbox sandbox \
 && chown -R 1000:1000 /workspace

WORKDIR /workspace
USER 1000
ENTRYPOINT ["/usr/local/bin/pi"]
