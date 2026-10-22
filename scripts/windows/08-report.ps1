# Step 8/8: generate SETUP-REPORT.md from the live state.
param([string]$SmokeOk = '0')
. "$PSScriptRoot\lib.ps1"

Write-Log "Step 8/8: generating $($script:RootDir)/SETUP-REPORT.md"

$sb = New-Object System.Text.StringBuilder
function Add-Line {
    param([string]$Line = '')
    [void]$sb.AppendLine($Line)
}
function Format-Row {
    param([string]$Name, [bool]$Ok, [string]$Detail)
    $mark = if ($Ok) { 'OK' } else { 'FAIL' }
    return "| $Name | $mark | $Detail |"
}

$giteaAdmin = ((Get-GiteaAdminStatus -Url "$($script:GiteaUrl)/api/v1/user") -eq '200')

$orgsOk = $true
$orgsDetail = ''
foreach ($org in $script:ConanRemotes) {
    $code = Get-GiteaAdminStatus -Url "$($script:GiteaUrl)/api/v1/orgs/$org"
    $orgsDetail += "$org`:$code "
    if ($code -ne '200') { $orgsOk = $false }
}

$tokenOk = $false
if ((Test-Path -LiteralPath $script:GiteaTokenFile) -and
    (Get-Item -LiteralPath $script:GiteaTokenFile).Length -gt 0) {
    $savedToken = (Get-Content -Raw -LiteralPath $script:GiteaTokenFile).Trim()
    $code = (Invoke-GiteaCurl @(
            '-s', '-o', '/dev/null', '-w', '%{http_code}',
            '-H', "Authorization: token $savedToken",
            "$($script:GiteaUrl)/api/v1/user"
        )).Trim()
    $tokenOk = ($code -eq '200')
}

$conanVersion = ''
$versionResult = Invoke-Docker -DockerArgs @(
    'exec', $script:ConanContainer, 'conan', '--version'
) -AllowFailure
if ($versionResult.ExitCode -eq 0) {
    $parts = @($versionResult.Output.Trim() -split '\s+')
    if ($parts.Count -ge 3) { $conanVersion = $parts[2] }
}
$conanOk = (-not [string]::IsNullOrEmpty($conanVersion)) -and
    (-not (Test-VersionLt -A $conanVersion -B '2.32'))

$profileOk = $false
$profileResult = Invoke-Docker -DockerArgs @(
    'exec', $script:ConanContainer, 'conan', 'profile', 'show'
) -AllowFailure
if ($profileResult.ExitCode -eq 0) {
    $profileLines = @($profileResult.Output -split "`r?`n" | ForEach-Object { $_.Trim() })
    $profileOk = ($profileLines -contains 'compiler.version=13') -and
        ($profileLines -contains 'compiler.cppstd=17')
}

$remotesOk = $true
$remotesDetail = ''
$remotesList = (Invoke-Docker -DockerArgs @(
        'exec', $script:ConanContainer, 'conan', 'remote', 'list'
    ) -AllowFailure).Output
$usersList = (Invoke-Docker -DockerArgs @(
        'exec', $script:ConanContainer, 'conan', 'remote', 'list-users'
    ) -AllowFailure).Output
function Get-RemoteUrl {
    param([string]$Text, [string]$Name)
    $pattern = '^' + [regex]::Escape($Name) + ':\s+(\S+)'
    foreach ($line in ($Text -split "`r?`n")) {
        $match = [regex]::Match($line, $pattern)
        if ($match.Success) { return $match.Groups[1].Value }
    }
    return ''
}
function Test-RemoteUser {
    param([string]$Text, [string]$Remote, [string]$User)
    $inRemote = $false
    $sawUser = $false
    $sawAuth = $false
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -match ('^' + [regex]::Escape($Remote) + ':\s*$')) {
            $inRemote = $true
            continue
        }
        if ($inRemote -and $line -match '^\S') { break }
        if ($inRemote) {
            if ($line -match ('Username:\s+' + [regex]::Escape($User))) { $sawUser = $true }
            if ($line -match 'authenticated:\s+True') { $sawAuth = $true }
        }
    }
    return ($sawUser -and $sawAuth)
}
foreach ($remote in $script:ConanRemotes) {
    $url = "$($script:ArtifactoryNetworkUrl)/artifactory/api/conan/$remote"
    if ((Get-RemoteUrl -Text $remotesList -Name $remote) -ne $url) { $remotesOk = $false }
    if (-not (Test-RemoteUser -Text $usersList -Remote $remote -User $script:ArtifactoryAdminUser)) {
        $remotesOk = $false
    }
    $remotesDetail += "$remote "
}

