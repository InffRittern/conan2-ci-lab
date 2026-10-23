# 08 — миграция CI с Conan 1.x на Conan 2.x

Цель: провести cutover пайплайнов `jenkins-libraries` / `dependency-builder`
с Conan 1 на Conan 2, не теряя старые продукты и возможность rollback.

Сценарий описывает порядок для реального стенда. В sandbox контейнер `conan`
содержит только Conan 2.33.0; inventory Conan 1 выполняется на хосте
(`conan.exe` 1.66) или в отдельном venv. Не смешивайте `CONAN_HOME` и
`CONAN_USER_HOME` этих версий.

## Фаза 0. Freeze и backup

1. Остановите публикацию новых версий в source (`conan-local`, `ap-source`,
   `conan-thirdparty`).
2. Снимите backup Artifactory: PostgreSQL + filestore.
3. Зафиксируйте окно rollback и ответственного.
4. Не удаляйте source-репозитории до завершения проверки.

## Фаза 1. Inventory Conan 1

Выполнять в окружении Conan 1:

```bash
export CONAN_USER_HOME=/tmp/conan1-home
export CONAN_REVISIONS_ENABLED=1
CONAN1=/path/to/conan1/bin/conan
export ARTIFACTORY_URL=http://localhost:8082
export ARTIFACTORY_USER=admin
export ARTIFACTORY_PASSWORD='<пароль>'

$CONAN1 --version

for r in conan-local ap-source conan-thirdparty ap-thirdparty conan; do
  $CONAN1 remote add "$r" \
    "$ARTIFACTORY_URL/artifactory/api/conan/$r"
  $CONAN1 user -p "$ARTIFACTORY_PASSWORD" -r "$r" "$ARTIFACTORY_USER"
done

for r in conan-local ap-source conan-thirdparty ap-thirdparty conan; do
  echo "== $r"
  $CONAN1 search "*" -r "$r"
done > /tmp/conan1-inventory.txt
```

В Conan 1.66 `search "*" --revisions` завершается ошибкой: `--revisions`
требует конкретный ref. Поэтому revisions и package ID снимайте отдельно для
каждого ref из списка:

```bash
$CONAN1 search 'ap-thirdparty/1.0.0@' --revisions -r conan-thirdparty
$CONAN1 search 'zlib/1.3.1@' --revisions -r conan
```

Нужен именно `--revisions`: без него нет recipe revision и нельзя сопоставить
старые бинарники с новыми.

Дополнительно снимите JSON для машинной сверки (без `--revisions`, затем
уточняйте revisions по каждому ref):

```bash
$CONAN1 search "*" --json /tmp/conan1-all.json -r conan
```

Полный manifest `repo|ref|rrev|pkgid` и перенос точных pref описаны в
[`../conan1-conan2-migration-runbook.md`](../conan1-conan2-migration-runbook.md),
разделы 2 и 6. Он нужен для аудита и rollback, но **не заменяет пересборку**:
package ID Conan 2 другой.

## Фаза 2. Target-репозитории

Создайте LOCAL `packages`, `products`, `develop` и virtual `conan2`, который
агрегирует их:

```yaml
localRepositories:
  packages:
    type: conan
  products:
    type: conan
  develop:
    type: conan

virtualRepositories:
  conan2:
    type: conan
    repositories:
      - packages
      - products
      - develop
```

Причина: Conan 2 разрешает зависимости в рамках remote, через который найден
корневой рецепт. Без `conan2` продукт из `products` не увидит библиотеки из
`packages`.

Проверка:

```bash
curl -u "$ARTIFACTORY_USER:$ARTIFACTORY_PASSWORD" \
  "$ARTIFACTORY_URL/artifactory/api/repositories"
```

## Фаза 3. Пересборка библиотек в Conan 2

Cutover выполняется из чистого baseline, а не из рабочего дерева, где уже
применены сценарии 02/03. Иначе `ap-base` будет с трёхаргументным API, а
диапазоны будут `[>=2 <3]`.

```bash
git worktree remove --force /tmp/conan2-cutover 2>/dev/null || true
rm -rf /tmp/conan2-cutover
git worktree add --detach /tmp/conan2-cutover 5ce4447
cp -a demo/conan-migration-sandbox/scripts \
  /tmp/conan2-cutover/demo/conan-migration-sandbox/
cp -a demo/conan-migration-sandbox/ci \
  /tmp/conan2-cutover/demo/conan-migration-sandbox/
cd /tmp/conan2-cutover/demo/conan-migration-sandbox

# Отдельный кэш: локальные рецепты участвуют в разрешении диапазонов и могут
# затенять remote (например, неудачный ap-base/1.9.9 из другого эксперимента).
export CONAN_HOME=/tmp/conan2-cutover-home
rm -rf "$CONAN_HOME"
conan profile detect --force

export CONAN_USERNAME=admin
export CONAN_PASSWORD='<artifactory-пароль>'
export PACKAGES_REMOTE=packages
export PRODUCTS_REMOTE=products
export DEVELOP_REMOTE=develop
bash scripts/bootstrap-remotes.sh

# Target-репозитории должны быть пустыми: cutover пересобирает baseline.
for r in packages products develop; do
  conan remove "*" -r "$r" -c
done
```

Собирайте в порядке зависимостей. Каждый вызов публикует полный пакет
(Release + Debug) и продвигает его в `products`:

