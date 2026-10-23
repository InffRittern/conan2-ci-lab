# Алгоритм миграции рецептов и пакетов Conan 1 → Conan 2

## 0. Назначение

Документ описывает повторяемый алгоритм перевода **одного пакета или
группы пакетов** с Conan 1 на Conan 2. Он не привязан к конкретному
проекту: вместо имён используйте placeholders.

> `example-*`, `source-*` и `my-*` — абстрактные имена. Публичные
> библиотеки и инструменты (`fmt`, `catch2`, `cmake`, `ninja`) оставлены
> как узнаваемые примеры.

Основной документ с обоснованиями, стендом и командами:
[`conan1-conan2-migration-runbook.md`](conan1-conan2-migration-runbook.md).

Алгоритм покрывает два разных вида работ:

1. **Миграция рецепта** — переписать `conanfile.py` и `test_package` на
   C2 API.
2. **Миграция пакета** — пересобрать бинарник в C2 и опубликовать
   проверенный набор.

Это не одна операция. Рецепт можно портировать и проверить локально, но
пакет всё равно должен быть пересобран: C1-бинарники не переносятся.

## 1. Инварианты

1. **Source и target существуют параллельно** до завершения cutover.
2. **C1-бинарники не копируются в C2.** Package ID и раскладка
   различаются.
3. **Рецепт не конвертируется автоматически.** Официального конвертера
   C1→C2 нет; рецепт портируется и проверяется сборкой.
4. **Единица работы — `ref + configuration`**, а не каждый исторический
   package ID.
5. **У каждого ref есть владелец и решение** до начала пересборки.
6. **Gate предыдущего этапа закрыт до начала следующего.**
7. **Точность важнее скорости:** фиксируются recipe revision,
   package ID, package revision и профили.
8. **`--build=never` — обязательная проверка потребителя.** Иначе
   потребитель тихо соберёт пакет и скроет проблему.
9. **Lockfile — вход разрешения, package list — выход сборки.** Это
   разные артефакты.
10. **C1-репозитории не удаляются до закрытия окна rollback.**
11. **Платформа — часть identity пакета.** Linux, WSL и Windows дают
    разные package ID; WSL для Conan — это Linux, а не Windows.

## 2. Общая схема этапов

| Этап | Вход | Выход | Gate |
|---|---|---|---|
| 0. Решения | список пакетов, владельцы | политика ref, матрица, lock-политика | решения зафиксированы |
| 1. Discovery | source remotes, потребители | inventory и backlog | каждый ref классифицирован |
| 2. Target | решения | C2-репозитории и remotes | тестовый пакет виден через target |
| 3. Freeze/backup | source | freeze, backup, restore test | restore проверен |
| 4. C1 baseline | существующие C1-пакеты | pref/manifest для rollback | manifest снят, копирования нет |
| 5. Recipe migration | C1-рецепты | C2-рецепты и test_package | рецепт загружается и собирается |
| 6. Package rebuild | C2-рецепты | бинарники, package ID, lockfiles | матрица и package ID зелёные |
| 7. Staged publish | проверенные бинарники | package lists, manifest, promote | counts и verify зелёные |
| 8. Cutover | опубликованный набор | clean consumer, CI | `--build=never` проходит |
| 9. Decommission | закрытое окно rollback | source read-only/архив | C1 больше не нужен |

Не переходите дальше, если gate не закрыт. Особенно это касается этапов
5–7: ошибка в рецепте или package ID проявится позже, когда пересборка
уже потратит время CI.

Команды в этапах ниже даны для POSIX shell (Linux/WSL). Для Windows
PowerShell используйте эквиваленты из §16; логика этапов и gates не
меняются. WSL запускает Linux-Conan, а не `conan.exe`.

## 3. Этап 0. Решения

До команд зафиксируйте:

| Решение | Что определить |
|---|---|
| Топология | `packages`, `products`, `develop`, virtual `conan2` |
| Ref-политика | сохранять `user/channel` или менять; менять отдельно от options |
| Матрица | OS, compiler, version, libcxx, cppstd, build_type, runtime, shared/static |
| Package ID | какие options входят в ID, какие build-only |
| Lockfile | где создаётся, где хранится, коммитится ли |
| Compatibility | разрешать fallback по `cppstd`/`cstd` или запретить |
| Внешние зависимости | ConanCenter, зеркало, приватный форк |
| Rollback | предыдущий C1-набор и предыдущий C2 release bundle |
| Владельцы | рецепт, пакет, CI, Artifactory |
| Окно rollback | сколько source остаётся доступным |

Результат этапа: `migration-decisions.md` или раздел в backlog.
Без этих решений discovery превращается в сбор данных без критерия
готовности.

## 4. Этап 1. Discovery

### 4.1. Что инвентаризировать

Для каждого пакета:

- `name/version@user/channel`;
- recipe revision;
- все используемые package ID;
- package revision, если нужен точный rollback;
- settings и options;
- платформа: `os`, compiler, version, libcxx/runtime, build_type;
- requires/build requires;
- потребители: репозитории, `conanfile.py`, `conanfile.txt`, lockfiles,
  CI jobs, Docker-образы;
- профили потребителей;
- source remotes;
- владельца.

### 4.2. C1-инвентарь

```bash
export C1=/path/to/conan1/bin/conan
export C1_HOME=/tmp/conan1-inventory
export CONAN_USER_HOME="$C1_HOME"
export CONAN_REVISIONS_ENABLED=1

"$C1" --version
"$C1" remote list
"$C1" profile list
```

Поиск по source-репозиториям:

```bash
for repo in $C1_REMOTES; do
  echo "== $repo"
  "$C1" search "*" -r "$repo"
done > /tmp/conan1-inventory.txt
```

Для конкретного ref ревизии снимаются отдельно:

```bash
"$C1" search "$REF" --revisions \
  --json "/tmp/revisions-${REF//\//_}.json" -r "$SOURCE_REPO"
```

Wildcard с `--revisions` в C1.66 не работает. Package revision через
`conan search` не видна; для точного переноса нужен manifest из кэша.

### 4.3. Модель записи

Одна строка backlog:

