using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Threading;
using NUnit.Framework;

namespace NibblePoker.BakaShrot.Tests
{
    // Each test pushes to topics of its own: ids start at 1 in each.
    public class ClientTests
    {
        [Test]
        public void ConnectsFromAClientToml()
        {
            using Client kitchen = Server.Connect("kitchen");
            Assert.That(kitchen.Connected, Is.True);
            Assert.That(kitchen.Node, Is.EqualTo("kitchen"));
            Assert.That(kitchen.Port, Is.EqualTo(Server.Port));
        }

        [Test]
        public void NothingYet()
        {
            using Client kitchen = Server.Connect("kitchen");
            kitchen.Push("nothing-other", "so kitchen has a message somewhere");
            Assert.That(kitchen.Latest("nothing", "kitchen"), Is.Null);
            MessagesPage page = kitchen.GetMessages("nothing", "kitchen", 0, 1000);
            Assert.That(page.Messages, Is.Empty);
            Assert.That(page.More, Is.False);
            Assert.That(page.LastId, Is.EqualTo(0));
        }

        [Test]
        public void PushesAndPages()
        {
            using Client kitchen = Server.Connect("kitchen");
            List<long> ids = Enumerable.Range(1, 250).Select(i => kitchen.Push("pages", "{\"i\":" + i + "}")).ToList();
            Assert.That(ids, Is.EqualTo(Enumerable.Range(1, 250).Select(i => (long)i)));

            Message latest = kitchen.Latest("pages", "kitchen");
            Assert.That(latest.Id, Is.EqualTo(250));
            Assert.That(latest.Data, Is.EqualTo("{\"i\":250}"));
            Assert.That(latest.Pushed, Is.EqualTo(DateTime.UtcNow).Within(TimeSpan.FromMinutes(1)));
            Assert.That(latest.Pushed.Kind, Is.EqualTo(DateTimeKind.Utc));

            MessagesPage page = kitchen.GetMessages("pages", "kitchen", 0, 100);
            Assert.That(page.Messages.Select(m => m.Id), Is.EqualTo(Enumerable.Range(1, 100).Select(i => (long)i)));
            Assert.That(page.More, Is.True);
            Assert.That(page.LastId, Is.EqualTo(100));
            Message first = page.Messages[0];
            Assert.That((first.Topic, first.Node, first.Data, first.AttachmentSize, first.AttachmentReady),
                Is.EqualTo(("pages", "kitchen", "{\"i\":1}", 0L, false)));
            Assert.That(page.Messages.Select(m => m.PushedAt), Is.Ordered);

            page = kitchen.GetMessages("pages", "kitchen", 150, 100);
            Assert.That(page.Messages.Select(m => m.Id), Is.EqualTo(Enumerable.Range(151, 100).Select(i => (long)i)));
            Assert.That(page.More, Is.False);

            page = kitchen.GetMessages("PAGES", "Kitchen", 250, 1000);
            Assert.That(page.Messages, Is.Empty, "names in another case, after the last one");

            Assert.That(kitchen.IterMessages("pages", "kitchen", 0).Select(m => m.Id),
                Is.EqualTo(Enumerable.Range(1, 250).Select(i => (long)i)));
        }

        [Test]
        public void DataAsPushed()
        {
            using Client kitchen = Server.Connect("kitchen");
            string[] data = { "plain text, not JSON", "héllo wörld, 🌍, 日本語", "", "{\"a\":[1,2]}" };
            foreach (string one in data)
                kitchen.Push("data", one);
            Assert.That(kitchen.GetMessages("data", "kitchen", 0, 1000).Messages.Select(m => m.Data), Is.EqualTo(data));
            Assert.That(kitchen.Push("data", null!), Is.EqualTo(5), "null data is empty");
        }

        [Test]
        public void AnswersSplitAtAboutOneMegabyte()
        {
            using Client kitchen = Server.Connect("kitchen");
            string big = new string('x', 700 * 1024);
            long[] ids = { kitchen.Push("big", big), kitchen.Push("big", big), kitchen.Push("big", big) };
            MessagesPage page = kitchen.GetMessages("big", "kitchen", 0, 10);
            Assert.That(page.Messages.Select(m => m.Id), Is.EqualTo(ids.Take(1)));
            Assert.That(page.More, Is.True);
            List<Message> every = kitchen.IterMessages("big", "kitchen", 0).ToList();
            Assert.That(every.Select(m => m.Id), Is.EqualTo(ids));
            Assert.That(every.All(m => m.Data == big), Is.True);
        }

