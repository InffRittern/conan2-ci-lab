# 06 — единый граф продуктов и promote всего набора

Цель: собирать и продвигать `ap-product-a` и `ap-product-b` как один набор,
а не по отдельности. Если один продукт не собирается, `develop` не меняется.

## Проблема, которую закрывает сценарий

Старый `products-pipeline.sh` запускается на один продукт. Два независимых
job могут дать такой порядок:

```text
product-a собран -> promote в develop
product-b упал   -> develop уже содержит несовместимый набор
```

Кроме того, каждый продукт резолвит свой граф. Конфликт версий или опций между
продуктами обнаруживается только у потребителя.

## Решение

В `ci/all-products/conanfile.py` лежит graph-only корень:

```python
self.requires("ap-product-a/[>=1.0 <2]")
self.requires("ap-product-b/[>=1.0 <2]")
```

Один `conan lock create` и один merged build-order покрывают оба продукта и
все общие зависимости. Публикация начинается только после того, как собраны
все refs из build-order.

## Предусловия

В `products` уже должны быть библиотеки. Их публикует
`ci-package-release.sh` (сценарий 05). Если `products` пуст, для проверки
графа можно временно резолвить из virtual `conan2`:

```bash
export CI_RESOLVE_REMOTE=conan2
```

Но канонический CI резолвит из `products`:

```bash
cd demo/conan-migration-sandbox
export CONAN_USERNAME=admin
export CONAN_PASSWORD='<artifactory-пароль>'
export PACKAGES_REMOTE=packages
export PRODUCTS_REMOTE=products
export DEVELOP_REMOTE=develop
export CI_RESOLVE_REMOTE=products
```

## 1. Проверка графа без сборки

```bash
bash scripts/ci-products-release.sh --dry-run
```

Ожидаемый build-order (порядок уровней):

```text
ap-base/2.0.0
ap-headers/1.3.290
ap-texture/1.0.0
ap-utils/1.0.0
ap-box/1.0.0
ap-gfx/1.0.0
ap-sdk/1.0.0
ap-product-a/1.0.0
ap-product-b/1.0.0
```

`ap-base/2.0.0` выбран потому, что текущие диапазоны demo — `[>=2 <3]`
(состояние после сценария 03). На чистом baseline будет `1.0.0`.

`--dry-run` создаёт lockfile и build-order, но не собирает и не публикует
пакеты. `--no-promote` собирает и публикует в `products`, но не трогает
`develop`; манифест в этом режиме проверяется по `products`.

## 2. Полный релиз

```bash
bash scripts/ci-products-release.sh
```

Порядок:

1. `conan lock create` единого графа для Release;
2. расширение того же lockfile конфигурацией Debug;
3. `conan graph build-order` для Release и Debug;
4. `conan graph build-order-merge` **без** `--reduce`;
5. сборка каждого ref в Release и Debug с общим lockfile;
6. только после всех сборок — `conan upload` каждого ref в `products`;
7. `promote.sh` каждого ref из `products` в `develop`;
8. сохранение lockfile и package list продуктов;
9. запись `lockfiles/ci/release-manifest.json` последним;
10. `ci-verify-release.sh` проверяет каждый ref в `develop`.

### Почему без `--reduce`

На стенде проверено: `build-order-merge --reduce` на уже заполненном кэше
может вернуть **пустой** `order`, хотя граф содержит все refs. Поэтому
скрипт мержит без `--reduce` и сам дедуплицирует refs.

## 3. Проверка результата

```bash
conan list 'ap-product-a/1.0.0:*#*' -r develop
conan list 'ap-product-b/1.0.0:*#*' -r develop

test -s lockfiles/ci/all-products.lock
test -s lockfiles/ci/release-manifest.json
test -s lockfiles/ap-product-a/ap-product-a.lock
test -s lockfiles/ap-product-b/ap-product-b.lock

bash scripts/ci-verify-release.sh
```

Манифест содержит:

```json
{
  "lockfile": "lockfiles/ci/all-products.lock",
  "verify_remote": "develop",
  "promoted_to_develop": true,
  "refs": [
    "ap-base/2.0.0",
    "ap-headers/1.3.290",
    "ap-texture/1.0.0",
    "ap-utils/1.0.0",
    "ap-box/1.0.0",
    "ap-gfx/1.0.0",
    "ap-sdk/1.0.0",
    "ap-product-a/1.0.0",
    "ap-product-b/1.0.0"
  ],
  "products": [
    "ap-product-a/1.0.0",
    "ap-product-b/1.0.0"
  ]
}
```

`generated_at` и имена remote добавляются скриптом.

## 4. Проверка отрицательного сценария

Ломаем `ap-utils` в отдельной копии и убеждаемся, что `develop` не меняется:

```bash
rm -rf /tmp/ci-fail
cp -a . /tmp/ci-fail
rm -rf /tmp/ci-fail/build /tmp/ci-fail/lockfiles/ci
printf '\n#error forced failure\n' >> /tmp/ci-fail/libs/ap-utils/src/ap-utils.cpp

cd /tmp/ci-fail
bash scripts/ci-products-release.sh
# ожидаем ненулевой код возврата

test ! -f lockfiles/ci/release-manifest.json
conan list 'ap-product-a/*' -r develop
```

Проверено на стенде: сборка падает на `ap-utils`, манифест не создаётся,
`develop` остаётся с прежним `ap-product-a/1.0.0`. Ни один ref не был
загружен, потому что upload начинается после цикла сборки.

## 5. Границы атомарности

Artifactory CE не предоставляет штатного promote. Поэтому `promote.sh` делает
`list → download → upload` по одному ref. Если процесс оборвётся в середине
цикла promote, часть refs уже будет в `develop`.

Компенсация:

- `release-manifest.json` пишется последним и является указателем релиза;
- `ci-verify-release.sh` проверяет наличие всех refs и бинарников;
- lockfile + package list фиксируют точные package revisions;
- при обрыве повторный запуск идемпотентен: `conan upload -c` и promote
  перезаливают недостающее.

Это не транзакция. Для настоящей атомарности нужен Artifactory Pro с
`conan art:promote` или отдельный immutable release-репозиторий.

## Ожидаемый результат

- Единый lockfile содержит оба продукта и все общие зависимости.
- Build-order содержит оба продукта; `ap-base` один, а не две версии.
- При успехе все refs есть в `develop`, манифест записан последним.
- При падении любого продукта или библиотеки `develop` не меняется.
- `ci-verify-release.sh` возвращает 0 только для полного набора.

## Если не зелёно

- `Version range ... could not be resolved` — в `products` нет библиотек;
  сначала выполните `ci-package-release.sh` или временно задайте
  `CI_RESOLVE_REMOTE=conan2`.
- Build-order пуст — проверьте, что не добавлен `--reduce`; см. выше.
- `ci-verify-release.sh` падает на конкретном ref — посмотрите
  `conan list '<ref>:*#*' -r develop`; скорее всего promote оборвался.
- Продукт собрался, но `develop` старый — проверьте `PROMOTE_TO_DEVELOP`
  и наличие `release-manifest.json`.
