<#
.SYNOPSIS
   This script defines a collection of code snippets used by Pask

.NOTE
    DO NOT MODIFY - the script is managed and updated by Pask package
#>

# Define Pask internal variables
if (-not (Test-Path variable:!BuildProperties!)) { ${script:!BuildProperties!} = @{} }
if (-not (Test-Path variable:!Files!)) { [System.Collections.ArrayList] ${script:!Files!} = @() }

<#
.SYNOPSIS
    Sets a build property

.PARAMETER Name <string>
    The property name

.PARAMETER Value <ScriptBlock>
    The property value

.PARAMETER Default <ScriptBlock>
    The default value

.EXAMPLE
    Set a build property with explicit value
    Set-Property -Name Configuration -Value Debug

.EXAMPLE
    Set a build property with value of session or default
    Set-Property -Name Configuration -Default Release

.EXAMPLE
    Set a build property with value of session
    Set-Property -Name Configuration

.OUTPUTS
    None
#>
function script:Set-BuildProperty {
    param(
        [Parameter(Mandatory=$true,Position=0)][ValidateNotNullOrEmpty()][string]$Name,
        [Parameter(ParameterSetName="ExplicitValue")]$Value,
        [Parameter(ParameterSetName="ValueOfSessionOrDefault")]$Default
    )

    $private:PropertyValue = switch ($PsCmdlet.ParameterSetName) {
        "ExplicitValue" { $Value }
        "ValueOfSessionOrDefault" { Get-BuildProperty $Name $Default }
        default { Get-BuildProperty $Name }
    }

    $private:VariableValue = if ($private:PropertyValue.GetType() -eq [ScriptBlock]) { 
        & $private:PropertyValue 
    } else { 
        $private:PropertyValue 
    }

    if(-not ${!BuildProperties!}.ContainsKey($Name)) {
        New-Variable -Name $Name -Value $private:VariableValue -Scope Script -Force
        ${script:!BuildProperties!} = ${!BuildProperties!} + @{$Name=$private:PropertyValue}
    } else {
        Set-Variable -Name $Name -Value $private:VariableValue -Scope Script -Force
        ${!BuildProperties!}.Set_Item($Name, $private:PropertyValue)
        ${script:!BuildProperties!} = ${!BuildProperties!}
    }
}
Set-Alias Set-Property Set-BuildProperty -Scope Script

<#
.SYNOPSIS 
    Gets all build properties

.OUTPUTS <hashtable>
    ------------------- EXAMPLE -------------------
    @{
        Configuration = Debug
        ProjectName = 'MyProject'
    }
#>
function script:Get-BuildProperties {
    ${!BuildProperties!}.GetEnumerator() | Foreach -Begin {
        $Result = @{}
    } -Process {
        $Value = Get-Variable -Name $_.Key -ValueOnly
        $Result.Add($_.Key, $Value)
    } -End {
        $Result
    }
}
Set-Alias Get-Properties Get-BuildProperties -Scope Script

<#
.SYNOPSIS
    Refreshes build properties with script block value

.OUTPUTS
    None
#>
function script:Refresh-BuildProperties {
    $private:BuildProperties = ${!BuildProperties!}.GetEnumerator() | Where { $_.Value.GetType() -eq [ScriptBlock] } 
    $private:BuildProperties | Foreach { Set-BuildProperty -Name $_.Key -Value $_.Value }
}
Set-Alias Refresh-Properties Refresh-BuildProperties -Scope Script

<#
.SYNOPSIS 
   Creates a new directory, if not found

.PARAMETER Path <string>
   Absolute or relative path

.OUTPUTS <System.IO.DirectoryInfo>
   The directory
#>
function script:New-Directory {
    param([string]$Path)

    if (-not (Test-Path "$Path")) { 
        New-Item -ItemType Directory -Path "$Path" -Force
    } else {
        Get-Item -Path "$Path"
    }
}

<#
.SYNOPSIS 
   Silently remove an item (no output)

