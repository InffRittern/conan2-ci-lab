# Инструкция: миграция Conan 1.x → Conan 2.x

Документ описывает миграцию Conan-хранилища в JFrog Artifactory CE.
Проверено на Artifactory CE `7.161.26`, Conan 1.66.0 и Conan 2.33.0,
Linux/GCC 13; сценарии `01–08` демонстрационного стенда пройдены.

Артефакты Conan хранятся только в JFrog Artifactory. Gitea используется
только как Git-хостинг исходников, Jenkins — только как CI/CD runner.
Мигрирует только Conan-хранилище; исходники, Git-история, Jenkins jobs и
SCM не переносятся.

Все относительные пути в примерах (`profiles/...`, `scenarios/...`) указаны
от `demo/conan-migration-sandbox`, если не указано иное; при запуске из корня
репозитория добавляйте этот префикс.

## Архитектура

| Компонент | Роль | Что хранит |
|---|---|---|
| Gitea | Git-хостинг | только исходники, `conanfile.py`, `test_package`, `Jenkinsfile` |
| Jenkins | CI/CD runner | pipeline-конфигурацию и build-артефакты; Conan-пакеты не хранит |
| JFrog Artifactory | artifact store | все Conan 1 source- и Conan 2 target-репозитории |

Правила:

- в Gitea **нет** Conan Package Registry; не настраивайте remote вида
  `.../api/packages/<owner>/conan`;
- Jenkins делает checkout из Gitea, собирает и загружает пакеты только в
  JFrog;
- все `conan upload`, `conan install`, `conan download` направлены в
  Artifactory;
- Gitea и Jenkins не входят в backup/rollback Artifactory.

Обозначения:

- **source** — Conan 1: LOCAL `conan-local`, `ap`, `ap-thirdparty`; VIRTUAL
  `conan-ap` (агрегирует `ap`), `conan-thirdparty` (агрегирует
  `ap-thirdparty`) и корневой `conan` (`conan-local`, `ap`, `ap-thirdparty`,
  `conan-remote` — ConanCenter);
- **target** — Conan 2-репозитории `packages`, `products`, `develop`,
  объединённые virtual `conan2`;
- **pref** — точная ссылка `name/version#recipe_revision:package_id`;
- **freeze** — запрет публикации в source на время cutover.

## 1. Границы и обязательные условия

Мигрируют:

- рецепты и бинарники Conan;
- все используемые package revisions;
- remotes клиентов, CI и разработчиков.

Не мигрируют:

- Git-репозитории, Jenkins jobs, webhooks, SCM;
- generic-артефакты `generic-local`;
- служебный `artifactory-build-info` (это build-info, не Conan-репозиторий).

Обязательно:

- резервная копия Artifactory (БД + filestore);
- окно freeze: в source никто не публикует;
- отдельные `CONAN_USER_HOME` для Conan 1 и `CONAN_HOME` для Conan 2;
- сервисная учётная запись Artifactory, а не `admin`, для production;
- проверка, что все клиенты умеют работать с выбранным target remote.

## 2. Инвентаризация source

Conan 1.66:

```bash
export CONAN_USER_HOME=/tmp/conan1-home
export CONAN_REVISIONS_ENABLED=1
CONAN1=/path/to/conan1/bin/conan
PROFILE=/path/to/profiles/linux-gcc-release

$CONAN1 --version
```

Добавьте source-remotes и войдите:

```bash
for r in conan-local ap ap-thirdparty conan-ap conan-thirdparty conan; do
  $CONAN1 remote add "$r" \
    "$ARTIFACTORY_URL/artifactory/api/conan/$r"
  $CONAN1 user -p "$ARTIFACTORY_PASSWORD" -r "$r" "$ARTIFACTORY_USER"
done
```

Снимите inventory:

```bash
for r in conan-local ap ap-thirdparty conan-ap conan-thirdparty conan; do
  echo "== $r"
  $CONAN1 search "*" -r "$r"
done > /tmp/conan1-inventory.txt

# Conan 1.66: wildcard с --revisions завершается ошибкой.
# Ревизии снимайте только по конкретному ref.
# Список refs возьмите из вывода search; ниже — пример для стенда:
for ref in 'ap/1.0.0@' 'ap-thirdparty/1.0.0@'; do
  for r in ap ap-thirdparty conan-ap conan-thirdparty conan; do
    echo "== $ref --revisions -r $r"
    $CONAN1 search "$ref" --revisions -r "$r"
  done
done >> /tmp/conan1-inventory.txt
```

