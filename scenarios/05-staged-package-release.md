# 05 — staged-релиз пакета: сначала бинарники, потом публикация

Цель: показать, как выпускать библиотеку так, чтобы рецепт не появлялся в
`packages` раньше, чем готовы **все** его конфигурации, и чтобы зависимые
пакеты не видели неполную версию.

## Проблема, которую закрывает сценарий

В старом пайплайне публикация могла происходить по шагам:

```text
upload recipe -> build Release -> build Debug -> upload Debug binary
```

Между первым и последним шагом `packages` содержит рецепт без нужного
бинарника. Зависимый job в этот момент получает `Missing binary` или, хуже,
собирает пакет с другим package ID. Это и есть «рецепт опубликован до сборки
всех конфигураций».

## Предусловия

- Conan 2.x в `PATH` (проверено на 2.33.0).
- Настроены remote `packages`, `products`, `develop`:

```bash
cd demo/conan-migration-sandbox
export CONAN_USERNAME=admin
export CONAN_PASSWORD='<artifactory-пароль>'
export PACKAGES_REMOTE=packages
export PRODUCTS_REMOTE=products
export DEVELOP_REMOTE=develop
bash scripts/bootstrap-remotes.sh
```

## 1. Сборка и публикация

```bash
bash scripts/ci-package-release.sh libs/ap-headers 1.4.2
```

Скрипт делает строго по порядку:

1. `conan lock create` + `conan create` для Release в локальном кэше;
2. то же для Debug;
3. `conan lock merge` двух конфигураций;
4. `conan upload ap-headers/1.4.2 -r packages` — только после обеих сборок;
5. `conan list` локального кэша и remote, сверка package ID;
6. `conan download` + `conan upload` в `products` (по умолчанию);
7. повторная сверка package ID уже в `products`;
8. сохранение package list.

Ключевой инвариант: **между шагами 1–3 в `packages` нет ни рецепта, ни
бинарников этой версии**. Если Debug не собрался, публикации не будет вовсе.

## 2. Проверка

```bash
conan list 'ap-headers/1.4.2:*#*' -r packages
conan list 'ap-headers/1.4.2:*#*' -r products

test -s lockfiles/packages/ap-headers/ap-headers-1.4.2.lock
test -s lockfiles/packages/ap-headers/ap-headers-1.4.2-packagelist.json
```

Ожидается:

- в `packages` и `products` по два package ID: Release и Debug;
- package list содержит `package_rev` для обоих бинарников, а не только `package_id`;
- merged lockfile фиксирует точный рецепт; обе конфигурации перечислены в
  package list.

## 3. Staging без promotion

Если версия ещё проверяется и не должна попасть в `products`:

```bash
bash scripts/ci-package-release.sh libs/ap-headers 1.4.2 --no-promote
```

Или через переменную:

```bash
PROMOTE_TO_PRODUCTS=0 \
  bash scripts/ci-package-release.sh libs/ap-headers 1.4.2
```

В этом режиме `packages` — нестабильный staging, `products` не меняется.

## 4. Проверка отрицательного сценария

Ломаем исходник и убеждаемся, что ничего не публикуется:

```bash
rm -rf /tmp/ci-fail && mkdir -p /tmp/ci-fail
cp -r libs/ap-base /tmp/ci-fail/ap-base
printf '\n#error forced failure\n' >> /tmp/ci-fail/ap-base/src/ap-base.cpp

bash scripts/ci-package-release.sh /tmp/ci-fail/ap-base 1.9.9 --no-promote
# ожидаем ненулевой код возврата

conan list 'ap-base/1.9.9:*' -r packages
# ожидаем: "There are no matching recipe references"
```

Проверено на стенде: сборка Release падает, `packages` не содержит
`ap-base/1.9.9`, `products` не меняется.

## 5. Почему это не «атомарный promote»

`ci-package-release.sh` делает публикацию **после** успешной сборки, но сам
`conan upload` не является транзакцией. Если процесс упадёт между загрузкой
рецепта и бинарников, в `packages` останется частичный ref. Поэтому:

- package list и lockfile пишутся только после успешной сверки;
- `ci-products-release.sh` не использует `packages` как источник для
  продуктов, а работает с `products` (см. сценарий 06);
- для истинной атомарности нужен Artifactory Pro и `conan art:promote`.

## Ожидаемый результат

- `ap-headers/1.4.2` собирается в Release и Debug.
- Рецепт появляется в `packages` только после обеих сборок.
- Package ID в `packages` и `products` совпадают.
- При падении любой конфигурации публикации нет.
- `lockfiles/packages/ap-headers/` содержит lockfile и package list.

## Если не зелёно

- `ERROR: ... missing package IDs` — remote не догрузил один из бинарников;
  повторите `conan upload` и проверьте `conan list ...:*#*`.
- `conan upload` просит подтверждение — скрипт передаёт `-c`; проверьте, что
  используется именно `ci-package-release.sh`, а не ручная команда.
- `set_version()` перезаписал версию — скрипт выставляет переменную
  `AP_<NAME>_VERSION`; для нового пакета добавьте её в `ci_version_env_for`.
