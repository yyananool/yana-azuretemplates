Configuration AppsConfiguration
{
    param (
        [Bool] $installEkranServer,
        [Bool] $installPGServer,
		[String] $sqlServerType,
        [String] $sqlServerHostname,
        [String] $sqlServerPort,
        [String] $managementToolUrl,
        [String] $subNetPrefix,
        [PSCredential] $sqlServerUser,
        [PSCredential] $mtDefaultUser
	)
    Import-DscResource -ModuleName 'PSDesiredStateConfiguration'
    
    Node localhost
    {

        Script InstallPostgreSQL {
            SetScript = {
                $fileName = "postgresql-13.1-1-windows-x64.exe"
                $filePath = "$env:TEMP\$fileName"
                $dataDir = "C:\Program Files\PostgreSQL\13\data"

                Get-Disk | Where-Object partitionstyle -eq 'raw' | Initialize-Disk -PartitionStyle GPT -PassThru | New-Partition -DriveLetter "G" -UseMaximumSize | Format-Volume -FileSystem NTFS -Confirm:$false
                New-PSDrive -Name "G" -Root "G:\" -PSProvider "FileSystem"
                $dataDir = "G:\PostgreSQL\13\data"

                Invoke-WebRequest -Uri http://get.enterprisedb.com/postgresql/$fileName -OutFile $filePath -UseBasicParsing
                & "$filePath" --mode unattended --superaccount $Using:sqlServerUser.UserName --superpassword $sqlServerUser.GetNetworkCredential().Password  --servicepassword $sqlServerUser.GetNetworkCredential().Password --serverport $Using:sqlServerPort --datadir $dataDir

                $proc = Get-Process -Name $fileName.Substring(0,$fileName.Length-4)
                While ($proc) {
                    if ($proc) {
                        Start-Sleep 10
                        $proc = Get-Process -Name $fileName.Substring(0,$fileName.Length-4) -ErrorAction SilentlyContinue
                    }
                    else {
                        Exit
                    }
                }

                if ( -Not $Using:installEkranServer) {
                    New-NetFirewallRule -DisplayName "PostgreSQLServer" -Direction Inbound -LocalPort $Using:sqlServerPort -Protocol TCP -Action Allow
                    $oldConfig = Get-Content -Path $dataDir\pg_hba.conf
                    Set-Content -Value $oldConfig.Replace('127.0.0.1/32', $Using:subNetPrefix) -Path $dataDir\pg_hba.conf -Force
                    Restart-Service -Name "postgresql*" -Force
                }
            }
            
            TestScript = { 
                if ($Using:installPGServer) {
                    if (Get-Process -Name "postgre*" -ErrorAction SilentlyContinue) {
                        return $true
                    }
                    else {
                        return $false
                    }
                }
                else {
                    return $true
                }
            }
            
            GetScript = { @{ Result = 'PostgreSQL is installed' } }
        }

        Script InstallNetFramework {
            SetScript = {
                $fileName = "ndp48-x86-x64-allos-enu.exe"
                $filePath = "$env:TEMP\$fileName"

                Invoke-WebRequest -Uri https://download.visualstudio.microsoft.com/download/pr/014120d7-d689-4305-befd-3cb711108212/0fd66638cde16859462a6243a4629a50/$fileName -OutFile $filePath -UseBasicParsing

                if ($?) {
	                & "$filePath" '/q' 
                    $proc = Get-Process -Name $fileName.Substring(0,$fileName.Length-4)

                    While ($proc) {
                        Start-Sleep 10
                        $proc = Get-Process -Name $fileName.Substring(0,$fileName.Length-4) -ErrorAction SilentlyContinue
                    }
                }
                else {
	                Throw "ERROR: .NET Framework installation failed"
	
                }
                # Waiting for the host reboot by the .NET installer (usually takes up to 2 min)
                Start-Sleep -Seconds 900
            }
            
            TestScript = { 
                $NetFrameworkReleaseVersion = (Get-ItemProperty "HKLM:SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full").Release

                if ($Using:installEkranServer -and ($NetFrameworkReleaseVersion -lt 528040)) {
                    return $false
                }
                else {
                    return $true
                }
            }
            
            GetScript = { @{ Result = '.NET Framework version is 4.8.X' } }
            DependsOn = "[Script]InstallPostgreSQL"
        }

        Script DownloadMSCppRedist {
            SetScript = {
                $fileName = "vc_redist.x64.exe"
                $filePath = "$env:TEMP\$fileName"
                Invoke-WebRequest -Uri https://download.microsoft.com/download/9/3/F/93FCF1E7-E6A4-478B-96E7-D4B285925B00/vc_redist.x64.exe -OutFile $filePath -UseBasicParsing
            }
            
            TestScript = { -Not $Using:installEkranServer }
                        
            GetScript = { @{ Result = 'Microsoft Visual C++ 2015 Redistributable has been downloaded' } }
        } 
        
        Script InstallMSCppRedist {
            SetScript = {
                $MSCppRedistFullPath = "$env:TEMP\vc_redist.x64.exe"
                & "$MSCppRedistFullPath" '/passive', '/quite'
            }
            
            TestScript = { -Not $Using:installEkranServer }
            
            GetScript = { @{ Result = 'Microsoft Visual C++ 2015 Redistributable has been installed' } }
            DependsOn = "[Script]DownloadMSCppRedist"
        }

        Script DownloadEkranServer {
            SetScript = {
                $fileName = "EkranSystem-en.zip"
                $filePath = "$env:TEMP\$fileName"
                Invoke-WebRequest -Uri https://www.ekransystem.com/sites/default/files/ekransystem/EkranSystem-en.zip -OutFile $filePath -UseBasicParsing

                $destination = "$env:TEMP\EkranSystem"
                Expand-Archive -Path $filePath -DestinationPath $destination -Force
            }
            
            TestScript = { -Not ($Using:installEkranServer) }
            
            GetScript = { @{ Result = 'EkranServer installation archive was downloaded' } }
        } 

        Script CreateIniFile {
		    SetScript = {
                if ($Using:installPGServer -and $Using:installEkranServer) {
                    $sqlInstanceName = 'localhost'
                }
                else {
                    $sqlInstanceName = $Using:sqlServerHostname
                }
                $mtAdminCred = $Using:mtDefaultUser
			    $OFS = "`r`n"
                $ConfigText = 
                "[Database]" +$OFS+ `
                "DBType=" + $Using:sqlServerType +$OFS+ `
                "ServerInstance=" + $sqlInstanceName + ":" + $Using:sqlServerPort +$OFS+ `
                "DBName=EkranActivityDB" +$OFS+ `
                "DBUserName=" + $Using:sqlServerUser.UserName +$OFS+ `
                "DBPassword=" + $sqlServerUser.GetNetworkCredential().Password +$OFS+ `
                "UseExistingDatabase=false" +$OFS+ `
				"Authentication=1" +$OFS+$OFS+ `
                
                "[Admin]" +$OFS+ `
                "AdminPassword=" + $mtAdminCred.GetNetworkCredential().Password +$OFS+$OFS+ `

                "[MT]" +$OFS+ `
                "ServerPath=localhost" +$OFS+ `
                "WebManagementUrl=" + $Using:managementToolUrl
             
                $EkranServerFullPath = Get-ChildItem -Path "$env:TEMP" -Filter EkranSystem_Server_*  -Recurse | % {$_.FullName}
                $EkranServerInstallerBaseName = Get-ChildItem -Path "$env:TEMP" -Filter EkranSystem_Server_*  -Recurse | % {$_.BaseName}
                $EkranServerInstallerBaseName = [string]::Concat($EkranServerInstallerBaseName, ".exe")
                $EkranServerInstallerDir = $EkranServerFullPath.TrimEnd($EkranServerInstallerBaseName)
				
                Set-Content $ConfigText -Path "$EkranServerInstallerDir\install.ini"
            }
            
            TestScript = { -Not ($Using:installEkranServer) }
            
            GetScript = { @{ Result = 'EkranServer configuration INI file has been created' } }
            DependsOn = "[Script]DownloadEkranServer"
        } 

        Script InstallEkranServer {
            SetScript = {
                $EkranServerFullPath = Get-ChildItem -Path "$env:TEMP" -Filter EkranSystem_Server_*  -Recurse | %{$_.FullName}
                & "$EkranServerFullPath" '/S'
                
                $proc = Get-Process -Name "EkranSystem*"
                While ($proc) {
                    if ($proc) {
                        Start-Sleep 10
                        $proc = Get-Process -Name "EkranSystem*" -ErrorAction SilentlyContinue
                    }
                    else {
                        Exit
                    }
                }
            }
            
            TestScript = { -Not $Using:installEkranServer }
            
            GetScript = { @{ Result = 'EkranServer has been installed' } }
            DependsOn = "[Script]InstallPostgreSQL", "[Script]DownloadEkranServer", "[Script]CreateIniFile"
        }

        WindowsFeatureSet ManagementToolRequirements
        {
            Name                    = @("Web-WebServer", "Web-WebSockets", "Web-Asp-Net", "Web-Asp-Net45", "Web-Mgmt-Console")
            Ensure                  = if ($installEkranServer) {'Present'} else { 'Absent' }
            IncludeAllSubFeature    = $true
            DependsOn = "[Script]InstallNetFramework"
        }

        Script CreateSelfSignedCertificate {
            SetScript = {
                
                $site = "Default Web Site"
                
                New-WebBinding -Name $site -IPAddress * -Port 443 -Protocol https
                $cert = New-SelfSignedCertificate -CertStoreLocation 'Cert:\LocalMachine\My' -DnsName "ekransystem"

                $certPath = "Cert:\LocalMachine\My\$($cert.Thumbprint)"
                $providerPath = 'IIS:\SslBindings\0.0.0.0!443'

                Get-Item $certPath | New-Item $providerPath
            }
            
            TestScript = { -Not $Using:installEkranServer }
            
            GetScript = { @{ Result = 'Self-signed cerificate has been generated' } }
            DependsOn = "[WindowsFeatureSet]ManagementToolRequirements"
        } 
        

        Script InstallEkranMt {
            SetScript = {
                $EkranMtFullPath = Get-ChildItem -Path "$env:TEMP" -Filter EkranSystem_ManagementTool_*  -Recurse | %{$_.FullName}
                & "$EkranMtFullPath" '/S'

                $proc = Get-Process -Name "EkranSystem*"
                While ($proc) {
                    if ($proc) {
                        Start-Sleep 10
                        $proc = Get-Process -Name "EkranSystem*" -ErrorAction SilentlyContinue
                    }
                    else {
                        Exit
                    }
                }
            }
            
            TestScript = { -Not $Using:installEkranServer }
            
            GetScript = { @{ Result = 'EkranServer Management Tool has been installed' } }
            DependsOn = "[WindowsFeatureSet]ManagementToolRequirements", "[Script]DownloadEkranServer", "[Script]CreateIniFile", "[Script]CreateSelfSignedCertificate"
        }

        Script InstallEkranAgent {
            SetScript = {
                $EkranServerFolder = "C:\Program Files\Ekran System\Ekran System\Server\"
                $ConfigText = "[AgentParameters]" + "`r`n" + "RemoteHost=localhost" + "`r`n" + "RemotePort=9447"
                Set-Content $ConfigText -Path "$EkranServerFolder\agent.ini"
                & "$EkranServerFolder\agent.exe"
            }
            
            TestScript = { -Not $Using:installEkranServer }
            
            GetScript = { @{ Result = 'EkranAgent has been installed' } }
            DependsOn = "[Script]InstallEkranServer" 
        }
        
    }
}