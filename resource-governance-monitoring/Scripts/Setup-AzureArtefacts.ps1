# Define all script parameters
$subscriptionId = "<YOUR AZURE SUBSCRIPTION ID>" 
$rdpUserName = "<YOUR USERNAME FOR REMOTE DESKTOP>"
$rdpPassword = "<YOUR PASSWORD FOR REMOTE DESKTOP>"
$certPassword = "<YOUR PASSWORD TO PROTECT THE CERTIFICATE>"
$resourceGroupName = "demo" + (Get-Date).ToString('ddHHmm')
$azureRegion = "westus"
$keyVaultName = $resourceGroupName + "keyvault"
$keyVaultSecretName = $resourceGroupName + "clustersecret"
$certDnsName = $resourceGroupName + "cluster.westus.cloudapp.azure.com"
$clusterTemplateFile = "..\ClusterSetup\ClusterDeployment\ServiceFabricCluster.json"
$memoryEaterTemplateFile = "..\MemoryEater\MemoryEaterDeployment\memoryeaterapp.json"
$fabricObserverTemplateFile = "..\FabricObserver\FabricObserverDeployment\fabricobserverapp.json"
$storageAccountName = $resourceGroupName + "artefacts"

# Start timer
Write-Host "$(Get-Date -Format '[MM/dd/yy HH:mm:ss]')"

# Connect to Azure
Write-Host "Log: Login to Azure" -ForegroundColor Green
Login-AzAccount
Set-AzContext -SubscriptionId $subscriptionId

# Create the Azure Resource Group
Write-Host "Log: Create Azure Resource Group" -ForegroundColor Green
New-AzResourceGroup -Name $resourceGroupName -Location $azureRegion

# Create Azure Key Vault
Write-Host "Log: Create Azure Key Vault" -ForegroundColor Green
New-AzKeyVault -VaultName $keyVaultName -ResourceGroupName $resourceGroupName -Location $azureRegion -EnabledForDeployment

# Create new self-signed certificate
Write-Host "Log: Create new self-signed certificate" -ForegroundColor Green
$securePassword = ConvertTo-SecureString -String $certPassword -AsPlainText -Force
$certFileFullPath = ".\$certDnsName.pfx"
$certPath = "Cert:\CurrentUser\My"
$certProvider = "Microsoft Enhanced RSA and AES Cryptographic Provider"
$notBeforeDate = Get-Date -Format "yyyy-MM-dd"
$notAfterDate = (Get-Date).AddDays(32).ToString("yyyy-MM-dd")
$certificate = New-SelfSignedCertificate -NotBefore $notBeforeDate -NotAfter $notAfterDate -DnsName $certDnsName -CertStoreLocation $certPath -Provider $certProvider -KeyExportPolicy ExportableEncrypted 
$certFileInfo = Export-PfxCertificate -Cert $certificate -FilePath $certFileFullPath -Password $securePassword 

# Upload new certificate to Azure Key Vault
Write-Host "Log: Upload certificate to Azure Key Vault instance" -ForegroundColor Green
$bytes = [System.IO.File]::ReadAllBytes($certFileInfo.FullName)
$base64 = [System.Convert]::ToBase64String($bytes)

$jsonBlob = @{
    data = $base64
    dataType = 'pfx'
    password = $certPassword
} | ConvertTo-Json

$contentBytes = [System.Text.Encoding]::UTF8.GetBytes($jsonBlob)
$content = [System.Convert]::ToBase64String($contentBytes)

$secretValue = ConvertTo-SecureString -String $content -AsPlainText -Force
$newSecret = Set-AzKeyVaultSecret -VaultName $keyVaultName -Name $keyVaultSecretName -SecretValue $secretValue -Verbose

# Install certificate locally for authentication with SFX
Write-Host "Log: Install certificate in local cert store" -ForegroundColor Green
Import-PfxCertificate -Exportable -CertStoreLocation Cert:\CurrentUser\My -FilePath $certFileFullPath -Password $securePassword

