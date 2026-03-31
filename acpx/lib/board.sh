#!/usr/bin/env bash
# board.sh — Task board management for acpx-butler
# Markdown files with YAML frontmatter as task definitions
# Directory structure as status: inbox/active/blocked/done/failed
# Compatible with Bash 3.2+ and zsh (no bare globs, uses find)

set -euo pipefail

BUTLER_ROOT="${BUTLER_ROOT:-.butler}"
BUTLER_BOARD="${BUTLER_ROOT}/board"
BUTLER_LOGS="${BUTLER_ROOT}/logs"

# ─── Helpers ────────────────────────────────────────────────────

_safe_sed_inplace() {
  local pattern="$1"
  local file="$2"
  sed -i.bak "$pattern" "$file"
  rm -f "${file}.bak"
}

# Escape YAML special characters in scalar values
# Prevents YAML frontmatter injection via --- or other special sequences
_yaml_escape() {
  local text="$1"
  # Replace dangerous YAML document separator --- with --
  text="${text//---/--}"
  # Also handle potential ... document end marker
  text="${text//\.\.\./\.\..}"
  printf '%s' "$text"
}

# Read a frontmatter field from a task file
_read_field() {
  local file="$1"
  local field="$2"
  sed -n "/^---$/,/^---$/s/^${field}: *//p" "$file" | head -1 | tr -d '"' | tr -d "'"
}

# Read array field from frontmatter (e.g., tags: [a, b])
_read_array_field() {
  local file="$1"
  local field="$2"
  local raw
  raw=$(sed -n "/^---$/,/^---$/s/^${field}: *//p" "$file" | head -1)
  echo "$raw" | sed 's/[][]//g' | tr ',' '\n' | sed 's/^ *//;s/ *$//' | grep -v '^$'
}

# Safe file listing — uses find instead of glob for zsh+bash compat
# Outputs one file path per line, empty if none found
_list_md_files() {
  local dir="$1"
  local pattern="${2:-*.md}"
  [[ -d "$dir" ]] || return 0
  command find "$dir" -maxdepth 1 -name "$pattern" -type f 2>/dev/null || true
}

# Count .md files in a directory safely
_count_md() {
  local dir="$1"
  [[ -d "$dir" ]] || { echo "0"; return; }
  local n
  n=$(_list_md_files "$dir" | grep -c . 2>/dev/null || true)
  echo "${n:-0}"
}

