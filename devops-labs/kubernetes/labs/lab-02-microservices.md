# Lab 02: Deploy a 3-Tier Microservices Application

**Difficulty**: Intermediate | **Time**: 60 minutes  
**Goal**: Deploy a production-like app with frontend, API, database, and cache. Wire them together using Services, ConfigMaps, and Secrets.

---

## Architecture

```
Browser → Frontend (nginx) → API (Node.js) → PostgreSQL
                                           → Redis (cache)
```

---

## Setup

```bash
# Create cluster if not running
kind create cluster --name devops-lab

# Create namespace
kubectl create namespace demo-app

# Set default namespace for this lab
kubectl config set-context --current --namespace=demo-app
```

---

## Part 1: Deploy the Data Tier

### PostgreSQL StatefulSet

```bash
# Create postgres secrets
kubectl create secret generic postgres-secrets \
  --from-literal=POSTGRES_PASSWORD=devpassword123 \
  --from-literal=POSTGRES_USER=appuser \
  --from-literal=POSTGRES_DB=appdb

# Apply postgres StatefulSet
cat << 'EOF' | kubectl apply -f -
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgres
  namespace: demo-app
spec:
  serviceName: postgres-headless
  replicas: 1
  selector:
    matchLabels:
      app: postgres
  template:
    metadata:
      labels:
        app: postgres
    spec:
      containers:
      - name: postgres
        image: postgres:15-alpine
        envFrom:
        - secretRef:
            name: postgres-secrets
        env:
        - name: PGDATA
          value: /var/lib/postgresql/data/pgdata
        ports:
        - containerPort: 5432
        resources:
          requests:
            cpu: "200m"
            memory: "256Mi"
          limits:
            cpu: "500m"
            memory: "512Mi"
        readinessProbe:
          exec:
            command: ["pg_isready", "-U", "appuser", "-d", "appdb"]
          initialDelaySeconds: 10
          periodSeconds: 5
  volumeClaimTemplates:
  - metadata:
      name: postgres-data
    spec:
      accessModes: ["ReadWriteOnce"]
      resources:
        requests:
          storage: 1Gi
EOF

# Create headless + regular services
kubectl expose statefulset postgres --port=5432 --cluster-ip=None --name=postgres-headless
kubectl expose statefulset postgres --port=5432 --name=postgres

# Wait for postgres
kubectl rollout status statefulset/postgres
kubectl get pods -l app=postgres

# Verify postgres is ready
kubectl exec -it postgres-0 -- pg_isready -U appuser -d appdb
```

### Redis Deployment

```bash
kubectl create secret generic redis-secrets \
  --from-literal=REDIS_PASSWORD=redispassword123

cat << 'EOF' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: redis
  namespace: demo-app
spec:
  replicas: 1
  selector:
    matchLabels:
      app: redis
  template:
    metadata:
      labels:
        app: redis
    spec:
      containers:
      - name: redis
        image: redis:7-alpine
        command:
          - redis-server
          - --requirepass
          - $(REDIS_PASSWORD)
        env:
        - name: REDIS_PASSWORD
          valueFrom:
            secretKeyRef:
              name: redis-secrets
              key: REDIS_PASSWORD
        ports:
        - containerPort: 6379
        resources:
          requests:
            cpu: "50m"
            memory: "64Mi"
          limits:
            cpu: "200m"
            memory: "256Mi"
EOF

kubectl expose deployment redis --port=6379
kubectl rollout status deployment/redis
```

---

## Part 2: Deploy the API Service

```bash
# Create ConfigMap for API
cat << 'EOF' | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: api-config
  namespace: demo-app
data:
  NODE_ENV: "production"
  PORT: "3000"
  REDIS_HOST: "redis.demo-app.svc.cluster.local"
  REDIS_PORT: "6379"
  LOG_LEVEL: "info"
EOF

# Deploy API (using a real public image for demo)
cat << 'EOF' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api-service
  namespace: demo-app
spec:
  replicas: 2
  selector:
    matchLabels:
      app: api-service
  template:
    metadata:
      labels:
        app: api-service
    spec:
      initContainers:
      - name: wait-for-postgres
        image: busybox:1.36
        command: ['sh', '-c',
          'until nc -z postgres.demo-app.svc.cluster.local 5432;
           do echo "Waiting for postgres..."; sleep 3; done; echo "DB ready!"']
      - name: wait-for-redis
        image: busybox:1.36
        command: ['sh', '-c',
          'until nc -z redis.demo-app.svc.cluster.local 6379;
           do echo "Waiting for redis..."; sleep 2; done; echo "Redis ready!"']
      containers:
      - name: api
        image: kennethreitz/httpbin    # Demo API that responds to requests
        envFrom:
        - configMapRef:
            name: api-config
        - secretRef:
            name: postgres-secrets
        ports:
        - containerPort: 80
          name: http
        readinessProbe:
          httpGet:
            path: /get
            port: 80
          initialDelaySeconds: 10
          periodSeconds: 5
        resources:
          requests:
            cpu: "100m"
            memory: "128Mi"
          limits:
            cpu: "500m"
            memory: "512Mi"
EOF

kubectl expose deployment api-service --port=80 --name=api-service
kubectl rollout status deployment/api-service
```

