#!/usr/bin/env bash

project_slug() {
  local name="$1"
  printf '%s' "$name" |
    tr '[:upper:]' '[:lower:]' |
    sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//'
}

project_add() {
  local path="${1:-}"
  local name="${2:-}"
  local absolute_path base id existing

  [[ -n "$path" ]] || {
    printf 'Project path is required.\n' >&2
    return 1
  }

  [[ -d "$path" ]] || {
    printf 'Project directory does not exist: %s\n' "$path" >&2
    return 1
  }

  absolute_path="$(cd "$path" && pwd -P)"
  base="$(basename "$absolute_path")"
  [[ -n "$name" ]] || name="$base"
  id="$(project_slug "$name")"
  [[ -n "$id" ]] || id="project"

  ensure_config || return 1

  existing="$(jq -r --arg path "$absolute_path" --arg id "$id" '
    [.projects[] | select(.path == $path or .id == $id)] | length
  ' "$(config_path)")"

  if ((existing > 0)); then
    printf 'A project with that path or ID already exists.\n' >&2
    return 1
  fi

  config_update '
    .projects += [{id: $id, name: $name, path: $path}]
    | if .defaultProjectId == null then .defaultProjectId = $id else . end
  ' --arg id "$id" --arg name "$name" --arg path "$absolute_path"

  printf 'Added project %s (%s)\n' "$name" "$absolute_path"
}

project_list() {
  ensure_config || return 1
  jq -r '
    .defaultProjectId as $default |
    if (.projects | length) == 0 then
      "No projects registered."
    else
      .projects[] |
      (if .id == $default then "*" else " " end) +
      " " + .name + " [" + .id + "]\n    " + .path
    end
  ' "$(config_path)"
}

project_find_json() {
  local query="$1"
  ensure_config || return 1
  jq -c --arg query "$query" '
    first(.projects[] | select(.id == $query or .name == $query or .path == $query)) // empty
  ' "$(config_path)"
}

project_remove() {
  local query="$1"
  local found id

  found="$(project_find_json "$query")"
  [[ -n "$found" ]] || {
    printf 'Project not found: %s\n' "$query" >&2
    return 1
  }

  id="$(jq -r '.id' <<<"$found")"

  config_update '
    .projects = [.projects[] | select(.id != $id)]
    | if .defaultProjectId == $id then
        .defaultProjectId = ((.projects[0].id) // null)
      else . end
  ' --arg id "$id"

  printf 'Removed project: %s\n' "$id"
}

project_set_default() {
  local query="$1"
  local found id

  found="$(project_find_json "$query")"
  [[ -n "$found" ]] || {
    printf 'Project not found: %s\n' "$query" >&2
    return 1
  }

  id="$(jq -r '.id' <<<"$found")"
  config_update '.defaultProjectId = $id' --arg id "$id"
  printf 'Default project set to: %s\n' "$id"
}

project_default_json() {
  ensure_config || return 1
  jq -c '
    .defaultProjectId as $id |
    first(.projects[] | select(.id == $id)) // empty
  ' "$(config_path)"
}
