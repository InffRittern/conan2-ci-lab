# Миграция Conan 1.x → Conan 2.x: runbook для реальных проектов

## 0. Назначение и границы

Документ описывает переход проекта с Conan 1.x на Conan 2.x: хранилище,
рецепты, CI, потребители и cutover. Он рассчитан на реальный проект, где
есть несколько библиотек, продуктов, платформ и CI-пайплайнов, а не только
на демонстрационный стенд.

Проверено на стенде: Artifactory CE `7.161.26`, Conan `1.66.0`,
Conan `2.33.0`, Linux/GCC 13; сценарии `01–09` пройдены. Команды и
ограничения, специфичные для стенда, вынесены в приложение; в основном
тексте используются параметры.

### 0.1. Два режима миграции

| Режим | Что уже есть | Главное отличие |
|---|---|---|
| Sandbox / greenfield | пустые target-репозитории, один продукт | можно пересобрать всё и сравнить с эталоном |
| Brownfield | существующий Artifactory CE с тысячами refs и package ID, работающие C1-consumers | нельзя останавливать всё; мигрируют только используемое, волнами |

Для brownfield этот runbook дополняют §3.5, §4.6, §6.5, §8.4 и §9.6.
Главное правило не меняется: **C1-хранилище остаётся рабочим до
завершения cutover**. Но «адаптировать пакеты» здесь означает
«портировать рецепт и пересобрать бинарник», а не «скопировать C1-файлы
в C2-репозиторий».

### 0.2. Read-only копии реальных проектов

Каталоги `demo/fmt`, `demo/fmt-recipe` и `demo/conan-thirdparty-index` —
копии реальных проектов для анализа. Это **не target миграции** и не
baseline. Они нужны, чтобы вывести алгоритм и проверить runbook на
реальных версиях, layout и ошибках.

Правила:

- не редактировать, не форматировать, не патчить и не коммитить копии;
- не запускать `conan export`, `conan create`, `conan install` внутри
  копий: появятся build-каталоги и изменённое состояние;
- для проверки сборки копировать рецепт/source в отдельный `$WORK`;
- в inventory фиксировать происхождение копии: путь, версию, commit/URL
  source, версию рецепта и дату снимка;
- выводы из копии — это evidence для discovery, а не подтверждение
  production-состояния.

Что извлекать из копий:

| Артефакт | Что проверить |
|---|---|
| source | версия, commit, лицензия, CMake-опции, требования к компилятору |
| C1-рецепт | API, `exports_sources`, `source()`, patches, options, `package_info`, `package_id` |
| C2-рецепт | `package_type`, `layout`, generators, `package_info`, test_package |
| index | `config.yml` vs `conandata.yml`, наличие `sources`, URL/credentials, наличие `.git` |
| diff | смена options, package ID, target names, runtime |

После анализа изменения вносятся только в рабочую копию или target-репозиторий,
а не в `demo/`. Практический разбор layout `fmt`/`fmt-recipe` — в
`migration-algorithm.md`, §17.


Документ покрывает:

- инвентаризацию Conan 1 и потребителей;
- массовую инвентаризацию существующего Artifactory и migration backlog;
- проектирование target-хранилища и remotes;
- freeze, backup и rollback;
- миграцию рецептов с C1 API на C2 API;
- пересборку бинарников и проверку package ID;
- пересборку волнами по dependency DAG;
- staged-публикацию и promote;
- переключение CI, разработчиков и потребителей;
- decommission старого хранилища.

Документ не покрывает:

- перенос Git-истории, Jenkins jobs, webhooks и SCM;
- миграцию generic-артефактов;
- изменение бизнес-логики приложений;
- автоматическую конвертацию C1-рецептов в C2: официального конвертера
  нет, рецепты портируются и проверяются сборкой;
- автоматический перенос C1-бинарников в C2: package ID не совпадают,
  бинарники нужно пересобрать.

Главное правило: **C1-хранилище и C2-хранилище существуют параллельно до
завершения cutover**. C1 остаётся доступным для rollback, C2 наполняется
новыми сборками. Не перезаписывайте C1-пакеты C2-рецептами.

## 1. Переменные и соглашения

Перед началом зафиксируйте имена. Все примеры ниже используют эти
переменные; для реального проекта подставьте свои значения.

> Имена `example-*`, `source-*` и `my-*` — абстрактные placeholders.
> Публичные библиотеки и инструменты (`fmt`, `catch2`, `hiredis`,
> `cpp_redis`, `sfl`, `cmake`, `ninja`) оставлены как узнаваемые примеры
> и не относятся к внутренним пакетам проекта.

| Переменная | Пример | Назначение |
|---|---|---|
| `ARTIFACTORY_URL` | `https://artifactory.example.com` | базовый URL Artifactory |
| `ARTIFACTORY_USER` | `svc-conan-ci` | сервисная учётная запись |
| `ARTIFACTORY_PASSWORD` | из CI secret | пароль; не хранить в репозитории |
| `C1` | `/opt/conan1/bin/conan` | бинарь Conan 1 |
| `C1_HOME` | `/tmp/conan1-home` | `CONAN_USER_HOME` для C1 |
| `C2` | `conan` | бинарь Conan 2 |
| `C2_HOME` | `/tmp/conan2-home` | `CONAN_HOME` для C2 |
| `C1_REMOTES` | `source-local source-libs source-thirdparty source-all` | source-remotes C1 |
| `C1_PROFILE` | `profiles/linux-gcc-release` | профиль C1; может отличаться от C2 |
| `C2_PACKAGES` | `packages` | LOCAL-репозиторий библиотек |
| `C2_PRODUCTS` | `products` | LOCAL-репозиторий продуктов |
| `C2_DEVELOP` | `develop` | LOCAL-репозиторий стабильных сборок |
| `C2_VIRTUAL` | `conan2` | VIRTUAL-агрегатор для потребителей |
| `C2_EXTERNAL` | `conancenter` | внешний remote или его зеркало |
| `PROFILE_LINUX_RELEASE` | `profiles/linux-gcc-release` | профиль Linux Release |
| `PROFILE_LINUX_DEBUG` | `profiles/linux-gcc-debug` | профиль Linux Debug |
| `PROFILE_WINDOWS_RELEASE` | `profiles/windows-msvc-release` | профиль Windows Release |
| `PRODUCT_REF` | `my-product/1.0.0` | пример ref продукта для команд |

Соглашения:

- **source** — C1-репозитории, из которых переносится baseline;
- **target** — C2-репозитории, в которые пересобираются пакеты;
- **pref** — `name/version#recipe_revision:package_id`;
- **package revision** — ревизия конкретного бинарника; нужна для точного
  rollback;
- **freeze** — запрет публикации в source на время cutover;
- **promote** — перенос проверенного пакета из staging в стабильный
  репозиторий.

### 1.1. Решения, которые нужно принять до старта

| Решение | Варианты | Рекомендация |
|---|---|---|
| Стратегия | big bang или параллельный target | параллельный target; C1 read-only на время cutover |
| Порядок | все сразу или leaf-first | leaf-first: build tools → библиотеки → продукты |
| Ref-политика | сохранить `user/channel` или перейти на чистые refs | сохранить на время миграции; менять отдельно |
| Внешние зависимости | ConanCenter, зеркало, приватный форк | зеркало/форк, если нужна воспроизводимость и контроль |
| Package ID | оставить текущие options/settings или менять | не менять одновременно с миграцией |
| Платформы | Linux only или Linux + Windows + macOS | явно зафиксировать матрицу до пересборки |
| Lockfile-политика | ranges в рецептах или lock в CI | ranges для разработки, lock + package list для CI |
| Окно rollback | дни или недели | не удалять source до истечения окна и проверки rollback |

## 2. Этапы миграции

| Этап | Результат | Gate |
|---|---|---|
| 0. Discovery | inventory рецептов, пакетов, потребителей, платформ и CI | все refs и владельцы известны |
| 1. Target design | созданы репозитории, remotes, права, virtual-агрегатор | потребитель видит тестовый пакет через target |
| 2. Freeze и backup | source заморожен, backup проверен восстановлением | restore test пройден |
| 3. C1 baseline | C1-пакеты собраны и сохранены точными pref | manifest совпадает с inventory |
| 4. Recipe migration | рецепты переведены на C2 API, test_package обновлён | матрица рецептов зелёная |
| 5. C2 rebuild | бинарники пересобраны в чистом C2 home | package ID и lockfile зафиксированы |
| 6. Staged publish | библиотеки и продукты опубликованы наборами | manifest и верификация зелёные |
| 7. Consumer/CI cutover | CI и потребители переключены на C2 | clean consumer и rollback проверены |
| 8. Decommission | source переведён в read-only/архив | окно rollback закрыто |

Не переходите к следующему этапу, пока не выполнен gate предыдущего.
Особенно это касается этапов 4–6: ошибка в рецепте или package ID
проявится позже, когда пересборка уже потратит время CI.

Для brownfield gate discovery — не «выгружены все refs», а «каждый
используемый ref классифицирован и имеет решение». Полный storage может
содержать тысячи неиспользуемых версий; они не должны блокировать
пересборку.

## 3. Этап 0. Discovery

### 3.1. Что собрать

1. **Рецепты и refs.** Все `name/version@user/channel`, которые
   публикуются или потребляются.
2. **Ревизии.** Recipe revision и package ID; package revision — если нужен
   точный rollback.
3. **Потребители.** Репозитории, `conanfile.py`/`conanfile.txt`, CI jobs,
   Docker-образы, разработчики.
4. **Remotes.** C1 local/virtual, ConanCenter, приватные форки.
5. **Профили.** OS, arch, compiler, version, libcxx, cppstd, build_type,
   runtime, CMake generator.
6. **Options.** Все варианты, которые влияют на package ID и ABI.
7. **Платформы.** Linux, Windows, macOS, cross-build, Docker/CI agents.
8. **Внешние зависимости.** Какие пакеты берутся из ConanCenter, какие
   зеркалируются, какие нельзя скачивать извне.