        [Test]
        public void Refusals()
        {
            using Client kitchen = Server.Connect("kitchen");
            kitchen.Push("refusals", "x");

            RefusedException refused = Assert.Throws<RefusedException>(() => kitchen.GetMessages("refusals", "nobody", 0, 1000))!;
            Assert.That(refused.Code, Is.EqualTo(ErrorCode.UnknownName));
            Assert.That(refused.Message, Does.Contain("nobody"));
            Assert.That(kitchen.Connected, Is.True, "still connected after a refusal");

            BakaShrotException error = Assert.Throws<BakaShrotException>(() => kitchen.Push("a b", "x"))!;
            Assert.That(error.Code, Is.EqualTo(ErrorCode.InvalidArgument));
            Assert.That(error.Message, Does.Contain("isn't a topic name"));

            error = Assert.Throws<BakaShrotException>(() => kitchen.Push("refusals", "a\0b"))!;
            Assert.That(error.Code, Is.EqualTo(ErrorCode.InvalidArgument), "a NUL would cut the message");

            error = Assert.Throws<BakaShrotException>(() => kitchen.GetMessages("refusals", "kitchen", 0, 0))!;
            Assert.That(error.Code, Is.EqualTo(ErrorCode.InvalidArgument), "limit 0");
            error = Assert.Throws<BakaShrotException>(() => kitchen.GetMessages("refusals", "kitchen", -1, 10))!;
            Assert.That(error.Code, Is.EqualTo(ErrorCode.InvalidArgument), "after -1");

            using Client lounge = Server.Connect("lounge");
            refused = Assert.Throws<RefusedException>(() => lounge.Push("logs", "x"))!;
            Assert.That(refused.Code, Is.EqualTo(ErrorCode.NotAllowed));
            refused = Assert.Throws<RefusedException>(() => lounge.GetMessages("refusals", "kitchen", 0, 1000))!;
            Assert.That(refused.Code, Is.EqualTo(ErrorCode.NotAllowed));
            refused = Assert.Throws<RefusedException>(() => lounge.Query("SELECT 1"))!;
            Assert.That(refused.Code, Is.EqualTo(ErrorCode.NotAllowed));
            Assert.That(kitchen.Connected && lounge.Connected, Is.True, "two clients at once");
        }

        [Test]
        public void Queries()
        {
            using Client kitchen = Server.Connect("kitchen");
            kitchen.Push("query", "{\"t\":21}");
            kitchen.Push("query", "not JSON");
            Assert.That(kitchen.Query(
                    "SELECT is_json, COUNT(*) AS n FROM messages WHERE topic = 'query' GROUP BY is_json ORDER BY is_json"),
                Is.EqualTo("{\"columns\":[\"is_json\",\"n\"],\"rows\":[[\"0\",\"1\"],[\"1\",\"1\"]]}"));
            Assert.That(kitchen.Query("SELECT 'é🌍' AS q"), Does.Contain("é🌍"), "UTF-16 both ways");

            RefusedException refused = Assert.Throws<RefusedException>(() => kitchen.Query("SELECT nope FROM data"))!;
            Assert.That(refused.Code, Is.EqualTo(ErrorCode.QueryFailed));
        }

        [Test]
        public void Lists()
        {
            using Client kitchen = Server.Connect("kitchen");
            kitchen.Push("listed", "x");
            Assert.That(kitchen.ListTopics(), Does.StartWith("{\"kind\":\"topic\"").And.Contain("\"listed\""));
            Assert.That(kitchen.ListNodes(), Does.StartWith("{\"kind\":\"node\"").And.Contain("\"kitchen\""));

            // Filtered: the topics a node pushed to, the nodes of a topic.
            Assert.That(kitchen.ListTopics(null, "KITCHEN"), Does.Contain("\"listed\""));
            Assert.That(kitchen.ListNodes("list?d", null), Is.EqualTo("{\"kind\":\"node\",\"names\":[\"kitchen\"],\"truncated\":false}"));
            Assert.That(kitchen.ListTopics(null, "nobody"), Is.EqualTo("{\"kind\":\"topic\",\"names\":[],\"truncated\":false}"));
            BakaShrotException invalid = Assert.Catch<BakaShrotException>(() => kitchen.ListNodes("a b", null))!;
            Assert.That(invalid.Code, Is.EqualTo(ErrorCode.InvalidArgument));
        }