# Create Azure Service Fabric cluster
Write-Host "Log: Create Azure Service Fabric cluster" -ForegroundColor Green
$templateParameter = @{}
$templateParameter.Add("certificateThumbprint", $certificate.Thumbprint)
$templateParameter.Add("sourceVaultResourceId", $(Get-AzKeyVault -VaultName $keyVaultName).ResourceId)
$templateParameter.Add("certificateUrlValue", $newSecret.Id)
$templateParameter.Add("adminUserName", $rdpUserName)
$templateParameter.Add("adminPassword", $rdpPassword)
$templateParameter.Add("resourcePrefix", $resourceGroupName)
$deploymentName = (Get-ChildItem $clusterTemplateFile).BaseName + '-' + (Get-Date).ToString('MMdd-HHmm');
$outputs = New-AzResourceGroupDeployment -Name $deploymentName -ResourceGroupName $resourceGroupName -TemplateFile $clusterTemplateFile -TemplateParameterObject $templateParameter -Verbose -ErrorVariable ErrorMessages

# Get the connection string for Aplication Insights 
Write-Host "Log: Read connection string for Azure Application Insights from ARM template deployment output" -ForegroundColor Green
$aiConnectionString = ""
foreach ($key in $outputs.Outputs.keys) {
    if ($key -eq "appInsightsConnectionString") {
        $aiConnectionString = $outputs.Outputs[$key].value
    }
}

# Set connection string for Application Insights in FabricObserver for telemetry
Write-Host "Log: Insert connection string for Azure Application Insights in Settings.xml from FabricObserver application" -ForegroundColor Green
$filePathToTask = "..\FabricObserver\FabricObserver\PackageRoot\Config\Settings.xml"
$settingsFileInfo = Get-Item $filePathToTask
[xml]$xml = Get-Content -Path $settingsFileInfo.FullName
$ns = New-Object System.Xml.XmlNamespaceManager($xml.NameTable) # added this line
$ns.AddNamespace("ns", "http://schemas.microsoft.com/2011/01/fabric") 
$element = $xml.SelectSingleNode("//ns:Parameter[@Name='AppInsightsConnectionString']", $ns)
$element.SetAttribute("Value", $aiConnectionString)
$xml.Save($settingsFileInfo.FullName)

# NuGet restore for Microsoft.VisualStudio.Azure.Fabric.MSBuild.1.7.6
Write-Host "Log: Install nuget.exe for package restore"
$source = "https://dist.nuget.org/win-x86-commandline/latest/nuget.exe"
$destination = "nuget.exe"
if (-Not [System.IO.File]::Exists($destination)) {
    #Download the file
    Invoke-WebRequest -Uri $source -OutFile $destination
}
.\nuget.exe restore ..\MemoryEater.sln

 # Build deployment package for FabricObserver 
Write-Host "Log: Build FabricObserver application, option local build"
$releaseMode = "Debug"
dotnet publish "..\FabricObserver\FabricObserverApp\FabricObserverApp.sfproj" -c $releaseMode -r win-x64 --self-contained true

Write-Host "Log: Create one deployment file for FabricObserver application, option pre-built app folder" -ForegroundColor Green
$fabricObserverPackagePath = "..\FabricObserver\FabricObserverApp\pkg\$releaseMode\*"
$fabricObserverDestinationFile = "FabricObserver.Windows.SelfContained.3.2.4.831"
$fabricObserverDestinationPath = "..\FabricObserver\Release\"
$fabricObserverDestinationFileZip = $fabricObserverDestinationPath + ".zip"
$fabricObserverDestinationFileSfpgk = $fabricObserverDestinationPath + ".sfpkg"
New-Item -Path "..\FabricObserver" -Name "Release" -ItemType "Directory" -ErrorAction SilentlyContinue
Compress-Archive -Path $fabricObserverPackagePath -DestinationPath $fabricObserverDestinationFileZip -Update
Move-Item -Path $fabricObserverDestinationFileZip -Destination $fabricObserverDestinationFileSfpgk -Force

# Build deployment package for MemoryEater application
Write-Host "Log: Build MemoryEater application, option local build" -ForegroundColor Green
dotnet publish "..\MemoryEater\MemoryEaterApp\MemoryEaterApp.sfproj" -c "Release" -r win-x64 --self-contained true

Write-Host "Log: Create one deployment file for MemoryEater application, option after local build" -ForegroundColor Green
$memoryEaterPackagePath = "..\MemoryEater\MemoryEaterApp\pkg\Release\*"
$memoryEaterDestinationFile = "MemoryEater.1.0.0"
$memoryDestinationPath = "..\MemoryEater\Release\"
$memoryEaterDestinationFileZip = $memoryDestinationPath + $memoryEaterDestinationFile + ".zip"
$memoryEaterDestinationFileSfpgk = $memoryDestinationPath + $memoryEaterDestinationFile + ".sfpkg"
New-Item -Path "..\MemoryEater" -Name "Release" -ItemType "Directory" -ErrorAction SilentlyContinue
Compress-Archive -Path $memoryEaterPackagePath -DestinationPath $memoryEaterDestinationFileZip -Update
Move-Item -Path $memoryEaterDestinationFileZip -Destination $memoryEaterDestinationFileSfpgk -Force