.PARAMETER Item <string>
   Wildcards are permitted

.OUTPUTS
   None
#> 
function script:Remove-ItemSilently {
    param([parameter(ValueFromPipeline)][string]$Item)

    Remove-Item -Path "$Item" -Recurse -Force -ErrorAction SilentlyContinue | Out-Null

    # Ensure removal of directories exceeding the 260 characters limit
    Get-ChildItem -Directory -Path "$Item" -Recurse `
        | Sort -Descending @{Expression = {$_.FullName.Length}} `
        | Select -ExpandProperty FullName `
        | ForEach { CMD /C "RD /S /Q ""$($_)""" }
}

<#
.SYNOPSIS 
   Gets the NuGet executable

.OUTPUTS <string>
   Full name
#> 
function script:Get-NuGetExe {
    Join-Path $SolutionFullPath ".nuget\NuGet.exe"
}

<#
.SYNOPSIS 
   Initializes the NuGet executable by downloading it, if not found

.OUTPUTS
   None
#> 
function script:Initialize-NuGetExe {
    $NuGet = Get-NuGetExe
    if(-not (Test-Path $NuGet -PathType Leaf) -or -not (Test-Path $NuGet)) {
        # Download
        New-Directory (Split-Path $NuGet) | Out-Null
        # Installing NuGet command line https://docs.nuget.org/consume/command-line-reference
        "Downloading NuGet.exe"
        $(New-Object System.Net.WebClient).DownloadFile("https://dist.nuget.org/win-x86-commandline/latest/nuget.exe", $NuGet)
    }
}

<#
.SYNOPSIS 
   Gets the NuGet packages directory

.OUTPUTS <string>
   The full path
#> 
function script:Get-PackagesDir {
    $PackagesDir = Join-Path $SolutionFullPath "packages" 
    $NuGet = Get-NuGetExe
    if (Test-Path $NuGet) {
        Push-Location -Path (Split-Path $NuGet)
        try {
            $RepositoryPath = Invoke-Command -ScriptBlock { & $NuGet config repositoryPath -AsPath 2>$1 }
            if ((-not [string]::IsNullOrWhiteSpace($RepositoryPath)) -and (Test-Path $RepositoryPath -PathType Container -IsValid)) { 
                $PackagesDir = $RepositoryPath
            }
        } catch {
        } finally {
            Pop-Location
        }
    }
    return $PackagesDir
}

<#
.SYNOPSIS 
   Restores NuGet packages for the solution

.OUTPUTS
   None
#> 
function script:Restore-NuGetPackages {
    if ($Task.Name -ne $MyInvocation.MyCommand.Name) {
        Write-BuildMessage "Restore NuGet packages" -ForegroundColor "Cyan"
    }
    Initialize-NuGetExe
    Exec { & $(Get-NuGetExe) restore "$SolutionFullName" -PackagesDirectory $(Get-PackagesDir) -NonInteractive -Verbosity quiet }
}

<#
.SYNOPSIS 
   Restores NuGet packages marked as development-only-dependency for the solution

.OUTPUTS
   None
#> 
function script:Restore-NuGetDevelopmentPackages {
    Initialize-NuGetExe
    $PackagesDir = Get-PackagesDir
    $NuGetExe = Get-NuGetExe
    Get-SolutionPackages | Where { $_.developmentDependency -eq $true } | ForEach {
        Invoke-Command -ErrorAction Stop -ScriptBlock { & $NuGetExe install $_.id -Version $_.version -OutputDirectory "$PackagesDir" -NonInteractive -Verbosity quiet }
        if ($LASTEXITCODE) {
            Write-BuildMessage -Message "Error restoring NuGet package $($_.id).$($_.version)" -ForegroundColor "Red"
            exit $LASTEXITCODE
        }
    }
}

<#
.SYNOPSIS 
   Writes a message to the host with custom background and foreground color

.PARAMETER Message <string>

.PARAMETER BackgroundColor <System.ConsoleColor>
   Default to $Host.UI.RawUI.BackgroundColor

.PARAMETER ForegroundColor  <System.ConsoleColor>
   Default to $Host.UI.RawUI.ForegroundColor 

.OUTPUTS
   None
#>
function script:Write-BuildMessage {
    param(
        [Parameter(ValueFromPipeline=$true,Mandatory=$true)][string]$Message,
        [string]$BackgroundColor = $Host.UI.RawUI.BackgroundColor,
        [string]$ForegroundColor = $Host.UI.RawUI.ForegroundColor
    )

    $OriginalBackgroundColor = $Host.UI.RawUI.BackgroundColor
    $OriginalForegroundColor = $Host.UI.RawUI.ForegroundColor
    $Host.UI.RawUI.BackgroundColor = $BackgroundColor
    $Host.UI.RawUI.ForegroundColor = $ForegroundColor
    $Message
    $Host.UI.RawUI.BackgroundColor = $OriginalBackgroundColor
    $Host.UI.RawUI.ForegroundColor = $OriginalForegroundColor
}

<#
.SYNOPSIS 
   Gets a project full name given its base name

.PARAMETER Name <string> = $ProjectName
   The project name

.OUTPUTS <string>
   The full name
#>
function script:Get-ProjectFullName {
    param([string]$Name = $ProjectName)

    Get-SolutionProjects `
        | Where { $_.Name -eq $Name } `
        | Select -First 1 @{ Name = "ProjectFullName"; Expression = { Join-Path $_.Directory $_.File } } `
        | Select -ExpandProperty ProjectFullName
}

