#!/bin/bash
set -euo pipefail

export GH_CONFIG_DIR=/cache/agent-github-app/gh
export GH_HOST=github.com
mkdir -p "$GH_CONFIG_DIR"

case "${1:-}" in
  --version|version|help|completion) exec /bin/gh "$@" ;;
esac

normalize_repository() {
  local value="$1" owner="" name=""
  case "$value" in
    https://github.com/*) value="${value#https://github.com/}" ;;
    ssh://git@github.com/*) value="${value#ssh://git@github.com/}" ;;
    git@github.com:*) value="${value#git@github.com:}" ;;
    github.com/*) value="${value#github.com/}" ;;
    *://*|*@*) return 1 ;;
  esac
  value="${value%%\?*}"
  value="${value%%\#*}"
  [[ "$value" == */* ]] || return 1
  owner="${value%%/*}"
  name="${value#*/}"
  name="${name%%/*}"
  name="${name%.git}"
  [[ "$owner" =~ ^[A-Za-z0-9-]+$ && "$name" =~ ^[A-Za-z0-9_.-]+$ ]] || return 1
  printf '%s/%s\n' "$owner" "$name"
}

explicit_repo=""
target_repo=""
expect_repo=0
skip_value=0
for argument in "$@"; do
  if [ "$expect_repo" = 1 ]; then
    explicit_repo="$argument"
    expect_repo=0
    continue
  fi
  if [ "$skip_value" = 1 ]; then
    skip_value=0
    continue
  fi
  case "$argument" in
    -R|--repo) expect_repo=1 ;;
    --repo=*) explicit_repo="${argument#--repo=}" ;;
    -R?*) explicit_repo="${argument#-R}" ;;
    --help|-h) exec /bin/gh "$@" ;;
    -f|-F|-H|-q|-t|-X|-o|-b|-B|--field|--raw-field|--header|--jq|--template|--method|--input|--hostname|--cache|--preview|--output|--branch|--base|--head|--title|--body|--body-file|--label|--assignee|--reviewer|--milestone|--project|--search|--limit|--json)
      skip_value=1
      ;;
    repos/*/*|/repos/*/*|https://api.github.com/repos/*/*)
      if [ "${1:-}" = api ]; then
        endpoint="${argument#https://api.github.com/}"
        endpoint="${endpoint#/}"
        target_repo="$(normalize_repository "${endpoint#repos/}" || true)"
      fi
      ;;
    https://github.com/*)
      target_repo="$(normalize_repository "$argument" || true)"
      ;;
  esac
done

if [ -z "$target_repo" ] && [ "${1:-}" = repo ]; then
  case "${2:-}" in
    clone|view|fork|sync|create) target_repo="$(normalize_repository "${3:-}" || true)" ;;
  esac
fi

repository=""
if [ -n "$target_repo" ]; then
  repository="$target_repo"
elif [ -n "$explicit_repo" ]; then
  repository="$(normalize_repository "$explicit_repo")" || {
    echo '[agent] --repo must identify a GitHub.com OWNER/REPO' >&2
    exit 1
  }
elif [ -n "${GH_REPO:-}" ]; then
  repository="$(normalize_repository "$GH_REPO")" || {
    echo '[agent] GH_REPO must identify a GitHub.com OWNER/REPO' >&2
    exit 1
  }
else
  remote=""
  while read -r key value; do
    if [ "$value" = base ]; then
      remote="${key#remote.}"
      remote="${remote%.gh-resolved}"
      break
    fi
  done < <(/bin/git config --get-regexp '^remote\..*\.gh-resolved$' 2>/dev/null || true)
  remote="${remote:-origin}"
  remote_url="$(/bin/git remote get-url "$remote" 2>/dev/null || true)"
  repository="$(normalize_repository "$remote_url" || true)"
fi

GH_TOKEN="$("$(dirname "$0")/github-app-token" "$repository")" || {
  echo '[agent] GitHub App authentication failed; check installation access and select a repository with GH_REPO or --repo' >&2
  exit 1
}
export GH_TOKEN
if [ -n "$repository" ]; then
  export GH_REPO="$repository"
fi
exec /bin/gh "$@"
