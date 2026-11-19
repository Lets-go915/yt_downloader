[Setup]
AppName=YT Downloader
AppVersion=1.0.0
DefaultDirName={autopf}\YT Downloader
DefaultGroupName=YT Downloader
OutputBaseFilename=yt_downloader_setup
Compression=lzma2
SolidCompression=yes
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=Output

[Files]
Source: "build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\YT Downloader"; Filename: "{app}\yt_downloader.exe"
Name: "{autodesktop}\YT Downloader"; Filename: "{app}\yt_downloader.exe"
