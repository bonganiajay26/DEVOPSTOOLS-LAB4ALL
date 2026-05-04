/**
 * Observability-First Instrumentation — Node.js / Express
 * =========================================================
 * Same metrics contract as python-metrics.py.
 * Every service, every language, same dashboard.
 *
 * Install:
 *   npm install prom-client @opentelemetry/sdk-node \
 *     @opentelemetry/auto-instrumentations-node \
 *     @opentelemetry/exporter-jaeger @opentelemetry/api
 */

'use strict';

const promClient = require('prom-client');

// ── Setup default metrics (node.js runtime) ──────────────────
// Includes: gc_duration, heap_used, event_loop_lag, etc.
const register = new promClient.Registry();
promClient.collectDefaultMetrics({ register, prefix: 'nodejs_' });

// ══════════════════════════════════════════════════════════════
// 1. STANDARD HTTP METRICS
// ══════════════════════════════════════════════════════════════

const httpRequestsTotal = new promClient.Counter({
  name: 'http_requests_total',
  help: 'Total HTTP requests',
  labelNames: ['method', 'endpoint', 'status_code', 'service'],
  registers: [register],
});

const httpRequestDuration = new promClient.Histogram({
  name: 'http_request_duration_seconds',
  help: 'HTTP request latency in seconds',
  labelNames: ['method', 'endpoint'],
  // Match Python buckets — same SLO dashboard works for both languages
  buckets: [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10],
  registers: [register],
});

const httpRequestsInProgress = new promClient.Gauge({
  name: 'http_requests_in_progress',
  help: 'Current in-flight HTTP requests',
  labelNames: ['method', 'endpoint'],
  registers: [register],
});

// ══════════════════════════════════════════════════════════════
// 2. BUSINESS METRICS
// ══════════════════════════════════════════════════════════════

const ordersCreatedTotal = new promClient.Counter({
  name: 'orders_created_total',
  help: 'Total orders created',
  labelNames: ['payment_method', 'customer_tier'],
  registers: [register],
});

const orderValueDollars = new promClient.Histogram({
  name: 'order_value_dollars',
  help: 'Distribution of order values',
  buckets: [1, 10, 50, 100, 500, 1000, 5000],
  registers: [register],
});

const paymentsProcessedTotal = new promClient.Counter({
  name: 'payments_processed_total',
  help: 'Total payment transactions',
  labelNames: ['status', 'provider'],
  registers: [register],
});

const activeUsers = new promClient.Gauge({
  name: 'active_users_current',
  help: 'Currently active users',
  registers: [register],
});

// ══════════════════════════════════════════════════════════════
// 3. RESOURCE METRICS
// ══════════════════════════════════════════════════════════════

const dbConnectionsActive = new promClient.Gauge({
  name: 'db_connections_active',
  help: 'Active database connections',
  labelNames: ['database'],
  registers: [register],
});

const dbQueryDuration = new promClient.Histogram({
  name: 'db_query_duration_seconds',
  help: 'Database query execution time',
  labelNames: ['query_type', 'table'],
  buckets: [0.001, 0.005, 0.01, 0.05, 0.1, 0.5, 1, 5],
  registers: [register],
});

const cacheOperationsTotal = new promClient.Counter({
  name: 'cache_operations_total',
  help: 'Total cache operations',
  labelNames: ['operation', 'result'],
  registers: [register],
});

// ══════════════════════════════════════════════════════════════
// 4. DEPLOYMENT TRACKING
// ══════════════════════════════════════════════════════════════

const appInfo = new promClient.Gauge({
  name: 'app_info',
  help: 'Application version information',
  labelNames: ['version', 'git_sha', 'build_date', 'service', 'environment'],
  registers: [register],
});

appInfo.labels({
  version:     process.env.APP_VERSION   || 'unknown',
  git_sha:     process.env.GIT_SHA       || 'unknown',
  build_date:  process.env.BUILD_DATE    || 'unknown',
  service:     process.env.SERVICE_NAME  || 'myapp',
  environment: process.env.APP_ENV       || 'production',
}).set(1);   // Always 1 — presence means the version is running