`conan search "*" -r conan` включает ConanCenter через `conan-remote`;
для source-инвентаря используйте локальные/virtual source-репозитории и
явные refs.

Для машинной сверки JSON снимайте по конкретному ref; wildcard с
`--revisions` в 1.66 не работает:

```bash
$CONAN1 search 'ap/1.0.0@' --revisions --json /tmp/ap-revisions.json -r ap
```

`conan search ref` даёт package ID, `--revisions` — recipe revision.
Package revision в этом выводе не показывается: для переноса используйте
manifest/pref из кэша (раздел 6).

Пример фактического inventory стенда:

```text
ap/1.0.0             rrev 94b5374a94ac677865de5094132c484a  pkg 3dcaac93f3cf6432dc25ae41cd21792a9760e18b
ap-thirdparty/1.0.0  rrev 8861c4b019a9721e437350de4738b5de  pkg 3dcaac93f3cf6432dc25ae41cd21792a9760e18b
```

## 3. Сборка source-пакетов

Порядок обязателен из-за зависимостей:

```text
ap-headers/1.3.290
ap-headers/1.4.1
ap-base
ap-utils
ap-gfx
ap-texture
ap-box
ap-sdk
ap-product-a
ap-product-b
```

Если в вашем хозяйстве есть отдельные recipe-only репозитории, добавьте их
в конец порядка.

Пример:

```bash
cd /workspace/legacy-src/libs/ap-base
$CONAN1 create . --build=missing -pr="$PROFILE"
```

Не передавайте второй positional reference (`conan create . ap-base/1.0.0`):
в Conan 1 это может создать `ap-base/1.0.0@ap-base/1.0.0`. Версия задаётся
`set_version()` или переменной окружения рецепта.

Для `ap-headers` две версии:

```bash
cd /workspace/legacy-src/libs/ap-headers
AP_HEADERS_VERSION=1.3.290 \
  $CONAN1 create . --build=missing -pr="$PROFILE"
AP_HEADERS_VERSION=1.4.1 \
  $CONAN1 create . --build=missing -pr="$PROFILE"
```

Проверка локального кэша:

```bash
$CONAN1 search "*"

# ревизии — только по конкретному ref
$CONAN1 search 'ap-base/1.0.0@' --revisions
$CONAN1 search 'ap-headers/1.3.290@' --revisions
```

## 4. Загрузка source-пакетов

Загружайте точный pref, а не только `name/version`:

```bash
upload_pref() {
  repo="$1"
  ref="$2"
  rrev=$($CONAN1 search "$ref" --revisions | grep -oE '#[0-9a-f]{32}' | head -1 | tr -d '#')
  [ -n "$rrev" ] || { echo "no revision: $ref" >&2; return 1; }
  base="$CONAN_USER_HOME/.conan/data/${ref%/*}/${ref#*/}/_/_/package"

  for pkgid in $(find "$base" -mindepth 1 -maxdepth 1 -type d -printf '%f\n'); do
    echo "$ref#$rrev:$pkgid -> $repo"
    $CONAN1 upload "$ref#$rrev:$pkgid" \
      -r "$repo" --all --confirm
  done
}

upload_pref ap-thirdparty ap-headers/1.3.290
upload_pref ap-thirdparty ap-headers/1.4.1
upload_pref ap ap-base/1.0.0
upload_pref ap ap-utils/1.0.0
upload_pref ap ap-gfx/1.0.0
upload_pref ap ap-texture/1.0.0
upload_pref ap ap-box/1.0.0
upload_pref ap ap-sdk/1.0.0
upload_pref conan-local ap-product-a/1.0.0
upload_pref conan-local ap-product-b/1.0.0
```

Загружайте в LOCAL `ap`/`ap-thirdparty`; virtual `conan-ap` и
`conan-thirdparty` только агрегируют их для чтения.

Проверка:

```bash
$CONAN1 search "*" -r ap
$CONAN1 search "*" -r ap-thirdparty
$CONAN1 search "*" -r conan-local
$CONAN1 search 'ap/1.0.0@' --revisions -r conan-ap
```

Для virtual `conan` нужен `CONAN_REVISIONS_ENABLED=1`; без него Conan 1
получает ошибку `only works with revisions enabled`.

## 5. Создание target-репозиториев

