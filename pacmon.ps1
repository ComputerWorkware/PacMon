# PacMon - Dependency Check Runner for TeamCity

### BEGIN INIT PARAMS

[CmdletBinding()]
Param(
	# -target <relative path to scan>
	[Parameter(Mandatory=$TRUE)]
	[string]$target,
	
	# -app <project title>
	[Parameter(Mandatory=$FALSE)]
	[string]$app = "PacMon",
		
	# -dc <relative path to dependency check>
	[Parameter(Mandatory=$FALSE)]
	[string]$dc = "dc",
	
	# -etc <dependency check command line parameters>
	[Parameter(Mandatory=$FALSE)]
	[string]$etc,

	# -s <relative path to suppression file>
	[Parameter(Mandatory=$FALSE)]
	[string]$s = "suppress.xml",
	
	# -x <relative path to temporary xml file>
	[Parameter(Mandatory=$FALSE)]
	[string]$x = "output.xml",
	
	# -h <relative path to artifact html file>
	[Parameter(Mandatory=$FALSE)]
	[string]$h = "vulnerabilities.html",

    # -reportSeverity <list of severities which will cause a build to fail. Can be any combination of LOW, MEDIUM, HIGH, CRITICAL>
	[Parameter(Mandatory=$FALSE)]
	[string]$reportSeverity = "LOW, MEDIUM, HIGH, CRITICAL"
)

[string]$suppressFilename = $s
[string]$xmlFilename = $x
[string]$htmlFilename = $h

### END INIT PARAMS

function Get-DependencyCheckArgs([string]$projectName, [string]$inputFilePath, [string]$outputFilePath, [string]$suppressionFilePath, [string]$additionalArgs){
	$format = Get-FileExtensionFromPath $outputFilePath
	[string]$dcArgs = '--project "{0}" --scan "{1}" --out "{2}" --format "{3}"' -f $projectName, $inputFilePath, $outputFilePath, $format
	
	if (Test-Path $suppressionFilePath) {
		$dcArgs = '{0} --suppression "{1}"' -f $dcArgs, $suppressionFilePath
	}
	
	if ($additionalArgs) {
		$dcArgs = '{0} {1}' -f $dcArgs, $additionalArgs
	}
	
	$dcArgs
}

function Run-DependencyCheck([string]$dcPath, [string]$cmdLineArgs){
	$command = '/c {0}\bin\dependency-check.bat {1}' -f $dcPath, $cmdLineArgs
	Write-Output ("Executing: cmd.exe {0}" -f $command)
	& cmd.exe $command
    Write-Output ("Finished executing")
}

function Validate-Dependencies([string]$xmlPath) {
	if (!(Test-Path $xmlPath)) {
		Write-Error ("XML output not found: {0}" -f $xmlPath)
		exit(1)
	}

	[xml]$xml = Get-Content $xmlPath	

	if (!$xml.analysis) {
		Write-Error "XML contains no analysis"
		Delete-File $xmlPath
		exit(1)
	}
	
	if (!$xml.analysis.dependencies.dependency) {
		Write-Error "Analysis contains no dependencies"
		Delete-File $xmlPath
		exit(0)
	}
	
	$xml.analysis.dependencies.dependency
}

function Parse-Dependencies($dependencies) {
	Foreach ($dependency IN $dependencies) {
		Parse-Dependency($dependency)
	}
}

function Parse-Dependency($dependency) {
	[string]$name = Clean-String($dependency.fileName)
	[string]$description = Clean-String($dependency.description)

	Start-Test $name $description

	if ($dependency.vulnerabilities) {
		Parse-Vulnerabilities $name $dependency
	}
	
	End-Test($name)
}

function Parse-Vulnerabilities([string]$name, $dependency){
	Foreach ($vulnerability in $dependency.vulnerabilities.vulnerability ) {
		Parse-Vulnerability $name $vulnerability
	}
	
	Foreach ($vulnerability in $dependency.vulnerabilities.suppressedVulnerability) {
		Parse-SuppressedVulnerability $name $vulnerability
	}
}

function Parse-Vulnerability([string]$name, $vulnerability){
	[string]$message = Get-TestMessage $vulnerability
	[string]$details = Clean-String($vulnerability.description)
    [string]$severity = Clean-String($vulnerability.severity)

    $at = $reportSeverity.IndexOf($severity, 0, $reportSeverity.Length)
    $reportSeverityMatches = $at -gt -1;

    if ($reportSeverityMatches) {
        Fail-Test $name $message $details
    } else {
        Write-Output ("WARN: Vulnarability found, but ignored because of severity level ({0}, {1}, {2}, {3})" -f $name, $message, $details, $severity)
    }
}

