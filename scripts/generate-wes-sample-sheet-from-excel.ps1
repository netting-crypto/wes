param(
    [Parameter(Mandatory = $true)]
    [string]$ExcelPath,
    [Parameter(Mandatory = $true)]
    [string]$FastqDir,
    [Parameter(Mandatory = $true)]
    [string]$OutPath
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

Add-Type -AssemblyName System.IO.Compression.FileSystem

function Get-EntryText {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.Compression.ZipArchive]$Zip,
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $entry = $Zip.Entries | Where-Object { $_.FullName -eq $Name } | Select-Object -First 1
    if ($null -eq $entry) {
        return $null
    }

    $reader = New-Object System.IO.StreamReader($entry.Open())
    try {
        return $reader.ReadToEnd()
    } finally {
        $reader.Dispose()
    }
}

function Get-CellText {
    param(
        [Parameter(Mandatory = $true)]
        [System.Xml.XmlElement]$Cell,
        [Parameter()]
        [AllowEmptyCollection()]
        [string[]]$SharedStrings,
        [Parameter(Mandatory = $true)]
        [System.Xml.XmlNamespaceManager]$Ns
    )

    $type = [string]$Cell.GetAttribute("t")
    if ($type -eq "s") {
        return $SharedStrings[[int]$Cell.v]
    }
    if ($type -eq "inlineStr") {
        return (($Cell.SelectNodes(".//d:t", $Ns) | ForEach-Object { $_.InnerText }) -join "")
    }
    return [string]$Cell.v
}

function Get-SampleIdFromFileName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FileName
    )

    $sampleId = $FileName
    $sampleId = $sampleId -replace '\.fastq\.gz$', ''
    $sampleId = $sampleId -replace '\.fq\.gz$', ''
    $sampleId = $sampleId -replace '_L\d{3}_R[12]_001$', ''
    $sampleId = $sampleId -replace '_S\d+_R[12]_001$', ''
    $sampleId = $sampleId -replace '_R[12]_001$', ''
    $sampleId = $sampleId -replace '\.R[12]$', ''
    $sampleId = $sampleId -replace '_R[12]$', ''
    return $sampleId
}

