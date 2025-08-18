param (
    [Parameter(Mandatory = $true)]
    [array]$ServiceAccounts,  # Массив объектов: @{ Name="имя"; Roles=@("роль1","роль2") }

    [Parameter(Mandatory = $true)]
    [string]$FolderId,        # Папка для сервисных аккаунтов
     
    [Parameter(Mandatory = $true)]
    [string]$BucketName,       # Имя S3-бакета

    [Parameter(Mandatory = $true)]
    [string]$BucketSize      # Размер s3 бакета
)

# --- Создание и привязка сервисных аккаунтов ---
foreach ($saDef in $ServiceAccounts) {
    $ServiceAccountName = $saDef.Name
    $Roles = $saDef.Roles

    # Проверяем, существует ли сервисный аккаунт
    $sa = yc iam service-account get --name $ServiceAccountName --format json 2>$null | ConvertFrom-Json

    if (-not $sa) {
        Write-Host "Service account '$ServiceAccountName' not found. Creating..."
        $createCmd = "yc iam service-account create --name $ServiceAccountName --folder-id $FolderId --format json"
        $sa = Invoke-Expression $createCmd | ConvertFrom-Json
        Write-Host "Service account created: $($sa.id)"
    } else {
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
# Проверяем, существует ли бакет
$bucketExists = yc storage bucket get --name $BucketName --format json 2>$null
if (-not $bucketExists) {
    Write-Host "Bucket '$BucketName' not found. Creating..."
    yc storage bucket create --name $BucketName --folder-id $FolderId --max-size $BucketSize
    Write-Host "Bucket '$BucketName' created."
} else {
    Write-Host "Bucket '$BucketName' already exists."
}

Write-Host "All service accounts processed and bucket verified."