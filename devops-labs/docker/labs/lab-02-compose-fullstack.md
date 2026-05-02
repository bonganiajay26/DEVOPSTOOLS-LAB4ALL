# Lab 02: Docker Compose — Full-Stack Application

**Difficulty**: Intermediate | **Time**: 60 minutes  
**Goal**: Build and run a complete 3-tier application with Docker Compose.

---

## Architecture

```
Browser → Nginx (port 80)
                │
                ▼
         Flask API (port 5000)
                │
         ┌──────┴──────┐
    Postgres        Redis
   (5432)          (6379)
```

---

## Part 1: Build the Application

```bash
mkdir compose-lab && cd compose-lab

# ── Flask API ─────────────────────────────────────────────────
mkdir api && cat > api/app.py << 'EOF'
from flask import Flask, jsonify, request
import psycopg2
import redis
import os
import json
import time

app = Flask(__name__)

# Database connection
def get_db():
    return psycopg2.connect(os.environ['DATABASE_URL'])

# Redis connection  
r = redis.from_url(os.environ['REDIS_URL'])

@app.route('/health')
def health():
    # Check DB
    try:
        conn = get_db()
        conn.close()
        db_status = "healthy"
    except:
        db_status = "unhealthy"

    # Check Redis
    try:
        r.ping()
        redis_status = "healthy"
    except:
        redis_status = "unhealthy"

    return jsonify({
        "status": "healthy" if db_status == redis_status == "healthy" else "degraded",
        "database": db_status,
        "cache": redis_status
    })

@app.route('/api/items', methods=['GET'])
def get_items():
    # Try cache first
    cached = r.get('items')
    if cached:
        return jsonify({"items": json.loads(cached), "source": "cache"})

    # Query DB
    conn = get_db()
    cursor = conn.cursor()
    cursor.execute("SELECT id, name, price FROM items ORDER BY id")
    rows = cursor.fetchall()
    conn.close()

    items = [{"id": r[0], "name": r[1], "price": float(r[2])} for r in rows]

    # Cache for 30 seconds
    r.setex('items', 30, json.dumps(items))

    return jsonify({"items": items, "source": "database"})

@app.route('/api/items', methods=['POST'])
def create_item():
    data = request.json
    conn = get_db()
    cursor = conn.cursor()
    cursor.execute(
        "INSERT INTO items (name, price) VALUES (%s, %s) RETURNING id",
        (data['name'], data['price'])
    )
    item_id = cursor.fetchone()[0]
    conn.commit()
    conn.close()

    # Invalidate cache
    r.delete('items')

    return jsonify({"id": item_id, "name": data['name'], "price": data['price']}), 201

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000)
EOF

cat > api/requirements.txt << 'EOF'
flask==3.0.0
psycopg2-binary==2.9.9
redis==5.0.1
gunicorn==21.2.0
EOF

cat > api/Dockerfile << 'EOF'
FROM python:3.12-slim
RUN apt-get update && apt-get install -y --no-install-recommends curl && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py .
EXPOSE 5000
HEALTHCHECK --interval=10s --timeout=5s --retries=3 CMD curl -f http://localhost:5000/health || exit 1
CMD ["gunicorn", "--bind", "0.0.0.0:5000", "--workers", "2", "app:app"]
EOF
```

### Database init script

```bash
mkdir db && cat > db/init.sql << 'EOF'
CREATE TABLE IF NOT EXISTS items (
    id    SERIAL PRIMARY KEY,
    name  VARCHAR(255) NOT NULL,
    price DECIMAL(10,2) NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

INSERT INTO items (name, price) VALUES
    ('Widget A', 9.99),
    ('Widget B', 19.99),
    ('Premium Widget', 49.99)
ON CONFLICT DO NOTHING;
EOF
```

### Nginx config

```bash
mkdir nginx && cat > nginx/nginx.conf << 'EOF'
events { worker_connections 256; }

http {
    upstream api {
        server api:5000;
    }

    server {
        listen 80;

        location /api {
            proxy_pass http://api;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
        }

        location /health {
            proxy_pass http://api/health;
        }

        location / {
            return 200 '{"service": "compose-lab", "status": "running"}';
            add_header Content-Type application/json;
        }
    }
}
EOF
```

---

## Part 2: Docker Compose File

```bash
cat > docker-compose.yml << 'EOF'
name: compose-lab

services:
  nginx:
    image: nginx:1.25-alpine
    ports:
      - "80:80"
    volumes:
      - ./nginx/nginx.conf:/etc/nginx/nginx.conf:ro
    depends_on:
      api:
        condition: service_healthy
    networks:
      - frontend

  api:
    build: ./api
    environment:
      DATABASE_URL: postgresql://appuser:apppass@postgres:5432/appdb
      REDIS_URL: redis://redis:6379/0
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
    networks:
      - frontend
      - backend
    restart: unless-stopped

  postgres:
    image: postgres:15-alpine
    environment:
      POSTGRES_USER: appuser
      POSTGRES_PASSWORD: apppass
      POSTGRES_DB: appdb
    volumes:
      - pgdata:/var/lib/postgresql/data
      - ./db/init.sql:/docker-entrypoint-initdb.d/init.sql:ro
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U appuser -d appdb"]
      interval: 5s
      timeout: 3s
      retries: 5
    networks:
      - backend

  redis:
    image: redis:7-alpine
    command: redis-server --maxmemory 64mb --maxmemory-policy allkeys-lru
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 5s
      timeout: 3s
      retries: 3
    networks:
      - backend

networks:
  frontend:
  backend:

volumes:
  pgdata:
EOF
```

---

## Part 3: Run and Test

```bash
# Start everything
docker compose up -d

# Watch startup
docker compose logs -f

# Check status
docker compose ps

# Test the API
curl http://localhost/health | jq .
curl http://localhost/api/items | jq .

# Create an item
curl -X POST http://localhost/api/items \
  -H "Content-Type: application/json" \
  -d '{"name": "New Widget", "price": 29.99}' | jq .

# Test caching (second request = cache hit)
curl http://localhost/api/items | jq .source   # "database"
curl http://localhost/api/items | jq .source   # "cache"

# Scale the API
docker compose up -d --scale api=3
docker compose ps   # 3 API instances!

# Watch load balancing
for i in {1..6}; do
  curl -s http://localhost/api/items | jq -r .source
done
```

---

## Part 4: Development Workflow

```bash
# Create override file for development
cat > docker-compose.override.yml << 'EOF'
services:
  api:
    build:
      context: ./api
    volumes:
      - ./api/app.py:/app/app.py    # Live code reload
    environment:
      FLASK_ENV: development
      FLASK_DEBUG: "1"
    command: python app.py          # Override gunicorn with flask dev server
    ports:
      - "5000:5000"                 # Direct access for debugging
EOF

# Edit app.py on host → changes immediately visible in container
docker compose up api -d

# Make a change
echo "    # added comment" >> api/app.py

# Flask hot-reload picks it up automatically!
curl http://localhost:5000/health
```

---

## Part 5: Cleanup

```bash
# Stop and remove containers + networks
docker compose down

# Also remove volumes (DELETES DATA)
docker compose down -v

# Remove built images
docker compose down --rmi all

cd ..
rm -rf compose-lab
```

## What You Learned

- [x] Multi-service Docker Compose setup
- [x] Service health checks and dependency ordering
- [x] Network isolation (frontend/backend separation)
- [x] Named volumes for data persistence
- [x] Scaling services horizontally
- [x] Development overrides for hot reload