function Resolve-Pair {
    param(
        [Parameter(Mandatory = $true)]
        [string]$EntryText
    )

    $parts = @($EntryText -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($parts.Count -lt 2) {
        return $null
    }

    $r1 = $parts | Where-Object { $_ -match '(^|[._])R?1([._]|$)' } | Select-Object -First 1
    $r2 = $parts | Where-Object { $_ -match '(^|[._])R?2([._]|$)' } | Select-Object -First 1

    if ([string]::IsNullOrWhiteSpace($r1) -or [string]::IsNullOrWhiteSpace($r2)) {
        if ($parts.Count -eq 2) {
            $r1 = $parts[0]
            $r2 = $parts[1]
        } else {
            return $null
        }
    }

    return [pscustomobject]@{
        R1 = $r1
        R2 = $r2
    }
}

$zip = [System.IO.Compression.ZipFile]::OpenRead($ExcelPath)
try {
    [xml]$workbookXml = Get-EntryText -Zip $zip -Name 'xl/workbook.xml'
    [xml]$relsXml = Get-EntryText -Zip $zip -Name 'xl/_rels/workbook.xml.rels'

    $nsMain = New-Object System.Xml.XmlNamespaceManager($workbookXml.NameTable)
    $nsMain.AddNamespace('d', 'http://schemas.openxmlformats.org/spreadsheetml/2006/main')
    $nsRel = New-Object System.Xml.XmlNamespaceManager($relsXml.NameTable)
    $nsRel.AddNamespace('r', 'http://schemas.openxmlformats.org/package/2006/relationships')

    $firstSheet = $workbookXml.SelectSingleNode('//d:sheets/d:sheet[1]', $nsMain)
    $sheetName = [string]$firstSheet.GetAttribute("name")
    $relId = $firstSheet.GetAttribute('id', 'http://schemas.openxmlformats.org/officeDocument/2006/relationships')
    $relNode = $relsXml.SelectSingleNode("//r:Relationship[@Id='$relId']", $nsRel)
    $target = [string]$relNode.Target
    if ($target -notmatch '^xl/') {
        $target = 'xl/' + $target.TrimStart('/')
    }

    $sharedStrings = @()
    $sharedText = Get-EntryText -Zip $zip -Name 'xl/sharedStrings.xml'
    if ($sharedText) {
        [xml]$sharedXml = $sharedText
        $nsShared = New-Object System.Xml.XmlNamespaceManager($sharedXml.NameTable)
        $nsShared.AddNamespace('d', 'http://schemas.openxmlformats.org/spreadsheetml/2006/main')
        foreach ($si in $sharedXml.SelectNodes('//d:sst/d:si', $nsShared)) {
            $sharedStrings += (($si.SelectNodes('.//d:t', $nsShared) | ForEach-Object { $_.InnerText }) -join '')
        }
    }

    [xml]$sheetXml = Get-EntryText -Zip $zip -Name $target
    $nsSheet = New-Object System.Xml.XmlNamespaceManager($sheetXml.NameTable)
    $nsSheet.AddNamespace('d', 'http://schemas.openxmlformats.org/spreadsheetml/2006/main')

    $headerCells = @{}
    foreach ($cell in $sheetXml.SelectNodes('//d:worksheet/d:sheetData/d:row[@r="1"]/d:c', $nsSheet)) {
        if ($cell.r -match '^([A-Z]+)1$') {
            $headerCells[$Matches[1]] = Get-CellText -Cell $cell -SharedStrings $sharedStrings -Ns $nsSheet
        }
    }

    $fastqCol = $null
    foreach ($key in $headerCells.Keys) {
        if ($headerCells[$key] -eq 'fastq_files') {
            $fastqCol = $key
            break
        }
    }
    if ([string]::IsNullOrWhiteSpace($fastqCol)) {
        throw "Could not find a 'fastq_files' column in $sheetName"
    }

    $rows = New-Object System.Collections.Generic.List[object]
    $seenEntries = New-Object 'System.Collections.Generic.HashSet[string]'

    foreach ($row in $sheetXml.SelectNodes('//d:worksheet/d:sheetData/d:row[position()>1]', $nsSheet)) {
        $cell = $row.SelectSingleNode("d:c[starts-with(@r,'$fastqCol')]", $nsSheet)
        if ($null -eq $cell) {
            continue
        }

        $entryText = (Get-CellText -Cell $cell -SharedStrings $sharedStrings -Ns $nsSheet).Trim()
        if ([string]::IsNullOrWhiteSpace($entryText)) {
            continue
        }
        if (-not $seenEntries.Add($entryText)) {
            continue
        }

        $pair = Resolve-Pair -EntryText $entryText
        if ($null -eq $pair) {
            continue
        }

        $sampleId = Get-SampleIdFromFileName -FileName $pair.R1
        $rows.Add([pscustomobject]@{
            sample_id = $sampleId
            family_id = $sampleId
            role = 'unknown'
            affected = '0'
            fastq_r1 = ($FastqDir.TrimEnd('/') + '/' + $pair.R1)
            fastq_r2 = ($FastqDir.TrimEnd('/') + '/' + $pair.R2)
            bam_path = ''
        }) | Out-Null
    }

    $rows = $rows | Sort-Object sample_id, fastq_r1
    $outDir = Split-Path -Parent $OutPath
    if (-not [string]::IsNullOrWhiteSpace($outDir)) {
        New-Item -ItemType Directory -Force -Path $outDir | Out-Null
    }

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("sample_id`tfamily_id`trole`taffected`tfastq_r1`tfastq_r2`tbam_path") | Out-Null
    foreach ($row in $rows) {
        $lines.Add(("{0}`t{1}`t{2}`t{3}`t{4}`t{5}`t{6}" -f $row.sample_id, $row.family_id, $row.role, $row.affected, $row.fastq_r1, $row.fastq_r2, $row.bam_path)) | Out-Null
    }
    [System.IO.File]::WriteAllLines($OutPath, $lines)

    Write-Output "sheet=$sheetName"
    Write-Output "sample_sheet=$OutPath"
    Write-Output "sample_count=$($rows.Count)"
}
finally {
    $zip.Dispose()
}
