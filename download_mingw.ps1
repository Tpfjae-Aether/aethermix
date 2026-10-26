$url = 'https://github.com/brechtsanders/winlibs_mingw/releases/download/13.2.0-11.0.0-11.0.0-r5/winlibs-x86_64-posix-seh-gcc-13.2.0-mingw-w64ucrt-11.0.0-r5.zip'
$output = "$env:TEMP\mingw.zip"
Invoke-WebRequest -Uri $url -OutFile $output
Expand-Archive -Path $output -DestinationPath 'C:/Aether/mingw'
