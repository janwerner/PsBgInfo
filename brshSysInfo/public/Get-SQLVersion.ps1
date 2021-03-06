function Get-siSQLVersionInfo {
	<#
	.SYNOPSIS
	Pulls sql version and patch information

	.DESCRIPTION
	Determining the version of SQL Server could be an entire 3 day training class. It can be even worse
	if you don't have access into SQL. This function tries to parse all the possible version pieces
	into one cohesive understandable view. It even works with things that are SQL Server but not called
	SQL Server (I'm looking at you Windows Internal Database)

	.EXAMPLE
	Get-siSQLVersionInfo
	#>

	[CmdletBinding()]
	param ()

	try {
		if (test-path "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server") {
			#Establish the array that will hold the registry values
			$values = @()
			# Create the array that will hold all the output objects
			$all = @()
			# Define base HKLM
			$reg = [Microsoft.Win32.RegistryKey]::OpenRemoteBaseKey('LocalMachine', '.')
			# Second, test if SQL instances are available
			if (test-path "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL") {
				# Open the Reg's List of All Instances
				$regKey = $reg.OpenSubKey("SOFTWARE\\Microsoft\\Microsoft SQL Server\\Instance Names\\SQL" )
				# And get all the Value NAMES
				$values = @($regkey.GetValueNames())
			}
			#Third, test if the Windows Internal Database exists (Server 2008 is fine with above; 2012 doesn't respect 'Instance Names')
			if (resolve-path "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\*SQLWID") {
				$widpath = resolve-path "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\*SQLWID"
				$widpath | ForEach-Object {
					#if (test-path "$_\CurrentVersion") {
					$values += $_.Path.Split('\')[-1]
					#}
				}
			}
			#Now, assuming we have anything to look for...
			if ($values.Count -gt 0) {
				#...cycle through all the Value NAMES to find specific instance information
				$values | ForEach-Object {
					# The Actual Value NAME
					[string] $InstanceName = $_
					# The Value VALUE
					try {
						[string] $inst = $regKey.GetValue($InstanceName)
						if ($inst.length -eq 0) { $inst = $InstanceName }
					} catch { $inst = $InstanceName}
					# Build the path the to the Instance in the registry
					$path = "SOFTWARE\\Microsoft\\Microsoft SQL Server\\" + $inst
					# Get the Version info
					try {
						[string] $Version = $reg.OpenSubKey($path + "\\MSSQLServer\\" + "CurrentVersion").GetValue("CurrentVersion")
					} catch { [string] $Version = 'Unknown' }
					# Make an attempt for Cluster Information
					try {
						[bool] $IsCluster = $true
						[string] $ClusterName = ""
						[string] $ClusterOwner = ""
						$ClusterName = $reg.OpenSubKey($path + "\\Cluster").GetValue("ClusterName")
						try {
							$ClusterOwner = (Get-WmiObject -Namespace "root\mscluster" -Class MSCluster_Resource |
									Where-Object {($_.Name -match $ClusterName) -and ($_.Type -eq "Network Name")} |
									Select-Object OwnerNode -First 1).OwnerNode
						} catch { $ClusterOwner = ""}
					} catch { [bool] $IsCluster = $false }
					if ($IsCluster -and ($ClusterName.Length -gt 0)) {
						$FinalInstanceName = "$ClusterName\$InstanceName"
					} else {
						$FinalInstanceName = "$InstanceName"
					}
					try {
						$ServiceStatus = [string] (get-service | Where-Object { $_.DisplayName -eq "SQL Server `($($InstanceName)`)"}).Status
						if ($ServiceStatus.Length -gt 0) {
							$ServiceStatus = "`($($ServiceStatus)`)"
						} else { $ServiceStatus = "" }
					} catch { $ServiceStatus = "" }
					# Try to get the Error Log, so we can read more definite version information
					# The Error log location is 1 of the "switches" used to start sqlserver
					# We pull the switches from the registry, find the error log, and read the header
					# Otherwise, we just use the version held in the registry - which is not quite as accurate
					Try {
						$SQLArgsKey = $reg.OpenSubKey($path + "\\MSSQLServer\\" + "Parameters")
						$SQLArgs = $SQLArgsKey.GetValueNames()
						$SQLArgs | ForEach-Object {
							[string] $ParamName = $_
							[String] $Param = $SQLArgsKey.GetValue($ParamName)
							if ($Param -match "ERROR") { [String] $PathToErrorLog = $Param.Replace('-e', '') }
						}
						if ($PathToErrorLog.Length -gt 0) {
							try {
								if (Test-Path $PathToErrorLog -ErrorAction SilentlyContinue) {
									Get-Content $PathToErrorLog -TotalCount 5 | ForEach-Object {
										if ($_ -match "Microsoft SQL") { $FullVersion = $_.Substring($_.IndexOf('SQL')).Trim().Replace(' (X64)', '').Replace(' - ', ', ').Replace(" Server", "") }
										if ($_ -match 'on Windows') { $Edition = $_.SubString(0, $_.IndexOf('on Windows')).Trim().Replace(' (64-bit)', '').Replace(" Edition", "") }
									}
								}
							} catch { $FullVersion = ""; $Edition = ""}

						}
						if ($FullVersion.Length -gt 0) {
							$FinalVersion = $FullVersion
							if ($Edition.Length -gt 0) {
								$FinalVersion = "$Edition, $FullVersion"
							}
						} else { $FinalVersion = "v$Version" }
					} catch { $FinalVersion = $Version }

					# Create a new object to hold this info, and add our custom info
					$out = new-object psobject
					Add-member -InputObject $out -MemberType NoteProperty -Name "InstanceName" -value ("$FinalInstanceName $ServiceStatus")
					Add-Member -InputObject $out -MemberType NoteProperty -Name "Version" -value ("$FinalVersion")
					if ($IsCluster) {
						Add-Member -InputObject $out -MemberType NoteProperty -Name "OwningNode" -value ("Resource is owned by $ClusterOwner")
					} else {
						Add-Member -InputObject $out -MemberType NoteProperty -Name "OwningNode" -value ("Not a Cluster Resource")
					}
					$out.PSObject.TypeNames.Insert(0, 'brshSysInfo.SQLInfo')
					$all += $out
				}
				# Output all the objects
				$all
			}
		}
	} catch {
		Write-Verbose 'Error pulling SQL Information'
		Write-Verbose $_.Exception.Message
	}
}
