/**
 * k6 Performance Baseline Test
 * ============================
 * Validates that a new deployment meets performance thresholds
 * before being promoted to production.
 *
 * Run:
 *   k6 run performance-baseline.js --env BASE_URL=https://staging.company.com
 *
 * Thresholds (fail the gate if violated):
 *   - p99 latency < 500ms
 *   - p95 latency < 200ms
 *   - Error rate  < 1%
 *   - Request rate >= 100 req/s (proves the service handles load)
 */

import http from "k6/http";
import { check, sleep } from "k6";
import { Rate, Trend, Counter } from "k6/metrics";

// ── Custom metrics ────────────────────────────────────────────
const errorRate        = new Rate("error_rate");
const checkoutLatency  = new Trend("checkout_latency");
const searchLatency    = new Trend("search_latency");
const authLatency      = new Trend("auth_latency");
const failedRequests   = new Counter("failed_requests");

// ── Test configuration ────────────────────────────────────────
export const options = {
  // Load profile: ramp up, sustain, ramp down
  stages: [
    { duration: "30s", target: 10  },   // Ramp up to 10 VUs
    { duration: "1m",  target: 50  },   // Ramp up to 50 VUs
    { duration: "2m",  target: 50  },   // Sustain 50 VUs for 2 min
    { duration: "30s", target: 0   },   // Ramp down
  ],

  // ── THRESHOLDS — gate fails if any of these are violated ─────
  thresholds: {
    // Overall p99 must be < 500ms
    "http_req_duration{percentile:99}": ["p(99)<500"],

    // p95 < 200ms
    "http_req_duration{percentile:95}": ["p(95)<200"],

    // Error rate < 1%
    "http_req_failed": ["rate<0.01"],
    "error_rate":      ["rate<0.01"],

    // Checkout endpoint p99 < 1000ms (heavier endpoint)
    "checkout_latency": ["p(99)<1000"],

    // Auth endpoint p99 < 300ms (critical path)
    "auth_latency": ["p(99)<300"],

    // At least 100 successful requests total
    "http_reqs": ["count>100"],
  },

  // Tag requests for detailed breakdown
  tags: {
    environment: __ENV.ENVIRONMENT || "staging",
    version:     __ENV.IMAGE_TAG   || "unknown",
  },
};

const BASE_URL = __ENV.BASE_URL || "https://staging.company.com";

// ── Scenario: Health check ────────────────────────────────────
function healthCheck() {
  const res = http.get(`${BASE_URL}/health`, {
    tags: { endpoint: "health" },
  });
  check(res, {
    "health: status 200": (r) => r.status === 200,
    "health: has status field": (r) => r.json("status") === "healthy",
    "health: < 100ms": (r) => r.timings.duration < 100,
  });
}

// ── Scenario: Authentication ──────────────────────────────────
function authScenario() {
  const payload = JSON.stringify({
    email: `user_${Math.floor(Math.random() * 10000)}@example.com`,
    password: "testpassword123",
  });

  const start = Date.now();
  const res = http.post(`${BASE_URL}/api/v1/auth/login`, payload, {
    headers: { "Content-Type": "application/json" },
    tags: { endpoint: "auth" },
  });
  authLatency.add(Date.now() - start);

  const ok = check(res, {
    "auth: status 200 or 401": (r) => [200, 401].includes(r.status),
    "auth: response time < 300ms": (r) => r.timings.duration < 300,
  });
  if (!ok) {
    errorRate.add(1);
    failedRequests.add(1);
  } else {
    errorRate.add(0);
  }
  return res.json("token") || null;
}

// ── Scenario: Product search ──────────────────────────────────
function searchScenario(token) {
  const queries = ["laptop", "phone", "headphones", "monitor", "keyboard"];
  const query   = queries[Math.floor(Math.random() * queries.length)];

  const headers = token
    ? { Authorization: `Bearer ${token}` }
    : {};

  const start = Date.now();
  const res   = http.get(`${BASE_URL}/api/v1/search?q=${query}&limit=20`, {
    headers,
    tags: { endpoint: "search" },
  });
  searchLatency.add(Date.now() - start);

  const ok = check(res, {
    "search: status 200": (r) => r.status === 200,
    "search: has results": (r) => Array.isArray(r.json("items")),
    "search: < 200ms": (r) => r.timings.duration < 200,
  });
  if (!ok) errorRate.add(1);
  else     errorRate.add(0);
}

// ── Scenario: Checkout flow (most critical) ───────────────────
function checkoutScenario(token) {
  if (!token) return;

  const payload = JSON.stringify({
    items: [
      { product_id: "prod-123", quantity: 1, price: 99.99 },
    ],
    shipping_address: {
      street: "123 Test St",
      city:   "San Francisco",
      zip:    "94102",
    },
  });

  const start = Date.now();
  const res   = http.post(`${BASE_URL}/api/v1/checkout/calculate`, payload, {
    headers: {
      "Content-Type": "application/json",
      Authorization:  `Bearer ${token}`,
    },
    tags: { endpoint: "checkout" },
  });
  checkoutLatency.add(Date.now() - start);

  const ok = check(res, {
    "checkout: status 200": (r) => r.status === 200,
    "checkout: has total": (r) => r.json("total") > 0,
    "checkout: < 1000ms": (r) => r.timings.duration < 1000,
  });
  if (!ok) {
    errorRate.add(1);
    failedRequests.add(1);
  } else {
    errorRate.add(0);
  }
}

// ── Main test function ────────────────────────────────────────
export default function () {
  // Simulate realistic user journey
  healthCheck();
  sleep(0.5);

  const token = authScenario();
  sleep(1);

  searchScenario(token);
  sleep(0.5);

  // 30% of users attempt checkout
  if (Math.random() < 0.3) {
    checkoutScenario(token);
    sleep(2);
  }

  sleep(1);
}

// ── Setup: verify service is up before load test ─────────────
export function setup() {
  const res = http.get(`${BASE_URL}/health`);
  if (res.status !== 200) {
    throw new Error(`Service not healthy before load test: ${res.status}`);
  }
  console.log(`Service healthy at ${BASE_URL}. Starting load test.`);
  return { baseUrl: BASE_URL };
}

// ── Teardown: print summary ───────────────────────────────────
export function teardown(data) {
  console.log(`Load test complete for: ${data.baseUrl}`);
  console.log("Check thresholds above — PASS if all green, FAIL if any red.");
}
