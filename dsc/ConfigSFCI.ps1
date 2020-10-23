
configuration ConfigSFCI
{
    param
    (
        [Parameter(Mandatory)]
        [String]$DomainName,

        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$Admincreds,

        [Parameter(Mandatory)]
        [String]$ClusterName,

        [Parameter(Mandatory)]
        [String]$vmNamePrefix,

        [Parameter(Mandatory)]
        [Int]$vmCount,

        [Parameter(Mandatory)]
        [String]$witnessStorageName,

        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$witnessStorageKey,

        [String]$DomainNetbiosName=(Get-NetBIOSName -DomainName $DomainName),

        [Int]$RetryCount=20,
        [Int]$RetryIntervalSec=30
    )

    Import-DscResource -ModuleName xComputerManagement, xFailOverCluster, xActiveDirectory, xPendingReboot,xNetworking
 
    [System.Management.Automation.PSCredential]$DomainCreds = New-Object System.Management.Automation.PSCredential ("${DomainNetbiosName}\$($Admincreds.UserName)", $Admincreds.Password)
    
    $firstNode  = $vmNamePrefix+"01"
    $secondNode = $vmNamePrefix+"02"
    [System.Collections.ArrayList]$Nodes=@("$firstNode",$secondNode)

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
			DependsOn = "[WindowsFeature]FC"
        } 

        WindowsFeature FCPS
        {
            Name = "RSAT-Clustering-PowerShell"
            Ensure = "Present"
        }

        WindowsFeature Telnet
        {
            Name = "Telnet-Client"
            Ensure = "Present"
        }

        WindowsFeature ADPS
        {
            Name = "RSAT-AD-PowerShell"
            Ensure = "Present"
        }

        WindowsFeature ASDistTransaction
        {
            Name = "AS-Dist-Transaction"
            Ensure = "Present"
        }


        WindowsFeature FS
        {
            Name = "FS-FileServer"
            Ensure = "Present"
        }

        xWaitForADDomain DscForestWait 
        { 
            DomainName = $DomainName 
            DomainUserCredential= $DomainCreds
            RetryCount = $RetryCount 
            RetryIntervalSec = $RetryIntervalSec 
	        DependsOn = "[WindowsFeature]ADPS"
        }
        
        xComputer DomainJoin
        {
            Name = $env:COMPUTERNAME
            DomainName = $DomainName
            Credential = $DomainCreds
	        DependsOn = "[xWaitForADDomain]DscForestWait"
        }

        xCluster FailoverCluster
        {
            Name = $ClusterName
            DomainAdministratorCredential = $DomainCreds
            Nodes = $Nodes
	        DependsOn = "[xComputer]DomainJoin"
        }

        Script CloudWitness
        {
            SetScript = "Set-ClusterQuorum -CloudWitness -AccountName ${witnessStorageName} -AccessKey $($witnessStorageKey.GetNetworkCredential().Password)"
            TestScript = "(Get-ClusterQuorum).QuorumResource.Name -eq 'Cloud Witness'"
            GetScript = "@{Ensure = if ((Get-ClusterQuorum).QuorumResource.Name -eq 'Cloud Witness') {'Present'} else {'Absent'}}"
            DependsOn = "[xCluster]FailoverCluster"
        }

        Script IncreaseClusterTimeouts
        {
            SetScript = "(Get-Cluster).SameSubnetDelay = 2000; (Get-Cluster).SameSubnetThreshold = 15; (Get-Cluster).CrossSubnetDelay = 3000; (Get-Cluster).CrossSubnetThreshold = 15"
            TestScript = "(Get-Cluster).SameSubnetDelay -eq 2000 -and (Get-Cluster).SameSubnetThreshold -eq 15 -and (Get-Cluster).CrossSubnetDelay -eq 3000 -and (Get-Cluster).CrossSubnetThreshold -eq 15"
            GetScript = "@{Ensure = if ((Get-Cluster).SameSubnetDelay -eq 2000 -and (Get-Cluster).SameSubnetThreshold -eq 15 -and (Get-Cluster).CrossSubnetDelay -eq 3000 -and (Get-Cluster).CrossSubnetThreshold -eq 15) {'Present'} else {'Absent'}}"
            DependsOn = "[Script]CloudWitness"
        }

        # Likelely redundant
        Script MoveClusterGroups1
        {
            SetScript = 'try {Get-ClusterGroup -ErrorAction SilentlyContinue | Move-ClusterGroup -Node $env:COMPUTERNAME -ErrorAction SilentlyContinue} catch {}'
            TestScript = 'return $false'
            GetScript = '@{Result = "Moved Cluster Group"}'
            DependsOn = "[Script]IncreaseClusterTimeouts"
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
            DependsOn             = "[Script]MoveClusterGroups1"
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