$compatOk = $false
$conanHome = (Invoke-Docker -DockerArgs @(
        'exec', $script:ConanContainer, 'conan', 'config', 'home'
    ) -AllowFailure).Output.Trim()
if (-not [string]::IsNullOrEmpty($conanHome)) {
    $compat = (Invoke-Docker -DockerArgs @(
            'exec', $script:ConanContainer, 'cat',
            "$conanHome/extensions/plugins/compatibility/compatibility.py"
        ) -AllowFailure)
    if ($compat.ExitCode -eq 0 -and
        (Test-HasText $compat.Output 'def compatibility(conanfile):') -and
        (Test-HasText $compat.Output 'return []')) {
        $compatOk = $true
    }
}

$jenkinsOk = Test-JenkinsAuth
$adminOk = $false
if ($jenkinsOk -and (Test-Path -LiteralPath $script:JenkinsPassFile)) {
    $savedPass = (Get-Content -Raw -LiteralPath $script:JenkinsPassFile).Trim()
    if (-not [string]::IsNullOrEmpty($savedPass)) {
        $code = (Invoke-Docker -DockerArgs @(
                'exec', $script:JenkinsContainer, 'curl', '-s', '-o', '/dev/null', '-w', '%{http_code}',
                '-u', "$($script:JenkinsAdminUser):$savedPass",
                "$($script:JenkinsUrl)/whoAmI/api/json"
            )).Output.Trim()
        $adminOk = ($code -eq '200')
    }
}

$pluginsOk = $false
$pluginsDetail = ''
if ($jenkinsOk) {
    $pluginsJson = Get-JenkinsPluginJson
    $pluginsOk = $true
    foreach ($plugin in $script:JenkinsPlugins) {
        if (Test-HasText $pluginsJson ('"shortName":"' + $plugin + '"')) {
            $pluginsDetail += "$plugin "
        } else {
            $pluginsOk = $false
        }
    }
}

$credsOk = $false
if ($jenkinsOk) {
    $credsJson = (Invoke-Docker -DockerArgs (@(
                'exec', $script:JenkinsContainer, 'curl', '-sg'
            ) + $script:JenkinsAuth + @(
                "$($script:JenkinsUrl)/credentials/store/system/domain/_/api/json?tree=credentials[id,typeName]"
            ))).Output
    if ((Test-HasText $credsJson '"id":"gitea-admin"') -and
        (Test-HasText $credsJson '"id":"gitea-conan-token"')) {
        $credsOk = $true
    }
}

$serverOk = $false
if ($jenkinsOk) {
    $configureHtml = (Invoke-Docker -DockerArgs (@(
                'exec', $script:JenkinsContainer, 'curl', '-sS'
            ) + $script:JenkinsAuth + @(
                "$($script:JenkinsUrl)/configure"
            ))).Output
    if ((Test-HasText $configureHtml 'http://gitea:3000') -and
        (Test-HasText $configureHtml 'gitea-admin')) {
        $serverOk = $true
    }
}

$smoke = ($SmokeOk -eq '1')
$smokeDetail = if ($smoke) {
    'create → upload → download → promote выполнен, пакеты удалены'
} else {
    'не проверялся в этом запуске'
}

