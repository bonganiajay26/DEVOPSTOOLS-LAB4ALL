# Example 05: Go Multi-Stage Dockerfile
# Result: ~10MB image from ~900MB builder

# ── Stage 1: Build ────────────────────────────────────────────
FROM golang:1.22-alpine AS builder

# Install build dependencies
RUN apk add --no-cache git ca-certificates tzdata

WORKDIR /src

# Cache dependencies separately from source
COPY go.mod go.sum ./
RUN go mod download

# Build with optimizations
COPY . .

# Flags: strip debug info (-s -w), static binary (CGO_ENABLED=0)
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build \
    -ldflags="-s -w -X main.Version=$(git describe --tags --always)" \
    -o /app/server \
    ./cmd/server

# ── Stage 2: Test ─────────────────────────────────────────────
FROM builder AS test
RUN go test ./... -v -race -coverprofile=/tmp/coverage.out
RUN go vet ./...

# ── Stage 3: Minimal production runtime ───────────────────────
FROM scratch AS production
# 'scratch' = truly empty image. Not even a shell.

# Copy only what's needed
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
COPY --from=builder /usr/share/zoneinfo /usr/share/zoneinfo
COPY --from=builder /app/server /server

# Non-root user (no adduser in scratch, use numeric UID)
USER 65534:65534    # nobody:nobody

EXPOSE 8080

ENTRYPOINT ["/server"]

# Build commands:
# Production: docker build --target production -t myapi:latest .
# With tests: docker build --target test -t myapi:test . (fails if tests fail)
# Size check:  docker image inspect myapi:latest | jq '.[0].Size' | numfmt --to=iec
