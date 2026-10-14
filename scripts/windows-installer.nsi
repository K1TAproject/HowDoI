Unicode true
!include "MUI2.nsh"
!include "x64.nsh"
!include "LogicLib.nsh"

Name "HowDoI ${VERSION}"
OutFile "${PROJECT_ROOT}\dist\HowDoI-${VERSION}-windows-x64-setup.exe"
InstallDir "$LOCALAPPDATA\Programs\HowDoI"
InstallDirRegKey HKCU "Software\K1TAproject\HowDoI" "InstallDir"
RequestExecutionLevel user
SetCompressor /SOLID lzma
ShowInstDetails show
ShowUninstDetails show
VIProductVersion "${NUMERIC_VERSION}"
VIAddVersionKey "ProductName" "HowDoI"
VIAddVersionKey "FileDescription" "HowDoI Windows 安装程序"
VIAddVersionKey "FileVersion" "${FULL_VERSION}"
VIAddVersionKey "ProductVersion" "${FULL_VERSION}"
VIAddVersionKey "LegalCopyright" "K1TAproject"
!define MUI_ICON "${PROJECT_ROOT}\windows\runner\resources\app_icon.ico"
!define MUI_UNICON "${PROJECT_ROOT}\windows\runner\resources\app_icon.ico"
!define MUI_ABORTWARNING
!define MUI_WELCOMEPAGE_TEXT "安装 HowDoI ${VERSION} 旅行路书。$\r$\n$\r$\n程序安装到当前用户目录，无需管理员权限。安装和卸载均保留现有旅行数据。$\r$\n$\r$\n继续前请关闭正在运行的 HowDoI。"
!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_COMPONENTS
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!define MUI_FINISHPAGE_RUN "$INSTDIR\howdoi.exe"
!define MUI_FINISHPAGE_RUN_NOTCHECKED
!insertmacro MUI_PAGE_FINISH
!define MUI_UNCONFIRMPAGE_TEXT_TOP "卸载 HowDoI 程序和本安装包创建的快捷方式。旅行数据、备份及应用内下载的版本会保留。"
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "SimpChinese"

!macro RequireClosed PREFIX
Function ${PREFIX}CheckClosed
  FindWindow $0 "FLUTTER_RUNNER_WIN32_WINDOW" "howdoi"
  ${If} $0 != 0
    MessageBox MB_OK|MB_ICONEXCLAMATION "请先保存行程并关闭 HowDoI，再运行安装或卸载程序。" /SD IDOK
    SetErrorLevel 2
    Abort
  ${EndIf}
FunctionEnd
!macroend
!insertmacro RequireClosed ""
!insertmacro RequireClosed "un."

Function .onInit
  ${IfNot} ${RunningX64}
    MessageBox MB_OK|MB_ICONSTOP "此安装包需要 64 位 Windows。" /SD IDOK
    SetErrorLevel 2
    Abort
  ${EndIf}
  SetShellVarContext current
  SetRegView 64
  Call CheckClosed
FunctionEnd

Function un.onInit
  SetShellVarContext current
  SetRegView 64
  Call un.CheckClosed
FunctionEnd

Section "HowDoI 程序及开始菜单快捷方式（必需）" SEC_APP
  SectionIn RO
  Call CheckClosed
  SetOutPath "$INSTDIR"
  File /r "${RELEASE_DIR}\*.*"
  WriteUninstaller "$INSTDIR\Uninstall.exe"
  CreateShortcut "$SMPROGRAMS\HowDoI.lnk" "$INSTDIR\howdoi.exe"
  WriteRegStr HKCU "Software\K1TAproject\HowDoI" "InstallDir" "$INSTDIR"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\HowDoI" "DisplayName" "HowDoI"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\HowDoI" "DisplayVersion" "${FULL_VERSION}"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\HowDoI" "Publisher" "K1TAproject"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\HowDoI" "InstallLocation" "$INSTDIR"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\HowDoI" "DisplayIcon" "$INSTDIR\howdoi.exe"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\HowDoI" "UninstallString" '$\"$INSTDIR\Uninstall.exe$\"'
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\HowDoI" "QuietUninstallString" '$\"$INSTDIR\Uninstall.exe$\" /S'
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\HowDoI" "NoModify" 1
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\HowDoI" "NoRepair" 1
SectionEnd

Section "创建桌面快捷方式" SEC_DESKTOP
  CreateShortcut "$DESKTOP\HowDoI.lnk" "$INSTDIR\howdoi.exe"
SectionEnd

Section "Uninstall"
  Call un.CheckClosed
  ; Generated exact file list: never recursively delete a user-selected directory.
  !include "${UNINSTALL_FILES}"
  Delete "$INSTDIR\Uninstall.exe"
  RMDir "$INSTDIR"
  Delete "$SMPROGRAMS\HowDoI.lnk"
  Delete "$DESKTOP\HowDoI.lnk"
  DeleteRegKey HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\HowDoI"
  DeleteRegKey HKCU "Software\K1TAproject\HowDoI"
SectionEnd
