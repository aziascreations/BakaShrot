// BakaShrot client for C#, over the client library (bakashrot.dll,
// libbakashrot.so). One file, C# 2 and the .NET 2.0 class library only:
// .NET Framework 2.0 and 3.x up to the latest .NET. docs/client.md, "C#".
//
//     using (Client client = new Client("10.0.0.2", 7000, "ca.crt", "kitchen.crt", "kitchen.key", null))
//     {
//         client.Connect();
//         long id = client.Push("sensors", "{\"t\":21}");
//         foreach (Message message in client.IterMessages("sensors", client.Node, 0))
//             Console.WriteLine(message.Id + " " + message.Data);
//     }
//
// The library goes next to the app, which must run 64-bit. Errors are
// exceptions with the library's ErrorCode: RefusedException (the server
// refused, still connected), ConnectionLostException (Connect() again),
// AuthException (a certificate or role refused when connecting),
// BakaShrotException (the rest). A Client's calls are serialized: it can be
// shared between threads, and several can be connected at once.

using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace NibblePoker.BakaShrot
{
    /// <summary>crates/bakashrot-proto/src/error.rs: 1-99 refused by the
    /// server, 100 and up the client's own.</summary>
    public enum ErrorCode
    {
        None = 0,
        NotAllowed = 1, UnknownName = 2, NotFound = 3, NotReady = 4, TooBig = 5,
        InvalidRequest = 7, DataMismatch = 8, QueryFailed = 9, ServerError = 10,
        NotConnected = 100, ConnectFailed = 101, AuthRejected = 102, ServerNotVerified = 103,
        ConnectionLost = 104, ProtocolError = 105, InvalidArgument = 106, FileError = 107,
        AttachmentMismatch = 108, AlreadyConnected = 109, Internal = 110, VersionMismatch = 111
    }

    public class BakaShrotException : Exception
    {
        public readonly ErrorCode Code;

        public BakaShrotException(string message, ErrorCode code) : base(message)
        {
            Code = code;
        }
    }

    /// <summary>The server refused (codes 1-99), the connection still open:
    /// Message is its reason.</summary>
    public class RefusedException : BakaShrotException
    {
        public RefusedException(string reason, ErrorCode code) : base(reason, code) { }
    }

    /// <summary>Not connected, unreachable, or the connection broke:
    /// Connect() again. A push whose answer was lost may be stored.</summary>
    public class ConnectionLostException : BakaShrotException
    {
        public ConnectionLostException(string message, ErrorCode code) : base(message, code) { }
    }

    /// <summary>Connecting refused for good: a certificate either way, no
    /// role allowed, another protocol version.</summary>
    public class AuthException : BakaShrotException
    {
        public AuthException(string message, ErrorCode code) : base(message, code) { }
    }

    /// <summary>A stored message, its data as pushed (JSON or not).</summary>
    public sealed class Message
    {
        public long Id;
        public string Topic, Node, Data;
        /// <summary>Milliseconds since 1970-01-01 UTC, by the server it was pushed to.</summary>
        public long PushedAt;
        /// <summary>0 without an attachment.</summary>
        public long AttachmentSize;
        /// <summary>All of the attachment is on this server.</summary>
        public bool AttachmentReady;

        public DateTime Pushed
        {
            get { return new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc).AddMilliseconds(PushedAt); }
        }
    }

    /// <summary>One answer of GetMessages(): More if more follow LastId.</summary>
    public sealed class MessagesPage
    {
        public List<Message> Messages = new List<Message>();
        public bool More;

        /// <summary>The last message's id, 0 if none.</summary>
        public long LastId
        {
            get { return Messages.Count == 0 ? 0 : Messages[Messages.Count - 1].Id; }
        }
    }

    /// <summary>A row of EnumerateQuery(): its values (null for NULL), by
    /// index or column name.</summary>
    public sealed class QueryRow
    {
        /// <summary>The query's columns, the same array for every row.</summary>
        public readonly string[] Columns;
        public readonly string[] Values;

        internal QueryRow(string[] columns, string[] values)
        {
            Columns = columns;
            Values = values;
        }

        public string this[int column]
        {
            get { return Values[column]; }
        }

        /// <summary>The first column with that name (as the query wrote it).</summary>
        public string this[string column]
        {
            get
            {
                int index = Array.IndexOf(Columns, column);
                if (index < 0)
                    throw new ArgumentException("No column " + column, "column");
                return Values[index];
            }
        }
    }

    public sealed class Client : IDisposable
    {
        public readonly string Host, Ca, Certificate, Key, Crl;
        public readonly int Port;
        private readonly object sync = new object();
        private string node = "";
        private long handle; // its client in the library, 0 before Connect() and after Close()

        /// <summary>host: a name or an address. The certificates and the CRL
        /// (null for none): PEM text or a file's path.</summary>
        public Client(string host, int port, string ca, string certificate, string key, string crl)
        {
            Host = host;
            Port = port;
            Ca = ca;
            Certificate = certificate;
            Key = key;
            Crl = crl;
        }

        /// <summary>The node the server says this client is, once connected.</summary>
        public string Node { get { return node; } }

        public bool Connected
        {
            get { lock (sync) return handle != 0 && Native.BakaShrot_IsConnected(handle) != IntPtr.Zero; }
        }

        public Client Connect()
        {
            lock (sync)
            {
                if (handle == 0 && (handle = Native.BakaShrot_CreateClient()) == 0)
                    throw new BakaShrotException("The library made no client", ErrorCode.Internal);
                if (Native.BakaShrot_IsConnected(handle) != IntPtr.Zero)
                    return this;
                Check(Native.BakaShrot_SetCaCertificateW(handle, Text(Ca)), "Certificates");
                Check(Native.BakaShrot_SetCertificateW(handle, Text(Certificate)), "Certificates");
                Check(Native.BakaShrot_SetPrivateKeyW(handle, Text(Key)), "Certificates");
                Check(Native.BakaShrot_SetCrlW(handle, Text(Crl ?? "")), "Certificates");
                if (Native.BakaShrot_ConnectW(handle, Text(Host), Port) == IntPtr.Zero)
                    throw Failed("Connect to " + Host + ":" + Port, true);
                node = GetString(Native.BakaShrot_GetNodeW);
                return this;
            }
        }

        /// <summary>Disconnects and frees its client in the library; Connect() reconnects.</summary>
        public void Close()
        {
            lock (sync)
            {
                if (handle != 0)
                    Native.BakaShrot_FreeClient(handle);
                handle = 0;
            }
        }

        public void Dispose()
        {
            Close();
            GC.SuppressFinalize(this);
        }

        ~Client()
        {
            if (handle != 0)
                Native.BakaShrot_FreeClient(handle);
        }

        /// <summary>Pushes data (JSON or not) to topic, as this client's node: its id.</summary>
        public long Push(string topic, string data)
        {
            lock (sync)
                return Id(Native.BakaShrot_PushMessageToW(Handle(), Text(topic), Text(data ?? "")), "Push");
        }

        /// <summary>With an attachment (1 byte and up): the message is stored once all of it came.</summary>
        public long Push(string topic, string data, byte[] attachment)
        {
            lock (sync)
                return Id(Native.BakaShrot_PushMessageWithDataW(Handle(), Text(topic), Text(data ?? ""), attachment,
                    attachment == null ? 0 : attachment.LongLength), "Push");
        }

        /// <summary>With the file at path as its attachment, read a part at a time.</summary>
        public long PushFile(string topic, string data, string path)
        {
            lock (sync)
                return Id(Native.BakaShrot_PushMessageWithFileW(Handle(), Text(topic), Text(data ?? ""), Text(path)), "Push");
        }

        /// <summary>The latest message of topic and node, null if none yet.</summary>
        public Message Latest(string topic, string node)
        {
            lock (sync)
            {
                if (Native.BakaShrot_GetLatestMessageOfW(Handle(), Text(topic), Text(node)) != IntPtr.Zero)
                    return Current();
                BakaShrotException error = Failed("Latest message", false);
                if (error.Code == ErrorCode.NotFound)
                    return null;
                throw error;
            }
        }

        /// <summary>The messages of topic and node after id after (0 for the
        /// first), in order: limit at most (1-10000), fewer past about 1 MB.</summary>
        public MessagesPage GetMessages(string topic, string node, long after, int limit)
        {
            lock (sync)
            {
                int count = Native.BakaShrot_GetMessagesW(Handle(), Text(topic), Text(node), after, limit);
                if (count < 0)
                    throw Failed("Get messages", false);
                MessagesPage page = new MessagesPage();
                for (int index = 0; index < count; index++)
                {
                    Native.BakaShrot_SelectMessage(handle, index);
                    page.Messages.Add(Current());
                }
                page.More = Native.BakaShrot_HasMoreMessages(handle) != IntPtr.Zero;
                return page;
            }
        }

        /// <summary>Every message of topic and node after id after, until there are no more.</summary>
        public IEnumerable<Message> IterMessages(string topic, string node, long after)
        {
            MessagesPage page;
            do
            {
                page = GetMessages(topic, node, after, 1000);
                foreach (Message message in page.Messages)
                    yield return message;
                after = Math.Max(after, page.LastId);
            } while (page.More);
        }

        /// <summary>The messages pushed from now on, as Follow(topic, node, after, 500) does.</summary>
        public IEnumerable<Message> Follow(string topic, string node)
        {
            Message latest = Latest(topic, node);
            return Follow(topic, node, latest == null ? 0 : latest.Id, 500);
        }

        /// <summary>Every message after id after, then new ones as they
        /// come, checking every intervalMs: forever, stop enumerating to
        /// stop. Nothing reconnects by itself.</summary>
        public IEnumerable<Message> Follow(string topic, string node, long after, int intervalMs)
        {
            while (true)
            {
                MessagesPage page = GetMessages(topic, node, after, 1000);
                foreach (Message message in page.Messages)
                    yield return message;
                after = Math.Max(after, page.LastId);
                if (!page.More)
                    Thread.Sleep(intervalMs);
            }
        }

        /// <summary>A message's attachment, in memory (SaveAttachment() for
        /// big ones), checked with its SHA-256.</summary>
        public byte[] GetAttachment(string topic, string node, long messageId)
        {
            lock (sync)
            {
                long size = Id(Native.BakaShrot_LoadAttachmentW(Handle(), Text(topic), Text(node), messageId), "Attachment");
                try
                {
                    byte[] data = new byte[size];
                    Native.BakaShrot_GetAttachmentData(handle, data, size);
                    return data;
                }
                finally
                {
                    Native.BakaShrot_FreeAttachmentData(handle);
                }
            }
        }

        /// <summary>Saves a message's attachment as the file at path
        /// (replaced), checked with its SHA-256: its size. A failed one
        /// leaves no file.</summary>
        public long SaveAttachment(string topic, string node, long messageId, string path)
        {
            lock (sync)
                return Id(Native.BakaShrot_SaveAttachmentW(Handle(), Text(topic), Text(node), messageId, Text(path)), "Attachment");
        }

        /// <summary>The topics with messages that this client may push to or
        /// read, as JSON: {"kind":"topic","truncated":false,"names":[...]}.</summary>
        public string ListTopics()
        {
            return ListTopics(null, null);
        }

        /// <summary>ListTopics(), only those of the topic and node pairs that
        /// topic and node match, each a name or a pattern ("sensors.*"), null
        /// for any: ListTopics(null, "kitchen") is the topics kitchen pushed to.</summary>
        public string ListTopics(string topic, string node)
        {
            lock (sync)
                return Names(Native.BakaShrot_ListNamesW(Handle(), 1, Text(topic), Text(node)), "List topics");
        }

        /// <summary>The nodes with messages in the topics this client may
        /// read, as ListTopics() says them.</summary>
        public string ListNodes()
        {
            return ListNodes(null, null);
        }

        /// <summary>ListNodes(), filtered as ListTopics(topic, node) is:
        /// ListNodes("logs", null) is the nodes that pushed to logs.</summary>
        public string ListNodes(string topic, string node)
        {
            lock (sync)
                return Names(Native.BakaShrot_ListNamesW(Handle(), 2, Text(topic), Text(node)), "List nodes");
        }

        /// <summary>Runs one read-only SELECT or WITH: the server's JSON,
        /// {"columns":[...],"rows":[[...],...]}.</summary>
        public string Query(string sql)
        {
            lock (sync)
            {
                Check(Native.BakaShrot_QueryW(Handle(), Text(sql)), "Query");
                return GetString(Native.BakaShrot_GetQueryResultAsJsonW);
            }
        }

        /// <summary>The topics ListTopics() lists, one at a time, without
        /// JSON. Asked once a foreach starts (each one asks again), closed
        /// when it ends.</summary>
        public IEnumerable<string> EnumerateTopics()
        {
            return EnumerateNames(1, null, null);
        }

        /// <summary>The topics ListTopics(topic, node) lists, as EnumerateTopics() gives them.</summary>
        public IEnumerable<string> EnumerateTopics(string topic, string node)
        {
            return EnumerateNames(1, topic, node);
        }

        /// <summary>The nodes ListNodes() lists, as EnumerateTopics() gives them.</summary>
        public IEnumerable<string> EnumerateNodes()
        {
            return EnumerateNames(2, null, null);
        }

        /// <summary>The nodes ListNodes(topic, node) lists, as EnumerateTopics() gives them.</summary>
        public IEnumerable<string> EnumerateNodes(string topic, string node)
        {
            return EnumerateNames(2, topic, node);
        }

        /// <summary>Query(sql)'s rows, one at a time, without JSON. Asked
        /// once a foreach starts (each one asks again), closed when it ends.</summary>
        public IEnumerable<QueryRow> EnumerateQuery(string sql)
        {
            long enumeration;
            lock (sync)
                enumeration = Opened(Native.BakaShrot_EnumerateQueryW(Handle(), Text(sql)), "Query");
            try
            {
                string[] columns = new string[Native.BakaShrot_GetQueryColumnCount(enumeration)];
                for (int column = 0; column < columns.Length; column++)
                    columns[column] = GetString(enumeration, ColumnGetter(Native.BakaShrot_GetQueryColumnNameW, column));
                while (Next(Native.BakaShrot_NextQueryRow(enumeration)))
                {
                    string[] values = new string[columns.Length];
                    for (int column = 0; column < values.Length; column++)
                        if (Native.BakaShrot_IsQueryValueNull(enumeration, column) == IntPtr.Zero)
                            values[column] = GetString(enumeration, ColumnGetter(Native.BakaShrot_GetQueryValueW, column));
                    yield return new QueryRow(columns, values);
                }
            }
            finally
            {
                Native.BakaShrot_CloseEnum(enumeration);
            }
        }

        // --- Inside ---------------------------------------------------------

        private IEnumerable<string> EnumerateNames(int kind, string topic, string node)
        {
            long enumeration;
            lock (sync)
                enumeration = Opened(Native.BakaShrot_EnumerateNamesW(Handle(), kind, Text(topic), Text(node)),
                    kind == 1 ? "List topics" : "List nodes");
            try
            {
                while (Next(Native.BakaShrot_NextName(enumeration)))
                    yield return GetString(enumeration, Native.BakaShrot_GetEnumNameW);
            }
            finally
            {
                Native.BakaShrot_CloseEnum(enumeration);
            }
        }

        // An enumeration's handle, 0 on failure.
        private long Opened(long enumeration, string what)
        {
            if (enumeration == 0)
                throw Failed(what, false);
            return enumeration;
        }

        // A Next...(): 1 an item, 0 no more, -1 closed (with its client, by Close()).
        private static bool Next(IntPtr result)
        {
            if (result.ToInt64() < 0)
                throw new ConnectionLostException("The client was closed while enumerating", ErrorCode.NotConnected);
            return result != IntPtr.Zero;
        }

        private long Handle()
        {
            if (handle == 0)
                throw new ConnectionLostException("Not connected", ErrorCode.NotConnected);
            return handle;
        }

        private Message Current()
        {
            Message message = new Message();
            message.Id = Native.BakaShrot_GetMessageId(handle);
            message.Topic = GetString(Native.BakaShrot_GetMessageTopicW);
            message.Node = GetString(Native.BakaShrot_GetMessageNodeW);
            message.Data = GetString(Native.BakaShrot_GetMessageDataW);
            message.PushedAt = Native.BakaShrot_GetMessagePushedAt(handle);
            message.AttachmentSize = Native.BakaShrot_GetMessageAttachmentSize(handle);
            message.AttachmentReady = Native.BakaShrot_IsMessageAttachmentReady(handle) != IntPtr.Zero;
            return message;
        }

        private string Names(int count, string what)
        {
            if (count < 0)
                throw Failed(what, false);
            return GetString(Native.BakaShrot_GetNamesListAsJsonW);
        }

        // Strings go as UTF-16: one with a NUL would be cut there.
        private static string Text(string value)
        {
            if (value != null && value.IndexOf('\0') >= 0)
                throw new BakaShrotException("A string with a NUL character", ErrorCode.InvalidArgument);
            return value;
        }

        private delegate IntPtr Getter(long handle, byte[] buffer, IntPtr size);
        private delegate IntPtr IndexGetter(long handle, int index, byte[] buffer, IntPtr size);

        private string GetString(Getter getter)
        {
            return GetString(handle, getter);
        }

        // A string getter, of a client or an enumeration: the size first
        // (bytes, the terminator included), then the copy.
        private static string GetString(long from, Getter getter)
        {
            int size = getter(from, null, IntPtr.Zero).ToInt32();
            if (size <= 2)
                return "";
            byte[] buffer = new byte[size];
            getter(from, buffer, new IntPtr(size));
            return Encoding.Unicode.GetString(buffer, 0, size - 2);
        }

        // A column's getter, as a string getter.
        private static Getter ColumnGetter(IndexGetter getter, int column)
        {
            return delegate(long from, byte[] buffer, IntPtr size) { return getter(from, column, buffer, size); };
        }

        private void Check(IntPtr result, string what)
        {
            if (result == IntPtr.Zero)
                throw Failed(what, false);
        }

        // An id or a size, -1 on failure.
        private long Id(long result, string what)
        {
            if (result < 0)
                throw Failed(what, false);
            return result;
        }

        private BakaShrotException Failed(string what, bool connecting)
        {
            ErrorCode code = (ErrorCode)Native.BakaShrot_GetLastError(handle);
            string reason = GetString(Native.BakaShrot_GetRefusalReasonW);
            if (connecting && (code == ErrorCode.AuthRejected || code == ErrorCode.ServerNotVerified
                    || code == ErrorCode.NotAllowed || code == ErrorCode.VersionMismatch))
                return new AuthException(what + ": " + reason, code);
            if ((int)code >= 1 && (int)code <= 99)
                return new RefusedException(reason, code);
            string message = what + " (" + code + "): " + reason;
            if (code == ErrorCode.NotConnected || code == ErrorCode.ConnectFailed || code == ErrorCode.ConnectionLost
                    || code == ErrorCode.ProtocolError)
                return new ConnectionLostException(message, code);
            return new BakaShrotException(message, code == ErrorCode.None ? ErrorCode.Internal : code);
        }

    }

    // The library's exports used here, the W ones (UTF-16): bindings/c/bakashrot.h.
    // ptrdiff_t is IntPtr, int64_t long, int32_t int. No calling convention:
    // the library is 64-bit only, where there's one.
    internal static class Native
    {
        private const string Dll = "bakashrot";
        private const CharSet Utf16 = CharSet.Unicode;

        [DllImport(Dll, ExactSpelling = true)] internal static extern long BakaShrot_CreateClient();
        [DllImport(Dll, ExactSpelling = true)] internal static extern IntPtr BakaShrot_FreeClient(long client);
        [DllImport(Dll, ExactSpelling = true)] internal static extern int BakaShrot_GetLastError(long client);
        [DllImport(Dll, ExactSpelling = true)] internal static extern IntPtr BakaShrot_GetRefusalReasonW(long client, byte[] buffer, IntPtr size);
        [DllImport(Dll, ExactSpelling = true, CharSet = Utf16)] internal static extern IntPtr BakaShrot_SetCaCertificateW(long client, string certificate);
        [DllImport(Dll, ExactSpelling = true, CharSet = Utf16)] internal static extern IntPtr BakaShrot_SetCertificateW(long client, string certificate);
        [DllImport(Dll, ExactSpelling = true, CharSet = Utf16)] internal static extern IntPtr BakaShrot_SetPrivateKeyW(long client, string key);
        [DllImport(Dll, ExactSpelling = true, CharSet = Utf16)] internal static extern IntPtr BakaShrot_SetCrlW(long client, string crl);
        [DllImport(Dll, ExactSpelling = true, CharSet = Utf16)] internal static extern IntPtr BakaShrot_ConnectW(long client, string host, int port);
        [DllImport(Dll, ExactSpelling = true)] internal static extern IntPtr BakaShrot_IsConnected(long client);
        [DllImport(Dll, ExactSpelling = true)] internal static extern IntPtr BakaShrot_GetNodeW(long client, byte[] buffer, IntPtr size);
        [DllImport(Dll, ExactSpelling = true, CharSet = Utf16)] internal static extern long BakaShrot_PushMessageToW(long client, string topic, string data);
        [DllImport(Dll, ExactSpelling = true, CharSet = Utf16)] internal static extern IntPtr BakaShrot_GetLatestMessageOfW(long client, string topic, string node);
        [DllImport(Dll, ExactSpelling = true, CharSet = Utf16)] internal static extern int BakaShrot_GetMessagesW(long client, string topic, string node, long after, int limit);
        [DllImport(Dll, ExactSpelling = true)] internal static extern IntPtr BakaShrot_SelectMessage(long client, int index);
        [DllImport(Dll, ExactSpelling = true)] internal static extern IntPtr BakaShrot_HasMoreMessages(long client);
        [DllImport(Dll, ExactSpelling = true)] internal static extern long BakaShrot_GetMessageId(long client);
        [DllImport(Dll, ExactSpelling = true)] internal static extern long BakaShrot_GetMessagePushedAt(long client);
        [DllImport(Dll, ExactSpelling = true)] internal static extern long BakaShrot_GetMessageAttachmentSize(long client);
        [DllImport(Dll, ExactSpelling = true)] internal static extern IntPtr BakaShrot_IsMessageAttachmentReady(long client);
        [DllImport(Dll, ExactSpelling = true)] internal static extern IntPtr BakaShrot_GetMessageDataW(long client, byte[] buffer, IntPtr size);
        [DllImport(Dll, ExactSpelling = true)] internal static extern IntPtr BakaShrot_GetMessageTopicW(long client, byte[] buffer, IntPtr size);
        [DllImport(Dll, ExactSpelling = true)] internal static extern IntPtr BakaShrot_GetMessageNodeW(long client, byte[] buffer, IntPtr size);
        [DllImport(Dll, ExactSpelling = true, CharSet = Utf16)] internal static extern int BakaShrot_ListNamesW(long client, int kind, string topics, string nodes);
        [DllImport(Dll, ExactSpelling = true)] internal static extern IntPtr BakaShrot_GetNamesListAsJsonW(long client, byte[] buffer, IntPtr size);
        [DllImport(Dll, ExactSpelling = true, CharSet = Utf16)] internal static extern IntPtr BakaShrot_QueryW(long client, string sql);
        [DllImport(Dll, ExactSpelling = true)] internal static extern IntPtr BakaShrot_GetQueryResultAsJsonW(long client, byte[] buffer, IntPtr size);
        [DllImport(Dll, ExactSpelling = true, CharSet = Utf16)] internal static extern long BakaShrot_EnumerateNamesW(long client, int kind, string topics, string nodes);
        [DllImport(Dll, ExactSpelling = true)] internal static extern IntPtr BakaShrot_NextName(long enumeration);
        [DllImport(Dll, ExactSpelling = true)] internal static extern IntPtr BakaShrot_GetEnumNameW(long enumeration, byte[] buffer, IntPtr size);
        [DllImport(Dll, ExactSpelling = true, CharSet = Utf16)] internal static extern long BakaShrot_EnumerateQueryW(long client, string sql);
        [DllImport(Dll, ExactSpelling = true)] internal static extern int BakaShrot_GetQueryColumnCount(long enumeration);
        [DllImport(Dll, ExactSpelling = true)] internal static extern IntPtr BakaShrot_GetQueryColumnNameW(long enumeration, int index, byte[] buffer, IntPtr size);
        [DllImport(Dll, ExactSpelling = true)] internal static extern IntPtr BakaShrot_NextQueryRow(long enumeration);
        [DllImport(Dll, ExactSpelling = true)] internal static extern IntPtr BakaShrot_GetQueryValueW(long enumeration, int index, byte[] buffer, IntPtr size);
        [DllImport(Dll, ExactSpelling = true)] internal static extern IntPtr BakaShrot_IsQueryValueNull(long enumeration, int index);
        [DllImport(Dll, ExactSpelling = true)] internal static extern IntPtr BakaShrot_CloseEnum(long enumeration);
        [DllImport(Dll, ExactSpelling = true, CharSet = Utf16)] internal static extern long BakaShrot_PushMessageWithFileW(long client, string topic, string data, string filePath);
        [DllImport(Dll, ExactSpelling = true, CharSet = Utf16)] internal static extern long BakaShrot_PushMessageWithDataW(long client, string topic, string data, byte[] attachment, long size);
        [DllImport(Dll, ExactSpelling = true, CharSet = Utf16)] internal static extern long BakaShrot_SaveAttachmentW(long client, string topic, string node, long messageId, string filePath);
        [DllImport(Dll, ExactSpelling = true, CharSet = Utf16)] internal static extern long BakaShrot_LoadAttachmentW(long client, string topic, string node, long messageId);
        [DllImport(Dll, ExactSpelling = true)] internal static extern long BakaShrot_GetAttachmentData(long client, byte[] buffer, long bufferSize);
        [DllImport(Dll, ExactSpelling = true)] internal static extern IntPtr BakaShrot_FreeAttachmentData(long client);
    }
}