# Get next task ID (max existing + 1)
_next_id() {
  local max_id=0
  for dir in inbox active blocked done failed; do
    local dir_path="${BUTLER_BOARD}/${dir}"
    [[ -d "$dir_path" ]] || continue
    while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      local basename
      basename=$(basename "$f" .md)
      local id
      id=$(echo "$basename" | sed 's/-.*//')
      if [[ "$id" =~ ^[0-9]+$ ]] && [[ "10#$id" -gt "10#$max_id" ]]; then
        max_id="$id"
      fi
    done < <(_list_md_files "$dir_path")
  done
  printf '%03d' $((10#$max_id + 1))
}

# Find task file by ID across all status directories
_find_task() {
  local id="${1:?Usage: _find_task <id>}"
  for dir in inbox active blocked done failed; do
    local dir_path="${BUTLER_BOARD}/${dir}"
    while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      local basename
      basename=$(basename "$f")
      if [[ "$basename" == "${id}-"* ]]; then
        echo "$f"
        return 0
      fi
    done < <(_list_md_files "$dir_path")
  done
  return 1
}

# Get status from file path
_status_from_path() {
  local file="$1"
  echo "$file" | sed "s|${BUTLER_BOARD}/||" | cut -d'/' -f1
}

# ─── Core Functions ─────────────────────────────────────────────

board_init() {
  if [[ -d "$BUTLER_BOARD" ]]; then
    echo "Board already exists at ${BUTLER_BOARD}"
    return 0
  fi

  mkdir -p "${BUTLER_BOARD}/inbox"
  mkdir -p "${BUTLER_BOARD}/active"
  mkdir -p "${BUTLER_BOARD}/blocked"
  mkdir -p "${BUTLER_BOARD}/done"
  mkdir -p "${BUTLER_BOARD}/failed"
  mkdir -p "${BUTLER_BOARD}/archive"
  mkdir -p "$BUTLER_LOGS"

  cat > "${BUTLER_ROOT}/state.md" <<STATE
# Butler State

## Board
Created: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
Next ID: 001

## Statistics
Total: 0 | Inbox: 0 | Active: 0 | Blocked: 0 | Done: 0 | Failed: 0
STATE

  echo "Board initialized at ${BUTLER_BOARD}"
}

# Add a task
board_add() {
  [[ -d "$BUTLER_BOARD" ]] || { echo "Error: Board not initialized. Run board_init first." >&2; return 1; }

  local title="" type="shell" priority="normal" command="" task_desc=""
  local assign_to="" role="" tags="" blocked_by="" from_file=""
  local max_retries=2 on_success="" on_failure=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --title)       title="$2"; shift 2 ;;
      --type)        type="$2"; shift 2 ;;
      --priority)    priority="$2"; shift 2 ;;
      --command)     command="$2"; shift 2 ;;
      --task)        task_desc="$2"; shift 2 ;;
      --assign-to)   assign_to="$2"; shift 2 ;;
      --role)        role="$2"; shift 2 ;;
      --tags)        tags="$2"; shift 2 ;;
      --blocked-by)  blocked_by="$2"; shift 2 ;;
      --max-retries) max_retries="$2"; shift 2 ;;
      --on-success)  on_success="$2"; shift 2 ;;
      --on-failure)  on_failure="$2"; shift 2 ;;
      --from)        from_file="$2"; shift 2 ;;
      *)             echo "Unknown option: $1" >&2; return 1 ;;
    esac
  done

  # Batch import from file
  if [[ -n "$from_file" ]]; then
    _board_add_batch "$from_file"
    return
  fi

  [[ -z "$title" ]] && { echo "Error: --title is required" >&2; return 1; }

  # Security: escape YAML special characters in title and assign_to
  local safe_title safe_assign_to
  safe_title=$(_yaml_escape "$title")
  safe_assign_to=$(_yaml_escape "$assign_to")

  local id
  id=$(_next_id)
  local slug
  slug=$(echo "$title" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//')
  # Fallback for empty slug (e.g., pure CJK titles): use timestamp
  [[ -z "$slug" ]] && slug=$(date +"%Y%m%d%H%M%S")
  local filename="${id}-${slug}.md"
  local filepath="${BUTLER_BOARD}/inbox/${filename}"

  local tags_fm="[${tags}]"
  [[ -z "$tags" ]] && tags_fm="[]"
  local blocked_fm="[${blocked_by}]"
  [[ -z "$blocked_by" ]] && blocked_fm="[]"

  cat > "$filepath" <<TASK
---
id: ${id}
title: ${safe_title}
type: ${type}
priority: ${priority}
status: inbox
created: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
assign_to: ${safe_assign_to}
role: ${role}
blocked_by: ${blocked_fm}
retry_count: 0
max_retries: ${max_retries}
tags: ${tags_fm}
on_success: ${on_success}
on_failure: ${on_failure}
---

## Task
${task_desc}

## Command
${command}

## Success Criteria
- exit_code == 0

## Notes

TASK

  echo "$id"
}

