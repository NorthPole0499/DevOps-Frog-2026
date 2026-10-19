# Лабораторная работа №1 — Docker

В рамках лабораторной работы исследуются основные механизмы контейнеризации Linux:

- namespaces;
- cgroups v2;
- capabilities;
- seccomp;
- собственный скрипт `mydocker.sh`;
- Docker;
- Docker images и multi-stage build;
- Docker volumes.

Мониторинг и gVisor будут добавлены позже.

## Структура

- `src/api.py` — тестовый HTTP API;
- `mydocker.sh` — запуск приложения с изоляцией и ограничением ресурсов;
- `seccomp_test.py` — демонстрация seccomp;
- `basic.dockerfile` — базовый Docker-образ;
- `multistage.dockerfile` — multi-stage Docker-образ.
