# 04 — воспроизводимая сборка старого продукта

Цель: после появления новых версий библиотек в `develop` собрать старый
продукт ровно с теми версиями и бинарниками, которые были зафиксированы
раньше.

Нужны два файла:

- `lockfiles/ap-product-a/ap-product-a.lock` — версии/revisions рецептов;
- `lockfiles/ap-product-a/ap-product-a-packagelist.json` — `package_id`/`package_rev`
  бинарников.

Lockfile сам по себе **не** фиксирует `package_id`/`package_rev`, поэтому без
package list полная воспроизводимость не гарантируется.

## 0. Сохранить артефакты старой сборки

Сделайте это сразу после успешного сценария 01, до выпуска новых версий.
В реальном CI эти файлы лежат в артефактах/коммите.

```bash
cd demo/conan-migration-sandbox
mkdir -p /tmp/ap-product-a-old
cp lockfiles/ap-product-a/ap-product-a.lock /tmp/ap-product-a-old/ap-product-a.lock
cp lockfiles/ap-product-a/ap-product-a-packagelist.json /tmp/ap-product-a-old/ap-product-a-packagelist.json
```

Альтернатива без `/tmp`: pipeline также сохраняет версионные копии
`ap-product-a-1.0.0.lock` и `ap-product-a-1.0.0-packagelist.json` (см. шаг 4).

## 1. Смоделировать появление новых версий

Например, выпустить `ap-base/1.1.0` (сценарий 02) или `ap-base/2.0.0` (сценарий 03) и
пересобрать библиотеки. В `develop` появятся новые версии, а старый lockfile
останется в `/tmp/ap-product-a-old` или в версионной копии.

```bash
bash scripts/packages-pipeline.sh libs/ap-base 2.0.0
```

## 2. Скачать точные бинарники по package list

Package list содержит package IDs, поэтому скачиваем именно их, а не «последнюю
версию»:

```bash
conan download \
  --list=/tmp/ap-product-a-old/ap-product-a-packagelist.json \
  -r=develop
```

Имя remote в `-r` должно совпадать с ключом верхнего уровня в package list:
`products-pipeline.sh` сохраняет список из `develop`, поэтому скачивание идёт
из `develop`. Если нужен именно `products`, сначала создайте package list
командой `conan list 'ap-product-a/1.0.0:*' -r=products --format=json --out-file=...`
и используйте `-r=products`.

## 3. Восстановить граф по старому lockfile

```bash
AP_PRODUCT_A_VERSION=1.0.0 conan install products/ap-product-a \
  -pr:h profiles/linux-gcc-release \
  -pr:b profiles/linux-gcc-release \
  -s build_type=Release \
  --lockfile=/tmp/ap-product-a-old/ap-product-a.lock \
  --build=never
```

`--build=never` важен: если нужного бинарника нет, команда должна упасть, а не
молча собрать другой. Именно это проверяет воспроизводимость.

Ожидается, что в выводе будут старые версии, например `ap-base/1.0.0`, а не
`2.0.0`.

## 4. Пересобрать продукт из исходников с теми же зависимостями

```bash
AP_PRODUCT_A_VERSION=1.0.0 conan create products/ap-product-a \
  -pr:h profiles/linux-gcc-release \
  -pr:b profiles/linux-gcc-release \
  -s build_type=Release \
  -r=products \
  --lockfile=/tmp/ap-product-a-old/ap-product-a.lock \
  --build=missing
```

`--build=missing` пересоберёт только то, чего нет в кэше; версии зависимостей
останутся зафиксированными lockfile. `test_package` проверит, что старый API
совместим со старыми библиотеками.

## 5. Версионные копии

`products-pipeline.sh` после успешной сборки сохраняет:

```text
lockfiles/ap-product-a/ap-product-a.lock
lockfiles/ap-product-a/ap-product-a-packagelist.json
lockfiles/ap-product-a/ap-product-a-1.0.0.lock
lockfiles/ap-product-a/ap-product-a-1.0.0-packagelist.json
```

Для старой версии используйте версионные файлы:

```bash
AP_PRODUCT_A_VERSION=1.0.0 conan install products/ap-product-a \
  -pr:h profiles/linux-gcc-release \
  -pr:b profiles/linux-gcc-release \
  -s build_type=Release \
  --lockfile=lockfiles/ap-product-a/ap-product-a-1.0.0.lock \
  --build=never
```

## Ожидаемый результат

- `conan download --list=...` скачивает ровно зафиксированные бинарники.
- `conan install --lockfile=... --build=never` не тянет новые версии библиотек.
- `conan create` старого продукта проходит без ручного редактирования
  `conanfile.py`.
- Если lockfile/package list потеряны, воспроизводимость не гарантируется:
  диапазоны могут выбрать новые версии, а lockfile — другие revisions.
