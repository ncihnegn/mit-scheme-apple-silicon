// Derived from MIT/GNU Scheme C sources (`src/microcode/prims.h`, `src/microcode/ux*.c`)
// and Microsoft Win32 / Winsock2 / MinGW-w64 ABI specifications:
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");
const abi = @import("prim_abi.zig");

pub const HANDLE = *anyopaque;
pub const INVALID_HANDLE_VALUE: HANDLE = @ptrFromInt(std.math.maxInt(usize));
pub const HMODULE = *anyopaque;
pub const SOCKET = usize;
pub const INVALID_SOCKET: SOCKET = std.math.maxInt(usize);
pub const DWORD = u32;
pub const WORD = u16;
pub const BOOL = c_int;
pub const LONG = c_long;
pub const ULONG = c_ulong;
pub const NTSTATUS = i32;

pub const STD_INPUT_HANDLE: DWORD = @bitCast(@as(i32, -10));
pub const STD_OUTPUT_HANDLE: DWORD = @bitCast(@as(i32, -11));
pub const STD_ERROR_HANDLE: DWORD = @bitCast(@as(i32, -12));

pub const MEM_COMMIT: DWORD = 0x1000;
pub const MEM_RESERVE: DWORD = 0x2000;
pub const MEM_RELEASE: DWORD = 0x8000;
pub const PAGE_READWRITE: DWORD = 0x04;
pub const PAGE_EXECUTE_READWRITE: DWORD = 0x40;

pub const GENERIC_READ: DWORD = 0x80000000;
pub const GENERIC_WRITE: DWORD = 0x40000000;
pub const FILE_APPEND_DATA: DWORD = 0x00000004;
pub const FILE_WRITE_ATTRIBUTES: DWORD = 0x00000100;
pub const FILE_SHARE_READ: DWORD = 0x00000001;
pub const FILE_SHARE_WRITE: DWORD = 0x00000002;
pub const FILE_SHARE_DELETE: DWORD = 0x00000004;

pub const CREATE_NEW: DWORD = 1;
pub const CREATE_ALWAYS: DWORD = 2;
pub const OPEN_EXISTING: DWORD = 3;
pub const OPEN_ALWAYS: DWORD = 4;
pub const TRUNCATE_EXISTING: DWORD = 5;

pub const FILE_ATTRIBUTE_READONLY: DWORD = 0x00000001;
pub const FILE_ATTRIBUTE_DIRECTORY: DWORD = 0x00000010;
pub const FILE_ATTRIBUTE_NORMAL: DWORD = 0x00000080;
pub const FILE_ATTRIBUTE_REPARSE_POINT: DWORD = 0x00000400;
pub const INVALID_FILE_ATTRIBUTES: DWORD = 0xFFFFFFFF;
pub const FILE_FLAG_BACKUP_SEMANTICS: DWORD = 0x02000000;
pub const FILE_FLAG_OPEN_REPARSE_POINT: DWORD = 0x00200000;

pub const FILE_BEGIN: DWORD = 0;
pub const FILE_CURRENT: DWORD = 1;
pub const FILE_END: DWORD = 2;

pub const FILE_TYPE_UNKNOWN: DWORD = 0;
pub const FILE_TYPE_DISK: DWORD = 1;
pub const FILE_TYPE_CHAR: DWORD = 2;
pub const FILE_TYPE_PIPE: DWORD = 3;

pub const MOVEFILE_REPLACE_EXISTING: DWORD = 0x1;
pub const SYMBOLIC_LINK_FLAG_DIRECTORY: DWORD = 0x1;
pub const SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE: DWORD = 0x2;

pub const ENABLE_PROCESSED_INPUT: DWORD = 0x0001;
pub const ENABLE_LINE_INPUT: DWORD = 0x0002;
pub const ENABLE_ECHO_INPUT: DWORD = 0x0004;
pub const ENABLE_PROCESSED_OUTPUT: DWORD = 0x0001;
pub const ENABLE_VIRTUAL_TERMINAL_PROCESSING: DWORD = 0x0004;

pub const CTRL_C_EVENT: DWORD = 0;
pub const CTRL_BREAK_EVENT: DWORD = 1;

pub const WAIT_OBJECT_0: DWORD = 0x00000000;
pub const WAIT_TIMEOUT: DWORD = 0x00000102;
pub const WAIT_FAILED: DWORD = 0xFFFFFFFF;
pub const INFINITE: DWORD = 0xFFFFFFFF;
pub const STILL_ACTIVE: DWORD = 259;

pub const STARTF_USESTDHANDLES: DWORD = 0x00000100;
pub const CREATE_NEW_PROCESS_GROUP: DWORD = 0x00000200;
pub const DUPLICATE_SAME_ACCESS: DWORD = 0x00000002;

