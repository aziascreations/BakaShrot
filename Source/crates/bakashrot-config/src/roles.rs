//! Roles, and what a certificate's roles allow together.

use crate::values::check_names;
use bakashrot_proto::names::{names_equal, pattern_matches};
use serde::Deserialize;

/// Topic or node names and patterns (`sensors.*`, `*` for all), none twice.
#[derive(Debug, Clone, Default, PartialEq, Eq, Deserialize)]
#[serde(try_from = "Vec<String>")]
pub struct NameList(Vec<String>);

impl TryFrom<Vec<String>> for NameList {
    type Error = String;

    fn try_from(list: Vec<String>) -> Result<Self, String> {
        check_names(&list, true)?;
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
        self.0
            .iter()
            .any(|entry| names_equal(entry, name) || pattern_matches(entry, name))
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
/// on its own (a role's topics go with that role's nodes), replication
/// within the server's `replicated_topics`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Permissions {
    pub(crate) roles: Vec<Role>,
    pub(crate) replicated_topics: Option<NameList>,
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

    /// Whether `node`'s messages in `topic` are sent to it.
    pub fn sends(&self, topic: &str, node: &str) -> bool {
        self.replicated(topic)
            && self
                .roles
                .iter()
                .any(|role| role.send_topics.matches(topic) && role.send_nodes.matches(node))
    }

    /// Whether `node`'s messages in `topic` are taken from it.
    pub fn accepts(&self, topic: &str, node: &str) -> bool {
        self.replicated(topic)
            && self
                .roles
                .iter()
                .any(|role| role.accept_topics.matches(topic) && role.accept_nodes.matches(node))
    }

    /// Whether it replicates at all: a peer.
    pub fn replicates(&self) -> bool {
        self.roles
            .iter()
            .any(|role| !role.send_topics.is_empty() || !role.accept_topics.is_empty())
    }

    fn replicated(&self, topic: &str) -> bool {
        self.replicated_topics
            .as_ref()
            .is_none_or(|topics| topics.matches(topic))
    }
}
