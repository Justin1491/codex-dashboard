#!/usr/bin/env bash

normalize_codex_state() {
  local usage_json="${1:-}"
  local credits_json="${2:-}"

  [[ -n "$usage_json" ]] || usage_json='{}'
  [[ -n "$credits_json" ]] || credits_json='{}'

  jq -n \
    --argjson usage "$usage_json" \
    --argjson credits "$credits_json" '
      def clamp:
        if . < 0 then 0 elif . > 100 then 100 else . end;

      def used($window):
        (($window.used_percent // 0) | tonumber? // 0 | clamp);

      def reset($window):
        (($window.reset_at // 0) | tonumber? // 0);

      def credit_records:
        [($credits.credits // [])[]? |
          {
            status: (.status // "unknown"),
            grantedAt: (.granted_at // null),
            expiresAt: (.expires_at // null)
          }
        ];

      ($usage.rate_limit.primary_window // {}) as $primary |
      ($usage.rate_limit.secondary_window // {}) as $secondary |
      (used($primary)) as $primaryUsed |
      (used($secondary)) as $secondaryUsed |

      {
        plan: ($usage.plan_type // "unknown"),
        access: {
          allowed: ($usage.rate_limit.allowed // false),
          limitReached: ($usage.rate_limit.limit_reached // false)
        },
        usageWindows: [
          {
            id: "five-hour",
            label: "5-hour",
            usedPercent: $primaryUsed,
            remainingPercent: (100 - $primaryUsed),
            windowSeconds: (($primary.limit_window_seconds // 18000) | tonumber? // 18000),
            resetAt: reset($primary)
          },
          {
            id: "weekly",
            label: "Weekly",
            usedPercent: $secondaryUsed,
            remainingPercent: (100 - $secondaryUsed),
            windowSeconds: (($secondary.limit_window_seconds // 604800) | tonumber? // 604800),
            resetAt: reset($secondary)
          }
        ],
        resetCredits: {
          availableCount: (
            $credits.available_count
            // $usage.rate_limit_reset_credits.available_count
            // 0
          ),
          records: credit_records
        }
      }
    '
}