```text
repo | ref | recipe_revision | package_id | package_revision |
settings | options | requires | consumers | owner | decision | evidence
```

Для больших хранилищ шардируйте backlog по repo и префиксу ref:

```text
inventory/<repo>/<first-letter>.jsonl
```

### 4.4. Классификация

| Класс | Признак | Решение |
|---|---|---|
| Internal, source есть | рецепт и исходники доступны | портировать и пересобрать |
| External CCI | версия есть в ConanCenter | взять C2-рецепт, пересобрать |
| Patched external | локальный патч/опция | приватный форк или vendored source |
| Binary-only | есть package, нет рецепта/исходников | `blocked-no-source` |
| Unused | нет потребителей | архив, не мигрировать |
| Build tool | cmake, ninja, toolchain | волна 0 |

Единица миграции — `ref + configuration потребителя`, а не все
исторические package ID.

### 4.5. Gate discovery

- все refs и ревизии известны;
- потребители и CI jobs перечислены;
- профили и матрица зафиксированы;
- внешние зависимости известны;
- каждый ref классифицирован;
- `blocked-no-source` вынесен отдельно;
- у каждого ref есть владелец.

## 5. Этап 2. Target design

Минимальная топология:

```text
packages   LOCAL   библиотеки и build tools
products   LOCAL   продукты и staging
develop    LOCAL   стабильные сборки
conan2     VIRTUAL packages + products + develop + external C2 remote
```

Правила:

- C2-рецепты не загружаются в C1-репозитории;
- старый C1-virtual не входит в `conan2`;
- внешний C2-remote должен быть виден через `conan2`;
- потребители читают только `conan2`;
- CI пишет в `packages`/`products`, promote — отдельная роль;
- один и тот же ref не публикуется одновременно в `products` и
  `develop` без явной политики.

Gate: тестовый пакет устанавливается через `conan2`.

## 6. Этап 3. Freeze и backup

1. Объявить freeze на source.
2. Остановить все CI jobs, которые публикуют в source.
3. Запретить разработчикам `conan upload` в source.
4. Сделать backup Artifactory: БД + filestore.
5. Проверить restore на отдельном инстансе.
6. Сохранить inventory, manifests, profiles, remotes и package lists.

Gate: restore проверен, freeze действует, окно rollback записано.

## 7. Этап 4. C1 baseline

Если C1-пакеты уже лежат в Artifactory:

1. Оставить их на месте.
2. Снять точный manifest для используемых refs.
3. Зафиксировать recipe revision, package ID и, если доступно,
   package revision.
4. Не копировать бинарники в C2.
5. Не создавать `legacy`-копию без необходимости.
6. Пересоздать consumer lockfiles: C1 lockfile несовместим с C2.
7. Снимать baseline отдельно для каждой платформы: C1-кэш Windows и
   C1-кэш WSL/Linux — разные кэши, даже если ref совпадает.

Если пакет существует только как бинарник, это `blocked-no-source`, а не
задача «переупаковать». Такой ref не входит в зелёный gate.

Gate: для каждого используемого ref есть pref/manifest; C1 остаётся
доступным для rollback.

## 8. Этап 5. Миграция рецепта

### 8.1. Сканирование C1-паттернов

Искать:

```text
from conans
imports()
self.copy
deps_cpp_info
env_info
user_info
generators = "cmake"
generators = "cmake_multi"
generators = "json"
self.env_info
```

Это кандидаты, а не автоматический вердикт. Для внешних рецептов не
переписывайте C1-копию: берите C2-рецепт из CCI или приватного форка.

### 8.2. Выбор пути

```text
рецепт и исходники есть?
├─ нет  → blocked-no-source / C1-only
└─ да
   ├─ внешний и версия есть в CCI → C2-рецепт из CCI/форка
   └─ внутренний/патченный      → портировать вручную
```

### 8.3. Порядок портирования

1. Импорты только из `conan.*`.
2. Metadata: `name`, `version`, `license`, `author`, `description`.
3. Settings и options; не менять их одновременно с `user/channel`.
4. Requires: точные refs или согласованные ranges.
5. Source export: `exports_sources` или `export()`.
6. `layout()`: `cmake_layout(self)` или явные folders.
7. `generate()`: `CMakeToolchain`, `CMakeDeps`, `VirtualBuildEnv`,
   `VirtualRunEnv` для runtime/тестов.
8. `build()`: `CMake`, тесты только при включённой опции.
9. `package()`: `cmake.install()` + `copy()`.
10. `package_info()`: `cpp_info`, `cmake_file_name`,
    `cmake_target_name`.
11. `test_package`: отдельный C2-потребитель.
12. `README` и CI-команды.

Минимальные фрагменты, которые чаще всего забывают:

```python
from conan.tools.files import copy

class PkgConan(ConanFile):
    exports_sources = (
        "CMakeLists.txt",
        "src/*",
        "include/*",
        "tests/*",
        "cmake/*",
        "docs/*",
    )

    def package(self):
        copy(
            self,
            "*.txt",
            src=os.path.join(self.source_folder, "docs", "licenses"),
            dst=os.path.join(self.package_folder, "licenses"),
        )
        cmake = CMake(self)
        cmake.install()
```

C1-атрибут `scm` сам по себе не заменяет `exports_sources`/`export()`:
без них в cache попадает только `conanfile.py`.

### 8.4. Обязательные проверки рецепта

```bash
"$C2" export "$RECIPE_PATH"
"$C2" cache path "$REF" --folder=export_source
```

В export_source должны быть исходники, а не только `conanfile.py`.

```bash
"$C2" graph info "$RECIPE_PATH" --build=missing \
  -r "$C2_VIRTUAL" \
  -pr:h "$PROFILE_HOST" -pr:b "$PROFILE_BUILD" \
  2>&1 | tee /tmp/graph.log

grep -q "ERROR:" /tmp/graph.log && echo "graph failed" || echo "graph ok"
```

`conan graph info` может вернуть exit code `0` при `ERROR:` в выводе.
Проверять надо лог.

```bash
"$C2" create "$RECIPE_PATH" --build=missing \
  -r "$C2_VIRTUAL" \
  -pr:h "$PROFILE_HOST" -pr:b "$PROFILE_BUILD"
```

