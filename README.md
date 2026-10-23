# conan2-ci-lab

Локальный воспроизводимый контур для миграции Conan 1 → Conan 2:

- **Gitea** — Git-хостинг и исходники. Package Registry отключён.
- **Jenkins** — CI/CD, сборка и продвижение Conan-пакетов.
- **JFrog Artifactory CE for C/C++** — единственное хранилище Conan-артефактов.
- **PostgreSQL** — общая БД Gitea и Artifactory.
- **Docker-in-Docker** — изолированный демон для сборок Jenkins.
- **Conan** — sidecar-контейнер с тулчейном для ручных проверок.

```text
Gitea (source) ──webhook──▶ Jenkins (pipeline)
                               │
                               │ conan upload / download / promote
                               ▼
                     Artifactory (Conan repos)
                     packages → products → develop
```

Gitea **не** используется как Conan Package Registry. Jenkins **не** хранит
пакеты: он только запускает pipeline. Все рецепты и бинарники Conan находятся
в Artifactory.

## Требования

- Docker Engine или Docker Desktop с Compose v2.
- Не менее 8 ГБ RAM (рекомендуется 16 ГБ): Artifactory и Jenkins требовательны
  к памяти.
- Свободные порты на хосте: `3000`, `222`, `8080`, `50000`, `8081`, `8082`.
- Linux/WSL с `bash` или Windows с PowerShell 5.1+.
- Для ручного прогона Conan-сценария: `conan >= 2.32`, `python3`, GCC 13, CMake
  и Ninja в `PATH`. В контейнере `conan` этот toolchain ставит bootstrap.
- Доступ к Docker Hub и `releases-docker.jfrog.io` для загрузки образов.

Версии зафиксированы в `docker-compose.yml`: Gitea `28.0.0`,
Jenkins `2.580.1`, Artifactory `7.161.26`, PostgreSQL `18`, Docker-in-Docker
`29.8.2`. Bootstrap ставит Conan `>= 2.32` и использует GCC 13 / C++17.

## Быстрый старт

### Linux / WSL

```bash
git clone <repo-url> conan2-ci-lab
cd conan2-ci-lab

cp .env.example .env
# При необходимости измените пароли в .env.

docker compose up -d --build
docker compose ps

bash bootstrap.sh
```

### Windows PowerShell

```powershell
git clone <repo-url> conan2-ci-lab
cd conan2-ci-lab

Copy-Item .env.example .env
# При необходимости измените пароли в .env.

docker compose up -d --build
docker compose ps

powershell -ExecutionPolicy Bypass -File .\bootstrap.ps1
```

`bootstrap.sh` / `bootstrap.ps1` идемпотентны: их можно запускать повторно на
уже работающем стенде. Они ждут готовности сервисов, создают администраторов,
организации и токен Gitea, ставят toolchain и Conan в контейнер `conan`,
настраивают remotes Artifactory, плагины и credentials Jenkins, выполняют
smoke-тест и генерируют `SETUP-REPORT.md`.

## Доступ к сервисам

| Сервис | URL | Учётная запись |
|---|---|---|
| Gitea | <http://localhost:3000> | `admin` / значение `GITEA_ADMIN_PASSWORD` |
| Jenkins | <http://localhost:8080> | `admin` / значение `JENKINS_ADMIN_PASSWORD` |
| Artifactory | <http://localhost:8082> | `admin` / значение `ARTIFACTORY_PASSWORD` |
| Artifactory UI | <http://localhost:8081> | тот же администратор |

Пароли по умолчанию в `.env.example` предназначены **только для локальной
лаборатории**. Для любого общего окружения задайте свои значения в `.env`.
Файл `.env` и каталог `.secrets/` исключены из Git.

Bootstrap складывает машинные секреты в `.secrets/`:

- `gitea-token` — PAT для Jenkins и API;
- `jenkins-pass` — пароль администратора Jenkins.

`SETUP-REPORT.md` содержит фактическое состояние стенда и также исключён из Git.
Его можно открыть после bootstrap.

## Что создаётся в Artifactory

`artifactory-init` автоматически создаёт при первом запуске:

| Тип | Имя | Назначение |
|---|---|---|
| local | `conan-local`, `ap-source`, `conan-thirdparty`, `ap-thirdparty` | source-репозитории Conan 1 |
| local | `generic-local` | прочие исходные артефакты |
| local | `packages`, `products`, `develop` | целевые стадии Conan 2 |
| local | `conancenter-fork` | бинарники, собранные из приватного форка Conan Center |
| remote | `conan-remote` | ConanCenter (`https://center.conan.io`) |
| virtual | `conan` | source-репозитории + ConanCenter |
| virtual | `conan2` | `packages` + `products` + `develop` |

Bootstrap настраивает в контейнере `conan` remotes `packages`, `products` и
`develop` на
`http://artifactory:8082/artifactory/api/conan/<repo>` и логинится под
администратором Artifactory.

## Проверка Conan-сценария

Для ручного прогона нужен Conan 2 в `PATH` (или используйте контейнер
`conan`). На хосте укажите URL Artifactory, доступный с хоста:

```bash
export ARTIFACTORY_URL=http://localhost:8082
export CONAN_USERNAME=admin
export CONAN_PASSWORD="$(grep '^ARTIFACTORY_PASSWORD=' .env | cut -d= -f2-)"

cd demo/conan-migration-sandbox
bash scripts/bootstrap-remotes.sh

# Сборка библиотек в порядке зависимостей; скрипт принимает путь и версию.
bash scripts/packages-pipeline.sh libs/ap-base 1.0.0
bash scripts/packages-pipeline.sh libs/ap-headers 1.3.290
bash scripts/packages-pipeline.sh libs/ap-headers 1.4.1
bash scripts/packages-pipeline.sh libs/ap-utils 1.0.0
bash scripts/packages-pipeline.sh libs/ap-gfx 1.0.0
bash scripts/packages-pipeline.sh libs/ap-texture 1.0.0
bash scripts/packages-pipeline.sh libs/ap-box 1.0.0
bash scripts/packages-pipeline.sh libs/ap-sdk 1.0.0

# Сборка продукта, публикация в products и продвижение в develop.
bash scripts/products-pipeline.sh products/ap-product-a
bash scripts/products-pipeline.sh products/ap-product-b

# Точечное продвижение уже собранного пакета.
bash scripts/promote.sh 'ap-base/1.0.0' packages products
```

Полный порядок сборки с версиями `ap-headers`, остальными продуктами,
ограничения и разбор ошибок — в
[`demo/conan-migration-sandbox/README.md`](demo/conan-migration-sandbox/README.md).
Пошаговые сценарии стенда — в каталоге [`scenarios/`](scenarios/) (`01` … `09`).
Пошаговая миграция хранилища описана в
[`conan1-conan2-migration-runbook.md`](conan1-conan2-migration-runbook.md).

Jenkins job по push не создаётся автоматически: bootstrap настраивает только
сервер Gitea, credentials и плагины. Для сквозного CI создайте Pipeline job из
`demo/conan-migration-sandbox/Jenkinsfile` и включите webhook в Gitea
(`manageHooks=true` уже задан).

## Структура репозитория

```text
.
├── docker-compose.yml          # Gitea, Jenkins, Artifactory, Postgres, DinD, Conan
├── bootstrap.sh / .ps1         # единые точки входа
├── .env.example                # локальные параметры без секретов
├── .gitignore                  # исключает секреты, кэши и артефакты сборки
├── conan1-conan2-migration-runbook.md # пошаговая миграция Conan 1 → 2
├── scenarios/                  # пошаговые сценарии стенда (01–09)
├── scripts/
│   ├── linux/                  # шаги 00–08 для bash
│   └── windows/                # те же шаги для PowerShell
├── jenkins/                    # Dockerfile Jenkins с Conan toolchain
├── postgres/init/              # создание БД Gitea
└── demo/
    ├── conan-migration-sandbox/ # рецепты, профили, lockfiles, CI-скрипты
    └── recipe-demo/             # минимальный Conan 2-рецепт для проверки
```

## Остановка и полный сброс

Остановить стенд, сохранив данные:

```bash
docker compose down
```

Удалить контейнеры **и все данные** (Gitea, Jenkins, Artifactory, Postgres):

```bash
docker compose down -v
```

> `down -v` необратимо удаляет named volumes. Не используйте его, если в
> стенде есть нужные репозитории, jobs или пакеты. После сброса повторите
> `docker compose up -d --build` и bootstrap.

## Troubleshooting

**Порты заняты.** Проверьте, кто слушает `3000`, `8080`, `8082`:

```bash
# Linux/WSL
ss -ltnp | grep -E ':(3000|8080|8081|8082)\b'

# Windows PowerShell
Get-NetTCPConnection -LocalPort 3000,8080,8081,8082 -State Listen
```

Остановите конфликтующий процесс или измените публикацию портов в
`docker-compose.yml`. Если меняете порт Gitea, обновите `GITEA__server__ROOT_URL`
и `GITEA_URL`; для Jenkins — `JENKINS_URL` и URL в настройках.

**Сервис долго не поднимается.** Artifactory на первом старте может занимать
несколько минут. Смотрите:

```bash
docker compose ps
docker compose logs -f artifactory
docker compose logs -f artifactory-init
```

**Bootstrap упал на шаге.** Исправьте причину и запустите bootstrap снова:
шаги идемпотентны. Для диагностики смотрите `SETUP-REPORT.md` и логи
контейнеров. Секреты не попадают в Git, поэтому повторный запуск не требует
ручного удаления `.secrets/`.

**Нужно поменять пароль администратора.** Измените значение в `.env`,
перезапустите Compose (если пароль используется контейнером) и выполните
bootstrap: он обновит администратора Gitea/Jenkins и credentials Jenkins.
Для Artifactory пароль администратора задаётся при инициализации; смена
пароля на уже существующем томе выполняется средствами Artifactory.

## Безопасность

Это локальная лаборатория, а не production-шаблон. Не публикуйте порты в
интернет, не используйте значения из `.env.example` вне локальной машины и не
коммитьте `.env`, `.secrets/`, `SETUP-REPORT.md`, backup-файлы и кэши.
