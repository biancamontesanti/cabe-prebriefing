$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$Port = if ($env:PORT) { [int]$env:PORT } else { 4173 }
$Prefix = "http://localhost:$Port/"

$Types = @{
  ".html" = "text/html; charset=utf-8"
  ".mov" = "video/quicktime"
  ".mp4" = "video/mp4"
  ".png" = "image/png"
  ".jpg" = "image/jpeg"
}

function Send-File {
  param(
    [System.Net.HttpListenerContext]$Context,
    [string]$Path,
    [string]$ContentType
  )

  $Response = $Context.Response
  $File = [System.IO.FileInfo]::new($Path)
  $Response.ContentType = $ContentType
  $Response.AddHeader("Accept-Ranges", "bytes")

  $Start = 0L
  $End = $File.Length - 1L
  $Range = $Context.Request.Headers["Range"]

  if ($Range -match "bytes=(\d+)-(\d*)") {
    $Start = [int64]$Matches[1]
    if ($Matches[2]) {
      $End = [int64]$Matches[2]
    }
    $Response.StatusCode = 206
    $Response.AddHeader("Content-Range", "bytes $Start-$End/$($File.Length)")
  }

  $Length = $End - $Start + 1L
  $Response.ContentLength64 = $Length

  $Stream = [System.IO.File]::OpenRead($Path)
  try {
    $Stream.Seek($Start, [System.IO.SeekOrigin]::Begin) | Out-Null
    $Buffer = [byte[]]::new(65536)
    $Remaining = $Length

    while ($Remaining -gt 0) {
      $ReadSize = [Math]::Min($Buffer.Length, $Remaining)
      $Read = $Stream.Read($Buffer, 0, $ReadSize)
      if ($Read -le 0) { break }
      $Response.OutputStream.Write($Buffer, 0, $Read)
      $Remaining -= $Read
    }
  }
  finally {
    $Stream.Dispose()
    $Response.Close()
  }
}

$Listener = [System.Net.HttpListener]::new()
$Listener.Prefixes.Add($Prefix)
$Listener.Start()
Write-Host "Pixel landing page running at $Prefix"

try {
  while ($Listener.IsListening) {
    $Context = $Listener.GetContext()
    $Path = $Context.Request.Url.AbsolutePath

    $FilePath = if ($Path -eq "/") {
      Join-Path $Root "index.html"
    }
    else {
      Join-Path $Root ($Path.TrimStart("/"))
    }

    $ResolvedRoot = [System.IO.Path]::GetFullPath($Root)
    $ResolvedFile = [System.IO.Path]::GetFullPath($FilePath)

    if ($ResolvedFile.StartsWith($ResolvedRoot) -and [System.IO.File]::Exists($ResolvedFile)) {
      $Extension = [System.IO.Path]::GetExtension($FilePath)
      $ContentType = if ($Types.ContainsKey($Extension)) { $Types[$Extension] } else { "application/octet-stream" }
      Send-File -Context $Context -Path $ResolvedFile -ContentType $ContentType
    }
    else {
      $Context.Response.StatusCode = 404
      $Bytes = [System.Text.Encoding]::UTF8.GetBytes("Not found")
      $Context.Response.ContentLength64 = $Bytes.Length
      $Context.Response.OutputStream.Write($Bytes, 0, $Bytes.Length)
      $Context.Response.Close()
    }
  }
}
finally {
  $Listener.Stop()
}
