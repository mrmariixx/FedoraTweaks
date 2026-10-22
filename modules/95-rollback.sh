
# shellcheck shell=bash
# Rollback and status — review every pending change before undoing it.
# Undo commands are executable shell commands: keep the journal private.

stage_status() {
  header "Applied changes"

  local -a entries=()
  local entry id date desc undo
  local pending=0

  if ! mapfile -t entries < <(journal_pending); then
    err "Could not read the change journal."
    return 1
  fi

  if (( ${#entries[@]} == 0 )); then
    ok "No pending changes recorded."
    return 0
  fi

  printf '\n'
  printf '  %-4s %-20s %s\n' "ID" "DATE" "CHANGE"
  printf '  %-4s %-20s %s\n' "----" "--------------------" "------------------------------"

  for entry in "${entries[@]}"; do
    IFS=$'\t' read -r id date desc undo <<<"$entry"

    [[ -n $id ]] || {
      warn "Ignoring a journal entry with no ID."
      continue
    }

    printf '  %-4s %-20s %s\n' \
      "$id" "${date:-unknown}" "${desc:-Unnamed change}"

    if [[ -n $undo ]]; then
      ((pending += 1))
    else
      warn "Entry $id has no undo command."
    fi
  done

  printf '\n'
  explain "Pending entries with undo commands: $pending"
  explain "Journal: $FT_JOURNAL"
  explain "Backups: $FT_BACKUP_DIR"

  if (( pending == 0 )); then
    warn "No executable rollback commands were found."
    return 1
  fi
}

stage_rollback() {
  header "Rollback"

  local -a entries=()
  local -a selected=()
  local -a pick=()
  local -a numbers=()
  local entry id date desc undo
  local choice token index
  local failed=0
  local succeeded=0

  if ! mapfile -t entries < <(journal_pending); then
    err "Could not read the change journal."
    return 1
  fi

  if (( ${#entries[@]} == 0 )); then
    ok "Nothing to roll back."
    return 0
  fi

  printf '\n'
  explain "Pending changes are listed in journal order. Verify the operation before undoing it."
  printf '\n'

  for index in "${!entries[@]}"; do
    IFS=$'\t' read -r id date desc undo <<<"${entries[$index]}"

    printf '  %2d) %-20s %s\n' \
      "$((index + 1))" "${date:-unknown}" "${desc:-Unnamed change}"

    if [[ -z $undo ]]; then
      warn "Entry $id has no undo command and cannot be selected."
    fi
  done

  printf '\n'
  explain "Enter numbers separated by spaces, 'a' for all, or press Enter to cancel."

  if [[ ! -r /dev/tty ]]; then
    err "No controlling terminal is available; refusing interactive rollback."
    return 1
  fi

  if ! IFS= read -r -p "Undo which? " choice </dev/tty; then
    warn "Could not read your selection."
    return 1
  fi

  [[ -z $choice ]] && {
    info "Rollback cancelled."
    return 0
  }

  if [[ $choice == a || $choice == all ]]; then
    for index in "${!entries[@]}"; do
      selected+=("$index")
    done
  else
    # Parse the selection without pathname expansion.
    read -r -a numbers <<<"$choice"

    if (( ${#numbers[@]} == 0 )); then
      info "Rollback cancelled."
      return 0
    fi

    for token in "${numbers[@]}"; do
      if [[ ! $token =~ ^[0-9]+$ ]]; then
        err "Invalid selection: $token"
        return 1
      fi

      # Avoid arithmetic evaluation of unusually long user input.
      if (( ${#token} > 9 )); then
        err "Selection is out of range: $token"
        return 1
      fi

      index=$((10#$token))

      if (( index < 1 || index > ${#entries[@]} )); then
        err "Selection is out of range: $token"
        return 1
      fi

      selected+=("$((index - 1))")
    done
  fi

  # Remove duplicates while retaining the user's selection order.
  local -A seen=()
  for index in "${selected[@]}"; do
    if [[ ! ${seen[$index]+present} ]]; then
      pick+=("$index")
      seen[$index]=1
    fi
  done

  if (( ${#pick[@]} == 0 )); then
    info "No changes selected."
    return 0
  fi

  # Refuse entries that cannot be safely interpreted.
  for index in "${pick[@]}"; do
    IFS=$'\t' read -r id date desc undo <<<"${entries[$index]}"

    if [[ -z $id || -z $undo ]]; then
      err "Selected entry $((index + 1)) has no ID or undo command."
      return 1
    fi

    # The existing journal format stores executable commands as text.
    # Reject embedded newlines and control characters before execution.
    if [[ $undo == *$'\n'* || $undo == *$'\r'* ]]; then
      err "Selected entry $id contains an invalid multiline undo command."
      return 1
    fi
  done

  printf '\n'
  explain "Selected rollback operations: ${#pick[@]}"

  for index in "${pick[@]}"; do
    IFS=$'\t' read -r id date desc undo <<<"${entries[$index]}"
    printf '  - %s\n' "${desc:-Unnamed change}"
  done

  if [[ ${FT_DRY_RUN:-0} == 1 ]]; then
    warn "DRY RUN: rollback commands will not be executed."
    for index in "${pick[@]}"; do
      IFS=$'\t' read -r id date desc undo <<<"${entries[$index]}"
      printf '\n  Entry %s\n    %s\n' "$id" "$undo"
    done
    return 0
  fi

  if ! IFS= read -r -p "Proceed with these rollback operations? [y/N] " choice </dev/tty; then
    warn "Could not read confirmation."
    return 1
  fi

  case $choice in
    y|Y|yes|YES) ;;
    *)
      info "Rollback cancelled."
      return 0
      ;;
  esac

  if ! sudo_init; then
    err "Could not initialize sudo. Nothing was rolled back."
    return 1
  fi

  # Execute in the selected order. A failed undo remains pending.
  for index in "${pick[@]}"; do
    IFS=$'\t' read -r id date desc undo <<<"${entries[$index]}"

    printf '\n  %sUndo:%s %s\n' \
      "${C_BOLD:-}" "${C_RESET:-}" "${desc:-Unnamed change}"

    # Journal commands are trusted executable data. Protect the journal
    # against modification by other users and never populate it from
    # untrusted sources.
    if run bash -c "$undo"; then
      if journal_mark_undone "$id"; then
        ok "Entry $id reverted."
        ((succeeded += 1))
      else
        err "Undo ran, but entry $id could not be marked as reverted."
        warn "Check the system state before retrying this entry."
        ((failed += 1))
      fi
    else
      err "Undo command failed for entry $id."
      warn "The entry remains pending. Review the command and current system state before retrying."
      ((failed += 1))
    fi
  done

  printf '\n'
  explain "Rollback summary: $succeeded succeeded, $failed failed."

  note "After rollback" \
    "Some changes require a reboot or a new login session to take full effect. Kernel arguments, modules-load settings and persistent sysctl files may need a reboot. KDE and environment changes may need logout/login. Check each failed entry before retrying it."

  (( failed == 0 ))
}