`packages`, `products`, `develop` — LOCAL Conan. Если их нет, создайте YAML:

```yaml
localRepositories:
  packages:
    type: conan
  products:
    type: conan
  develop:
    type: conan
```

Virtual `conan2` обязателен: Conan 2 разрешает зависимости в рамках одного
remote, через который найден корневой рецепт. Без него `products` не видит
`packages`.

```yaml
virtualRepositories:
  conan2:
    type: conan
    repositories:
      - packages
      - products
      - develop
```

Применение:

```bash
curl -u "$ARTIFACTORY_USER:$ARTIFACTORY_PASSWORD" \
  -H 'Content-Type: application/yaml' \
  -X PATCH \
  --data-binary @repos.yaml \
  "$ARTIFACTORY_URL/artifactory/api/system/configuration"
```

Проверка:

```bash
curl -u "$ARTIFACTORY_USER:$ARTIFACTORY_PASSWORD" \
  "$ARTIFACTORY_URL/artifactory/api/repositories"
```

`conan-remote-cache` вручную не создавайте: это не отдельный API-репозиторий,
а узел кэша remote в UI Artifactory. В `/api/repositories` его нет; кэш
обслуживается Artifactory автоматически.

В Artifactory CE `DELETE /api/repositories/<key>` возвращает HTTP 400
(удаление репозитория — Pro-only). Временные репозитории удаляйте через
PATCH конфигурации:

```yaml
localRepositories:
  temp-repo: null
virtualRepositories:
  temp-virtual: null
```

Для аудита при необходимости создайте отдельный LOCAL-репозиторий, например
`legacy` (раздел 6).

## 6. Перенос точных pref в audit-репозиторий (опционально)

Этот шаг переносит исходные бинарники и рецепты в отдельный LOCAL-репозиторий
`legacy` для аудита и rollback. **Не загружайте их в `packages`/`products`**:
legacy-рецепт может стать latest и перекрыть Conan 2-рецепт. Для чистого
cutover раздел можно пропустить — source остаётся архивом. Перенос **не
заменяет пересборку** под Conan 2: package ID Conan 2 отличается.

```bash
export CONAN_HOME=/tmp/conan2-home
export LEGACY_REPO=legacy
rm -rf "$CONAN_HOME"
conan profile detect --force

for r in conan conan-local ap ap-thirdparty conan-ap conan-thirdparty "$LEGACY_REPO"; do
  conan remote add -f "$r" \
    "$ARTIFACTORY_URL/artifactory/api/conan/$r"
  conan remote login "$r" "$ARTIFACTORY_USER" -p "$ARTIFACTORY_PASSWORD"
done
```

Manifest `source_repo|ref|rrev|pkgid` можно получить из Conan 1-кэша:

```bash
# выполнить в окружении Conan 1
: > /tmp/legacy-prefs.txt
emit() {
  repo="$1"; shift
  for ref in "$@"; do
    rrev=$($CONAN1 search "$ref" --revisions | grep -oE '#[0-9a-f]{32}' | head -1 | tr -d '#')
    [ -n "$rrev" ] || { echo "no revision: $ref" >&2; return 1; }
    base="$CONAN_USER_HOME/.conan/data/${ref%/*}/${ref#*/}/_/_/package"
    for pkgid in $(find "$base" -mindepth 1 -maxdepth 1 -type d -printf '%f\n'); do
      echo "$repo|$ref|$rrev|$pkgid" >> /tmp/legacy-prefs.txt
    done
  done
}
emit ap-thirdparty ap-headers/1.3.290 ap-headers/1.4.1
emit ap ap-base/1.0.0 ap-utils/1.0.0 ap-gfx/1.0.0 \
  ap-texture/1.0.0 ap-box/1.0.0 ap-sdk/1.0.0
emit conan-local ap-product-a/1.0.0 ap-product-b/1.0.0
```

Перенос должен выполнять Conan 1: Conan 2 не загружает старые Conan 1-рецепты
с `from conans import ConanFile` (`ImportError: cannot import name
'ConanFile' from 'conans'`), причём команда может вернуть exit code `0`.
Настройте audit-remote в Conan 1:

```bash
$CONAN1 remote add -f "$LEGACY_REPO" \
  "$ARTIFACTORY_URL/artifactory/api/conan/$LEGACY_REPO"
$CONAN1 user -p "$ARTIFACTORY_PASSWORD" -r "$LEGACY_REPO" "$ARTIFACTORY_USER"

while IFS='|' read -r repo ref rrev pkgid; do
  $CONAN1 upload "$ref#$rrev:$pkgid" -r "$LEGACY_REPO" --all --confirm
done < /tmp/legacy-prefs.txt
```