9. **CI/CD.** Где собирается, где хранится кэш, кто публикует, какие
   credentials используются.
10. **Владельцы.** Кто отвечает за рецепт, продукт, CI и Artifactory.

### 3.2. Инвентаризация Conan 1

```bash
export CONAN_USER_HOME="$C1_HOME"
export CONAN_REVISIONS_ENABLED=1

$C1 --version
$C1 remote list
$C1 profile list
```

Добавьте source-remotes и войдите под сервисной учётной записью:

```bash
for r in $C1_REMOTES; do
  $C1 remote add "$r" \
    "$ARTIFACTORY_URL/artifactory/api/conan/$r"
  $C1 user -p "$ARTIFACTORY_PASSWORD" -r "$r" "$ARTIFACTORY_USER"
done
```

Снимите список refs:

```bash
for r in $C1_REMOTES; do
  echo "== $r"
  $C1 search "*" -r "$r"
done > /tmp/conan1-inventory.txt
```

Для каждого ref снимите ревизии отдельно:

```bash
# Для каждого ref и remote, где он найден:
$C1 search "$ref" --revisions \
  --json "/tmp/revisions-${repo}-${ref//\//_}.json" -r "$repo"
```

В Conan 1.66 wildcard с `--revisions` завершается ошибкой
`With --revision, specify a reference`; ревизии снимайте только по
конкретному ref. Вывод `conan search` не показывает package revision —
для точного переноса используйте manifest из кэша.

### 3.3. Выходные артефакты discovery

- `conan1-inventory.txt` — refs по remotes;
- `conan1-revisions.json` — recipe revisions;
- `conan1-prefs.txt` — `repo|ref|rrev|pkgid`;
- карта потребителей;
- матрица профилей и платформ;
- список внешних зависимостей;
- список CI jobs и credentials;
- ответственные за каждый ref;
- `migration-backlog.jsonl` — классификация и решение по каждому ref;
- `blocked-no-source.txt` — пакеты без рецепта/исходников;
- `package-id-map.csv` — ожидаемый и фактический package ID после пересборки.

### 3.4. Подводные камни discovery

- **Virtual remotes скрывают источник.** `conan search -r conan` может
  включать ConanCenter; для инвентаря используйте local-репозитории и
  явные refs.
- **Package revision не видна в `search`.** Без manifest точный rollback
  невозможен.
- **C1-кэш уже загрязнён.** В нём могут быть неудачные версии, которые
  влияют на version range. Для инвентаря это не критично, для пересборки —
  критично.
- **Один ref может публиковаться из нескольких CI jobs.** Зафиксируйте
  владельца, иначе после cutover будет гонка публикаций.
- **ConanCenter нестабилен как источник истины.** Для production лучше
  зеркало или приватный форк.

### 3.5. Discovery при тысячах пакетов в существующем Artifactory

Если source уже содержит тысячи refs и package ID, задача discovery — не
выгрузить всё подряд, а получить **migration backlog**: что используется,
что можно архивировать, что блокировано отсутствием исходников.

Порядок:

1. **Зафиксируйте снимок.** Freeze на время crawl или хотя бы запишите
   timestamp начала и конца. Иначе refs, опубликованные во время обхода,
   попадут в отчёт непредсказуемо.
2. **Соберите кандидатов через Artifactory AQL.** AQL быстрее, чем обход
   каждого remote через Conan, но AQL-выборка — только кандидаты.
3. **Подтвердите refs через Conan 1.** Для каждого remote и ref возьмите
   recipe revision и package ID. AQL не заменяет `conan search` и не
   показывает package revision.
4. **Свяжите refs с потребителями.** CI jobs, `conanfile.py`/`.txt`,
   lockfiles, Docker-образы, продуктовые репозитории.
5. **Классифицируйте каждый ref и примите решение.** Не начинайте
   пересборку, пока у каждого ref нет владельца и решения.

Пример постраничной AQL-выборки кандидатов:

```bash
offset=0
while :; do
  curl -sS -u "$ARTIFACTORY_USER:$ARTIFACTORY_PASSWORD" \
    -H 'Content-Type: text/plain' \
    "$ARTIFACTORY_URL/artifactory/api/search/aql" \
    --data-binary "items.find({\"repo\":\"source-local\",\"type\":\"file\",\"name\":\"conanmanifest.txt\"})
      .include(\"repo\",\"path\",\"size\",\"modified\")
      .offset(${offset}).limit(1000)" \
    > "/tmp/aql-source-local-${offset}.json"
  [ "$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["results"]))' \
    "/tmp/aql-source-local-${offset}.json")" -lt 1000 ] && break
  offset=$((offset + 1000))
done
```

Проверьте на одном repo, что путь/маркер действительно соответствует
вашей раскладке. В Conan 1 и Conan 2 служебные файлы могут отличаться;
AQL-фильтр — эвристика, истина — вывод Conan-клиента.

Минимальная модель записи на один ref:

```text
repo | ref | recipe_revision | package_id | settings | options |
requires | size | last_modified | evidence_of_use | consumers | owner | decision
```

Не храните тысячи записей в одном JSON: шардируйте по repo и префиксу
ref, например `inventory/<repo>/<first-letter>.jsonl`. Один большой файл
тяжело мержить и невозможно безопасно обновлять инкрементально.

Классификация:

| Класс | Признак | Решение |
|---|---|---|
| Internal, source есть | рецепт и исходники в Git | портировать рецепт, пересобрать |
| External из ConanCenter | версия есть в CCI | взять C2-рецепт/remote, пересобрать |
| Patched external | локальный патч/опция | приватный форк или vendored source |
| Binary-only | есть package, нет рецепта/исходников | блокер: upstream source, vendor или оставить C1-only |
| Unused | нет потребителей и загрузок | архив, не мигрировать |
| Build tool / toolchain | cmake, ninja, компиляторы | волна 0 |

Единица миграции — **ref + конфигурация потребителя**, а не каждый
исторический package ID. Тысячи бинарников в C1 не означают, что все
тысячи нужно пересобрать: matrix строится из фактических потребителей и
поддерживаемых платформ. Если данных об использовании нет, не угадывайте:
берите dependency closure продуктов и CI jobs.

### 3.6. Подводные камни discovery при большом объёме

- **AQL-выборка неполная.** `limit` без пагинации молча обрежет результат;
  проверяйте, что последняя страница короче лимита.
- **Один ref в нескольких repo.** Virtual `conan` скрывает источник;
  инвентаризируйте LOCAL-репозитории.
- **Исторические версии.** Тысячи версий не равны тысячам нужных версий;
  фиксируйте потребителей, а не только содержимое storage.
- **C1 lockfile не является C2 lockfile.** Формат и разрешение другие;
  потребительские lockfiles придётся пересоздать.
- **Нет исходников.** Если пакет пришёл только бинарником, «адаптировать»
  его нельзя; это отдельный риск и отдельный owner.

## 4. Этап 1. Проектирование target

### 4.1. Топология репозиториев

Минимальная схема:

| Репозиторий | Тип | Назначение | Кто пишет |
|---|---|---|---|
| `packages` | LOCAL | библиотеки, build tools, внешние зеркала | CI библиотек |
| `products` | LOCAL | продукты и staging | CI продуктов |
| `develop` | LOCAL | стабильные сборки для потребителей | promote |
| `conan2` | VIRTUAL | единая точка чтения | никто |
| `legacy` | LOCAL, опционально | аудит C1-pref | только C1 |

Virtual `conan2` обязателен: Conan 2 разрешает зависимости в рамках одного
remote, через который найден корневой рецепт. Если `conan2` агрегирует
только `products`, но не `packages`, продукт не увидит библиотеки.

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

Если проект использует ConanCenter, добавьте его в `conan2` или в
отдельный remote, который видят потребители. Иначе `fmt`, `catch2`,
`cmake` и другие внешние зависимости не разрешатся.

### 4.2. Ref-политика и package ID

- Сохраните `user/channel` на время миграции, если потребители уже
  используют такие refs.
- Не меняйте одновременно `settings`, `options`, `package_type` и
  `user/channel`: иначе вырастет число package ID и станет невозможно
  понять, что именно сломалось.
- Зафиксируйте, какие options входят в package ID, а какие являются
  build-only.
- Для shared/static, Debug/Release, runtime и cppstd заранее определите,
  какие конфигурации обязательны, а какие — опциональны.

### 4.3. Внешние зависимости

Для каждой внешней зависимости выберите:

1. **ConanCenter напрямую** — просто, но зависит от доступности и
   ревизий.
2. **Зеркало в `packages`** — контролируемо, но нужно поддерживать.
3. **Приватный форк** — нужно, если внешний пакет патчится или нужна
   изоляция.

Если target `conan2` не содержит ConanCenter, `--build=missing` не поможет:
рецепт просто не будет найден. Это частая причина падения `sfl`-подобных
рецептов с `fmt`/`catch2`.

### 4.4. Права, retention и безопасность

- Сервисная учётная запись Artifactory, не `admin`.
- CI пишет только в `packages`/`products`, promote — отдельная роль.
- Потребители читают только `conan2`.
- Включите retention/quota, чтобы staging и старые pre-release не росли
  бесконечно.
- Не передавайте Gitea-токены в Artifactory и наоборот.
- Проверьте TLS и корпоративные сертификаты на агентах.

### 4.5. Подводные камни target design

- **Один remote не видит другой.** Conan 2 не ищет зависимости по всем
  remotes; используйте virtual-агрегатор.
- **`conan2` без external remote.** Локальные пакеты найдутся, внешние —
  нет.
- **Права на virtual.** Потребителю не нужен write в `conan2`.
- **Artifactory CE не умеет всё.** Нет `DELETE /api/repositories/<key>`,
  нет транзакционного `conan art:promote`; используйте PATCH и manifest.
- **`conan-remote-cache` — не репозиторий.** Это узел кэша remote в UI;
  в `/api/repositories` его нет.
- **`artifactory-build-info` зарезервирован.** PATCH с этим именем
  вернёт 400.
