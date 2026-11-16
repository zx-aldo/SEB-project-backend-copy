using System;
using System.IO;
using System.Management;
using System.Net.NetworkInformation;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Threading;

namespace SebClientPrototype;

// Common schema matching the PDF: event_id, timestamp, session_id, user_id, type, severity + payload
public record SebEvent(
    string event_id,
    string timestamp,
    string session_id,
    string user_id,
    string type,
    string severity,
    object payload
);

public static class Program
{
    private static readonly string SessionId = "test-session-123";
    private static readonly string UserId = Environment.UserName;
    private static readonly string LogFile = "events.jsonl";
    private static readonly object FileLock = new();

    public static void Main()
    {
        Console.WriteLine($"SEB Prototype started. Session: {SessionId}");
        Console.WriteLine($"Logging to: {Path.GetFullPath(LogFile)}");

        using var focusMonitor = new FocusMonitor();
        using var peripheralMonitor = new PeripheralMonitor();
        using var connectivityMonitor = new ConnectivityMonitor();
        using var shortcutMonitor = new ShortcutMonitor();

        Console.WriteLine("Monitors active. Press Enter to exit...");
        Console.ReadLine();
    }

    public static void EmitEvent(string type, string severity, object payload)
    {
        var ev = new SebEvent(
            Guid.NewGuid().ToString(),
            DateTime.UtcNow.ToString("o"),
            SessionId,
            UserId,
            type,
            severity,
            payload
        );
        var json = JsonSerializer.Serialize(ev, new JsonSerializerOptions { WriteIndented = false });
        
        lock (FileLock)
        {
            File.AppendAllText(LogFile, json + Environment.NewLine);
        }
        Console.WriteLine($"[{severity}] {type} -> {json}");
    }
}

// ---------------------------------------------------------------
// 1. Focus Change Monitor using SetWinEventHook
// ---------------------------------------------------------------
public class FocusMonitor : IDisposable
{
    private const uint EVENT_SYSTEM_FOREGROUND = 0x0003;
    private const uint WINEVENT_OUTOFCONTEXT = 0x0000;
    private const int OBJID_WINDOW = 0;
    
    private delegate void WinEventDelegate(IntPtr hWinEventHook, uint eventType,
        IntPtr hwnd, int idObject, int idChild, uint dwEventThread, uint dwmsEventTime);
    
    private static WinEventDelegate? _delegate; 
    private IntPtr _hook;

    public FocusMonitor()
    {
        _delegate = WinEventProc;
        _hook = SetWinEventHook(EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_FOREGROUND,
            IntPtr.Zero, _delegate, 0, 0, WINEVENT_OUTOFCONTEXT);
        if (_hook == IntPtr.Zero) Console.WriteLine("[WARN] Focus hook failed.");
    }

    private static void WinEventProc(IntPtr hWinEventHook, uint eventType,
        IntPtr hwnd, int idObject, int idChild, uint dwEventThread, uint dwmsEventTime)
    {
        Console.WriteLine(">>> RAW EVENT FIRED <<<");
        // Only process the actual main window, not internal elements (like buttons or menus)
        if (idObject != OBJID_WINDOW) return;

        // Get the root ancestor window
        hwnd = GetAncestor(hwnd, 2); 
        var title = GetWindowTitle(hwnd);

        if (!string.IsNullOrWhiteSpace(title))
        {
            Program.EmitEvent("focus_change", "info", new
            {
                previous_state = "", 
                current_state = title,
                duration_ms = 0 
            });
        }
    }

    private static string GetWindowTitle(IntPtr hwnd)
    {
        int length = GetWindowTextLength(hwnd);
        if (length == 0) return "";
        var sb = new StringBuilder(length + 1);
        GetWindowText(hwnd, sb, sb.Capacity);
        return sb.ToString();
    }

    [DllImport("user32.dll")]
    private static extern IntPtr SetWinEventHook(uint eventMin, uint eventMax,
        IntPtr hmodWinEventProc, WinEventDelegate lpfnWinEventProc,
        uint idProcess, uint idThread, uint dwFlags);

    [DllImport("user32.dll")]
    private static extern bool UnhookWinEvent(IntPtr hWinEventHook);

    [DllImport("user32.dll")]
    private static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int count);

    [DllImport("user32.dll")]
    private static extern int GetWindowTextLength(IntPtr hWnd);

    [DllImport("user32.dll")]
    private static extern IntPtr GetAncestor(IntPtr hwnd, uint gaFlags);

    public void Dispose() => UnhookWinEvent(_hook);
}