# Prepare storage for artefacts
Write-Host "Log: Create Azure Storage account with container for application artefacts" -ForegroundColor Green
$storageContainerName = 'stageartifacts'
$storageAccount = New-AzStorageAccount -StorageAccountName $storageAccountName -Type 'Standard_LRS' -ResourceGroupName $resourceGroupName -Location $azureRegion
New-AzStorageContainer -Name $storageContainerName -Context $storageAccount.Context

# Upload artefacts for FabricObserver
Write-Host "Log: Upload FabricObserver artefacts" -ForegroundColor Green
$fabricObserverFile = $fabricObserverDestinationFile + ".sfpkg"
Set-AzStorageBlobContent -Container $storageContainerName -File $fabricObserverDestinationFileSfpgk -Blob $fabricObserverFile -Context $storageAccount.Context

# Upload artefacts for Demo App
Write-Host "Log: Upload MemoryEater artefacts" -ForegroundColor Green
$memoryEaterFile = $memoryEaterDestinationFile + ".sfpkg"
Set-AzStorageBlobContent -Container $storageContainerName -File $memoryEaterDestinationFileSfpgk -Blob $memoryEaterFile -Context $storageAccount.Context

# Generate a 1 hour SAS token for the artifacts location 
Write-Host "Log: Generate SAS token to access artefacts" -ForegroundColor Green
$sasToken = New-AzStorageContainerSASToken -Container $storageContainerName -Context $storageAccount.Context -Permission r -ExpiryTime (Get-Date).AddHours(1)

# Deploy apps as ARM application resource to Service Fabric Cluster
Write-Host "Log: Create artefacts location URL for ARM template parameter file" -ForegroundColor Green
$artifactsLocationName = $storageAccount.Context.BlobEndPoint + $storageContainerName + '/'
$fabricObserverPackageUrl = $artifactsLocationName + $fabricObserverFile + $sasToken
$memoryEaterPackageUrl = $artifactsLocationName + $memoryEaterFile + $sasToken

Write-Host "Log: Deploy MemoryEater to cluster via ARM application resource deployment" -ForegroundColor Green
$memoryEaterTemplateParameter = @{}
$memoryEaterTemplateParameter.Add("clusterName", $resourceGroupName + "cluster")
$memoryEaterTemplateParameter.Add("memoryEaterApplicationTypeVersion", "1.0.0")
$memoryEaterTemplateParameter.Add("memoryEaterPackageLocation", $memoryEaterPackageUrl)
$deploymentName = (Get-ChildItem $memoryEaterTemplateFile).BaseName + '-' + (Get-Date).ToString('MMdd-HHmm');
New-AzResourceGroupDeployment -Name $deploymentName -ResourceGroupName $resourceGroupName -TemplateFile $memoryEaterTemplateFile -TemplateParameterObject $memoryEaterTemplateParameter -Verbose -ErrorVariable ErrorMessages

Write-Host "Log: Deploy FabricObserver to cluster via ARM application resource deployment" -ForegroundColor Green
$fabricObserverTemplateParameter = @{}
$fabricObserverTemplateParameter.Add("clusterName", $resourceGroupName + "cluster")
$fabricObserverTemplateParameter.Add("fabricObserverApplicationTypeVersion", "3.2.4.831")
$fabricObserverTemplateParameter.Add("fabricObserverPackageLocation", $fabricObserverPackageUrl)
$deploymentName = (Get-ChildItem $fabricObserverTemplateFile).BaseName + '-' + (Get-Date).ToString('MMdd-HHmm');
New-AzResourceGroupDeployment -Name $deploymentName -ResourceGroupName $resourceGroupName -TemplateFile $fabricObserverTemplateFile -TemplateParameterObject $fabricObserverTemplateParameter -Verbose -ErrorVariable ErrorMessages

Write-Host "$(Get-Date -Format '[MM/dd/yy HH:mm:ss]')"

Write-Host "SFX: $($certDnsName):19080"
Write-Host "Dashboard: $($certDnsName):8081"
Write-Host "API: $($certDnsName):8081/api/addstring/10"