Один успешный `create` не закрывает gate: нужна хотя бы одна
конфигурация с тестами и одна без тестов.

### 8.5. `test_package`

`test_package` — это отдельный потребитель. Он должен:

- использовать `CMakeToolchain`/`CMakeDeps`;
- использовать `VirtualRunEnv`, если пакет shared;
- проверять `cmake_target_name`, include dirs, libs, runtime;
- не использовать `deps_cpp_info`;
- не использовать `CONAN_PKG::<name>`;
- не использовать `conanbuildinfo.cmake`;
- запускать executable через `env="conanrun"`.

Минимальная проверка CMake:

```cmake
find_package(<pkg> REQUIRED)
target_link_libraries(test_package PRIVATE <namespace>::<target>)
```

### 8.6. Частые ошибки

| Симптом | Причина | Решение |
|---|---|---|
| `AttributeError: 'ConanFile' object has no attribute 'copy'` | C1 `self.copy` | `copy()` из `conan.tools.files` |
| `ImportError: cannot import name 'ConanFile' from 'conans'` | C1-импорт | `from conan import ConanFile` |
| distribution пустой, ошибок нет | C2 не вызывает `imports()` | перенести копирование в `generate()` |
| `deps_cpp_info` отсутствует | C1 API | `self.dependencies` |
| `env_info`/`user_info` отсутствуют | C1 API | `VirtualRunEnv`/`conf_info` |
| source пустой, export успешен | `scm` не экспортирует исходники | `exports_sources`/`export()` |
| `conan package` не работает | команда удалена | `conan create`/`conan export-pkg` |
| тесты не находят `.so`/`.dll` | нет runtime env | `VirtualRunEnv` |
| CMake target называется иначе | нет `cmake_target_name` | задать property |
| package ID не меняется, хотя тесты влияют на бинарник | опция удалена из ID | проверить, не меняет ли она библиотеку |

### 8.7. Gate recipe

- нет C1-импортов и C1-API;
- `conan export` кладёт исходники в cache;
- `conan graph info` не содержит `ERROR:`;
- `conan create` проходит хотя бы в одной конфигурации;
- `test_package` линкует и запускает пакет;
- README и CI больше не используют `conan package`;
- внешние зависимости имеют C2-рецепты.

## 9. Этап 6. Пересборка пакета

### 9.1. Чистый home

```bash
export CONAN_HOME="$C2_HOME"
rm -rf "$CONAN_HOME"

"$C2" profile detect --force
"$C2" remote add -f "$C2_VIRTUAL" \
  "$ARTIFACTORY_URL/artifactory/api/conan/$C2_VIRTUAL"
"$C2" remote login "$C2_VIRTUAL" "$ARTIFACTORY_USER" \
  -p "$ARTIFACTORY_PASSWORD"
```

Профили должны повторять source-конфигурацию: compiler, version, libcxx,
cppstd, build_type, runtime, generator. Для Linux/WSL и Windows профили
различаются; готовые варианты и PowerShell-эквиваленты — в §16.2–16.4.

### 9.2. Build order

```bash
"$C2" graph build-order "$RECIPE_PATH" --build=missing \
  --order-by=recipe \
  -r "$C2_VIRTUAL" \
  -pr:h "$PROFILE_HOST" -pr:b "$PROFILE_BUILD" \
  --format=json > /tmp/build-order.json
```

Порядок: build tools → leaf libraries → libraries → SDK → products.
Не используйте `--reduce` на промежуточных order'ах: уменьшённый order
нельзя мержить.

Если рецепта зависимости нет в remote, `--build=missing` не поможет.
Нужен `local-recipes-index`, зеркало или приватный форк.

### 9.3. Матрица

Минимум для библиотеки:

| Измерение | Минимум |
|---|---|
| OS | Linux |
| Compiler | GCC |
| Build type | Release |
| Linkage | shared |
| Tests | `test_package` |

Для реального проекта добавить:

- Linux + Windows (+ macOS);
- GCC/Clang/MSVC;
- Release + Debug;
- shared + static;
- все поддерживаемые `cppstd`;
- runtime MD/MT;
- все публичные options;
- `build_tests=True/False`;
- cross-build, если есть.

WSL входит в Linux-строку матрицы (`os=Linux`), но маркируется
`runner=wsl`. Windows — отдельная строка с MSVC и runtime. Не считайте
WSL отдельной Conan-платформой.

### 9.4. Ожидаемый и фактический package ID

Для каждой строки матрицы (`platform + config`) зафиксировать:

```text
ref | platform | config | expected_package_id | actual_package_id | status | log
```

Expected ID берётся из `conan graph info --format=json` до сборки.
Actual ID — из `conan list` после сборки. «Собралось без ошибок» не
означает, что ID совпал.

### 9.5. Проверка содержимого пакета

```bash
"$C2" cache path "$PREF" --folder=package
```

Проверить:

- headers;
- libs/import libraries;
- DLL/SO/dylib;
- лицензии;
- CMake config/targets;
- natvis и Windows runtime;
- symlink'и на Linux;
- RPATH/`$ORIGIN`;
- отсутствие source-файлов, которых не должно быть в пакете.

Платформенные инструменты и артефакты — в §16.7: ELF/RPATH для Linux и
WSL, `.dll`/`.lib`/`.pdb` и `dumpbin` для Windows.

### 9.6. Lockfile

```bash
"$C2" lock create "$RECIPE_PATH" \
  -pr:h "$PROFILE_HOST" -pr:b "$PROFILE_BUILD" \
  -s build_type="$BUILD_TYPE" \
  -r "$C2_VIRTUAL" \
  --lockfile-out "lock/${PLATFORM}-${BUILD_TYPE}.lock"
```

Для библиотеки lockfile обычно не коммитится; для продукта — коммитится
в PR, меняющем зависимости. В CI передавайте lockfile явно, иначе
stale-файл из workspace может изменить граф.

### 9.7. Compatibility plugin

Если нужен строгий package ID, отключите fallback:

```python
def compatibility(conanfile):
    return []
```

