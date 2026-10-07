FROM node:24-slim

# Strumenti di base per l'agente
RUN apt-get update && apt-get install -y --no-install-recommends \
      git ca-certificates curl ripgrep \
    && rm -rf /var/lib/apt/lists/*

# OpenCode con versione FISSATA: sostituisci con quella che hai testato
ARG OPENCODE_VERSION=2.0.23
RUN npm install -g @opencode/cli@${OPENCODE_VERSION}

# Git: identità per i commit dell'agente e fiducia sulla cartella montata
RUN git config --system user.name "Agent" \
 && git config --system user.email "agent@localhost" \
 && git config --system --add safe.directory /workspace

RUN mkdir -p /home/node/.config/opencode /home/node/.local/share/opencode \
 && chown -R node:node /home/node/.config /home/node/.local

ARG BUN_VERSION=1.4.2
RUN npm install -g bun@${BUN_VERSION}

# Utente non root (nell'immagine node è l'utente "node", UID 1000)
USER node
WORKDIR /workspace

CMD ["bash"]
