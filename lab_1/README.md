# Лабораторная работа №1 — Docker
## Этап 0
Мною был создан небольшой HHTP-сервис на Python c использованием flask
В нем было три эндпоинта `/healt`, `/eat?mb=N`, `/burn` и `/metrics`

Эндпоинт `/health` использовался для проверки сервиса 

Эндпоинт `/eat` был нужен для экспериментов с ограничением памяти через cgroups

Эндпоинт `/burn` создаёт бесконечную вычислительную нагрузку на CPU 

Также в сервис был добавлен эндпоинт `/metrics`, через который Prometheus получает метрики работы приложения

После запуска сервис был проверен командой:

```bash
curl http://localhost:8080/health
```
![Проверка работы API](./img/Screenshot%202026-09-27%20225215.png)

## Этап 1 

Изначально мы запустили сервис без изоляции. После запуска сервиса был найден PID

```bash
pgrep -af api.py
```
Также была просмотрена информация о PID, PPID, пользователе и потреблении ресурсов
```bash
ps -o pid,ppid,user,%cpu,%mem,cmd -p <PID>
```

![PID и PPID процесса](./img/Screenshot%202026-09-27%20230046.png)

## Этап 2

Далее я начал изучать namespaces. Namespaces позволяют изолировать процессы друг от друга 

Сначала был создан отдельный PID namespace:

```bash
sudo unshare --pid --fork --mount-proc bash
```

После этого был проверен PID процесса

```bash
echo $$
```

Внутри нового namespace процесс получил PID `1`. При этом для основной системы этот же процесс имеет другой PID.
Далее была проверена одновременная изоляция нескольких namespaces

```bash
sudo unshare --pid --fork --mount --mount-proc --uts --ipc --net bash
```

Для проверки UTS namespace я изменил hostname

```bash
hostname my-container
hostname
```

Внутри namespace hostname стал `my-container`, при этом hostname основной системы не изменился никак

Отдельно был протестирован user namespace

```bash
sudo unshare --user --map-root-user --pid --fork --mount-proc bash
```

Для проверки были выполнены команды
```bash
whoami
id
echo $$
```

Внутри namespace пользователь отображался как `root`, а процесс имел PID `1`.

Таким образом удалось убедиться, что namespaces позволяют изолировать PID, hostname, сеть и пользователей процесса.

![Проверка namespaces](./img/Screenshot%202026-09-27%20231258.png)


## Этап 3. Cgroups v2

Далее надо было ограничить ресурсы процесса с помощью cgroups

Сначала была проверена используемая версия cgroups. Также были просмотрены доступные контроллерыю Среди доступных контроллеров присутствовали `cpu`, `memory` и `pids`.

### Ограничение памяти

Была создана отдельная cgroup

```bash
sudo mkdir /sys/fs/cgroup/lab1
```

Юыл установлен лимит оперативной памяти 100 мб

```bash
echo 104857600 | sudo tee /sys/fs/cgroup/lab1/memory.max
echo 0 | sudo tee /sys/fs/cgroup/lab1/memory.swap.max
```

После запуска API его PID был добавлен в созданную cgroup

```bash
echo <PID> | sudo tee /sys/fs/cgroup/lab1/cgroup.procs
```

Для проверки ограничения памяти использовался эндпоинт `/eat`.

```bash
curl "http://localhost:8080/eat?mb=40"
```

При небольшом объёме памяти сервис продолжал работать. После попытки выделить памяти больше установленного лимита процесс был завершён системой

```bash
curl "http://localhost:8080/eat?mb=100"
```

Состояние cgroup можно было посмотреть командой

```bash
cat /sys/fs/cgroup/lab1/memory.events
```

В результате счётчики `oom` и `oom_kill` увеличились. Это означает, что ограничение памяти действительно сработало и процесс был завершён механизмом OOM.

![Ограничение памяти через cgroups](./img/Screenshot%202026-10-19%20215305.png)


### Ограничение CPU и количества процессов

Аналогично были поставлены ограничения на процессорное время и количесвто процессов

