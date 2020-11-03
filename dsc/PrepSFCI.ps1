#
# CopyrightMicrosoft Corporation. All rights reserved."
#

configuration PrepSFCI
{
    param
    (
        [Parameter(Mandatory)]
        [String]$DomainName,

        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$AdminCreds,

        [Parameter(Mandatory)]
        [String]$ClusterName,

        [String]$DomainNetbiosName=(Get-NetBIOSName -DomainName $DomainName),

        [Int]$RetryCount=20,
        [Int]$RetryIntervalSec=30
    )

    Import-DscResource -ModuleName xComputerManagement,ActiveDirectoryDsc,xFailOverCluster,ComputerManagementDsc,xNetworking

    [System.Management.Automation.PSCredential]$DomainCreds = New-Object System.Management.Automation.PSCredential ("${DomainNetbiosName}\$($Admincreds.UserName)", $Admincreds.Password)

    Node localhost
    {
        # Set LCM to reboot if needed
        LocalConfigurationManager
        {
            DebugMode = "ForceModuleImport"
            RebootNodeIfNeeded = $true
        }

        WindowsFeature FC
        {
            Name = "Failover-Clustering"
            Ensure = "Present"
        }

        WindowsFeature FailoverClusterTools 
        { 
            Ensure = "Present" 
            Name = "RSAT-Clustering-Mgmt"
        } 

        WindowsFeature FCPS
        {
            Name = "RSAT-Clustering-PowerShell"
            Ensure = "Present"
        }
        
        WindowsFeature FCCMD
        {
            Name      = 'RSAT-Clustering-CmdInterface'
            Ensure    = 'Present'
        }

        WindowsFeature ADPS
        {
            Name = "RSAT-AD-PowerShell"
            Ensure = "Present"
        }

        WindowsFeature Telnet
        {
            Name = "Telnet-Client"
            Ensure = "Present"
        }

        WindowsFeature FS
        {
            Name = "FS-FileServer"
            Ensure = "Present"
        }

        WaitForADDomain DscForestWait
        { 
            DomainName = $DomainName 
            Credential = $DomainCreds
            DependsOn = "[WindowsFeature]ADPS"
        }

        xComputer DomainJoin
        {
            Name = $env:COMPUTERNAME
            DomainName = $DomainName
            Credential = $DomainCreds
            DependsOn = "[xWaitForADDomain]DscForestWait"
        }

        PendingReboot AfterDomainJoin
        { 
            Name = "AfterDomainJoin"
            DependsOn = "[xComputer]DomainJoin"
        }

        xCluster FailoverCluster
        {
            Name = $ClusterName
            DomainAdministratorCredential = $DomainCreds
	        DependsOn = "[PendingReboot]AfterDomainJoin"
        }

        xFirewall SQLFirewall
        {
            Name                  = "EPIC Firewall Rules"
            DisplayName           = "EPIC Firewall Rules"
            Ensure                = "Present"
            Enabled               = "True"
            Profile               = ("Domain", "Private", "Public")
            Direction             = "Inbound"
            RemotePort            = "Any"
            LocalPort             = ("3549", "3306", "59999","10022", "10021")
            Protocol              = "TCP"
            Description           = "Firewall Rule for EPIC"
            DependsOn             = "[PendingReboot]AfterDomainJoin"
        }

    }
}

function Get-NetBIOSName
{ 
    [OutputType([string])]
    param(
        [string]$DomainName
    )

    if ($DomainName.Contains('.')) {
        $length=$DomainName.IndexOf('.')
        if ( $length -ge 16) {
            $length=15
        }
        return $DomainName.Substring(0,$length)
    }
    else {
        if ($DomainName.Length -gt 15) {
            return $DomainName.Substring(0,15)
        }
        else {
            return $DomainName
        }
    }
} 