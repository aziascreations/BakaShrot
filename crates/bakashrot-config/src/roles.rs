//! Roles, and what a certificate's roles allow together.

use crate::values::check_names;
use bakashrot_proto::names::{name_matches, names_equal};
use serde::Deserialize;

/// Topic or node names and patterns (`sensors.*`, `*` for all), none twice.
#[derive(Debug, Clone, Default, PartialEq, Eq, Deserialize)]
#[serde(try_from = "Vec<String>")]
pub struct NameList(Vec<String>);

impl TryFrom<Vec<String>> for NameList {
    type Error = String;

    fn try_from(list: Vec<String>) -> Result<Self, String> {
        check_names(&list)?;
        Ok(NameList(list))
    }
}

impl NameList {
    /// `*`: every name.
    pub fn every() -> NameList {
        NameList(vec!["*".to_owned()])
    }

    /// Whether `name` is in it: one of its names, or matched by one of its
    /// patterns (without case).
    pub fn matches(&self, name: &str) -> bool {
        self.0.iter().any(|entry| name_matches(entry, name))
    }

    /// Whether it has nothing: matches nothing.
    pub fn is_empty(&self) -> bool {
        self.0.is_empty()
    }

    /// Its names and patterns, as written.
    pub fn entries(&self) -> &[String] {
        &self.0
    }
}

/// A `[roles.<name>]` section: what certificates with this role may do.
/// Every key is optional.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Role {
    /// The role, as certificates say it (compared without case): the
    /// section's name.
    #[serde(skip)]
    pub name: String,
    /// The topics it may push to, always as its own node.
    #[serde(default)]
    pub push_topics: NameList,
    /// The topics it may read the messages of.
    #[serde(default)]
    pub read_topics: NameList,
    /// Whether it may run read-only SQL, which reads every topic.
    #[serde(default)]
    pub query: bool,
    /// Whether listing topics answers every topic with messages, not only
    /// those it may push to or read.
    #[serde(default)]
    pub list_topics: bool,
    /// Whether listing nodes answers every node with messages, not only
    /// those of the topics it may read.
    #[serde(default)]
    pub list_nodes: bool,
    /// Replication: the topics sent to it.
    #[serde(default)]
    pub send_topics: NameList,
    /// Replication: the topics taken from it.
    #[serde(default)]
    pub accept_topics: NameList,
    /// Replication: the nodes whose messages are sent to it (all by default).
    #[serde(default = "NameList::every")]
    pub send_nodes: NameList,
    /// Replication: the nodes whose messages are taken from it (all by
    /// default).
    #[serde(default = "NameList::every")]
    pub accept_nodes: NameList,
}

/// What a certificate may do: everything one of its roles allows, each role
/// on its own (a role's topics go with that role's nodes). The roles are
/// all there is: no other list of topics.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Permissions {
    pub(crate) roles: Vec<Role>,
}

impl Permissions {
    /// Its roles that this server has a section for.
    pub fn roles(&self) -> impl Iterator<Item = &str> {
        self.roles.iter().map(|role| role.name.as_str())
    }

    /// Whether it may push to `topic`.
    pub fn can_push(&self, topic: &str) -> bool {
        self.roles
            .iter()
            .any(|role| role.push_topics.matches(topic))
    }

    /// Whether it may read `topic`'s messages.
    pub fn can_read(&self, topic: &str) -> bool {
        self.roles
            .iter()
            .any(|role| role.read_topics.matches(topic))
    }

    /// Whether it may run read-only SQL.
    pub fn can_query(&self) -> bool {
        self.roles.iter().any(|role| role.query)
    }

    /// Whether listing names may show `topic`: one it may push to or
    /// read, any with `list_topics` or `query` (which reads them all
    /// anyway).
    pub fn may_list_topic(&self, topic: &str) -> bool {
        self.roles.iter().any(|role| {
            role.list_topics
                || role.query
                || role.push_topics.matches(topic)
                || role.read_topics.matches(topic)
        })
    }

    /// Whether listing names may show the nodes with messages in `topic`:
    /// one it may read, any with `list_nodes` or `query`.
    pub fn may_list_nodes_of(&self, topic: &str) -> bool {
        self.roles
            .iter()
            .any(|role| role.list_nodes || role.query || role.read_topics.matches(topic))
    }

    /// Whether `node`'s messages in `topic` are sent to it.
    pub fn sends(&self, topic: &str, node: &str) -> bool {
        self.roles
            .iter()
            .any(|role| role.send_topics.matches(topic) && role.send_nodes.matches(node))
    }

    /// Whether `node`'s messages in `topic` are taken from it.
    pub fn accepts(&self, topic: &str, node: &str) -> bool {
        self.roles
            .iter()
            .any(|role| role.accept_topics.matches(topic) && role.accept_nodes.matches(node))
    }

    /// The topics and the nodes taken from it, as `SyncState` lists them:
    /// its roles' `accept_*` (of those that accept topics), none twice.
    /// What's taken is still [`Permissions::accepts`]'.
    pub fn accepted(&self) -> (Vec<String>, Vec<String>) {
        let (mut topics, mut nodes) = (Vec::<String>::new(), Vec::<String>::new());
        for role in self
            .roles
            .iter()
            .filter(|role| !role.accept_topics.is_empty())
        {
            for (list, entries) in [
                (&mut topics, role.accept_topics.entries()),
                (&mut nodes, role.accept_nodes.entries()),
            ] {
                for entry in entries {
                    if !list.iter().any(|known| names_equal(known, entry)) {
                        list.push(entry.clone());
                    }
                }
            }
        }
        (topics, nodes)
    }

    /// Whether it replicates at all: a peer.
    pub fn replicates(&self) -> bool {
        self.roles
            .iter()
            .any(|role| !role.send_topics.is_empty() || !role.accept_topics.is_empty())
    }
}
