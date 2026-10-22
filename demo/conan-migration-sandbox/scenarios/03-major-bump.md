# 03 — мажорный bump ap-base

Цель: показать, что диапазоны `[>=1.0 <2]` не подхватывают `2.0.0`
автоматически, и выполнить осознанную интеграцию через расширение диапазонов.

## 1. Выпустить ap-base/2.0.0

API можно оставить совместимым с `1.x` или изменить — важна версия. Для чистой
демонстрации достаточно:

```bash
cd demo/conan-migration-sandbox
bash scripts/packages-pipeline.sh libs/ap-base 2.0.0
```

Проверка:

```bash
conan list 'ap-base/2.0.0:*' -r=packages
```

## 2. Убедиться, что диапазоны не подхватывают мажор

```bash
AP_PRODUCT_A_VERSION=1.0.0 conan graph info products/ap-product-a \
  -pr:h profiles/linux-gcc-release \
  -pr:b profiles/linux-gcc-release \
  -s build_type=Release \
  -r=packages \
  --format=json > /tmp/ap-product-a-graph.json

python3 - <<'PY'
import json
data = json.load(open('/tmp/ap-product-a-graph.json'))
for node in data.get('graph', {}).get('nodes', {}).values():
    ref = node.get('ref') or ''
    if ref.startswith('ap-base/'):
        print(ref)
PY
```

Ожидается `ap-base/1.0.0` (или `1.1.0`, если сценарий 02 уже выполнялся), но **не**
`2.0.0`. Это и есть защита от автоматического просачивания мажора.

## 3. Осознанно расширить диапазоны

Обновить требования у прямых потребителей `ap-base`:

```diff
# libs/ap-utils/conanfile.py
-self.requires("ap-base/[>=1.0 <2]")
+self.requires("ap-base/[>=2.0 <3]")
```

```diff
# libs/ap-gfx/conanfile.py
-self.requires("ap-base/[>=1.0 <2]")
+self.requires("ap-base/[>=2.0 <3]")
```

```diff
# products/ap-product-b/conanfile.py
-self.requires("ap-base/[>=1.0 <2]")
+self.requires("ap-base/[>=2.0 <3]")
```

`ap-sdk` и `ap-product-a` не требуют `ap-base` напрямую; они получат новый мажор
транзитивно через `ap-gfx`.

Если в `2.0.0` менялся API, сначала исправьте `ap-utils`, `ap-gfx`,
`ap-product-b` и их `test_package`; иначе сборка упадёт — это ожидаемо.

## 4. Пересобрать и проверить

```bash
bash scripts/packages-pipeline.sh libs/ap-utils 1.0.0
bash scripts/packages-pipeline.sh libs/ap-gfx 1.0.0
bash scripts/packages-pipeline.sh libs/ap-sdk 1.0.0
bash scripts/packages-pipeline.sh libs/ap-box 1.0.0
bash scripts/packages-pipeline.sh libs/ap-texture 1.0.0
bash scripts/packages-pipeline.sh libs/ap-headers 1.3.290
bash scripts/packages-pipeline.sh libs/ap-headers 1.4.1

bash scripts/products-pipeline.sh products/ap-product-a
bash scripts/products-pipeline.sh products/ap-product-b
```

Повторный `conan graph info` должен показать `ap-base/2.0.0`.

## 5. Promote только при успехе

`products-pipeline.sh` сам вызывает `promote.sh` в `develop` **после**
успешной сборки. Если сборка упала, promote не выполняется; в `develop`
остаётся предыдущая версия.

Проверка:

```bash
conan list 'ap-product-a/1.0.0:*' -r=develop
conan list 'ap-product-b/1.0.0:*' -r=develop
```

## Автоматизированный вариант

```bash
bash scripts/scenario-major-bump.sh ap-base 1.0.0 2.0.0
```

Скрипт:

1. собирает `ap-base/2.0.0` и заливает в `packages`;
2. promote'ит её в `products`;
3. собирает `ap-product-a` и `ap-product-b` с **текущими** диапазонами (поэтому `2.0.0`
   может быть проигнорирована — это ожидаемо);
4. печатает результат по каждому продукту и **не** откатывает изменения
   автоматически.

Он не меняет диапазоны — расширение `[>=2.0 <3]` остаётся осознанным ручным
шагом.

## Ожидаемый результат

- До изменения диапазонов `2.0.0` не попадает в граф продуктов.
- После расширения диапазонов и пересборки продуктов `2.0.0` используется.
- В `develop` попадает только успешно собранная версия.
