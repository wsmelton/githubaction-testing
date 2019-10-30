function Get-DbaNetworkCertificate {
    <#
    .SYNOPSIS
        Simplifies finding computer certificates that are candidates for using with SQL Server's network encryption

    .DESCRIPTION
        Gets computer certificates on localhost that are candidates for using with SQL Server's network encryption

    .PARAMETER ComputerName
       The target SQL Server instance or instances. Defaults to localhost. If target is a cluster, you must specify the distinct nodes.

    .PARAMETER Credential
        Allows you to login to $ComputerName using alternative credentials.

    .PARAMETER EnableException
        By default, when something goes wrong we try to catch it, interpret it and give you a friendly warning message.
        This avoids overwhelming you with "sea of red" exceptions, but is inconvenient because it basically disables advanced scripting.
        Using this switch turns this "nice by default" feature off and enables you to catch exceptions with your own try/catch.

    .NOTES
        Tags: Certificate
        Author: Chrissy LeMaire (@cl), netnerds.net

        Website: https://dbatools.io
        Copyright: (c) 2018 by dbatools, licensed under MIT
        License: MIT https://opensource.org/licenses/MIT

    .EXAMPLE
        PS C:\> Get-DbaNetworkCertificate

        Gets computer certificates on localhost that are candidates for using with SQL Server's network encryption

    .EXAMPLE
        PS C:\> Get-DbaNetworkCertificate -ComputerName sql2016

        Gets computer certificates on sql2016 that are being used for SQL Server network encryption

    #>
    [CmdletBinding()]
    param (
        [parameter(ValueFromPipeline)]
        [DbaInstanceParameter[]]$ComputerName = $env:COMPUTERNAME,
        [PSCredential]$Credential,
        [switch]$EnableException
    )

    process {
        # Registry access


        foreach ($computer in $computername) {

            try {
                $sqlwmis = Invoke-ManagedComputerCommand -ComputerName $computer.ComputerName -ScriptBlock { $wmi.Services } -Credential $Credential -ErrorAction Stop | Where-Object DisplayName -match "SQL Server \("
            } catch {
                Stop-Function -Message $_ -Target $sqlwmi -Continue
            }

            foreach ($sqlwmi in $sqlwmis) {

                $regroot = ($sqlwmi.AdvancedProperties | Where-Object Name -eq REGROOT).Value
                $vsname = ($sqlwmi.AdvancedProperties | Where-Object Name -eq VSNAME).Value
                $instancename = $sqlwmi.DisplayName.Replace('SQL Server (', '').Replace(')', '') # Don't clown, I don't know regex :(
                $serviceaccount = $sqlwmi.ServiceAccount

                if ([System.String]::IsNullOrEmpty($regroot)) {
                    $regroot = $sqlwmi.AdvancedProperties | Where-Object { $_ -match 'REGROOT' }
                    $vsname = $sqlwmi.AdvancedProperties | Where-Object { $_ -match 'VSNAME' }

                    if (![System.String]::IsNullOrEmpty($regroot)) {
                        $regroot = ($regroot -Split 'Value\=')[1]
                        $vsname = ($vsname -Split 'Value\=')[1]
                    } else {
                        Write-Message -Level Warning -Message "Can't find instance $vsname on $env:COMPUTERNAME"
                        return
                    }
                }

                if ([System.String]::IsNullOrEmpty($vsname)) { $vsname = $computer }

                Write-Message -Level Verbose -Message "Regroot: $regroot"
                Write-Message -Level Verbose -Message "ServiceAcct: $serviceaccount"
                Write-Message -Level Verbose -Message "InstanceName: $instancename"
                Write-Message -Level Verbose -Message "VSNAME: $vsname"

                $scriptblock = {
                    $regroot = $args[0]
                    $serviceaccount = $args[1]
                    $instancename = $args[2]
                    $vsname = $args[3]

                    $regpath = "Registry::HKEY_LOCAL_MACHINE\$regroot\MSSQLServer\SuperSocketNetLib"

                    $thumbprint = (Get-ItemProperty -Path $regpath -Name Certificate -ErrorAction SilentlyContinue).Certificate

                    try {
                        $cert = Get-ChildItem Cert:\LocalMachine -Recurse -ErrorAction Stop | Where-Object Thumbprint -eq $Thumbprint
                    } catch {
                        # Don't care - sometimes there's errors that are thrown for apparent good reason
                        # here to avoid an empty catch
                        $null = 1
                    }

                    if (!$cert) { continue }

                    [pscustomobject]@{
                        ComputerName   = $env:COMPUTERNAME
                        InstanceName   = $instancename
                        SqlInstance    = $vsname
                        ServiceAccount = $serviceaccount
                        FriendlyName   = $cert.FriendlyName
                        DnsNameList    = $cert.DnsNameList
                        Thumbprint     = $cert.Thumbprint
                        Generated      = $cert.NotBefore
                        Expires        = $cert.NotAfter
                        IssuedTo       = $cert.Subject
                        IssuedBy       = $cert.Issuer
                        Certificate    = $cert
                    }
                }

                try {
                    Invoke-Command2 -ComputerName $computer.ComputerName -Credential $Credential -ArgumentList $regroot, $serviceaccount, $instancename, $vsname -ScriptBlock $scriptblock -ErrorAction Stop |
                        Select-DefaultView -ExcludeProperty Certificate
                } catch {
                    Stop-Function -Message $_ -ErrorRecord $_ -Target $ComputerName -Continue
                }
            }
        }
    }
}