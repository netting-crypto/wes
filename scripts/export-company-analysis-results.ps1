param(
    [Parameter(Mandatory = $true)]
    [string]$ExcelPath,
    [string]$WorksheetName = "",
    [int]$WorksheetIndex = 2,
    [Parameter(Mandatory = $true)]
    [string]$OutputPath
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if (!(Test-Path -LiteralPath $ExcelPath)) {
    throw "Excel file not found: $ExcelPath"
}

$outputDir = Split-Path -Parent $OutputPath
if ($outputDir -and !(Test-Path -LiteralPath $outputDir)) {
    New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
}

$excel = New-Object -ComObject Excel.Application
$excel.Visible = $false
$excel.DisplayAlerts = $false
$workbook = $null

try {
    $workbook = $excel.Workbooks.Open($ExcelPath)
    $worksheet = $null

    if (-not [string]::IsNullOrWhiteSpace($WorksheetName)) {
        foreach ($candidate in $workbook.Worksheets) {
            if ([string]$candidate.Name -eq $WorksheetName) {
                $worksheet = $candidate
                break
            }
        }
    }

    if ($null -eq $worksheet) {
        if ($WorksheetIndex -lt 1 -or $WorksheetIndex -gt $workbook.Worksheets.Count) {
            throw "Worksheet index out of range: $WorksheetIndex"
        }
        $worksheet = $workbook.Worksheets.Item($WorksheetIndex)
    }

    $usedRange = $worksheet.UsedRange
    $rowCount = [int]$usedRange.Rows.Count
    $columnCount = [int]$usedRange.Columns.Count

    $header = @()
    for ($column = 1; $column -le $columnCount; $column++) {
        $header += ([string]$worksheet.Cells.Item(1, $column).Text -replace "`t", " ")
    }
    ($header -join "`t") | Set-Content -Path $OutputPath -Encoding UTF8

    for ($row = 2; $row -le $rowCount; $row++) {
        $values = @()
        $hasContent = $false
        for ($column = 1; $column -le $columnCount; $column++) {
            $value = [string]$worksheet.Cells.Item($row, $column).Text
            if ($value -ne "") {
                $hasContent = $true
            }
            $values += ($value -replace "`t", " ")
        }

        if ($hasContent) {
            ($values -join "`t") | Add-Content -Path $OutputPath -Encoding UTF8
        }
    }

    Write-Output $OutputPath
} finally {
    if ($workbook) {
        $workbook.Close($false) | Out-Null
        [System.Runtime.InteropServices.Marshal]::ReleaseComObject($workbook) | Out-Null
    }
    $excel.Quit()
    [System.Runtime.InteropServices.Marshal]::ReleaseComObject($excel) | Out-Null
    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()
}