Не удаляйте файл: Conan падает, если `compatibility.py` отсутствует.
Распространяйте политику через `conan config install`, иначе на разных
агентах будет разное поведение.

Цена отключения — больше пересборок: матрица должна содержать все
поддерживаемые `cppstd`.

### 9.8. Gate rebuild

- чистый `CONAN_HOME`;
- профили совпадают с source;
- build order построен;
- все обязательные конфигурации собраны;
- expected/actual package ID совпадают;
- `test_package` проходит;
- runtime-зависимости найдены;
- compatibility-политика зафиксирована.

## 10. Этап 7. Staged publish

### 10.1. Библиотека

1. Собрать Release и Debug.
2. Прогнать `test_package` в обеих конфигурациях.
3. Смёржить package lists отдельно для каждой платформы: Linux/WSL и
   Windows не смешиваются в одном списке.
4. Загрузить точный ref в `packages`.
5. Снять package list с `package_rev`.
6. Promote в `develop` после fan-in.

```bash
"$C2" list "$REF:*#*" --format=json \
  > artifacts/${NAME}-${CONFIG}.json

"$C2" pkglist merge \
  -l artifacts/${NAME}-linux-release.json \
  -l artifacts/${NAME}-linux-debug.json \
  --format=json > artifacts/${NAME}-uploaded.json

"$C2" upload --list=artifacts/${NAME}-uploaded.json \
  -r "$C2_PACKAGES" -c
```

Пример выше — Linux. Для Windows имена файлов, профили и package list
другие; не смешивайте их с Linux-списком. Не используйте wildcard
upload: загружайте точный ref или проверенный package list.

### 10.2. Promote

```bash
"$C2" download --list=artifacts/${NAME}-uploaded.json \
  -r "$C2_PACKAGES" --format=json > artifacts/${NAME}-promote.json

"$C2" upload --list=artifacts/${NAME}-promote.json \
  -r "$C2_DEVELOP" -c
```

Promote — это download проверенного списка и upload того же набора.
Не пересобирайте пакет на этапе promote.

### 10.3. Manifest

Manifest пишется последним. В нём:

- `ref`, recipe revision, package ID, package revision;
- `platform` (`linux`/`windows`) и `runner` (`linux`/`wsl`/`windows`);
- профили и `build_type`;
- commit исходников;
- `promoted_to_develop`;
- timestamp и версия CI-скрипта.

Проверить counts refs/package ID в source, package list и manifest.
Расхождение — gate, а не предупреждение.

`conan upload` и `conan list` могут вернуть exit code `0` при ошибке
(например, при HTTP 404). Проверяйте содержимое JSON и наличие пакета
в remote, а не только код возврата.

### 10.4. Gate publish

- package list содержит `package_id` и `package_rev`;
- все конфигурации в одном merged list;
- `develop` не обновлён частично;
- manifest записан последним;
- verify-скрипт зелёный;
- пакет виден через `conan2`.

## 11. Этап 8. Cutover

### 11.1. Clean consumer

```bash
export CONAN_HOME=/tmp/conan2-clean-consumer
rm -rf "$CONAN_HOME"

"$C2" profile detect --force
"$C2" remote add -f "$C2_VIRTUAL" \
  "$ARTIFACTORY_URL/artifactory/api/conan/$C2_VIRTUAL"
"$C2" remote login "$C2_VIRTUAL" "$ARTIFACTORY_USER" \
  -p "$ARTIFACTORY_PASSWORD"

"$C2" install --requires="$REF" \
  -r "$C2_VIRTUAL" --build=never \
  -pr:h "$PROFILE_HOST" -pr:b "$PROFILE_BUILD"
```

`--build=never` обязателен. Если пакет не найден, это ошибка cutover, а
не повод собрать его из исходников. Повторите проверку для каждой
платформы из матрицы; Windows- и Linux-потребители используют разные
профили и package ID.

### 11.2. CI

1. Отдельный `CONAN_HOME` на job или эфемерный агент.
2. `conan profile detect`/`conan config install`.
3. `conan remote login` под сервисной учётной записью.
4. Lockfile, package list, профили и версия Conan — артефакты CI.
5. Публикация только через staged-скрипты.
6. `conan2` — единственный remote для потребителя.
7. CI-кэш не должен переживать смену target-топологии без очистки.
8. CI wrapper (Jenkins shared library и т.п.) должен быть проверен и
   зафиксирован по версии, а не по плавающей ветке.
9. Linux, WSL и Windows используют разные runner’ы, профили и package
   lists; проверки и ограничения — в §16.

### 11.3. Canary и rollback

- Переключить один сервис/продукт.
- Сравнить build manifest, runtime и размер дистрибутива.
- Держать C1-remote доступным.
- Проверить rollback до массового переключения.
- После canary переключать остальные продукты партиями.

Rollback:

1. Остановить публикацию в target.
2. Зафиксировать текущий manifest и package list.
3. Переключить consumer/CI на старый pipeline.
4. Собрать с `--build=never` и проверить runtime.
5. Не удалять source до завершения разбора.

Rollback выполняется отдельно для каждой платформы: Linux/WSL-bundle не
заменяет Windows-bundle и наоборот.

### 11.4. Gate cutover

- clean consumer ставится с `--build=never`;
- старый продукт ставится по lockfile + package list;
- CI использует чистый home;
- canary зелёный;
- rollback отрепетирован;
- C1 lockfiles заменены на C2 lockfiles/package lists;
- для каждого продукта есть предыдущий C2 release bundle.

## 12. Этап 9. Decommission

1. Закрыть окно rollback.
2. Перевести source в read-only/архив.
3. Удалить C1-remotes из клиентов и CI.
4. Обновить документацию, профили и шаблоны.
5. Сохранить inventory, manifests и backup по retention.
6. Проверить, что новые публикации идут только в target.
7. Удалить временные target-репозитории через PATCH, если они больше не
   нужны.

## 13. Шаблоны артефактов

### 13.1. Backlog

```jsonl
{"repo":"<repo>","ref":"<name>/<version>@<user>/<channel>","platform":"linux|windows","recipe_revision":"<rrev>","package_id":"<pkgid>","package_revision":"<prev>","settings":{},"options":{},"requires":[],"consumers":[],"owner":"<team>","decision":"migrate|external|blocked-no-source|unused","evidence":"<link>"}
```

