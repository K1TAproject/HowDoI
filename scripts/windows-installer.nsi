Unicode true
!include "MUI2.nsh"
!include "x64.nsh"
!include "LogicLib.nsh"
!ifndef INSTALL_KEY
!define INSTALL_KEY "Software\K1TAproject\HowDoI"
!endif
!ifndef UNINSTALL_KEY
!define UNINSTALL_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\HowDoI"
!endif
!ifndef OUTPUT_FILE
!define OUTPUT_FILE "${PROJECT_ROOT}\dist\HowDoI-${VERSION}-windows-x64-setup.exe"
!endif
Var DesktopFolder
Var MenuFolder

Name "HowDoI ${VERSION}"
OutFile "${OUTPUT_FILE}"
InstallDir "$LOCALAPPDATA\Programs\HowDoI"
InstallDirRegKey HKCU "${INSTALL_KEY}" "InstallDir"
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
!ifndef ISOLATED_ROOT
  FindWindow $0 "FLUTTER_RUNNER_WIN32_WINDOW" "howdoi"
  ${If} $0 != 0
    MessageBox MB_OK|MB_ICONEXCLAMATION "请先保存行程并关闭 HowDoI，再运行安装或卸载程序。" /SD IDOK
    SetErrorLevel 2
    Abort
  ${EndIf}
!endif
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
  StrCpy $DesktopFolder "$DESKTOP"
  StrCpy $MenuFolder "$SMPROGRAMS"
!ifdef ISOLATED_ROOT
  StrCpy $DesktopFolder "${ISOLATED_ROOT}\Desktop"
  StrCpy $MenuFolder "${ISOLATED_ROOT}\Programs"
!endif
  SetRegView 64
  Call CheckClosed
FunctionEnd

Function un.onInit
  SetShellVarContext current
  StrCpy $DesktopFolder "$DESKTOP"
  StrCpy $MenuFolder "$SMPROGRAMS"
!ifdef ISOLATED_ROOT
  StrCpy $DesktopFolder "${ISOLATED_ROOT}\Desktop"
  StrCpy $MenuFolder "${ISOLATED_ROOT}\Programs"
!endif
  SetRegView 64
  Call un.CheckClosed
FunctionEnd

Section "HowDoI 程序及开始菜单快捷方式（必需）" SEC_APP
  SectionIn RO
  Call CheckClosed
  ClearErrors
  SetOutPath "$INSTDIR"
  File /r "${RELEASE_DIR}\*.*"
  IfErrors install_failed
  WriteUninstaller "$INSTDIR\Uninstall.exe"
  CreateDirectory "$MenuFolder"
  CreateDirectory "$DesktopFolder"
  CreateShortcut "$MenuFolder\HowDoI.lnk" "$INSTDIR\howdoi.exe"
  WriteRegStr HKCU "${INSTALL_KEY}" "InstallDir" "$INSTDIR"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayName" "HowDoI"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayVersion" "${FULL_VERSION}"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "Publisher" "K1TAproject"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "InstallLocation" "$INSTDIR"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayIcon" "$INSTDIR\howdoi.exe"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "UninstallString" '$\"$INSTDIR\Uninstall.exe$\"'
  WriteRegStr HKCU "${UNINSTALL_KEY}" "QuietUninstallString" '$\"$INSTDIR\Uninstall.exe$\" /S'
  WriteRegDWORD HKCU "${UNINSTALL_KEY}" "NoModify" 1
  WriteRegDWORD HKCU "${UNINSTALL_KEY}" "NoRepair" 1
  IfErrors install_failed
  Goto install_done
install_failed:
  SetErrorLevel 1
  Abort "安装文件或快捷方式写入失败"
install_done:
SectionEnd

Section "创建桌面快捷方式" SEC_DESKTOP
  ClearErrors
  CreateShortcut "$DesktopFolder\HowDoI.lnk" "$INSTDIR\howdoi.exe"
  ${If} ${Errors}
    SetErrorLevel 1
    Abort "桌面快捷方式写入失败"
  ${EndIf}
SectionEnd

Section "Uninstall"
  Call un.CheckClosed
  ; Generated exact file list: never recursively delete a user-selected directory.
  !include "${UNINSTALL_FILES}"
  Delete "$INSTDIR\Uninstall.exe"
  RMDir "$INSTDIR"
  Delete "$MenuFolder\HowDoI.lnk"
  Delete "$DesktopFolder\HowDoI.lnk"
  DeleteRegKey HKCU "${UNINSTALL_KEY}"
  DeleteRegKey HKCU "${INSTALL_KEY}"
SectionEnd

Function .onInstFailed
  SetErrorLevel 1
FunctionEnd