// ---------------------------------------------------------------
// 2. Peripheral Change Monitor using WMI
// ---------------------------------------------------------------
public class PeripheralMonitor : IDisposable
{
    private readonly ManagementEventWatcher _watcher;

    public PeripheralMonitor()
    {
        var query = new WqlEventQuery("SELECT * FROM Win32_DeviceChangeEvent");
        _watcher = new ManagementEventWatcher(query);
        _watcher.EventArrived += OnDeviceChange;
        _watcher.Start();
    }

    private void OnDeviceChange(object sender, EventArrivedEventArgs e)
    {
        var eventType = e.NewEvent.Properties["EventType"].Value;
        var state = eventType?.ToString() switch
        {
            "2" => "connected",
            "3" => "disconnected",
            _ => "changed"
        };
        Program.EmitEvent("peripheral_change", "suspicious", new
        {
            device_type = "unknown", 
            device_id = "",
            previous_state = "",
            current_state = state,
            required = false,
            permitted = true
        });
    }

    public void Dispose()
    {
        _watcher.Stop();
        _watcher.Dispose();
    }
}

// ---------------------------------------------------------------
// 3. Connectivity Change Monitor using NetworkChange
// ---------------------------------------------------------------
public class ConnectivityMonitor : IDisposable
{
    private string _lastState = "";

    public ConnectivityMonitor()
    {
        NetworkChange.NetworkAvailabilityChanged += OnNetworkAvailabilityChanged;
        NetworkChange.NetworkAddressChanged += OnNetworkAddressChanged;
        _lastState = NetworkInterface.GetIsNetworkAvailable() ? "connected" : "disconnected";
    }

    private void OnNetworkAvailabilityChanged(object? sender, NetworkAvailabilityEventArgs e)
    {
        var current = e.IsAvailable ? "connected" : "disconnected";
        if (current != _lastState)
        {
            Program.EmitEvent("connectivity_change", "warning", new
            {
                previous_state = _lastState,
                current_state = current,
                outage_duration_ms = 0
            });
            _lastState = current;
        }
    }

    private void OnNetworkAddressChanged(object? sender, EventArgs e)
    {
        Program.EmitEvent("network_path_change", "warning", new
        {
            @interface = "",
            interface_type = "",
            local_ip = "",
            gateway = "",
            tunnel_indicator = false,
            permitted = true
        });
    }

    public void Dispose()
    {
        NetworkChange.NetworkAvailabilityChanged -= OnNetworkAvailabilityChanged;
        NetworkChange.NetworkAddressChanged -= OnNetworkAddressChanged;
    }
}

// ---------------------------------------------------------------
// 4. Restricted Shortcut Monitor using SetWindowsHookEx
// ---------------------------------------------------------------
public class ShortcutMonitor : IDisposable
{
    private const int WH_KEYBOARD_LL = 13;
    private const int WM_KEYDOWN = 0x0100;
    private static LowLevelKeyboardProc _proc = HookCallback;
    private static IntPtr _hookID = IntPtr.Zero;

    public ShortcutMonitor()
    {
        _hookID = SetHook(_proc);
    }

    private static IntPtr SetHook(LowLevelKeyboardProc proc)
    {
        using var curProcess = System.Diagnostics.Process.GetCurrentProcess();
        using var curModule = curProcess.MainModule!;
        return SetWindowsHookEx(WH_KEYBOARD_LL, proc,
            GetModuleHandle(curModule.ModuleName), 0);
    }

    private delegate IntPtr LowLevelKeyboardProc(int nCode, IntPtr wParam, IntPtr lParam);

    private static IntPtr HookCallback(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode >= 0 && wParam == (IntPtr)WM_KEYDOWN)
        {
            int vkCode = Marshal.ReadInt32(lParam);
            bool altDown = (GetAsyncKeyState(0x12) & 0x8000) != 0;
            
            // Block Alt+Tab
            if (vkCode == 0x09 && altDown) 
            {
                Program.EmitEvent("restricted_shortcut", "info", new
                {
                    shortcut = "Alt+Tab",
                    operation = "block",
                    blocked = true
                });
                return (IntPtr)1; // Block the key
            }
        }
        return CallNextHookEx(_hookID, nCode, wParam, lParam);
    }

    public void Dispose()
    {
        UnhookWindowsHookEx(_hookID);
    }

    [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    private static extern IntPtr SetWindowsHookEx(int idHook, LowLevelKeyboardProc lpfn,
        IntPtr hMod, uint dwThreadId);

    [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool UnhookWindowsHookEx(IntPtr hhk);

    [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    private static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);

    [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    private static extern IntPtr GetModuleHandle(string lpModuleName);

    [DllImport("user32.dll")]
    private static extern short GetAsyncKeyState(int vKey);
}