const deployTimestamp = new promClient.Gauge({
  name: 'app_deploy_timestamp_seconds',
  help: 'Unix timestamp of last deployment',
  labelNames: ['version', 'environment'],
  registers: [register],
});

deployTimestamp.labels({
  version:     process.env.APP_VERSION || 'unknown',
  environment: process.env.APP_ENV     || 'production',
}).setToCurrentTime();

// ══════════════════════════════════════════════════════════════
// 5. EXPRESS MIDDLEWARE
// ══════════════════════════════════════════════════════════════

/**
 * Normalize URL paths to prevent metric cardinality explosion.
 * /api/users/12345 → /api/users/:id
 */
function normalizePath(path) {
  return path
    .replace(/\/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/gi, '/:uuid')
    .replace(/\/\d+/g, '/:id');
}

/**
 * Express middleware: auto-tracks all request metrics.
 * Usage: app.use(metricsMiddleware);
 */
function metricsMiddleware(req, res, next) {
  const endpoint = normalizePath(req.path);
  const method   = req.method;
  const end      = httpRequestDuration.startTimer({ method, endpoint });

  httpRequestsInProgress.inc({ method, endpoint });

  res.on('finish', () => {
    const statusCode = String(res.statusCode);

    end();   // Records duration
    httpRequestsInProgress.dec({ method, endpoint });
    httpRequestsTotal.inc({
      method,
      endpoint,
      status_code: statusCode,
      service: process.env.SERVICE_NAME || 'myapp',
    });

    // Add version to every response header
    res.setHeader('X-Service-Version', process.env.APP_VERSION || 'unknown');
  });

  next();
}

// ══════════════════════════════════════════════════════════════
// 6. HEALTH ENDPOINTS
// ══════════════════════════════════════════════════════════════

function setupHealthRoutes(app, deps = {}) {
  /** Liveness: is the app alive? K8s restarts if this fails. */
  app.get('/health/live', (_req, res) => {
    res.json({ status: 'alive' });
  });

  /** Readiness: is the app ready for traffic? Removed from Service if fails. */
  app.get('/health/ready', async (_req, res) => {
    const checks = {};
    let ok = true;

    if (deps.db) {
      try {
        await deps.db.query('SELECT 1');
        checks.database = 'ok';
      } catch (err) {
        checks.database = `error: ${err.message}`;
        ok = false;
      }
    }

    if (deps.redis) {
      try {
        await deps.redis.ping();
        checks.cache = 'ok';
      } catch (err) {
        checks.cache = `error: ${err.message}`;
        ok = false;
      }
    }

    res.status(ok ? 200 : 503).json({
      status:  ok ? 'ready' : 'not_ready',
      checks,
      version: process.env.APP_VERSION || 'unknown',
    });
  });

  /** Startup probe: has app finished initializing? */
  app.get('/health/started', (_req, res) => {
    res.json({ status: 'started' });
  });

  /** Prometheus scrape endpoint */
  app.get('/metrics', async (_req, res) => {
    res.set('Content-Type', register.contentType);
    res.end(await register.metrics());
  });
}

// ══════════════════════════════════════════════════════════════
// 7. OPENTELEMETRY DISTRIBUTED TRACING
// ══════════════════════════════════════════════════════════════

function setupTracing(serviceName) {
  const { NodeSDK } = require('@opentelemetry/sdk-node');
  const { getNodeAutoInstrumentations } = require('@opentelemetry/auto-instrumentations-node');
  const { JaegerExporter } = require('@opentelemetry/exporter-jaeger');

  const sdk = new NodeSDK({
    serviceName: serviceName || process.env.SERVICE_NAME || 'myapp',
    traceExporter: new JaegerExporter({
      endpoint: `http://${process.env.JAEGER_HOST || 'jaeger.tracing.svc.cluster.local'}:14268/api/traces`,
    }),
    instrumentations: [
      getNodeAutoInstrumentations({
        // Auto-instruments: express, http, pg, redis, mongoose, grpc, etc.
        '@opentelemetry/instrumentation-fs': { enabled: false },   // Too noisy
      }),
    ],
  });

  sdk.start();

  // Graceful shutdown
  process.on('SIGTERM', () => {
    sdk.shutdown().finally(() => process.exit(0));
  });

  return sdk;
}

