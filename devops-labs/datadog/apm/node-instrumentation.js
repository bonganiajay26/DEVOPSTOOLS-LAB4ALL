'use strict'

// Must be the very first line — before any other require()
const tracer = require('dd-trace').init({
  service: 'my-api',
  env: process.env.DD_ENV || 'production',
  version: process.env.APP_VERSION || '1.0.0',
  logInjection: true,      // injects trace_id/span_id into logs automatically
  runtimeMetrics: true,    // sends Node.js runtime metrics (heap, GC, event loop)
  profiling: true,         // enables continuous profiler
})

module.exports = tracer

// ── Custom span example ───────────────────────────────────────────
// const tracer = require('./tracer')
//
// async function checkoutOrder(cartId) {
//   const span = tracer.startSpan('checkout.process')
//   span.setTag('cart.id', cartId)
//   try {
//     const result = await doCheckout(cartId)
//     return result
//   } catch (err) {
//     span.setTag('error', err)
//     throw err
//   } finally {
//     span.finish()
//   }
// }