function Parse-SuppressedVulnerability([string]$name, $vulnerability){
	[string]$message = "SUPPRESSED: {0}" -f (Get-TestMessage $vulnerability)
	Ignore-Test $name $message
}

function Get-TestMessage($vulnerability) {
	[string]$vulnerabilityName = Clean-String($vulnerability.name)
	[string]$vulnerabilitySeverity = Clean-String($vulnerability.severity)
	("{0} ({1})" -f $vulnerabilityName, $vulnerabilitySeverity)
}

function Has-Vulnerability($dependencies) {
	$vulnerabilityFound = $FALSE
	Foreach ($dependency IN $dependencies) {
		if ($dependency.vulnerabilities) {
			$vulnerabilityFound = $TRUE
		}
	}
	$vulnerabilityFound
}

### TeamCity Test Service Message functions

function Start-Test([string]$name, [string]$message){
	Write-Output ("##teamcity[testStarted name='{0}' captureStandardOutput='{1}']" -f $name, $message)
}

function Update-Test([string]$name, [string]$message){
	Write-Output ("##teamcity[testStdOut name='{0}' out='{1}']" -f $name, $message)
}

function Ignore-Test([string]$name, [string]$message){
	Write-Output ("##teamcity[testIgnored name='{0}' message='{1}']" -f $name, $message)
}

function Fail-Test([string]$name, [string]$message, [string]$details){
	Write-Output ("##teamcity[testFailed name='{0}' type='vulnerability' message='{1}' details='{2}']" -f $name, $message, $details)
}

function End-Test([string]$name){
	Write-Output ("##teamcity[testFinished name='{0}']" -f $name)
}

### General Purpose

function Clean-String([string]$string){
	$string = $string -replace "`t|`n|`r",""
	$string = $string -replace " ;|; ",";"
	$string = $string -replace "'",""
	$string
}

function Get-FileExtensionFromPath([string]$path){
	$parts = $path.Split('.')
	$ext = $parts[$parts.Length-1]
	$ext.ToUpper()
}

function Delete-File([string]$path) {
	Invoke-Expression ('DEL {0}' -f $path)
}

#
# http://stackoverflow.com/questions/1183183/path-of-currently-executing-powershell-script
#
function Get-ScriptDirectory
{
	$Invocation = (Get-Variable MyInvocation -Scope 1).Value
	Split-Path $Invocation.MyCommand.Path
}

#
# https://confluence.jetbrains.com/display/TCD9/PowerShell
#
function Set-PSConsole {
	if (Test-Path env:TEAMCITY_VERSION) {
		try {
			$rawUI = (Get-Host).UI.RawUI
			$m = $rawUI.MaxPhysicalWindowSize.Width
			$rawUI.BufferSize = New-Object Management.Automation.Host.Size ([Math]::max($m, 500), $rawUI.BufferSize.Height)
			$rawUI.WindowSize = New-Object Management.Automation.Host.Size ($m, $rawUI.WindowSize.Height)
		} catch {}
	}
}

### BEGIN SCRIPT

[string]$basePath = Get-ScriptDirectory
[string]$dcPath = '{0}\{1}' -f $basePath, $dc
[string]$xmlPath = '{0}\{1}' -f $basePath, $xmlFilename
[string]$htmlPath = '{0}\{1}' -f $basePath, $htmlFilename
[string]$suppressPath = '{0}\{1}' -f $basePath, $suppressFilename

$scanArgs = Get-DependencyCheckArgs $app $target $xmlPath $suppressPath $etc

Run-DependencyCheck $dcPath $scanArgs

$dependencies = Validate-Dependencies $xmlPath

Set-PSConsole

Parse-Dependencies $dependencies

Delete-File $xmlPath

if (Has-Vulnerability $dependencies) {
	Write-Output ("Vulnerability found -- generating report artifact: {0}" -f $htmlFilename)
	[string]$artifactArgs = Get-DependencyCheckArgs $app $target $htmlPath $suppressPath $etc
	Run-DependencyCheck $dcPath $artifactArgs
}

exit(0)

### END SCRIPT