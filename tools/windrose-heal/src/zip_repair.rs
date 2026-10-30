use anyhow::{Context, Result};
use serde::Serialize;
use std::fs::{self, File};
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};
use zip::write::SimpleFileOptions;

use crate::audit;
use crate::heal::{self, Strategy};
use crate::levels;
use crate::player_db;
use crate::summary;

const MAX_ZIP_ENTRIES: usize = 20_000;
const MAX_EXTRACTED_FILE_BYTES: u64 = 256 * 1024 * 1024;
const MAX_EXTRACTED_TOTAL_BYTES: u64 = 512 * 1024 * 1024;

#[derive(Debug, Serialize)]
pub struct ZipRepairReport {
    pub scanned_players: usize,
    pub repaired_players: usize,
    pub players: Vec<PlayerRepairResult>,
}

#[derive(Debug, Serialize)]
pub struct PlayerRepairResult {
    pub player_db: String,
    pub player_name: Option<String>,
    pub drift_detected: bool,
    pub case: String,
}

pub fn repair_zip(
    input_zip: &Path,
    output_zip: &Path,
    strategy: Strategy,
    audit: &audit::Audit,
) -> Result<ZipRepairReport> {
    if !input_zip.is_file() {
        anyhow::bail!("input zip not found: {:?}", input_zip);
    }

    let scratch = tempfile::Builder::new()
        .prefix("windrose-heal-")
        .tempdir()
        .context("create scratch directory")?;
    let extract_root = scratch.path().join("extracted");
    fs::create_dir_all(&extract_root)?;
    extract_safe(input_zip, &extract_root)?;

    let player_dbs = find_player_dbs(&extract_root)?;
    if player_dbs.is_empty() {
        anyhow::bail!("could not find SaveProfiles/<steamid>/RocksDB/0.10.0/Players/<PlayerId> in uploaded zip");
    }

    let mut players = Vec::new();
    let mut repaired_players = 0usize;
    let mut profile_dirs = Vec::new();

    for db_path in &player_dbs {
        if let Some(profile_dir) = profile_dir_for_player_db(db_path) {
            profile_dirs.push(profile_dir);
        }

        let result = repair_player_db(db_path, strategy, audit)
            .with_context(|| format!("repair player DB {:?}", db_path))?;
        if result.drift_detected && !result.case.starts_with("no-op") {
            repaired_players += 1;
        }
        players.push(result);
    }

    if repaired_players == 0 {
        anyhow::bail!("no repairable progression drift was found in the uploaded save");
    }

    cleanup_profile_backups(&profile_dirs)?;

    if let Some(parent) = output_zip.parent() {
        fs::create_dir_all(parent)?;
    }
    write_zip_from_dir(&extract_root, output_zip)?;

    Ok(ZipRepairReport {
        scanned_players: player_dbs.len(),
        repaired_players,
        players,
    })
}

pub fn repair_player_db(
    db_path: &Path,
    strategy: Strategy,
    audit: &audit::Audit,
) -> Result<PlayerRepairResult> {
    let (key, value_before) = player_db::read_single_r5bl_player_row(db_path)?;
    let doc_before = player_db::parse_bson(&value_before)?;
    player_db::assert_roundtrip(&doc_before, &value_before)?;

    let summary_before = summary::Summary::from_doc(&doc_before, &key, value_before.len())?;
    let levels = levels::vanilla_da_hero_levels();
    let diagnosis = heal::diagnose(&doc_before, &levels)?;

    if !diagnosis.drift_detected {
        return Ok(PlayerRepairResult {
            player_db: db_path.display().to_string(),
            player_name: summary_before.player_name,
            drift_detected: false,
            case: "no-op: no drift detected".to_string(),
        });
    }

    let (doc_after, case_applied) = heal::apply_heal(doc_before.clone(), &diagnosis, strategy)?;
    let value_after = player_db::emit_bson(&doc_after)?;

    let doc_reparsed = player_db::parse_bson(&value_after)?;
    player_db::assert_roundtrip(&doc_reparsed, &value_after)?;

    player_db::write_r5bl_player_row(db_path, &key, &value_after)?;

    let (_verify_key, value_verify) = player_db::read_single_r5bl_player_row(db_path)?;
    if value_verify != value_after {
        anyhow::bail!(
            "post-write verification failed: reread value does not match what was written"
        );
    }

    let summary_after = summary::Summary::from_doc(&doc_after, &key, value_after.len())?;
    audit.record(
        db_path,
        &case_applied,
        &summary_before,
        &summary_after,
        strategy.as_str(),
    )?;

    Ok(PlayerRepairResult {
        player_db: db_path.display().to_string(),
        player_name: summary_after.player_name,
        drift_detected: true,
        case: case_applied,
    })
}