Для cgroup был установлен лимит

```bash
echo "20000 100000" | sudo tee /sys/fs/cgroup/lab1/cpu.max
```

Такое значение ограничивает процесс примерно 20% одного ядра CPU.

Для нагрузки использовался эндпоинт burn

```bash
curl http://localhost:8080/burn
```

После этого статистика cgroup была просмотрена командой

```bash
cat /sys/fs/cgroup/lab1/cpu.stat
```


![Ограничение CPU и throttling](./img/Screenshot%202026-10-19%20220325.png)



Для количесвта процессов был установлен небольшой лимит

```bash
echo 5 | sudo tee /sys/fs/cgroup/lab1/pids.max
```

После этого были запущены несколько фоновых процессов

```bash
sleep 1000 &
```

При достижении установленного лимита новые процессы переставали создаваться.

Текущее количество процессов и статистику ограничения можно было посмотреть командами:

```bash
cat /sys/fs/cgroup/lab1/pids.current
cat /sys/fs/cgroup/lab1/pids.events
```

![Ограничение количества процессов](./img/Screenshot%202026-10-19%20220752.png)


## Этап 4

Также была рассмотрена дополнительная изоляция прав процесса. Capabilities и Seccomp

Linux capabilities позволяют убрать у процесса отдельные привилегии root-пользователя, не забираяправа

Для эксперимента была отключена capability `CAP_SYS_TIME` и выполнена попытка изменить системное время

```bash
capsh --drop=cap_sys_time -- -c 'date -s "2030-01-01"'
```

Нам не удалось изменить время, так как не был прав



seccomp позволяет ограничивать системные вызовы, которые процесс может выполнять.

Для проверки был создан файл `seccomp_test.py`.

В нём с помощью seccomp были запрещены системные вызовы `mkdir` и `mkdirat`.

После загрузки фильтра программа пыталась создать директорию

```python
os.mkdir("/tmp/seccomp-test")
```

В результате была ошибка

```text
PermissionError: [Errno 1] Operation not permitted
```

При этом остальные разрешенные системные вызовы продолжали работать корректео


![Проверка seccomp](./img/Screenshot%202026-10-19%20224142.png)


## Этап 5

После изучения отдельных механизмов я попробовал объединить их в один скрипт.Для этого был создан файл:

```text
mydocker.sh
```
В скрипте использовался `unshare` для создания namespaces

Также создавалась отдельная cgroup с ограничениями

```text
Memory: 100 MB
CPU: 20%
PIDs: 20
```

Через `capsh` у процесса также удалялись некоторые capabilities

```text
CAP_SYS_ADMIN
CAP_SYS_TIME
CAP_NET_ADMIN
CAP_SYS_MODULE
```

После этого внутри созданного окружения запускался наш Python API.

При запуске скрипта процесс внутри изолированного окружения имел PID `1`, hostname `my-container`, а cgroups ограничивали доступные ему ресурсы.

Так мы собрали упрощенный контейнер которые до этого проверяли отдельно

![Запуск собственного контейнера mydocker.sh](./img/Screenshot%202026-10-19%20224556.png)



## Этап 6

Далее установили уже сам Docker. Мы запустили наш сервис внутри контейнера с ограническиями ресурсов

```bash
docker run \
  --memory=100m \
  --cpus=0.2 \
  --pids-limit=20 \
  -p 8080:8080 \
  lab1-api
```

Здесь те же ограничения что использовались ранее в cgroups
Мы также проверили работоспособность нашего приложение через запрос health на что получели удовлетворительный ответ OK

Для приложения был создан Dockerfile, который устанавливал необходимые Python-зависимости, копировал `api.py` и запускал приложение внутри контейнера. Это дало нав возможность упаковать все в единый docker image


### Multi-stage build

ДАлее подготовили два варианта docker image. Один с базовый Python image. Второй с помощью multi-stage build. 
Далее были подготовлены два варианта Docker image.

На первой стадии создавалось Python-окружение и устанавливались зависимости

```dockerfile
FROM python:3.14 AS builder
```

