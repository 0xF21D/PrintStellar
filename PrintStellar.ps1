#requires -modules ActiveDirectory

# PrintStellar.ps1

# Description: This script queries the print spooler status and installed printers for all windows servers in a domain. It results 
# in a $report object that can then be parsed in different ways to determine what servers have additional printers installed
# outside of the default microsoft printers. It can then be configured to disable the print spooler. See the options below for
# addtional options. 

# If configured to disable the spooler, the default behavior is to disable the spooler on all servers where the only printers
# installed (if any) are listed in the $PrinterIgnoreList below. This is configured default to Microsoft XPS and PDF printers.
# Add servers that you don't want to disable to the $ServerIgnoreList below

# The script exports a report.csv file to your desktop for ease of audit and viewing of results. 

# Right now it is recommended to run this script in ISE or VSCode after modification (and audit). Note that you can run this
# as your normal account, or run from a server. You will be prompted for appropriate credentials. Also note that you should
# absolutely run this first with $DisableMode set to false for purpose of discovery.

# The script connects to servers via jobs. Set this to the maximum number of concurrent jobs you wish to run at the same time. 
$maxjob = 50

# Set this to the BaseDN of the server objects you wish to query. Ideally this will be your domain base DN, as the script will filter to 
# servers automatically OS caption (OperatingSystem). The script will also ignore servers that are not enabled in AD. 
$BaseDN = 'DC=yourdomain,DC=com'

# List servers you wish to ignore. These are servers that you need to leave the spooler on regardless. Consider other steps to harden. 
$ServerIgnoreList = @('LISTYOURSERVERS','THATYOUWANTTOIGNOREHERE')

# Switch this to $true if you want the script to disable the spooler on servers that have no additional printers installed. 
[bool]$DisableMode = $false

# List the printers you wish to ignore. These are typically default printers that are not shared on on servers. 
$PrinterIgnoreList = @('Microsoft XPS Document Writer','Microsoft Print to PDF')

# Change nothing below this line unless you want to alter behaviors of the script, otherwise the options above should be sufficient.
# You are encouraged to audit this. You run this tool at your own risk. :)

# Payload script for server job. 
$scriptblock = {
    param($PrinterIgnoreList,$DisableMode)
    # Printers we are going to ignore.
      
    # Need to use Win32_Service instead of Get-Service since Get-Service doesn't always return the StartType on older Server versions.
    $Spooler = Get-CimInstance -ClassName Win32_Service -Filter "Name = 'Spooler'" | Select-Object Started,StartMode
    
    # If the spooler is not disabled then we can get the list of printers, otherwise we'll just go with the spooler status. 
    if ($Spooler.StartMode -ne 'Disabled') {
        $PrinterList = (Get-Printer)
        $ReturnList = [ordered]@{
            Server = $env:COMPUTERNAME
            SpoolerStarted = $Spooler.Started
            SpoolerStartMode = $Spooler.StartMode
            PrinterCount = ($PrinterList | Measure-Object).Count
            PrinterList = ($PrinterList | Where-Object{$_.Name -notin $PrinterIgnoreList})
        }
        
    } 
    else {
        $ReturnList = [ordered]@{
            Server = $env:COMPUTERNAME
            SpoolerStarted = $Spooler.Started
            SpoolerStartMode = $Spooler.StartMode
            PrinterCount = $null
            PrinterList = $null
        }
        
    }

    if ($DisableMode -and $SpoolerStartMode -ne 'Disabled') {
        if (($ReturnList.PrinterList | Measure-Object).count -eq 0) { 
            #Stop-Service -Name Spooler -Force
            #Set-Service -Name Spooler -StartupType Disabled -Force
            $Spooler = Get-CimInstance -ClassName Win32_Service -Filter "Name = 'Spooler'" | Select-Object Started,StartMode
            $ReturnList.SpoolerStarted = $Spooler.Started
            $ReturnList.SpoolerStartMode = $Spooler.StartMode
            if ($Spooler.Started -eq $false -and $Spooler.StartMode -eq 'Disabled') { 
                $ReturnList = $ReturnList + @{Result = 'Spooler Disabled'}
            } else {
                $ReturnList = $ReturnList + @{Result = 'Could Not Disable'}
            }
        } else {
            $ReturnList = $ReturnList + @{Result = 'Not Disabling'}
        }
    } else {
        if ($ReturnList.SpoolerStarted -eq $false) { 
        $ReturnList = $ReturnList + @{Result = 'Already Disabled'}
        } else { 
            if (($ReturnList.PrinterList | Measure-Object).count -eq 0) { 
                $ReturnList = $ReturnList + @{Result = 'Would Disable'}
            } else {
                $ReturnList = $ReturnList + @{Result = 'Would Not Disable'}
            }
        }
    }

    return $ReturnList
}

