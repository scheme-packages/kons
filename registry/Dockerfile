FROM node:26-bookworm-slim

WORKDIR /app

RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates tar gzip \
  && rm -rf /var/lib/apt/lists/*

COPY package.json package-lock.json ./
RUN npm ci --omit=dev

COPY server.js smtp.js ./
COPY public ./public

RUN mkdir -p /var/lib/kons-registry

ENV KONS_REGISTRY_HOST=0.0.0.0
ENV KONS_REGISTRY_PORT=8787
ENV KONS_REGISTRY_DATA=/var/lib/kons-registry

EXPOSE 8787

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:8787/healthz').then((r)=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

CMD ["node", "server.js"]