далее переносилось виртуальное окружение в более легкий image

```dockerfile
FROM python:3.14-slim
```

Оба образа были собраны и сравнены командой

```bash
docker images lab1-api
```

![Docker и multi-stage build](./img/Screenshot%202026-10-20%20002133.png)


### Docker Volumes


Далее проверили работу файлов внутри контейнера.
сперва создали файл
```bash
echo "test-data" > /tmp/test.txt
```
После удаление  контейнера этот файл исчез. Значит файловая система хранения не позволяет постоянно хранить данные

Далее был создан Docker volume

```bash
docker volume create lab1-data
```

Volume подключался к контейнеру в директорию `/data`. После создания файла в `/data`, удаления контейнера и запуска нового контейнера с тем же volume данные сохранились.

Таким образом Docker volumes позволяют хранить данные независимо от контейнера


## Этап 7
Далее мы рассмотрели технологию gVisor, она добовляет дополнительную изоляцию между приложениям внутри коптейнера и ядром ОС
После работы с обычным Docker была дополнительно рассмотрена технология gVisor.

После установки runtime `runsc` он был добавлен в Docker.

Для проверки был запущен тестовый контейнер и проверен используемый runtime

```bash
docker run -d --runtime=runsc --name gvisor-check ubuntu sleep 1000

docker inspect gvisor-check --format '{{.HostConfig.Runtime}}'
```

Результат
```text
runsc
```

Таким образом контейнер был успешно запущен с использованием gVisor вместо стандартного Docker runtime.

![Запуск контейнера через gVisor](./img/Screenshot%202026-10-20%20170132.png)

![Проверка runtime runsc](./img/Screenshot%202026-10-20%20171401.png)


## Этап 8

Также был добавлин мониторинг процессов через Prometheus для сбора метрик и Grafana для визуализации

В Python API был добавлен эндпоинт:

```text
/metrics
```

Он отдаёт метрики приложения в формате Prometheus.

Также был создан файл

```text
monitoring/prometheus/prometheus.yml
```

В Prometheus были добавлены два источника метрик

```text
flask-api
cadvisor
```

После запуска Prometheus была выполнена проверка Targets.

Оба источника находились в состоянии `UP`, то есть Prometheus успешно получал данные.

![Prometheus Targets](./img/Screenshot%202026-10-20%20173626.png)

### Grafana

Далее мы сделали визуализацию метрик в Graafna. 

Prometheus был подключён к Grafana в качестве Data Source. После этого был создан dashboard с тремя основными графиками.
 

#### Memory Usage

Текущее использование RAM

```promql
container_memory_working_set_bytes{name="lab1-api"}
```

Лимит памяти

```promql
container_spec_memory_limit_bytes{name="lab1-api"}
```


#### CPU Usage

Для отображения использования CPU использовался запрос

```promql
rate(container_cpu_usage_seconds_total{name="lab1-api"}[1m])
```

Лимит на CPU
```promql
container_spec_cpu_quota{name="lab1-api"}
/
container_spec_cpu_period{name="lab1-api"}
```


#### CPU Throttling

Отдельно был построен график CPU throttling:

```promql
100 *
rate(container_cpu_cfs_throttled_periods_total{name="lab1-api"}[1m])
/
rate(container_cpu_cfs_periods_total{name="lab1-api"}[1m])
```

Для проверки создали нагрузку через /burn

```bash
timeout 20s curl http://localhost:8080/burn
```

На графиек видно увеличение всех показателей

![Grafana dashboard](./img/Screenshot%202026-10-20%20183634.png)

### Ужас работы через ВМ

Начиная с этапа 7 ВМ потихоньку начала умирать. 3 раза ВМ отказывалась на что либо реагировать и приходилось перезагружать, каждая перезагрузка убила надежду на сохранения всех данных, так как заливалось в гит все разом после мониторинга. Очень интересно тыкаться и все вручную сравнивать (контейнеры, ручную изоляцию и тд) Но уверен что если бы не ВМ то удолвольствия было бы больше