# Get administrative credentials. 
$Credential = Get-Credential

# Collect list of servers. The server must be enabled in AD. 
Write-Progress -Activity 'Getting Server List from Active Directory'
$ServerList = Get-ADComputer -SearchBase $BaseDN -Filter * -Properties OperatingSystem | Where-Object {$_.Enabled -eq $True -and $_.OperatingSystem -match 'Server' -and $_.Name -notin $ServerIgnoreList}

# Set some variables and objects up. 
[array]$Report = $null
[long]$TotalItems = $ServerList.Count
[long]$Progress = 1
[long]$Percentage = 0

# Step through the server list. 

ForEach ($Server in $ServerList) {  
    $Percentage = ($Progress * 100) / $TotalItems
    Write-Progress -Activity 'Querying Servers' -PercentComplete $Percentage -Status "$Percentage% complete..." -CurrentOperation "Attempting to start job for $($Server.Name)"
    
    # Check if name resolves. 

    $DNS = Resolve-DnsName -Name $Server.Name -ErrorAction SilentlyContinue

    # Does the DNS Resolve? If so check if I can reach the server. 
    if ($DNS) {
    $Reachable = Test-Connection -Ping $Server.Name -Count 2 | Where-Object {$_.Status -ne 'TimedOut'}
    }
    
    # If I can reach the server then I "should" be able to connect to it, so I'm going to attempt to start the job. 
    if ($Reachable) { 

        $check = $false

        # Hold off until I can run a job. Once a job is available, run.
        while ($check -eq $false) {
            if((Get-Job -State 'Running').count -lt $maxjob) {
                $null = Invoke-Command -ScriptBlock $scriptblock -Credential $Credential -ComputerName $Server.Name -ArgumentList $PrinterIgnoreList,$DisableMode -ErrorAction SilentlyContinue -AsJob
                $check = $true
            }
        }
    } else {   # Ping failed. So assuming not connectable. 
        $Report = $Report + [pscustomobject]@{
            Server = $Server.Name
            Reachable = $false
            Connectable = $false
            Result = 'Nothing to do.'
            SpoolerStarted = $null
            SpoolerStartMode = $null
            PrinterCount= $null
            PrinterList = $null
        }
    }

    # Clean up and increment progress counter. 
    Remove-Variable -Name DNS -ErrorAction SilentlyContinue
    Remove-Variable -Name Reachable -ErrorAction SilentlyContinue
    $Progress++
}

# Wait patiently for remaining jobs to finish. 
while ((Get-Job -State 'Running').count -gt 0) {
    Start-Sleep -Seconds 1
    Write-Progress -Activity "Waiting for remaining jobs to complete."
}

# Retrieve job list. 
$JobList = Get-Job

# Step through job list and for each successful job, record the results. For each failed job, record as not connectable (failed).
Write-Progress -Activity "Processing."
ForEach ($Job in $JobList) {
    try {
        $JobResult = @(Receive-Job -Id $Job.ID -ErrorAction Stop)
        $Report = $Report + [pscustomobject]@{
            Server = $Job.Location
            Reachable = $true
            Connectable = $true
            Result = $JobResult.Result
            SpoolerStarted = $JobResult.SpoolerStarted
            SpoolerStartMode = $JobResult.SpoolerStartMode
            PrinterCount = $JobResult.PrinterCount
            PrinterList = $JobResult.PrinterList
        }
    }
    catch
    {
        $Report = $Report + [pscustomobject]@{
            Server = $Job.Location
            Reachable = $true
            Connectable = $false
            Result = 'Nothing to do.'
            SpoolerStarted = $null
            SpoolerStartMode = $null
            PrinterCount = $null
            PrinterList = $null
        }
    }
}

# Purge jobs and credentials.
Remove-Job -Name *
Remove-Variable -Name Credential

# Export report to desktop. 
$Report | Export-CSV -Path "$($env:USERPROFILE)\desktop\report.csv" -NoTypeInformation