// ══════════════════════════════════════════════════════════════
// 8. STRUCTURED LOGGING (Winston → Loki)
// ══════════════════════════════════════════════════════════════

const { createLogger, format, transports } = require('winston');
const { trace } = require('@opentelemetry/api');

const structuredLogger = createLogger({
  format: format.combine(
    format.timestamp(),
    format.errors({ stack: true }),
    format.printf((info) => {
      // Inject trace context for log-trace correlation in Grafana
      const span = trace.getActiveSpan();
      const traceId = span?.spanContext()?.traceId || '';

      return JSON.stringify({
        timestamp:   info.timestamp,
        level:       info.level,
        message:     info.message,
        service:     process.env.SERVICE_NAME  || 'myapp',
        version:     process.env.APP_VERSION   || 'unknown',
        environment: process.env.APP_ENV       || 'production',
        trace_id:    traceId,   // Links logs to traces in Grafana
        ...info.meta,           // Any extra fields passed by caller
        ...(info.stack ? { stack: info.stack } : {}),
      });
    })
  ),
  transports: [new transports.Console()],
});

// ══════════════════════════════════════════════════════════════
// 9. BUSINESS METRIC HELPERS
// ══════════════════════════════════════════════════════════════

const metrics = {
  // Track an order being created
  orderCreated: (paymentMethod, tier, value) => {
    ordersCreatedTotal.inc({ payment_method: paymentMethod, customer_tier: tier });
    orderValueDollars.observe(value);
  },

  // Track a payment
  paymentProcessed: (provider, status) => {
    paymentsProcessedTotal.inc({ provider, status });
  },

  // Track DB query timing
  dbQuery: (queryType, table, fn) => async (...args) => {
    const end = dbQueryDuration.startTimer({ query_type: queryType, table });
    try {
      const result = await fn(...args);
      end();
      return result;
    } catch (err) {
      end();
      throw err;
    }
  },

  // Track cache hit/miss
  cacheGet: (result) => {
    cacheOperationsTotal.inc({ operation: 'get', result });
  },

  // Update active users gauge (call periodically)
  setActiveUsers: (count) => {
    activeUsers.set(count);
  },

  // Update DB connection pool stats
  updateDbPool: (database, active, poolSize) => {
    dbConnectionsActive.set({ database }, active);
  },
};

module.exports = {
  register,
  metricsMiddleware,
  setupHealthRoutes,
  setupTracing,
  structuredLogger,
  metrics,
};

// ══════════════════════════════════════════════════════════════
// USAGE EXAMPLE
// ══════════════════════════════════════════════════════════════

/*
const express = require('express');
const {
  metricsMiddleware,
  setupHealthRoutes,
  setupTracing,
  structuredLogger: log,
  metrics,
} = require('./nodejs-metrics');

// Initialize tracing BEFORE requiring anything else
setupTracing('payment-service');

const app = express();
app.use(express.json());

// Auto-instrument all routes
app.use(metricsMiddleware);

// Add health + metrics endpoints
setupHealthRoutes(app, { db: pool, redis: redisClient });

// Business routes
app.post('/api/v1/orders', async (req, res) => {
  const { items, paymentMethod } = req.body;

  try {
    const order = await createOrder(items);
    metrics.orderCreated(paymentMethod, order.tier, order.total);

    log.info('Order created', { orderId: order.id, total: order.total });
    res.status(201).json(order);
  } catch (err) {
    log.error('Order creation failed', { error: err.message, meta: req.body });
    res.status(500).json({ error: 'Order creation failed' });
  }
});

app.listen(8080, () => log.info('Server started', { port: 8080 }));
*/
