@echo off
setlocal
set BASE=http://127.0.0.1:3690
if "%1"=="" goto state
if /i "%1"=="state" goto state
if /i "%1"=="play" (curl -s %BASE%/play?id=%2 & goto eof)
if /i "%1"=="pause" (curl -s %BASE%/pause & goto eof)
if /i "%1"=="resume" (curl -s %BASE%/resume & goto eof)
if /i "%1"=="toggle" (curl -s %BASE%/toggle & goto eof)
if /i "%1"=="next" (curl -s %BASE%/next & goto eof)
if /i "%1"=="prev" (curl -s %BASE%/prev & goto eof)
if /i "%1"=="seek" (curl -s %BASE%/seek?ms=%2 & goto eof)
if /i "%1"=="volume" (curl -s %BASE%/volume?v=%2 & goto eof)
if /i "%1"=="theme" (curl -s %BASE%/theme?name=%2 >nul & echo theme set: %2 & goto eof)
if /i "%1"=="themes" (curl -s %BASE%/themes & goto eof)
if /i "%1"=="library" (curl -s %BASE%/library & goto eof)
if /i "%1"=="queue" (curl -s %BASE%/queue & goto eof)
if /i "%1"=="lyrics" (curl -s %BASE%/lyrics?id=%2 & goto eof)
if /i "%1"=="rescan" (curl -s %BASE%/rescan & goto eof)
if /i "%1"=="extensions" (curl -s %BASE%/extensions & goto eof)
if /i "%1"=="oauth" (curl -s %BASE%/oauth/start & goto eof)
if /i "%1"=="streaming" (curl -s %BASE%/state & goto eof)
if /i "%1"=="np" (type "%~dp0now_playing.json" & goto eof)
echo aether ^<command^> - control the sovereign player
echo   state | np        playback snapshot
echo   play ^<id^>         play a track id
echo   pause | resume | toggle | next | prev
echo   seek ^<ms^>         seek to position
echo   volume ^<0-100^>    set volume
echo   theme ^<name^>       apply a theme
echo   themes | library | queue | extensions
echo   lyrics ^<id^>       lyrics for a track
echo   rescan             re-scan music folders
goto eof
:state
curl -s %BASE%/state
:eof
echo.
