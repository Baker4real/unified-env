using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Win32;
using Microsoft.Win32.SafeHandles;

namespace CodexHookGovernance
{
    public enum UserEnvironmentValueKind
    {
        Missing = 0,
        String = 1,
        ExpandString = 2
    }

    public sealed class UserEnvironmentValueSnapshot
    {
        public UserEnvironmentValueSnapshot(string value, UserEnvironmentValueKind kind)
        {
            Value = value;
            Kind = kind;
        }

        public string Value { get; }
        public UserEnvironmentValueKind Kind { get; }
    }

    public static class UserEnvironmentTransaction
    {
        private static readonly UIntPtr HkeyCurrentUser = new UIntPtr(0x80000001u);
        private const string EnvironmentSubKey = "Environment";
        private const string SerenaHomeValueName = "SERENA_HOME";
        private const int KeyQueryValue = 0x0001;
        private const int KeySetValue = 0x0002;
        private const int ErrorSuccess = 0;
        private const int ErrorFileNotFound = 2;
        private const int ErrorMoreData = 234;
        private const int RegSz = 1;
        private const int RegExpandSz = 2;

        [DllImport("ktmw32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern SafeFileHandle CreateTransaction(
            IntPtr transactionAttributes, IntPtr uow, uint createOptions,
            uint isolationLevel, uint isolationFlags, uint timeout, string description);

        [DllImport("ktmw32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CommitTransaction(SafeFileHandle transactionHandle);

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern int RegOpenKeyTransactedW(
            UIntPtr hKey, string subKey, int options, int samDesired,
            out SafeRegistryHandle result, SafeFileHandle transaction, IntPtr extendedParameter);

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode)]
        private static extern int RegQueryValueExW(
            SafeRegistryHandle hKey, string valueName, IntPtr reserved,
            out int type, byte[] data, ref int dataSize);

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode)]
        private static extern int RegSetValueExW(
            SafeRegistryHandle hKey, string valueName, int reserved, int type,
            byte[] data, int dataSize);

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode)]
        private static extern int RegDeleteValueW(SafeRegistryHandle hKey, string valueName);

        public static UserEnvironmentValueSnapshot ReadUserSerenaHome()
        {
            return ReadNonTransactional(EnvironmentSubKey, SerenaHomeValueName);
        }

        public static void SetUserSerenaHome(
            string expectedValue,
            UserEnvironmentValueKind expectedKind,
            string desiredValue,
            UserEnvironmentValueKind desiredKind)
        {
            SetTransactional(
                EnvironmentSubKey,
                SerenaHomeValueName,
                expectedValue,
                expectedKind,
                desiredValue,
                desiredKind,
                null,
                null);
        }

        public static void SetFixtureValue(
            string subKey,
            string expectedValue,
            UserEnvironmentValueKind expectedKind,
            string desiredValue,
            UserEnvironmentValueKind desiredKind)
        {
            AssertFixtureSubKey(subKey);
            SetTransactional(subKey, SerenaHomeValueName, expectedValue, expectedKind, desiredValue, desiredKind, null, null);
        }

        public static Task SetFixtureValueWithBarrier(
            string subKey,
            string expectedValue,
            UserEnvironmentValueKind expectedKind,
            string desiredValue,
            UserEnvironmentValueKind desiredKind,
            ManualResetEventSlim transactionReady,
            ManualResetEventSlim allowCommit)
        {
            AssertFixtureSubKey(subKey);
            if (transactionReady == null) throw new ArgumentNullException(nameof(transactionReady));
            if (allowCommit == null) throw new ArgumentNullException(nameof(allowCommit));
            return Task.Run(() => SetTransactional(
                subKey, SerenaHomeValueName, expectedValue, expectedKind,
                desiredValue, desiredKind, transactionReady, allowCommit));
        }

        private static void SetTransactional(
            string subKey,
            string valueName,
            string expectedValue,
            UserEnvironmentValueKind expectedKind,
            string desiredValue,
            UserEnvironmentValueKind desiredKind,
            ManualResetEventSlim transactionReady,
            ManualResetEventSlim allowCommit)
        {
            ValidateValueContract(expectedValue, expectedKind, nameof(expectedKind));
            ValidateValueContract(desiredValue, desiredKind, nameof(desiredKind));
            using (SafeFileHandle transaction = CreateTransaction(
                IntPtr.Zero, IntPtr.Zero, 0, 0, 0, 0, "Codex User environment transaction"))
            {
                if (transaction.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
                SafeRegistryHandle key;
                int opened = RegOpenKeyTransactedW(
                    HkeyCurrentUser, subKey, 0, KeyQueryValue | KeySetValue,
                    out key, transaction, IntPtr.Zero);
                if (opened != ErrorSuccess) throw new Win32Exception(opened);
                using (key)
                {
                    UserEnvironmentValueSnapshot current = ReadFromHandle(key, valueName);
                    if (current.Kind != expectedKind || !string.Equals(current.Value, expectedValue, StringComparison.Ordinal))
                    {
                        throw new IOException("User environment value changed before transactional write.");
                    }

                    if (desiredKind == UserEnvironmentValueKind.Missing)
                    {
                        int deleted = RegDeleteValueW(key, valueName);
                        if (deleted != ErrorSuccess && deleted != ErrorFileNotFound) throw new Win32Exception(deleted);
                    }
                    else
                    {
                        byte[] bytes = Encoding.Unicode.GetBytes(desiredValue + "\0");
                        int written = RegSetValueExW(key, valueName, 0, (int)desiredKind, bytes, bytes.Length);
                        if (written != ErrorSuccess) throw new Win32Exception(written);
                    }

                    if (transactionReady != null)
                    {
                        transactionReady.Set();
                        if (!allowCommit.Wait(5000)) throw new TimeoutException("User environment transaction fixture was not released.");
                    }
                    if (!CommitTransaction(transaction)) throw new Win32Exception(Marshal.GetLastWin32Error());
                }
            }

            UserEnvironmentValueSnapshot verified = ReadNonTransactional(subKey, valueName);
            if (verified.Kind != desiredKind || !string.Equals(verified.Value, desiredValue, StringComparison.Ordinal))
            {
                throw new IOException("User environment transactional write failed post-commit verification.");
            }
        }

        private static UserEnvironmentValueSnapshot ReadFromHandle(SafeRegistryHandle key, string valueName)
        {
            int type;
            int byteCount = 0;
            int first = RegQueryValueExW(key, valueName, IntPtr.Zero, out type, null, ref byteCount);
            if (first == ErrorFileNotFound) return new UserEnvironmentValueSnapshot(null, UserEnvironmentValueKind.Missing);
            if (first != ErrorSuccess && first != ErrorMoreData) throw new Win32Exception(first);
            byte[] bytes = new byte[byteCount];
            int second = RegQueryValueExW(key, valueName, IntPtr.Zero, out type, bytes, ref byteCount);
            if (second != ErrorSuccess) throw new Win32Exception(second);
            UserEnvironmentValueKind kind = ToSupportedKind(type);
            string value = DecodeRegistryString(bytes, byteCount);
            return new UserEnvironmentValueSnapshot(value, kind);
        }

        private static string DecodeRegistryString(byte[] bytes, int byteCount)
        {
            if (byteCount < 2 || (byteCount & 1) != 0 || bytes[byteCount - 2] != 0 || bytes[byteCount - 1] != 0)
            {
                throw new IOException("User environment registry string encoding is invalid.");
            }
            string value = Encoding.Unicode.GetString(bytes, 0, byteCount - 2);
            if (value.IndexOf('\0') >= 0)
            {
                throw new IOException("User environment registry string encoding contains an embedded NUL.");
            }
            return value;
        }

        private static UserEnvironmentValueSnapshot ReadNonTransactional(string subKey, string valueName)
        {
            using (RegistryKey key = Registry.CurrentUser.OpenSubKey(subKey, false))
            {
                if (key == null) throw new IOException("User environment registry key is unavailable.");
                object raw = key.GetValue(valueName, null, RegistryValueOptions.DoNotExpandEnvironmentNames);
                if (raw == null) return new UserEnvironmentValueSnapshot(null, UserEnvironmentValueKind.Missing);
                RegistryValueKind registryKind = key.GetValueKind(valueName);
                UserEnvironmentValueKind kind = registryKind == RegistryValueKind.String
                    ? UserEnvironmentValueKind.String
                    : registryKind == RegistryValueKind.ExpandString
                        ? UserEnvironmentValueKind.ExpandString
                        : throw new IOException("User environment value type is unsupported.");
                return new UserEnvironmentValueSnapshot((string)raw, kind);
            }
        }

        private static UserEnvironmentValueKind ToSupportedKind(int type)
        {
            if (type == RegSz) return UserEnvironmentValueKind.String;
            if (type == RegExpandSz) return UserEnvironmentValueKind.ExpandString;
            throw new IOException("User environment value type is unsupported.");
        }

        private static void ValidateValueContract(string value, UserEnvironmentValueKind kind, string name)
        {
            if (kind == UserEnvironmentValueKind.Missing)
            {
                if (value != null) throw new ArgumentException("Missing environment values must be null.", name);
                return;
            }
            if (kind != UserEnvironmentValueKind.String && kind != UserEnvironmentValueKind.ExpandString)
            {
                throw new ArgumentOutOfRangeException(name);
            }
            if (value == null) throw new ArgumentNullException(name);
        }

        private static void AssertFixtureSubKey(string subKey)
        {
            if (subKey == null || !Regex.IsMatch(subKey, @"\ASoftware\\Codex\\HookFixtures\\[0-9a-f]{32}\z", RegexOptions.CultureInvariant))
            {
                throw new ArgumentException("Fixture registry key is outside the fixed test root.", nameof(subKey));
            }
        }
    }
}