pub const BCRYPT_USE_SYSTEM_PREFERRED_RNG: ULONG = 0x00000002;

pub const AF_INET: c_int = 2;
pub const SOCK_STREAM: c_int = 1;
pub const IPPROTO_TCP: c_int = 6;
pub const SOL_SOCKET: c_int = 0xFFFF;
pub const SO_REUSEADDR: c_int = 0x0004;
pub const FIONBIO: c_long = @bitCast(@as(u32, 0x8004667E));
pub const SD_RECEIVE: c_int = 0;
pub const SD_SEND: c_int = 1;
pub const SD_BOTH: c_int = 2;
pub const POLLRDNORM: i16 = 0x0100;
pub const POLLWRNORM: i16 = 0x0010;
pub const POLLERR: i16 = 0x0001;
pub const POLLHUP: i16 = 0x0002;
pub const POLLNVAL: i16 = 0x0004;
pub const SOCKET_ERROR: c_int = -1;

pub const ComputerNameDnsHostname: c_uint = 1;
pub const ComputerNameDnsFullyQualified: c_uint = 3;

pub const EXCEPTION_CONTINUE_SEARCH: c_long = 0;
pub const EXCEPTION_ACCESS_VIOLATION: DWORD = 0xC0000005;
pub const EXCEPTION_ILLEGAL_INSTRUCTION: DWORD = 0xC000001D;
pub const EXCEPTION_INT_DIVIDE_BY_ZERO: DWORD = 0xC0000094;
pub const EXCEPTION_STACK_OVERFLOW: DWORD = 0xC00000FD;

pub const FILETIME = extern struct {
    dwLowDateTime: DWORD,
    dwHighDateTime: DWORD,
};

pub const SYSTEM_INFO = extern struct {
    dwOemId: DWORD,
    dwPageSize: DWORD,
    lpMinimumApplicationAddress: ?*anyopaque,
    lpMaximumApplicationAddress: ?*anyopaque,
    dwActiveProcessorMask: usize,
    dwNumberOfProcessors: DWORD,
    dwProcessorType: DWORD,
    dwAllocationGranularity: DWORD,
    wProcessorLevel: WORD,
    wProcessorRevision: WORD,
};

pub const WIN32_FILE_ATTRIBUTE_DATA = extern struct {
    dwFileAttributes: DWORD,
    ftCreationTime: FILETIME,
    ftLastAccessTime: FILETIME,
    ftLastWriteTime: FILETIME,
    nFileSizeHigh: DWORD,
    nFileSizeLow: DWORD,
};

pub const BY_HANDLE_FILE_INFORMATION = extern struct {
    dwFileAttributes: DWORD,
    ftCreationTime: FILETIME,
    ftLastAccessTime: FILETIME,
    ftLastWriteTime: FILETIME,
    dwVolumeSerialNumber: DWORD,
    nFileSizeHigh: DWORD,
    nFileSizeLow: DWORD,
    nNumberOfLinks: DWORD,
    nFileIndexHigh: DWORD,
    nFileIndexLow: DWORD,
};

pub const WIN32_FIND_DATAA = extern struct {
    dwFileAttributes: DWORD,
    ftCreationTime: FILETIME,
    ftLastAccessTime: FILETIME,
    ftLastWriteTime: FILETIME,
    nFileSizeHigh: DWORD,
    nFileSizeLow: DWORD,
    dwReserved0: DWORD,
    dwReserved1: DWORD,
    cFileName: [260]u8,
    cAlternateFileName: [14]u8,
};

pub const COORD = extern struct {
    X: i16,
    Y: i16,
};

pub const SMALL_RECT = extern struct {
    Left: i16,
    Top: i16,
    Right: i16,
    Bottom: i16,
};

pub const CONSOLE_SCREEN_BUFFER_INFO = extern struct {
    dwSize: COORD,
    dwCursorPosition: COORD,
    wAttributes: WORD,
    srWindow: SMALL_RECT,
    dwMaximumWindowSize: COORD,
};

pub const SECURITY_ATTRIBUTES = extern struct {
    nLength: DWORD,
    lpSecurityDescriptor: ?*anyopaque,
    bInheritHandle: BOOL,
};

pub const STARTUPINFOA = extern struct {
    cb: DWORD,
    lpReserved: ?[*:0]u8,
    lpDesktop: ?[*:0]u8,
    lpTitle: ?[*:0]u8,
    dwX: DWORD,
    dwY: DWORD,
    dwXSize: DWORD,
    dwYSize: DWORD,
    dwXCountChars: DWORD,
    dwYCountChars: DWORD,
    dwFillAttribute: DWORD,
    dwFlags: DWORD,
    wShowWindow: WORD,
    cbReserved2: WORD,
    lpReserved2: ?[*]u8,
    hStdInput: ?HANDLE,
    hStdOutput: ?HANDLE,
    hStdError: ?HANDLE,
};