fn extract_safe(input_zip: &Path, output_dir: &Path) -> Result<()> {
    extract_safe_with_limits(
        input_zip,
        output_dir,
        MAX_ZIP_ENTRIES,
        MAX_EXTRACTED_FILE_BYTES,
        MAX_EXTRACTED_TOTAL_BYTES,
    )
}

fn extract_safe_with_limits(
    input_zip: &Path,
    output_dir: &Path,
    max_entries: usize,
    max_file_bytes: u64,
    max_total_bytes: u64,
) -> Result<()> {
    let file = File::open(input_zip).with_context(|| format!("open {:?}", input_zip))?;
    let mut archive = zip::ZipArchive::new(file).context("open zip archive")?;

    if archive.len() > max_entries {
        anyhow::bail!("zip has too many entries; refusing to extract");
    }

    let mut extracted_total = 0u64;
    for i in 0..archive.len() {
        let mut file = archive.by_index(i)?;
        let enclosed = file.enclosed_name().ok_or_else(|| {
            anyhow::anyhow!("unsafe zip entry path: {}", String::from_utf8_lossy(file.name_raw()))
        })?;
        let out_path = output_dir.join(enclosed);

        if file.is_dir() {
            fs::create_dir_all(&out_path)?;
            continue;
        }

        let announced_size = file.size();
        if announced_size > max_file_bytes {
            anyhow::bail!("zip entry is too large; refusing to extract");
        }
        if extracted_total.saturating_add(announced_size) > max_total_bytes {
            anyhow::bail!("zip extracted size is too large; refusing to extract");
        }

        if let Some(parent) = out_path.parent() {
            fs::create_dir_all(parent)?;
        }
        let mut out = File::create(&out_path)?;
        let written = copy_limited(
            &mut file,
            &mut out,
            max_file_bytes,
            max_total_bytes.saturating_sub(extracted_total),
        )?;
        extracted_total = extracted_total
            .checked_add(written)
            .ok_or_else(|| anyhow::anyhow!("zip extracted size overflow"))?;
    }

    Ok(())
}

fn copy_limited<R: Read, W: Write>(
    reader: &mut R,
    writer: &mut W,
    max_file_bytes: u64,
    max_remaining_bytes: u64,
) -> Result<u64> {
    let mut written = 0u64;
    let mut buffer = [0u8; 64 * 1024];

    loop {
        let read = reader.read(&mut buffer)?;
        if read == 0 {
            break;
        }
        written = written
            .checked_add(read as u64)
            .ok_or_else(|| anyhow::anyhow!("zip extracted size overflow"))?;
        if written > max_file_bytes || written > max_remaining_bytes {
            anyhow::bail!("zip extracted size is too large; refusing to extract");
        }
        writer.write_all(&buffer[..read])?;
    }

    Ok(written)
}

fn find_player_dbs(root: &Path) -> Result<Vec<PathBuf>> {
    let mut found = Vec::new();
    walk_dirs(root, &mut |path| {
        if path.file_name().and_then(|s| s.to_str()) == Some("Players") {
            if path_components_end_with(path, &["RocksDB", "0.10.0", "Players"]) {
                if let Ok(entries) = fs::read_dir(path) {
                    for entry in entries.flatten() {
                        let child = entry.path();
                        if child.is_dir() && child.join("CURRENT").is_file() {
                            found.push(child);
                        }
                    }
                }
            }
        }
    })?;
    found.sort();
    Ok(found)
}

fn profile_dir_for_player_db(db_path: &Path) -> Option<PathBuf> {
    let mut cur = db_path;
    for _ in 0..4 {
        cur = cur.parent()?;
    }
    Some(cur.to_path_buf())
}

fn cleanup_profile_backups(profile_dirs: &[PathBuf]) -> Result<()> {
    for profile_dir in profile_dirs {
        if let Some(parent) = profile_dir.parent() {
            if let Some(profile_name) = profile_dir.file_name() {
                let backup_dir = parent.join(format!("{}_Backups", profile_name.to_string_lossy()));
                if backup_dir.is_dir() {
                    fs::remove_dir_all(&backup_dir)
                        .with_context(|| format!("remove {:?}", backup_dir))?;
                }
            }
        }

        if let Ok(entries) = fs::read_dir(profile_dir) {
            for entry in entries {
                let entry = entry?;
                let path = entry.path();
                let name = entry.file_name().to_string_lossy().to_string();
                if path.is_dir() && name.starts_with("_scout_quarantine_") {
                    fs::remove_dir_all(&path).with_context(|| format!("remove {:?}", path))?;
                }
            }
        }
    }
    Ok(())
}

