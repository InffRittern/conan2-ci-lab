# 07 — мажорные и pre-release версии

Цель: зафиксировать политику версий для CI: мажор не просачивается
автоматически, pre-release не попадает в стабильные диапазоны, а старые
продукты остаются воспроизводимыми.

## 1. Мажорный bump — это новая ветка, а не замена

Правило:

- `1.x` остаётся в `products` и `develop` для старых продуктов;
- `2.x` выпускается отдельной версией и не попадает в диапазоны `[>=1 <2]`;
- продукт переходит на `2.x` только новым релизом продукта, с явным изменением
  диапазонов и пересборкой всех промежуточных библиотек.

### Шаг 1. Выпустить новый мажор библиотеки

```bash
cd demo/conan-migration-sandbox
export CONAN_USERNAME=admin
export CONAN_PASSWORD='<artifactory-пароль>'
export PACKAGES_REMOTE=packages
export PRODUCTS_REMOTE=products
export DEVELOP_REMOTE=develop

bash scripts/ci-package-release.sh libs/ap-base 2.0.0
```

`ci-package-release.sh` собирает Release и Debug, затем публикует полный
пакет в `packages` и продвигает его в `products`.

### Шаг 2. Убедиться, что старый продукт не переключился

```bash
conan install products/ap-product-a \
  -pr:h profiles/linux-gcc-release \
  -pr:b profiles/linux-gcc-release \
  -s build_type=Release \
  --lockfile lockfiles/ap-product-a/ap-product-a.lock \
  --build=never
```

Lockfile старого релиза всё ещё указывает на `ap-base/1.x`. Новый мажор в
`products` не меняет уже сохранённый lockfile.

### Шаг 3. Осознанно включить мажор

Для продукта, который готов к переходу, нужно:

1. поднять версии промежуточных библиотек, которые компилируются против
   `ap-base` (`ap-utils`, `ap-gfx`, `ap-sdk` — по цепочке зависимостей);
2. изменить их диапазоны на `[>=2.0 <3]`, а также диапазоны `ap-sdk` в
   продуктах и в `ci/all-products/conanfile.py`;
3. поднять версию продукта (`ap-product-a/2.0.0` или `ap-product-b/2.0.0`);
4. пересобрать весь набор через `ci-products-release.sh`.

Пример изменения диапазона:

```diff
# libs/ap-utils/conanfile.py
-self.requires("ap-base/[>=1.0 <2]")
+self.requires("ap-base/[>=2.0 <3]")
```

```diff
# products/ap-product-b/conanfile.py
-self.requires("ap-base/[>=1.0 <2]")
+self.requires("ap-base/[>=2.0 <3]")
```

Если менялся API, сначала правятся исходники и `test_package`. Падение
сборки — ожидаемый сигнал: старый код не совместим с новым мажором.

Полный пошаговый diff и пересборка — в
[`03-major-bump.md`](03-major-bump.md). Новый CI-порядок:

```bash
# после правок и подъёма версий
bash scripts/ci-package-release.sh libs/ap-utils 2.0.0
bash scripts/ci-package-release.sh libs/ap-gfx 2.0.0
bash scripts/ci-package-release.sh libs/ap-sdk 2.0.0

# продукт 2.0.0 с диапазонами [>=2 <3]
AP_PRODUCT_A_VERSION=2.0.0 bash scripts/ci-products-release.sh
```

## 2. Pre-release не должен попадать в стабильный диапазон

Conan по умолчанию **исключает** pre-release из version range. Проверено на
2.33.0: если в локальном кэше есть только `ap-base/2.0.0-beta.1`, диапазон
`[>=1 <2]` не разрешается.

### Шаг 1. Собрать pre-release только в staging

```bash
bash scripts/ci-package-release.sh libs/ap-base 2.0.0-beta.1 --no-promote
```

`--no-promote` оставляет версию в `packages`; `products` и `develop` не
меняются.

### Шаг 2. Проверить, что диапазон её игнорирует

Изолированный `CONAN_HOME`, чтобы в кэше была только beta:

```bash
rm -rf /tmp/conan-beta
export CONAN_HOME=/tmp/conan-beta
conan profile detect --force

AP_BASE_VERSION=2.0.0-beta.1 conan export libs/ap-base

conan graph info --requires='ap-base/[>=1 <2]' --no-remote \
  -pr:h profiles/linux-gcc-release \
  -pr:b profiles/linux-gcc-release
```

Ожидается ошибка:

```text
Version range '>=1 <2' ... could not be resolved
```

Это не баг: стабильный диапазон не должен тянуть beta.

### Шаг 3. Явный тест pre-release

```bash
conan graph info --requires='ap-base/2.0.0-beta.1' --no-remote \
  -pr:h profiles/linux-gcc-release \
  -pr:b profiles/linux-gcc-release
```

Версия находится; дальше её можно собрать и проверить отдельным
test-потребителем.

Если нужен диапазон с pre-release, используйте `include_prerelease` только
в отдельном тестовом графе и с явной нижней границей, например:

```text
ap-base/[>=2.0.0-beta.1, include_prerelease]
```

Не добавляйте такой диапазон в стабильные продукты: он начнёт подхватывать
beta/rc автоматически.

## 3. Политика версий для CI

| Изменение | Действие CI | Где публикуется |
|---|---|---|
| patch/minor в пределах `1.x` | обычный `ci-package-release.sh` | `packages` → `products` |
| новый major `2.0.0` | отдельная версия, без изменения старых диапазонов | `packages` → `products` |
| переход продукта на major | новый релиз продукта + диапазоны `[>=2 <3]` | `products` → `develop` |
| pre-release | `--no-promote`, только `packages` | `packages` |
| срочный фикс старой ветки | выпуск `1.x.y` из ветки, lockfile старого продукта не трогать | `packages` → `products` |

## 4. Проверка воспроизводимости после мажора

```bash
# старый продукт должен ставиться без сборки
conan install products/ap-product-a \
  -pr:h profiles/linux-gcc-release \
  -pr:b profiles/linux-gcc-release \
  -s build_type=Release \
  --lockfile lockfiles/ap-product-a/ap-product-a.lock \
  --build=never
```

Если команда падает на `Missing binary`, значит lockfile/package list не
фиксируют старый бинарник. Проверьте, что package list снят с `:*#*`, а не с
`:*`.

## Ожидаемый результат

- `2.0.0` не попадает в старые продукты автоматически.
- Новый продукт с `[>=2 <3]` собирается только после пересборки цепочки.
- `2.0.0-beta.1` не разрешается диапазоном `[>=1 <2]`.
- Старый продукт ставится из lockfile с `--build=never`.
- Pre-release остаётся в `packages`, если не было явного promote.

## Если не зелёно

- `2.0.0` всё равно выбирается старым продуктом — проверьте, что диапазон
  действительно `[>=1 <2]`, а не `[>=1 <3]`.
- Pre-release неожиданно разрешается — проверьте, нет ли в диапазоне
  `include_prerelease`; он включает pre-release.
- Старый lockfile не ставится — package list должен содержать `package_rev`;
  переснимите его командой `conan list '<ref>:*#*'`.