- **Дубли refs в target-репозиториях.** Если один ref есть в `products`
  и `develop`, `conan2` может выбрать не тот; не публикуйте один ref в
  двух местах без явной политики.

### 4.6. Brownfield: старый и новый Artifactory рядом

Если source уже работает, не переименовывайте и не переиспользуйте его
под C2. Схема:

| Хранилище | Режим | Клиент |
|---|---|---|
| существующие `source-local`, `source-libs`, `source-all` и их virtual | read-only на время cutover | C1 |
| новые `packages`, `products`, `develop` | read/write | C2 |
| новый virtual `conan2` | read-only для потребителей | C2 |

Правила:

- **Не загружайте C2-рецепты в C1-репозиторий.** C1-клиент увидит
  несовместимый рецепт и упадёт; C1 и C2 layout/API различаются.
- **Не добавляйте старый C1-virtual в `conan2`.** Иначе C2-граф может
  найти C1-рецепт, который не импортируется.
- **Не удаляйте старые репозитории.** Это rollback и аудит.
- **Не делайте `conan2` агрегатором C1.** Virtual собирается только из
  C2 target-репозиториев; внешний C2-remote подключается отдельно.
- **Разделяйте права.** C2 CI пишет в `packages`/`products`; promote —
  отдельная роль; потребитель читает только `conan2`.
- **Учитывайте storage.** C1 и C2-бинарники сосуществуют; планируйте
  retention и квоты до массовой пересборки, а не после.

Если в Artifactory уже есть виртуальный `source-all`, который агрегирует
C1-репозитории, создайте отдельный `conan2`. Переиспользование имени
приведёт к тому, что часть клиентов получит несовместимый набор.

## 5. Этап 2. Freeze и backup

### 5.1. Freeze

1. Объявите окно freeze для source.
2. Остановите публикацию из всех CI jobs, а не только из основного.
3. Запретите разработчикам `conan upload` в source.
4. Зафиксируйте, кто может снять freeze и по какой причине.

### 5.2. Backup

- Backup Artifactory: БД + filestore.
- Проверьте восстановление на отдельном инстансе, а не только наличие
  архива.
- Сохраните inventory, manifests, profiles и remotes.
- Сохраните package list для критичных продуктов.
- Проверьте, что backup не содержит незавершённых upload.

### 5.3. Подводные камни freeze/backup

- CI job, который публикует в source, забыли остановить.
- Backup есть, но restore не проверен.
- Freeze не распространили на разработчиков.
- Source удалили до истечения окна rollback.
- В inventory попали только `name/version`, но не revisions.

## 6. Этап 3. C1 baseline

### 6.1. Сборка source-пакетов

Порядок обязателен из-за зависимостей. Для реального проекта постройте
граф и зафиксируйте порядок:

```text
build-tools
headers
base libraries
middleware libraries
sdk
products
```

Пример для одной библиотеки:

```bash
cd path/to/library
$C1 create . --build=missing -pr "$C1_PROFILE"
```

Не передавайте второй positional reference (`conan create . name/version`):
в Conan 1 это может создать ref вида `name/version@name/version`. Версию
задавайте через `set_version()` или переменную окружения рецепта.

Если у библиотеки несколько версий, соберите каждую явно:

```bash
# имя переменной версии зависит от рецепта; ниже — пример
PROJECT_VERSION=1.0.0 $C1 create . --build=missing -pr "$C1_PROFILE"
PROJECT_VERSION=1.1.0 $C1 create . --build=missing -pr "$C1_PROFILE"
```

### 6.2. Загрузка точных pref

Загружайте точный pref, а не только `name/version`:

```bash
upload_pref() {
  repo="$1"
  ref="$2"
  rrev=$($C1 search "$ref" --revisions -r "$repo" |
    grep -oE '#[0-9a-f]{32}' | head -1 | tr -d '#')
  [ -n "$rrev" ] || { echo "no revision: $ref" >&2; return 1; }

  ref_path="${ref%@*}"
  user_channel="${ref#*@}"
  if [ "$user_channel" = "$ref" ]; then
    user="_"; channel="_"
  else
    user="${user_channel%/*}"; channel="${user_channel#*/}"
  fi
  base="$C1_HOME/.conan/data/${ref_path%/*}/${ref_path#*/}"
  base="$base/$user/$channel/package"
  [ -d "$base" ] || { echo "no package dir: $base" >&2; return 1; }
  for pkgid in $(find "$base" -mindepth 1 -maxdepth 1 \
      -type d -printf '%f\n'); do
    echo "$ref#$rrev:$pkgid -> $repo"
    $C1 upload "$ref#$rrev:$pkgid" -r "$repo" --confirm
  done
}
```

Загружайте в LOCAL-репозитории; virtual-репозитории только агрегируют их
для чтения.

### 6.3. Audit-репозиторий `legacy` (опционально)

`legacy` нужен для аудита и rollback исходных C1-бинарников. **Не
загружайте legacy в `packages`/`products`**: C1-рецепт может стать latest
и перекрыть C2-рецепт.

Перенос должен выполнять Conan 1: Conan 2 не загружает старые рецепты с
`from conans import ConanFile` (`ImportError: cannot import name
'ConanFile' from 'conans'`), причём команда может вернуть exit code `0`.
Проверяйте вывод, а не только код возврата.

### 6.4. Подводные камни C1 baseline

- **`conan search` не показывает package revision.** Нужен manifest.
- **Virtual remote не источник истины.** Для upload используйте LOCAL.
- **`CONAN_REVISIONS_ENABLED=1` обязателен** для virtual `conan`.
- **C1-рецепт нельзя собрать в C2.** Точный pref можно скачать для аудита,
  но не для сборки.
- **C1-бинарники не переиспользуются.** Package ID в C2 другой.
- **`conan upload` может вернуть 0 при ошибке.** Проверяйте наличие
  пакета в JSON/manifest.
- **`find -printf` — GNU find.** На macOS/BSD используйте
  `-exec basename {} \;`.

### 6.5. Если C1-пакеты уже лежат в Artifactory

Для brownfield C1 baseline уже существует. Не копируйте его бинарники в
C2-репозитории и не пытайтесь выдать за C2-пакеты: C2 не загрузит
C1-рецепт, а package ID и раскладка могут не совпасть.

Что делать:

1. **Оставьте C1-пакеты на месте.** Source-репозиторий — эталон для
   аудита и rollback. Зафиксируйте его inventory и переведите в
   read-only после freeze.
2. **Снимите точный manifest.** Для используемых refs сохраните recipe
   revision, package ID и, если доступно, package revision. Одного
   `name/version` недостаточно.
3. **Для каждого ref выберите путь:**

   | Условие | Действие |
   |---|---|
   | рецепт и исходники доступны | портировать рецепт, пересобрать |
   | версия есть в ConanCenter | взять C2-рецепт из CCI, пересобрать |
   | пакет пропатчен | приватный форк/локальный индекс рецептов |
   | только бинарник, исходников нет | upstream source, vendor или оставить C1-only |
   | потребителей нет | архивировать, не мигрировать |

4. **Не создавайте `legacy`-копию без необходимости.** Если C1-пакеты уже
   в Artifactory, отдельный `legacy` только удвоит storage. `legacy`
   оправдан, если нужно изолировать аудит от рабочего C1-репозитория.
5. **Пересоздайте consumer lockfiles.** C1 lockfile несовместим с C2;
   после миграции продукта его lockfile и package list создаются заново.

Если пакет существует только как бинарник, это **блокер миграции**, а не
задача «переупаковать». Зафиксируйте его в отдельном списке
`blocked-no-source` и не включайте в зелёный gate.

## 7. Этап 4. Миграция рецептов

Этот этап runbook для хранилища обычно пропускает, но для реального
проекта он обязателен. Без него `--build=missing` пересоберёт C1-рецепты
и упадёт или соберёт не то.

### 7.1. Карта API C1 → C2

| Conan 1 | Conan 2 |
|---|---|
| `from conans import ConanFile` | `from conan import ConanFile` |
| `conans.CMake` | `conan.tools.cmake.CMake` |
| `conans.tools` | `conan.tools.files`, `conan.tools.scm`, `conan.tools.env` |
| `imports()` + `self.copy()` | `generate()` + `conan.tools.files.copy()` |
| `self.deps_cpp_info` | `self.dependencies` |
| `self.env_info` | `VirtualRunEnv`, `self.buildenv`, `self.runenv` |
| `self.user_info` | `self.conf_info` |
| `generators = "cmake"` | `CMakeToolchain` + `CMakeDeps` |
| `generators = "cmake_multi"` | `CMakeToolchain` + multi-config |
| `generators = "json"` | `conan graph info --format=json` или custom generator |
| `self.cpp_info` в `package_info()` | `self.cpp_info` / `self.cpp.package` |
| `test_package` C1 | `test_package` C2 с `CMakeToolchain`/`CMakeDeps` |

### 7.2. Чек-лист рецепта

1. Импорты только из `conan.*`; нет `conans`.
2. Нет `imports()`, `self.copy()`, `deps_cpp_info`, `env_info`,
   `user_info`.
3. `layout()` задаёт source/build/package; для CMake —
   `cmake_layout(self)`.
4. `generate()` создаёт `CMakeToolchain`, `CMakeDeps`,
   `VirtualBuildEnv`; для тестов/рантайма — `VirtualRunEnv`.
5. `build()` использует `CMake`; тесты запускаются через `cmake.test()`
   или CI.
6. `package()` использует `cmake.install()` и `copy()`; лицензии и
   ресурсы копируются явно.
7. `package_info()` заполняет `self.cpp_info`, а не `deps_cpp_info`.
8. `export()`/`source()` используют `Git`, `update_conandata`, commit.
9. `test_package` переписан на C2 и проверяет линковку/запуск.
10. Проверены options, package ID, components и target names.
11. `package_type` задан: `shared-library`, `static-library`,
   `header-library` или `application`.
12. `cmake_file_name`/`cmake_target_name` заданы, если потребитель
   использует `find_package()`.

Пример для CMake-потребителя:

