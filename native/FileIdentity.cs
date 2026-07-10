using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public sealed class FileIdentityInfo
{
    public uint VolumeSerialNumber { get; set; }
    public ulong FileIndex { get; set; }
    public uint NumberOfLinks { get; set; }
    public long LogicalBytes { get; set; }
    public long AllocatedBytes { get; set; }
    public bool AllocatedBytesAccurate { get; set; }
    public FileAttributes FileAttributes { get; set; }
}

public static class FileIdentity
{
    private const uint FileReadAttributes = 0x80;
    private const uint ShareAll = 0x7;
    private const uint OpenExisting = 3;
    private const uint FileFlagBackupSemantics = 0x02000000;
    private const uint InvalidFileSize = 0xffffffff;

    [StructLayout(LayoutKind.Sequential)]
    private struct ByHandleFileInformation
    {
        public uint FileAttributes;
        public System.Runtime.InteropServices.ComTypes.FILETIME CreationTime;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastAccessTime;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWriteTime;
        public uint VolumeSerialNumber;
        public uint FileSizeHigh;
        public uint FileSizeLow;
        public uint NumberOfLinks;
        public uint FileIndexHigh;
        public uint FileIndexLow;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateFileW(
        string fileName, uint desiredAccess, uint shareMode, IntPtr securityAttributes,
        uint creationDisposition, uint flagsAndAttributes, IntPtr templateFile);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetFileInformationByHandle(
        SafeFileHandle file, out ByHandleFileInformation information);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern uint GetCompressedFileSizeW(string fileName, out uint fileSizeHigh);

    public static FileIdentityInfo Read(string path)
    {
        using (SafeFileHandle handle = CreateFileW(
            path, FileReadAttributes, ShareAll, IntPtr.Zero, OpenExisting,
            FileFlagBackupSemantics, IntPtr.Zero))
        {
            if (handle.IsInvalid)
                throw new Win32Exception(Marshal.GetLastWin32Error(), path);

            ByHandleFileInformation raw;
            if (!GetFileInformationByHandle(handle, out raw))
                throw new Win32Exception(Marshal.GetLastWin32Error(), path);

            long logical = ((long)raw.FileSizeHigh << 32) | raw.FileSizeLow;
            uint allocatedHigh;
            Marshal.GetLastWin32Error();
            uint allocatedLow = GetCompressedFileSizeW(path, out allocatedHigh);
            int allocationError = Marshal.GetLastWin32Error();
            bool allocationAccurate = allocatedLow != InvalidFileSize || allocationError == 0;
            long allocated = allocationAccurate
                ? ((long)allocatedHigh << 32) | allocatedLow
                : logical;

            return new FileIdentityInfo
            {
                VolumeSerialNumber = raw.VolumeSerialNumber,
                FileIndex = ((ulong)raw.FileIndexHigh << 32) | raw.FileIndexLow,
                NumberOfLinks = raw.NumberOfLinks,
                LogicalBytes = logical,
                AllocatedBytes = allocated,
                AllocatedBytesAccurate = allocationAccurate,
                FileAttributes = (FileAttributes)raw.FileAttributes
            };
        }
    }
}
