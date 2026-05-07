use std::env;
use std::fs::File;
use std::io::{self, BufRead, BufReader};
use std::path::Path;

fn extract_unity_refs(path: &str) -> io::Result<Vec<String>> {
    let mut refs = Vec::new();
    let mut seen_missing = false;
    let mut seen_m_script = false;
    let mut seen_guids = std::collections::HashSet::new();

    let file = File::open(path)?;
    let reader = BufReader::new(file);

    for line in reader.lines() {
        let line = line?;
        if !seen_missing && (line.contains("Missing") || line.contains("missing")) {
            refs.push("contains missing-reference text".to_string());
            seen_missing = true;
        }
        if !seen_m_script && line.contains("m_Script:") {
            refs.push("contains MonoBehaviour script reference".to_string());
            seen_m_script = true;
        }

        if refs.len() >= 12 {
            break;
        }

        if let Some(idx) = line.find("guid:") {
            let rest = &line[idx + 5..];
            let trimmed = rest.trim_start();
            if trimmed.len() >= 32 {
                let guid = &trimmed[..32];
                if guid.chars().all(|c| c.is_ascii_hexdigit()) {
                    let ref_str = format!("guid:{}", guid);
                    if seen_guids.insert(ref_str.clone()) {
                        refs.push(ref_str);
                        if refs.len() >= 12 {
                            break;
                        }
                    }
                }
            }
        }
    }

    Ok(refs)
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 3 || args[1] != "extract-unity-refs" {
        eprintln!("Usage: {} extract-unity-refs <file_path>", args[0]);
        std::process::exit(1);
    }

    let path = &args[2];
    let ext = Path::new(path)
        .extension()
        .and_then(|s| s.to_str())
        .map(|s| s.to_lowercase())
        .unwrap_or_default();

    let is_unity_ext = matches!(
        ext.as_str(),
        "asmdef" | "asset" | "controller" | "mat" | "meta" | "prefab" | "unity"
    );

    let refs = if is_unity_ext {
        extract_unity_refs(path).unwrap_or_else(|_| Vec::new())
    } else {
        Vec::new()
    };

    let json = serde_json::to_string(&refs).unwrap_or_else(|_| "[]".to_string());
    println!("{}", json);
}