---

## Part 3: Deploy the Frontend

```bash
# Create nginx config that proxies to API
cat << 'EOF' | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: nginx-config
  namespace: demo-app
data:
  nginx.conf: |
    events { worker_connections 1024; }
    http {
      upstream api {
        server api-service.demo-app.svc.cluster.local:80;
      }
      server {
        listen 80;
        
        location /api/ {
          proxy_pass http://api/;
          proxy_set_header Host $host;
          proxy_set_header X-Real-IP $remote_addr;
        }
        
        location /health {
          return 200 '{"status":"healthy","app":"frontend"}';
          add_header Content-Type application/json;
        }
        
        location / {
          root /usr/share/nginx/html;
          try_files $uri $uri/ /index.html;
        }
      }
    }
EOF

cat << 'EOF' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: frontend
  namespace: demo-app
spec:
  replicas: 2
  selector:
    matchLabels:
      app: frontend
  template:
    metadata:
      labels:
        app: frontend
    spec:
      containers:
      - name: nginx
        image: nginx:1.25-alpine
        ports:
        - containerPort: 80
        volumeMounts:
        - name: nginx-config
          mountPath: /etc/nginx/nginx.conf
          subPath: nginx.conf
        readinessProbe:
          httpGet:
            path: /health
            port: 80
          initialDelaySeconds: 5
          periodSeconds: 5
        resources:
          requests:
            cpu: "50m"
            memory: "64Mi"
          limits:
            cpu: "200m"
            memory: "128Mi"
      volumes:
      - name: nginx-config
        configMap:
          name: nginx-config
EOF

kubectl expose deployment frontend --port=80 --type=NodePort --name=frontend
kubectl rollout status deployment/frontend
```

---

## Part 4: Validate the Full Stack

```bash
# Check all pods
kubectl get pods -o wide

# Check all services
kubectl get svc

# Verify inter-service connectivity
kubectl run nettest --image=nicolaka/netshoot:latest -it --rm -- \
  curl -s http://api-service.demo-app.svc.cluster.local/get | head -5

# Port-forward frontend
kubectl port-forward svc/frontend 8080:80 &

# Test the health endpoint
curl http://localhost:8080/health

# Test API proxy
curl http://localhost:8080/api/get

# Check events for any issues
kubectl get events --sort-by=.lastTimestamp
```

---

## Part 5: Simulate Failures

### Test pod failure recovery

```bash
# Delete a pod — Deployment auto-recreates it
kubectl delete pod -l app=api-service --wait=false
watch kubectl get pods
```

### Test database reconnection

```bash
# Delete postgres pod — StatefulSet recreates it with same storage
kubectl delete pod postgres-0
kubectl get pods -w
# Wait for postgres-0 to come back
# API init container will reconnect automatically
```

### Test config update

```bash
# Update ConfigMap — pods need restart to pick up new values
kubectl edit configmap api-config
# Change LOG_LEVEL: "debug"

# Rolling restart to pick up new config
kubectl rollout restart deployment/api-service
kubectl rollout status deployment/api-service
```

---

## Cleanup

```bash
kubectl delete namespace demo-app
kubectl config set-context --current --namespace=default
```

## What You Learned

- [x] Ordered startup with init containers
- [x] Service discovery via DNS
- [x] ConfigMap and Secret injection
- [x] StatefulSet with PVC for database persistence
- [x] Nginx reverse proxy with ConfigMap-mounted config
- [x] Failure recovery and rolling restarts

## Next Lab

→ [Lab 03: CI/CD Pipeline with GitHub Actions](lab-03-cicd.md)
