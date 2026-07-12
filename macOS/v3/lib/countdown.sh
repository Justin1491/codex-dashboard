#!/usr/bin/env bash

iso_to_epoch() {
  local timestamp="${1:-}"

  if [[ -z "$timestamp" || "$timestamp" == "null" ]]; then
    printf '0'
    return
  fi

  timestamp="$(printf '%s' "$timestamp" | sed -E 's/\.[0-9]+Z$/Z/')"

  if date -j -f '%Y-%m-%dT%H:%M:%SZ' "$timestamp" '+%s' >/dev/null 2>&1; then
    TZ=UTC date -j -f '%Y-%m-%dT%H:%M:%SZ' "$timestamp" '+%s'
  elif date -d "$timestamp" '+%s' >/dev/null 2>&1; then
    date -d "$timestamp" '+%s'
  else
    printf '0'
  fi
}

epoch_to_local_time() {
  local epoch="${1:-0}"

  if [[ ! "$epoch" =~ ^[0-9]+$ ]] || ((epoch <= 0)); then
    printf '—'
    return
  fi

  if date -r "$epoch" '+%b %-d, %Y %-I:%M:%S %p %Z' >/dev/null 2>&1; then
    date -r "$epoch" '+%b %-d, %Y %-I:%M:%S %p %Z'
  else
    date -d "@$epoch" '+%b %-d, %Y %-I:%M:%S %p %Z'
  fi
}

countdown_calculate() {
  local expiration_epoch="${1:-0}"
  local now_epoch="${2:-$(date +%s)}"
  local remaining

  COUNTDOWN_STATE='unknown'
  COUNTDOWN_DAYS=0
  COUNTDOWN_HOURS=0
  COUNTDOWN_MINUTES=0
  COUNTDOWN_SECONDS=0

  if [[ ! "$expiration_epoch" =~ ^[0-9]+$ ]] ||
     [[ ! "$now_epoch" =~ ^[0-9]+$ ]] ||
     ((expiration_epoch <= 0)); then
    return
  fi

  remaining=$((expiration_epoch - now_epoch))

  if ((remaining <= 0)); then
    COUNTDOWN_STATE='ready'
    return
  fi

  COUNTDOWN_STATE='active'
  COUNTDOWN_DAYS=$((remaining / 86400))
  COUNTDOWN_HOURS=$(((remaining % 86400) / 3600))
  COUNTDOWN_MINUTES=$(((remaining % 3600) / 60))
  COUNTDOWN_SECONDS=$((remaining % 60))
}

countdown_format() {
  local expiration_epoch="${1:-0}"
  local now_epoch="${2:-$(date +%s)}"

  countdown_calculate "$expiration_epoch" "$now_epoch"

  case "$COUNTDOWN_STATE" in
    active)
      printf '%dd %02dh %02dm %02ds' \
        "$COUNTDOWN_DAYS" "$COUNTDOWN_HOURS" "$COUNTDOWN_MINUTES" "$COUNTDOWN_SECONDS"
      ;;
    ready)
      printf 'READY'
      ;;
    *)
      printf 'UNKNOWN'
      ;;
  esac
}
