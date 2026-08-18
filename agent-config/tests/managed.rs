use std::fs;
use std::path::{Path, PathBuf};

use agent_config::model::{Content, Entry, Location};
use agent_config::place::{self, Confirm};

struct Scripted(Vec<&'static str>);

impl Confirm for Scripted {
    fn confirm(&mut self, _prompt: &str) -> Result<bool, String> {
        match self.0.remove(0) {
            "y" => Ok(true),
            "a" => Ok(true),
            "n" => Ok(false),
            other => panic!("unexpected scripted answer {other}"),
        }
    }
}

struct YesAll;

impl Confirm for YesAll {
    fn confirm(&mut self, _prompt: &str) -> Result<bool, String> {
        Ok(true)
    }
}

struct NeverAsked;

impl Confirm for NeverAsked {
    fn confirm(&mut self, prompt: &str) -> Result<bool, String> {
        panic!("confirm must not be asked, got: {prompt}");
    }
}

fn workspace(name: &str) -> PathBuf {
    let dir = PathBuf::from(env!("CARGO_TARGET_TMPDIR")).join(name);
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).unwrap();
    dir
}

fn host_entry(key: &str, root: &Path, rel: &str, content: &str) -> Entry {
    Entry {
        key: key.into(),
        location: Location::Host(format!(
            "{}/{rel}",
            root.display().to_string().replace('\\', "/")
        )),
        content: Content::File {
            bytes: content.as_bytes().to_vec(),
            executable: false,
            marked: true,
        },
    }
}

#[test]
fn managed_place_confirms_and_marks_each_file() {
    let root = workspace("managed-place-yes");
    let entries = vec![
        host_entry("fragment", &root, "managed-settings.d/10-lab.json", "{}\n"),
        host_entry("hook:conf", &root, "hooks/lab/agent-audit.conf", "a=1\n"),
    ];
    place::managed_place(&entries, "agent-config", &mut YesAll).unwrap();

    for rel in [
        "managed-settings.d/10-lab.json",
        "hooks/lab/agent-audit.conf",
    ] {
        assert!(root.join(rel).is_file(), "missing {rel}");
        let marker = fs::read_to_string(root.join(format!("{rel}.managed"))).unwrap();
        assert!(marker.contains("executor=agent-config"), "{marker}");
        assert!(marker.contains("placed_at="), "{marker}");
        assert!(!marker.contains("endpoint="), "{marker}");
    }
}

#[test]
fn managed_place_decline_skips_the_file() {
    let root = workspace("managed-place-decline");
    let entries = vec![
        host_entry("one", &root, "one.json", "1\n"),
        host_entry("two", &root, "two.json", "2\n"),
    ];
    place::managed_place(&entries, "agent-config", &mut Scripted(vec!["n", "y"])).unwrap();
    assert!(
        !root.join("one.json").exists(),
        "declined file must not be placed"
    );
    assert!(root.join("two.json").is_file());
}

#[test]
fn managed_place_refuses_foreign_files() {
    let root = workspace("managed-place-foreign");
    fs::create_dir_all(root.join("managed-settings.d")).unwrap();
    fs::write(
        root.join("managed-settings.d/10-lab.json"),
        "{\"real\":1}\n",
    )
    .unwrap();

    let entries = vec![host_entry(
        "fragment",
        &root,
        "managed-settings.d/10-lab.json",
        "{}\n",
    )];
    let err = place::managed_place(&entries, "agent-config", &mut NeverAsked).unwrap_err();
    assert!(err.contains("refused"), "{err}");
    assert_eq!(
        fs::read_to_string(root.join("managed-settings.d/10-lab.json")).unwrap(),
        "{\"real\":1}\n",
        "foreign file must never be touched"
    );
}

#[test]
fn managed_place_refuses_a_different_executor() {
    let root = workspace("managed-place-executor");
    let entries = vec![host_entry("fragment", &root, "10-lab.json", "{}\n")];
    place::managed_place(&entries, "executor-a", &mut YesAll).unwrap();

    let err = place::managed_place(&entries, "executor-b", &mut NeverAsked).unwrap_err();
    assert!(err.contains("refused"), "{err}");
}

#[test]
fn managed_place_identical_content_is_a_noop_without_confirm() {
    let root = workspace("managed-place-noop");
    let entries = vec![host_entry("fragment", &root, "10-lab.json", "{}\n")];
    place::managed_place(&entries, "agent-config", &mut YesAll).unwrap();
    place::managed_place(&entries, "agent-config", &mut NeverAsked).unwrap();
}

#[test]
fn managed_place_update_needs_a_fresh_confirm() {
    let root = workspace("managed-place-update");
    place::managed_place(
        &[host_entry("fragment", &root, "10-lab.json", "old\n")],
        "agent-config",
        &mut YesAll,
    )
    .unwrap();
    place::managed_place(
        &[host_entry("fragment", &root, "10-lab.json", "new\n")],
        "agent-config",
        &mut Scripted(vec!["y"]),
    )
    .unwrap();
    assert_eq!(
        fs::read_to_string(root.join("10-lab.json")).unwrap(),
        "new\n"
    );
}

#[test]
fn managed_teardown_removes_marked_files_and_sweeps_empty_dirs() {
    let root = workspace("managed-teardown");
    let entries = vec![
        host_entry("fragment", &root, "managed-settings.d/10-lab.json", "{}\n"),
        host_entry("hook:conf", &root, "hooks/lab/agent-audit.conf", "a=1\n"),
    ];
    place::managed_place(&entries, "agent-config", &mut YesAll).unwrap();

    let candidates: Vec<(String, String)> = [
        ("fragment", "managed-settings.d/10-lab.json"),
        ("hook:conf", "hooks/lab/agent-audit.conf"),
        ("hook:recipient.pem", "hooks/lab/recipient.pem"),
    ]
    .into_iter()
    .map(|(key, rel)| {
        (
            key.to_string(),
            format!("{}/{rel}", root.display().to_string().replace('\\', "/")),
        )
    })
    .collect();

    place::managed_teardown(&candidates, &root, "agent-config", &mut YesAll).unwrap();
    assert!(!root.exists(), "empty managed root must be swept away");
}

#[test]
fn managed_teardown_refuses_unmarked_files() {
    let root = workspace("managed-teardown-foreign");
    fs::write(root.join("10-lab.json"), "real org config\n").unwrap();
    let candidates = vec![(
        "fragment".to_string(),
        format!(
            "{}/10-lab.json",
            root.display().to_string().replace('\\', "/")
        ),
    )];
    let err =
        place::managed_teardown(&candidates, &root, "agent-config", &mut NeverAsked).unwrap_err();
    assert!(err.contains("refused"), "{err}");
    assert!(
        root.join("10-lab.json").is_file(),
        "foreign file must remain"
    );
}

#[test]
fn managed_teardown_refuses_a_different_executor() {
    let root = workspace("managed-teardown-executor");
    let entries = vec![host_entry("fragment", &root, "10-lab.json", "{}\n")];
    place::managed_place(&entries, "executor-a", &mut YesAll).unwrap();

    let candidates = vec![(
        "fragment".to_string(),
        format!(
            "{}/10-lab.json",
            root.display().to_string().replace('\\', "/")
        ),
    )];
    let err =
        place::managed_teardown(&candidates, &root, "executor-b", &mut NeverAsked).unwrap_err();
    assert!(err.contains("refused"), "{err}");
    assert!(root.join("10-lab.json").is_file(), "file must remain");
}
