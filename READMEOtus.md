# Проект микросервисного приложения на основе Kubernetes для OTUS

За основу был взят репозиторий [opentelemetry-demo](https://github.com/open-telemetry/opentelemetry-demo).  
Это приложение интернет-магазина, построенное на микросервисной архитектуре.  
Проект доработан для разворачивания в **Yandex Cloud**.

---

## Требования

1. **Операционная система**: Windows 10 или 11.  
2. **Предварительно установленные утилиты**:
   - [Yandex CLI](https://yandex.cloud/ru/docs/cli/quickstart#install)  
   - [kubectl](https://kubernetes.io/docs/tasks/tools/)  
   - [Helm](https://helm.sh/docs/intro/install/)  

   ⚠️ После установки необходимо инициализировать Yandex CLI.  

3. **Подготовленная инфраструктура в Yandex Cloud**:
   - [Создание платежного аккаунта](https://yandex.cloud/ru/docs/billing/concepts/billing-account)  
   - [Создание облака](https://yandex.cloud/ru/docs/resource-manager/operations/cloud/create)  
   - [Создание каталога](https://yandex.cloud/ru/docs/resource-manager/operations/folder/create)  

   При создании каталога необходимо сохранить его **ID** — он потребуется для разворачивания кластера.

# Разворачивание кластера и сервисов.

1. Склонировать данный репозиторий на машину под управлением OS Windows 10 или 11.
2. Затем в powershell запустить скрипт .\projectfiles\create-kuber-cluster.ps1 со следующими парамтерами:

```
.\projectfiles\create-kuber-cluster.ps1 `
    -FolderId "xxxx" `
    -BucketName "xxxx" `
    -BucketSize "10737418240" `
    -Networkname "xxxx" `
    -Clustername "xxxx" `
    -ServiceAccounts @(
        @{ Name = "sa-kuber-admin"; Roles = @("vpc.publicAdmin", "editor", "k8s.clusters.agent") },
        @{ Name = "sa-puller"; Roles = @("container-registry.images.puller") },
        @{ Name = "sa-objectstorage"; Roles = @("storage.admin", "storage.viewer", "storage.editor") }
)
```
Где :

FolderId - ID директории, который Вы сохранили при создании.
BucketName - Имя бакета S3 хранилища.
BucketSize - Размер бакета S3 хранилища.
Networkname - Имя сети
Clustername - Имя кластера kubernetes
ServiceAccounts - Параметры сервисных аккаунтов. Имена могут быть любые, но роли должны остаться теми же.

4. После выполнения скрипта посмотреть external ip-адрес ingress контроллера командой kubectl get svc -n ingress-nginx-space и открыть grafana по адресу http://<external_ip_ingress_controller>/grafana .
5. В grafana добавить источник данных loki, в качестве url указать http://loki.monitoring.svc.cluster.local:3100, а так же импортировать дашборды из файлов:
.\projectfiles\Logs _ App-1755449641512.json
.\projectfiles\Kubernetes _ Views _ Global-1755449622473.json
.\projectfiles\Spanmetrics Demo Dashboard with Alerts-1755449695690.json
6. Посмотреть командой kubectl get svc -n otel-demo | grep frontend-external ip-адрес сервиса, и перейти по адресу http://<external_ip_ingress_controller>:8080, чтобы проверить работу фронтэнда.