Проверка Conan 2 (точный pref скачивается, хотя `conan list` может показать
`No packages found`):

```bash
conan download \
  "ap/1.0.0#94b5374a94ac677865de5094132c484a:3dcaac93f3cf6432dc25ae41cd21792a9760e18b" \
  -r "$LEGACY_REPO"
```

`conan download` точного pref из Conan 1-репозитория в Conan 2-кэш работает;
проверено на `ap/1.0.0#94b5374...:3dcaac93...`. Это только аудит/rollback:
рецепт остаётся Conan 1 (`from conans import ConanFile`), поэтому для сборки
нужен пересобранный Conan 2-рецепт.

Ограничение стенда: `conan list "ref:*" -r <repo>` может показать
`No packages found`, хотя точный `conan download` работает. Не считайте
пустой список доказательством отсутствия пакета; сверяйтесь с manifest.
Кроме того, в Conan 2 `conan list` при HTTP 404 возвращает exit code `0`:
проверяйте JSON (`error`) или текст ответа, а не только код возврата.

## 7. Пересборка под Conan 2

### 7.1. Профиль

Используйте тот же профиль, что и source, включая `compiler.cppstd=17` и
Ninja:

```ini
[settings]
os=Linux
arch=x86_64
compiler=gcc
compiler.version=13
compiler.libcxx=libstdc++11
compiler.cppstd=17
build_type=Release

[conf]
tools.cmake.cmaketoolchain:generator=Ninja
```

Проверка:

```bash
conan profile show -pr=profiles/linux-gcc-release
```

Для cutover используйте отдельный чистый `CONAN_HOME`. Conan сначала
разрешает version range по локальному кэшу: оставшийся после негативного
теста `ap-base/1.9.9` был выбран для `[>=1 <2]` и сломал сборку `ap-utils`.
Удаляйте такие refs (`conan remove 'ap-base/1.9.9' -c`) или начинайте с
нового home.

### 7.2. Сборка и загрузка

```bash
export CONAN_HOME=/tmp/conan2-rebuild
rm -rf "$CONAN_HOME"
conan profile detect --force
conan remote add -f conan2 \
  "$ARTIFACTORY_URL/artifactory/api/conan/conan2"
conan remote login conan2 "$ARTIFACTORY_USER" -p "$ARTIFACTORY_PASSWORD"

# локальные remotes для upload; conan2 — только virtual-агрегатор
export CONAN_USERNAME="$ARTIFACTORY_USER"
export CONAN_PASSWORD="$ARTIFACTORY_PASSWORD"
bash scripts/bootstrap-remotes.sh

conan install --requires=ap-product-b/1.0.0 \
  -r conan2 --build=missing \
  -pr profiles/linux-gcc-release

# ap-product-a не входит в граф ap-product-b
conan install --requires=ap-product-a/1.0.0 \
  -r conan2 --build=missing \
  -pr profiles/linux-gcc-release

# версия, которая не попала в граф ap-product-b
conan install --requires=ap-headers/1.4.1 \
  -r conan2 --build=missing \
  -pr profiles/linux-gcc-release
```

Почему `--build=missing`: Conan 2 вычисляет другие package ID. Без пересборки
consumer получает `Missing binary` даже после переноса старых файлов.

Загрузите новые бинарники:

```bash
conan upload "ap-product-b/1.0.0:*" -r products --confirm
conan upload "ap-product-a/1.0.0:*" -r products --confirm
conan upload "ap-base/1.0.0:*" -r packages --confirm
conan upload "ap-utils/1.0.0:*" -r packages --confirm
conan upload "ap-gfx/1.0.0:*" -r packages --confirm
conan upload "ap-texture/1.0.0:*" -r packages --confirm
conan upload "ap-box/1.0.0:*" -r packages --confirm
conan upload "ap-sdk/1.0.0:*" -r packages --confirm
conan upload "ap-headers/1.3.290:*" -r packages --confirm
conan upload "ap-headers/1.4.1:*" -r packages --confirm
```

Опционально проверьте отдельный recipe-only fixture `../recipe-demo`:

```bash
(
  cd ../recipe-demo
  conan create . --build=missing -pr profiles/linux-gcc-release
)
conan upload "recipe-demo/1.0.0:*" -r packages --confirm
```

