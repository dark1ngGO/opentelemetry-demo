param (
    [Parameter(Mandatory = $true)]
    [array]$ServiceAccounts,  # Массив объектов: @{ Name="имя"; Roles=@("роль1","роль2") }

    [Parameter(Mandatory = $true)]
    [string]$FolderId,        # Папка в ya cloud
     
    [Parameter(Mandatory = $true)]
    [string]$BucketName,      # Имя S3-бакета

    [Parameter(Mandatory = $true)]
    [string]$BucketSize,      # Размер S3-бакета

    [Parameter(Mandatory = $true)]
    [string]$Networkname,     # Имя сети

    [Parameter(Mandatory = $true)]
    [string]$Clustername      # Имя кластера
)

# --- Создание и привязка сервисных аккаунтов ---
foreach ($saDef in $ServiceAccounts) {
    $ServiceAccountName = $saDef.Name
    $Roles = $saDef.Roles

    # Проверяем, существует ли сервисный аккаунт
    $sa = yc iam service-account get --name $ServiceAccountName --folder-id $FolderId --format json 2>$null | ConvertFrom-Json

    if (-not $sa) {
        Write-Host "Service account '$ServiceAccountName' not found. Creating..."
        $createCmd = "yc iam service-account create --name $ServiceAccountName --folder-id $FolderId --format json"
        $sa = Invoke-Expression $createCmd | ConvertFrom-Json
        Write-Host "Service account created: $($sa.id)"
    }
    else {
        Write-Host "Service account '$ServiceAccountName' already exists: $($sa.id)"
    }

    $saId = $sa.id

    # Назначаем роли
    foreach ($role in $Roles) {
        Write-Host "Binding role '$role' for service account $ServiceAccountName ($saId)..."
        & yc resource-manager folder add-access-binding $FolderId `
            --role $role `
            --subject "serviceAccount:$saId"
    }

    # Для sa с ролями storage.admin и storage.editor создаем статический ключ
    if ($Roles -contains "storage.admin" -or $Roles -contains "storage.editor") {
        Write-Host "Creating static key for $ServiceAccountName..."
        $key = yc iam access-key create --service-account-id $saId --format json | ConvertFrom-Json
        Write-Host "Static key created. ID: $($key.id)"
        Write-Host "Access Key ID: $($key.access_key)"
        Write-Host "Secret Key: $($key.secret)"
    }
}

# --- Создание S3-бакета ---
$bucketExists = yc storage bucket get --name $BucketName --folder-id $FolderId --format json 2>$null
if (-not $bucketExists) {
    Write-Host "Bucket '$BucketName' not found. Creating..."
    yc storage bucket create --name $BucketName --folder-id $FolderId --max-size $BucketSize
    Write-Host "Bucket '$BucketName' created."
}
else {
    Write-Host "Bucket '$BucketName' already exists."
}

# --- Создание сети ---
$net = yc vpc network get --name $Networkname --folder-id $FolderId --format json 2>$null | ConvertFrom-Json
if (-not $net) {
    Write-Host "Network '$Networkname' not found. Creating..."
    $net = yc vpc network create --name $Networkname --description "My network" --folder-id $FolderId --format json | ConvertFrom-Json
    Write-Host "Network created: $($net.id)"
}
else {
    Write-Host "Network '$Networkname' already exists: $($net.id)"
}
$NetworkId = $net.id

# --- Функция для подсетей ---
function Get-OrCreateSubnet([string]$name, [string]$zone, [string]$cidr) {
    $s = yc vpc subnet get --name $name --folder-id $FolderId --format json 2>$null | ConvertFrom-Json
    if ($s) {
        if ($s.network_id -ne $NetworkId) {
            throw "Subnet '$name' exists but belongs to another network ($($s.network_id)). Expected network: $NetworkId"
        }
        Write-Host "Subnet '$name' already exists: $($s.id)"
    }
    else {
        Write-Host "Subnet '$name' not found in folder $FolderId. Creating ($zone, $cidr)..."
        $s = yc vpc subnet create --name $name --description "My subnet" --folder-id $FolderId --network-id $NetworkId --zone $zone --range $cidr --format json | ConvertFrom-Json
        Write-Host "Subnet created: $($s.id)"
    }
    return $s.id
}