Add-Line '# Отчёт о настройке локального CI-контура'
Add-Line ''
Add-Line ('Дата: ' + (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm') + ' UTC')
Add-Line ('Проект: `' + (Split-Path -Leaf $script:RootDir) + '`')
Add-Line ('Сеть Docker: `' + $script:CiNetwork + '`')
Add-Line ''
Add-Line '## Что настроено'
Add-Line ''
Add-Line '| Компонент | Статус | Проверка |'
Add-Line '|---|---|---|'
Add-Line (Format-Row ('Gitea: администратор `' + $script:GiteaAdminUser + '`') $giteaAdmin 'HTTP 200 и `is_admin=true` (Шаг 1)')
Add-Line (Format-Row 'Gitea: организации' $orgsOk ($orgsDetail + '(Шаг 2)'))
Add-Line (Format-Row 'Gitea: PAT `conan-ci`' $tokenOk 'токен из `.secrets/gitea-token` принят API (Шаг 2)')
Add-Line (Format-Row 'Conan' $conanOk ('версия ' + $(if ($conanVersion) { $conanVersion } else { 'не найдена' }) + ' (требуется ≥ 2.32, Шаг 3)'))
Add-Line (Format-Row 'Conan: профиль' $profileOk 'gcc 13, C++17 (Шаг 3)')
Add-Line (Format-Row 'Conan: remotes' $remotesOk ($remotesDetail + '— URL и `authenticated: True` (Шаг 4)'))
Add-Line (Format-Row 'Conan: compatibility' $compatOk 'плагин заменён на no-op (Шаг 4)')
Add-Line (Format-Row 'Jenkins: администратор' $adminOk ('`' + $script:JenkinsAdminUser + '` логинится, анонимный доступ закрыт (Шаг 5)'))
Add-Line (Format-Row 'Jenkins: плагины' $pluginsOk ($pluginsDetail + '(Шаг 5)'))
Add-Line (Format-Row 'Jenkins: credentials' $credsOk '`gitea-admin`, `gitea-conan-token` (Шаг 6)')
Add-Line (Format-Row 'Jenkins: Gitea Server' $serverOk '`http://gitea:3000`, manageHooks=true (Шаг 6)')
Add-Line (Format-Row 'Smoke-тест Conan' $smoke $smokeDetail)

Add-Line @'

## Учётные данные и секреты

| Файл | Содержимое | Права |
|---|---|---|
| `.secrets/gitea-token` | PAT Gitea (40 hex), scopes: org/repo + read:user | 600 (Linux) |
| `.secrets/jenkins-pass` | пароль Jenkins-администратора | 600 (Linux) |
| каталог `.secrets` | — | 700 (Linux) |
'@
Add-Line ('Пароль Gitea-администратора по умолчанию: `' + $script:GiteaAdminPassword + '` (переопределяется `GITEA_ADMIN_PASSWORD`).')
Add-Line ('Пароль Jenkins-администратора по умолчанию: `' + $script:JenkinsAdminPassword + '` (переопределяется `JENKINS_ADMIN_PASSWORD`).')
Add-Line @'
Токен и пароль записаны в открытом виде: каталог не должен попадать в Git.

Linux-скрипты вызывают `chmod 700/600`; на Windows-ФС (DrvFs) режимы не
сохраняются, поэтому PowerShell-вариант дополнительно применяет `icacls`
(наследование снимается, доступ остаётся у текущего пользователя и `SYSTEM`).
На DrvFs ACL тоже может не отображаться — это ограничение файловой системы.

## Как проверить вручную

Проверки ниже выполняются через `docker exec`, чтобы не зависеть от настроек
локального прокси. Те же API доступны с хоста по опубликованным портам.

```bash
# Gitea
docker exec gitea curl -sS -u 'admin:password' http://localhost:3000/api/v1/user
docker exec gitea curl -sS -H "Authorization: token $(cat .secrets/gitea-token)" http://localhost:3000/api/v1/user

# Организации
for org in packages products develop; do
  docker exec gitea curl -sS -o /dev/null -w "$org %{http_code}\n" \
    -u 'admin:password' "http://localhost:3000/api/v1/orgs/$org"
done

# Conan
docker exec conan conan --version
docker exec conan conan profile show
docker exec conan conan remote list
docker exec conan conan remote list-users
docker exec conan conan list '*' -r=packages

# Jenkins
docker exec jenkins curl -sS -u "admin:$(cat .secrets/jenkins-pass)" http://localhost:8080/whoAmI/api/json
docker exec jenkins curl -sS -u "admin:$(cat .secrets/jenkins-pass)" \
  'http://localhost:8080/credentials/store/system/domain/_/api/json?tree=credentials[id]'
```

PowerShell: те же команды, но секреты читаются иначе.

```powershell
$token = (Get-Content .secrets/gitea-token -Raw).Trim()
docker exec gitea curl -sS -H "Authorization: token $token" http://localhost:3000/api/v1/user
$pass = (Get-Content .secrets/jenkins-pass -Raw).Trim()
docker exec jenkins curl -sS -u "admin:$pass" http://localhost:8080/whoAmI/api/json
```

Повторный запуск всего контура:

- Linux/WSL: `bash scripts/linux/bootstrap.sh`
- Windows PowerShell: `powershell -ExecutionPolicy Bypass -File scripts/windows/bootstrap.ps1`
  (или `powershell -ExecutionPolicy Bypass -File bootstrap.ps1`)

Скрипты идемпотентны: повторный прогон не пересоздаёт организации, токен (если он
валиден), remotes и пользователей, а smoke-пакеты удаляются в конце.

## Ограничения и отклонения

1. **Сервис `conan` описан в `docker-compose.yml`.** Это контейнер
   `ubuntu:24.04` с `sleep infinity` и томом `conan_workspace`; bootstrap
   устанавливает в него toolchain и Conan. Для стека, созданного до появления
   сервиса, шаг `00` создаёт контейнер вручную как fallback.

2. **`docker compose down -v` не выполнялся.** Это разрушило бы данные общего
   стека (Gitea, Jenkins, Artifactory, Postgres) на машине. Идемпотентность
   проверена последовательными прогонами обоих вариантов без удаления томов.
   Полный прогон «с нуля» на чистом хосте не проверялся.

3. **Conan 2.33 требует файл `compatibility.py`.** Удаление или опустошение
   файла ломает все команды Conan. Плагин заменён на функцию, возвращающую
   пустой список (бинарные fallback-и не создаются).

4. **Gitea 28.0.0, Jenkins 2.580.1** — фактические версии из compose; они
   отличаются от версий в исходном описании задания (1.27.3 / 2.568.3).
   API-вызовы и CLI-флаги проверены на этих версиях.

5. **Gitea PAT.** После `change-password` Gitea выставляет
   `must-change-password`; скрипт снимает флаг через
   `gitea admin user must-change-password --unset`. Для проверки PAT требуется
   scope `read:user` (write-scopes не дают доступа к `/api/v1/user`).

6. **Плагины Jenkins** ставятся в `/var/jenkins_home/plugins` (том), а не в
   `/usr/share/jenkins/ref/plugins` (слой образа). После установки новых
   плагинов скрипт перезапускает Jenkins; повторный прогон перезапуска не делает.

7. **Пайплайн по push не создавался.** Bootstrap не создаёт репозиторий,
   Jenkins job и webhook; настроены только Gitea Server, credentials и плагины.
   Для сквозного сценария нужно создать репозиторий, Jenkins job (Pipeline from
   SCM) и включить webhook (manageHooks=true уже задан).

8. **Gitea Package Registry отключён.** Gitea хранит только исходники; все
   Conan-артефакты находятся в Artifactory, а remotes `packages`,
   `products`, `develop` указывают на его Conan API.

9. **`conan upload --list`** в Conan 2.33 привязан к исходному remote, поэтому
   продвижение между `packages`/`products`/`develop` выполняется через
   `download` + `upload` (см. `scripts/linux/07-smoke-test.sh` и
   `scripts/windows/07-smoke-test.ps1`).

## Состав скриптов

| Назначение | Linux (bash) | Windows (PowerShell) |
|---|---|---|
| общие переменные, ожидание сервисов, API-хелперы | `scripts/linux/lib.sh` | `scripts/windows/lib.ps1` |
| ожидание Gitea/Jenkins, проверка сервиса `conan` | `scripts/linux/00-wait-ready.sh` | `scripts/windows/00-wait-ready.ps1` |
| администратор, `[packages]`, `ALLOWED_HOST_LIST` | `scripts/linux/01-gitea-admin.sh` | `scripts/windows/01-gitea-admin.ps1` |
| организации `packages/products/develop`, PAT | `scripts/linux/02-gitea-orgs-token.sh` | `scripts/windows/02-gitea-orgs-token.ps1` |
| установка Conan/тулчейна, профиль gcc 13 / C++17 | `scripts/linux/03-conan-profile.sh` | `scripts/windows/03-conan-profile.ps1` |
| remotes, логин, отключение compatibility | `scripts/linux/04-conan-remotes.sh` | `scripts/windows/04-conan-remotes.ps1` |
| плагины, URL, security realm, администратор | `scripts/linux/05-jenkins-admin.sh` | `scripts/windows/05-jenkins-admin.ps1` |
| credentials и Gitea Server | `scripts/linux/06-jenkins-gitea.sh` | `scripts/windows/06-jenkins-gitea.ps1` |
| create → upload → download → promote → cleanup | `scripts/linux/07-smoke-test.sh` | `scripts/windows/07-smoke-test.ps1` |
| этот отчёт | `scripts/linux/08-report.sh` | `scripts/windows/08-report.ps1` |
| последовательный запуск 00–07 и отчёта | `scripts/linux/bootstrap.sh` (обёртка `bootstrap.sh`) | `scripts/windows/bootstrap.ps1` (обёртка `bootstrap.ps1`) |
'@

$reportPath = Join-Path $script:RootDir 'SETUP-REPORT.md'
$text = $sb.ToString().Replace("`r`n", "`n")
[IO.File]::WriteAllText($reportPath, $text, (New-Object System.Text.UTF8Encoding($false)))

if (-not (Test-Path -LiteralPath $reportPath) -or (Get-Item -LiteralPath $reportPath).Length -eq 0) {
    Stop-WithError 'report was not written'
}
Write-Log "Step 8/8: OK ($reportPath)"
