# Production Node.js Multi-stage Dockerfile
# Build: docker build -t frontend:prod .
# Size comparison: naive image ~1.2GB → this image ~45MB

# ── Stage 1: Dependencies ────────────────────────────────────
FROM node:20-alpine AS deps
WORKDIR /app
# Copy package files first (layer cache: only reinstalls on package change)
COPY package.json package-lock.json ./
RUN npm ci --only=production && \
    # Remove npm cache to save space
    npm cache clean --force

# ── Stage 2: Build ────────────────────────────────────────────
FROM node:20-alpine AS builder
WORKDIR /app
COPY package.json package-lock.json ./
# Install ALL deps including devDependencies (need build tools)
RUN npm ci
# Copy source and build
COPY . .
RUN npm run build

# ── Stage 3: Production runtime ──────────────────────────────
FROM node:20-alpine AS production
ENV NODE_ENV=production
WORKDIR /app

# Security: non-root user (node user exists in node:alpine)
RUN chown -R node:node /app
USER node

# Copy ONLY what's needed to run
COPY --from=deps --chown=node:node /app/node_modules ./node_modules
COPY --from=builder --chown=node:node /app/dist ./dist
COPY --from=builder --chown=node:node /app/package.json ./

EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=5s \
    CMD wget -qO- http://localhost:3000/health || exit 1

CMD ["node", "dist/server.js"]

# .dockerignore (create this file too!):
# node_modules/
# .git/
# .env*
# *.test.ts
# coverage/
# .next/
# dist/