# --- Создание подсетей ---
$SubnetId = Get-OrCreateSubnet -name "default-ru-central1-a" -zone "ru-central1-a" -cidr "10.128.0.0/24"
$SubnetId_d = Get-OrCreateSubnet -name "default-ru-central1-d" -zone "ru-central1-d" -cidr "10.130.0.0/24"
$SubnetId_b = Get-OrCreateSubnet -name "default-ru-central1-b" -zone "ru-central1-b" -cidr "10.129.0.0/24"

# --- Создание Kubernetes-кластера ---
$kuberAdminSaName = $ServiceAccounts[0].Name
$kuberPullerSaName = $ServiceAccounts[1].Name

$cluster = yc managed-kubernetes cluster get --name $Clustername --folder-id $FolderId --format json 2>$null | ConvertFrom-Json
if (-not $cluster) {
    Write-Host "Cluster '$Clustername' not found. Creating..."
    $cluster = yc managed-kubernetes cluster create `
        --name $Clustername `
        --network-id $NetworkId `
        --master-location zone=ru-central1-a,subnet-id=$SubnetId `
        --service-account-name $kuberAdminSaName `
        --node-service-account-name $kuberPullerSaName `
        --public-ip `
        --folder-id $FolderId `
        --format json | ConvertFrom-Json
    Write-Host "Cluster created: $($cluster.id)"
}
else {
    Write-Host "Cluster '$Clustername' already exists: $($cluster.id)"
}
$ClusterID = $cluster.id

# --- Создание node-group ---
$nodeGroup = yc managed-kubernetes node-group get --name "k8s-test-workers" --cluster-name $Clustername --folder-id $FolderId --format json 2>$null | ConvertFrom-Json
if (-not $nodeGroup) {
    Write-Host "Node-group 'k8s-test-workers' not found. Creating..."
    yc managed-kubernetes node-group create `
        --cluster-name $Clustername `
        --cores 4 `
        --disk-size 50 `
        --disk-type network-ssd `
        --fixed-size 2 `
        --location zone=ru-central1-a `
        --memory 12 `
        --name k8s-test-workers `
        --container-runtime containerd `
        --preemptible `
        --version 1.32 `
        --network-interface subnets=$SubnetId,ipv4-address=nat `
        --folder-id $FolderId
    Write-Host "Node-group 'k8s-test-workers' created."
}
else {
    Write-Host "Node-group 'k8s-test-workers' already exists."
}

# --- Получение kubeconfig ---
yc managed-kubernetes cluster get-credentials --id $ClusterID --external --force

Write-Host "All resources successfully created and configured."

# --- Применяем namespaces ---
Write-Host "Applying namespaces"

kubectl apply -f https://raw.githubusercontent.com/dark1ngGO/opentelemetry-demo/refs/heads/main/projectfiles/telemetryNS.yaml

Write-Host "OK"

# --- Ставим ingress-nginx ---

Write-Host "Installing ingress-nginx"

$HelmChartPath = Join-Path -Path $PSScriptRoot -ChildPath "ingress-nginx"
helm install --namespace ingress-nginx-space ingress-nginx $HelmChartPath

Write-Host "OK"

# --- Ставим argocd ---
Write-Host "Installing argocd"

kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

Write-Host "OK"

# --- Применяем манифесты argocd ---
Write-Host "Applying argocd manifests"

kubectl apply -f https://raw.githubusercontent.com/dark1ngGO/opentelemetry-demo/refs/heads/main/projectfiles/argoman-repo.yaml
kubectl apply -f https://raw.githubusercontent.com/dark1ngGO/opentelemetry-demo/refs/heads/main/projectfiles/argoman-project.yaml
kubectl apply -f https://raw.githubusercontent.com/dark1ngGO/opentelemetry-demo/refs/heads/main/projectfiles/argoman-otel-app.yaml

Write-Host "OK"

# --- Ставим Loki---
Write-Host "Installing Loki"

$LokiValuesPath = Join-Path -Path $PSScriptRoot -ChildPath "loki\values.yaml"
helm install loki grafana/loki-stack --namespace monitoring -f $LokiValuesPath

Write-Host "OK"

Write-Host "Done."