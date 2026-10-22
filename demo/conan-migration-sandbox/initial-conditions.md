# Начальные условия

## Дерево элементов

```text
conan
artifactory-build-info
conan-local
conan-ap
└── ap
conan-thirdparty
└── ap-thirdparty
generic-local
conan-remote
conan-remote-cache
```

## Состав

| №   | Элемент                  | Уровень                        | Назначение                                                                 |
| --- | ------------------------ | ------------------------------ | -------------------------------------------------------------------------- |
| 1   | `conan`                  | корневой                       | виртуальный репозиторий — точка входа для Conan 1                          |
| 2   | `artifactory-build-info` | корневой                       | служебный репозиторий build-info, не Conan-репозиторий                     |
| 3   | `conan-local`            | корневой                       | локальный source-репозиторий Conan 1                                       |
| 4   | `conan-ap`               | корневой                       | родительский узел для `ap`                                                 |
| 5   | `ap`                     | вложенный в `conan-ap`         | локальный source-элемент; имя не содержит префикса с дефисом и не менялось |
| 6   | `conan-thirdparty`       | корневой                       | родительский узел для third-party-элемента                                 |
| 7   | `ap-thirdparty`          | вложенный в `conan-thirdparty` | third-party-элемент с заменённым префиксом                                 |
| 8   | `generic-local`          | корневой                       | generic-репозиторий для не-Conan артефактов                                |
| 9   | `conan-remote`           | корневой                       | remote-репозиторий ConanCenter                                             |
| 10  | `conan-remote-cache`     | корневой                       | кеш remote-репозитория                                                     |