pub const PROCESS_INFORMATION = extern struct {
    hProcess: ?HANDLE,
    hThread: ?HANDLE,
    dwProcessId: DWORD,
    dwThreadId: DWORD,
};

pub const WSADATA = extern struct {
    wVersion: WORD,
    wHighVersion: WORD,
    iMaxSockets: u16,
    iMaxUdpDg: u16,
    lpVendorInfo: ?[*]u8,
    szDescription: [257]u8,
    szSystemStatus: [129]u8,
};

pub const WSAPOLLFD = extern struct {
    fd: SOCKET,
    events: i16,
    revents: i16,
};

pub const SockAddrIn = extern struct {
    sin_family: u16,
    sin_port: u16,
    sin_addr: [4]u8,
    sin_zero: [8]u8,
};

pub const Hostent = extern struct {
    h_name: ?[*:0]u8,
    h_aliases: ?[*]?[*:0]u8,
    h_addrtype: i16,
    h_length: i16,
    h_addr_list: ?[*]?[*]u8,
};

pub const Servent = extern struct {
    s_name: ?[*:0]u8,
    s_aliases: ?[*]?[*:0]u8,
    s_proto: ?[*:0]u8,
    s_port: i16,
};

pub const EXCEPTION_RECORD = extern struct {
    ExceptionCode: DWORD,
    ExceptionFlags: DWORD,
    ExceptionRecord: ?*EXCEPTION_RECORD,
    ExceptionAddress: ?*anyopaque,
    NumberParameters: DWORD,
    ExceptionInformation: [15]usize,
};

pub const EXCEPTION_POINTERS = extern struct {
    ExceptionRecord: *EXCEPTION_RECORD,
    ContextRecord: ?*anyopaque,
};

pub const PHANDLER_ROUTINE = *const fn (DWORD) callconv(.winapi) BOOL;
pub const PVECTORED_EXCEPTION_HANDLER = *const fn (*EXCEPTION_POINTERS) callconv(.winapi) c_long;
pub const WAITORTIMERCALLBACK = *const fn (?*anyopaque, u8) callconv(.winapi) void;

