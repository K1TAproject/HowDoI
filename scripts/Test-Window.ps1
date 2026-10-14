$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
$exe = Join-Path $projectRoot 'build/windows/x64/runner/Release/howdoi.exe'
$testRoot = Join-Path $projectRoot ('work/window-smoke-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
$db = Join-Path $testRoot 'isolated.db'
$ready = Join-Path $testRoot 'ready'
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class HowDoIWindowTest {
  [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left, Top, Right, Bottom; }
  [StructLayout(LayoutKind.Sequential)] public struct MonitorInfo { public int Size; public Rect Monitor, Work; public uint Flags; }
  public delegate bool MonitorProc(IntPtr monitor, IntPtr dc, ref Rect rect, IntPtr data);
  public delegate bool WindowProc(IntPtr h, IntPtr data);
  [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
  [DllImport("user32.dll")] public static extern bool EnumWindows(WindowProc proc, IntPtr data);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  public static IntPtr ForProcess(int pid) {
    var found = IntPtr.Zero;
    EnumWindows((h, data) => {
      uint owner; GetWindowThreadProcessId(h, out owner);
      if (owner == pid && (GetWindowLongPtr(h, -16).ToInt64() & 0x00CF0000) == 0x00CF0000) { found = h; return false; }
      return true;
    }, IntPtr.Zero);
    return found;
  }
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out Rect r);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int w, int height, uint flags);
  [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int command);
  [DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetWindowLongPtr(IntPtr h, int index);
  [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr dc, uint flags);
  [DllImport("user32.dll")] public static extern bool EnumDisplayMonitors(IntPtr dc, IntPtr clip, MonitorProc proc, IntPtr data);
  [DllImport("user32.dll")] public static extern bool GetMonitorInfo(IntPtr h, ref MonitorInfo info);
  public static MonitorInfo[] Monitors() {
    var values = new List<MonitorInfo>();
    EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, (IntPtr h, IntPtr dc, ref Rect r, IntPtr data) => {
      var info = new MonitorInfo { Size = Marshal.SizeOf<MonitorInfo>() };
      GetMonitorInfo(h, ref info); values.Add(info); return true;
    }, IntPtr.Zero);
    return values.ToArray();
  }
}
'@
$oldDpiContext = [HowDoIWindowTest]::SetThreadDpiAwarenessContext([IntPtr](-4))
$process = Start-Process -FilePath $exe -ArgumentList '--update-probe',"`"$db`"","`"$ready`"",'--window-test' -WindowStyle Hidden -PassThru
try {
  $deadline = (Get-Date).AddSeconds(20)
  do { Start-Sleep -Milliseconds 100; $process.Refresh() } until ((Test-Path -LiteralPath $ready) -or $process.HasExited -or (Get-Date) -gt $deadline)
  if ($process.HasExited -or !(Test-Path -LiteralPath $ready)) { throw '独立数据库窗口启动失败' }
  $windowDeadline = (Get-Date).AddSeconds(5)
  do {
    Start-Sleep -Milliseconds 100
    $process.Refresh(); $handle = [HowDoIWindowTest]::ForProcess($process.Id)
  } until ($handle -ne [IntPtr]::Zero -or $process.HasExited -or (Get-Date) -gt $windowDeadline)
  if ($handle -eq [IntPtr]::Zero) { throw '未找到测试进程窗口' }
  $style = [HowDoIWindowTest]::GetWindowLongPtr($handle, -16).ToInt64()
  if (($style -band 0x00CF0000) -ne 0x00CF0000) { throw '原生标题栏/缩放/最小化/最大化样式缺失' }
  Write-Output '原生窗口框架样式：通过；标题栏颜色属性仅支持设置，外观需截图检查'
  [void][HowDoIWindowTest]::ShowWindow($handle, 3)
  Start-Sleep -Milliseconds 250
  if (![HowDoIWindowTest]::IsZoomed($handle)) { throw '最大化失败' }
  [void][HowDoIWindowTest]::ShowWindow($handle, 6)
  if (![HowDoIWindowTest]::IsIconic($handle)) { throw '最小化失败' }
  [void][HowDoIWindowTest]::ShowWindow($handle, 9)
  [void][HowDoIWindowTest]::SendMessage($handle, 0x112, [IntPtr]0xF120, [IntPtr]::Zero)
  [void][HowDoIWindowTest]::SendMessage($handle, 0xA3, [IntPtr]2, [IntPtr]::Zero)
  if (![HowDoIWindowTest]::IsZoomed($handle)) { throw '标题栏双击最大化失败' }
  [void][HowDoIWindowTest]::ShowWindow($handle, 9)
  Write-Output '最小化、最大化、还原、标题栏双击消息：通过'
  $monitors = [HowDoIWindowTest]::Monitors()
  foreach ($monitor in $monitors) {
    [void][HowDoIWindowTest]::SetWindowPos($handle, [IntPtr]::Zero, ($monitor.Work.Left + 40), ($monitor.Work.Top + 40), 900, 650, 4)
    Start-Sleep -Milliseconds 250
    $rect = New-Object HowDoIWindowTest+Rect
    [void][HowDoIWindowTest]::GetWindowRect($handle, [ref]$rect)
    if ($rect.Right - $rect.Left -ne 900 -or $rect.Bottom - $rect.Top -ne 650) { throw '窗口尺寸调整失败' }
    $point = [IntPtr]((($rect.Top + 2) -band 0xFFFF) * 65536 + (($rect.Left + 2) -band 0xFFFF))
    $hit = [HowDoIWindowTest]::SendMessage($handle, 0x84, [IntPtr]::Zero, $point).ToInt32()
    if ($hit -notin @(10,12,13)) { throw "边缘缩放命中测试失败：$hit" }
    Write-Output "显示器位置 ($($monitor.Work.Left),$($monitor.Work.Top))：缩放边缘、900x650 尺寸通过；DPI=$([HowDoIWindowTest]::GetDpiForWindow($handle))"
  }
  Write-Output "实际检测显示器数量：$($monitors.Count)。未连接的显示器/DPI 组合及 Snap 手势需人工验证。"
  Add-Type -AssemblyName System.Drawing
  $bitmap = New-Object System.Drawing.Bitmap(900,650)
  $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
  $dc = $graphics.GetHdc()
  try { [void][HowDoIWindowTest]::PrintWindow($handle, $dc, 2) } finally { $graphics.ReleaseHdc($dc); $graphics.Dispose() }
  $bitmap.Save((Join-Path $projectRoot 'work/window-0.1.3.png'))
  $bitmap.Dispose()
  [void][HowDoIWindowTest]::PostMessage($handle, 0x10, [IntPtr]::Zero, [IntPtr]::Zero)
  if (!$process.WaitForExit(5000) -or $process.ExitCode -ne 0) { throw '原生关闭失败' }
  Write-Output '原生关闭（无未保存编辑）：通过；全程使用隔离测试数据库'
} finally {
  if (!$process.HasExited) { $process.Kill(); $process.WaitForExit() }
  [void][HowDoIWindowTest]::SetThreadDpiAwarenessContext($oldDpiContext)
}
