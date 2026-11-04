param(
    [Parameter(Mandatory=$true)][string]$ImagePath,
    [Parameter(Mandatory=$true)][string]$OutputPath,
    [switch]$WordBoxes,
    [int]$Scale = 2
)
$ErrorActionPreference = 'Stop'
$ocrScaledPath = $null
$ocrActualScale = 1
try {
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    [Windows.Storage.StorageFile, Windows.Storage, ContentType=WindowsRuntime] | Out-Null
    [Windows.Storage.Streams.IRandomAccessStream, Windows.Storage.Streams, ContentType=WindowsRuntime] | Out-Null
    [Windows.Graphics.Imaging.BitmapDecoder, Windows.Graphics.Imaging, ContentType=WindowsRuntime] | Out-Null
    [Windows.Graphics.Imaging.SoftwareBitmap, Windows.Graphics.Imaging, ContentType=WindowsRuntime] | Out-Null
    [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType=WindowsRuntime] | Out-Null
    [Windows.Media.Ocr.OcrResult, Windows.Foundation, ContentType=WindowsRuntime] | Out-Null
    $script:asTask = [System.WindowsRuntimeSystemExtensions].GetMethods() |
        Where-Object { $_.Name -eq 'AsTask' -and $_.IsGenericMethod -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' } |
        Select-Object -First 1
    function Await-Operation($Operation, [Type]$ResultType) {
        $task = $script:asTask.MakeGenericMethod($ResultType).Invoke($null, @($Operation))
        $task.Wait()
        return $task.Result
    }
    if ($Scale -gt 1) {
        Add-Type -AssemblyName System.Drawing
        $ocrSource = [Drawing.Image]::FromFile($ImagePath)
        try {
            $ocrActualScale = [Math]::Max(1,[Math]::Min($Scale,[Math]::Floor(2500 / [Math]::Max($ocrSource.Width,$ocrSource.Height))))
            if ($ocrActualScale -gt 1) {
                $ocrScaledPath = $OutputPath + '.scaled.png'
                $ocrBitmap = New-Object Drawing.Bitmap ($ocrSource.Width * $ocrActualScale),($ocrSource.Height * $ocrActualScale)
                $ocrGraphics = [Drawing.Graphics]::FromImage($ocrBitmap)
                try {
                    $ocrGraphics.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                    $ocrGraphics.DrawImage($ocrSource,0,0,$ocrBitmap.Width,$ocrBitmap.Height)
                    $ocrBitmap.Save($ocrScaledPath,[Drawing.Imaging.ImageFormat]::Png)
                } finally { $ocrGraphics.Dispose(); $ocrBitmap.Dispose() }
                $ImagePath = $ocrScaledPath
            }
        } finally { $ocrSource.Dispose() }
    }
    $file = Await-Operation ([Windows.Storage.StorageFile]::GetFileFromPathAsync($ImagePath)) ([Windows.Storage.StorageFile])
    $stream = Await-Operation ($file.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
    try {
        $decoder = Await-Operation ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
        $bitmap = Await-Operation ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
        try {
            $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
            if ($null -eq $engine) { throw 'No installed OCR language is available.' }
            $result = Await-Operation ($engine.RecognizeAsync($bitmap)) ([Windows.Media.Ocr.OcrResult])
            $rows = foreach ($line in $result.Lines) {
                $words = @($line.Words)
                if ($words.Count -eq 0) { continue }
                if ($WordBoxes) {
                    foreach ($word in $words) {
                        $box = $word.BoundingRect
                        '{0}`t{1}`t{2}`t{3}`t{4}' -f [int]($box.X / $ocrActualScale),[int]($box.Y / $ocrActualScale),[int]($box.Width / $ocrActualScale),[int]($box.Height / $ocrActualScale),($word.Text -replace '[\t\r\n]',' ')
                    }
                    continue
                }
                $left = ($words | ForEach-Object { $_.BoundingRect.X } | Measure-Object -Minimum).Minimum
                $top = ($words | ForEach-Object { $_.BoundingRect.Y } | Measure-Object -Minimum).Minimum
                $right = ($words | ForEach-Object { $_.BoundingRect.X + $_.BoundingRect.Width } | Measure-Object -Maximum).Maximum
                $bottom = ($words | ForEach-Object { $_.BoundingRect.Y + $_.BoundingRect.Height } | Measure-Object -Maximum).Maximum
                '{0}`t{1}`t{2}`t{3}`t{4}' -f [int]($left / $ocrActualScale),[int]($top / $ocrActualScale),[int](($right-$left) / $ocrActualScale),[int](($bottom-$top) / $ocrActualScale),($line.Text -replace '[\t\r\n]',' ')
            }
            # Real tabs keep this deliberately small protocol readable in AHK.
            $rows = @($rows | ForEach-Object { $_.Replace('`t', "`t") })
            [IO.File]::WriteAllLines($OutputPath, $rows, [Text.UTF8Encoding]::new($false))
        } finally { if ($bitmap) { $bitmap.Dispose() } }
    } finally { if ($stream) { $stream.Dispose() } }
} catch {
    $detail = $_.Exception.ToString() -replace '[\r\n]+',' '
    [IO.File]::WriteAllText($OutputPath, "ERROR`t$detail", [Text.UTF8Encoding]::new($false))
    exit 1
}
 finally {
    if ($ocrScaledPath -and [IO.File]::Exists($ocrScaledPath)) { [IO.File]::Delete($ocrScaledPath) }
}