pub const kernel32 = struct {
    pub extern "kernel32" fn GetLastError() callconv(.winapi) DWORD;
    pub extern "kernel32" fn GetSystemInfo(lpSystemInfo: *SYSTEM_INFO) callconv(.winapi) void;
    pub extern "kernel32" fn VirtualAlloc(lpAddress: ?*anyopaque, dwSize: usize, flAllocationType: DWORD, flProtect: DWORD) callconv(.winapi) ?*anyopaque;
    pub extern "kernel32" fn VirtualFree(lpAddress: ?*anyopaque, dwSize: usize, dwFreeType: DWORD) callconv(.winapi) BOOL;
    pub extern "kernel32" fn GetCurrentProcess() callconv(.winapi) HANDLE;
    pub extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) DWORD;
    pub extern "kernel32" fn FlushInstructionCache(hProcess: HANDLE, lpBaseAddress: ?*const anyopaque, dwSize: usize) callconv(.winapi) BOOL;
    pub extern "kernel32" fn GetStdHandle(nStdHandle: DWORD) callconv(.winapi) ?HANDLE;
    pub extern "kernel32" fn GetFileType(hFile: HANDLE) callconv(.winapi) DWORD;
    pub extern "kernel32" fn CreateFileA(
        lpFileName: [*:0]const u8,
        dwDesiredAccess: DWORD,
        dwShareMode: DWORD,
        lpSecurityAttributes: ?*SECURITY_ATTRIBUTES,
        dwCreationDisposition: DWORD,
        dwFlagsAndAttributes: DWORD,
        hTemplateFile: ?HANDLE,
    ) callconv(.winapi) HANDLE;
    pub extern "kernel32" fn ReadFile(hFile: HANDLE, lpBuffer: ?*anyopaque, nNumberOfBytesToRead: DWORD, lpNumberOfBytesRead: ?*DWORD, lpOverlapped: ?*anyopaque) callconv(.winapi) BOOL;
    pub extern "kernel32" fn WriteFile(hFile: HANDLE, lpBuffer: ?*const anyopaque, nNumberOfBytesToWrite: DWORD, lpNumberOfBytesWritten: ?*DWORD, lpOverlapped: ?*anyopaque) callconv(.winapi) BOOL;
    pub extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.winapi) BOOL;
    pub extern "kernel32" fn FlushFileBuffers(hFile: HANDLE) callconv(.winapi) BOOL;
    pub extern "kernel32" fn GetFileSizeEx(hFile: HANDLE, lpFileSize: *i64) callconv(.winapi) BOOL;
    pub extern "kernel32" fn SetFilePointerEx(hFile: HANDLE, liDistanceToMove: i64, lpNewFilePointer: ?*i64, dwMoveMethod: DWORD) callconv(.winapi) BOOL;
    pub extern "kernel32" fn SetEndOfFile(hFile: HANDLE) callconv(.winapi) BOOL;
    pub extern "kernel32" fn GetFileAttributesA(lpFileName: [*:0]const u8) callconv(.winapi) DWORD;
    pub extern "kernel32" fn SetFileAttributesA(lpFileName: [*:0]const u8, dwFileAttributes: DWORD) callconv(.winapi) BOOL;
    pub extern "kernel32" fn GetFileAttributesExA(lpFileName: [*:0]const u8, fInfoLevelId: c_uint, lpFileInformation: *WIN32_FILE_ATTRIBUTE_DATA) callconv(.winapi) BOOL;
    pub extern "kernel32" fn GetFileInformationByHandle(hFile: HANDLE, lpFileInformation: *BY_HANDLE_FILE_INFORMATION) callconv(.winapi) BOOL;
    pub extern "kernel32" fn GetFinalPathNameByHandleA(hFile: HANDLE, lpszFilePath: [*]u8, cchFilePath: DWORD, dwFlags: DWORD) callconv(.winapi) DWORD;
    pub extern "kernel32" fn SetFileTime(hFile: HANDLE, lpCreationTime: ?*const FILETIME, lpLastAccessTime: ?*const FILETIME, lpLastWriteTime: ?*const FILETIME) callconv(.winapi) BOOL;
    pub extern "kernel32" fn DeleteFileA(lpFileName: [*:0]const u8) callconv(.winapi) BOOL;
    pub extern "kernel32" fn MoveFileExA(lpExistingFileName: [*:0]const u8, lpNewFileName: [*:0]const u8, dwFlags: DWORD) callconv(.winapi) BOOL;
    pub extern "kernel32" fn CopyFileA(lpExistingFileName: [*:0]const u8, lpNewFileName: [*:0]const u8, bFailIfExists: BOOL) callconv(.winapi) BOOL;
    pub extern "kernel32" fn CreateHardLinkA(lpFileName: [*:0]const u8, lpExistingFileName: [*:0]const u8, lpSecurityAttributes: ?*anyopaque) callconv(.winapi) BOOL;
    pub extern "kernel32" fn CreateSymbolicLinkA(lpSymlinkFileName: [*:0]const u8, lpTargetFileName: [*:0]const u8, dwFlags: DWORD) callconv(.winapi) u8;
    pub extern "kernel32" fn CreateDirectoryA(lpPathName: [*:0]const u8, lpSecurityAttributes: ?*anyopaque) callconv(.winapi) BOOL;
    pub extern "kernel32" fn RemoveDirectoryA(lpPathName: [*:0]const u8) callconv(.winapi) BOOL;
    pub extern "kernel32" fn FindFirstFileA(lpFileName: [*:0]const u8, lpFindFileData: *WIN32_FIND_DATAA) callconv(.winapi) HANDLE;
    pub extern "kernel32" fn FindNextFileA(hFindFile: HANDLE, lpFindFileData: *WIN32_FIND_DATAA) callconv(.winapi) BOOL;
    pub extern "kernel32" fn FindClose(hFindFile: HANDLE) callconv(.winapi) BOOL;
    pub extern "kernel32" fn GetVolumeInformationA(
        lpRootPathName: ?[*:0]const u8,
        lpVolumeNameBuffer: ?[*]u8,
        nVolumeNameSize: DWORD,
        lpVolumeSerialNumber: ?*DWORD,
        lpMaximumComponentLength: ?*DWORD,
        lpFileSystemFlags: ?*DWORD,
        lpFileSystemNameBuffer: ?[*]u8,
        nFileSystemNameSize: DWORD,
    ) callconv(.winapi) BOOL;
    pub extern "kernel32" fn GetCurrentDirectoryA(nBufferLength: DWORD, lpBuffer: [*]u8) callconv(.winapi) DWORD;
    pub extern "kernel32" fn SetCurrentDirectoryA(lpPathName: [*:0]const u8) callconv(.winapi) BOOL;
    pub extern "kernel32" fn GetSystemTimeAsFileTime(lpSystemTimeAsFileTime: *FILETIME) callconv(.winapi) void;
    pub extern "kernel32" fn GetSystemTimePreciseAsFileTime(lpSystemTimeAsFileTime: *FILETIME) callconv(.winapi) void;
    pub extern "kernel32" fn QueryPerformanceCounter(lpPerformanceCount: *i64) callconv(.winapi) BOOL;
    pub extern "kernel32" fn QueryPerformanceFrequency(lpFrequency: *i64) callconv(.winapi) BOOL;
    pub extern "kernel32" fn GetProcessTimes(hProcess: HANDLE, lpCreationTime: *FILETIME, lpExitTime: *FILETIME, lpKernelTime: *FILETIME, lpUserTime: *FILETIME) callconv(.winapi) BOOL;
    pub extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
    pub extern "kernel32" fn Sleep(dwMilliseconds: DWORD) callconv(.winapi) void;
    pub extern "kernel32" fn CreatePipe(hReadPipe: *HANDLE, hWritePipe: *HANDLE, lpPipeAttributes: ?*SECURITY_ATTRIBUTES, nSize: DWORD) callconv(.winapi) BOOL;
    pub extern "kernel32" fn PeekNamedPipe(
        hNamedPipe: HANDLE,
        lpBuffer: ?*anyopaque,
        nBufferSize: DWORD,
        lpBytesRead: ?*DWORD,
        lpTotalBytesAvail: ?*DWORD,
        lpBytesLeftThisMessage: ?*DWORD,
    ) callconv(.winapi) BOOL;
    pub extern "kernel32" fn DuplicateHandle(
        hSourceProcessHandle: HANDLE,
        hSourceHandle: HANDLE,
        hTargetProcessHandle: HANDLE,
        lpTargetHandle: *HANDLE,
        dwDesiredAccess: DWORD,
        bInheritHandle: BOOL,
        dwOptions: DWORD,
    ) callconv(.winapi) BOOL;
    pub extern "kernel32" fn CreateProcessA(
        lpApplicationName: ?[*:0]const u8,
        lpCommandLine: ?[*:0]u8,
        lpProcessAttributes: ?*SECURITY_ATTRIBUTES,
        lpThreadAttributes: ?*SECURITY_ATTRIBUTES,
        bInheritHandles: BOOL,
        dwCreationFlags: DWORD,
        lpEnvironment: ?*anyopaque,
        lpCurrentDirectory: ?[*:0]const u8,
        lpStartupInfo: *STARTUPINFOA,
        lpProcessInformation: *PROCESS_INFORMATION,
    ) callconv(.winapi) BOOL;
    pub extern "kernel32" fn WaitForSingleObject(hHandle: HANDLE, dwMilliseconds: DWORD) callconv(.winapi) DWORD;
    pub extern "kernel32" fn GetExitCodeProcess(hProcess: HANDLE, lpExitCode: *DWORD) callconv(.winapi) BOOL;
    pub extern "kernel32" fn TerminateProcess(hProcess: HANDLE, uExitCode: c_uint) callconv(.winapi) BOOL;
    pub extern "kernel32" fn GenerateConsoleCtrlEvent(dwCtrlEvent: DWORD, dwProcessGroupId: DWORD) callconv(.winapi) BOOL;
    pub extern "kernel32" fn GetConsoleMode(hConsoleHandle: HANDLE, lpMode: *DWORD) callconv(.winapi) BOOL;
    pub extern "kernel32" fn SetConsoleMode(hConsoleHandle: HANDLE, dwMode: DWORD) callconv(.winapi) BOOL;
    pub extern "kernel32" fn GetConsoleScreenBufferInfo(hConsoleOutput: HANDLE, lpConsoleScreenBufferInfo: *CONSOLE_SCREEN_BUFFER_INFO) callconv(.winapi) BOOL;
    pub extern "kernel32" fn FlushConsoleInputBuffer(hConsoleInput: HANDLE) callconv(.winapi) BOOL;
    pub extern "kernel32" fn GetNumberOfConsoleInputEvents(hConsoleInput: HANDLE, lpcNumberOfEvents: *DWORD) callconv(.winapi) BOOL;
    pub extern "kernel32" fn SetConsoleCtrlHandler(HandlerRoutine: ?PHANDLER_ROUTINE, Add: BOOL) callconv(.winapi) BOOL;
    pub extern "kernel32" fn GetComputerNameA(lpBuffer: [*]u8, nSize: *DWORD) callconv(.winapi) BOOL;
    pub extern "kernel32" fn GetComputerNameExA(NameType: c_uint, lpBuffer: [*]u8, nSize: *DWORD) callconv(.winapi) BOOL;
    pub extern "kernel32" fn GetEnvironmentStringsA() callconv(.winapi) ?[*]u8;
    pub extern "kernel32" fn FreeEnvironmentStringsA(penv: [*]u8) callconv(.winapi) BOOL;
    pub extern "kernel32" fn LoadLibraryA(lpLibFileName: [*:0]const u8) callconv(.winapi) ?HMODULE;
    pub extern "kernel32" fn GetModuleHandleA(lpModuleName: ?[*:0]const u8) callconv(.winapi) ?HMODULE;
    pub extern "kernel32" fn GetProcAddress(hModule: HMODULE, lpProcName: [*:0]const u8) callconv(.winapi) ?*anyopaque;
    pub extern "kernel32" fn FreeLibrary(hLibModule: HMODULE) callconv(.winapi) BOOL;
    pub extern "kernel32" fn CreateTimerQueueTimer(
        phNewTimer: *?HANDLE,
        TimerQueue: ?HANDLE,
        Callback: WAITORTIMERCALLBACK,
        Parameter: ?*anyopaque,
        DueTime: DWORD,
        Period: DWORD,
        Flags: ULONG,
    ) callconv(.winapi) BOOL;
    pub extern "kernel32" fn DeleteTimerQueueTimer(TimerQueue: ?HANDLE, Timer: HANDLE, CompletionEvent: ?HANDLE) callconv(.winapi) BOOL;
    pub extern "kernel32" fn AddVectoredExceptionHandler(First: ULONG, Handler: PVECTORED_EXCEPTION_HANDLER) callconv(.winapi) ?*anyopaque;
};