### 13.2. Package ID map

```csv
ref,platform,config,expected_package_id,actual_package_id,status,log
```

### 13.3. Manifest

```json
{
  "ref": "<name>/<version>@<user>/<channel>",
  "platform": "linux",
  "runner": "wsl",
  "recipe_revision": "<rrev>",
  "configurations": [
    {
      "profile": "<profile>",
      "build_type": "Release",
      "package_id": "<pkgid>",
      "package_revision": "<prev>"
    }
  ],
  "source_commit": "<git-sha>",
  "promoted_to_develop": true,
  "created_at": "<timestamp>",
  "ci_version": "<version>"
}
```

`platform` — это Conan-платформа (`linux`/`windows`), `runner` — где
реально выполнялась сборка (`linux`/`wsl`/`windows`). Для WSL:
`platform=linux`, `runner=wsl`.

### 13.4. Release bundle

```text
release/<git-sha>/
  linux-gcc-release/
    conan.lock
    package-list.json
    profiles/
      <profile>
    manifest.json
  windows-msvc-release/
    conan.lock
    package-list.json
    profiles/
      <profile>
    manifest.json
```

WSL использует `linux-*` bundle; `runner=wsl` фиксируется в manifest,
а не в имени Conan-платформы.

## 14. Антипаттерны

- Копировать C1-бинарники в C2.
- Загружать C2-рецепты в C1-репозиторий.
- Использовать `scm` без `exports_sources`/`export()`.
- Оставлять `self.copy`, `deps_cpp_info`, `env_info`, `user_info`.
- Использовать `conan package`.
- Запускать `conan create` в C1 home.
- Считать `--build=missing` заменой отсутствующему рецепту.
- Публиковать wildcard'ом `name/*`.
- Делать поштучный promote и оставлять `develop` частично обновлённым.
- Считать package list lockfile'ом.
- Считать lockfile достаточным для точного rollback без package list.
- Использовать несколько remotes у потребителя без явной политики.
- Полагаться на `latest` вместо lockfile + package list.
- Отключать тесты, чтобы «сборка прошла».
- Менять одновременно `settings`, `options`, `package_type` и
  `user/channel`.
- Удалять C1-репозитории до закрытия окна rollback.

## 15. Минимальный чек-лист

### Рецепт

- [ ] Нет `conans`, `imports()`, `self.copy`, `deps_cpp_info`,
      `env_info`, `user_info`.
- [ ] Исходники попадают в cache через `exports_sources`/`export()`.
- [ ] `layout()` и `cmake_layout` проверены.
- [ ] `generate()` создаёт toolchain/deps/env.
- [ ] `VirtualRunEnv` добавлен для shared/тестов.
- [ ] `package_info()` заполняет `cpp_info`.
- [ ] `test_package` переписан на C2.
- [ ] Options/package ID проверены.
- [ ] `cmake_file_name`/`cmake_target_name` заданы.
- [ ] README и CI не используют `conan package`.

### Пакет

- [ ] Чистый `CONAN_HOME`.
- [ ] Профили совпадают с source.
- [ ] Build order построен.
- [ ] Все обязательные конфигурации собраны.
- [ ] Expected/actual package ID совпадают.
- [ ] `test_package` проходит.
- [ ] Runtime-зависимости проверены.
- [ ] Package list содержит `package_rev`.
- [ ] Manifest записан последним.
- [ ] Clean consumer ставится с `--build=never`.

### Платформа

- [ ] Linux: RPATH/RUNPATH, SONAME, symlink’и, `ldd` проверены.
- [ ] WSL: используется Linux-Conan, скрипты в LF, `CONAN_HOME` на ext4.
- [ ] Windows: UTF-8 JSON, длинные пути, Debug/Release runtime, DLL в `PATH`.
- [ ] Для каждой платформы отдельные package list и manifest.
- [ ] WSL не считается отдельной Conan-платформой: `platform=linux`,
      `runner=wsl`.
- [ ] C1-кэши Windows и WSL не смешиваются.

## 16. Платформы: Linux, WSL, Windows

### 16.1. Общая модель

CLI Conan 2 одинаковый на всех платформах. Различаются:

- оболочка и синтаксис переменных;
- пути и права;
- профиль (`os`, compiler, runtime);
- формат бинарников;
- runtime-окружение;
- способ проверки пакета.

| Платформа | `os` в profile | Compiler | Артефакты | Runtime |
|---|---|---|---|---|
| Linux | `Linux` | gcc/clang | `.so`, `.a`, headers | `LD_LIBRARY_PATH`, RPATH/`$ORIGIN` |
| WSL | `Linux` | gcc/clang | ELF `.so`, `.a` | как Linux; Windows DLL не подходят |
| Windows | `Windows` | msvc | `.dll`, `.lib`, `.pdb`, `.exe` | `PATH`, CRT, Debug/Release |

Ключевое правило: **WSL для Conan — это Linux, а не Windows.** Пакет,
собранный Windows-Conan, не становится пригодным для WSL, и наоборот.

### 16.2. Linux

```bash
uname -a
export CONAN_HOME="$HOME/.conan2"
export C2=/path/to/conan2/bin/conan

"$C2" --version
"$C2" profile detect --force
"$C2" profile show -pr "$PROFILE_HOST"
```

Профиль Linux/Ninja:

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

Проверки:

```bash
PACKAGE=$("$C2" cache path "$PREF" --folder=package)

readelf -d "$PACKAGE/lib/lib<name>.so" | grep -E 'RPATH|RUNPATH'
ldd "$PACKAGE/lib/lib<name>.so"
find "$PACKAGE" -type l -ls
```

Учитывайте:

- ABI `libstdc++11` vs `libstdc++` — это разные package ID;
- glibc: собирайте на самой старой поддерживаемой базе, а не на новой;
- SONAME и symlink’и (`libfoo.so` → `libfoo.so.1`) должны сохраняться;
- RPATH `$ORIGIN` проверяется после установки, а не только в build tree;
- Docker/CI с `root` может дать другие права на файлы.

