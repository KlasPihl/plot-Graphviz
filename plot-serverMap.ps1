<#
.Synopsis
    Creates graphical network map of servers
.DESCRIPTION
    Dependent on Graphviz and PSGraph
    Can be used as data collector with imported data to create a network map.


.PARAMETER ShowPorts
    Include connections for each port, otherwise only a connection is shown.
    For a complete map logging of data should run for days, then multiple data on connections on ports will be available.
        If so the color and width of the arrows will represent the most used ports.


    TCP connections shown in 'black' or grayscale depending if multiple connections is found.
    UDP is shown in a brown color or scale.
.PARAMETER Computerlist
    Computer FQDN

.PARAMETER ExcludeService
    Service names to be ignored.

.PARAMETER ExcludePort
    Ports to be ignored.

.PARAMETER SelectPort
    List separated by '|' for selected ports to map. Others is excluded.

.PARAMETER CollectData
    Only gather data and export to -Path

.PARAMETER Path
    Target or source path of logging.

    Format;
        UFT8
        Delimiter ';'
        Headers;
            "ForeignPort";"Date";"LocalPort";"ForeignAddress";"LocalAddress";"State";"PID";"ProcessName";"Protocol";"PSComputerName";"RunspaceId";"PSShowComputerName"


.PARAMETER OnlyShowFQDN
    Ignores ForeignAddress if not possible to reslve FQDN.

.PARAMETER ExcludeComputer
    List of computers to exlude from map.

.EXAMPLE
    "pihl-dc.pihl.local" | .\plot-serverMap.ps1 -Path .\pihl-dc.csv -SelectPort "139|445"
.EXAMPLE
    1..24| ForEach-Object {"pihl-fs.pihl.local" | .\plot-serverMap.ps1 -CollectData -cred $cred -Path pihl-fs.csv ;Start-Sleep -Seconds (60*60)}
        Collect connections from 'pihl-fs.pihl.local' once an hour and saves to pihl-fs.csv

.EXAMPLE
    "pihl-fs.pihl.local" | .\plot-serverMap.ps1 -ShowPorts -cred $cred -Path test1.csv -InformationAction Continue

.EXAMPLE
    "pihl-fs.pihl.local" | .\plot-serverMap.ps1 -OnlyShowFQDN -ExcludeComputer @("host.docker.internal";"vpn.pihl.local") -ShowPorts -InformationAction Continue -Verbose

    Collects connections on "pihl-fs.pihl.local",
        removes any foreign device that can't resolve DNS,
        removes foreign device defined in -ExcludeComputer,
        Shows port

.EXAMPLE
    (Get-ADComputer -SearchBase 'OU=Domain Controllers,DC=pihl,DC=local' -Filter * |
        Select-Object -ExpandProperty DNSHostName) |
        .\plot-serverMap.ps1 -cred $cred -ShowPorts
.OUTPUTS
    Picture in .png format
    Global variable $Graph
.NOTES
    2019-07-10 Initial code when I got frustrated of bad documentation at customer site.
    2022-03-18 Refresh of code https://github.com/KlasPihl


#>
[CmdletBinding()]
Param
(
    #[Alias('ComputerList')]
    [Parameter(Mandatory = $True,
        ValueFromPipeline = $True)]
    $Computer,

    [switch] $ShowPorts,
    [Parameter(Mandatory = $true,
        ValueFromPipelineByPropertyName = $false)]
    [System.Management.Automation.PSCredential]$cred,
    $ExcludeService = 'HealthService|lsass|CcmExec',
    $ExcludePort =  '5985|139|135',
    $SelectPort,
    [switch]$CollectData,
    [ValidateScript({if(-not $CollectData) {Test-Path $PSitem} else {$true}})]
    $Path,
    [switch]$OnlyShowFQDN,
    [array]$ExcludeComputer
)
#require PSGraph

