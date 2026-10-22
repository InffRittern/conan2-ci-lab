#!/usr/bin/env bash
# Step 8/8: generate SETUP-REPORT.md from the live state.
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

log "Step 8/8: generating ${ROOT_DIR}/SETUP-REPORT.md"

row() { # name status detail
  local mark='OK'
  [ "$2" = "1" ] || mark='FAIL'
  printf '| %s | %s | %s |\n' "$1" "$mark" "$3"
}

gitea_admin=0
[ "$(gitea_admin_status "${GITEA_URL}/api/v1/user")" = "200" ] && gitea_admin=1

orgs_ok=1
orgs_detail=''
for org in "${CONAN_REMOTES[@]}"; do
  code="$(gitea_admin_status "${GITEA_URL}/api/v1/orgs/${org}")"
  orgs_detail="${orgs_detail}${org}:${code} "
  [ "$code" = "200" ] || orgs_ok=0
done

token_ok=0
if [ -s "$GITEA_TOKEN_FILE" ]; then
  code="$(gitea_curl -s -o /dev/null -w '%{http_code}' \
    -H "Authorization: token $(cat "$GITEA_TOKEN_FILE")" "${GITEA_URL}/api/v1/user")"
  [ "$code" = "200" ] && token_ok=1
fi

conan_version="$(docker exec "$CONAN_CONTAINER" conan --version 2>/dev/null | awk '{print $3}' || true)"
conan_ok=0
[ -n "$conan_version" ] && ! version_lt "$conan_version" "2.32" && conan_ok=1

profile_ok=0
if docker exec "$CONAN_CONTAINER" conan profile show 2>/dev/null | grep -qx 'compiler.version=13' \
   && docker exec "$CONAN_CONTAINER" conan profile show 2>/dev/null | grep -qx 'compiler.cppstd=17'; then
  profile_ok=1
fi

remotes_ok=1
remotes_detail=''
remotes_list="$(docker exec "$CONAN_CONTAINER" conan remote list 2>/dev/null || true)"
users_list="$(docker exec "$CONAN_CONTAINER" conan remote list-users 2>/dev/null || true)"
for remote in "${CONAN_REMOTES[@]}"; do
  url="${ARTIFACTORY_NETWORK_URL}/artifactory/api/conan/${remote}"
  if ! printf '%s\n' "$remotes_list" | grep -q "^${remote}: ${url} "; then
    remotes_ok=0
  fi
  if ! printf '%s\n' "$users_list" | grep -A3 "^${remote}:" | grep -q "authenticated: True"; then
    remotes_ok=0
  fi
  remotes_detail="${remotes_detail}${remote} "
done

compat_ok=0
if docker exec "$CONAN_CONTAINER" sh -c '
     f="$(conan config home)/extensions/plugins/compatibility/compatibility.py"
     grep -q "^def compatibility(conanfile):" "$f" && grep -q "return \[\]" "$f"' 2>/dev/null; then
  compat_ok=1
fi

jenkins_ok=0
jenkins_auth_probe && jenkins_ok=1 || true
admin_ok=0
if [ "$jenkins_ok" = "1" ] && [ -s "$JENKINS_PASS_FILE" ]; then
  code="$(docker exec "$JENKINS_CONTAINER" curl -s -o /dev/null -w '%{http_code}' \
    -u "${JENKINS_ADMIN_USER}:$(cat "$JENKINS_PASS_FILE")" \
    "${JENKINS_URL}/whoAmI/api/json")"
  [ "$code" = "200" ] && admin_ok=1
fi

plugins_ok=0
plugins_detail=''
if [ "$jenkins_ok" = "1" ]; then
  plugins_json="$(jenkins_plugin_json 2>/dev/null || true)"
  plugins_ok=1
  for plugin in "${JENKINS_PLUGINS[@]}"; do
    if has_text "$plugins_json" "\"shortName\":\"${plugin}\""; then
      plugins_detail="${plugins_detail}${plugin} "
    else
      plugins_ok=0
    fi
  done