### 16.3. WSL

1. Установите Conan **внутри дистрибутива WSL**.
2. Не вызывайте `conan.exe` из Linux-шелла: он получит Windows-пути,
   Windows-профиль и Windows-кэш.
3. Проверьте, какой бинарник найден:

```bash
command -v conan
file "$(command -v conan)"
uname -a
```

Если `file` показывает `PE32+`, вы запускаете Windows-Conan. Для
Linux-сборки это неверно.

Пути:

| Windows | WSL |
|---|---|
| `C:\git\<repo>` | `/mnt/c/git/<repo>` |
| `C:\Users\<user>` | `/mnt/c/Users/<user>` |
| `C:\c2` | `/mnt/c/c2` |

Конвертация:

```bash
wslpath -u 'C:\git\<repo>'
wslpath -w /mnt/c/git/<repo>
```

Рекомендации:

- `CONAN_HOME` держите на ext4, например `$HOME/.conan2`, а не на
  `/mnt/c`: меньше проблем с правами, symlink’ами и скоростью.
- Репозиторий может лежать на `/mnt/c`, но build/cache лучше на ext4.
- Для shell-скриптов нужен LF. Если виден CRLF, исправьте
  `.gitattributes` или настройку Git, а не маскируйте ошибку в CI.
- Исполняемый бит на `/mnt/c` может не сохраняться; запускайте
  `bash scripts/ci.sh`.
- Symlink’и на `/mnt/c` могут вести себя иначе, чем на ext4.

Проверка line endings:

```bash
file scripts/ci.sh
git config --get core.autocrlf
```

Запуск из Windows:

```powershell
wsl.exe -- bash -lc 'cd /mnt/c/git/<repo> && conan --version'
```

Запуск Windows-команды из WSL — только осознанно:

```bash
cmd.exe /c "conan --version"
```

Не смешивайте окружения в одном job.

### 16.4. Windows

Используйте PowerShell 7, если есть выбор. Windows PowerShell 5.1
поддерживается, но у него другие кодировки и операторы.

```powershell
$ErrorActionPreference = "Stop"

$env:CONAN_HOME = "C:\c2"
if (Test-Path $env:CONAN_HOME) {
    Remove-Item -Recurse -Force $env:CONAN_HOME
}

& $C2 profile detect --force
& $C2 remote add -f $env:C2_VIRTUAL `
    "$env:ARTIFACTORY_URL/artifactory/api/conan/$env:C2_VIRTUAL"
& $C2 remote login $env:C2_VIRTUAL $env:ARTIFACTORY_USER `
    -p $env:ARTIFACTORY_PASSWORD
```

Профиль Windows/MSVC:

```ini
[settings]
os=Windows
arch=x86_64
compiler=msvc
compiler.version=193
compiler.runtime=dynamic
compiler.runtime_type=Release
compiler.cppstd=17
build_type=Release

[conf]
tools.cmake.cmaketoolchain:generator=Visual Studio 17 2022
```

Правила:

- `compiler.runtime_type` должен соответствовать `build_type`
  (`Debug`/`Release`);
- `compiler.runtime=static` (`/MT`) и `dynamic` (`/MD`) дают разные
  package ID;
- не смешивайте Debug-библиотеку с Release-потребителем;
- для Ninja нужен доступный `cl.exe` (окружение MSVC), иначе берите
  Visual Studio generator;
- multi-config generator: не задавайте `CMAKE_BUILD_TYPE` вручную,
  используйте `--config`/Conan;
- `cmake_layout` и CMakePresets предпочтительнее ручных путей.

Сборка в PowerShell:

```powershell
& $C2 profile show -pr $env:PROFILE_HOST

& $C2 create $env:RECIPE_PATH --build=missing `
    -r $env:C2_VIRTUAL `
    -pr:h $env:PROFILE_HOST -pr:b $env:PROFILE_BUILD
```

JSON и кодировки:

```powershell
& $C2 graph info $env:RECIPE_PATH --build=missing `
    -r $env:C2_VIRTUAL `
    -pr:h $env:PROFILE_HOST -pr:b $env:PROFILE_BUILD `
    --format=json 2> graph.err |
    Out-File -Encoding utf8 graph.json

if ((Select-String -Path graph.err -Pattern 'ERROR:' -Quiet) -or
    (Select-String -Path graph.json -Pattern 'ERROR:' -Quiet)) {
    throw "conan graph info failed; see graph.err / graph.json"
}
```

`graph info` может напечатать `ERROR:` в stdout и всё равно вернуть `0`.
Поэтому проверяются оба потока. Не проверяйте только `$LASTEXITCODE`.

В Windows PowerShell 5.1 оператор `>` по умолчанию пишет UTF-16LE.
Для JSON это частая причина ошибок парсинга. Используйте
`Out-File -Encoding utf8`; если нужен UTF-8 без BOM, пишите через
`[IO.File]::WriteAllText()` с `UTF8Encoding($false)`.

Длинные пути (от администратора):

```bat
reg add "HKLM\SYSTEM\CurrentControlSet\Control\FileSystem" ^
  /v LongPathsEnabled /t REG_DWORD /d 1 /f
