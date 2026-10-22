# Инструкция: миграция Conan 1.x → Conan 2.x

Документ описывает миграцию Conan-хранилища в JFrog Artifactory CE.
Проверено на Artifactory CE `7.161.26`, Conan 1.66.0 и Conan 2.33.0,
Linux/GCC 13.

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

- **source** — Conan 1-репозитории `conan-local`, `ap-source`,
  `conan-thirdparty`, `ap-thirdparty`, объединённые virtual `conan`;
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
for r in conan-local ap-source conan-thirdparty ap-thirdparty conan; do
  $CONAN1 remote add "$r" \
    "$ARTIFACTORY_URL/artifactory/api/conan/$r"
  $CONAN1 user -p "$ARTIFACTORY_PASSWORD" -r "$r" "$ARTIFACTORY_USER"
done
```

Снимите inventory:

```bash
for r in conan-local ap-source conan-thirdparty ap-thirdparty conan; do
  echo "== $r"
  $CONAN1 search "*" --revisions -r "$r"
done > /tmp/conan1-inventory.txt
```

Если нужен полный список всех версий и ревизий, используйте JSON:

```bash
$CONAN1 search "*" --revisions --json /tmp/conan1-all.json
```

Важно: `conan search` без `--revisions` не даёт полной картины; для миграции
нужны именно recipe revisions и package ID.

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
recipe-demo
```

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
$CONAN1 search "*" --revisions
```

## 4. Загрузка source-пакетов

Загружайте точный pref, а не только `name/version`:

```bash
upload_pref() {
  repo="$1"
  ref="$2"
  line=$($CONAN1 search "$ref" --revisions | grep "^$ref#" | head -1)
  rrev=${line#*#}
  base="$CONAN_USER_HOME/.conan/data/${ref%/*}/${ref#*/}/_/_/package"

  for pkgid in $(find "$base" -mindepth 1 -maxdepth 1 -type d -printf '%f\n'); do
    echo "$ref#$rrev:$pkgid -> $repo"
    $CONAN1 upload "$ref#$rrev:$pkgid" \
      -r "$repo" --all --confirm
  done
}

upload_pref conan-thirdparty ap-headers/1.3.290
upload_pref conan-thirdparty ap-headers/1.4.1
upload_pref ap-source ap-base/1.0.0
upload_pref ap-source ap-utils/1.0.0
upload_pref ap-source ap-gfx/1.0.0
upload_pref ap-source ap-texture/1.0.0
upload_pref ap-source ap-box/1.0.0
upload_pref ap-source ap-sdk/1.0.0
upload_pref conan-local ap-product-a/1.0.0
upload_pref conan-local ap-product-b/1.0.0
upload_pref conan-local recipe-demo/1.0.0
```

Проверка:

```bash
$CONAN1 search "*" -r ap-source
$CONAN1 search "*" -r conan-thirdparty
$CONAN1 search "*" -r conan-local
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

`conan-remote-cache` вручную не создавайте: Artifactory CE отклоняет
remote с суффиксом `-cache`. Кэш обслуживается Artifactory автоматически.

## 6. Перенос точных pref в target

Этот шаг переносит исходные бинарники и рецепты. Он нужен для аудита и
rollback, но **не заменяет пересборку** под Conan 2: package ID Conan 2
отличается.

```bash
export CONAN_HOME=/tmp/conan2-home
rm -rf "$CONAN_HOME"
conan profile detect --force

for r in conan conan-local ap-source conan-thirdparty packages products; do
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
    line=$($CONAN1 search "$ref" --revisions | grep "^$ref#" | head -1)
    rrev=${line#*#}
    base="$CONAN_USER_HOME/.conan/data/${ref%/*}/${ref#*/}/_/_/package"
    for pkgid in $(find "$base" -mindepth 1 -maxdepth 1 -type d -printf '%f\n'); do
      echo "$repo|$ref|$rrev|$pkgid" >> /tmp/legacy-prefs.txt
    done
  done
}
emit conan-thirdparty ap-headers/1.3.290 ap-headers/1.4.1
emit ap-source ap-base/1.0.0 ap-utils/1.0.0 ap-gfx/1.0.0 \
  ap-texture/1.0.0 ap-box/1.0.0 ap-sdk/1.0.0
emit conan-local ap-product-a/1.0.0 ap-product-b/1.0.0 recipe-demo/1.0.0
```

Перенос:

```bash
export CONAN_HOME=/tmp/conan2-home

while IFS='|' read -r repo ref rrev pkgid; do
  case "$ref" in
    ap-product-a/1.0.0|ap-product-b/1.0.0) target=products ;;
    *) target=packages ;;
  esac

  conan download "$ref#$rrev:$pkgid" -r "$repo"
  conan upload "$ref#$rrev:$pkgid" -r "$target" --confirm
done < /tmp/legacy-prefs.txt
```

Ограничение стенда: `conan list "ref:*" -r <source>` может показать
`No packages found`, хотя точный `conan download` работает. Не считайте
пустой список доказательством отсутствия пакета; сверяйтесь с manifest.

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

### 7.2. Сборка и загрузка

```bash
export CONAN_HOME=/tmp/conan2-home
conan remote add -f conan2 \
  "$ARTIFACTORY_URL/artifactory/api/conan/conan2"
conan remote login conan2 "$ARTIFACTORY_USER" -p "$ARTIFACTORY_PASSWORD"

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

# самостоятельный recipe-репозиторий
cd /workspace/recipe-demo-git
conan create . --build=missing -pr profiles/linux-gcc-release
```

Почему `--build=missing`: Conan 2 вычисляет другие package ID. Без пересборки
consumer получает `Missing binary` даже после переноса старых файлов. Если
`recipe-demo` — отдельный репозиторий, путь `/workspace/recipe-demo-git`
замените на свой.

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

# продукты: единый граф, один build-order, promote всего набора
export CI_RESOLVE_REMOTE=products
bash scripts/ci-products-release.sh --dry-run
bash scripts/ci-products-release.sh
bash scripts/ci-verify-release.sh
```

Почему так:

- `ci-package-release.sh` загружает `name/version` только после успешной
  сборки Release и Debug и сверяет package ID в `packages` и `products`;
- `ci-products-release.sh` резолвит `ap-product-a` и `ap-product-b` одним
  lockfile через `ci/all-products/conanfile.py`;
- при падении любого продукта `develop` не меняется;
- `release-manifest.json` пишется последним и является указателем релиза;
- `ci-verify-release.sh` проверяет, что все refs и бинарники есть в
  `develop`.

Ограничение Artifactory CE: штатного `conan art:promote` нет, поэтому
`promote.sh` не транзакционен. Манифест и проверка компенсируют это, но не
делают promote атомарным. Подробные сценарии:
[`05-staged-package-release.md`](demo/conan-migration-sandbox/scenarios/05-staged-package-release.md),
[`06-unified-product-release.md`](demo/conan-migration-sandbox/scenarios/06-unified-product-release.md).

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
3. `conan remote login` в `conan2`;
4. `ci-package-release.sh` для библиотек: обе конфигурации до upload;
5. `ci-products-release.sh` для продуктов: единый граф и promote набора;
6. `ci-verify-release.sh` и `release-manifest.json` — в archiveArtifacts;
7. lockfile и package list — тоже артефакты, но источник истины — JFrog.

Минимальный фрагмент Jenkinsfile:

```groovy
stage('Build and publish') {
    steps {
        withCredentials([string(credentialsId: 'artifactory-password',
                                 variable: 'ARTIFACTORY_PASSWORD')]) {
            sh """
                export CONAN_HOME="\$WORKSPACE/.conan2"
                conan remote add -f conan2 \
                  "\$ARTIFACTORY_URL/artifactory/api/conan/conan2" || true
                conan remote login conan2 "\$ARTIFACTORY_USER" \
                  -p "\$ARTIFACTORY_PASSWORD"

                # библиотеки: полный пакет, затем staging в products
                bash scripts/ci-package-release.sh libs/ap-base 1.0.0

                # продукты: единый граф, build-order, promote всего набора
                CI_RESOLVE_REMOTE=products \
                  bash scripts/ci-products-release.sh
                bash scripts/ci-verify-release.sh
            """
        }
    }
}
```

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

- верните remote URL на source `conan` (или `conan-local`/`ap-source`);
- не удаляйте target `packages`/`products`/`develop` до завершения проверки;
- не удаляйте Gitea и Jenkins: они не участвуют в миграции хранилища;
- при необходимости восстановите Artifactory из backup БД и filestore.

## 11. Чек-лист

- [ ] Есть backup Artifactory (БД + filestore).
- [ ] Source заморожен; новые публикации остановлены.
- [ ] Conan 1 home изолирован; `CONAN_REVISIONS_ENABLED=1`.
- [ ] Инвентарь source содержит recipe revisions и package ID.
- [ ] Source-пакеты загружены точными pref.
- [ ] Target `packages`/`products`/`develop` созданы.
- [ ] Virtual `conan2` агрегирует target.
- [ ] Выполнена пересборка Conan 2 с `--build=missing`.
- [ ] Библиотеки опубликованы через `ci-package-release.sh` (Release + Debug).
- [ ] Продукты собраны единым графом и продвинуты через `ci-products-release.sh`.
- [ ] `release-manifest.json` создан последним и проверен `ci-verify-release.sh`.
- [ ] Новые бинарники загружены в target.
- [ ] Чистый consumer скачал всё через `conan2`, без source.
- [ ] Rollback проверен; source не удалён.
- [ ] Документация и inventory обновлены.

## 12. Известные ограничения

1. Package ID Conan 1 и Conan 2 не совпадают; пересборка обязательна.
2. `conan list` по source Conan 1 может не показывать бинарники; используйте
   точный pref/manifest.
3. `conan-remote-cache` не создаётся как отдельный remote с суффиксом
   `-cache`.
4. `artifactory-build-info` — служебный репозиторий, не Conan.
5. `ap-thirdparty` может остаться пустым, если нет подтверждённой карты
   пакетов.
6. Virtual-репозиторий `conan2` обязателен для межрепозиторных зависимостей.