# Batch add tasks from a simple YAML file
_board_add_batch() {
  local file="$1"
  [[ ! -f "$file" ]] && { echo "Error: File not found: $file" >&2; return 1; }

  local count=0
  local current_title="" current_type="shell" current_priority="normal"
  local current_command="" current_task="" current_assign="" current_role=""
  local current_tags="" current_blocked="" current_max_retries="2"
  local current_on_success="" current_on_failure=""

  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line// /}" ]] && continue

    if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*title: ]]; then
      if [[ -n "$current_title" ]]; then
        board_add \
          --title "$current_title" --type "$current_type" --priority "$current_priority" \
          --command "$current_command" --task "$current_task" --assign-to "$current_assign" \
          --role "$current_role" --tags "$current_tags" --blocked-by "$current_blocked" \
          --max-retries "$current_max_retries" --on-success "$current_on_success" \
          --on-failure "$current_on_failure" > /dev/null
        count=$((count + 1))
      fi
      current_type="shell"; current_priority="normal"
      current_command=""; current_task=""; current_assign=""; current_role=""
      current_tags=""; current_blocked=""; current_max_retries="2"
      current_on_success=""; current_on_failure=""
      current_title=$(echo "$line" | sed 's/.*title: *//' | tr -d '"' | tr -d "'")
    elif [[ "$line" =~ title: ]]; then
      current_title=$(echo "$line" | sed 's/.*title: *//' | tr -d '"' | tr -d "'")
    elif [[ "$line" =~ type: ]]; then
      current_type=$(echo "$line" | sed 's/.*type: *//' | tr -d '"' | tr -d "'")
    elif [[ "$line" =~ priority: ]]; then
      current_priority=$(echo "$line" | sed 's/.*priority: *//' | tr -d '"' | tr -d "'")
    elif [[ "$line" =~ command: ]]; then
      current_command=$(echo "$line" | sed 's/.*command: *//' | tr -d '"' | tr -d "'")
    elif [[ "$line" =~ ^[[:space:]]+task: ]]; then
      current_task=$(echo "$line" | sed 's/.*task: *//' | tr -d '"' | tr -d "'")
    elif [[ "$line" =~ assign_to: ]]; then
      current_assign=$(echo "$line" | sed 's/.*assign_to: *//' | tr -d '"' | tr -d "'")
    elif [[ "$line" =~ [[:space:]]role: ]]; then
      current_role=$(echo "$line" | sed 's/.*role: *//' | tr -d '"' | tr -d "'")
    elif [[ "$line" =~ tags: ]]; then
      current_tags=$(echo "$line" | sed 's/.*tags: *//' | tr -d '"' | tr -d "'" | sed 's/[][]//g')
    elif [[ "$line" =~ blocked_by: ]]; then
      current_blocked=$(echo "$line" | sed 's/.*blocked_by: *//' | tr -d '"' | tr -d "'" | sed 's/[][]//g')
    elif [[ "$line" =~ max_retries: ]]; then
      current_max_retries=$(echo "$line" | sed 's/.*max_retries: *//')
    elif [[ "$line" =~ on_success: ]]; then
      current_on_success=$(echo "$line" | sed 's/.*on_success: *//' | tr -d '"' | tr -d "'")
    elif [[ "$line" =~ on_failure: ]]; then
      current_on_failure=$(echo "$line" | sed 's/.*on_failure: *//' | tr -d '"' | tr -d "'")
    fi
  done < "$file"

  if [[ -n "$current_title" ]]; then
    board_add \
      --title "$current_title" --type "$current_type" --priority "$current_priority" \
      --command "$current_command" --task "$current_task" --assign-to "$current_assign" \
      --role "$current_role" --tags "$current_tags" --blocked-by "$current_blocked" \
      --max-retries "$current_max_retries" --on-success "$current_on_success" \
      --on-failure "$current_on_failure" > /dev/null
    count=$((count + 1))
  fi

  echo "Imported ${count} task(s)"
}

# Move a task to a new status
board_move() {
  local id="${1:?Usage: board_move <id> <status>}"
  local new_status="${2:?Usage: board_move <id> <status>}"

  case "$new_status" in
    inbox|active|blocked|done|failed) ;;
    *) echo "Error: Invalid status '${new_status}'. Must be: inbox|active|blocked|done|failed" >&2; return 1 ;;
  esac

  local src
  src=$(_find_task "$id") || { echo "Error: Task ${id} not found" >&2; return 1; }
  local old_status
  old_status=$(_status_from_path "$src")

  [[ "$old_status" == "$new_status" ]] && return 0

  _safe_sed_inplace "s/^status: .*/status: ${new_status}/" "$src"

  if [[ "$new_status" == "done" ]]; then
    if ! grep -q "^completed:" "$src"; then
      # Insert completed: before the closing --- of frontmatter
      # The frontmatter has on_failure as last field, then ---
      local ts
      ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
      # Use awk to insert before the second --- delimiter
      awk -v ts="$ts" '
        /^---$/ { count++; if (count == 2) { print "completed: " ts } }
        { print }
      ' "$src" > "${src}.tmp" && mv "${src}.tmp" "$src"
    fi
  fi

  local filename
  filename=$(basename "$src")
  mv "$src" "${BUTLER_BOARD}/${new_status}/${filename}"

  echo "Task ${id}: ${old_status} -> ${new_status}"
}