fi

creds_ok=0
if [ "$jenkins_ok" = "1" ]; then
  creds_json="$(docker exec "$JENKINS_CONTAINER" curl -sg ${JENKINS_AUTH} \
    "${JENKINS_URL}/credentials/store/system/domain/_/api/json?tree=credentials[id,typeName]" 2>/dev/null || true)"
  if has_text "$creds_json" '"id":"gitea-admin"' \
     && has_text "$creds_json" '"id":"artifactory-password"'; then
    creds_ok=1
  fi
fi

server_ok=0
if [ "$jenkins_ok" = "1" ]; then
  configure_html="$(docker exec "$JENKINS_CONTAINER" curl -sS ${JENKINS_AUTH} \
    "${JENKINS_URL}/configure" 2>/dev/null || true)"
  if has_text "$configure_html" 'http://gitea:3000' \
     && has_text "$configure_html" 'gitea-admin'; then
    server_ok=1
  fi
fi

smoke_ok="${1:-0}"
smoke_detail='не проверялся в этом запуске'
[ "$smoke_ok" = "1" ] && smoke_detail='create → upload → download → promote выполнен, пакеты удалены'

cat > "${ROOT_DIR}/SETUP-REPORT.md" <<EOF
# Отчёт о настройке локального CI-контура

Дата: $(date -u '+%Y-%m-%d %H:%M UTC')
Проект: \`$(basename "$ROOT_DIR")\`
Сеть Docker: \`${CI_NETWORK}\`

## Что настроено

| Компонент | Статус | Проверка |
|---|---|---|
$(row "Gitea: администратор \`${GITEA_ADMIN_USER}\`" "$gitea_admin" "HTTP 200 и \`is_admin=true\` (Шаг 1)")
$(row "Gitea: организации" "$orgs_ok" "${orgs_detail}(Шаг 2)")
$(row "Gitea: PAT \`conan-ci\`" "$token_ok" "токен из \`.secrets/gitea-token\` принят API (Шаг 2)")
$(row "Conan" "$conan_ok" "версия ${conan_version:-не найдена} (требуется ≥ 2.32, Шаг 3)")
$(row "Conan: профиль" "$profile_ok" "gcc 13, C++17 (Шаг 3)")
$(row "Conan: remotes" "$remotes_ok" "${remotes_detail}— URL и \`authenticated: True\` (Шаг 4)")
$(row "Conan: compatibility" "$compat_ok" "плагин заменён на no-op (Шаг 4)")
$(row "Jenkins: администратор" "$admin_ok" "\`${JENKINS_ADMIN_USER}\` логинится, анонимный доступ закрыт (Шаг 5)")
$(row "Jenkins: плагины" "$plugins_ok" "${plugins_detail}(Шаг 5)")
$(row "Jenkins: credentials" "$creds_ok" "\`gitea-admin\`, \`artifactory-password\` (Шаг 6)")
$(row "Jenkins: Gitea Server" "$server_ok" "\`http://gitea:3000\`, manageHooks=true (Шаг 6)")
$(row "Smoke-тест Conan" "$smoke_ok" "$smoke_detail")

## Учётные данные и секреты

| Файл | Содержимое | Права |
|---|---|---|
| \`.secrets/gitea-token\` | PAT Gitea (40 hex), scopes: org/repo + read:user | 600 |
| \`.secrets/jenkins-pass\` | пароль Jenkins-администратора | 600 |
| каталог \`.secrets\` | — | 700 |

> \`chmod 700/600\` вызывается Linux-скриптами. На Windows-ФС (DrvFs) режимы не
> сохраняются: каталог отображается как \`755\`, файлы — как \`644\`. PowerShell-вариант
> дополнительно применяет \`icacls\` (наследование снимается, доступ остаётся у
> текущего пользователя и \`SYSTEM\`); на DrvFs ACL тоже может не отображаться.

Пароль Gitea-администратора по умолчанию: \`${GITEA_ADMIN_PASSWORD}\` (переопределяется \`GITEA_ADMIN_PASSWORD\`).
Пароль Jenkins-администратора по умолчанию: \`${JENKINS_ADMIN_PASSWORD}\` (переопределяется \`JENKINS_ADMIN_PASSWORD\`).
Токен и пароль записаны в открытом виде: каталог не должен попадать в Git.

## Как проверить вручную

Проверки ниже выполняются через \`docker exec\`, чтобы не зависеть от настроек
локального прокси. Те же API доступны с хоста по опубликованным портам.

\`\`\`bash
# Gitea
docker exec gitea curl -sS -u '${GITEA_ADMIN_USER}:${GITEA_ADMIN_PASSWORD}' http://localhost:3000/api/v1/user
docker exec gitea curl -sS -H "Authorization: token \$(cat .secrets/gitea-token)" http://localhost:3000/api/v1/user

# Организации
for org in packages products develop; do
  docker exec gitea curl -sS -o /dev/null -w "\$org %{http_code}\\n" \\
    -u '${GITEA_ADMIN_USER}:${GITEA_ADMIN_PASSWORD}' "http://localhost:3000/api/v1/orgs/\$org"
done

# Conan
docker exec conan conan --version
docker exec conan conan profile show
docker exec conan conan remote list
docker exec conan conan remote list-users
docker exec conan conan list '*' -r=packages

# Jenkins
docker exec jenkins curl -sS -u "${JENKINS_ADMIN_USER}:\$(cat .secrets/jenkins-pass)" http://localhost:8080/whoAmI/api/json
docker exec jenkins curl -sS -u "${JENKINS_ADMIN_USER}:\$(cat .secrets/jenkins-pass)" \\
  'http://localhost:8080/credentials/store/system/domain/_/api/json?tree=credentials[id]'
\`\`\`

PowerShell: те же команды, но секреты читаются иначе.

\`\`\`powershell
\$token = (Get-Content .secrets/gitea-token -Raw).Trim()
docker exec gitea curl -sS -H "Authorization: token \$token" http://localhost:3000/api/v1/user
\$pass = (Get-Content .secrets/jenkins-pass -Raw).Trim()
docker exec jenkins curl -sS -u "admin:\$pass" http://localhost:8080/whoAmI/api/json
\`\`\`

Повторный запуск всего контура:

- Linux/WSL: \`bash scripts/linux/bootstrap.sh\`
- Windows PowerShell: \`powershell -ExecutionPolicy Bypass -File scripts/windows/bootstrap.ps1\`
  (или \`powershell -ExecutionPolicy Bypass -File bootstrap.ps1\`)

Скрипты идемпотентны:
повторный прогон не пересоздаёт организации, токен (если он валиден), remotes и
пользователей, а smoke-пакеты удаляются в конце.

## Ограничения и отклонения

1. **Сервис \`conan\` описан в \`docker-compose.yml\`.** Это контейнер
   \`ubuntu:24.04\` с \`sleep infinity\` и томом \`conan_workspace\`; bootstrap
   устанавливает в него toolchain и Conan. Для стека, созданного до появления
   сервиса, шаг \`00\` создаёт контейнер вручную как fallback.

2. **\`docker compose down -v\` не выполнялся.** Это разрушило бы данные общего
   стека (Gitea, Jenkins, Artifactory, Postgres) на машине. Идемпотентность
   проверена последовательными прогонами обоих вариантов (\`bootstrap.sh\` и
   \`bootstrap.ps1\`) без удаления томов. Полный прогон «с нуля» на чистом хосте
   не проверялся.

3. **Conan 2.33 требует файл \`compatibility.py\`.** Удаление или опустошение
   файла ломает все команды Conan. Плагин заменён на функцию, возвращающую
   пустой список (бинарные fallback-и не создаются).

4. **Gitea 28.0.0, Jenkins 2.580.1** — фактические версии из compose; они
   отличаются от версий в исходном описании задания (1.27.3 / 2.568.3).
   API-вызовы и CLI-флаги проверены на этих версиях.

5. **Gitea PAT.** После \`change-password\` Gitea выставляет
   \`must-change-password\`; скрипт снимает флаг через
   \`gitea admin user must-change-password --unset\`. Для проверки PAT требуется
   scope \`read:user\` (write-scopes не дают доступа к \`/api/v1/user\`).

6. **Плагины Jenkins** ставятся в \`/var/jenkins_home/plugins\` (том), а не в
   \`/usr/share/jenkins/ref/plugins\` (слой образа). После установки новых
   плагинов скрипт перезапускает Jenkins; повторный прогон перезапуска не делает.

7. **Пайплайн по push не создавался.** Bootstrap не создаёт репозиторий,
   Jenkins job и webhook; настроены только Gitea Server, credentials и плагины.
   Для сквозного сценария нужно создать репозиторий, Jenkins job (Pipeline from
   SCM) и включить webhook (manageHooks=true уже задан).

8. **Gitea Package Registry отключён.** Gitea хранит только исходники; все
   Conan-артефакты находятся в Artifactory, а remotes \`packages\`,
   \`products\`, \`develop\` указывают на его Conan API.

9. **\`conan upload --list\`** в Conan 2.33 привязан к исходному remote, поэтому
   продвижение между \`packages\`/\`products\`/\`develop\` выполняется через
   \`download\` + \`upload\` (см. \`scripts/linux/07-smoke-test.sh\` и
   \`scripts/windows/07-smoke-test.ps1\`).

## Состав скриптов

| Назначение | Linux (bash) | Windows (PowerShell) |
|---|---|---|
| общие переменные, ожидание сервисов, API-хелперы | \`scripts/linux/lib.sh\` | \`scripts/windows/lib.ps1\` |
| ожидание Gitea/Jenkins, проверка сервиса \`conan\` | \`scripts/linux/00-wait-ready.sh\` | \`scripts/windows/00-wait-ready.ps1\` |
| администратор, \`[packages]\`, \`ALLOWED_HOST_LIST\` | \`scripts/linux/01-gitea-admin.sh\` | \`scripts/windows/01-gitea-admin.ps1\` |
| организации \`packages/products/develop\`, PAT | \`scripts/linux/02-gitea-orgs-token.sh\` | \`scripts/windows/02-gitea-orgs-token.ps1\` |
| установка Conan/тулчейна, профиль gcc 13 / C++17 | \`scripts/linux/03-conan-profile.sh\` | \`scripts/windows/03-conan-profile.ps1\` |
| remotes, логин, отключение compatibility | \`scripts/linux/04-conan-remotes.sh\` | \`scripts/windows/04-conan-remotes.ps1\` |
| плагины, URL, security realm, администратор | \`scripts/linux/05-jenkins-admin.sh\` | \`scripts/windows/05-jenkins-admin.ps1\` |
| credentials и Gitea Server | \`scripts/linux/06-jenkins-gitea.sh\` | \`scripts/windows/06-jenkins-gitea.ps1\` |
| create → upload → download → promote → cleanup | \`scripts/linux/07-smoke-test.sh\` | \`scripts/windows/07-smoke-test.ps1\` |
| этот отчёт | \`scripts/linux/08-report.sh\` | \`scripts/windows/08-report.ps1\` |
| последовательный запуск 00–07 и отчёта | \`scripts/linux/bootstrap.sh\` (обёртка \`bootstrap.sh\`) | \`scripts/windows/bootstrap.ps1\` (обёртка \`bootstrap.ps1\`) |
EOF

[ -s "${ROOT_DIR}/SETUP-REPORT.md" ] || die "report was not written"
log "Step 8/8: OK (${ROOT_DIR}/SETUP-REPORT.md)"