pub const advapi32 = struct {
    pub extern "advapi32" fn GetUserNameA(lpBuffer: [*]u8, pcbBuffer: *DWORD) callconv(.winapi) BOOL;
};

pub const bcrypt = struct {
    pub extern "bcrypt" fn BCryptGenRandom(hAlgorithm: ?*anyopaque, pbBuffer: [*]u8, cbBuffer: ULONG, dwFlags: ULONG) callconv(.winapi) NTSTATUS;
};

pub const ws2_32 = struct {
    pub extern "ws2_32" fn WSAStartup(wVersionRequested: WORD, lpWSAData: *WSADATA) callconv(.winapi) c_int;
    pub extern "ws2_32" fn WSACleanup() callconv(.winapi) c_int;
    pub extern "ws2_32" fn WSAGetLastError() callconv(.winapi) c_int;
    pub extern "ws2_32" fn socket(af: c_int, sock_type: c_int, protocol: c_int) callconv(.winapi) SOCKET;
    pub extern "ws2_32" fn closesocket(s: SOCKET) callconv(.winapi) c_int;
    pub extern "ws2_32" fn connect(s: SOCKET, name: *const anyopaque, namelen: c_int) callconv(.winapi) c_int;
    pub extern "ws2_32" fn bind(s: SOCKET, name: *const anyopaque, namelen: c_int) callconv(.winapi) c_int;
    pub extern "ws2_32" fn listen(s: SOCKET, backlog: c_int) callconv(.winapi) c_int;
    pub extern "ws2_32" fn accept(s: SOCKET, addr: ?*anyopaque, addrlen: ?*c_int) callconv(.winapi) SOCKET;
    pub extern "ws2_32" fn shutdown(s: SOCKET, how: c_int) callconv(.winapi) c_int;
    pub extern "ws2_32" fn recv(s: SOCKET, buf: [*]u8, len: c_int, flags: c_int) callconv(.winapi) c_int;
    pub extern "ws2_32" fn send(s: SOCKET, buf: [*]const u8, len: c_int, flags: c_int) callconv(.winapi) c_int;
    pub extern "ws2_32" fn setsockopt(s: SOCKET, level: c_int, optname: c_int, optval: ?*const anyopaque, optlen: c_int) callconv(.winapi) c_int;
    pub extern "ws2_32" fn ioctlsocket(s: SOCKET, cmd: c_long, argp: *c_ulong) callconv(.winapi) c_int;
    pub extern "ws2_32" fn WSAPoll(fdArray: [*]WSAPOLLFD, fds: ULONG, timeout: c_int) callconv(.winapi) c_int;
    pub extern "ws2_32" fn gethostname(name: [*]u8, namelen: c_int) callconv(.winapi) c_int;
    pub extern "ws2_32" fn gethostbyname(name: [*:0]const u8) callconv(.winapi) ?*Hostent;
    pub extern "ws2_32" fn gethostbyaddr(addr: [*]const u8, len: c_int, addr_type: c_int) callconv(.winapi) ?*Hostent;
    pub extern "ws2_32" fn getservbyname(name: [*:0]const u8, proto: [*:0]const u8) callconv(.winapi) ?*Servent;
    pub extern "ws2_32" fn htons(hostshort: u16) callconv(.winapi) u16;
};