# List tasks
board_list() {
  [[ -d "$BUTLER_BOARD" ]] || { echo "Error: Board not initialized." >&2; return 1; }

  local filter_status="" filter_tag="" format="table"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --status) filter_status="$2"; shift 2 ;;
      --tag)    filter_tag="$2"; shift 2 ;;
      --format) format="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  local dirs
  if [[ -n "$filter_status" ]]; then
    dirs="$filter_status"
  else
    dirs="inbox active blocked done failed"
  fi

  local total=0

  if [[ "$format" == "table" ]]; then
    printf "%-5s %-8s %-6s %-10s %s\n" "ID" "STATUS" "TYPE" "PRIORITY" "TITLE"
    printf "%-5s %-8s %-6s %-10s %s\n" "---" "------" "----" "--------" "-----"
  fi

  for dir in $dirs; do
    local dir_path="${BUTLER_BOARD}/${dir}"
    [[ -d "$dir_path" ]] || continue

    while IFS= read -r f; do
      [[ -z "$f" ]] && continue

      local id title type priority
      id=$(_read_field "$f" "id")
      title=$(_read_field "$f" "title")
      type=$(_read_field "$f" "type")
      priority=$(_read_field "$f" "priority")

      if [[ -n "$filter_tag" ]]; then
        local tags
        tags=$(_read_array_field "$f" "tags")
        echo "$tags" | grep -q "$filter_tag" || continue
      fi

      total=$((total + 1))

      if [[ "$format" == "table" ]]; then
        printf "%-5s %-8s %-6s %-10s %s\n" "$id" "$dir" "$type" "$priority" "$title"
      elif [[ "$format" == "short" ]]; then
        echo "${id} [${dir}] ${title}"
      fi
    done < <(_list_md_files "$dir_path")
  done

  if [[ "$total" -eq 0 ]]; then echo "(no tasks)"; fi
}

# Get the next executable task (considers priority and dependencies)
board_next() {
  [[ -d "$BUTLER_BOARD" ]] || return 1

  local inbox_dir="${BUTLER_BOARD}/inbox"
  [[ -d "$inbox_dir" ]] || return 0

  local best_id="" best_priority=99

  _priority_num() {
    case "$1" in
      critical) echo 0 ;;
      high)     echo 1 ;;
      normal)   echo 2 ;;
      low)      echo 3 ;;
      *)        echo 2 ;;
    esac
  }

  while IFS= read -r f; do
    [[ -z "$f" ]] && continue

    local id priority
    id=$(_read_field "$f" "id")
    priority=$(_read_field "$f" "priority")

    # Check dependencies
    if ! board_check_deps "$id"; then
      board_move "$id" "blocked" > /dev/null 2>&1 || true
      continue
    fi

    local pnum
    pnum=$(_priority_num "$priority")

    if [[ "$pnum" -lt "$best_priority" ]]; then
      best_priority="$pnum"
      best_id="$id"
    fi
  done < <(_list_md_files "$inbox_dir")

  [[ -n "$best_id" ]] && echo "$best_id"
}

# Check if all dependencies for a task are satisfied
board_check_deps() {
  local id="${1:?Usage: board_check_deps <id>}"
  local task_file
  task_file=$(_find_task "$id" 2>/dev/null) || return 0

  local blocked_by
  blocked_by=$(_read_array_field "$task_file" "blocked_by")

  [[ -z "$blocked_by" ]] && return 0

  while IFS= read -r dep_id; do
    [[ -z "$dep_id" ]] && continue
    local dep_file
    dep_file=$(_find_task "$dep_id" 2>/dev/null) || { return 1; }
    local dep_status
    dep_status=$(_status_from_path "$dep_file")
    [[ "$dep_status" == "done" ]] || return 1
  done <<< "$blocked_by"

  return 0
}