Для автоматизированного релиза не повторяйте эти команды вручную, а
используйте staged-порядок из 7.3.

### 7.3. Staged CI: релиз библиотек и продуктов

Для CI не публикуйте рецепт до сборки всех конфигураций и не продвигайте
продукты по одному. В sandbox для этого есть отдельные скрипты:

```bash
cd demo/conan-migration-sandbox

# библиотеки: Release + Debug, затем полная публикация в packages/products
bash scripts/ci-package-release.sh libs/ap-headers 1.3.290
bash scripts/ci-package-release.sh libs/ap-headers 1.4.1
bash scripts/ci-package-release.sh libs/ap-base 1.0.0
bash scripts/ci-package-release.sh libs/ap-utils 1.0.0
bash scripts/ci-package-release.sh libs/ap-gfx 1.0.0
bash scripts/ci-package-release.sh libs/ap-texture 1.0.0
bash scripts/ci-package-release.sh libs/ap-box 1.0.0
bash scripts/ci-package-release.sh libs/ap-sdk 1.0.0

# на чистом target: рецепты продуктов должны быть в products до dry-run,
# иначе version range ap-product-* не разрешится.
# Если рецепты уже там, не переэкспортируйте их без необходимости.
conan export products/ap-product-a
conan export products/ap-product-b
conan upload "ap-product-a/1.0.0" -r products -c --only-recipe
conan upload "ap-product-b/1.0.0" -r products -c --only-recipe

# продукты: единый граф, один build-order, promote всего набора
export CI_RESOLVE_REMOTE=products
bash scripts/ci-products-release.sh --dry-run
bash scripts/ci-products-release.sh
bash scripts/ci-verify-release.sh

# pre-release: только packages, без promote в products
bash scripts/ci-package-release.sh libs/ap-base 2.0.0-beta.1 --no-promote
```

Пустой `products` на старте — нормальная ситуация для чистого cutover:
`ci-products-release.sh` строит граф из `ci/all-products/conanfile.py`, где
продукты заданы version range. Пока их рецептов нет в resolve-remote,
`conan lock create` завершается ошибкой
`Package 'ap-product-a/[>=1.0 <2]' not resolved`. Поэтому сначала
выгружаются только рецепты (`--only-recipe`), а бинарники — уже единым
релизом.

Pre-release (`2.0.0-beta.1`) остаётся в `packages`: `--no-promote` не
продвигает его в `products`. Диапазон `[>=1 <2]` такую версию не выбирает;
для проверки нужен явный ref или lock.

Почему так:

- `ci-package-release.sh` загружает `name/version` только после успешной
  сборки Release и Debug и сверяет package ID в `packages` и `products`;
- `ci-products-release.sh` резолвит `ap-product-a` и `ap-product-b` одним
  lockfile через `ci/all-products/conanfile.py`; рецепты продуктов должны
  уже существовать в resolve-remote;
- при падении любого продукта `develop` не меняется;
- `release-manifest.json` пишется последним и является указателем релиза;
- `ci-verify-release.sh` проверяет, что все refs и бинарники есть в
  `develop`;
- при breaking change major обновляйте диапазоны потребителей
  (`[>=1 <2]` → `[>=2 <3]`) и пересобирайте всю цепочку; старые продукты
  остаются воспроизводимыми через lock + package list.

Ограничение Artifactory CE: штатного `conan art:promote` нет, поэтому
`promote.sh` не транзакционен. Манифест и проверка компенсируют это, но не
делают promote атомарным. Подробные сценарии:
[`05-staged-package-release.md`](demo/conan-migration-sandbox/scenarios/05-staged-package-release.md),
[`06-unified-product-release.md`](demo/conan-migration-sandbox/scenarios/06-unified-product-release.md),
[`08-conan1-to-conan2-cutover.md`](demo/conan-migration-sandbox/scenarios/08-conan1-to-conan2-cutover.md).

## 8. Проверка потребителя

Используйте чистый home с **единственным** remote `conan2`:

```bash
export CONAN_HOME=/tmp/conan2-clean-consumer
rm -rf "$CONAN_HOME"
conan profile detect --force
conan remote add -f conan2 \
  "$ARTIFACTORY_URL/artifactory/api/conan/conan2"
conan remote login conan2 "$ARTIFACTORY_USER" -p "$ARTIFACTORY_PASSWORD"

conan install --requires=ap-product-b/1.0.0 \
  -r conan2 --build=never \
  -pr profiles/linux-gcc-release
```