```python
class MyLibConan(ConanFile):
    name = "my-lib"
    version = "1.0.0"
    package_type = "shared-library"

    def package_info(self):
        self.cpp_info.set_property("cmake_file_name", "MyLib")
        self.cpp_info.set_property("cmake_target_name", "My::Lib")
        self.cpp_info.libs = ["mylib"]
```

### 7.3. Типовые ошибки C2-рецепта

| Симптом | Причина | Решение |
|---|---|---|
| `ImportError: cannot import name 'ConanFile' from 'conans'` | C1-рецепт | переписать импорт на `conan` |
| distribution пустой, ошибок нет | C2 не вызывает `imports()` | перенести копирование в `generate()` |
| `AttributeError: 'ConanFile' object has no attribute 'copy'` | C1 `self.copy` | `copy(self, pattern, src, dst)` |
| `AttributeError: deps_cpp_info` | C1 API | `self.dependencies.host.values()` |
| `Invalid generator 'json'` | C1 generator | `conan graph info --format=json` |
| ресурсы зависимости не копируются | C2 `resdirs` по умолчанию `[]` | задать `self.cpp_info.resdirs = ["res"]` |
| тесты не находят `.so`/`.dll` | нет runtime env | `VirtualRunEnv(self).generate()` |
| editable-пакет указывает не туда | override `cpp.build.libdirs`/`bindirs` | проверить фактические output dirs CMake |
| natvis не найден в cache | `recipe_folder` в `layout()` | использовать `package_folder` в `package_info()` или `source_folder` в `generate()` |
| package ID не меняется, хотя тесты влияют на бинарник | `del self.info.options.build_tests` | проверить, не меняет ли опция библиотеку |
| CMake-таргет называется иначе | нет `cmake_target_name` | задать property в `cpp.package`/`cpp.build` |

### 7.4. Distribution/consumer-рецепт

Для рецепта, который собирает дистрибутив из зависимостей, `imports()`
нужно полностью заменить:

```python
import os
from conan import ConanFile
from conan.tools.files import copy

class DistributionConan(ConanFile):
    settings = "os", "arch", "compiler", "build_type"

    def layout(self):
        self.folders.build = "build"

    def generate(self):
        dest = os.path.join(self.build_folder, "dist")
        for dep in self.dependencies.host.values():
            for src in dep.cpp_info.bindirs:
                copy(self, "*.dll", src, os.path.join(dest, "bin"))
            for src in dep.cpp_info.libdirs:
                copy(self, "*.so*", src, os.path.join(dest, "lib"))
            for src in dep.cpp_info.resdirs:
                copy(self, "*", src, os.path.join(dest, "share"))
            copy(self, "*",
                 os.path.join(dep.package_folder, "licenses"),
                 os.path.join(dest, "licenses"))
```

Правила:

- `self.dependencies["name"]` бросает `KeyError`, если зависимости нет;
  для опциональных используйте `if "name" in self.dependencies`.
- `copy()` по умолчанию `keep_path=True` и `ignore_case=True`; для Linux
  case-sensitive копирования задайте `ignore_case=False`.
- Не используйте `folder=True`: такого параметра нет.
- Для лицензий копируйте содержимое `licenses`, а не создавайте
  `licenses/licenses`.
- `generators = "json"` замените на `conan graph info --format=json` или
  собственный generator; в C2 такого generator нет.

### 7.5. test_package

`conan create` запускает `test_package` по умолчанию; не отключайте его в
CI без причины. `test_package` — это отдельный потребитель. Он должен:

- использовать `CMakeToolchain`/`CMakeDeps`, если проверяет CMake-пакет;
- иметь `settings`/`options`, совпадающие с проверяемой конфигурацией;
- проверять не только компиляцию, но и запуск, если пакет shared;
- проверять `cmake_target_name`, include dirs, libs, runtime;
- не полагаться на `deps_cpp_info`.

### 7.6. Матрица проверки рецепта

| Измерение | Минимум | Для реального проекта |
|---|---|---|
| OS | Linux | Linux + Windows (+ macOS, если есть) |
| Compiler | GCC | GCC, Clang, MSVC |
| Build type | Release | Release + Debug |
| Linkage | shared | shared + static, если поддерживается |
| cppstd | 17 | все поддерживаемые standard |
| Runtime | default | MD/MT, Debug/Release runtime |
| Options | default | все публичные options |
| Tests | test_package | test_package + build_tests |
| Cross-build | нет | build/host profiles, если есть |
| Editable | нет | если разработчики используют editable |

### 7.7. Подводные камни миграции рецептов

- **`imports()` молча не работает.** В C2 он не вызывается; ошибки нет,
  но distribution останется пустым.
- **`scm`-атрибут сам по себе не экспортирует исходники.** Conan 2
  игнорирует C1-поле `scm`; без `exports_sources`/`export()` в кэш
  попадает только `conanfile.py`, и `conan create` собирает пустой
  source. Проверяйте содержимое export-папки после `conan export`.
- **`conan package` удалён.** Локальная команда `conan package` из C1
  не работает; используйте `conan create` или `conan export-pkg`.
- **`self.copy()` удалён.** Используйте `copy()`.
- **`deps_cpp_info` удалён.** Используйте `self.dependencies`.
- **`env_info`/`user_info` удалены.** Используйте `VirtualRunEnv`/
  `conf_info`.
- **`CMakeDeps` не угадывает target name.** Задайте
  `cmake_target_name`.
- **`resdirs` по умолчанию пуст.** Ресурсы dependency исчезнут, если
  рецепт их не объявил.
- **`cmake_layout` уже задаёт `cpp.build.libdirs`/`bindirs`.** Ручной
  override может сломать editable.
- **`recipe_folder` в cache — не source.** Пути к natvis/include нужно
  проверять на `conan create`.
- **`test_requires` — это test-контекст.** Проверьте, что тесты реально
  линкуются и запускаются, а не только что dependency видна.
- **`CMake.test()` по умолчанию использует `conanbuild` + `conanrun`.**
  Если тесты не находят runtime, проверьте `VirtualRunEnv`.
- **`build_tests` в package ID.** Если опция меняет библиотеку, удалять
  её из package ID нельзя.
- **`license`/`author`/`topics` — метаданные.** Они не влияют на сборку,
  но нужны для аудита и публикации.

### 7.8. Массовая миграция рецептов

Тысячи refs не означают тысячи уникальных рецептов: версии часто
генерируются из одного шаблона. Сначала сгруппируйте refs по источнику
рецепта (Git path, шаблон, fork), затем мигрируйте группу.

Порядок:

1. **Сканируйте C1-паттерны.** `from conans`, `imports()`, `self.copy`,
   `deps_cpp_info`, `env_info`, `user_info`, `generators = "cmake"`.
   Это кандидаты, а не автоматический вердикт.
2. **Отделите внешние рецепты.** Для ConanCenter берите C2-рецепт из
   CCI/private fork, а не переписывайте C1-копию вручную.
3. **Почините генератор.** Если рецепты созданы шаблоном, исправьте
   шаблон и перегенерируйте; иначе каждая версия снова потребует ручной
   правки.
4. **Проверяйте загрузку рецепта.** `conan export`/`conan graph info`
   ловят синтаксис и импорты, но не сборку. Для каждого шаблона
   выполните полный `conan create` хотя бы в одной конфигурации.
5. **Не делайте shim `conans`.** Подмена импортов не переносит API
   (`imports()`, `deps_cpp_info`); рецепт должен быть переписан.

Автоматического конвертера C1→C2 нет. Есть два реалистичных ускорителя:
шаблон/кодогенерация для однотипных рецептов и переиспользование
C2-рецептов CCI для внешних зависимостей. Остальное — порт с тестами.

## 8. Этап 5. Пересборка C2

### 8.1. Чистый home и профили

```bash
export CONAN_HOME="$C2_HOME"
rm -rf "$CONAN_HOME"
$C2 profile detect --force
$C2 remote add -f "$C2_VIRTUAL" \
  "$ARTIFACTORY_URL/artifactory/api/conan/$C2_VIRTUAL"
$C2 remote login "$C2_VIRTUAL" "$ARTIFACTORY_USER" \
  -p "$ARTIFACTORY_PASSWORD"
```

Профиль должен повторять source-конфигурацию: compiler, version, libcxx,
cppstd, build_type, runtime, CMake generator. Для Linux/Ninja:

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
$C2 profile show -pr "$PROFILE_LINUX_RELEASE"
```

### 8.2. Сборка

Для каждого рецепта в build order:

```bash
$C2 create path/to/recipe --build=missing \
  -r "$C2_VIRTUAL" \
  -pr:h "$PROFILE_LINUX_RELEASE" -pr:b "$PROFILE_LINUX_RELEASE"
```

Проверка графа потребителя:

```bash
$C2 install --requires="$PRODUCT_REF" \
  -r "$C2_VIRTUAL" --build=missing \
  -pr:h "$PROFILE_LINUX_RELEASE" -pr:b "$PROFILE_LINUX_RELEASE"
```

Почему `--build=missing`: Conan 2 вычисляет другие package ID. Без
пересборки consumer получает `Missing binary` даже после переноса старых
файлов.

Для нескольких конфигураций соберите каждую отдельно и сохраните
lockfile:

```bash
$C2 lock create . \
  -pr:h "$PROFILE_LINUX_RELEASE" -pr:b "$PROFILE_LINUX_RELEASE" \
  -s build_type=Release \
  -r "$C2_VIRTUAL" \
  --lockfile-out lock/Release.lock

$C2 lock create . \
  -pr:h "$PROFILE_LINUX_DEBUG" -pr:b "$PROFILE_LINUX_DEBUG" \
  -s build_type=Debug \
  -r "$C2_VIRTUAL" \
  --lockfile lock/Release.lock \
  --lockfile-out lock/Debug.lock