BEGIN {
    $ComputerList = @()
}
PROCESS {

    $ComputerList +=
    Switch ($Computer.GetType()) {
        { $_.Name -eq 'String' }
        { $Computer }
        { $_.Name -eq 'Hashtable' }
        { $Computer.ComputerName }
        { $_.Name -eq 'PSCustomObject' -and (Get-Member -MemberType Properties -Name "Computer" -InputObject $Computer) }
        { $Computer.Computer }
        { $_.Name -eq 'PSCustomObject' -and (Get-Member -MemberType Properties -Name "ComputerName" -InputObject $Computer) }
        { $Computer.ComputerName }
    }
}
END {

    Import-Module PSGraph
    #region functions
    function convert-Scale {
        <#
        .SYNOPSIS
            Re-map integer numers for scaling

        .DESCRIPTION
            If highest, topcount, is one no scaling is done.

        .NOTES
            2022-03-18 Version 1 Klas.Pihl@Atea.se
        .LINK
            http://james-ramsden.com/map-a-value-from-one-number-scale-to-another-formula-and-c-code/
        .EXAMPLE
            convert-scale 8 3
                Top value is 8 and scale on a value of 2
                Rounded result: 4
        #>
        [CmdletBinding()]
        param (
        $TopCount,
        $LowerCount=1,
        $Count,
        $LowerScale=2,
        $UpperScale=9 #width high based on https://graphviz.org/doc/info/colors.html
        )
        if($count -lt 1) {
            $Count = 1
        }
        if($TopCount -eq 1) {
            return $UpperScale
        } else {
            [math]::Round($LowerScale + ($UpperScale - $LowerScale) * (($Count-$LowerCount)/($TopCount-$LowerCount)))
        }

    }
    function get-NetStat  {
        <#
        .SYNOPSIS
            Collect netstat on TCP and UDP by Invoking netstat on remote computer.

        .EXAMPLE
            get-netstat -HostName pihl-fs.pihl.local -cred $cred

        .OUTPUTS
            ForeignPort Date           LocalPort ForeignAddress LocalAddress State       PID ProcessName Protocol PSComputerName
            ----------- ----           --------- -------------- ------------ -----       --- ----------- -------- --------------
            64206       20220319 10:41 49667     10.254.0.84    10.254.0.102 ESTABLISHED 380 svchost     TCP      pihl-fs.pihl.local
        #>
        [CmdletBinding()]
        param (
            $Computer,
            $cred
        )
        [scriptblock]$SBnetstat =
        {
            function parse-netstat ($NetstatOutput) {
                foreach ($line in $NetstatOutput) {

                    # Remove the whitespace at the beginning on the line
                    $line = $line -replace '^\s+', ''

                    # Split on whitespaces characteres
                    $line = $line -split '\s+'

                    $Date = get-date -Format "yyyyMMdd HH:mm"
                    # Define Properties
                    $properties = @{
                        Protocol      = $line[0]
                        LocalAddress   = $line[1].Split(':')[0]
                        LocalPort      = $line[1].Split(':')[1]
                        ForeignAddress = $line[2].Split(':')[0]
                        ForeignPort    = $line[2].Split(':')[1]
                        State          = $line[3]
                        PID            = $line[4]
                        ProcessName    = $($processes | Where-Object { $_.id -eq $line[4] }).ProcessName
                        Date = $Date
                    }

                    # Output object
                    New-Object -TypeName PSObject -Property $properties
                }
            }
            $processes = get-process | Select-Object id, ProcessName
            $connections = netstat -aon -p tcp | select-string 'ESTABLISHED' | Out-String
            $connections += netstat -aon -p udp | select-string 'ESTABLISHED' | Out-String
            $connections = $connections.Split([Environment]::NewLine, [StringSplitOptions]::RemoveEmptyEntries)
            $formattedOutput = parse-netstat -NetstatOutput $connections | Where-Object { $_.LocalAddress -ne '127.0.0.1' }
            return $formattedOutput
        }
        $data = Invoke-Command -ComputerName $Computer -ScriptBlock $SBnetstat -Credential $cred
        return $data
    }
    function test-WSManComputer  {
        <#
        .SYNOPSIS
            Test if computer is able to communicate by WSMan used by invoking commands to get netstat logs.

        #>
        param (
            $ComputerList
        )
        foreach ($Computer in $ComputerList) {
            if ([bool](Test-WSMan $Computer -ErrorAction SilentlyContinue )) {
                Write-Output $Computer
            }
            else { Write-Warning "$computer no connection by WinRM" }
        }
    }

    #endregion functions

    #format ComputerList to lower
    $ComputerList = $ComputerList | ForEach-Object { $_.tolower() }
    Write-Verbose "Computerlist: $($ComputerList | Format-Table | Out-String)"
    #validate that computer is aple to connect by WinRM, if not thow warning.
    $ComputerListConnect = test-WSManComputer -ComputerList $ComputerList
    if (!$ComputerListConnect) {
        Write-Warning "No valid computers"
        break
    }
    $data = @() #empty array
    #region get netstat data from all computers
    if($PSBoundParameters.ContainsKey("Path")) {
        Write-Verbose "Define CSV parameters"
        $CSVSplattImport = @{
            Delimiter =  ';'
            Encoding = 'utf8'
            Path = $Path
        }
        $CSVSplattExport = $CSVSplattImport + @{
            NoClobber = $true
            Append =$true
            NoTypeInformation = $true
            Force = $true
        }
    }

    if($PSBoundParameters.ContainsKey("Path") -and (-not $CollectData)) {
        Write-Verbose "Load data from $Path"
        $data = Import-Csv @CSVSplattImport
    } else {

        foreach ($Computer in $ComputerListConnect) {
            Write-Verbose "Collect sessions from $($Computer | out-string)"
            $data += get-netstat -Computer $Computer -cred $cred
        }
    }
    if($PSBoundParameters.ContainsKey("Path") -and $CollectData) {
        Write-Verbose "Export data to $path"
        $data | Export-Csv @CSVSplattExport
    } else {
        Write-Verbose "Compile data"
        if($PSBoundParameters.ContainsKey('SelectPort')) {
            $ConnectionsToNetwork = $data | Where-Object LocalPort -match $SelectPort
        } else {
            $ConnectionsToNetwork = $data | Where-Object { $_.LocalPort -notmatch $ExcludePort -and $_.ProcessName -notmatch $ExcludeService }
        }
        if(-not $ConnectionsToNetwork) {
            Write-Error "No sessons found"
            exit(1)
        }

        $grafData = ($ConnectionsToNetwork | Group-Object ForeignAddress, LocalPort, LocalAddress,Protocol,Date).name #LocalPort

        $grafDataCSV = $grafData | ConvertFrom-Csv -Delimiter ',' -Header 'ForeignAddress', 'LocalPort', 'LocalAddress','Protocol','Date', 'LocalFQDN', 'ForeignFQDN'


        #endregion get netstat data from all computers

        #region add known FQDN
        #Several redundat querys made, could be optimized
        Write-Verbose "Resolve name on foreign hosts"
        $allHosts = (($grafDataCSV.ForeignAddress + $grafDataCSV.LocalAddress) | Group-Object).name | ConvertFrom-Csv -Header 'IP', 'FQDN'
        $Counter = 1
        foreach ($node in $allHosts) {
            Write-Progress -Activity "Resolve name on foreign hosts" -Status ("{0}/{1}" -f $counter,$allHosts.count) -PercentComplete (100*$Counter/$allHosts.Count)
            $Counter++
            $FQDN = Resolve-DnsName -Name $node.IP -NoRecursion -QuickTimeout -ErrorAction SilentlyContinue -TcpOnly | Select-Object -First 1
            if ($FQDN) {
                $node.FQDN = $FQDN.namehost.tolower()
            } elseif(-not $OnlyShowFQDN) {
                try { $node.FQDN = ($data | Where-Object { $node.IP -eq $_.LocalAddress }).PSComputerName[0] }
                catch { $node.FQDN = $node.IP }
                #$node.FQDN = $node.IP
                Write-Warning "No DNS found $($node.IP)"
            } else {
                Write-Warning "No DNS found $($node.IP), exlude from result as of parameter '-OnlyShowFQDN'"
            }
        }
        $allHosts = $allHosts | Where-Object {$PSitem.FQDN -and ($ExcludeComputer -notcontains $PSitem.FQDN)}
        foreach ($connection in $grafDataCSV) {
            $connection.LocalFQDN = ($allHosts | Where-Object { $_.IP -eq $connection.LocalAddress }).FQDN | Get-Unique
            $connection.ForeignFQDN = ($allHosts | Where-Object { $_.IP -eq $connection.ForeignAddress }).FQDN | Get-Unique
        }
        $grafDataCSV = $grafDataCSV | Where-Object ForeignFQDN

        #Write-Verbose $($grafDataCSV | Format-Table | Out-String)
        #region graf
        if($ShowPorts) {
            Write-Verbose "Group sessons on port and ForeignAddress"
            $grafDataCSV = ($grafDataCSV | Group-Object ForeignAddress,LocalPort) |
                Select-Object Count,
                    @{Name='ForeignAddress';E={$PSitem.Group.ForeignAddress| Select-Object -First 1}},
                    @{Name='LocalPort';E={$PSitem.Group.LocalPort| Select-Object -First 1}},
                    @{Name='LocalAddress';E={$PSitem.Group.LocalAddress| Select-Object -First 1}},
                    @{Name='Protocol';E={$PSitem.Group.Protocol| Select-Object -First 1}},
                    @{Name='Date';E={$PSitem.Group.Date| Select-Object -First 1}},
                    @{Name='LocalFQDN';E={$PSitem.Group.LocalFQDN| Select-Object -First 1}},
                    @{Name='ForeignFQDN';E={$PSitem.Group.ForeignFQDN| Select-Object -First 1}}
            $TopPortCount = $grafDataCSV | Measure-Object -Property Count -Maximum | Select-Object -ExpandProperty Maximum
        }


        #penwidth=2 color
        $Global:Graph = graph g @{rankdir = 'TB';concentrate="true"; } {
            node -Default @{shape = 'box3d' } #ellipse

            <# Definition dont render in Grapwhiz
            node definitions @{shape='plaintext';label=' <

            <TABLE BORDER="0" CELLBORDER="1" CELLSPACING="0">
                <TR><TD BGCOLOR="green">Local</TD></TR>
                <TR><TD BGCOLOR="gray">Foreign</TD></TR>
                <TR><TD BGCOLOR="black"><FONT COLOR="white">TCP</FONT></TD></TR>
                <TR><TD BGCOLOR="orange4">UDP</TD></TR>
                <TR>
                    <TD>
                        <TABLE CELLPADDING="0" BORDER="0" CELLSPACING="0">
                                        <TR>
                                            <TD><FONT COLOR="green">n</FONT></TD>
                                            <TD><FONT COLOR="black" POINT-SIZE="8">x</FONT></TD>
                                            <TD><FONT COLOR="red">port</FONT></TD>
                                        </TR>
                        </TABLE>
                    </TD>
                </TR>
            </TABLE>
            >'
        }
        #>
            #create nodes
            $allHosts | ForEach-Object {
                if (($ComputerListConnect -contains $PSitem.FQDN) -or ($ComputerListConnect -eq $PSitem.FQDN)) {
                    $fillColour = 'green'
                } else {
                    $fillColour = 'gray'
                }
                node $PSitem.IP @{label = $PSitem.FQDN; fillcolor = $fillColour; style = 'filled' }
            }
            #create connections
            if ($ShowPorts) {
                foreach ($connection in $grafDataCSV) {
                    $colorscheme = switch ($connection.Protocol) {
                        TCP { "greys9" }
                        UDP { "ylorbr9" }
                    }
                    switch ($connection.count) {
                        1 {
                            $penwidth = 1
                            $color = 9
                            $label =$connection.LocalPort
                        }
                        default {
                            $penwidth = convert-scale -TopCount $TopPortCount -LowerCount 1 -LowerScale 2 -UpperScale 9 -Count $connection.Count
                            $color = $penwidth
                            $label = ("{0}x{1}" -f $connection.Count,$connection.LocalPort)
                        }
                    }
                    #$connection | ForEach-Object { edge $_.LocalAddress -from $_.ForeignAddress @{label = $_.LocalPort; style = 'bold' } }
                    edge $connection.LocalAddress -from $connection.ForeignAddress @{colorscheme=$colorscheme ;label = $label; style = 'bold';color=$color;penwidth=$penwidth;fontcolor="gray";}
                }
            }
            else {
                $grafDataCSVHosts = ($grafDataCSV | Group-Object LocalAddress, ForeignAddress).name | ConvertFrom-Csv -Delimiter ',' -Header 'ForeignAddress', 'LocalAddress'
                foreach ($connection in $grafDataCSVHosts) {
                    edge $connection.LocalAddress -from $connection.ForeignAddress @{label = $null; style = 'bold' }
                }
            }
        }
        $ResultExportPicture = $Graph | Export-PSGraph -ShowGraph
        Write-Information ("Picture path: {0}" -f$ResultExportPicture.fullname)


        #end region graf
    }
}