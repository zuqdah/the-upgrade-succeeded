#Requires -Version 7.2
<#
.SYNOPSIS
Requests a URL on a fixed interval until a stop file appears, one JSON line per request.

.DESCRIPTION
Runs as its own process so that nothing the drill does -- a Terraform apply
blocking for fifteen minutes, a kubectl call hanging -- can pause it. A gap in
the samples would read as "nothing failed" for exactly the moment something
might have.

Every request opens a new connection. A probe that reuses one keep-alive
connection is pinned to whichever pod answered first and never sees the others
fail, which is the opposite of what real traffic from many clients does.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][uri]$Url,
    [Parameter(Mandatory)][string]$OutFile,
    [Parameter(Mandatory)][string]$StopFile,
    [ValidateRange(50, 5000)][int]$IntervalMs = 200,
    [ValidateRange(100, 10000)][int]$TimeoutMs = 2000
)

$ErrorActionPreference = 'Stop'

$handler = [System.Net.Http.SocketsHttpHandler]::new()
$handler.PooledConnectionLifetime = [TimeSpan]::Zero
$handler.ConnectTimeout = [TimeSpan]::FromMilliseconds($TimeoutMs)
$client = [System.Net.Http.HttpClient]::new($handler)
$client.Timeout = [TimeSpan]::FromMilliseconds($TimeoutMs)

$writer = [System.IO.StreamWriter]::new($OutFile, $false, [System.Text.UTF8Encoding]::new($false))
try {
    while (-not (Test-Path -LiteralPath $StopFile)) {
        $started = [DateTimeOffset]::UtcNow
        $clock = [System.Diagnostics.Stopwatch]::StartNew()
        $record = [ordered]@{ t = $started.ToUnixTimeMilliseconds(); ok = $false; status = $null; ms = $null; who = $null; error = $null }

        try {
            $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, $Url)
            $request.Headers.ConnectionClose = $true
            $response = $client.SendAsync($request).GetAwaiter().GetResult()
            $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            $record.status = [int]$response.StatusCode
            $record.ok = $response.IsSuccessStatusCode
            $record.who = $body.Trim()
            $response.Dispose()
        }
        catch {
            $inner = $_.Exception
            while ($inner.InnerException) { $inner = $inner.InnerException }
            $record.error = $inner.Message
        }

        $record.ms = $clock.ElapsedMilliseconds
        $writer.WriteLine(($record | ConvertTo-Json -Compress))
        $writer.Flush()

        $wait = $IntervalMs - [int]$clock.ElapsedMilliseconds
        if ($wait -gt 0) { Start-Sleep -Milliseconds $wait }
    }
}
finally {
    $writer.Dispose()
    $client.Dispose()
}