```

### 8.3. Подводные камни пересборки

- **Локальный кэш влияет на version range.** Оставшийся после
  негативного теста ref может быть выбран для `[>=1 <2]`; начинайте с
  чистого home или удаляйте такие refs.
- **Package ID изменился.** Не ищите старые бинарники по старому ID.
- **`--build=missing` не создаёт рецепт.** Если рецепта нет в remote,
  будет ошибка; сначала опубликуйте рецепт/зеркало.
- **Внешние зависимости.** `fmt`, `catch2`, `cmake` должны быть видны
  через `conan2` или отдельный remote.
- **Tool requirements.** `cmake`, `ninja`, компиляторы должны быть
  доступны в build-контексте.
- **Runtime.** Для shared-библиотек проверьте `VirtualRunEnv`, RPATH на
  Linux и PATH к DLL на Windows.
- **C1/C2 coexistence.** Не подмешивайте C1-пакеты в C2-граф: рецепт
  может быть несовместим.

### 8.4. Массовая пересборка: волны, матрица и гейты

Тысячи C1-пакетов нельзя пересобирать одним `conan create "*"`: нет
такого ref, а порядок зависимостей и матрица конфигураций слишком велики
для одного job. Пересборка идёт **волнами по dependency DAG**.

| Волна | Содержимое | Гейт |
|---|---|---|
| 0 | toolchain, build tools, внешние C2-рецепты | tool_requires разрешаются, профиль стабилен |
| 1 | leaf-библиотеки без внутренних зависимостей | package ID и test_package зелёные |
| 2 | библиотеки, зависящие от волны 1 | consumer smoke на предыдущей волне |
| 3 | SDK, агрегаторы, продукты | clean consumer `--build=never` |
| 4 | старые/редкие потребители | по мере переключения |

Правила:

- **Стройте план из backlog.** В волну попадают только refs с решением
  `migrate` и известными потребителями. Unused и `blocked-no-source` не
  входят.
- **Матрица — из потребителей.** Не пересобирайте все исторические
  package ID. Для каждого ref соберите конфигурации, которые реально
  запрашивают продукты: OS/arch/compiler/cppstd/build_type/runtime/options.
- **Единица работы — `ref + configuration`.** Для каждой строки заранее
  зафиксируйте ожидаемый package ID/набор ID, иначе массовый прогон
  скрывает расхождения.
- **Порядок — из C2-графа.** C1 build order не переносится. После
  миграции рецептов постройте `conan graph build-order` для набора волны
  и используйте его, а не ручной список.
- **Один чистый `CONAN_HOME` на прогон, не на каждый пакет.** Кэш нужен
  для скорости, но version ranges и старые refs могут затенять remote.
  Используйте точные refs/lockfile; при сомнении очищайте кэш между
  волнами.
- **Ограничьте параллелизм.** Artifactory CE и агенты не бесконечны;
  запускайте N независимых сборок, а не все тысячи сразу. Ошибка одного
  ref не должна блокировать независимые refs, но гейт волны не
  закрывается, пока не разобраны все падения.
- **Карантин.** Падающий ref получает статус `blocked`, лог и владельца.
  Не «лечите» его понижением версии или `--build=missing` в consumer
  job.

После каждой волны снимите отчёт:

```text
ref | config | expected package_id | actual package_id | status | log
```

Отчёт должен показывать три класса: `built`, `missing`, `unexpected`.
«Собралось без ошибок» не означает, что package ID соответствует
ожидаемому.

## 9. Этап 6. Staged publish

### 9.1. Библиотеки

Для каждой библиотеки:

1. Соберите Release и Debug.
2. Прогоните `test_package` в обеих конфигурациях.
3. Смёржите lockfiles.
4. Загрузите `name/version` целиком в `packages`.
5. Снимите package list с `:*#*` и сверьте package ID:

   ```bash
   $C2 list "my-lib/1.0.0:*#*" --format=json \
     > lockfiles/my-lib-packagelist.json
   ```

6. Только после этого promote в `products`, если нужно.

Не публикуйте рецепт до того, как собраны все обязательные конфигурации:
иначе потребитель может получить «половину» пакета. В package list должны
быть `package_id` и `package_rev`, иначе точный откат невозможен.

### 9.2. Продукты

1. Соберите единый граф всех продуктов.
2. Получите build order для Release и Debug.
3. Соберите весь набор.
4. Загрузите весь набор в `products`.
5. Promote в `develop` только после успешной сборки всего набора.
6. Запишите `release-manifest.json` последним.
7. Проверьте manifest в `develop`.

Promote — это download проверенного package list из `products` и upload
того же набора в `develop`; не собирайте продукт заново при promote.

При падении любого продукта `develop` не должен меняться. Это важнее
скорости: частично обновлённый `develop` хуже, чем отсутствие релиза.

В manifest фиксируйте:

- `ref`, recipe revision, `package_id`, `package_rev`;
- профили и `build_type` каждой конфигурации;
- commit/тег исходников продукта;
- `promoted_to_develop`;
- timestamp и версию CI-скрипта.

Verify-скрипт должен проверить, что все refs из manifest есть в
`develop`, package ID/revisions совпадают, а clean consumer ставится с
`--build=never`.

### 9.3. Pre-release

Pre-release публикуйте только в `packages` (или staging) и не promote в
`products`/`develop`. Version range не должен выбирать pre-release, если
это не разрешено политикой. Полный порядок — §9.5.2.

### 9.4. Подводные камни публикации

- **Поштучный upload продукта.** Оставляет `develop` в промежуточном
  состоянии.
- **Wildcard upload.** `conan upload "name/*"` может захватить лишние
  версии; используйте точный ref или проверенный скрипт.
- **Package list без `package_rev`.** Точный rollback невозможен.
- **Promote без проверки.** Сначала download/verify, потом upload.
- **Artifactory CE.** Нет транзакционного promote; manifest и
  verify-скрипт компенсируют, но не делают операцию атомарной.
- **Staging и stable в одном репозитории.** Легко перепутать latest;
  используйте отдельные `packages`/`products`/`develop`.

## 9.5. CI-конвейер: проектные решения

Раздел отвечает на вопросы, которые нельзя решить одним флагом Conan.
Формат каждого пункта: короткий ответ, пример, проверка.

Главное правило: **lockfile — вход разрешения зависимостей, package
list — выход сборки**. Нельзя требовать от lockfile того, что он по
модели Conan 2 не хранит.

В примерах: `packages` — staging, `products` — stable, `develop` — dev;
`PROFILE_*` — пути к профилям, `CI_PROJECT_DIR` — workspace CI.

| Вопрос | Короткий ответ |
|---|---|
| Новый мажор | Автоматически не переключать; автоматизировать PR и проверку продукта |
| Pre-release | Opt-in, точный ref, только staging |
| Lockfile | Для multi-config/параллельного CI и релиза; не всегда коммитить |
| Атомарный promote | Транзакции нет; fan-in + merged package list + manifest |
| Lockfile в отдельном repo | Не нужен; release bundle по git SHA |
| Package list | Опись бинарников, не вход разрешения |
| Compatibility plugin | Отключить fallback, если нужен строгий package ID |
| Новая транзитивная зависимость | Build-order + источник рецептов; promote до lockfile продукта |

### 9.5.1. Новый несовместимый мажор

**Короткий ответ:** безопасного автоматического перехода нет.
`requires = "lib/[>=1 <2]"` не выберет `2.0.0`; это защита, а не
дефект range.

Conan не проверяет API/ABI-совместимость. Мажор — это контракт,
который должен проверить consumer.

**Пример.** Consumer до и после PR:

```python
# было
requires = "lib/[>=1 <2]"

# стало
requires = "lib/[>=2 <3]"
```

Package pipeline собирает и публикует новый мажор:

```bash
conan create lib --version=2.0.0 \
  -pr:h "$PROFILE_LINUX_RELEASE" -pr:b "$PROFILE_LINUX_RELEASE" \
  --build=missing
conan upload "lib/2.0.0" -r packages -c
```

PR job consumer'а проверяет его против staging:

```bash
conan remote enable packages
conan lock create . -pr:h "$PROFILE_LINUX_RELEASE" \
  --lockfile-out conan.lock
conan install . -pr:h "$PROFILE_LINUX_RELEASE" \
  --lockfile=conan.lock --build=missing
conan remote disable packages
```

**Порядок:** собрать `2.0.0` → PR с range → PR CI всех продуктов
зелёный → promote `2.0.0` в `products` → merge PR → develop pipeline
собирает и promote `2.0.0` в `develop`. Пока PR не смержен, `develop`
отдаёт `1.x`; оба мажора могут жить одновременно.

**Проверка:** старый consumer без изменений всё ещё ставит `1.x`;
новый consumer с `[>=2 <3]` ставит `2.0.0` и проходит runtime-тесты.

**Антипаттерн:** `[>=1 <3]` «на всякий случай» — это уже разрешение
автоматически перейти на несовместимый мажор.

Zero-touch auto-merge допустим только при полном покрытии продуктов в
CI и явной политике «мажор считается принятым после зелёной сборки
всех продуктов». В остальных случаях последний шаг — approval
владельца consumer'а: Conan не подтвердит семантическую совместимость.

### 9.5.2. Pre-release

**Короткий ответ:** pre-release — только opt-in, точный ref и staging.
По умолчанию Conan не выбирает pre-release.

**Пример.** Тестовая ветка использует точный ref:

```python
requires = "lib/2.0.0-beta.1"
```

Сборка и публикация:

```bash
conan create lib --version=2.0.0-beta.1 \
  -pr:h "$PROFILE_LINUX_RELEASE" -pr:b "$PROFILE_LINUX_RELEASE" \
  --build=missing
conan upload "lib/2.0.0-beta.1" -r packages -c
```

Product job проверяет продукт, читая staging только на время job:

```bash
conan remote enable packages
conan install . -pr:h "$PROFILE_LINUX_RELEASE" --build=missing
conan remote disable packages
```

В `products`/`develop` pre-release не promote. После выхода `2.0.0`
идёт обычный pipeline; lockfile с pre-release остаётся артефактом
проверки.

Если нужен range, включайте pre-release явно:

```python
requires = "lib/[>=2 <3, include_prerelease]"
```

