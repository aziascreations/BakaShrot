//! A server on a free port, in a folder of its own with its CA and the
//! clients' certificates.

use bakashrot_config::Config;
use bakashrot_pki::{Ca, Identity, Usage};
use bakashrot_server::Server;
use std::path::PathBuf;

const CONFIG: &str = r#"
[server]
listen = "127.0.0.1:0"
ca = "ca.crt"
certificate = "server.crt"
key = "server.key"

[roles.home]
push_topics = ["logs", "secret"]
read_topics = ["*"]
query = true

[roles.lounge]
read_topics = ["logs"]
"#;

pub struct Running {
    pub folder: PathBuf,
    pub port: u16,
    ca: Ca,
    // Kept for the server's tasks to run.
    _runtime: tokio::runtime::Runtime,
}

impl Running {
    pub fn start(name: &str) -> Running {
        let folder = PathBuf::from(env!("CARGO_TARGET_TMPDIR"))
            .join(format!("capi-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&folder);
        std::fs::create_dir_all(&folder).unwrap();
        let issued = Ca::create("Test CA", 10).unwrap();
        let ca = Ca::load(&issued.certificate, &issued.key).unwrap();
        let server = ca
            .issue(
                &Identity::new("server-1", &["peer"]).unwrap(),
                Usage::Server,
                10,
            )
            .unwrap();
        std::fs::write(folder.join("ca.crt"), &issued.certificate).unwrap();
        std::fs::write(folder.join("server.crt"), &server.certificate).unwrap();
        std::fs::write(folder.join("server.key"), &server.key).unwrap();
        // `SYNC=normal` to measure without a disk flush per push.
        let sync = std::env::var("SYNC").unwrap_or_else(|_| "full".into());
        let config = CONFIG.replace(
            "[roles.home]",
            &format!(
                "synchronous = \"{sync}\"

[roles.home]"
            ),
        );
        std::fs::write(folder.join("server.toml"), config).unwrap();
        let config = Config::load(&folder.join("server.toml")).unwrap();
        let server = Server::start(config).unwrap();

        let runtime = tokio::runtime::Runtime::new().unwrap();
        let listener = runtime
            .block_on(tokio::net::TcpListener::bind("127.0.0.1:0"))
            .unwrap();
        let port = listener.local_addr().unwrap().port();
        runtime.spawn(async move { server.serve(listener).await });
        Running {
            folder,
            port,
            ca,
            _runtime: runtime,
        }
    }

    /// Issues a client's certificate, written as `<name>.crt` and
    /// `<name>.key`, with a `<name>.toml` to connect with.
    pub fn issue(&self, name: &str, roles: &[&str]) {
        let issued = self
            .ca
            .issue(&Identity::new(name, roles).unwrap(), Usage::Client, 10)
            .unwrap();
        std::fs::write(self.folder.join(format!("{name}.crt")), &issued.certificate).unwrap();
        std::fs::write(self.folder.join(format!("{name}.key")), &issued.key).unwrap();
        let toml = format!(
            "server = \"127.0.0.1:{}\"\nca = \"ca.crt\"\ncertificate = \"{name}.crt\"\nkey = \"{name}.key\"\n",
            self.port
        );
        std::fs::write(self.folder.join(format!("{name}.toml")), toml).unwrap();
    }
}
