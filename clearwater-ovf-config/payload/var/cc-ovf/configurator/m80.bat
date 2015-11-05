@echo off
REM
REM Figure out where I'm located
REM
for %%x in (%0) do set BatchPath=%%~dpsx
for %%x in (%BatchPath%) do set BatchPath=%%~dpsx

SETLOCAL

set PATH=%BatchPath%..\bin.MinGW-all;%PATH%

sh %BatchPath%m80.bash