Помните: стабильная версия имеет приоритет над pre-release, поэтому для
проверки конкретной beta надёжнее точный ref.

Или включайте глобально только в отдельном job:

```bash
conan install . \
  -cc core.version_ranges:resolve_prereleases=True \
  -pr:h "$PROFILE_LINUX_RELEASE"
```

**Проверка:** обычный `lib/[>=1 <2]` не выбирает `2.0.0-beta.1`;
точный ref выбирает. В `develop` не должно быть pre-release ref.

**Антипаттерн:** `core.version_ranges:resolve_prereleases=True` в общем
`global.conf` — это влияет на весь граф и на всех разработчиков.

Помните порядок: `1.1-alpha.1` предшествует `1.1`; при наличии
стабильной `1.1` range выберет её, а не pre-release.

### 9.5.3. Lockfile: когда сохранять

**Короткий ответ:** lockfile нужен, когда несколько конфигураций или
джоб должны разрешить зависимости одинаково, и для релиза. Для
одиночного `conan create` в чистом home он не обязателен.

**Пример multi-config.** Один lockfile создаётся один раз и передаётся
во все сборки:

```bash
conan lock create . -pr:h "$PROFILE_LINUX_RELEASE" \
  -s build_type=Release --lockfile-out conan.lock
conan lock create . -pr:h "$PROFILE_LINUX_DEBUG" \
  -s build_type=Debug --lockfile=conan.lock --lockfile-out conan.lock

conan create . --lockfile=conan.lock -s build_type=Release ...
conan create . --lockfile=conan.lock -s build_type=Debug ...
```

`conan.lock` в текущем каталоге Conan подхватывает автоматически. В CI
передавайте его явно, иначе stale-файл из workspace может незаметно
изменить граф:

```bash
conan install . --lockfile="$CI_PROJECT_DIR/conan.lock"
```

| Где | Коммитить | Где хранить | Зачем |
|---|---|---|---|
| Packages pipeline | Обычно нет | CI artifact + release bundle | Один набор для всех конфигураций; одна конфигурация — опционально |
| Product repo | В PR, меняющем зависимости | `conan.lock` в корне repo | Продукт сам выбирает версии |
| Release/rollback | Да | Release bundle, ключ — git SHA | Восстановление набора зависимостей |
| Разовый debug | Нет | Временный каталог | Не должен влиять на следующие сборки |

Правила:

- Не коммитьте lockfile автоматически после каждой сборки. Он меняется
  в PR, где меняются зависимости, а не в job, который поднял версию
  пакета. Иначе commit hash и содержимое lockfile расходятся.
- Для библиотек lockfile обычно не коммитится: библиотека не должна
  диктовать consumer'ам транзитивные версии. Его считают на лету или
  берут из product lockfile.
- Отдельный repo «с тем же commit hash» не нужен. Достаточно product
  repo в этом commit или release bundle по git SHA.

Пример release bundle:

```text
release/<git-sha>/
  conan.lock
  package-list.json
  profiles/linux-gcc-release
  manifest.json
```

**Проверка:** все конфигурации используют один `conan.lock`; в CI нет
неявного lockfile из текущего каталога; в release bundle lockfile
лежит рядом с package list и профилями.

### 9.5.4. Package list: зачем, если он не lock

**Короткий ответ:** package list — выход сборки, а не вход разрешения.
Lockfile отвечает «какие версии и recipe revisions», package list —
«какие бинарники собраны».

**Пример.** Собрали пакет, сняли опись и загрузили:

```bash
conan create . --format=json > graph.json
conan list --graph=graph.json --graph-binaries=build \
  --format=json > built.json
conan upload --list=built.json -r packages -c \
  --format=json > uploaded.json
```

Fan-in объединяет описи конфигураций и продвигает их:

```bash
conan pkglist merge \
  -l uploaded_linux_release.json \
  -l uploaded_linux_debug.json \
  --format=json > uploaded.json

conan download --list=uploaded.json -r products \
  --format=json > promote.json
conan upload --list=promote.json -r develop -c
```

Почему package list не заменяет lockfile:

- Lockfile хранит версии и recipe revisions, но не `package_id` и не
  `package_rev`. Это осознанное решение Conan 2.
- `package_id` вычисляется из рецепта, графа и профиля; `package_rev` —
  ревизия конкретного бинарника.
- `conan install` не принимает package list. Package list принимают
  `conan upload`, `conan download` и promote-команды.
- Package list не участвует в разрешении, поэтому «точная
  воспроизводимость по package list» не работает. Он нужен для
  другого: скачать/продвинуть/проверить ровно те бинарники, которые
  были собраны.
- Package list не запрещает появление новой `package_rev` для того же
  `package_id`. Это обеспечивает immutable remote (или политика
  «ровно одна package revision на package_id»).

Разделяйте три разных свойства:

| Свойство | Чем задаётся |
|---|---|
| Тот же набор версий и recipe revisions | Lockfile + profiles + версия Conan + remotes |
| Тот же набор бинарников | Package list + immutable remote |
| Тот же исходный код и окружение сборки | Git SHA + toolchain image + lockfile |

Полный release bundle: `git-sha`, `conan.lock`, merged package list,
профили, версия Conan и digest toolchain-образа. Только вместе они
дают воспроизводимый релиз; по отдельности — нет.

**Проверка:** `conan install --list=...` не должен приниматься; для
установки используйте lockfile, для переноса бинарников — package
list.

### 9.5.5. Атомарный promote и неполная матрица

**Короткий ответ:** атомарного promote в Conan/Artifactory CE нет.
Атомарность делается fan-in, merged package list и manifest, а не
поштучным upload.

**Пример пайплайна:**

| Этап | Что делает job | Артефакт/гейт |
|---|---|---|
| Build matrix | Собирает все конфигурации и загружает их в `packages` | `uploaded_<config>.json` от каждой ноги |
| Fan-in packages | Ждёт все ноги, мержит описи, сверяет число конфигураций и package ID | Один `uploaded.json` |
| Promote to products | Переносит merged package list в `products` | Проверка после переноса |
| Products build | Собирает продукты и загружает результат в `products` | `uploaded_products.json` |
| Fan-in products | Сверяет набор продуктов | Зелёная сборка всех продуктов |
| Promote to develop | Переносит финальный список | Manifest пишется последним |

Команды fan-in и promote:

```bash
conan pkglist merge \
  -l uploaded_linux_release.json \
  -l uploaded_linux_debug.json \
  --format=json > uploaded.json

conan download --list=uploaded.json -r packages \
  --format=json > promote.json
conan upload --list=promote.json -r products -c
```

Если packages pipeline не может гарантировать, что собрал все
конфигурации:

| Ситуация | Действие |
|---|---|
| Релизный пакет, матрица неполная | Блокировать promote до завершения матрицы |
| Products pipeline может дособрать | Разрешить `--build=missing`; missing попадут в package list products |
| Явно не-релизный/dev-пакет | Можно продвигать по конфигурации; для `develop` так нельзя |

Поштучный upload и promote после каждой ноги оставляют `develop` в
промежуточном состоянии. `conan art:promote` (Artifactory Pro) быстрее
обычного download+upload, но остаётся копированием: проверка после
promote всё равно нужна.

**Проверка:** число package ID в merged list совпадает с ожидаемым;
`develop` не содержит частично продвинутую конфигурацию; manifest
появился последним.

### 9.5.6. Отключение compatibility plugin

**Короткий ответ:** если нужен строгий «взяли ровно собранное»,
глобальный fallback надо отключить.

По умолчанию `compatibility.py` разрешает fallback по `cppstd` и
`cstd` (а для MSVC — `194` → `193`). Поэтому профиль с `cppstd=20`
может получить бинарник, собранный с `cppstd=17`.

**Пример.** Откройте файл в Conan home:

```bash
$EDITOR "$(conan config home)/extensions/plugins/compatibility/compatibility.py"
```

Содержимое должно быть таким:

```python
# Local policy: no binary fallback across cppstd/compiler.
def compatibility(conanfile):
    return []
```

Важно:

- Не удаляйте файл: Conan падает с ошибкой, что
  `compatibility.py` не существует. Отключение — это `return []`, а не
  удаление.
- Уберите первую строку `# This file was generated by Conan.`; иначе
  Conan при миграции перезапишет файл.
- Распространяйте файл вместе с `global.conf` и профилями через
  `conan config install`, иначе на разных агентах будет разное
  поведение:

  ```bash
  conan config install ./ci/conan-config -t dir
  ```
- Точечная альтернатива для одного рецепта — отключить fallback в
  `extension_properties`:

  ```python
  class LibConan(ConanFile):
      extension_properties = {"compatibility_cppstd": False}
  ```

  Это отключает только `cppstd`-fallback; для `cstd` есть
  `compatibility_cstd`.
- `core.graph:compatibility_mode=optimized` не отключает
  совместимость; это только оптимизация запросов.

Проверка:

```bash
conan graph info --requires=lib/1.0 \
  -pr:h "$PROFILE_LINUX_RELEASE" --format=json > graph.json
conan install --requires=lib/1.0 \
  -pr:h "$PROFILE_LINUX_RELEASE" --build=never
```

Если точного бинарника для `cppstd=20` нет, команда должна упасть с
`Missing binary`, а не тихо подставить `cppstd=17`. Цена — больше
пересборок; матрица должна собирать все поддерживаемые `cppstd`.

### 9.5.7. Новая транзитивная зависимость

**Короткий ответ:** она появляется в build-order пакетного pipeline;
расширять надо его, а не ждать products pipeline.

**Пример.** В `cpp_redis/4.3.1` появилась зависимость `hiredis/1.2.0`:

```python
class CppRedisConan(ConanFile):
    def requirements(self):
        self.requires("hiredis/1.2.0")
```

Цепочка сборки:

```text
hiredis/1.2.0 -> cpp_redis/4.3.1 -> product/1.0
```

Если рецепта `hiredis` нет в remotes, packages pipeline нужен источник
рецептов:

