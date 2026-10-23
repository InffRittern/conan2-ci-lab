# 01 — базовая сборка

Цель: собрать все библиотеки, залить их в `packages`, собрать оба продукта с
lockfile и получить в `develop` `ap-product-a/1.0.0` и `ap-product-b/1.0.0`.

> Сценарии 01–03 выполняются от baseline-коммита `5ce4447`: там
> `ap_base_add(int, int)` и диапазоны `[>=1 <2]`. В текущем `HEAD` уже
> применён результат сценария 03 (три аргумента и диапазоны `[>=2 <3]`),
> поэтому для повторного прогона создайте отдельный worktree:
>
> ```bash
> git worktree add --detach /tmp/conan2-baseline 5ce4447
> cd /tmp/conan2-baseline
> ```
>
> Скрипты и документацию из текущего `HEAD` можно скопировать поверх
> baseline worktree; source-файлы `libs/`, `products/` и `ci/` должны
> остаться из `5ce4447`.

## Подготовка

```bash
cd demo/conan-migration-sandbox
export CONAN_USERNAME=admin
export CONAN_PASSWORD="${CONAN_PASSWORD:?нужен пароль или токен JFrog Artifactory}"
export PACKAGES_REMOTE=packages
export PRODUCTS_REMOTE=products
export DEVELOP_REMOTE=develop

bash scripts/bootstrap-remotes.sh
```

## 1. Базовые библиотеки

Собираем `ap-base/1.0.0`. Версии `1.1.0` и `2.0.0` появятся в сценариях 02 и 03.

```bash
bash scripts/packages-pipeline.sh libs/ap-base 1.0.0
```

`ap-headers`: нужны и версия из пина `ap-box`, и версия для диапазона
`ap-texture`.

```bash
bash scripts/packages-pipeline.sh libs/ap-headers 1.3.290
bash scripts/packages-pipeline.sh libs/ap-headers 1.4.1
```

Далее строго в порядке зависимостей:

```bash
bash scripts/packages-pipeline.sh libs/ap-utils 1.0.0
bash scripts/packages-pipeline.sh libs/ap-gfx 1.0.0
bash scripts/packages-pipeline.sh libs/ap-texture 1.0.0
bash scripts/packages-pipeline.sh libs/ap-box 1.0.0
bash scripts/packages-pipeline.sh libs/ap-sdk 1.0.0
```

Проверка, что все рецепты и обе конфигурации лежат в `packages`:

```bash
conan list 'ap-base/1.0.0:*' -r=packages
conan list 'ap-utils/1.0.0:*' -r=packages
conan list 'ap-gfx/1.0.0:*' -r=packages
conan list 'ap-headers/1.3.290:*' -r=packages
conan list 'ap-headers/1.4.1:*' -r=packages
conan list 'ap-texture/1.0.0:*' -r=packages
conan list 'ap-box/1.0.0:*' -r=packages
conan list 'ap-sdk/1.0.0:*' -r=packages
```

Ожидается по две бинарные строки на пакет (Release и Debug).

## 2. Продукты

```bash
bash scripts/products-pipeline.sh products/ap-product-a
bash scripts/products-pipeline.sh products/ap-product-b
```

Что делает пайплайн:

1. создаёт единый `lockfiles/<product>/<product>.lock`;
2. считает build-order для Release и Debug и мержит его;
3. собирает локальные пакеты в порядке build-order для обеих конфигураций;
4. заливает их в `products`;
5. при успехе делает `list → download → upload` продукта в `develop`;
6. сохраняет `lockfiles/<product>/<product>-packagelist.json`.

## 3. Проверка

```bash
conan list 'ap-product-a/1.0.0:*' -r=develop
conan list 'ap-product-b/1.0.0:*' -r=develop

test -s lockfiles/ap-product-a/ap-product-a.lock
test -s lockfiles/ap-product-a/ap-product-a-packagelist.json
test -s lockfiles/ap-product-b/ap-product-b.lock
test -s lockfiles/ap-product-b/ap-product-b-packagelist.json
```

В `ap-product-a-packagelist.json` и `ap-product-b-packagelist.json` должны быть
`package_id` и `package_rev` для обеих конфигураций.

## 4. Зафиксировать baseline до новых версий

Сразу после успешной базовой сборки сохраните lockfile и package list в
неизменяемое место. Сценарии 04 и 07 используют эту копию: канонический
`ap-product-a.lock` позже будет перезаписан релизом с другими зависимостями.

```bash
mkdir -p /tmp/ap-product-a-old /tmp/ap-product-b-old
cp lockfiles/ap-product-a/ap-product-a.lock /tmp/ap-product-a-old/
cp lockfiles/ap-product-a/ap-product-a-packagelist.json /tmp/ap-product-a-old/
cp lockfiles/ap-product-b/ap-product-b.lock /tmp/ap-product-b-old/
cp lockfiles/ap-product-b/ap-product-b-packagelist.json /tmp/ap-product-b-old/
```

`products-pipeline.sh` также создаёт версионные копии
`ap-product-a-1.0.0.lock` и `ap-product-a-1.0.0-packagelist.json` и больше
не перезаписывает их при повторной сборке той же версии продукта.

## Ожидаемый результат

- Все команды завершаются с кодом 0.
- В `packages` лежат библиотеки в Release и Debug.
- В `products` лежат `ap-product-a/1.0.0` и `ap-product-b/1.0.0` вместе с зависимостями.
- В `develop` лежат `ap-product-a/1.0.0` и `ap-product-b/1.0.0`.
- `test_package` каждого пакета реально выполнил `assert`.
- `ap-box` разрешился с `ap-headers/1.3.290` благодаря `force=True`;
  `ap-texture` при этом собрался с этим же headers.

## Если не зелёно

- `conan: command not found` → `uv tool install conan`, затем новый shell.
- Ошибка login → проверьте `CONAN_PASSWORD` и `ARTIFACTORY_URL`; remote URL
  должен указывать на `/artifactory/api/conan/<repo>`.
- Конфликт `ap-headers` → проверьте, что в `ap-box/conanfile.py` стоит
  `force=True`; без него граф неразрешим by design, а `override=True` теряет
  include-пути в `CMakeDeps`.
- Нет бинарника для Debug → проверьте, что `packages-pipeline.sh` собирал обе
  конфигурации и `conan upload` не был пропущен.