Ожидаемо: все пакеты графа скачиваются из `conan2`, без source-URL.

Для старого продукта из `develop` добавьте remote в тот же чистый home:

```bash
conan remote add -f develop \
  "$ARTIFACTORY_URL/artifactory/api/conan/develop"
conan remote login develop "$ARTIFACTORY_USER" -p "$ARTIFACTORY_PASSWORD"

conan download \
  --list=lockfiles/ap-product-a/ap-product-a-packagelist.json \
  -r develop

conan install products/ap-product-a \
  -pr:h profiles/linux-gcc-release \
  -pr:b profiles/linux-gcc-release \
  -s build_type=Release \
  --lockfile lockfiles/ap-product-a/ap-product-a.lock \
  --build=never
```

Package list должен быть снят с `:*#*` и содержать `package_rev`; иначе
`conan download` не восстановит точный бинарник. Проверено в чистом home.

Для полной проверки соберите приложение:

```bash
conan install . -r conan2 --build=never -pr profiles/linux-gcc-release
conan build . -pr profiles/linux-gcc-release
```

Пример результата в стенде:

```text
ap_product_b_product_score(5)=68
```

## 9. Jenkins: CI/CD runner

Jenkins только запускает pipeline. Conan-пакеты в Jenkins не публикуются:
единственное хранилище — JFrog Artifactory.

Типовой job:

1. `checkout scm` — исходники из Gitea;
2. credentials `artifactory-password` — пароль Artifactory, не Gitea;
3. `conan remote login` в `conan2` и `bootstrap-remotes.sh` для
   `packages`/`products`/`develop`;
4. `ci-package-release.sh` для библиотек: обе конфигурации до upload;
5. `conan export` + `conan upload --only-recipe` для продуктов, если их
   рецептов ещё нет в `products`;
6. `ci-products-release.sh` для продуктов: единый граф и promote набора;
7. `ci-verify-release.sh` и `release-manifest.json` — в archiveArtifacts;
8. lockfile и package list — тоже артефакты, но источник истины — JFrog.

Минимальный фрагмент Jenkinsfile:

```groovy
stage('Build and publish') {
    steps {
        withCredentials([string(credentialsId: 'artifactory-password',
                                 variable: 'ARTIFACTORY_PASSWORD')]) {
            sh """
                export CONAN_HOME="\$WORKSPACE/.conan2"
                rm -rf "\$CONAN_HOME"
                conan profile detect --force
                conan remote add -f conan2 \
                  "\$ARTIFACTORY_URL/artifactory/api/conan/conan2" || true
                conan remote login conan2 "\$ARTIFACTORY_USER" \
                  -p "\$ARTIFACTORY_PASSWORD"

                # локальные remotes для upload
                export CONAN_USERNAME="\$ARTIFACTORY_USER"
                export CONAN_PASSWORD="\$ARTIFACTORY_PASSWORD"
                bash scripts/bootstrap-remotes.sh

                # библиотеки: полный пакет, затем staging в products
                bash scripts/ci-package-release.sh libs/ap-base 1.0.0

                # на чистом target: рецепты продуктов до единого графа
                conan export products/ap-product-a
                conan export products/ap-product-b
                conan upload "ap-product-a/1.0.0" -r products -c --only-recipe
                conan upload "ap-product-b/1.0.0" -r products -c --only-recipe

                # продукты: единый граф, build-order, promote всего набора
                CI_RESOLVE_REMOTE=products \
                  bash scripts/ci-products-release.sh
                bash scripts/ci-verify-release.sh
            """
        }
    }
}
```

Фрагмент предполагает чистый target: если рецепты продуктов уже есть в
`products`, шаг `conan export`/`--only-recipe` можно убрать.

В реальном job выполните `ci-package-release.sh` для всех библиотек в порядке
зависимостей до продуктового шага. Не публикуйте продукт отдельным
`conan upload`, пока не собран весь набор.

Не добавляйте в Jenkins шаг `conan upload` в Gitea и не передавайте
Gitea-токен в Artifactory: это разные системы и разные credentials.

## 10. Cutover и rollback

Перед cutover:

1. включите freeze в source;
2. переключите CI и разработчиков на `conan2`;
3. проверьте сборку продукта в чистом home;
4. сохраните inventory target и список package revisions;
5. оставьте source доступным на окно rollback.