```bash
conan remote add local-recipes /path/to/recipes \
  -t local-recipes-index
```

`local-recipes-index` даёт рецепты, но не бинарники: бинарники
собираются и promote как обычно.

Build-order для всех профилей:

```bash
conan graph build-order . --build=missing --order-by=recipe \
  -pr:h "$PROFILE_LINUX_RELEASE" -pr:b "$PROFILE_LINUX_RELEASE" \
  --format=json > order-linux.json

conan graph build-order . --build=missing --order-by=recipe \
  -pr:h "$PROFILE_WINDOWS_RELEASE" -pr:b "$PROFILE_WINDOWS_RELEASE" \
  --format=json > order-windows.json

conan graph build-order-merge \
  --file=order-linux.json --file=order-windows.json \
  --format=json > order.json
```

`--reduce` на промежуточных order'ах не используйте: уменьшённый
order нельзя мержить с другими. На финальном merge `--reduce` тоже
опасен: на заполненном кэше он может вернуть только часть refs (на
стенде — 2 продукта вместо 9 refs), хотя остальные пакеты ещё нужно
проверить или пересобрать. Мержите без `--reduce` и дедуплицируйте
refs перед сборкой; именно так работает `ci-products-release.sh`.

Дальше:

1. Соберите уровни `order.json`.
2. Снимите graph JSON и package list:

```bash
conan graph info . --build=missing \
  -pr:h "$PROFILE_LINUX_RELEASE" --format=json > graph.json
conan list --graph=graph.json --graph-binaries=build \
  --format=json > built.json
```

3. Загрузите `built.json` в `packages`, смержите с другими
   конфигурациями и promote в `products`.
4. Products pipeline создаёт lockfile только после того, как новые
   зависимости уже в `products`; иначе resolution упадёт.

Выбор `--build`:

| Случай | Аргумент |
|---|---|
| Onboarding нового рецепта и его транзитивных зависимостей | `--build=missing` |
| Обычное обновление существующего пакета | `--build=missing:mypkg/*` |

Если products pipeline должен протестировать новую зависимость до
promote, включите `packages` read-only на время job. Но финальный
promote новой зависимости в `products` всё равно должен произойти до
lockfile продукта.

**Проверка:** в build-order есть `hiredis` на уровне раньше
`cpp_redis`; в `products` есть и рецепт, и бинарники `hiredis`; продукт
собирается с `--build=never` без source-сборки.

### 9.6. Публикация и promote при тысячах пакетов

Массовая публикация — это не один `conan upload "*"`, а набор
ограниченных операций с проверяемыми описями.

Правила:

1. **Публикуйте волнами.** Сначала `packages`, затем `products`, затем
   `develop`. Внутри волны — по dependency order; зависимость попадает
   в стабильный remote раньше потребителя.
2. **Шардируйте package lists.** Один список на ref/конфигурацию или на
   продукт. Общий список на тысячи пакетов тяжело проверять и опасно
   применять частично.
3. **Не используйте wildcard upload.** `conan upload "lib/*"` может
   захватить старые версии и pre-release. Загружайте точный ref или
   проверенный package list.
4. **Manifest — последним.** Для каждой волны/продукта запишите manifest
   с количеством refs и package ID, revisions и статусом. Пока manifest
   не записан, волна не считается опубликованной.
5. **Проверяйте counts.** Сравните число refs/package ID в source,
   package list и manifest. Расхождение — гейт, а не предупреждение.
6. **Promote без пересборки.** Скачайте проверенный список из staging и
   загрузите тот же набор в stable. Не запускайте `conan create` на
   этапе promote.
7. **Проверяйте выборку и критичные пакеты.** Для тысяч пакетов полный
   runtime-прогон каждого бинарника может быть нереален; проверяйте все
   критичные refs и репрезентативную выборку остальных, но package
   ID/revisions сверяйте для всех.
8. **Rollback — по продукту.** Держите старый C1-remote и предыдущий
   C2 release bundle. Глобального атомарного rollback в Artifactory CE
   нет.

Artifactory CE не даёт транзакционного promote. Поэтому «атомарность»
здесь — это: полный staging-набор + проверенный manifest + promote
только после зелёного гейта. Частично опубликованная волна должна быть
явно помечена и не считаться стабильной.

## 10. Этап 7. Consumer/CI cutover

### 10.1. Чистый потребитель

```bash
export CONAN_HOME=/tmp/conan2-clean-consumer
rm -rf "$CONAN_HOME"
$C2 profile detect --force
$C2 remote add -f "$C2_VIRTUAL" \
  "$ARTIFACTORY_URL/artifactory/api/conan/$C2_VIRTUAL"
$C2 remote login "$C2_VIRTUAL" "$ARTIFACTORY_USER" \
  -p "$ARTIFACTORY_PASSWORD"

$C2 install --requires="$PRODUCT_REF" \
  -r "$C2_VIRTUAL" --build=never \
  -pr "$PROFILE_LINUX_RELEASE"
```

Ожидаемо: все пакеты графа скачиваются через `conan2`, без source-URL.

Для старого продукта из `develop`:

```bash
$C2 download \
  --list=lockfiles/product/product-packagelist.json \
  -r "$C2_DEVELOP"

$C2 install path/to/product \
  -pr:h "$PROFILE_LINUX_RELEASE" \
  -pr:b "$PROFILE_LINUX_RELEASE" \
  -s build_type=Release \
  --lockfile lockfiles/product/product.lock \
  --build=never
```

Package list должен быть снят с `:*#*` и содержать `package_rev`.

### 10.2. CI

1. Отдельный `CONAN_HOME` на job или эфемерный агент.
2. `conan profile detect`/`conan config install` для профилей.
3. `conan remote login` под сервисной учётной записью.
4. Lockfile, package list, профили и версия Conan — артефакты CI.
5. Публикация только через staged-скрипты.
6. `conan2` — единственный remote для потребителя.
7. Кэш CI не должен переживать смену target-топологии без очистки.

### 10.3. Параллельный запуск и canary

- Сначала переключите один сервис/продукт.
- Сравните build manifest, runtime-поведение и размер дистрибутива.
- Держите C1-remote доступным.
- После успешного canary переключайте остальные продукты партиями.

### 10.4. Подводные камни cutover

- **CI cache содержит C1-пакеты.** Чистый home или явная очистка.
- **Разные credentials для Gitea и Artifactory.** Не смешивайте.
- **Debug/Release runtime.** Windows DLL и Linux RPATH отличаются.
- **Consumer использует несколько remotes.** Conan 2 может выбрать не тот
  пакет; для воспроизводимости — один `conan2`.
- **Lockfile не содержит package_rev.** Для точного отката нужен
  package list и неизменяемый remote; одного lockfile недостаточно.
- **Старый продукт ставится по `latest`.** Только lockfile + package list.
- **Забыли проверить `--build=never`.** Иначе consumer тихо соберёт
  пакет из исходников и скроет проблему.

### 10.5. Rollback

Различайте два сценария:

1. **Откат C2-релиза на предыдущий C2-релиз.** Используйте старый
   lockfile и package list из `develop`, `--build=never`. Это штатный
   откат и не требует C1.
2. **Полный откат миграции на C1.** Переключите CI job и потребителя
   обратно на C1-бинарь и C1-remote. Не пытайтесь собрать C1-рецепт
   Conan 2: это другой API.

Порядок:

1. Остановите публикацию в target.
2. Зафиксируйте текущий manifest и package list для разбора.
3. Переключите consumer/CI на старый pipeline.
4. Соберите с `--build=never` и проверьте runtime.
5. Если повреждён target, восстановите Artifactory backup или
   пересоберите набор.
6. Не удаляйте source до завершения разбора.

Rollback нужно отрепетировать до cutover, иначе он останется планом на
бумаге.

## 11. Этап 8. Decommission

1. Закройте окно rollback.
2. Переведите source в read-only/архив.
3. Удалите C1-remotes из клиентов и CI.
4. Обновите документацию, профили, шаблоны репозиториев.
5. Сохраните inventory, manifests и backup согласно retention.
6. Проверьте, что новые публикации идут только в target.
7. Удалите временные target-репозитории через PATCH, если они больше не
   нужны.

Не удаляйте source, пока не истёк срок аудита и не проверен rollback.

## 12. Критические подводные камни

### 12.1. Данные и инвентаризация

- Package revision не видна в `conan search`; без manifest нет точного
  rollback.
- Wildcard `conan search "*" --revisions` в C1.66 не работает.
- Virtual remote может скрывать источник пакета.
- C1-кэш может содержать failed refs, влияющие на version range.
- AQL без пагинации обрезает тысячи записей; проверяйте последнюю страницу.
- Storage с тысячами package ID не равен списку обязательных пересборок;
  нужен migration backlog по потребителям.

### 12.2. Рецепты

- `imports()` в C2 не вызывается; distribution останется пустым.
- `self.copy`, `deps_cpp_info`, `env_info`, `user_info` удалены.
- `generators = "json"` не существует.
- `resdirs` в C2 по умолчанию `[]`.
- `cmake_layout` уже задаёт build lib/bin dirs; override требует проверки.
- `recipe_folder` в cache не равен source folder.
- `test_requires` — test-контекст; проверяйте фактическую линковку.
- `build_tests` в package ID — только если тесты не меняют бинарник.

### 12.3. Package ID и бинарники

- C1 и C2 package ID не совпадают.
- Смена settings/options/package_type/user/channel меняет ID.
- Debug/Release runtime и cppstd должны быть согласованы.
- Shared/static и runtime-зависимости могут требовать разных package ID.
- Старые бинарники не доказывают наличие нового package ID.

### 12.4. Remotes и Artifactory

- Conan 2 не ищет по всем remotes; нужен virtual.
- `conan2` без внешних зависимостей не разрешит `fmt`/`catch2`.
- Artifactory CE не удаляет репозитории через DELETE; используйте PATCH.
- `conan-remote-cache` — не API-репозиторий.
- `artifactory-build-info` зарезервирован.
- Нет транзакционного promote; нужен manifest + verify.

