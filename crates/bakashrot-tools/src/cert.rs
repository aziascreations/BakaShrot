//! `bakashrot cert`: makes a CA, issues certificates, revokes them, shows
//! them, with no server. Every file is PEM; keys are written once, never
//! over an existing file. See `docs/certificates.md`.

use bakashrot_pki::{CA_DAYS, CERTIFICATE_DAYS, Ca, Identity, Revocations, Usage, summarize};
use clap::Subcommand;
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};

// `bakashrot cert`'s commands (its help is `Command::Cert`'s, in main.rs).
#[derive(Subcommand)]
pub enum Command {
    /// Makes a new CA: ca.crt and ca.key in --out. Keep ca.key off the
    /// servers: whoever has it can make any identity.
    Ca {
        /// The CA's name (its certificate's CN).
        #[arg(long)]
        name: String,
        /// How long it's valid, in days.
        #[arg(long, default_value_t = CA_DAYS)]
        days: u32,
        /// Where to write ca.crt and ca.key.
        #[arg(long, default_value = ".")]
        out: PathBuf,
    },
    /// Issues a certificate for a node: NAME.crt and NAME.key in --out
    /// (or --file's).
    Issue {
        /// The node's name.
        #[arg(long)]
        name: String,
        /// A role, any number of times (the server's config says what each
        /// may do).
        #[arg(long = "role")]
        roles: Vec<String>,
        /// A server's certificate (clients and peers connect to it), not a
        /// client's.
        #[arg(long)]
        server: bool,
        /// How long it's valid, in days.
        #[arg(long, default_value_t = CERTIFICATE_DAYS)]
        days: u32,
        /// The folder of ca.crt and ca.key.
        #[arg(long, default_value = ".")]
        ca: PathBuf,
        /// Where to write the certificate and its key.
        #[arg(long, default_value = ".")]
        out: PathBuf,
        /// The files' name, without .crt and .key (the node's name by
        /// default): another certificate for the same name, beside the
        /// first one (two servers of the same name, a new one before the
        /// old one is revoked).
        #[arg(long)]
        file: Option<String>,
    },
    /// Revokes certificates: (re)writes ca.crl in --ca, with every one
    /// revoked before. Push it to the servers' folders.
    Revoke {
        /// The certificates to revoke.
        #[arg(required = true)]
        certificates: Vec<PathBuf>,
        /// The folder of ca.crt, ca.key and ca.crl.
        #[arg(long, default_value = ".")]
        ca: PathBuf,
        /// When to expect the next CRL, in days.
        #[arg(long, default_value_t = CERTIFICATE_DAYS)]
        days: u32,
    },
    /// Shows what a certificate says.
    Show {
        /// The certificate.
        certificate: PathBuf,
    },
}

/// Runs one of `bakashrot cert`'s commands.
pub fn run(command: Command) -> Result<(), String> {
    match command {
        Command::Ca { name, days, out } => {
            let ca = Ca::create(&name, days).map_err(|e| e.to_string())?;
            write_pair(
                &out.join("ca.crt"),
                &ca.certificate,
                &out.join("ca.key"),
                &ca.key,
            )?;
        }
        Command::Issue {
            name,
            roles,
            server,
            days,
            ca,
            out,
            file,
        } => {
            let roles: Vec<&str> = roles.iter().map(String::as_str).collect();
            let identity = Identity::new(&name, &roles).map_err(|e| e.to_string())?;
            let usage = if server { Usage::Server } else { Usage::Client };
            let issued = load_ca(&ca)?
                .issue(&identity, usage, days)
                .map_err(|e| e.to_string())?;
            let file = file.unwrap_or(name);
            write_pair(
                &out.join(format!("{file}.crt")),
                &issued.certificate,
                &out.join(format!("{file}.key")),
                &issued.key,
            )?;
        }
        Command::Revoke {
            certificates,
            ca: folder,
            days,
        } => revoke(&folder, &certificates, days)?,
        Command::Show { certificate } => show(&certificate)?,
    }
    Ok(())
}

