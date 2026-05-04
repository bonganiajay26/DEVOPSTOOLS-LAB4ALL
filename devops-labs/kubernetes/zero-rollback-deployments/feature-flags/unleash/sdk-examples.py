"""
Feature Flags with Unleash SDK
==============================
Decouple deployment from release. Deploy code dark, release safely.

This file covers:
  1. Basic flag check
  2. Gradual rollout (percentage-based)
  3. User targeting (specific accounts)
  4. Environment-specific flags
  5. Kill switch pattern
  6. A/B testing with flags
  7. Flag-driven canary (no K8s changes needed)

Install: pip install UnleashClient
Docs:    https://github.com/Unleash/unleash-client-python
"""

from UnleashClient import UnleashClient
import os

# ── Initialize the client ──────────────────────────────────────
client = UnleashClient(
    url=os.getenv("UNLEASH_URL", "https://unleash.company.com/api"),
    app_name="payment-service",
    environment=os.getenv("APP_ENV", "production"),
    custom_headers={"Authorization": os.getenv("UNLEASH_API_TOKEN", "")},
    refresh_interval=15,        # Refresh flags every 15 seconds
    metrics_interval=60,        # Report usage metrics every 60 seconds
)
client.initialize_client()


# ═══════════════════════════════════════════════════════════════
# PATTERN 1: Simple on/off flag
# Use case: deploy new checkout flow, enable only in staging first
# ═══════════════════════════════════════════════════════════════
def process_checkout(cart, user):
    if client.is_enabled("new-checkout-flow"):
        return new_checkout_logic(cart, user)
    return legacy_checkout_logic(cart, user)


# ═══════════════════════════════════════════════════════════════
# PATTERN 2: Gradual rollout (percentage-based)
# Use case: roll out to 10% of users, watch metrics, increase
# In Unleash UI: Activation Strategy → Gradual rollout → 10%
# ═══════════════════════════════════════════════════════════════
def get_recommendation_engine(user_id: str):
    context = {"userId": user_id}
    if client.is_enabled("new-recommendation-engine", context):
        return new_ml_recommender          # New engine for this % of users
    return legacy_recommender


# ═══════════════════════════════════════════════════════════════
# PATTERN 3: User targeting (specific accounts)
# Use case: enable for beta customers, enterprise tier, internal users
# In Unleash UI: Activation Strategy → UserIDs → [user1, user2, ...]
# ═══════════════════════════════════════════════════════════════
def get_feature_set(user_id: str, account_tier: str):
    context = {
        "userId": user_id,
        "properties": {
            "accountTier": account_tier,
            "internalUser": str(user_id.endswith("@company.com")),
        }
    }

    features = {
        "bulk_export": client.is_enabled("bulk-export", context),
        "advanced_analytics": client.is_enabled("advanced-analytics", context),
        "ai_insights": client.is_enabled("ai-insights-beta", context),
    }

    return features


# ═══════════════════════════════════════════════════════════════
# PATTERN 4: Kill switch (instant disable without deployment)
# Use case: new payment processor has a bug — disable instantly
# Toggle in Unleash UI → service falls back to old processor
# ═══════════════════════════════════════════════════════════════
def process_payment(order):
    if client.is_enabled("use-stripe-v3"):
        try:
            return stripe_v3_client.charge(order)
        except Exception as e:
            # Flag catches all errors — disable flag to fallback
            raise
    else:
        # Fallback: old Stripe v2 (always safe)
        return stripe_v2_client.charge(order)


# ═══════════════════════════════════════════════════════════════
# PATTERN 5: A/B testing with feature flags
# Use case: test two pricing UIs, measure conversion
# ═══════════════════════════════════════════════════════════════
def get_pricing_ui(user_id: str) -> str:
    context = {"userId": user_id}

    # 50% get variant A, 50% get variant B
    if client.is_enabled("pricing-ui-variant-b", context):
        track_event("pricing_ui", user_id, variant="B")
        return "pricing_v2_template"
    else:
        track_event("pricing_ui", user_id, variant="A")
        return "pricing_v1_template"


# ═══════════════════════════════════════════════════════════════
# PATTERN 6: Dependency-aware flags
# Use case: new feature requires both frontend AND backend flags
# ═══════════════════════════════════════════════════════════════
def can_use_real_time_collaboration(user_id: str) -> bool:
    context = {"userId": user_id}
    return (
        client.is_enabled("realtime-backend", context)
        and client.is_enabled("realtime-frontend", context)
        # Both must be on — either alone is incomplete
    )


# ═══════════════════════════════════════════════════════════════
# PATTERN 7: Operational flag (infrastructure, not features)
# Use case: graceful degradation when downstream is unhealthy
# ═══════════════════════════════════════════════════════════════
def get_order_status(order_id: str):
    if client.is_enabled("use-order-cache-fallback"):
        # Upstream order service is having issues
        # Serve from Redis cache (stale but available)
        return redis_cache.get(f"order:{order_id}")
    else:
        # Normal path: query order service directly
        return order_service_client.get(order_id)


# ═══════════════════════════════════════════════════════════════
# PATTERN 8: Flag with custom variant (not just on/off)
# Use case: A/B/C test three algorithm variations
# ═══════════════════════════════════════════════════════════════
def get_search_algorithm(user_id: str) -> str:
    context = {"userId": user_id}
    variant = client.get_variant("search-algorithm-test", context)

    if variant["enabled"]:
        algo = variant["name"]     # "control", "v2", "v3"
        track_event("search_algo", user_id, variant=algo)
        return algo
    return "control"


# ═══════════════════════════════════════════════════════════════
# PATTERN 9: The deployment ceremony
# These are the operational steps when deploying with feature flags
# ═══════════════════════════════════════════════════════════════

DEPLOYMENT_CEREMONY = """
Deploying with Feature Flags — Ceremony:

1. BEFORE CODING
   □ Create flag in Unleash: name, description, default=OFF
   □ Add flag name to PR description

2. DURING CODING
   □ Wrap ALL new code paths in flag check
   □ Keep old code path — it's the fallback
   □ Test both flag=ON and flag=OFF

3. DEPLOYING
   □ Deploy code (flag is OFF — zero user impact)
   □ Enable flag for internal users only (yourco.com emails)
   □ Test with internal users for 24h

4. GRADUAL ROLLOUT
   □ Enable for 1% of users — monitor error rate, latency
   □ 10% — monitor for 1 hour
   □ 25% → 50% → 100% — monitor between each step
   □ If issues at ANY step → flip flag OFF (instant rollback)

5. CLEANUP (2 weeks after 100% rollout)
   □ Delete flag from Unleash
   □ Remove flag check from code
   □ Delete old code path (flag=OFF branch)
   □ Open PR: "cleanup: remove new-checkout-flow flag"
"""


def cleanup_example():
    """
    After 2 weeks at 100%, remove the flag.
    This prevents flag debt from accumulating.
    """
    # BEFORE cleanup (with flag):
    # if client.is_enabled("new-checkout-flow"):
    #     return new_checkout_logic(cart, user)
    # return legacy_checkout_logic(cart, user)

    # AFTER cleanup (flag removed):
    return new_checkout_logic(None, None)   # New logic is now permanent


# ── Helper stubs (would be real implementations) ──────────────
def new_checkout_logic(cart, user): return {"status": "new"}
def legacy_checkout_logic(cart, user): return {"status": "legacy"}
def new_ml_recommender(u): return []
def legacy_recommender(u): return []
def track_event(name, user_id, **kwargs): pass
def redis_cache(): pass