### 12.5. CI и публикация

- Поштучный upload продукта оставляет `develop` частично обновлённым.
- `conan upload` может вернуть 0 при ошибке; проверяйте наличие.
- `conan list` при 404 может вернуть 0; проверяйте JSON.
- Lockfile не содержит `package_id`/`package_rev`; точный набор
  бинарников задаёт package list. Без immutable remote и package list
  rollback неточный.
- CI cache может подмешать старые пакеты.
- Gitea/Jenkins credentials нельзя смешивать с Artifactory.
- Один package list/manifest на тысячи пакетов невозможно проверить
  частично; шардируйте по ref/продукту и сверяйте counts.

### 12.6. Платформы и runtime

- Windows: DLL search path, Debug/Release runtime, `/MD` vs `/MT`,
  natvis, длинные пути.
- Linux: RPATH/`$ORIGIN`, SONAME, symlink’и, libstdc++/glibc.
- macOS: `@rpath`, architectures, SDK; отдельная матрица.
- Cross-build: build/host profiles, tool_requires, sysroot.
- Shared-библиотеки: тесты и приложения нуждаются в runtime env.

### 12.7. Безопасность

- Не использовать `admin` в production.
- Ограничить write-права CI.
- Не хранить пароли в рецептах и логах.
- `conan user -p`/`conan remote login -p` могут попасть в history и
  process list; используйте CI secret и эфемерные агенты.
- Проверять URL и TLS.
- Для Git-export использовать ключ с минимальными правами.

## 13. Чек-листы

### 13.1. Discovery

- [ ] Все source-remotes известны.
- [ ] Все refs и ревизии сняты.
- [ ] Package revisions сохранены для критичных пакетов.
- [ ] Потребители и CI jobs перечислены.
- [ ] Платформы и профили зафиксированы.
- [ ] Внешние зависимости перечислены.
- [ ] Владельцы рецептов назначены.
- [ ] Для тысяч пакетов AQL-страницы прочитаны полностью, без обрезания.
- [ ] Каждый ref классифицирован: migrate / external / binary-only / unused.
- [ ] Список `blocked-no-source` зафиксирован отдельно.

### 13.2. Target

- [ ] `packages`/`products`/`develop` созданы.
- [ ] `conan2` агрегирует нужные репозитории.
- [ ] Внешний remote/зеркало доступны через target.
- [ ] Права и retention настроены.
- [ ] Тестовый пакет виден через `conan2`.
- [ ] Старые C1-репозитории переведены в read-only и не входят в `conan2`.
- [ ] C2-рецепты не загружены в C1-репозитории.

### 13.3. Freeze/backup

- [ ] Source заморожен.
- [ ] Backup БД и filestore сделан.
- [ ] Restore проверен.
- [ ] Inventory сохранён.
- [ ] Окно rollback определено.

### 13.4. Рецепты

- [ ] Нет `conans`, `imports()`, `self.copy`, `deps_cpp_info`,
      `env_info`, `user_info`.
- [ ] Исходники попадают в cache через `exports_sources`/`export()`,
      а не через C1-атрибут `scm`.
- [ ] `layout()` и `cmake_layout` проверены.
- [ ] `generate()` создаёт toolchain/deps/env.
- [ ] `VirtualRunEnv` добавлен для shared/тестов.
- [ ] `package_info()` заполняет `cpp_info`.
- [ ] `test_package` обновлён.
- [ ] Options/package ID проверены.
- [ ] `resdirs`, лицензии, symlink’и проверены.
- [ ] Windows/natvis проверены, если Windows в scope.

### 13.5. Пересборка

- [ ] Чистый `CONAN_HOME`.
- [ ] Профили совпадают с source.
- [ ] Lockfile создан для каждой конфигурации.
- [ ] `--build=missing` отработал.
- [ ] Все обязательные конфигурации собраны.
- [ ] Package ID соответствуют ожидаемым.
- [ ] Compatibility plugin отключён или политика fallback зафиксирована.
- [ ] Новые транзитивные зависимости вошли в build-order.
- [ ] Runtime-зависимости проверены.
- [ ] Backlog разбит на волны по dependency DAG.
- [ ] Матрица конфигураций построена из потребителей, а не из всех C1 package ID.
- [ ] Для каждой строки `ref + configuration` есть expected/actual package ID.
- [ ] Падающие refs изолированы, гейт волны не закрыт.

### 13.6. Публикация

- [ ] Библиотеки опубликованы через staged-процесс.
- [ ] Release и Debug собраны до upload.
- [ ] Продукты собраны единым графом.
- [ ] `develop` не менялся при падении.
- [ ] Manifest создан последним.
- [ ] Package list содержит `package_rev`.
- [ ] Release bundle содержит lockfile, package list, профили и версию Conan.
- [ ] Promote выполнен только после fan-in всех конфигураций.
- [ ] Verify-скрипт зелёный.
- [ ] Package lists шардированы по ref/продукту, без гигантского общего списка.
- [ ] Для каждой волны снят manifest и сверены counts refs/package ID.
- [ ] Публикация шла dependency order, без wildcard upload.

### 13.7. Cutover

- [ ] Clean consumer ставит через `conan2` с `--build=never`.
- [ ] Старый продукт ставится по lockfile + package list.
- [ ] CI использует чистый home.
- [ ] Canary-продукт проверен.
- [ ] Rollback проверен.
- [ ] Source остаётся доступным.
- [ ] Продукты переключаются партиями, а не все одновременно.
- [ ] C1 lockfiles заменены на C2 lockfiles и package lists.
- [ ] Для каждого продукта есть предыдущий C2 release bundle для отката.

### 13.8. Decommission

- [ ] Окно rollback закрыто.
- [ ] Source переведён в read-only/архив.
- [ ] C1-remotes удалены из клиентов.
- [ ] Документация обновлена.
- [ ] Inventory/manifest/backup сохранены по retention.
- [ ] Временные репозитории удалены через PATCH.

## 14. Приложение: команды стенда в абстрактных именах

Эти команды относятся к демонстрационному стенду и приведены как
референс; имена пакетов, репозиториев и путей абстрагированы. В реальном
проекте подставьте свои значения.

### 14.1. Стенд

- Artifactory CE `7.161.26`, Conan `1.66.0`, Conan `2.33.0`;
- Linux/GCC 13, CMake, Ninja;
- source: `source-local`, `source-libs`, `source-thirdparty`,
  virtual `source-platform`, `source-thirdparty-mirror`, `source-all`;
- target: `packages`, `products`, `develop`, virtual `conan2`;
- Gitea — только Git; Jenkins — только CI runner;
- сценарии `01–09` пройдены; `09` — приватный форк Conan Center.

### 14.2. Инвентаризация

```bash
export CONAN_USER_HOME=/tmp/conan1-home
export CONAN_REVISIONS_ENABLED=1
CONAN1=/path/to/conan1/bin/conan

for r in source-local source-libs source-thirdparty \
  source-platform source-thirdparty-mirror source-all; do
  $CONAN1 search "*" -r "$r"
done > /tmp/conan1-inventory.txt
```

### 14.3. Загрузка source

Используйте функцию `upload_pref` из §6.2.

```bash
upload_pref source-thirdparty example-headers/1.0.0
upload_pref source-thirdparty example-headers/1.1.0
upload_pref source-libs example-base/1.0.0
upload_pref source-libs example-utils/1.0.0
upload_pref source-libs example-gfx/1.0.0
upload_pref source-libs example-texture/1.0.0
upload_pref source-libs example-box/1.0.0
upload_pref source-libs example-sdk/1.0.0
upload_pref source-local example-product-a/1.0.0
upload_pref source-local example-product-b/1.0.0
```

### 14.4. Staged CI

```bash
cd demo/conan-migration-sandbox

bash scripts/ci-package-release.sh libs/example-headers 1.0.0
bash scripts/ci-package-release.sh libs/example-headers 1.1.0
bash scripts/ci-package-release.sh libs/example-base 1.0.0
bash scripts/ci-package-release.sh libs/example-utils 1.0.0
bash scripts/ci-package-release.sh libs/example-gfx 1.0.0
bash scripts/ci-package-release.sh libs/example-texture 1.0.0
bash scripts/ci-package-release.sh libs/example-box 1.0.0
bash scripts/ci-package-release.sh libs/example-sdk 1.0.0

conan export products/example-product-a
conan export products/example-product-b
conan upload "example-product-a/1.0.0" -r products -c --only-recipe
conan upload "example-product-b/1.0.0" -r products -c --only-recipe

export CI_RESOLVE_REMOTE=products
bash scripts/ci-products-release.sh --dry-run
bash scripts/ci-products-release.sh
bash scripts/ci-verify-release.sh
```

### 14.5. Ограничения стенда

1. `source-thirdparty` может остаться пустым, если нет подтверждённой карты
   пакетов; на стенде он заполнен placeholder `example-thirdparty/1.0.0`.
2. `conan list` по source C1 может не показывать бинарники; используйте
   точный pref/manifest.
3. При HTTP 404 `conan list` в Conan 2 возвращает exit code `0`.
4. `conan upload` C1-рецепта в Conan 2 падает с `ImportError` и тоже
   может вернуть `0`.
5. Artifactory CE не удаляет репозитории через `DELETE`; используйте
   PATCH с `null`.
6. Baseline поверх заполненного target может разрешить более поздний
   несовместимый 1.x; для репетиции нужны отдельные target-репозитории
   или фиксированный lock.
7. Legacy pref в `legacy` — только аудит/rollback; не смешивайте его с
   `packages`/`products`.
8. Virtual-репозиторий `conan2` обязателен для межрепозиторных
   зависимостей.

### 14.6. Сценарии

- [`05-staged-package-release.md`](scenarios/05-staged-package-release.md)
- [`06-unified-product-release.md`](scenarios/06-unified-product-release.md)
- [`08-conan1-to-conan2-cutover.md`](scenarios/08-conan1-to-conan2-cutover.md)
- [`09-conan-center-fork.md`](scenarios/09-conan-center-fork.md)
