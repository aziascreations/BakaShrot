-- BakaShrot's database, schema v9. Read Source/docs/storage.md first: the
-- keys below are packed integers, on purpose, and only bakashrot-storage
-- packs and unpacks them.
--
-- Not compatible with v8 (OldSource/Server/Storage/db_schema_v8.dbml): a
-- database of the old server isn't opened, its data isn't carried over.
-- Needs SQLite 3.38+ (JSON functions, ->>), bundled with the crate.
--
-- Run once, in one transaction, on an empty database (Database::open).
-- Every connection then sets journal_mode = WAL, synchronous (the
-- config's) and busy_timeout. No foreign keys: one writer keeps the tables
-- consistent, the CHECKs keep the values valid.
--
-- Packed keys (storage.md, "Keys"):
--   data.key             = stream_id << 43 | message_id
--   attachment_parts.key = attachment_id << 20 | part
-- 8796093022207 below is 2^43 - 1, a message id's mask.

PRAGMA application_id = 1112754260;  -- 'BSHT': a BakaShrot database

-- About the database itself. schema_version drives migrations: a database
-- without it, or of a version the server doesn't know, is refused; an older
-- one is migrated a version at a time, each step in one transaction that
-- also sets schema_version.
CREATE TABLE metadata (
    name  TEXT PRIMARY KEY,
    value ANY NOT NULL
) WITHOUT ROWID;

INSERT INTO metadata (name, value) VALUES
    ('schema_version', 9),
    ('created_at', CAST(strftime('%s', 'now') AS INTEGER) * 1000);
-- Database::open adds ('created_by', 'bakashrot-storage <version>').

-- A stream: one node's messages in one topic. Message ids count per
-- stream, replication compares streams' last ids, GetMessages reads one.
-- Topics and nodes are only names here: a topic's streams are its rows.
-- last_id is the highest id the stream ever had: deleting messages
-- (retention) leaves it, so ids never go back. Kept by trg_data_last_id.
CREATE TABLE streams (
    stream_id INTEGER PRIMARY KEY CHECK (stream_id BETWEEN 1 AND 1048575),
    topic     TEXT NOT NULL COLLATE NOCASE CHECK (length(topic) BETWEEN 1 AND 64),
    node      TEXT NOT NULL COLLATE NOCASE CHECK (length(node) BETWEEN 1 AND 64),
    last_id   INTEGER NOT NULL DEFAULT 0,
    UNIQUE (topic, node)
);

-- The messages, in ONE b-tree ordered by (stream, message id): key packs
-- both. A stream's messages sit together, a range of them is a range of
-- keys; no other index to write at every push. stream_id, message_id and
-- is_json are computed when read, never stored. pushed_at: ms since
-- 1970-01-01 UTC, stamped by the server it was pushed to, kept by
-- replication.
CREATE TABLE data (
    key          INTEGER PRIMARY KEY,
    pushed_at    INTEGER NOT NULL,
    message_data TEXT NOT NULL,
    stream_id    INTEGER GENERATED ALWAYS AS (key >> 43) VIRTUAL,
    message_id   INTEGER GENERATED ALWAYS AS (key & 8796093022207) VIRTUAL,
    is_json      INTEGER GENERATED ALWAYS AS (json_valid(message_data)) VIRTUAL,
    CHECK (key & 8796093022207 >= 1)
);

-- A message's attachment (one at most), or one being pushed (no message
-- yet). The states (storage.md, "Attachments"):
--   uploading    pushed, its parts coming; message_key is NULL until all
--                came and the message is stored with it, in one
--                transaction. Cut short: deleted, and at every start.
--   replicating  its message came from a peer, its parts come after
--                (asked from part received / 1 MiB on).
--   ready        all here, its SHA-256 checked.
--   too_big      bigger than max_attachment_size: its message is kept,
--                its parts never asked for.
--   deleting     its message was deleted: its parts go in the background,
--                then the row.
CREATE TABLE attachments (
    attachment_id INTEGER PRIMARY KEY,
    message_key   INTEGER,  -- data.key of its message, NULL while uploading
    size          INTEGER NOT NULL CHECK (size BETWEEN 1 AND 1099511627776),
    sha256        BLOB NOT NULL CHECK (length(sha256) = 32),
    received      INTEGER NOT NULL DEFAULT 0 CHECK (received BETWEEN 0 AND size),
    state         TEXT NOT NULL
                       CHECK (state IN ('uploading', 'replicating', 'ready', 'too_big', 'deleting')),
    CHECK ((message_key IS NULL) = (state = 'uploading'))
);
-- A message's attachment, by its message.
CREATE UNIQUE INDEX attachments_message ON attachments (message_key)
    WHERE message_key IS NOT NULL;
-- What's left to do: uploads to clean up, parts to ask for, parts to delete.
CREATE INDEX attachments_state ON attachments (state) WHERE state <> 'ready';

-- Its parts, 1 MiB each (ATTACHMENT_PART_SIZE), the last one what's left,
-- in ONE b-tree: key packs the attachment and the part (2^20 parts of
-- 1 MiB is exactly the 1 TiB limit). An attachment's parts are a range of
-- keys, in order.
CREATE TABLE attachment_parts (
    key       INTEGER PRIMARY KEY,
    part_data BLOB NOT NULL
);

-- A stored message moves its stream's last_id (pushes and replication
-- alike).
CREATE TRIGGER trg_data_last_id AFTER INSERT ON data BEGIN
    UPDATE streams SET last_id = max(last_id, NEW.key & 8796093022207)
    WHERE stream_id = NEW.key >> 43;
END;

-- A deleted message's attachment goes too, in the background.
CREATE TRIGGER trg_data_attachment AFTER DELETE ON data BEGIN
    UPDATE attachments SET state = 'deleting' WHERE message_key = OLD.key;
END;

-- What queries read (Query, read-only): the messages by name, no keys.
-- Joined by key range: a topic's or a node's messages are ranges of the
-- table, read in order (storage.md, "The query surface").
--   SELECT * FROM messages WHERE topic = 'logs' AND node = 'kitchen'
CREATE VIEW messages AS
SELECT s.topic,
       s.node,
       d.message_id,
       d.message_data,
       d.is_json,
       d.pushed_at,
       strftime('%Y-%m-%dT%H:%M:%fZ', d.pushed_at / 1000.0, 'unixepoch') AS pushed_utc,
       a.size AS attachment_size,
       a.state AS attachment_state
FROM streams s
JOIN data d ON d.key BETWEEN (s.stream_id << 43) AND (s.stream_id << 43) + 8796093022207
LEFT JOIN attachments a ON a.message_key = d.key;

-- What to browse with a database tool (v8's): set topic, and node or NULL
-- for all, in its one row, open browse_messages. Never written by the
-- server.
CREATE TABLE browse (
    id    INTEGER PRIMARY KEY CHECK (id = 1),
    topic TEXT COLLATE NOCASE,
    node  TEXT COLLATE NOCASE
);

CREATE VIEW browse_messages AS
SELECT m.node, m.message_id, m.pushed_utc, m.message_data, m.is_json,
       m.attachment_size, m.topic
FROM browse b
JOIN messages m ON m.topic = b.topic
WHERE b.id = 1 AND (b.node IS NULL OR m.node = b.node)
ORDER BY m.pushed_at DESC, m.node, m.message_id DESC;
