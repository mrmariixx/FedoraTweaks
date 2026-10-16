# shellcheck shell=bash
# Rollback and status — every applied change has an undo command in the journal.

stage_status() {
  header "Applied changes"
  local -a entries
  mapfile -t entries < <(journal_pending)
  if (( ${#entries[@]} == 0 )); then ok "No pending changes recorded."; return 0; fi
  local e id date desc undo
  for e in "${entries[@]}"; do
    IFS=$'\t' read -r id date desc undo <<<"$e"
    printf '  %s  %s\n' "$date" "$desc"
  done
  explain "Journal: $FT_JOURNAL   Backups: $FT_BACKUP_DIR"
}

stage_rollback() {
  header "Rollback"
  local -a entries
  mapfile -t entries < <(journal_pending)
  if (( ${#entries[@]} == 0 )); then ok "Nothing to roll back."; return 0; fi
  local i id date desc undo
  for i in "${!entries[@]}"; do
    IFS=$'\t' read -r id date desc undo <<<"${entries[$i]}"
    printf '  %2d) %s  %s\n' "$((i + 1))" "$date" "$desc"
  done
  explain "Newest first. Enter numbers (e.g. '1 3'), 'a' for all (newest to oldest), or nothing to cancel."
  local choice
  read -r -p "Undo which? " choice </dev/tty
  [[ -z $choice ]] && return 0
  local -a pick=()
  if [[ $choice == a || $choice == all ]]; then
    for i in "${!entries[@]}"; do pick+=("$i"); done
  else
    for i in $choice; do
      [[ $i =~ ^[0-9]+$ ]] && (( i >= 1 && i <= ${#entries[@]} )) || { err "Invalid choice: $i"; return 1; }
      pick+=("$((i - 1))")
    done
    mapfile -t pick < <(printf '%s\n' "${pick[@]}" | sort -n -u)
  fi
  [[ $FT_DRY_RUN == 1 ]] || sudo_init
  for i in "${pick[@]}"; do
    IFS=$'\t' read -r id date desc undo <<<"${entries[$i]}"
    printf '\n  %sUndo:%s %s\n' "$C_BOLD" "$C_RESET" "$desc"
    if run bash -c "$undo"; then
      [[ $FT_DRY_RUN == 1 ]] || journal_mark_undone "$id"
      ok "Reverted."
    else
      err "Undo command failed — left in the journal. Command was: $undo"
    fi
  done
  explain "Kernel arguments, modules-load and sysctl changes fully revert after a reboot. KDE changes apply after logging out and back in."
}
