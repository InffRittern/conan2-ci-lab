# 02 — ломающее изменение в ap-base

Цель: показать, что новая версия библиотеки ломает зависимые пакеты, пока
потребители не исправлены, и что продукт не попадает в `develop` при падении.

## 1. Внести ломающее изменение

В `libs/ap-base/include/ap-base/ap-base.h` изменить сигнатуру:

```diff
-int ap_base_add(int a, int b);
+int ap_base_add(int a, int b, int c);
```

В `libs/ap-base/src/ap-base.cpp`:

```diff
-int ap_base_add(int a, int b) {
-    return a + b;
+int ap_base_add(int a, int b, int c) {
+    return a + b + c;
 }
```

В `libs/ap-base/test_package/test_package.cpp` обновить вызов:

```diff
-    assert(ap_base_add(2, 3) == 5);
+    assert(ap_base_add(2, 3, 4) == 9);
```

`ap-utils` и `ap-gfx` намеренно **не** трогаем: они должны упасть на
компиляции.

## 2. Выпустить ap-base/1.1.0

```bash
cd demo/conan-migration-sandbox
bash scripts/packages-pipeline.sh libs/ap-base 1.1.0
```

Пайплайн соберёт `ap-base/1.1.0` для Release и Debug и зальёт в `packages`.
Диапазон `ap-base/[>=1.0 <2]` теперь будет выбирать `1.1.0`.

## 3. Попробовать собрать продукты

```bash
bash scripts/products-pipeline.sh products/ap-product-a
```

Ожидаемо: падение на компиляции `ap-utils`:

```text
error: too few arguments to function 'int ap_base_add(int, int, int)'
```

`ap-product-b` тоже упадёт, потому что тянет `ap-sdk` → `ap-gfx` →
`ap-utils`:

```bash
bash scripts/products-pipeline.sh products/ap-product-b
```

`products-pipeline.sh` не дойдёт до promote, поэтому в `develop` останется
старый `ap-product-a/1.0.0` / `ap-product-b/1.0.0`, а не сломанная сборка.

## 4. Как починить

Правильный путь — исправить потребителей и выпустить новые версии:

- `ap-utils`: `ap_base_add(value, value)` → `ap_base_add(value, value, 0)` и
  `ap_base_add(value, 7)` → `ap_base_add(value, 7, 0)`;
- `ap-gfx`: `ap_base_add(seed, 1)` → `ap_base_add(seed, 1, 0)`;
- `ap-product-b`: `ap_base_add(seed, 2)` → `ap_base_add(seed, 2, 0)`;
- прогнать `test_package` всех затронутых пакетов;
- пересобрать `ap-utils`, `ap-gfx`, `ap-sdk`, `ap-product-a`, `ap-product-b`
  через соответствующие pipeline.

```bash
bash scripts/packages-pipeline.sh libs/ap-utils 1.0.0
bash scripts/packages-pipeline.sh libs/ap-gfx 1.0.0
bash scripts/packages-pipeline.sh libs/ap-sdk 1.0.0
bash scripts/products-pipeline.sh products/ap-product-a
bash scripts/products-pipeline.sh products/ap-product-b
```

## 5. Как откатить

Вариант A — временно сузить диапазон у потребителей:

```python
self.requires("ap-base/[>=1.0 <1.1]")
```

Затем пересобрать `ap-utils` и `ap-gfx`; продукты снова увидят
`1.0.0`.

Вариант B — восстановить API в `ap-base` и выпустить `1.1.1` с совместимой
сигнатурой (не перезаписывать `1.1.0`, если она уже используется).

```bash
# после восстановления ap_base_add(int, int)
bash scripts/packages-pipeline.sh libs/ap-base 1.1.1
```

Не удаляйте `1.1.0` из remote вручную: это сломает lockfile тех, кто уже
зафиксировал её. Лучше выпустить исправленную версию и обновить диапазоны.

## Ожидаемый результат

- `ap-base/1.1.0` успешно собран и загружен.
- `ap-utils`, `ap-sdk`, `ap-product-a`, `ap-product-b` падают на этапе сборки.
- Promote в `develop` не происходит.
- После исправления потребителей и пересборки продукты снова зелёные.