pub const windows_epoch_offset_sec: i64 = 11_644_473_600;
const ticks_per_sec: i128 = 10_000_000;

pub fn filetimeToUnixNanotime(ft: FILETIME) abi.SchemeNanotime {
    const ticks: u64 = (@as(u64, ft.dwHighDateTime) << 32) | @as(u64, ft.dwLowDateTime);
    const offset_ticks: i128 = @as(i128, windows_epoch_offset_sec) * ticks_per_sec;
    const delta_ticks: i128 = @as(i128, ticks) - offset_ticks;
    const sec: i64 = @intCast(@divFloor(delta_ticks, ticks_per_sec));
    const rem_ticks: u32 = @intCast(@mod(delta_ticks, ticks_per_sec));
    return .{
        .seconds = sec,
        .nanoseconds = rem_ticks * 100,
    };
}

pub fn filetimeToUnixSec(ft: FILETIME) i64 {
    return filetimeToUnixNanotime(ft).seconds;
}

pub fn unixSecToFiletime(sec: i64) FILETIME {
    const ticks_i128 = (@as(i128, sec) + @as(i128, windows_epoch_offset_sec)) * ticks_per_sec;
    const ticks: u64 = if (ticks_i128 <= 0) 0 else @intCast(@min(ticks_i128, @as(i128, std.math.maxInt(u64))));
    return .{
        .dwLowDateTime = @truncate(ticks),
        .dwHighDateTime = @truncate(ticks >> 32),
    };
}