fn read(path: &Path) -> Result<String, String> {
    fs::read_to_string(path).map_err(|error| format!("{}: {error}", path.display()))
}

fn load_ca(folder: &Path) -> Result<Ca, String> {
    Ca::load(
        &read(&folder.join("ca.crt"))?,
        &read(&folder.join("ca.key"))?,
    )
    .map_err(|error| format!("the CA in {}: {error}", folder.display()))
}

/// Writes a new file, never over an existing one; a key readable by its
/// owner only (on Unix).
fn write_new(path: &Path, text: &str, private: bool) -> Result<(), String> {
    let mut options = fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    if private {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    #[cfg(not(unix))]
    let _ = private;
    let mut file = options
        .open(path)
        .map_err(|error| format!("{}: {error}", path.display()))?;
    file.write_all(text.as_bytes())
        .map_err(|error| format!("{}: {error}", path.display()))
}

/// Writes a certificate and its key, both or neither: nothing is written
/// when either is there already, the certificate is removed again when
/// its key can't be written.
fn write_pair(certificate: &Path, pem: &str, key: &Path, key_pem: &str) -> Result<(), String> {
    for path in [certificate, key] {
        if path.exists() {
            return Err(format!(
                "{}: already there, nothing written",
                path.display()
            ));
        }
    }
    write_new(certificate, pem, false)?;
    if let Err(error) = write_new(key, key_pem, true) {
        let _ = fs::remove_file(certificate);
        return Err(format!("{error}, nothing written"));
    }
    println!("Wrote {}", certificate.display());
    println!("Wrote {}", key.display());
    Ok(())
}

fn revoke(folder: &Path, certificates: &[PathBuf], days: u32) -> Result<(), String> {
    let ca = load_ca(folder)?;
    let ca_certificate = read(&folder.join("ca.crt"))?;
    let crl_path = folder.join("ca.crl");

    // Those revoked before stay revoked.
    let mut serials: Vec<Vec<u8>> = if crl_path.exists() {
        Revocations::load(&read(&crl_path)?, &ca_certificate)
            .map_err(|error| format!("{}: {error}", crl_path.display()))?
            .serials()
            .map(<[u8]>::to_vec)
            .collect()
    } else {
        Vec::new()
    };
    for path in certificates {
        let certificate = read(path)?;
        if !ca
            .issued(&certificate)
            .map_err(|e| format!("{}: {e}", path.display()))?
        {
            return Err(format!("{}: not issued by this CA", path.display()));
        }
        let summary = summarize(&certificate).map_err(|e| format!("{}: {e}", path.display()))?;
        if !serials.contains(&summary.serial) {
            serials.push(summary.serial);
        }
        println!("Revoked {} ({})", path.display(), summary.subject);
    }

    // Written aside then moved: a server reading it never sees half of it.
    let crl = ca
        .revocation_list(&serials, days)
        .map_err(|e| e.to_string())?;
    let temporary = folder.join("ca.crl.new");
    fs::write(&temporary, crl).map_err(|error| format!("{}: {error}", temporary.display()))?;
    fs::rename(&temporary, &crl_path)
        .map_err(|error| format!("{}: {error}", crl_path.display()))?;
    println!("Wrote {} ({} revoked)", crl_path.display(), serials.len());
    Ok(())
}

fn show(path: &Path) -> Result<(), String> {
    let summary = summarize(&read(path)?).map_err(|e| format!("{}: {e}", path.display()))?;
    println!("{}", path.display());
    match &summary.identity {
        Some(identity) => {
            println!("  name:    {}", identity.name);
            println!("  roles:   {}", identity.roles.join(", "));
        }
        None => println!("  subject: {}", summary.subject),
    }
    let usage = match (summary.is_ca, summary.usage) {
        (true, _) => "CA",
        (false, Some(Usage::Server)) => "server",
        (false, Some(Usage::Client)) => "client",
        (false, None) => "other",
    };
    println!("  usage:   {usage}");
    println!("  issuer:  {}", summary.issuer);
    println!("  valid:   {} to {}", summary.not_before, summary.not_after);
    println!("  serial:  {}", summary.serial_hex());
    Ok(())
}
