#!/usr/bin/env bash
# Bootstrap the local Gitea + Jenkins + Conan contour.
# Idempotent: safe to rerun on an existing stack.
set -euo pipefail
cd "$(cd "$(dirname "$0")/../.." && pwd)"

mkdir -p .secrets
chmod 700 .secrets

started="$(date +%s)"
for step in \
  00-wait-ready.sh \
  01-gitea-admin.sh \
  02-gitea-orgs-token.sh \
  03-conan-profile.sh \
  04-conan-remotes.sh \
  05-jenkins-admin.sh \
  06-jenkins-gitea.sh \
  07-smoke-test.sh; do
  printf '\n########## %s ##########\n' "$step"
  bash "scripts/linux/${step}"
done

printf '\n########## 08-report.sh ##########\n'
bash scripts/linux/08-report.sh 1

elapsed=$(( $(date +%s) - started ))
printf '\nBootstrap finished in %ss. Report: %s/SETUP-REPORT.md\n' "$elapsed" "$PWD"