Rollback:

- верните remote URL на source `conan` (или `conan-local`/`ap`);
- не удаляйте target `packages`/`products`/`develop` до завершения проверки;
- не удаляйте Gitea и Jenkins: они не участвуют в миграции хранилища;
- при необходимости восстановите Artifactory из backup БД и filestore.

Для репетиции baseline не запускайте его поверх уже заполненного target:
диапазоны `[>=1 <2]` могут выбрать более поздний несовместимый 1.x. Используйте
отдельные target-репозитории (`packages-08`, `products-08`, `develop-08`) или
фиксированный lock, а production target не трогайте до проверки.

Старый продукт восстанавливается не по `latest`, а по lockfile + package list
из `develop` с `--build=never` (раздел 8).

## 11. Чек-лист

- [ ] Есть backup Artifactory (БД + filestore).
- [ ] Source заморожен; новые публикации остановлены.
- [ ] Conan 1 home изолирован; `CONAN_REVISIONS_ENABLED=1`.
- [ ] Инвентарь source содержит recipe revisions и package ID; package
      revisions сохранены, если нужен точный rollback.
- [ ] Source-пакеты сохранены точными pref в `legacy`, если нужен аудит.
- [ ] Target `packages`/`products`/`develop` созданы.
- [ ] Virtual `conan2` агрегирует target.
- [ ] Для cutover используется чистый `CONAN_HOME`; failed/negative refs
      удалены из кэша.
- [ ] Выполнена пересборка Conan 2 с `--build=missing`.
- [ ] Библиотеки опубликованы через `ci-package-release.sh` (Release + Debug).
- [ ] На чистом target рецепты продуктов выгружены в `products` до
      `ci-products-release.sh`.
- [ ] Продукты собраны единым графом и продвинуты через `ci-products-release.sh`.
- [ ] Pre-release опубликован только в `packages` (`--no-promote`), не в
      `products`.
- [ ] `release-manifest.json` создан последним и проверен `ci-verify-release.sh`.
- [ ] Новые бинарники загружены в target.
- [ ] Чистый consumer скачал всё через `conan2`, без source.
- [ ] Старый продукт установлен из lockfile + package list с `--build=never`.
- [ ] Отсутствие пакета проверено по JSON, а не по exit code `conan list`.
- [ ] Временные target-репозитории удалены через PATCH; каноническая
      топология восстановлена.
- [ ] Rollback проверен; source не удалён.
- [ ] Документация и inventory обновлены.

## 12. Известные ограничения

1. Package ID Conan 1 и Conan 2 не совпадают; пересборка обязательна.
2. В Conan 1.66 `conan search "*" --revisions` завершается ошибкой
   `With --revision, specify a reference`. Ревизии снимайте только по
   конкретному ref; package revision в выводе `search` не показывается.
3. `conan list` по source Conan 1 может не показывать бинарники; используйте
   точный pref/manifest. При HTTP 404 `conan list` в Conan 2 возвращает
   exit code `0` — проверяйте JSON. `conan upload` Conan 1-рецепта в Conan 2
   падает с `ImportError: cannot import name 'ConanFile' from 'conans'`,
   но тоже может вернуть `0`; проверяйте вывод.
4. `conan-remote-cache` — узел кэша remote в UI, а не API-репозиторий; в
   `/api/repositories` его нет.
5. `artifactory-build-info` — зарезервированное имя; PATCH возвращает 400,
   создать его как обычный репозиторий нельзя.
6. Artifactory CE не удаляет репозитории через `DELETE
   /api/repositories/<key>` (400, Pro-only); используйте PATCH с `null`.
7. `ap-thirdparty` может остаться пустым, если нет подтверждённой карты
   пакетов; на стенде он заполнен placeholder `ap-thirdparty/1.0.0`.
8. Локальный кэш участвует в разрешении version range: failed ref
   (`ap-base/1.9.9`) может быть выбран для `[>=1 <2]` и сломать сборку.
9. Baseline поверх заполненного target может разрешить более поздний
   несовместимый 1.x; для репетиции нужны отдельные target-репозитории или
   фиксированный lock.
10. Legacy pref в `legacy` — только аудит/rollback; не смешивайте его с
    `packages`/`products`, иначе Conan 2 может выбрать старый рецепт.
11. Virtual-репозиторий `conan2` обязателен для межрепозиторных зависимостей.
