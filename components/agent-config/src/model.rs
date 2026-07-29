#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Agent {
    Claude,
    Codex,
}

impl Agent {
    pub fn parse(s: &str) -> Result<Self, String> {
        match s {
            "claude" => Ok(Agent::Claude),
            "codex" => Ok(Agent::Codex),
            other => Err(format!("--agent must be claude or codex (got '{other}')")),
        }
    }

    pub fn name(self) -> &'static str {
        match self {
            Agent::Claude => "claude",
            Agent::Codex => "codex",
        }
    }

    pub fn home(self) -> &'static str {
        match self {
            Agent::Claude => ".claude",
            Agent::Codex => ".codex",
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Scope {
    Local,
    Project,
    Managed,
}

impl Scope {
    pub fn parse(s: &str) -> Result<Self, String> {
        match s {
            "local" => Ok(Scope::Local),
            "project" => Ok(Scope::Project),
            "managed" => Ok(Scope::Managed),
            other => Err(format!(
                "--scope must be local, project or managed (got '{other}')"
            )),
        }
    }

    pub fn name(self) -> &'static str {
        match self {
            Scope::Local => "local",
            Scope::Project => "project",
            Scope::Managed => "managed",
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Os {
    Linux,
    Macos,
    Windows,
}

impl Os {
    pub fn parse(s: &str) -> Result<Self, String> {
        match s {
            "linux" => Ok(Os::Linux),
            "macos" => Ok(Os::Macos),
            "windows" => Ok(Os::Windows),
            other => Err(format!(
                "--os must be linux, macos or windows (got '{other}')"
            )),
        }
    }

    pub fn detect() -> Result<Self, String> {
        match std::env::consts::OS {
            "linux" => Ok(Os::Linux),
            "macos" => Ok(Os::Macos),
            "windows" => Ok(Os::Windows),
            other => Err(format!(
                "unsupported host OS '{other}' — pass --os explicitly"
            )),
        }
    }

    pub fn name(self) -> &'static str {
        match self {
            Os::Linux => "linux",
            Os::Macos => "macos",
            Os::Windows => "windows",
        }
    }

    pub fn flavor(self) -> Flavor {
        match self {
            Os::Windows => Flavor::Ps1,
            _ => Flavor::Sh,
        }
    }

    pub const ALL: [Os; 3] = [Os::Linux, Os::Macos, Os::Windows];
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Flavor {
    Sh,
    Ps1,
}

impl Flavor {
    pub fn ext(self) -> &'static str {
        match self {
            Flavor::Sh => "sh",
            Flavor::Ps1 => "ps1",
        }
    }
}

pub struct Cell {
    pub agent: Agent,
    pub scope: Scope,
    pub os: Os,
    pub target: Option<String>,
}

impl Cell {
    pub fn target(&self) -> Result<&str, String> {
        self.target
            .as_deref()
            .ok_or_else(|| format!("--scope {} requires --target <dir>", self.scope.name()))
    }
}

pub enum Location {
    InTarget(String),
    Host(String),
}

impl Location {
    pub fn render_rel(&self) -> Result<String, String> {
        match self {
            Location::InTarget(rel) => Ok(rel.clone()),
            Location::Host(abs) => host_render_rel(abs),
        }
    }
}

fn host_render_rel(target: &str) -> Result<String, String> {
    if let Some(rest) = target.strip_prefix("%USERPROFILE%") {
        return Ok(format!("USERPROFILE{rest}"));
    }
    let b = target.as_bytes();
    if b.len() > 2 && b[0].is_ascii_alphabetic() && b[1] == b':' && b[2] == b'/' {
        return Ok(format!("{}/{}", &target[..1], &target[3..]));
    }
    if let Some(rest) = target.strip_prefix('/') {
        return Ok(rest.to_string());
    }
    Err(format!(
        "cannot map target '{target}' into a render directory"
    ))
}

pub struct Entry {
    pub key: String,
    pub location: Location,
    pub content: Content,
}

pub enum Content {
    File {
        bytes: Vec<u8>,
        executable: bool,
        marked: bool,
    },
    JsonKeys(Vec<(String, serde_json::Value)>),
    TomlSections(Vec<Section>),
    AuthLink {
        source: std::path::PathBuf,
    },
}

pub struct Section {
    pub sentinel: String,
    pub text: String,
}

impl Entry {
    pub fn marked_file(key: &str, location: Location, content: String) -> Entry {
        Entry {
            key: key.into(),
            location,
            content: Content::File {
                bytes: content.into_bytes(),
                executable: false,
                marked: true,
            },
        }
    }
}

impl Content {
    pub fn rendered(&self) -> Option<(Vec<u8>, bool)> {
        match self {
            Content::File {
                bytes, executable, ..
            } => Some((bytes.clone(), *executable)),
            Content::JsonKeys(keys) => {
                let mut object = serde_json::Map::new();
                for (key, value) in keys {
                    object.insert(key.clone(), value.clone());
                }
                Some((
                    json_pretty(&serde_json::Value::Object(object)).into_bytes(),
                    false,
                ))
            }
            Content::TomlSections(sections) => {
                let texts: Vec<&str> = sections.iter().map(|s| s.text.as_str()).collect();
                Some((texts.join("\n").into_bytes(), false))
            }
            Content::AuthLink { .. } => None,
        }
    }
}

pub fn json_pretty(value: &serde_json::Value) -> String {
    let mut out = serde_json::to_string_pretty(value).expect("JSON serialization cannot fail");
    out.push('\n');
    out
}
