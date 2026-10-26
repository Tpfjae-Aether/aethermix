# Get the latest release from the winlibs project
$apiUrl = "https://api.github.com/repos/brechtsanders/winlibs_mingw/releases/latest"
$response = Invoke-RestMethod -Uri $apiUrl -Method Get
$tagName = $response.tag_name
Write-Host "Latest tag: $tagName"
# Construct the download URL for the x86_64-posix-seh variant
$url = "https://github.com/brechtsanders/winlibs_mingw/releases/download/$tagName/winlibs-x86_64-posix-seh-gcc-*-mingw-w64ucrt-*-r*.zip"
# Note: the above URL has wildcards, which won't work. We need to get the actual asset from the release.
# Instead, let's get the assets from the release and find the one we want.
$assets = $response.assets
$asset = $assets | Where-Object { $_.name -like "winlibs-x86_64-posix-seh-*" -and $_.name -like "*.zip" } | Select-Object -First 1
if ($asset) {
    $url = $asset.browser_download_url
    Write-Host "Downloading from: $url"
    $output = "$env:TEMP\mingw.zip"
    Invoke-WebRequest -Uri $url -OutFile $output
    Write-Host "Extracting to C:/Aether/mingw"
    Expand-Archive -Path $output -DestinationPath 'C:/Aether/mingw'
} else {
    Write-Error "Could not find the desired asset."
    exit 1
}