pub fn win32ErrorToErrno(err: DWORD) c_int {
    return switch (err) {
        0 => 0,
        2, 3, 15, 161 => @intFromEnum(std.c.E.NOENT),
        4 => @intFromEnum(std.c.E.MFILE),
        5, 65, 1314 => @intFromEnum(std.c.E.ACCES),
        6 => @intFromEnum(std.c.E.BADF),
        8, 14 => @intFromEnum(std.c.E.NOMEM),
        17 => @intFromEnum(std.c.E.XDEV),
        19 => @intFromEnum(std.c.E.ROFS),
        32, 33 => @intFromEnum(std.c.E.BUSY),
        80, 183 => @intFromEnum(std.c.E.EXIST),
        87 => @intFromEnum(std.c.E.INVAL),
        109, 232 => @intFromEnum(std.c.E.PIPE),
        39, 112 => @intFromEnum(std.c.E.NOSPC),
        120 => @intFromEnum(std.c.E.NOSYS),
        145 => @intFromEnum(std.c.E.NOTEMPTY),
        206 => @intFromEnum(std.c.E.NAMETOOLONG),
        267 => @intFromEnum(std.c.E.NOTDIR),
        10004 => @intFromEnum(std.c.E.INTR),
        10009 => @intFromEnum(std.c.E.BADF),
        10013 => @intFromEnum(std.c.E.ACCES),
        10014 => @intFromEnum(std.c.E.FAULT),
        10022 => @intFromEnum(std.c.E.INVAL),
        10024 => @intFromEnum(std.c.E.MFILE),
        10035 => @intFromEnum(std.c.E.AGAIN),
        10047 => @intFromEnum(std.c.E.AFNOSUPPORT),
        10048 => @intFromEnum(std.c.E.ADDRINUSE),
        10049 => @intFromEnum(std.c.E.ADDRNOTAVAIL),
        10054 => @intFromEnum(std.c.E.CONNRESET),
        10061 => @intFromEnum(std.c.E.CONNREFUSED),
        10065 => @intFromEnum(std.c.E.HOSTUNREACH),
        else => @intFromEnum(std.c.E.IO),
    };
}

pub fn win32AttrToMode(attrs: DWORD, is_symlink: bool) u32 {
    if (is_symlink) return 0o120777;
    if ((attrs & FILE_ATTRIBUTE_DIRECTORY) != 0) {
        return if ((attrs & FILE_ATTRIBUTE_READONLY) != 0) 0o040555 else 0o040755;
    }
    return if ((attrs & FILE_ATTRIBUTE_READONLY) != 0) 0o100444 else 0o100644;
}

pub fn normalizeSlashesInPlace(buf: []u8) void {
    for (buf) |*ch| {
        if (ch.* == '\\') ch.* = '/';
    }
}