```

После включения — перезагрузка. Дополнительно:

- держите `CONAN_HOME` коротким (`C:\c2`);
- не разворачивайте workspace в глубокую иерархию;
- для CMake/MSVC учитывайте лимит длины объектных путей;
- symlink’и в пакете требуют Developer Mode или прав администратора.

### 16.5. Эквиваленты shell-команд

| Задача | Linux/WSL bash | Windows PowerShell |
|---|---|---|
| Переменная | `export CONAN_HOME=...` | `$env:CONAN_HOME = "..."` |
| Удалить каталог | `rm -rf "$CONAN_HOME"` | `Remove-Item -Recurse -Force $env:CONAN_HOME` |
| Запуск | `"$C2" create ...` | `& $C2 create ...` |
| Перенаправление JSON | `> graph.json` | `Out-File -Encoding utf8 graph.json` |
| Поиск в логе | `grep -q "ERROR:" log` | `Select-String -Path log -Pattern "ERROR:" -Quiet` |
| Показать файл | `cat file` | `Get-Content file` |
| Копировать | `cp -r a b` | `Copy-Item -Recurse a b` |
| Цикл | `for x in ...; do ...; done` | `foreach ($x in ...) { ... }` |
| Проверить код | `$?` | `$LASTEXITCODE` |
| JSON-парсер | `jq` | `ConvertFrom-Json` |

Для `cmd.exe`: `set VAR=value`, `%VAR%`, `rmdir /s /q`. Смешивать
`cmd.exe` и PowerShell в одном job не стоит. В Windows PowerShell 5.1
нет `&&`; используйте отдельные шаги или проверку `$?`.

### 16.6. Profile и package ID

| Платформа | `os` | Compiler | Runtime settings |
|---|---|---|---|
| Linux | `Linux` | `gcc`/`clang` | `compiler.libcxx`, `cppstd` |
| WSL | `Linux` | `gcc`/`clang` | те же, что Linux |
| Windows | `Windows` | `msvc` | `compiler.runtime`, `runtime_type`, `cppstd` |

- Один ref может иметь Linux- и Windows-пакеты одновременно. Это
  нормально; package ID у них разные.
- Не сравнивайте package ID между платформами и не переносите
  Linux-пакет в Windows-remote как «тот же».
- WSL-пакет идентичен Linux-пакету только при совпадении compiler,
  version, libcxx, cppstd, build_type и options. Совпадение ОС не
  гарантирует совпадение ID.
- C1-кэш Windows и C1-кэш WSL — разные кэши. Не используйте один
  `CONAN_USER_HOME` для обоих.
- В manifest указывайте `platform` (Conan settings) и, отдельно,
  `runner` (`linux`/`wsl`/`windows`). WSL — это `platform=linux`,
  `runner=wsl`.

### 16.7. Пакет и runtime

| Платформа | Что проверять |
|---|---|
| Linux | `.so`/`.a`, SONAME, symlink’и, RPATH/RUNPATH, `ldd`, headers, CMake config |
| WSL | то же, что Linux; `file` должен показывать ELF, а не PE32+ |
| Windows | `.dll`, `.lib`, `.pdb`, `.exe`, `.natvis`, CRT, `dumpbin /dependents`, `PATH` |

Linux/WSL:

```bash
file "$PACKAGE/lib/lib<name>.so"
readelf -d "$PACKAGE/lib/lib<name>.so"
ldd "$PACKAGE/lib/lib<name>.so"
```

Windows:

```powershell
dumpbin /dependents "$env:PACKAGE\bin\<name>.dll"
Get-ChildItem -Recurse $env:PACKAGE | Select-Object FullName
```

`dumpbin` доступен из Developer Command Prompt / VS Build Tools.
Для shared-пакетов `VirtualRunEnv` обязателен и на Linux, и на Windows:
он задаёт `LD_LIBRARY_PATH` или `PATH` для `test_package`.

### 16.8. CI и release bundle

| Runner | Shell | Conan | Кэш |
|---|---|---|---|
| Linux | bash | Linux-Conan | ext4, отдельный `CONAN_HOME` |
| WSL | bash | Linux-Conan внутри WSL | ext4, не `/mnt/c` |
| Windows | PowerShell | Windows-Conan | короткий путь, UTF-8 JSON |

Требования:

- отдельный `CONAN_HOME` на job/agent;
- ключ кэша включает OS, compiler, version, runtime и профиль;
- WSL и Windows не делят кэш;
- версия Conan и `conan config install` фиксированы;
- package lists и manifests — отдельные для каждой платформы;
- публикация и promote — только по проверенному package list.

Структура bundle — в §13.4. Для каждой платформы используйте отдельный
подкаталог (`linux-gcc-release`, `windows-msvc-release`); не смешивайте
package lists разных платформ.

### 16.9. Типовые ошибки платформ

| Симптом | Платформа | Причина | Решение |
|---|---|---|---|
| `bad interpreter: /bin/bash^M` | Linux/WSL | CRLF в скрипте | LF + `.gitattributes` |
| `conan: command not found` | WSL | Conan не установлен в дистрибутиве | установить внутри WSL |
| `file conan` → `PE32+` | WSL | запускается `conan.exe` | использовать Linux-Conan |
| `JSONDecodeError` после `>` | Windows 5.1 | UTF-16LE | `Out-File -Encoding utf8` / UTF-8 без BOM |
| `The system cannot find the path specified` | Windows | длинный путь | `LongPathsEnabled`, короткий `CONAN_HOME` |
| `LNK1104` / DLL locked | Windows | DLL занят или не в `PATH` | закрыть процесс, проверить `PATH` |
| `error while loading shared libraries` | Linux/WSL | нет RPATH/`LD_LIBRARY_PATH` | `VirtualRunEnv`, RPATH |
| `MSB8020` | Windows | нет toolset/VS | установить Build Tools, проверить profile |
| пакет есть, но `Missing binary` | все | другой package ID | сверить profile/settings/options |

### 16.10. Platform gate

Для каждой платформы отдельно:

- [ ] `conan --version` и `profile show` соответствуют платформе.
- [ ] `CONAN_HOME` чистый и находится на правильной ФС.
- [ ] `conan create` и `test_package` проходят.
- [ ] package ID совпадает с ожидаемым.
- [ ] содержимое пакета проверено платформенным инструментом.
- [ ] clean consumer ставится с `--build=never`.
- [ ] package list и manifest лежат в платформенном bundle.

Для WSL дополнительно:

- [ ] используется Linux-Conan, а не `conan.exe`;
- [ ] shell-скрипты в LF;
- [ ] `CONAN_HOME` не на `/mnt/c`.

Для Windows дополнительно:

- [ ] JSON-файлы в UTF-8, не UTF-16;
- [ ] длинные пути обработаны;
- [ ] runtime Debug/Release совпадает у пакета и потребителя;
- [ ] DLL находятся через `PATH`/`VirtualRunEnv`.

## 17. Аналитический пример: `fmt` и `fmt-recipe` в read-only копии

> `demo/fmt`, `demo/fmt-recipe` и `demo/conan-thirdparty-index` — копии
> реальных проектов только для чтения и анализа. Это не target миграции:
> не редактируйте их, не запускайте в них сборку и не коммитьте изменения.
> Для проверки рецепта используйте отдельную рабочую копию.

В `demo/` лежат два каталога:

```text
demo/
  fmt/           # исходники fmt
  fmt-recipe/    # Conan-рецепт, patches, test_package