<#
.SYNOPSIS 
   Gets all projects in the solution

.OUTPUTS <object[]>
   ------------------- EXAMPLE -------------------
   @(
      @{
         Name = 'Project'
         File = 'Project.csproj'
         Directory = 'C:\Solution_Dir\Project_Dir'
      }
   )
#>
function script:Get-SolutionProjects {
    $Projects = @()
    Get-Content "$SolutionFullName" |
    Select-String 'Project\(' |
        ForEach {
            $ProjectParts = $_ -Split '[,=]' | ForEach { $_.Trim('[ "{}]') };
            if($ProjectParts[2] -match ".*\.\w+proj$") {
                $ProjectPathParts = $ProjectParts[2].Split("\");
                $Projects += New-Object PSObject -Property @{
                    Name = $ProjectParts[1];
                    File = $ProjectPathParts[-1];
                    Directory = Join-Path "$SolutionFullPath" $ProjectParts[2].Replace("\$($ProjectPathParts[-1])", "");
                }
            }
        }
    return $Projects
}

<#
.SYNOPSIS 
   Gets all NuGet packages installed in the solution

.OUTPUTS <object[]>
   ------------------- EXAMPLE -------------------
   @(
      @{
         id = 'NUnit'
         version = '3.2.0'
      }
   )
#>
function script:Get-SolutionPackages {
    $Packages = @()

    foreach($Project in Get-SolutionProjects) {
        $PackagesConfig = Join-Path $Project.Directory "packages.config"
        if(Test-Path $PackagesConfig) {
            $Packages += ([xml](Get-Content -Path "$PackagesConfig")).packages.package
        }
    }

    return ($Packages | Select -Unique id, version, developmentDependency | Sort id, version)
}

<#
.SYNOPSIS 
   Gets the the package directory for a given NuGet package Id

.PARAMETER PackageId <string>
   A NuGet package Id installed in the solution

.OUTPUTS <string>
   The package directory
#>
function script:Get-PackageDir {
    param([Parameter(ValueFromPipeline=$true,Mandatory=$true)][AllowEmptyString()][string]$PackageId)

    if ([string]::IsNullOrWhiteSpace($PackageId)) { 
        throw "PackageId cannot be empty"
    }

    $MatchingPackages = Get-SolutionPackages | Where { $_.id -ieq $PackageId }

    if ($MatchingPackages.Count -eq 0) {
        throw "Cannot find '$PackageId' NuGet package in the solution"
    } elseif ($MatchingPackages.Count -gt 1) {
        throw "Found multiple versions of '$PackageId' NuGet package installed in the solution"
    }

    return Join-Path (Get-PackagesDir) ($MatchingPackages[0].id + '.' + $MatchingPackages[0].version)
}

<#
.SYNOPSIS 
   Imports all PS1 files with matching name, searching sequentially in
      - any Pask.* package installed in the solution
      - any Pask.* project in the solution
      - $BuildFullPath
   Import only occur only once, files are cached

.PARAMETER File <string[]>
   File names (no extension)

.PARAMETER Path <string>
   Path relative to $BuildFullPath

.PARAMETER Safe <switch> = $false
   Tells not to error if the file is not found;

.OUTPUTS
   None
#>
function script:Import-File {
    param(
        [Parameter(Mandatory=$true)][string[]]$File,
        [Parameter(Mandatory=$true)][string]$Path,
        [switch]$Safe
    )

    # List of directories in which to search the files
    $Directories = @()
    # Search the file in Pask.* packages
    foreach ($Package in (Get-SolutionPackages | Where { $_.id -match "^Pask.*" })) {
        $Directories += Get-PackageDir $Package.id
    }
    # Search the files in Pask.* projects
    foreach ($Project in (Get-SolutionProjects | Where { $_.Name -match "^Pask.*" })) {
        $Directories += $Project.Directory
    }
    # Search the files in the build directory
    $Directories += $BuildFullPath

    foreach($F in $File) {
        foreach($Directory in $Directories) {
            $FileFullName = Join-Path $Directory (Join-Path $Path "$F.ps1")
            if (-not (Test-Path $FileFullName)) { continue }
            Get-ChildItem $FileFullName | ForEach {
                if (Get-Files $_.FullName) {
                    $Imported = $true
                } else {
                    . $_.FullName
                    ${!Files!}.Add($_.FullName) | Out-Null
                    ${script:!Files!} = ${!Files!}
                    $Imported = $true
                }
            }
        }
        if (-not $Imported -and -not $Safe) {
            throw "Cannot import $F"
        }
    }
}

<#
.SYNOPSIS 
   Imports all tasks with matching name, searching sequentially in
      - any Pask.* package installed in the solution
      - any Pask.* project in the solution
      - $BuildFullPath\tasks
   The latter imported overrides previous tasks imported with the same name
   Import only occur only once, tasks are cached

.PARAMETER Task <string[]>
   Tasks name

.OUTPUTS
   None
#>
function script:Import-Task {
    param([Parameter(Mandatory=$true)][string[]]$Task)

    Import-File -File $Task -Path "tasks"
}

<#
.SYNOPSIS 
   Imports all scripts with matching name, searching sequentially in
      - any Pask.* package installed in the solution
      - any Pask.* project in the solution
      - $BuildFullPath\scripts
   Import only occur only once, scripts are cached

.PARAMETER Script <string[]>
   Scripts name

.PARAMETER Safe <switch> = $false
   Tells not to error if the file is not found

.OUTPUTS
   None
#>
function script:Import-Script {
    param(
        [Parameter(Mandatory=$true)][string[]]$Script,
        [switch]$Safe
    )

    Import-File -File $Script -Path "scripts" -Safe:$Safe
}

<#
.SYNOPSIS 
   Imports the Properties script for a given Pask.* package/project or all
   It does always import $BuildFullPath\scripts\Properties.ps1 (if found)
   Import only occur only once, properties are cached

.PARAMETER Project <string[]>
   Project names matching ^Pask.*

.PARAMETER Package <string[]>
   Packages name matching ^Pask.*

.PARAMETER All <switch> = $false
   Tells to import all Properties file found

.OUTPUTS
   None
#>
function script:Import-Properties {
    param(
        [ValidatePattern('^Pask.*')][string[]]$Project,
        [ValidatePattern('^Pask.*')][string[]]$Package,
        [switch]$All
    )

    $PropertiesPath = "scripts\Properties.ps1"

    if ($All) {
        $AllProjects = Get-SolutionProjects | Where { $_.Name -match "^Pask.*" } | Select -ExpandProperty Name | Get-Unique
        if($AllProjects) { $Project = $AllProjects }
        $AllPackages = Get-SolutionPackages | Where { $_.id -match "^Pask.*" } | Select -ExpandProperty id | Get-Unique
        if($AllPackages) { $Package = $AllPackages }
    }

    # Always import solution properties
    $SolutionProperties = Join-Path $BuildFullPath $PropertiesPath
    if ((Test-Path $SolutionProperties) -and -not (Get-Files $SolutionProperties)) {
        . $SolutionProperties
        ${!Files!}.Add($SolutionProperties) | Out-Null
        ${script:!Files!} = ${!Files!}
    }

    # Import properties from projects
    foreach ($Prj in $Project) {
        $SolutionProject = Get-SolutionProjects | Where { $_.Name -eq $Prj } | Select -First 1
        if ($SolutionProject) {
            $ProjectProperties = Join-Path $SolutionProject.Directory $PropertiesPath
            If ((Test-Path $ProjectProperties) -and -not (Get-Files $ProjectProperties)) {
                . $ProjectProperties
                ${!Files!}.Add($ProjectProperties) | Out-Null
                ${script:!Files!} = ${!Files!}
            }
        }
    }

    # Import properties from packages
    foreach ($Pkg in $Package) {
        if (Get-SolutionPackages | Where { $_.id -eq $Pkg }) {
            $PackageProperties = Join-Path (Get-PackageDir $Pkg) $PropertiesPath
            if ((Test-Path $PackageProperties) -and -not (Get-Files $PackageProperties)) {
                . $PackageProperties
                ${!Files!}.Add($PackageProperties) | Out-Null
                ${script:!Files!} = ${!Files!}
            }
        }
    }
}

<#
.SYNOPSIS 
    Gets a list of imported files matching a file name

.PARAMETER Name <string>
    The file base name or full name; wildcards are permitted

.OUTPUTS <string[]>
    The files full name
#>
function script:Get-Files {
    param([string]$Name = ".*")

    if([System.IO.Path]::IsPathRooted($Name)) {
        ${!Files!} | Where { $_ -eq $Name }
    } else {
        ${!Files!} | Where { $_ -match ".*\\$Name\.(ps1)$" }
    }
}

<#
.SYNOPSIS 
   Sets the default project

.PARAMETER Name <string>
   The project name

.OUTPUTS
   None
#>
function script:Set-Project {
    param([string]$Name)

    $private:Project = Get-SolutionProjects | Where { $_.Name -eq $Name } | Select -First 1

    if (-not $private:Project) {
        Write-BuildMessage -Message "Cannot find project $Name" -ForegroundColor "Yellow"
        # Find first project in the solution
        $private:Project = Get-SolutionProjects | Select -First 1
        Set-BuildProperty -Name ProjectName -Value $private:Project.Name
        Set-BuildProperty -Name ProjectFullPath -Value $private:Project.Directory
        Write-BuildMessage -Message "Using default project $script:ProjectName" -ForegroundColor "Yellow"
    } else {
        Write-BuildMessage -Message "Set default project $Name" -ForegroundColor "Yellow"
        Set-BuildProperty -Name ProjectName -Value $Name
        Set-BuildProperty -Name ProjectFullPath -Value $private:Project.Directory
    }

    Set-BuildProperty -Name ProjectFullName -Value (Get-ProjectFullName)
    Set-BuildProperty -Name ArtifactFullPath -Value (Join-Path $BuildOutputFullPath $script:ProjectName)

    Refresh-Properties
}

<#
.SYNOPSIS 
   Removes recursively any pdb (Program Database) file found in a given path

.PARAMETER Path <string>

.OUTPUTS
   None
#>
function script:Remove-PdbFiles {
    param([string]$Path)

    foreach($Item in (Get-ChildItem -Path "$Path" -Recurse -File -Include *.pdb | Select-Object -ExpandProperty FullName)) {
        Remove-ItemSilently $Item
    }
}

<#
.SYNOPSIS 
   Gets the MSBuild build output directory for a given a project name

.PARAMETER ProjectName <string>

.OUTPUTS <string>
   The absolute path
#>
function script:Get-ProjectBuildOutputDir {
    param([Parameter(Mandatory=$true,ValueFromPipeline=$true)][string]$ProjectName)

    Begin { 
        $private:Result = @() 
        $private:SolutionProjects = Get-SolutionProjects
    }
    
    Process {
        $Directory = $SolutionProjects | Where { $_.Name -eq $ProjectName } | Select -First 1 -ExpandProperty Directory
        Assert ($Directory -and (Test-Path $Directory)) "Cannot find project $ProjectName directory"
        if ($Configuration -and $Platform -and (Test-Path (Join-Path $Directory "bin\$Platform\$Configuration"))) {
            # Project directory with build configuration and platform
            $Result += Join-Path $Directory "bin\$Platform\$Configuration"
        } elseif ($Configuration -and (Test-Path (Join-Path $Directory "bin\$Configuration"))) {
            # Project directory with build configuration
            $Result += Join-Path $Directory "bin\$Configuration"
        } elseif (Test-Path (Join-Path $Directory "bin")) {
            # Project directory with bin folder
            $Result += Join-Path $Directory "bin"
        }
    }

    End { 
        if ($Result.Count -eq 1) { 
            $Result[0] 
        } else { 
            $Result 
        } 
    }
}

<#
.SYNOPSIS 
   Gets the git executable

.OUTPUTS <string>
   The full name
#>
function script:Get-GitExe {
    Get-Command git -ErrorAction SilentlyContinue | Select -ExpandProperty Source
}

<#
.SYNOPSIS 
   Gets the last git committer date

.OUTPUTS <DateTime>
#>
function script:Get-CommitterDate {
    $GitExe = Get-GitExe

    if (-not $GitExe -or -not (Test-Path $GitExe)) {
        return [DateTime]::Now
    }
    
    $Date = exec { & $GitExe -C "$($SolutionFullPath.Trim('\'))" show --no-patch --format=%ci }
    
    return [DateTime]::Parse($Date, $null, [System.Globalization.DateTimeStyles]::RoundtripKind)
}

<#
.SYNOPSIS 
   Gets the current git branch name

.OUTPUTS <string>
#>
function script:Get-Branch {
    $GitExe = Get-GitExe

    if (-not $GitExe -or -not (Test-Path $GitExe)) {
        return [string]::Empty
    }

    $RawName = exec { git -C "$($SolutionFullPath.Trim('\'))" name-rev --name-only HEAD }
    
    if ($RawName -match '/([^/]+)$') {
        # In this case we resolved refs/heads/branch_name but we are only interested in branch_name
        $Name = $Matches[1]
    } else {
        $Name = $RawName
    }

    # If the current revision is behind HEAD, strip out such information from the name (e.g. master~1)
    return ($Name -replace "[~]\d+", "") | Select @{Name="Name"; Expression={$_}}, @{Name="IsMaster"; Expression={$_ -eq "master"}}
}

<#
.SYNOPSIS 
   Gets the version based on the last git committer date

.OUTPUTS <object>
   --------------------------------- EXAMPLE --------------------------------
   Example in the master branch with committer date 2016-08-05 07:44:15
   @{
      Major = 2016
      Minor = 8
      Patch = 5074415
      PreReleaseLabel = ''
      Build = 5
      Revision = 74415
      SemVer = '2016.8.5.74415'
      AssemblySemVer = '2016.8.5.744'
      InformationalVersion = '2016.8.5.74415'
   }
   --------------------------------- EXAMPLE --------------------------------
   Example in a branch 'new-feature' with committer date 2016-08-05 07:44:15
   @{
      Major = 2016
      Minor = 8
      Patch = 5074415
      PreReleaseLabel = 'new-feature'
      Build = 5
      Revision = 74415
      SemVer = '2016.8.5.74415-new-feature'
      AssemblySemVer = '2016.8.5.744'
      InformationalVersion = '2016.8.5.74415-new-feature'
   }
#>
function script:Get-Version {
    $CommitterDate = Get-CommitterDate
    $Branch = Get-Branch

    $Major = $CommitterDate.Year
    $Minor = $CommitterDate.Month.ToString("D1")
    $Build = $CommitterDate.Day.ToString("D1")
    $Patch = "$Build$($CommitterDate.Hour.ToString('D2'))$($CommitterDate.Minute.ToString('D2'))$($CommitterDate.Second.ToString('D2'))"
    $Revision = "$($CommitterDate.Hour.ToString('D1'))$($CommitterDate.Minute.ToString('D2'))$($CommitterDate.Second.ToString('D2'))"
    $PreReleaseLabel = if ($Branch.IsMaster) { "" } else { $Branch.Name[0..19] -join "" }
    $InformationalVersion = if ($PreReleaseLabel) { "$Major.$Minor.$Build.$Revision-$PreReleaseLabel" } else { "$Major.$Minor.$Build.$Revision" }

    return New-Object PSObject -Property ([ordered]@{
        Major = $Major;
        Minor = $Minor;
        Patch = $Patch;
        PreReleaseLabel = $PreReleaseLabel;
        Build = $Build;
        Revision = $Revision;
        SemVer = $InformationalVersion;
        # Remove the Seconds from $Revision due to build numbers limited to 65535
        AssemblySemVer = "$Major.$Minor.$Build.$($Revision -replace '.{2}$')";
        InformationalVersion = $InformationalVersion;
    })
}

<#
.SYNOPSIS 
   Gets the semantic version

.PARAMETER SemanticVersion <string>

.OUTPUTS <object>
   ---------------------------------------------- EXAMPLE ----------------------------------------------
   Example in the master branch with semantic version 1.4.2
   @{
      Major = 1
      Minor = 4
      Patch = 2
      PreReleaseLabel = ''
      Build = 2
      Revision = 0
      SemVer = '1.4.2'
      AssemblySemVer = '1.4.2.0'
      InformationalVersion = '1.4.2'
   }
   ---------------------------------------------- EXAMPLE ----------------------------------------------
   Example in the master branch with semantic version 1.4.2-beta01
   @{
      Major = 1
      Minor = 4
      Patch = 2
      PreReleaseLabel = 'beta01'
      Build = 2
      Revision = 0
      SemVer = '1.4.2-beta01'
      AssemblySemVer = '1.4.2.0'
      InformationalVersion = '1.4.2-beta01'
   }
   ---------------------------------------------- EXAMPLE ----------------------------------------------
   Example in a branch 'new-feature' with semantic version 1.4.2 and committer date 2016-11-12 11:35:20
   @{
      Major = 1
      Minor = 4
      Patch = 2
      PreReleaseLabel = 'pre20161112113520'
      Build = 2
      Revision = 0
      SemVer = '1.4.2-pre20161112113520'
      AssemblySemVer = '1.4.2.0'
      InformationalVersion = '1.4.2-pre20161112113520'
   }
#>
function script:Get-SemanticVersion {
    param([string]$SemanticVersion)

    $VersionParts = $SemanticVersion.Split(".")
    $PatchParts = $VersionParts[2].Split("-")

    $Major = $VersionParts[0]
    $Minor = $VersionParts[1]
    $Patch = $PatchParts[0]
    
    $PreReleaseLabel = $PatchParts[1]
    if (-not (Get-Branch).IsMaster -and -not $PreReleaseLabel) {
        # Set pre-release label if not in master
        $CommitterDate = Get-CommitterDate
        $PreReleaseLabel = "pre$($CommitterDate.Year)$($CommitterDate.Month.ToString('D2'))$($CommitterDate.Day.ToString('D2'))$($CommitterDate.Hour.ToString('D2'))$($CommitterDate.Minute.ToString('D2'))$($CommitterDate.Second.ToString('D2'))"
    }

    $SemVer = if ($PreReleaseLabel) { "$Major.$Minor.$Patch-$PreReleaseLabel" } else { "$Major.$Minor.$Patch" }
    
    return New-Object PSObject -Property ([ordered]@{
        Major = $Major;
        Minor = $Minor;
        Patch = $Patch;
        PreReleaseLabel = $PreReleaseLabel;
        Build = $Patch;
        Revision = 0;
        SemVer = $SemVer;
        AssemblySemVer = "$Major.$Minor.$Patch.0";
        InformationalVersion = $SemVer
    })
}

<#
.SYNOPSIS 
   Gets the semantic version from a given project's version.txt

.PARAMETER Name <string>
   The project name
   Defualt to $ProjectName

.OUTPUTS <object>
   See Get-SemanticVersion
#>
function script:Get-ProjectSemanticVersion {
    param([string]$Name = $ProjectName)
    
    $VersionFile = Get-SolutionProjects `
                    | Where { $_.Name -eq $Name } `
                    | Select -First 1 -ExpandProperty Directory `
                    | Join-Path -ChildPath "Version.txt"

    Assert (Test-Path $VersionFile) "Cannot find version file in project $Name"
    
    Get-SemanticVersion (Get-Content $VersionFile | ? { $_.Trim() -ne '' }).Trim()
}

<#
.SYNOPSIS 
   Invokes tasks in parallel

.PARAMETER Task <string[]>

.PARAMETER Result
   Tells to output build information using a variable.

.PARAMETER TaskProperties <string[]>
   Custom properties which overrides the existings when name matches

.EXAMPLE
   Jobs Task1, Task2 -CustomProperty "CustomPropertyValue"

.OUTPUTS
   Output of invoked builds and other log messages
#>
function script:Jobs {
    param(
        [Parameter(Position=0)][string[]]$Task,
        $Result,
        [Parameter(ValueFromRemainingArguments=$true)][string[]]$TaskProperties
    )

    # Create the list of properties for the new parallel build script
    $Properties = ${!BuildProperties!}
    for ($i=0; $i -lt $TaskProperties.Count; $i+=2) {
        $Key = ($TaskProperties[$i] -replace '^-+') 
        $Value = $TaskProperties[$i+1]
        if ($Properties.ContainsKey($Key)) {
            $Properties.Set_Item($Key, $Value)
        } else {
            $Properties.Add($Key, $Value)
        }
    }

    # Create the parallel build script
    $ParallelBuildScript = New-Item -ItemType File -Name "$([System.IO.Path]::GetRandomFileName()).ps1" -Path $Env:Temp -Value {
        param(
            [Alias("Files")] $private:Files,
            [Alias("Properties")] $private:Properties=@{}
        )

        # Import Pask script
        . $private:Files[0]

        # Set Pask properties
        $private:Properties.Keys | % { Set-BuildProperty -Name $_ -Value $private:Properties.Item($_) }

        # Import files
        for ($i=1; $i -lt $private:Files.Count; $i+=1) {
            . $private:Files[$i]
        }

        # Include the build script
        . "$(Join-Path $BuildFullPath "build.ps1")"
    }

    # Invoke to parallel tasks
    Invoke-Builds @(@{File=$ParallelBuildScript.FullName; Task=$Task; Result="!BuildsResult!"; "private:Files"=(Get-Files); "private:Properties"=$Properties})

    # Output build information using a variable
    if ($Result -and $Result -is [string]) {
        New-Variable -Name $Result -Force -Scope 1 -Value ${!BuildsResult!}
    } elseif ($Result) {
        $Result.Value = ${!BuildsResult!}
    }

    # Remove the parallel build script
    Remove-Item "$($ParallelBuildScript.FullName)" -Force
}