pub fn appendQuotedWindowsArg(out: *std.ArrayList(u8), allocator: std.mem.Allocator, arg: []const u8) !void {
    if (arg.len == 0) {
        try out.appendSlice(allocator, "\"\"");
        return;
    }
    var needs_quote = false;
    for (arg) |c| {
        if (c == ' ' or c == '\t' or c == '"') {
            needs_quote = true;
            break;
        }
    }
    if (!needs_quote) {
        try out.appendSlice(allocator, arg);
        return;
    }

    try out.append(allocator, '"');
    var i: usize = 0;
    while (i < arg.len) {
        var backslashes: usize = 0;
        while (i < arg.len and arg[i] == '\\') : (i += 1) {
            backslashes += 1;
        }
        if (i == arg.len) {
            try out.appendNTimes(allocator, '\\', backslashes * 2);
            break;
        } else if (arg[i] == '"') {
            try out.appendNTimes(allocator, '\\', backslashes * 2 + 1);
            try out.append(allocator, '"');
            i += 1;
        } else {
            try out.appendNTimes(allocator, '\\', backslashes);
            try out.append(allocator, arg[i]);
            i += 1;
        }
    }
    try out.append(allocator, '"');
}

test "win_api filetime conversions, error mapping, mode bits, slash normalization, and argv quoting" {
    // Epoch zero round-trip (1970-01-01T00:00:00Z)
    const ft_epoch = unixSecToFiletime(0);
    try std.testing.expectEqual(@as(i64, 0), filetimeToUnixSec(ft_epoch));
    const nt_epoch = filetimeToUnixNanotime(ft_epoch);
    try std.testing.expectEqual(@as(i64, 0), nt_epoch.seconds);
    try std.testing.expectEqual(@as(u32, 0), nt_epoch.nanoseconds);

    // Modern timestamp + sub-second nanoseconds (1_700_000_000.123456700 s)
    const modern_sec: i64 = 1_700_000_000;
    const base_ft = unixSecToFiletime(modern_sec);
    const base_ticks: u64 = (@as(u64, base_ft.dwHighDateTime) << 32) | @as(u64, base_ft.dwLowDateTime);
    const with_sub: u64 = base_ticks + 1_234_567;
    const nt_modern = filetimeToUnixNanotime(.{
        .dwLowDateTime = @truncate(with_sub),
        .dwHighDateTime = @truncate(with_sub >> 32),
    });
    try std.testing.expectEqual(modern_sec, nt_modern.seconds);
    try std.testing.expectEqual(@as(u32, 123_456_700), nt_modern.nanoseconds);

    // Win32 / WSA error mappings
    try std.testing.expectEqual(@intFromEnum(std.c.E.NOENT), win32ErrorToErrno(2));
    try std.testing.expectEqual(@intFromEnum(std.c.E.ACCES), win32ErrorToErrno(5));
    try std.testing.expectEqual(@intFromEnum(std.c.E.EXIST), win32ErrorToErrno(183));
    try std.testing.expectEqual(@intFromEnum(std.c.E.CONNREFUSED), win32ErrorToErrno(10061));
    try std.testing.expectEqual(@intFromEnum(std.c.E.AGAIN), win32ErrorToErrno(10035));
    try std.testing.expectEqual(@intFromEnum(std.c.E.IO), win32ErrorToErrno(999999));

    // File attributes to POSIX mode
    try std.testing.expectEqual(@as(u32, 0o120777), win32AttrToMode(FILE_ATTRIBUTE_REPARSE_POINT, true));
    try std.testing.expectEqual(@as(u32, 0o040755), win32AttrToMode(FILE_ATTRIBUTE_DIRECTORY, false));
    try std.testing.expectEqual(@as(u32, 0o040555), win32AttrToMode(FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_READONLY, false));
    try std.testing.expectEqual(@as(u32, 0o100644), win32AttrToMode(FILE_ATTRIBUTE_NORMAL, false));
    try std.testing.expectEqual(@as(u32, 0o100444), win32AttrToMode(FILE_ATTRIBUTE_READONLY, false));

    // Slash normalization
    var path_buf = "C:\\Program Files\\MIT-GNU-Scheme\\lib".*;
    normalizeSlashesInPlace(&path_buf);
    try std.testing.expectEqualStrings("C:/Program Files/MIT-GNU-Scheme/lib", &path_buf);

    // MSVC CommandLineToArgvW quoting
    var cmd: std.ArrayList(u8) = .empty;
    defer cmd.deinit(std.testing.allocator);
    try appendQuotedWindowsArg(&cmd, std.testing.allocator, "plain");
    try cmd.append(std.testing.allocator, ' ');
    try appendQuotedWindowsArg(&cmd, std.testing.allocator, "hello world\\");
    try cmd.append(std.testing.allocator, ' ');
    try appendQuotedWindowsArg(&cmd, std.testing.allocator, "a\\\"b");
    try cmd.append(std.testing.allocator, ' ');
    try appendQuotedWindowsArg(&cmd, std.testing.allocator, "");
    try std.testing.expectEqualStrings(
        "plain \"hello world\\\\\" \"a\\\\\\\"b\" \"\"",
        cmd.items,
    );
}