fn write_zip_from_dir(root: &Path, output_zip: &Path) -> Result<()> {
    let file = File::create(output_zip).with_context(|| format!("create {:?}", output_zip))?;
    let mut zip = zip::ZipWriter::new(file);
    let options = SimpleFileOptions::default().compression_method(zip::CompressionMethod::Deflated);

    add_dir_to_zip(root, root, &mut zip, options)?;
    zip.finish()?;
    Ok(())
}

fn add_dir_to_zip(
    root: &Path,
    dir: &Path,
    zip: &mut zip::ZipWriter<File>,
    options: SimpleFileOptions,
) -> Result<()> {
    let mut entries: Vec<_> = fs::read_dir(dir)?.filter_map(|entry| entry.ok()).collect();
    entries.sort_by_key(|entry| entry.path());

    for entry in entries {
        let path = entry.path();
        if path.is_dir() {
            add_dir_to_zip(root, &path, zip, options)?;
            continue;
        }

        let rel = path.strip_prefix(root)?;
        let name = zip_name(rel);
        zip.start_file(name, options)?;
        let mut input = File::open(&path)?;
        io::copy(&mut input, zip)?;
    }

    Ok(())
}

fn zip_name(path: &Path) -> String {
    path.components()
        .map(|component| component.as_os_str().to_string_lossy())
        .collect::<Vec<_>>()
        .join("/")
}

fn walk_dirs<F>(root: &Path, visitor: &mut F) -> Result<()>
where
    F: FnMut(&Path),
{
    if !root.is_dir() {
        return Ok(());
    }
    visitor(root);
    for entry in fs::read_dir(root)? {
        let entry = entry?;
        let path = entry.path();
        if path.is_dir() {
            walk_dirs(&path, visitor)?;
        }
    }
    Ok(())
}

fn path_components_end_with(path: &Path, suffix: &[&str]) -> bool {
    let parts: Vec<String> = path
        .components()
        .map(|component| component.as_os_str().to_string_lossy().to_string())
        .collect();
    if parts.len() < suffix.len() {
        return false;
    }
    let tail = &parts[parts.len() - suffix.len()..];
    tail.iter()
        .zip(suffix.iter())
        .all(|(actual, expected)| actual.eq_ignore_ascii_case(expected))
}

#[cfg(test)]
mod tests {
    use super::*;
    use bson::{doc, Bson};
    use rocksdb::{ColumnFamilyDescriptor, Options, DB};
    use tempfile::TempDir;
    use zip::ZipArchive;

    fn node(level: i32, cost: i32) -> Bson {
        Bson::Document(doc! {
            "NodeLevel": level,
            "NodeData": {
                "NodePointsCost": cost,
            },
        })
    }

    fn player_doc(
        total_exp: i64,
        reward_level: i32,
        stat_points: i32,
        talent_points: i32,
        stat_nodes: Vec<Bson>,
        talent_nodes: Vec<Bson>,
    ) -> bson::Document {
        doc! {
            "PlayerName": "Test Sailor",
            "_guid": "TEST-GUID",
            "PlayerMetadata": {
                "PlayerProgression": {
                    "TotalExp": total_exp,
                    "RewardLevel": reward_level,
                    "StatTree": {
                        "ProgressionPoints": stat_points,
                        "Nodes": stat_nodes,
                    },
                    "TalentTree": {
                        "ProgressionPoints": talent_points,
                        "Nodes": talent_nodes,
                    },
                },
            },
        }
    }

    fn write_player_db(path: &Path, doc: bson::Document) -> Result<()> {
        fs::create_dir_all(path)?;
        let mut opts = Options::default();
        opts.create_if_missing(true);
        opts.create_missing_column_families(true);
        let cfs: Vec<_> = player_db::CFS
            .iter()
            .map(|name| ColumnFamilyDescriptor::new(*name, Options::default()))
            .collect();
        let db = DB::open_cf_descriptors(&opts, path, cfs)?;
        let cf = db.cf_handle("R5BLPlayer").unwrap();
        db.put_cf(&cf, b"player-key", player_db::emit_bson(&doc)?)?;
        db.flush()?;
        drop(db);
        Ok(())
    }