```bash
bash scripts/ci-package-release.sh libs/ap-headers 1.3.290
bash scripts/ci-package-release.sh libs/ap-headers 1.4.1
bash scripts/ci-package-release.sh libs/ap-base 1.0.0
bash scripts/ci-package-release.sh libs/ap-utils 1.0.0
bash scripts/ci-package-release.sh libs/ap-gfx 1.0.0
bash scripts/ci-package-release.sh libs/ap-texture 1.0.0
bash scripts/ci-package-release.sh libs/ap-box 1.0.0
bash scripts/ci-package-release.sh libs/ap-sdk 1.0.0
```

Проверка после каждого шага:

```bash
conan list 'ap-base/1.0.0:*#*' -r packages
conan list 'ap-base/1.0.0:*#*' -r products
```

Ожидается два package ID (Release/Debug) в обоих remote. Если `products`
пуст, не запускайте продуктовый пайплайн: сначала устраните неполную
публикацию.

## Фаза 4. Пересборка продуктов одним графом

```bash
export CI_RESOLVE_REMOTE=products
bash scripts/ci-products-release.sh --dry-run
bash scripts/ci-products-release.sh
bash scripts/ci-verify-release.sh
```

Пайплайн:

1. резолвит `ap-product-a` и `ap-product-b` одним lockfile;
2. строит merged build-order для Release и Debug;
3. собирает все refs;
4. загружает их в `products`;
5. продвигает весь набор в `develop`;
6. пишет `lockfiles/ci/release-manifest.json` последним;
7. проверяет каждый ref в `develop`.

Если сборка любого продукта падает, `develop` не меняется. Это заменяет
пошаговый promote, при котором первый продукт уже оказывался в `develop`,
а второй падал.

После unified release у `ap-texture/1.0.0` в `products` и `develop` остаётся
четыре package ID: два собраны пакетным пайплайном против
`ap-headers/1.4.1`, два — в unified graph, где `ap-box` принудительно пинит
`ap-headers/1.3.290`. Это разные зависимости, а не дубликаты; `packages`
по-прежнему содержит ровно две конфигурации.

## Фаза 5. Проверка потребителя

Чистый `CONAN_HOME` с remote `conan2`:

```bash
export CONAN_HOME=/tmp/conan2-clean-consumer
rm -rf "$CONAN_HOME"
conan profile detect --force
conan remote add -f conan2 \
  "$ARTIFACTORY_URL/artifactory/api/conan/conan2"
conan remote login conan2 "$ARTIFACTORY_USER" \
  -p "$ARTIFACTORY_PASSWORD"

conan install --requires=ap-product-b/1.0.0 \
  -r conan2 --build=never \
  -pr profiles/linux-gcc-release
```

Ожидается: все пакеты графа скачаны из `conan2`, source-URL не используется.

Для старого продукта из `develop` добавьте этот remote в чистый home (пакет
list содержит ключ `develop`):

```bash
conan remote add -f develop \
  "$ARTIFACTORY_URL/artifactory/api/conan/develop"
conan remote login develop "$ARTIFACTORY_USER" \
  -p "$ARTIFACTORY_PASSWORD"

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

Проверено на стенде: такой `install` завершается успешно в чистом home,
если package list снят с `:*#*` и содержит `package_rev`.

## Фаза 6. Cutover и rollback

Cutover:

1. переключите Jenkins credentials и remote URL на `conan2`;
2. переведите разработчиков на Conan 2 и новый `CONAN_HOME`;
3. прогоните `ci-products-release.sh` на тестовой ветке;
4. сохраните `release-manifest.json`, lockfile и package lists как артефакты;
5. оставьте source-репозитории доступными на окно rollback.

Rollback:

- верните remote URL на source `conan` / `conan-local` / `ap-source`;
- не удаляйте target `packages`/`products`/`develop` до завершения проверки;
- не удаляйте Gitea и Jenkins: они не участвуют в миграции хранилища;
- восстановление Artifactory — из backup БД и filestore;
- помните, что `promote.sh` не откатывает `develop` автоматически; для
  старого продукта используйте его lockfile/package list, а не `latest`.

## Сопоставление проблем и мер контроля

| Проблема старого CI | Мера в новом CI |
|---|---|
| Новая версия библиотеки ломает зависимые | `ci-package-release.sh`: сборка обеих конфигураций до публикации; `products` как staging |
| Рецепт опубликован раньше бинарников | upload после обеих сборок + сверка package ID в `packages` и `products` |
| Зависимые не собираются, пока не готовы все конфигурации | build-order и запуск после полного набора; package list с `package_rev` |
| Новая версия ломает графы продуктов | единый `ci/all-products` graph + `--dry-run` до сборки |
| Пакеты собираются без учёта графов продуктов | `ci-products-release.sh` собирает весь build-order, а не отдельный пакет |
| Старые продукты невоспроизводимы | lockfile + package list + `release-manifest.json`; `--build=never` |
| Мажорные/pre-release просачиваются | диапазоны `[>=1 <2]`; pre-release только явно и в `packages` |
| Promote не атомарен | манифест последним + `ci-verify-release.sh`; Artifactory CE не даёт штатного promote |

## Ограничения стенда

- В контейнере `conan` нет Conan 1; inventory и старые pref снимаются на
  хосте или в отдельном venv.
- Source-репозитории сохранены, но новые сборки идут только в target.
- Artifactory CE не поддерживает `conan art:promote`; `promote.sh` не
  транзакционен.
- Для истинной атомарности нужен Artifactory Pro или immutable
  release-репозиторий с переключением указателя.

## Ожидаемый результат

- Inventory Conan 1 содержит recipe revisions и package ID.
- В `packages`/`products` лежат пересобранные Conan 2 бинарники.
- `develop` содержит оба продукта, собранные одним графом.
- Чистый потребитель ставит продукт через `conan2` без сборки.
- Старый продукт ставится из lockfile + package list.
- Source не удалён; rollback возможен.
