# recipe-demo

Минимальный Conan 2-рецепт для проверки миграции recipe/package revisions.
Gitea используется только как Git-хостинг, а сам пакет публикуется в JFrog
Artifactory. Пакет header-only, поэтому не требует компиляции библиотеки и
хорошо подходит для smoke-теста.

## Состав

```text
.
├── conanfile.py
├── include/recipe_demo/recipe_demo.h
├── profiles/
│   ├── linux-gcc-release
│   └── linux-gcc-debug
├── scripts/bootstrap-remotes.sh
└── test_package/
    ├── CMakeLists.txt
    ├── conanfile.py
    └── test_package.cpp
```

## Локальная проверка

```bash
conan profile detect --force
conan create . --build=missing -pr=profiles/linux-gcc-release
```

Ожидаемый вывод:

```text
recipe-demo: recipe-demo
```

## Публикация в Artifactory

```bash
export CONAN_HOME=/tmp/recipe-demo-target
conan remote add -f packages \
  "http://artifactory:8082/artifactory/api/conan/packages"
conan remote login packages admin -p "$ARTIFACTORY_PASSWORD"

conan create . --build=missing -r=packages -pr=profiles/linux-gcc-release
conan upload "recipe-demo/1.0.0:*" -r=packages -c
conan list "recipe-demo/1.0.0:*" -r=packages
```

Для production замените URL, учётные записи и имена репозиториев; полная
процедура — в [`../../conan1-conan2-migration-runbook.md`](../../conan1-conan2-migration-runbook.md).

## Проверка потребителем

```bash
export CONAN_HOME=/tmp/recipe-demo-consumer
conan remote add -f packages \
  "http://artifactory:8082/artifactory/api/conan/packages"
conan remote login packages admin -p "$ARTIFACTORY_PASSWORD"
conan install --requires=recipe-demo/1.0.0 --build=never -r=packages
```