```

Это распространённый layout «source рядом с recipe». Для Conan это всё
ещё **один recipe folder**: `conan export demo/fmt-recipe` видит только
содержимое `fmt-recipe`, а не соседний `demo/fmt`.

### 17.1. Проверить версии до порта

В анализируемой копии:

- `demo/fmt` — fmt 12.2.1 (`FMT_VERSION 120201`);
- `demo/fmt-recipe/conandata.yml` — version `7.1.3`, git URL и commit;
- `demo/fmt-recipe/conanfile.py` — C1 (`from conans`);
- `source()` клонирует git, а не использует `demo/fmt`;
- `patches/` рассчитаны на 7.1.3;
- `package()` ищет `LICENSE.rst`, а в `demo/fmt` лежит `LICENSE`;
- `test_package` — C1 (`conanbuildinfo.cmake`, `CONAN_PKG::fmt`).

Это две разные задачи:

1. портировать рецепт на C2 API;
2. решить, какую версию source он собирает.

Если запустить C2 `conan create demo/fmt-recipe` прямо в read-only копии,
рецепт упадёт на C1-импортах, а сборка может создать рабочие каталоги
рядом с оригиналом. Сначала сделайте рабочую копию. Если заменить только
импорты, но оставить `conandata.yml`, рецепт продолжит собирать 7.1.3,
а не локальный 12.2.1.

### 17.2. Выбрать источник

| Вариант | Когда использовать | Что менять |
|---|---|---|
| Оставить 7.1.3 | нужен паритет с C1 | только C2 API; patches не трогать |
| Перейти на 12.2.1 | нужна версия из `demo/fmt` | `version`, URL/commit, patches, тесты |
| Локальный source | нужна сборка именно `demo/fmt` | source нужно доставить в recipe folder |

Для локального source не полагайтесь на `../fmt`: `exports_sources`
относительны папки рецепта. Варианты:

- скопировать/смонтировать source в `fmt-recipe/source` и добавить его в
  `exports_sources`;
- использовать `source()` с локальным git-репозиторием и пином commit;
- использовать `local-recipes-index` только для рецепта, но source всё
  равно должен быть доступен сборке.

### 17.3. Минимальный C2-порт

1. `from conan import ConanFile`.
2. `from conan.tools.cmake import CMake, CMakeToolchain, CMakeDeps, cmake_layout`.
3. `from conan.tools.files import copy, rmdir`.
4. `layout()` → `cmake_layout(self)`.
5. `generate()` → `CMakeToolchain(self)`, `CMakeDeps(self)`.
6. `build()` → `CMake(self)`.
7. `package()` → `cmake.install()`, `copy()` для `LICENSE`, `rmdir()`
   для нежелательных `lib/cmake`/`lib/pkgconfig`, если это политика
   пакета.
8. `package_info()` → `self.cpp_info`; `user_info` заменить на
   `conf_info` только если есть реальный потребитель.
9. `package_id()` → `self.info.clear()` для header-only; не удалять
   несуществующие options.
10. `test_package` → `CMakeToolchain`/`CMakeDeps`, target
    `fmt::fmt`, `VirtualRunEnv` для shared.

Для header-only варианта:

```python
def package_id(self):
    if self.options.header_only:
        self.info.clear()
```

В C1-рецепте также есть `del self.info.options.with_fmt_alias`, хотя
такой option не объявлен. При порте это нужно убрать или объявить option
осознанно.

### 17.4. Команды

Команды ниже — после порта рецепта на C2 API; на текущем C1-рецепте
`conan export` из C2 упадёт на `from conans`. Работайте только в копии:

```bash
export C2=/path/to/conan2/bin/conan
export WORK=/tmp/fmt-migration
export PROFILE_HOST=profiles/linux-gcc-release
export PROFILE_BUILD=profiles/linux-gcc-release

rm -rf "$WORK"
mkdir -p "$WORK"
cp -a demo/fmt-recipe "$WORK/fmt-recipe"
# Если нужен локальный source, скопируйте и его:
# cp -a demo/fmt "$WORK/fmt"

"$C2" export "$WORK/fmt-recipe"
"$C2" cache path "fmt/7.1.3" --folder=export_source

"$C2" graph info "$WORK/fmt-recipe" --build=missing \
  -pr:h "$PROFILE_HOST" -pr:b "$PROFILE_BUILD" \
  2>&1 | tee /tmp/fmt-graph.log

"$C2" create "$WORK/fmt-recipe" --build=missing \
  -pr:h "$PROFILE_HOST" -pr:b "$PROFILE_BUILD"
```

Для Windows используйте `& $C2`, `Copy-Item -Recurse` и
PowerShell-эквиваленты из §16.4. Не запускайте эти команды в
`demo/fmt-recipe`: это read-only копия.

### 17.5. Gate для этого layout

- версия source и `conandata.yml` согласованы;
- `export_source` содержит нужные patches/CMake wrapper, а не только
  `conanfile.py`;
- `source()` не зависит от `../fmt` и не требует ручной раскладки;
- patches применяются к выбранной версии;
- `test_package` собирает `fmt::fmt`, а не `CONAN_PKG::fmt`;
- package ID для header-only и compiled-вариантов различаются ожидаемо;
- Linux/WSL и Windows package lists не смешиваются.

## 18. Связанные разделы runbook

- §0.1 — greenfield/brownfield;
- §3.5–3.6 — discovery при большом объёме;
- §4.6 — старый и новый Artifactory рядом;
- §6.5 — существующие C1-пакеты;
- §7.7 — подводные камни рецептов;
- §8.4 — волны и матрица;
- §9.5.3–9.5.6 — lockfile, package list, promote, compatibility;
- §9.6 — публикация при большом объёме;
- §10.4–10.5 — cutover и rollback;
- §12.6 — платформы и runtime;
- §13 — чек-листы.