    fn zip_dir(root: &Path, zip_path: &Path) -> Result<()> {
        write_zip_from_dir(root, zip_path)
    }

    fn zip_names(zip_path: &Path) -> Result<Vec<String>> {
        let file = File::open(zip_path)?;
        let mut archive = ZipArchive::new(file)?;
        let mut names = Vec::new();
        for i in 0..archive.len() {
            names.push(archive.by_index(i)?.name()?.to_string());
        }
        Ok(names)
    }

    fn zip_single_file(zip_path: &Path, name: &str, bytes: &[u8]) -> Result<()> {
        let file = File::create(zip_path)?;
        let mut zip = zip::ZipWriter::new(file);
        let options = SimpleFileOptions::default().compression_method(zip::CompressionMethod::Deflated);
        zip.start_file(name, options)?;
        zip.write_all(bytes)?;
        zip.finish()?;
        Ok(())
    }

    #[test]
    fn repair_zip_fixes_no_spend_drift_and_removes_stale_backups() -> Result<()> {
        let temp = TempDir::new()?;
        let input_root = temp.path().join("input");
        let profile = input_root.join("SaveProfiles/76561190000000000");
        let player = profile.join("RocksDB/0.10.0/Players/46C2F72E7113413A8482F79F30D291C4");
        write_player_db(&player, player_doc(1200, 0, 0, 0, vec![], vec![]))?;
        fs::create_dir_all(input_root.join("SaveProfiles/76561190000000000_Backups"))?;
        fs::create_dir_all(profile.join("_scout_quarantine_old"))?;

        let input_zip = temp.path().join("save.zip");
        let output_zip = temp.path().join("repaired.zip");
        zip_dir(&input_root, &input_zip)?;

        let audit = audit::Audit::new(None, "test-run".to_string());
        let report = repair_zip(&input_zip, &output_zip, Strategy::Safe, &audit)?;

        assert_eq!(report.scanned_players, 1);
        assert_eq!(report.repaired_players, 1);

        let names = zip_names(&output_zip)?;
        assert!(names
            .iter()
            .any(|name| name.contains("RocksDB/0.10.0/Players/46C2F72E7113413A8482F79F30D291C4/")));
        assert!(!names.iter().any(|name| name.contains("_Backups")));
        assert!(!names.iter().any(|name| name.contains("_scout_quarantine_")));
        Ok(())
    }

    #[test]
    fn repair_zip_refuses_spent_point_drift_in_safe_mode() -> Result<()> {
        let temp = TempDir::new()?;
        let input_root = temp.path().join("input");
        let player = input_root.join("SaveProfiles/76561190000000000/RocksDB/0.10.0/Players/46C2F72E7113413A8482F79F30D291C4");
        write_player_db(
            &player,
            player_doc(1200, 2, 4, 1, vec![node(3, 1)], vec![node(1, 1)]),
        )?;

        let input_zip = temp.path().join("save.zip");
        let output_zip = temp.path().join("repaired.zip");
        zip_dir(&input_root, &input_zip)?;

        let audit = audit::Audit::new(None, "test-run".to_string());
        let err = repair_zip(&input_zip, &output_zip, Strategy::Safe, &audit).unwrap_err();

        assert!(format!("{err:?}").contains("spent or allocated progression nodes"));
        assert!(!output_zip.exists());
        Ok(())
    }

    #[test]
    fn extract_safe_rejects_zip_slip_paths() -> Result<()> {
        let temp = TempDir::new()?;
        let input_zip = temp.path().join("bad.zip");
        let output_dir = temp.path().join("out");
        zip_single_file(&input_zip, "../evil.txt", b"bad")?;

        let err = extract_safe_with_limits(&input_zip, &output_dir, 20, 1024, 1024).unwrap_err();

        assert!(format!("{err:?}").contains("unsafe zip entry path"));
        Ok(())
    }

    #[test]
    fn extract_safe_rejects_extracted_size_limit() -> Result<()> {
        let temp = TempDir::new()?;
        let input_zip = temp.path().join("too-large.zip");
        let output_dir = temp.path().join("out");
        zip_single_file(
            &input_zip,
            "SaveProfiles/76561190000000000/large.bin",
            b"0123456789abcdef",
        )?;

        let err = extract_safe_with_limits(&input_zip, &output_dir, 20, 8, 8).unwrap_err();

        assert!(format!("{err:?}").contains("too large"));
        Ok(())
    }
}