        [Test]
        public void Enumerations()
        {
            using Client kitchen = Server.Connect("kitchen");
            kitchen.Push("enumerated", "x");
            kitchen.Push("enumerated", "y");
            Assert.That(kitchen.EnumerateTopics(), Does.Contain("enumerated"));
            Assert.That(kitchen.EnumerateTopics(null, "KITCHEN"), Does.Contain("enumerated"));
            Assert.That(kitchen.EnumerateNodes("enumer*", null), Is.EqualTo(new[] { "kitchen" }));
            Assert.That(kitchen.EnumerateNodes("nothing", null), Is.Empty);

            // Rows: by index or column, NULL as null; asked again each time.
            IEnumerable<QueryRow> rows = kitchen.EnumerateQuery(
                "SELECT message_data AS data, NULL AS missing, '' AS empty FROM messages WHERE topic = 'enumerated' ORDER BY message_id");
            for (int pass = 0; pass < 2; pass++)
            {
                List<QueryRow> got = new List<QueryRow>(rows);
                Assert.That(got.Count, Is.EqualTo(2));
                Assert.That(got[0].Columns, Is.EqualTo(new[] { "data", "missing", "empty" }));
                Assert.That(got[0]["data"], Is.EqualTo("x"));
                Assert.That(got[1][0], Is.EqualTo("y"));
                Assert.That(got[1]["missing"], Is.Null);
                Assert.That(got[1]["empty"], Is.EqualTo(""));
                Assert.Throws<ArgumentException>(() => { string _ = got[0]["nope"]; });
            }
            Assert.That(kitchen.EnumerateQuery("SELECT 1 AS a WHERE 0"), Is.Empty);

            // Failures when the foreach starts; closing the client ends one.
            IEnumerable<string> bad = kitchen.EnumerateNodes("a b", null);
            Assert.That(Assert.Catch<BakaShrotException>(() => bad.GetEnumerator().MoveNext())!.Code,
                Is.EqualTo(ErrorCode.InvalidArgument));
            Assert.That(Assert.Throws<RefusedException>(() => new List<QueryRow>(kitchen.EnumerateQuery("SELECT nope")))!.Code,
                Is.EqualTo(ErrorCode.QueryFailed));
            using (IEnumerator<string> topics = kitchen.EnumerateTopics().GetEnumerator())
            {
                Assert.That(topics.MoveNext(), Is.True);
                kitchen.Close();
                Assert.Throws<ConnectionLostException>(() => topics.MoveNext());
            }
        }

        [Test]
        public void Attachments()
        {
            using Client kitchen = Server.Connect("kitchen");
            byte[] blob = new byte[3 * 1024 * 1024 + 7];
            new Random(1).NextBytes(blob);
            long blobId = kitchen.Push("files", "{\"kind\":\"blob\"}", blob);
            Message message = kitchen.Latest("files", "kitchen");
            Assert.That((message.Id, message.AttachmentSize, message.AttachmentReady),
                Is.EqualTo((blobId, blob.LongLength, true)));
            Assert.That(kitchen.GetAttachment("files", "kitchen", blobId), Is.EqualTo(blob));

            string source = Server.In("source.bin");
            byte[] contents = new byte[1500 * 1024];
            new Random(2).NextBytes(contents);
            File.WriteAllBytes(source, contents);
            long fileId = kitchen.PushFile("files", "from a file", source);
            string copy = Server.In("copy.bin");
            Assert.That(kitchen.SaveAttachment("files", "kitchen", fileId, copy), Is.EqualTo(contents.Length));
            using (SHA256 sha = SHA256.Create())
                Assert.That(sha.ComputeHash(File.ReadAllBytes(copy)), Is.EqualTo(sha.ComputeHash(contents)));

            long plainId = kitchen.Push("files", "no attachment");
            RefusedException refused = Assert.Throws<RefusedException>(() => kitchen.GetAttachment("files", "kitchen", plainId))!;
            Assert.That(refused.Code, Is.EqualTo(ErrorCode.NotFound));
            string none = Server.In("none.bin");
            refused = Assert.Throws<RefusedException>(() => kitchen.SaveAttachment("files", "kitchen", plainId, none))!;
            Assert.That(refused.Code, Is.EqualTo(ErrorCode.NotFound));
            Assert.That(File.Exists(none), Is.False, "a failed one leaves no file");

            BakaShrotException error = Assert.Throws<BakaShrotException>(() => kitchen.Push("files", "x", new byte[0]))!;
            Assert.That(error.Code, Is.EqualTo(ErrorCode.InvalidArgument));
            error = Assert.Throws<BakaShrotException>(() => kitchen.PushFile("files", "x", Server.In("missing.bin")))!;
            Assert.That(error.Code, Is.EqualTo(ErrorCode.FileError));
            Assert.That(error.Message, Does.Contain("missing.bin"));
            Assert.That(kitchen.Connected, Is.True);
        }

        [Test]
        public void FollowsFromAnotherThread()
        {
            using Client kitchen = Server.Connect("kitchen");
            kitchen.Push("follow", "before");
            IEnumerable<Message> follow = kitchen.Follow("follow", "kitchen");
            List<Message> followed = new List<Message>();
            Exception? failed = null;
            Thread thread = new Thread(() =>
            {
                try
                {
                    foreach (Message message in follow)
                    {
                        followed.Add(message);
                        if (followed.Count == 5)
                            return;
                    }
                }
                catch (Exception error)
                {
                    failed = error;
                }
            });
            thread.Start();
            Thread.Sleep(300);
            List<long> ids = Enumerable.Range(0, 5).Select(i => kitchen.Push("follow", "{\"f\":" + i + "}")).ToList();
            Assert.That(thread.Join(10000), Is.True);
            Assert.That(failed, Is.Null);
            Assert.That(followed.Select(m => m.Id), Is.EqualTo(ids), "only the new ones");
        }