# Read full task details
board_show() {
  local id="${1:?Usage: board_show <id>}"
  local task_file
  task_file=$(_find_task "$id") || { echo "Error: Task ${id} not found" >&2; return 1; }
  cat "$task_file"
}

# Unblock tasks whose dependencies are now met
board_unblock() {
  local blocked_dir="${BUTLER_BOARD}/blocked"
  [[ -d "$blocked_dir" ]] || return 0

  local unblocked=0
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    local id
    id=$(_read_field "$f" "id")
    if board_check_deps "$id"; then
      board_move "$id" "inbox" 2>/dev/null || true
      unblocked=$((unblocked + 1))
    fi
  done < <(_list_md_files "$blocked_dir")

  if [[ "$unblocked" -gt 0 ]]; then echo "Unblocked ${unblocked} task(s)"; fi
}

# Archive completed tasks older than N days
board_archive() {
  local days="${1:-7}"
  local done_dir="${BUTLER_BOARD}/done"
  [[ -d "$done_dir" ]] || return 0

  local archive_dir="${BUTLER_BOARD}/archive"
  mkdir -p "$archive_dir"

  local count=0
  local cutoff
  cutoff=$(date -v-${days}d +"%Y%m%d" 2>/dev/null || date -d "${days} days ago" +"%Y%m%d" 2>/dev/null || echo "00000000")

  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    local completed
    completed=$(_read_field "$f" "completed")
    if [[ -n "$completed" ]]; then
      local completed_date
      completed_date=$(echo "$completed" | sed 's/[T:].*//' | tr -d '-')
      if [[ "$completed_date" -lt "$cutoff" ]] 2>/dev/null; then
        mv "$f" "$archive_dir/"
        count=$((count + 1))
      fi
    fi
  done < <(_list_md_files "$done_dir")

  if [[ "$count" -gt 0 ]]; then echo "Archived ${count} task(s)"; fi
}

# Retry a failed task
board_retry() {
  local id="${1:?Usage: board_retry <id>}"
  local task_file
  task_file=$(_find_task "$id") || { echo "Error: Task ${id} not found" >&2; return 1; }

  local current_status
  current_status=$(_status_from_path "$task_file")
  [[ "$current_status" == "failed" ]] || { echo "Error: Task ${id} is not failed (status: ${current_status})" >&2; return 1; }

  local retry_count max_retries
  retry_count=$(_read_field "$task_file" "retry_count")
  max_retries=$(_read_field "$task_file" "max_retries")

  retry_count=$((retry_count + 1))

  if [[ "$retry_count" -gt "$max_retries" ]]; then
    echo "Error: Task ${id} exceeded max retries (${max_retries})" >&2
    return 1
  fi

  _safe_sed_inplace "s/^retry_count: .*/retry_count: ${retry_count}/" "$task_file"
  board_move "$id" "inbox"
  echo "Task ${id}: retry ${retry_count}/${max_retries}"
}

# Board summary statistics
board_stats() {
  [[ -d "$BUTLER_BOARD" ]] || { echo "Board not initialized." >&2; return 1; }

  local inbox=0 active=0 blocked=0 done=0 failed=0
  for dir in inbox active blocked done failed; do
    local count
    count=$(_count_md "${BUTLER_BOARD}/${dir}")
    case "$dir" in
      inbox)   inbox="$count" ;;
      active)  active="$count" ;;
      blocked) blocked="$count" ;;
      done)    done="$count" ;;
      failed)  failed="$count" ;;
    esac
  done

  local total=$((inbox + active + blocked + done + failed))
  echo "Total: ${total} | Inbox: ${inbox} | Active: ${active} | Blocked: ${blocked} | Done: ${done} | Failed: ${failed}"
}