        [Test]
        public void TwoClientsInTwoThreads()
        {
            using Client a = Server.Connect("kitchen");
            using Client b = Server.Connect("kitchen");
            List<long>[] pushed = { new List<long>(), new List<long>() };
            Thread[] threads = new[] { a, b }.Select((client, index) => new Thread(() =>
            {
                for (int n = 0; n < 30; n++)
                    pushed[index].Add(client.Push("threads", "{\"n\":" + n + "}"));
            })).ToArray();
            foreach (Thread thread in threads)
                thread.Start();
            foreach (Thread thread in threads)
                Assert.That(thread.Join(30000), Is.True);
            Assert.That(pushed[0].Concat(pushed[1]).OrderBy(id => id), Is.EqualTo(Enumerable.Range(1, 60).Select(i => (long)i)));
        }

        [Test]
        public void Closing()
        {
            Client kitchen = Server.Connect("kitchen");
            kitchen.Ping();
            Assert.That(kitchen.Connected, Is.True, "still connected after a ping");
            kitchen.Close();
            Assert.That(kitchen.Connected, Is.False);
            ConnectionLostException lost = Assert.Throws<ConnectionLostException>(() => kitchen.Push("logs", "x"))!;
            Assert.That(lost.Code, Is.EqualTo(ErrorCode.NotConnected));
            lost = Assert.Throws<ConnectionLostException>(() => kitchen.Ping())!;
            Assert.That(lost.Code, Is.EqualTo(ErrorCode.NotConnected));
            kitchen.Connect();
            Assert.That(kitchen.Connected, Is.True, "connects again");
            kitchen.Dispose();
            Assert.That(kitchen.Connected, Is.False);
        }

        [Test]
        public void AnswerTimeouts()
        {
            const string forever =
                "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n) SELECT count(*) FROM n";
            using Client kitchen = Server.Connect("kitchen");
            Assert.That(kitchen.AnswerTimeoutMs, Is.EqualTo(Client.DefaultAnswerTimeoutMs));
            BakaShrotException refused = Assert.Throws<BakaShrotException>(() => kitchen.AnswerTimeoutMs = 0)!;
            Assert.That(refused.Code, Is.EqualTo(ErrorCode.InvalidArgument));
            kitchen.AnswerTimeoutMs = 300;
            Assert.That(kitchen.Connected, Is.True, "set while connected");
            ConnectionLostException lost = Assert.Throws<ConnectionLostException>(() => kitchen.Query(forever))!;
            Assert.That(lost.Code, Is.EqualTo(ErrorCode.ConnectionLost));
            Assert.That(kitchen.Connected, Is.False);
            kitchen.Connect();
            Assert.That(kitchen.AnswerTimeoutMs, Is.EqualTo(300), "kept across connections");
            lost = Assert.Throws<ConnectionLostException>(() => kitchen.Query(forever))!;
            Assert.That(lost.Code, Is.EqualTo(ErrorCode.ConnectionLost));
        }

        [Test]
        public void Connecting()
        {
            string ca = File.ReadAllText(Server.In("ca.crt"));
            string certificate = File.ReadAllText(Server.In("kitchen.crt"));
            string key = File.ReadAllText(Server.In("kitchen.key"));
            using (Client pem = new Client("127.0.0.1", Server.Port, ca, certificate, key, null).Connect())
                Assert.That(pem.Node, Is.EqualTo("kitchen"), "from PEM text");

            ConnectionLostException lost = Assert.Throws<ConnectionLostException>(() =>
                new Client("127.0.0.1", 1, ca, certificate, key, null).Connect())!;
            Assert.That(lost.Code, Is.EqualTo(ErrorCode.ConnectFailed));

            AuthException auth = Assert.Throws<AuthException>(() => Server.Connect("guest"))!;
            Assert.That(auth.Code, Is.EqualTo(ErrorCode.NotAllowed));

            BakaShrotException error = Assert.Throws<BakaShrotException>(() =>
                new Client("127.0.0.1", Server.Port, Server.In("missing.crt"), certificate, key, null).Connect())!;
            Assert.That(error.Code, Is.EqualTo(ErrorCode.FileError));
            error = Assert.Throws<BakaShrotException>(() =>
                new Client("127.0.0.1", Server.Port, ca, certificate, key, Server.In("missing.crl")).Connect())!;
            Assert.That(error.Code, Is.EqualTo(ErrorCode.FileError), "a CRL given that isn't there");
        }
    }
}
